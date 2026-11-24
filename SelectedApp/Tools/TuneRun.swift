import Foundation
@testable import SelectedCore

/// 无头参数调优驱动。
///
/// ## 为什么要有它
/// `PhaseTune.tune()` 的产出只渲染在参数中心调优面板上 —— 要做跨池横向对比
/// （单池最优 ≈ 过拟合噪声，跨池稳定胜出才可信），
/// 本驱动把 tune 的产出落成结构化 JSON，供离线分析。**不进 App 生产路径、不进调度器。**
///
/// ## 只许在**副本库**上跑（`tune_run.sh` 用 `sqlite3 .clone` 现造）
/// 驱动会**改写副本里激活版本的 `iterate.tune_pool_days`**（窗口参数化的唯一途径 ——
/// 该键不在出厂 JSON 里，`tune()` 读的就是激活参数）。线上库全程只读。
///
/// ## 窗口参数化的顺序（写死，别调换）
/// 1. `DBBootstrap.ensureReady()` + `ParamStore.ensureBuiltinSeeded()` 先预热 ——
///    补种逻辑对"内容变了"的出厂版会**按随包文件刷回去**，必须先让它跑完；
/// 2. 再把 `tune_pool_days` 写进激活版本行（本进程 seeded 已置 once，不会再刷）；
/// 3. `PhaseTune.tune()` 经 `activeParams()` 读到的就是改后参数。
///
/// ## 可比性
/// 各档只差 `tune_pool_days` / `include_replay` 两个变量；`seed=42` 固定（`PyRandom`
/// MT19937 同 seed 同序列 ⇒ 变异候选集完全一致，差异只来自样本池）。
///
/// ## 为什么用 replay 扩池而不是多档窗口对比
/// live 复盘日**只有约 13 天**（更早的样本是回放数据）⇒ `LIMIT 30/60/120`
/// 在 13 行的表上取到同一张池，窗口对比退化。稳健性改用
/// `include_replay=true`（设置页同款开关）扩池：回放是**收盘价口径**，与 live 的
/// 尾盘盘中口径不同，混池的绝对值不可当结论 —— 只用它看**改动方向**是否跨池稳定。
@main
struct TuneRun {
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 2, let poolDays = Int(args[1]), poolDays > 0 else {
            FileHandle.standardError.write("用法: tune_run <poolDays> [out.json] [--replay]\n".data(using: .utf8)!)
            exit(2)
        }
        let outPath = args.count >= 3 && args[2] != "--replay" ? args[2] : ""
        let replay = args.contains("--replay")

