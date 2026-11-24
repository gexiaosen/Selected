import Foundation

/// 扫描轮次落库。
///
/// **职责**：把 `ScanRunner` 产出的整轮结果写进四张表
/// （scan_rounds / picks / excluded_stocks / etf_picks），写操作走 `SQLiteWriter`。
///
/// **同 (date, slot) 幂等**：语义是「同 slot 多次运行取最新」（读取方按 run_time DESC 取），
/// 若只追加不清理 —— 手动扫描与调度器撞车、或调度器重试时会留下同一轮的多条记录与多份
/// picks，污染任何「按轮次计数」的统计。因此每次落库前先删掉该 (date, slot) 的旧轮次
/// （子表按 round_id 先删）。
final public class ScanStore: @unchecked Sendable {
    public static let shared = ScanStore()

    private init() {}

    /// 落库一轮扫描，返回 round_id。
    /// 失败会抛错 —— 写不进去必须让调用方看见（不得静默当成"落过了"）。
    @discardableResult
    public func persistRound(_ result: [String: Any]) throws -> Int {
        // 字段读取全部走 `ScanResult` 实体：散着的 `Self.str(p["code"])` 式读法，
        // 键名写错只会**安静地拿到默认值**；实体的 `declaredKeys` 由 `ScanEntityTests`
        // 对着黄金夹具逐键校验，键名不可能错。
        let r = ScanResult(JSONValue(result))
        let date = r.date
        let slot = r.slot
        let stats = r.stats

        return try SQLiteWriter.shared.write { tx in
            // 先删同轮旧记录（子表按 round_id 关联，先删子表）
            let old = try tx.query("SELECT id FROM scan_rounds WHERE date=? AND slot=?",
                                   [date, slot])
            let oldIds: [[Any?]] = old.map { [($0["id"] as? NSNumber)?.intValue ?? 0] }
            if !oldIds.isEmpty {
                // 固定三条（不拼表名，保持「全参数化 SQL」约定）
                try tx.executeBatch("DELETE FROM picks WHERE round_id=?", rows: oldIds)
                try tx.executeBatch("DELETE FROM excluded_stocks WHERE round_id=?", rows: oldIds)
                try tx.executeBatch("DELETE FROM etf_picks WHERE round_id=?", rows: oldIds)
                try tx.execute("DELETE FROM scan_rounds WHERE date=? AND slot=?", [date, slot])
            }

            try tx.execute(
                "INSERT INTO scan_rounds(date, slot, slot_label, run_time, screener_version, param_version, "
                + "total_scanned, after_hard_filter, after_profile_filter, after_form_filter, "
                + "excluded_count, final_count, tier1_count, tier2_count, market_env_json, result_json, status) "
                + "VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                [date, slot, r.slotLabel, r.runTime, r.screenerVersion, r.paramVersion,
                 stats.totalScanned, stats.afterHardFilter,
                 stats.afterProfileFilter, stats.afterFormFilter,
                 stats.excludedCount, stats.finalCount,
                 stats.tier1Count, stats.tier2Count,
                 PyJSON.encode(r.marketEnv.json.raw),
                 PyJSON.encode(r.slimJSON.raw),
                 r.status])
            let roundID = Int(tx.lastInsertRowID)

            var pickRows: [[Any?]] = []
            for (tierNum, group) in [(1, r.tier1), (2, r.tier2), (3, r.tier3)] {
                for p in group {
                    pickRows.append([
                        roundID, date, slot, p.code, p.name, tierNum,
                        p.score, p.scoreRaw,
                        p.maQualified ? 1 : 0, p.tierLockApplied ? 1 : 0,
                        p.price, p.changePct, p.volumeRatio,
                        p.turnover, p.amplitude, p.amount, p.avgPrice,
                        PyJSON.encode(p.deepInfo.json.raw),
                        PyJSON.encode(p.json.rawArray("score_details")),
                        PyJSON.encode(p.json.rawArray("penalty_details")),
                        p.marketWeak ? 1 : 0,
                    ])
                }
            }
            try tx.executeBatch(
                "INSERT INTO picks(round_id, date, slot, code, name, tier, score, "
                + "score_raw, ma_qualified, tier_lock_applied, price, change_pct, "
                + "volume_ratio, turnover, amplitude, amount, avg_price, "
                + "deep_info_json, score_details_json, penalty_details_json, market_weak) "
                + "VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                rows: pickRows)

            let excludedRows: [[Any?]] = r.excludedDeepTrend.map { e in
                [roundID, date, slot, e.code, e.name, e.reason]
            }
            try tx.executeBatch(
                "INSERT INTO excluded_stocks(round_id, date, slot, code, name, reason) VALUES(?,?,?,?,?,?)",
                rows: excludedRows)

            let etfRows: [[Any?]] = r.etfRecommendations.map { e in
                [roundID, date, slot, e.code, e.name, e.price,
                 e.changePct, e.volumeRatio, e.turnover, e.amount]
            }
            try tx.executeBatch(
                "INSERT INTO etf_picks(round_id, date, slot, code, name, price, change_pct, "
                + "volume_ratio, turnover, amount) VALUES(?,?,?,?,?,?,?,?,?,?)",
                rows: etfRows)
            return roundID
        }
    }

    /// 落库的 result_json 精简版：只留统计与环境，明细走 picks 表。
    /// 实现在 `ScanResult.slimJSON`（实体侧），这里保留薄壳以兼容调用方
    /// （逐键等价性由 `ScanEntityTests` 断言）。
    public static func slimResult(_ result: [String: Any]) -> [String: Any] {
        (ScanResult(JSONValue(result)).slimJSON.raw as? [String: Any]) ?? [:]
    }

    // MARK: - 取值工具（类型安全转换）
    //
    // `persistRound` 已全走 `ScanResult` 实体，下面只剩 `slimResult` 兼容壳在用。
    // 保留是因为 `slimResult` 是 public API（`CompareStore` 等可能调用）。

    private static func dict(_ v: Any?) -> [String: Any] { (v as? [String: Any]) ?? [:] }
    private static func rows(_ v: Any?) -> [[String: Any]] { (v as? [[String: Any]]) ?? [] }
    private static func str(_ v: Any?, _ def: String = "") -> String { (v as? String) ?? def }
    private static func int(_ v: Any?) -> Int {
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String { return Int(s) ?? 0 }
        return 0
    }
    private static func bool(_ v: Any?, _ def: Bool) -> Bool {
        if let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
        if let b = v as? Bool { return b }
        return def
    }
    /// NSNull / nil → NSNull（JSON 编码需要显式 null，不能用 Optional.none 造成 encode 崩溃）
    private static func nonNull(_ v: Any?) -> Any { v ?? NSNull() }
}