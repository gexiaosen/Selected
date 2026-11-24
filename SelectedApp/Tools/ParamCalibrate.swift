import Foundation
import SQLite3
@testable import SelectedCore

/// 参数标定与验收驱动（真实库、只读；不进回归 —— 非 hermetic，见 run_all.sh 头部登记）
///
/// ## 它存在的理由
/// 2026-09 起的四版参数（backtest / 1.2.0 / 1.3.0 / strict）都靠一次性脚本标定，脚本没进仓库
/// ⇒ 下一轮迭代只能重新手写，也没有任何东西能证明当时的结论可复现。本驱动把
/// 「按真实落库特征重算分数 → 按档位切档 → 双口径统计成功率」固化成一条命令。
///
/// ## ⚠ 打分走真引擎，不走复刻
/// 分数一律由 `Screener.scoreStock` 现算，特征从 `picks.deep_info_json` 反序列化回
/// `DeepInfo` / `EngineQuote`。`--fidelity` 断言「用产生该轮的那一版参数重算 == 库里存的 score」
/// —— 这是工具自身的防漂移闸门：**引擎打分口径一改就报红**，而不是继续用旧公式给新参数下结论。
///
/// ## ⚠ 双口径必须分开（本项目最容易得出错结论的地方，判据 = `reviews.scan_mode`）
///   · `live`         14:00/14:30/14:50 盘中快照，量比是**时点**量比
///   · `replay_close` 收盘口径重建，量比是**全日**量比
/// 阈值不可互换；混算出来的"最优带"是两种口径的平均数，两个都不对。
///
/// ## ⚠ 两把尺子（2026-11-02 核对结论，两个都算）
///   · `stock_outcomes.disc_*` = 统一政策 `discipline_target_pct`（出厂 1.5%）⇒ **调优器读这套**
///   · `reviews.four_layer_json.disciplined` = 每票目标价反推（实盘约 +3.0%）⇒ **界面显示这套**
/// 同一天可差 10~20pp。标定用前者，验收必须看后者。
///
/// ## 收紧带为什么能"事后"应用
/// 画像带与价格下限位于打分**之前**，而打分/档位**逐只**决定（不依赖同轮其他票），
/// 所以在已评分池上按同条件剔除 = 重跑扫描。例外是 `budget.*`（会改变"谁被评分"），本工具不模拟。
@main
struct ParamCalibrate {

    struct Row {
        let date: String
        let slot: Int
        let code: String
        let storedScore: Double
        let quote: EngineQuote
        let deep: DeepInfo
        let intraday: [String: Any]?
        let formScore: Int
        let windowProfit: Double?
        let highProfit: Double?
        let closeProfit: Double?
        let discProfit: Double?
        let roundParamVersion: String
    }

    struct Stat {
        var n = 0
        var days = Set<String>()
        var hit15 = 0, hit15n = 0
        var hit30 = 0, hit30n = 0
        var closeWin = 0, closeN = 0
        var discSum = 0.0, discN = 0
    }

    static func fail(_ msg: String) -> Never {
        FileHandle.standardError.write("❌ \(msg)\n".data(using: .utf8)!)
        exit(2)
    }

    // MARK: - SQLite 取值

