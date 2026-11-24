import Foundation
import SQLite3

/// compare 的读库/落库层。
///
/// **职责**：
///   · 读：`scan_rounds` / `picks` / `excluded_stocks` / `etf_picks` → rounds
///   · 写：`signal_classes` + `compare_reports`
///   · 计算：由 `SignalClassifier` 负责
///
/// **为什么自己持有一个只读连接**：读操作可能来自后台任务（调度器补跑后刷新），
/// 而 UI 的 `SQLiteReader` 是**主线程专用**的共享连接（跨线程会 SIGSEGV）。
/// 独立连接 + 串行队列既安全，也让本类可独立编译测试。
///
/// 写操作走 `SQLiteWriter`。
final public class CompareStore: @unchecked Sendable {
    public static let shared = CompareStore()

    /// ⚠ 自持只读连接（**不能用 `SQLiteReader.shared`** —— 它是 `@MainActor` 的，
    ///   跨线程读会 SIGSEGV）。四件套（`READWRITE` / `PRAGMA query_only` / `busy_timeout` /
    ///   串行队列）由 `ReadOnlyConnection` **一处**保证。数据目录解析的唯一实现见 `DataDirectory.resolve()`。
    private let conn = ReadOnlyConnection(label: "CompareStore", pathProvider: DataDirectory.resolve)

    private init() {}

    // MARK: 路径

    /// 数据目录解析 —— 唯一实现见 `DataDirectory.resolve()`
    private func resolveDirUnlocked() -> String { DataDirectory.resolve() }