        // [1] 副本库补齐 schema/迁移 + 出厂参数补种预热
        if let err = DBBootstrap.ensureReady() {
            FileHandle.standardError.write("❌ ensureReady: \(err)\n".data(using: .utf8)!)
            exit(1)
        }
        ParamStore.shared.ensureBuiltinSeeded()
        let active = ParamStore.shared.activeName()
        guard let json = ParamStore.shared.versionParamsJSON(active),
              let data = json.data(using: .utf8),
              var params = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            FileHandle.standardError.write("❌ 激活版本「\(active)」参数不可读\n".data(using: .utf8)!)
            exit(1)
        }

        // [2] 窗口参数化：把 tune_pool_days 写进激活版本（只改副本库这一行）
        var iterate = (params["iterate"] as? [String: Any]) ?? [:]
        iterate["tune_pool_days"] = poolDays
        params["iterate"] = iterate
        do {
            let payload = PyJSON.encode(params)
            try SQLiteWriter.shared.write { tx in
                _ = try tx.execute("UPDATE param_versions SET params_json=? WHERE name=?",
                                   [payload, active])
            }
        } catch {
            FileHandle.standardError.write("❌ 写 tune_pool_days 失败: \(error)\n".data(using: .utf8)!)
            exit(1)
        }

        // [3] 调优（与 UI 同参数：trials=200 / hillRounds=3 / metric=l3 / seed 固定）
        let result: [String: Any]
        do {
            result = try PhaseTune.tune(trials: 200, hillRounds: 3, seed: 42,
                                        metric: PhaseTune.defaultMetric,
                                        includeReplayOverride: replay ? true : nil)
        } catch {
            FileHandle.standardError.write("❌ tune 抛错: \(error)\n".data(using: .utf8)!)
            exit(1)
        }

        // [4] 剥掉 per_stock 明细（逐股数组是体积大头，对比分析用不到）
        var wrapped: [String: Any] = [
            "pool_days_arg": poolDays, "seed": 42, "trials": 200, "hill_rounds": 3,
            "replay_override": replay,
            "active_version": active, "result": stripPerStock(result),
        ]
        wrapped["generated_at"] = ISO8601DateFormatter().string(from: Date())

        guard let outData = try? JSONSerialization.data(
            withJSONObject: wrapped, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
            FileHandle.standardError.write("❌ 输出 JSON 序列化失败\n".data(using: .utf8)!)
            exit(1)
        }
        if !outPath.isEmpty {
            do {
                try outData.write(to: URL(fileURLWithPath: outPath))
                print("已写出 \(outPath)")
            } catch {
                FileHandle.standardError.write("❌ 写文件失败: \(error)\n".data(using: .utf8)!)
                exit(1)
            }
        } else {
            FileHandle.standardOutput.write(outData)
        }

        // [5] 人读摘要（stdout，供脚本日志直接看）
        printDigest(poolDays: poolDays, active: active, result: result)
    }

    private static func stripPerStock(_ dict: [String: Any]) -> [String: Any] {
        var out = dict
        if let base = out["baseline"] as? [String: Any] {
            var b = base
            b.removeValue(forKey: "per_stock")
            out["baseline"] = b
        }
        if let cands = out["candidates"] as? [[String: Any]] {
            out["candidates"] = cands.map { c in
                var cc = c
                if let m = cc["metrics"] as? [String: Any] {
                    var mm = m
                    mm.removeValue(forKey: "per_stock")
                    cc["metrics"] = mm
                }
                return cc
            }
        }
        return out
    }

    private static func num(_ v: Any?) -> Double {
        if let n = v as? NSNumber { return n.doubleValue }
        return 0
    }

    private static func printDigest(poolDays: Int, active: String, result: [String: Any]) {
        guard (result["status"] as? String) == "ok" else {
            print("⚠ tune 未产出候选：\(result["error"] ?? "?")")
            return
        }
        func line(_ tag: String, _ metrics: Any?) {
            guard let m = metrics as? [String: Any] else { return }
            let t1 = (m["tier1"] as? [String: Any]) ?? [:]
            print(String(format: "   %@ total=%.2f  tier1胜率=%.1f%%  均收益=%.2f  覆盖率=%.1f%%",
                         tag, num(m["total"]), num(t1["winrate"]), num(t1["avg_profit"]),
                         num(m["coverage_pct"])))
        }
        print("\n== 窗口 \(poolDays) 天（激活版 \(active)）· 池 \(result["pool_size"] ?? "?") 只 / \(result["pool_dates"] ?? "?") 个交易日 · \(result["pool_window"] ?? "?") ==")
        if let gate = result["sample_gate"] as? [String: Any] {
            print("   sample_gate: \(gate)")
        }
        if let w = result["param_era_warning"] as? String { print("   \(w)") }
        line("基线", (result["baseline"] as? [String: Any])?["metrics"])
        if let cands = result["candidates"] as? [[String: Any]] {
            for (i, c) in cands.enumerated() {
                let diff = (c["diff"] as? [String: Any]) ?? [:]
                print("   ── 候选 \(i + 1)（\(diff.count) 项改动）")
                for k in diff.keys.sorted() {
                    print("      \(k) → \(diff[k]!)")
                }
                line("      ", c["metrics"])
            }
        }
    }
}
