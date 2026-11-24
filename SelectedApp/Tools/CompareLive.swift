import Foundation
@testable import SelectedCore

/// 生产数据端到端自检：对指定日期跑原生 compare（**只读，不落库**）
///
/// 这是**结构自检**（不比对任何历史期望值）：夹具只是一天的快照，
///   证明不了生产库里那些"三轮不全 / 有缺口 / 含历史回放标记"的真实数据
///   不会让 compare 崩或产出空壳。
@main
struct CompareLive {
    static func main() {
        let date = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
        let outPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2]
                                                     : "/tmp/compare_native.json"
        let rounds = CompareStore.shared.loadRounds(date: date)
        var report = SignalClassifier.compare(rounds, date: date)
        report.removeValue(forKey: "generated_at")
        let data = try! JSONSerialization.data(withJSONObject: report, options: [])
        try! data.write(to: URL(fileURLWithPath: outPath))
        let sig = (report["signals"] as? [String: Any])?.count ?? 0
        print("rounds=\(rounds.count) signals=\(sig) → \(outPath)")

        // ---- 结构自检（不许是空壳）----
        var bad: [String] = []
        func require(_ cond: Bool, _ label: String) { if !cond { bad.append(label) } }

        require(rounds.count == 3, "生产数据应有三轮（实得 \(rounds.count)）")
        require((report["status"] as? String) == "ok",
                "status 应为 ok（实得 \(String(describing: report["status"]))）")
        require(report["date"] as? String == date, "date 应回填为 \(date)")
        require((report["available_slots"] as? [Any])?.count == 3, "available_slots 应 3 项")
        require(sig > 0, "signals 不应为空")
        for key in ["market_env_table", "funnel_table", "tier1_matrix", "tier2_matrix",
                    "tier_changes", "excluded_table", "etf_matrix", "stability",
                    "suggestions", "warnings"] {
            require(report[key] != nil, "报告缺 \(key)")
        }
        // 逐票必须有判定字段（空壳的典型形态是"有 code 没 signal_type"）
        if let signals = report["signals"] as? [String: Any] {
            for (code, v) in signals {
                guard let m = v as? [String: Any] else {
                    bad.append("signals[\(code)] 不是对象")
                    continue
                }
                require(m["signal_type"] != nil, "signals[\(code)] 缺 signal_type")
                require(m["scores"] != nil, "signals[\(code)] 缺 scores")
            }
        }

        if bad.isEmpty {
            print("✅ 生产数据端到端自检通过（\(sig) 只票 / 报告结构完整）")
            exit(0)
        }
        print("❌ 生产数据端到端自检失败 \(bad.count) 项：")
        for b in bad.prefix(15) { print("   " + b) }
        exit(1)
    }
}