    private func query(_ sql: String, _ params: [Any?] = []) -> [[String: Any]] {
        conn.query(sql, params) { stmt in
            var row: [String: Any] = [:]
            for i in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, i))
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: row[name] = Int(sqlite3_column_int64(stmt, i))
                case SQLITE_FLOAT: row[name] = sqlite3_column_double(stmt, i)
                case SQLITE_TEXT:
                    row[name] = sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? ""
                case SQLITE_NULL: row[name] = NSNull()
                default: row[name] = NSNull()
                }
            }
            return row
        }
    }


    // MARK: 读：库 → rounds

    /// 最近一个有选股数据的交易日（排除今天）。
    ///
    /// 只认 `status='ok'` 的轮次；「今天」也走 `DataSources.runDate()`（fixture 回放时
    /// 用快照日期，否则回放结果会随运行日期漂移）。
    public func latestSelDate(before todayStr: String) -> String? {
        query("SELECT MAX(date) AS d FROM scan_rounds WHERE date < ? AND status='ok'", [todayStr])
            .first?["d"] as? String
    }

    /// 某日最近一轮的大盘环境（同日多轮取最新一次运行）
    public func marketEnv(date: String) -> [String: Any] {
        let rows = query("SELECT market_env_json FROM scan_rounds WHERE date=? "
                         + "ORDER BY run_time DESC LIMIT 1", [date])
        guard let s = rows.first?["market_env_json"] as? String else { return [:] }
        return (Self.jsonLoads(s) as? [String: Any]) ?? [:]
    }

    /// 某选股日的早盘预判标的
    public func predictStocks(selDate: String) -> [[String: Any]] {
        let rows = query("SELECT stocks_json FROM predicts WHERE sel_date=?", [selDate])
        guard let s = rows.first?["stocks_json"] as? String else { return [] }
        return (Self.jsonLoads(s) as? [[String: Any]]) ?? []
    }

    /// 某日各轮最新一次运行 → {slot: round}
    ///
    /// ⚠ **批量取，不做 N+1**：逐 slot 调 `loadLatestRound` 会产生 12 次 `queue.sync`
    ///   串行往返（每 slot 4 条 SQL）。这里 **4 条 SQL 一次取回**：`scan_rounds` 一条 +
    ///   三张子表各一条（用 `IN (…)`）。数据量小不是瓶颈 —— 这样做是为了
    ///   **别让"进一次三轮对比"随 slot 数线性增长**。
    /// ⚠ 口径与 `loadLatestRound` **必须一致**：同 slot 多次运行取 `run_time` 最新那一次。
    public func loadRounds(date: String) -> [Int: [String: Any]] {
        let slots = RoundPlan.slots

        let marks = Array(repeating: "?", count: slots.count).joined(separator: ",")
        var roundParams: [Any?] = [date as Any?]
        roundParams.append(contentsOf: slots.map { $0 as Any? })
        // ① 一条取回三个 slot 的**全部**轮次，按 run_time DESC → 每个 slot 的第一条就是最新
        let roundRows = query("SELECT * FROM scan_rounds WHERE date=? AND slot IN (\(marks))"
                              + " ORDER BY run_time DESC", roundParams)
        var bySlot: [Int: [String: Any]] = [:]
        for row in roundRows {
            guard let s = Self.intOf(row["slot"]) else { continue }
            if bySlot[s] == nil { bySlot[s] = row }
        }
        guard !bySlot.isEmpty else { return [:] }

        // ② 三张子表各一条；`excluded_stocks` 额外取 `round_id`（分组需要）
        let ids = bySlot.values.compactMap { Self.intOf($0["id"]) }
        let idMarks = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let idParams = ids.map { $0 as Any? }
        let picks = query("SELECT * FROM picks WHERE round_id IN (\(idMarks))"
                          + " ORDER BY score DESC", idParams)
        let excluded = query("SELECT code, name, reason, round_id FROM excluded_stocks"
                             + " WHERE round_id IN (\(idMarks))", idParams)
        let etfs = query("SELECT * FROM etf_picks WHERE round_id IN (\(idMarks))"
                         + " ORDER BY change_pct DESC", idParams)
        func grouped(_ rows: [[String: Any]]) -> [Int: [[String: Any]]] {
            var out: [Int: [[String: Any]]] = [:]
            for r in rows {
                guard let k = Self.intOf(r["round_id"]) else { continue }
                out[k, default: []].append(r)
            }
            return out
        }
        let picksBy = grouped(picks), excludedBy = grouped(excluded), etfsBy = grouped(etfs)

        var rounds: [Int: [String: Any]] = [:]
        for (slot, row) in bySlot {
            guard let id = Self.intOf(row["id"]) else { continue }
            rounds[slot] = Self.buildRound(
                roundRow: row,
                picks: picksBy[id] ?? [],
                excluded: excludedBy[id] ?? [],
                etfs: etfsBy[id] ?? [],
                resultJSON: Self.jsonLoads(row["result_json"] as? String) as? [String: Any] ?? [:])
        }
        return rounds
    }

    /// 某日某轮最新一次运行（同 slot 多次运行取最新）
    public func loadLatestRound(date: String, slot: Int) -> [String: Any]? {
        let rows = query("SELECT * FROM scan_rounds WHERE date=? AND slot=? ORDER BY run_time DESC LIMIT 1",
                         [date, slot])
        guard let row = rows.first else { return nil }
        let roundID = Self.intOf(row["id"])
        let picks = query("SELECT * FROM picks WHERE round_id=? ORDER BY score DESC", [roundID])
        let excluded = query("SELECT code, name, reason FROM excluded_stocks WHERE round_id=?", [roundID])
        let etfs = query("SELECT * FROM etf_picks WHERE round_id=? ORDER BY change_pct DESC", [roundID])
        let resultJSON = Self.jsonLoads(row["result_json"] as? String) as? [String: Any] ?? [:]
        return Self.buildRound(roundRow: row, picks: picks, excluded: excluded,
                               etfs: etfs, resultJSON: resultJSON)
    }

    /// 纯解析（可独立测试）：四张表的行 → round dict
    public static func buildRound(roundRow: [String: Any], picks: [[String: Any]],
                           excluded: [[String: Any]], etfs: [[String: Any]],
                           resultJSON: [String: Any]) -> [String: Any] {
        func num(_ v: Any?) -> Any { v ?? NSNull() }
        var stats: [String: Any] = [:]
        for k in ["total_scanned", "after_hard_filter", "after_profile_filter",
                  "after_form_filter", "excluded_count", "final_count",
                  "tier1_count", "tier2_count"] {
            stats[k] = num(roundRow[k])
        }
        return [
            "round_id": num(roundRow["id"]),
            "date": num(roundRow["date"]),
            "slot": num(roundRow["slot"]),
            "slot_label": num(roundRow["slot_label"]),
            "run_time": num(roundRow["run_time"]),
            "param_version": num(roundRow["param_version"]),
            "market_env": jsonLoads(roundRow["market_env_json"] as? String) ?? NSNull(),
            "stats": stats,
            "tier1": picks.filter { intOf($0["tier"]) == 1 }.map(pickToDict),
            "tier2": picks.filter { intOf($0["tier"]) == 2 }.map(pickToDict),
            "tier3": picks.filter { intOf($0["tier"]) == 3 }.map(pickToDict),
            "excluded_deep_trend": excluded.map { ["code": num($0["code"]),
                                                   "name": num($0["name"]),
                                                   "reason": num($0["reason"])] },
            "etf_recommendations": etfs,
            // 预算截断信息（老数据无此键 → 默认值，行为不变）
            "budget_limited": (resultJSON["budget_limited"] as? Bool) ?? false,
            "budget_skipped_codes": (resultJSON["budget_skipped_codes"] as? [String]) ?? [],
        ]
    }

    /// pick 行 → 对比报告消费的 dict
    public static func pickToDict(_ p: [String: Any]) -> [String: Any] {
        func col(_ name: String, _ fallback: Any) -> Any {
            if let v = p[name], !(v is NSNull) { return v }
            return fallback
        }
        let score = p["score"] ?? 0
        return [
            "code": col("code", ""), "name": col("name", ""),
            "tier": col("tier", 0), "score": score,
            // 均线锁档的原始分与资格（老数据无此列 → 回落为 score / true）
            "score_raw": col("score_raw", score),
            "ma_qualified": (intOf(p["ma_qualified"]) ?? 1) != 0,
            "tier_lock_applied": (intOf(p["tier_lock_applied"]) ?? 0) != 0,
            "price": col("price", 0), "change_pct": col("change_pct", 0),
            "volume_ratio": col("volume_ratio", 0), "turnover": col("turnover", 0),
            "amplitude": col("amplitude", 0), "amount": col("amount", 0),
            "avg_price": col("avg_price", 0),
            "deep_info": jsonLoads(p["deep_info_json"] as? String) ?? NSNull(),
            "score_details": jsonLoads(p["score_details_json"] as? String) ?? [],
            "penalty_details": jsonLoads(p["penalty_details_json"] as? String) ?? [],
            "market_weak": (intOf(p["market_weak"]) ?? 0) != 0,
        ]
    }

    // MARK: 一轮完整对比（读库 → 计算 → 落库）

    /// Store 的手动触发与调度器定时任务**共用这一份实现** ——
    /// 两份实现必然漂移出「手动能看到对比、调度到的没落库」这类故障。
    ///
    /// 无轮次数据时 `report["status"] == "no_data"` 且**不落库**。
    @discardableResult
    public static func runOnce(date: String, shouldStop: () -> Bool = { false }) throws -> [String: Any] {
        let rounds = CompareStore.shared.loadRounds(date: date)
        let report = SignalClassifier.compare(rounds, date: date)
        if (report["status"] as? String) != "no_data" {
            // 取消检查（审查 #12）：计算是毫秒级，唯一有价值的检查点是"退出后不再落库"
            if shouldStop() {
                return ["status": "cancelled", "date": date, "summary": "对比被取消（未落库）"]
            }
            try CompareStore.shared.persist(date: date, report: report)
        }
        return report
    }

    // MARK: 写：report → 库

    /// 落库 signal_classes + compare_reports。
    ///
    /// signals 取自 report["signals"]（SignalClassifier.compare 已按引擎口径生成）。
    @discardableResult
    public func persist(date: String, report: [String: Any]) throws -> Int {
        let signals = (report["signals"] as? [String: Any]) ?? [:]
        let reportJSON = try Self.encodeJSON(report)
        let updatedAt = Self.nowISO()
        return try SQLiteWriter.shared.write { tx in
            // 先清掉该日**已不在本次结果里**的旧行。
            // `signal_classes` 是"按日全量重算"的派生表：改参数后重算、或三轮补齐后重算时，
            // 若只 `INSERT OR REPLACE`，上一轮存在、这一轮消失的代码会**留在库里** ——
            // `SQLiteReader.signals(date:)` 与 tuner 标签都会读到幽灵行，
            // 表现为"某只票在对比段还在，但本轮其实没入档"。
            // 实现用「读现有 → 求差集 → 逐条删」而不是 `NOT IN (?,?,…)`：
            // 后者在代码数超过 SQLite 的绑定参数上限（默认 999）时会直接失败。
            let keep = Set(signals.keys)
            // ⚠ 读失败**必须抛出**：把"读失败"当成"没有幽灵行"，本段要消灭的那个故障
            //   （改参数重算后旧票留在库里）会**完整复现**，且无任何报错。
            //   ⇒ 读失败抛出，不回落空集合。
            let existing = try tx.query("SELECT code FROM signal_classes WHERE date=?", [date])
            let staleRows: [[Any?]] = existing.compactMap { row in
                guard let c = row["code"] as? String, !keep.contains(c) else { return nil }
                return [date, c]
            }
            try tx.executeBatch("DELETE FROM signal_classes WHERE date=? AND code=?", rows: staleRows)
            let signalRows: [[Any?]] = try signals.compactMap { (code, metaAny) in
                guard let meta = metaAny as? [String: Any] else { return nil }
                let scoresJSON = try Self.encodeJSON(meta["scores"] ?? [String: Any]())
                return [date, code, (meta["name"] as? String) ?? "",
                        (meta["signal_type"] as? String) ?? "", scoresJSON,
                        (meta["trend"] as? String) ?? ""]
            }
            try tx.executeBatch(
                "INSERT OR REPLACE INTO signal_classes(date, code, name, signal_type, scores_json, trend) "
                + "VALUES(?,?,?,?,?,?)",
                rows: signalRows)
            let n = signalRows.count
            try tx.execute(
                "INSERT OR REPLACE INTO compare_reports(date, json, updated_at) VALUES(?,?,?)",
                [date, reportJSON, updatedAt])
            return n
        }
    }

    /// JSON 编码（中文不转义，ensure_ascii=False 语义）
    public static func encodeJSON(_ obj: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: obj, options: [])
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// 写库时刻 `yyyy-MM-dd'T'HH:mm:ss`（**北京时间**，统一走 `ChinaTime`）。
    ///
    /// ⚠ 库里历史行曾按本机本地时间写入；换时区的设备上新旧行会混用。
    public static func nowISO() -> String {
        ChinaTime.formatter("yyyy-MM-dd'T'HH:mm:ss").string(from: Date())
    }

    // MARK: 工具

    public static func jsonLoads(_ s: String?) -> Any? {
        guard let s = s, !s.isEmpty, let d = s.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: d)
    }

    /// 转发 `Num.intOrNil`（Any? → Int?，全项目同一语义）。
    public static func intOf(_ v: Any?) -> Int? { Num.intOrNil(v) }

    public func close() {
        conn.close()
    }
}