    static func txt(_ s: OpaquePointer?, _ i: Int32) -> String {
        guard let c = sqlite3_column_text(s, i) else { return "" }
        return String(cString: c)
    }
    static func dbl(_ s: OpaquePointer?, _ i: Int32) -> Double? {
        sqlite3_column_type(s, i) == SQLITE_NULL ? nil : sqlite3_column_double(s, i)
    }
    static func intg(_ s: OpaquePointer?, _ i: Int32) -> Int {
        sqlite3_column_type(s, i) == SQLITE_NULL ? -1 : Int(sqlite3_column_int64(s, i))
    }
    static func prepare(_ db: OpaquePointer?, _ sql: String) -> OpaquePointer? {
        var s: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &s, nil) != SQLITE_OK {
            fail("SQL 准备失败：\(sql)\n   \(String(cString: sqlite3_errmsg(db)))")
        }
        return s
    }
    /// 只读打开 —— 工具绝不可能改动"库是唯一不可再生资产"
    static func openDB(_ path: String) -> OpaquePointer? {
        var db: OpaquePointer?
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
            fail("打不开库（只读）：\(path)\n   \(String(cString: sqlite3_errmsg(db)))")
        }
        return db
    }

    // MARK: - 取数

    /// `DeepInfo.json` 的逆（缺键按引擎同款回落，不猜值）
    static func deepFrom(_ j: [String: Any]) -> DeepInfo {
        func d(_ k: String) -> Double? {
            if let v = j[k] as? Double { return v }
            if let v = j[k] as? Int { return Double(v) }
            return nil
        }
        func b(_ k: String) -> Bool { (j[k] as? Bool) ?? false }
        return DeepInfo(ma5: d("ma5"), ma10: d("ma10"), ma20: d("ma20"), maPass: b("ma_pass"),
                        volMult5d: d("vol_mult_5d") ?? 0, consecUp: Int(d("consec_up") ?? 0),
                        cum5d: d("cum_5d"), prev1d: d("prev_1d") ?? 0,
                        distFromLow: d("dist_from_low") ?? 0, distFromHigh: d("dist_from_high") ?? 0,
                        ma20SlopeUp: b("ma20_slope_up"), maDeviation: d("ma_deviation") ?? 0,
                        gainRatio: d("gain_ratio") ?? 0, shadowBodyRatio: d("shadow_body_ratio") ?? 0)
    }

    static func loadRows(_ db: OpaquePointer?) -> [Row] {
        let sql = """
        SELECT p.date, p.slot, p.code, p.score,
               p.price, p.change_pct, p.volume_ratio, p.turnover, p.amplitude, p.amount, p.avg_price,
               p.deep_info_json, p.score_details_json,
               o.window_profit, o.high_profit, o.close_profit, o.disc_profit,
               r.param_version
        FROM picks p
        JOIN stock_outcomes o ON o.sel_date = p.date AND o.code = p.code
        JOIN scan_rounds r    ON r.id = p.round_id
        WHERE (o.skipped IS NULL OR o.skipped = 0) AND o.close_profit IS NOT NULL
        ORDER BY p.date, p.slot, p.code
        """
        let s = prepare(db, sql)
        defer { sqlite3_finalize(s) }
        var out: [Row] = []
        while sqlite3_step(s) == SQLITE_ROW {
            guard let dj = (try? JSONSerialization.jsonObject(with: Data(txt(s, 11).utf8))) as? [String: Any]
            else { continue }
            var q = EngineQuote()
            q.code = txt(s, 2); q.price = dbl(s, 4) ?? 0; q.changePct = dbl(s, 5) ?? 0
            q.volumeRatio = dbl(s, 6) ?? 0; q.turnover = dbl(s, 7) ?? 0
            q.amplitude = dbl(s, 8) ?? 0; q.amount = dbl(s, 9) ?? 0; q.avgPrice = dbl(s, 10) ?? 0
            let sd = txt(s, 12)
            out.append(Row(date: txt(s, 0), slot: intg(s, 1), code: q.code,
                           storedScore: dbl(s, 3) ?? 0, quote: q, deep: deepFrom(dj),
                           intraday: dj["intraday"] as? [String: Any],
                           formScore: sd.contains("形态满分") ? 3 : (sd.contains("形态及格") ? 2 : 0),
                           windowProfit: dbl(s, 13), highProfit: dbl(s, 14),
                           closeProfit: dbl(s, 15), discProfit: dbl(s, 16),
                           roundParamVersion: txt(s, 17)))
        }
        return out
    }

    static func loadEnv(_ db: OpaquePointer?) -> [String: [String: Any]] {
        let s = prepare(db, "SELECT date, slot, market_env_json FROM scan_rounds "
                          + "WHERE status='ok' AND market_env_json IS NOT NULL")
        defer { sqlite3_finalize(s) }
        var out: [String: [String: Any]] = [:]
        while sqlite3_step(s) == SQLITE_ROW {
            if let e = (try? JSONSerialization.jsonObject(with: Data(txt(s, 2).utf8))) as? [String: Any] {
                out["\(txt(s, 0))#\(intg(s, 1))"] = e
            }
        }
        return out
    }

    static func loadModes(_ db: OpaquePointer?) -> [String: String] {
        let s = prepare(db, "SELECT sel_date, scan_mode FROM reviews")
        defer { sqlite3_finalize(s) }
        var out: [String: String] = [:]
        while sqlite3_step(s) == SQLITE_ROW { out[txt(s, 0)] = txt(s, 1) }
        return out
    }

    static func versionExists(_ db: OpaquePointer?, _ name: String) -> Bool {
        let s = prepare(db, "SELECT 1 FROM param_versions WHERE name=?")
        defer { sqlite3_finalize(s) }
        sqlite3_bind_text(s, 1, name, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        return sqlite3_step(s) == SQLITE_ROW
    }

    static func loadVersion(_ db: OpaquePointer?, _ name: String) -> [String: Any] {
        let s = prepare(db, "SELECT params_json FROM param_versions WHERE name=?")
        defer { sqlite3_finalize(s) }
        sqlite3_bind_text(s, 1, name, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(s) == SQLITE_ROW else { fail("库里没有版本「\(name)」") }
        guard let p = (try? JSONSerialization.jsonObject(with: Data(txt(s, 0).utf8))) as? [String: Any]
        else { fail("版本「\(name)」的 params_json 不是对象") }
        return p
    }

    // MARK: - 计算

    static func rescore(_ rows: [Row], _ P: [String: Any], _ env: [String: [String: Any]]) -> [(Row, Double)] {
        rows.map { r in
            var meta: [String: Any] = [:]
            let m = env["\(r.date)#\(r.slot)"] ?? env[r.date] ?? [:]
            let (sc, _, _) = Screener.scoreStock(quote: r.quote, deep: r.deep, intraday: r.intraday,
                                                 patterns: nil, formScore: r.formScore, marketEnv: m,
                                                 params: P, meta: &meta)
            return (r, (sc as? NSNumber)?.doubleValue ?? 0)
        }
    }

    /// 该版参数对"已评分池"额外施加的收紧条件（**取自参数本身**，不在工具里硬编码阈值）
    static func bands(_ P: [String: Any]) -> [(name: String, lo: Double, hi: Double)] {
        let pf = (P["profile_filter"] as? [String: Any]) ?? [:]
        let hf = (P["hard_filter"] as? [String: Any]) ?? [:]
        func pair(_ k: String) -> (Double, Double)? {
            guard let a = pf[k] as? [Any], a.count >= 2,
                  let lo = a[0] as? Double, let hi = a[1] as? Double else { return nil }
            return (lo, hi)
        }
        var out: [(String, Double, Double)] = []
        if let (lo, hi) = pair("volume_ratio") { out.append(("volume_ratio", lo, hi)) }
        if let (lo, hi) = pair("change_pct") { out.append(("change_pct", lo, hi)) }
        if let (lo, hi) = pair("turnover") { out.append(("turnover", lo, hi)) }
        if let pm = hf["price_min"] as? Double { out.append(("price", pm, 1e18)) }
        return out
    }

    static func bandValue(_ r: Row, _ name: String) -> Double? {
        switch name {
        case "volume_ratio": return r.quote.volumeRatio
        case "change_pct": return r.quote.changePct
        case "turnover": return r.quote.turnover
        case "price": return r.quote.price
        default: return nil
        }
    }

    static func inBands(_ r: Row, _ bd: [(name: String, lo: Double, hi: Double)]) -> Bool {
        for b in bd {
            guard let v = bandValue(r, b.name) else { return false }
            if v < b.lo || v > b.hi { return false }
        }
        return true
    }

    static func stat(_ picked: [(Row, Double)]) -> Stat {
        var s = Stat()
        for (r, _) in picked {
            s.n += 1; s.days.insert(r.date)
            // live 用窗口最高（可执行），replay 无分时 → 用全日最高（口径略宽，只作方向参照）
            if let w = r.windowProfit {
                s.hit15 += w >= 1.5 ? 1 : 0; s.hit15n += 1
                s.hit30 += w >= 3.0 ? 1 : 0; s.hit30n += 1
            } else if let h = r.highProfit {
                s.hit15 += h >= 1.5 ? 1 : 0; s.hit15n += 1
                s.hit30 += h >= 3.0 ? 1 : 0; s.hit30n += 1
            }
            if let c = r.closeProfit { s.closeWin += c > 0 ? 1 : 0; s.closeN += 1 }
            if let d = r.discProfit { s.discSum += d; s.discN += 1 }
        }
        return s
    }

    static func pct(_ a: Int, _ b: Int) -> Double { b == 0 ? .nan : Double(a) * 100.0 / Double(b) }

    static func dimValue(_ r: Row, _ which: String, _ name: String) -> Double? {
        if let v = bandValue(r, name) { return v }
        if which == "intraday" { return (r.intraday?[name] as? NSNumber)?.doubleValue }
        let j = r.deep.json
        return (j[name] as? NSNumber)?.doubleValue
    }

    // MARK: - main

    static func main() {
        let args = CommandLine.arguments
        var versions: [String] = []
        var i = 1
        while i < args.count {
            if args[i] == "--version", i + 1 < args.count { versions.append(args[i + 1]); i += 1 }
            i += 1
        }
        func val(_ f: String, _ d: String) -> String {
            guard let k = args.firstIndex(of: f), k + 1 < args.count else { return d }
            return args[k + 1]
        }
        func has(_ f: String) -> Bool { args.contains(f) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dbPath = val("--db", "\(home)/Library/Application Support/Selected/selected.sqlite3")
        let split = val("--split", "2026-06-01")
        guard !versions.isEmpty else {
            fail("用法: param_calibrate_test.sh [--db 路径] --version 名字 [--version 名字 …] "
                 + "[--fidelity] [--buckets] [--eval] [--split YYYY-MM-DD]")
        }
        let anyMode = has("--fidelity") || has("--buckets") || has("--eval")
        let db = openDB(dbPath)
        defer { sqlite3_close(db) }
        // 去重：同一 (日期, 代码) 只保留**末轮**快照 —— 14:50 那轮才是最终决策，
        // 且 `stock_outcomes` 的档位与标签本就按 (日期,代码) 唯一。不去重会把 live 的
        // 三轮各算一次，"入档/日"直接虚高约 3 倍。
        let allRows = loadRows(db)
        var latest: [String: Row] = [:]
        for r in allRows {
            let k = "\(r.date)#\(r.code)"
            if latest[k] == nil || r.slot > latest[k]!.slot { latest[k] = r }
        }
        let rows = Array(latest.values).sorted { ($0.date, $0.code) < ($1.date, $1.code) }
        let env = loadEnv(db)
        let modes = loadModes(db)
        let liveDates = Set(modes.filter { $0.value == "live" }.keys)
        print("库：\(dbPath)")
        print("样本：已评分且有次日标签 \(rows.count) 条 / \(Set(rows.map { $0.date }).count) 天"
              + "（live \(liveDates.count) 天，replay \(Set(rows.map { $0.date }).count - liveDates.count) 天；"
              + "回放训练/留出分割 = \(split)）")
        if !anyMode { print("（未指定 --fidelity/--buckets/--eval，无事可做）"); return }

        if has("--fidelity") {
            print("\n== [fidelity] 用产生该轮的那一版参数重算，必须逐条等于库里存的 score ==")
            var checked = 0, bad = 0; var worst = 0.0
            var skippedVersions = 0
            for v in Set(rows.map { $0.roundParamVersion }).sorted() where !v.isEmpty {
                let sub = rows.filter { $0.roundParamVersion == v }
                // 版本行可能已被删除（墓碑机制会永久删掉出厂备选）⇒ 无法重算，只能跳过并出声，
                // 不能拿"当前激活版"的参数去重算旧轮次 —— 那会把分叉伪装成一致。
                guard versionExists(db, v) else {
                    skippedVersions += 1
                    print("   \(v.pad(22))" + String(format: " %6d 条  跳过（版本行已删除）", sub.count))
                    continue
                }
                let P = loadVersion(db, v)
                var vb = 0
                for (r, sc) in rescore(sub, P, env) {
                    checked += 1
                    let diff = abs(sc - r.storedScore)
                    if diff > 1e-9 { vb += 1; worst = max(worst, diff) }
                }
                bad += vb
                print("   \(v.pad(22))" + String(format: " %6d 条  不一致 %d", sub.count, vb))
            }
            if bad > 0 {
                print("❌ fidelity：\(bad)/\(checked) 条重算与库存分叉（最大偏差 \(String(format: "%.4f", worst))）")
                print("   ⇒ 引擎打分口径与历史落库已不一致（改过 scoreStock / DeepInfo 语义？）—— 本工具结论不可信")
                exit(1)
            }
            if skippedVersions > 0 {
                print("   ⚠ \(skippedVersions) 个版本行已删除，其轮次未参与比对（仅能比对参数仍可取回的部分）")
            }
            print("✅ fidelity：\(checked) 条全部逐条一致")
        }

        if has("--buckets") {
            print("\n== [buckets] 双口径分桶（hit@1.5 / hit@3.0；两列方向一致才可用于标定）==")
            let dims: [(String, String, [Double])] = [
                ("volume_ratio", "quote", [0.8, 1.0, 1.2, 1.5, 1.8, 2.2, 2.8, 3.5]),
                ("change_pct", "quote", [2.5, 3.0, 3.5, 4.0, 4.5, 5.2]),
                ("turnover", "quote", [4.2, 6.0, 8.0, 10.5]),
                ("price", "quote", [3, 5, 8, 15, 30, 60, 105]),
                ("vol_mult_5d", "deep", [0.8, 1.0, 1.3, 1.8, 2.5]),
                ("cum_5d", "deep", [-8, -4, 0, 3, 8, 12, 16, 22]),
                ("dist_from_low", "deep", [5, 12, 20, 30, 45]),
                ("ma_deviation", "deep", [1, 2, 3.5, 5, 8]),
                ("prev_1d", "deep", [-5, -2, 1, 4, 7]),
                ("consec_up", "deep", [1, 2, 4, 6]),
                ("dist_from_high", "deep", [-30, -20, -12, -6, 0]),
                ("gain_ratio", "deep", [0.5, 0.7, 0.85, 1.0]),
                ("shadow_body_ratio", "deep", [0.15, 0.3, 0.5, 0.8]),
            ]
            let windows: [(String, [Row])] = [
                ("REPLAY", rows.filter { !liveDates.contains($0.date) }),
                ("LIVE", rows.filter { liveDates.contains($0.date) }),
            ]
            for (name, src, cuts) in dims {
                print("  -- \(name) --")
                let edges = [-1e18] + cuts + [1e18]
                for (w, wrows) in windows {
                    var line = "     \(w.pad(9))"
                    for i2 in 0 ..< edges.count - 1 {
                        let s = wrows.filter {
                            guard let v = dimValue($0, src, name) else { return false }
                            return v >= edges[i2] && v < edges[i2 + 1]
                        }
                        if s.count < 25 { line += "      ————  "; continue }
                        let st = stat(s.map { ($0, 0.0) })
                        line += String(format: " %5.1f%%(%d)", pct(st.hit15, st.hit15n), s.count)
                    }
                    print(line)
                }
                print(String(format: "     桶边界:%@", cuts.map { String($0) }.joined(separator: " ")))
            }
        }

        if has("--eval") {
            print("\n== [eval] 各版参数在三个窗口上的入档量与成功率 ==")
            print("   " + "版本".pad(22) + " " + "窗口".pad(13)
                  + "  入档n   入档/日   一档/日  hit@1.5  hit@3.0    收红%    disc均%")
            let wins: [(String, (Row) -> Bool)] = [
                ("replay-train", { !liveDates.contains($0.date) && $0.date < split }),
                ("replay-holdout", { !liveDates.contains($0.date) && $0.date >= split }),
                ("live", { liveDates.contains($0.date) }),
            ]
            for v in versions {
                guard versionExists(db, v) else {
                    print("   \(v.pad(22)) —— 跳过（版本行不存在）")
                    continue
                }
                let P = loadVersion(db, v)
                let bd = bands(P)
                let tiers = ((P["scoring"] as? [String: Any])?["tiers"] as? [String: Any]) ?? [:]
                let t2 = (tiers["tier2_min"] as? NSNumber)?.doubleValue ?? 50
                let t1 = (tiers["tier1_min"] as? NSNumber)?.doubleValue ?? 70
                let scored = rescore(rows, P, env)
                for (wname, pred) in wins {
                    let sub = scored.filter { pred($0.0) && inBands($0.0, bd) }
                    let ent = sub.filter { $0.1 >= t2 }
                    let one = sub.filter { $0.1 >= t1 }
                    let s = stat(ent)
                    print("   " + v.pad(22) + " " + wname.pad(13) + String(format:
                            " %6d %8.1f %8.1f %7.1f%% %7.1f%% %7.1f%% %+9.3f",
                                 s.n,
                                 Double(s.n) / Double(max(1, s.days.count)),
                                 Double(one.count) / Double(max(1, s.days.count)),
                                 pct(s.hit15, s.hit15n), pct(s.hit30, s.hit30n),
                                 pct(s.closeWin, s.closeN),
                                 s.discN == 0 ? .nan : s.discSum / Double(s.discN)))
                }
            }
            print("   注：入档=tier1+tier2；hit@3.0 对齐界面复盘的每票目标价口径；disc 仅 live 有值。")
        }
    }
}

private extension String {
    func pad(_ w: Int) -> String { count >= w ? self : self + String(repeating: " ", count: w - count) }
}
