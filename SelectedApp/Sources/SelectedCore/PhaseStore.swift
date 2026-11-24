import Foundation
import SQLite3

/// 四阶段报告落库 —— `predict` / `verify` / `review` / `iterate` 四张表的读写。
///
/// **为什么单独一个 Store**：这四张表的生命周期与 `CompareStore`（扫描轮次/对比报告）
/// 不同 —— 它们按 `sel_date` 覆盖写、由四个独立阶段各自产出，且 `iterate_reports` 是
/// 自增主键 + 跨日触发。混进 CompareStore 会让"谁写哪张表"变得模糊。
///
/// 读走本类自带的 `query_only` 连接（阶段计算跑在**后台线程**，不能用主线程专用的
/// `SQLiteReader`；与 CompareStore / ParamStore / WatchStore 同一套模式 —— 四处同构
/// 是有意的：连接的生命周期与锁策略必须逐字相同，抽公共基类更容易在并发上出错）。
/// 写一律走 `SQLiteWriter`。
final public class PhaseStore: @unchecked Sendable {
    public static let shared = PhaseStore()

    /// ⚠ 自持只读连接（**不能用 `SQLiteReader.shared`** —— 它是 `@MainActor` 的，
    ///   跨线程读会 SIGSEGV）。四件套（`READWRITE` / `PRAGMA query_only` / `busy_timeout` /
    ///   串行队列）由 `ReadOnlyConnection` **一处**保证。
    ///   数据目录解析的唯一实现见 `DataDirectory.resolve()`。
    private let conn = ReadOnlyConnection(label: "PhaseStore", pathProvider: DataDirectory.resolve)

    private init() {}

    // MARK: - 只读连接

    public func query(_ sql: String, _ params: [Any?] = []) -> [[String: Any]] {
        conn.query(sql, params) { stmt in
            var row: [String: Any] = [:]
            for i in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, i))
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: row[name] = Int(sqlite3_column_int64(stmt, i))
                case SQLITE_FLOAT: row[name] = sqlite3_column_double(stmt, i)
                case SQLITE_TEXT:
                    row[name] = sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? ""
                default: row[name] = NSNull()
                }
            }
            return row
        }
    }


    /// 数据目录（与各 Store 同一套解析规则）—— 供自检报告输出 `db_path` 等用途。
    /// 不打开数据库，只解析路径（自检可能在库不可用时被调用）。
    /// 不缓存结果：`DataDirectory.resolve()` 就是唯一解析实现、成本可忽略。
    public var dataDirPath: String { DataDirectory.resolve() }

    public func close() {
        conn.close()
    }

    private func write<T>(_ body: (WriteTx) throws -> T) throws -> T {
        try SQLiteWriter.shared.write(body)
    }

    // ⚠ 下面三个写库时刻函数统一走 `ChinaTime`（全项目唯一出口，已钉死
    //   `Asia/Shanghai` + `en_US_POSIX`），与同一条写库链路上的 `ScanRunner` 一致 ——
    //   否则非上海时区设备上两者相差数小时（跨零点还会差一天），且不报错。
    // ⚠ 换过时区的设备上，历史行（本地时间写的）与新行（北京时间）会混用 ——
    //   不可回填，按「已知不足」接受。

    /// 写库时刻 `yyyy-MM-dd'T'HH:mm:ss`（**北京时间**）
    public static func nowISO() -> String {
        ChinaTime.formatter("yyyy-MM-dd'T'HH:mm:ss").string(from: Date())
    }

    /// `HH:mm`（**北京时间**）
    public static func nowHM() -> String {
        ChinaTime.formatter("HH:mm").string(from: Date())
    }

    /// `yyyy-MM-dd HH:mm:ss`（**北京时间**）
    public static func nowStamp() -> String {
        ChinaTime.formatter("yyyy-MM-dd HH:mm:ss").string(from: Date())
    }

    // MARK: - predicts（阶段一 早盘预判）

    public func persistPredict(date: String, selDate: String, predictTime: String,
                        marketEnv: [String: Any], stocks: [[String: Any]],
                        isEmptyDay: Bool, overall: [Any]) throws {
        let envJSON = PyJSON.encode(marketEnv)
        let stocksJSON = PyJSON.encode(stocks)
        let overallJSON = PyJSON.encode(overall)
        let updated = Self.nowISO()
        let empty = isEmptyDay ? 1 : 0
        _ = try write { tx in
            try tx.execute(
                "INSERT OR REPLACE INTO predicts(date, sel_date, predict_time, market_env_json,"
                + " stocks_json, is_empty_day, overall_json, report_md, updated_at)"
                + " VALUES(?,?,?,?,?,?,?,?,?)",
                [date, selDate, predictTime, envJSON, stocksJSON, empty, overallJSON, "", updated])
        }
    }

    // MARK: - verifies（阶段二 盘中验证）

    public func persistVerify(selDate: String, verifyTime: String, stats: [String: Any],
                       detail: [[String: Any]], deviations: [[String: Any]],
                       warnings: [String], isEmptyDay: Bool) throws {
        let updated = Self.nowISO()
        let empty = isEmptyDay ? 1 : 0
        _ = try write { tx in
            try tx.execute(
                "INSERT OR REPLACE INTO verifies(sel_date, verify_time, stats_json, detail_json,"
                + " deviation_json, warnings_json, is_empty_day, updated_at) VALUES(?,?,?,?,?,?,?,?)",
                [selDate, verifyTime, PyJSON.encode(stats), PyJSON.encode(detail),
                 PyJSON.encode(deviations), PyJSON.encode(warnings), empty, updated])
        }
    }

    // MARK: - reviews（阶段三 收盘复盘）

    /// `insights` 是**数组**、`reference` 可为 null —— 不要包成 `{"lines": …}`，
    /// 那会让复盘页读不出洞察。
    public func persistReview(selDate: String, reviewTime: String, fourLayer: [String: Any],
                       accuracy: [String: Any], stocks: [[String: Any]],
                       isEmptyDay: Bool, insights: [Any], reference: Any) throws {
        let updated = Self.nowISO()
        let empty = isEmptyDay ? 1 : 0
        _ = try write { tx in
            try tx.execute(
                "INSERT OR REPLACE INTO reviews(sel_date, review_time, four_layer_json,"
                + " accuracy_json, stocks_json, is_empty_day, report_md, insights_json,"
                + " reference_json, updated_at) VALUES(?,?,?,?,?,?,?,?,?,?)",
                [selDate, reviewTime, PyJSON.encode(fourLayer), PyJSON.encode(accuracy),
                 PyJSON.encode(stocks), empty, "", PyJSON.encode(insights),
                 PyJSON.encode(reference), updated])
        }
    }

    // MARK: - 复盘的选股口径标记

    /// 给某日的复盘打上**选股轮次的价格口径**标记（`reviews.scan_mode`）。
    ///
    /// 取值：`HistoryReplayJob.scanModeLive`（`"live"`，DEFAULT）/
    /// `HistoryReplayJob.scanModeReplay`（`"replay_close"`）。
    ///
    /// **为什么是插入之后的 UPDATE，而不是往 `persistReview` 的 INSERT 里加一列**：
    /// 走 DEFAULT + 事后 UPDATE，完全不动那条 INSERT 语句。
    ///
    /// ⚠ 与结果 JSON 里的 `data_mode`（`PhaseReview.swift` 的 `"replay_daily_kline"`）
    /// **语义不同、不可互相替代**：`data_mode` 说的是"这次复盘的**目标日**行情是不是实时取的"，
    /// `scan_mode` 说的是"这个**选股日**的选股轮次是什么价格口径"。
    /// 一次真实的 T+1 复盘在补跑时会是 `data_mode=replay_daily_kline` 而 `scan_mode=live`。
    @discardableResult
    public func markReviewScanMode(selDate: String, mode: String) throws -> Int {
        guard !selDate.isEmpty, !mode.isEmpty else { return 0 }
        return try write { tx in
            try tx.execute("UPDATE reviews SET scan_mode=? WHERE sel_date=?", [mode, selDate])
        }
    }

    /// 读某日复盘的选股口径标记。行不存在 → `nil`；列缺失（未迁移）→ `nil`。
    public func reviewScanMode(selDate: String) -> String? {
        guard !selDate.isEmpty else { return nil }
        return query("SELECT scan_mode FROM reviews WHERE sel_date=? LIMIT 1", [selDate])
            .first?["scan_mode"] as? String
    }

    // MARK: - iterate_reports（阶段四 三天迭代）

    /// 迭代报告按 `trigger_date` 覆盖写（`trigger_date` 是 UNIQUE 列）。
    /// `emptyTrend` / `fourLayerAvg` 可为 null。
    public func persistIterate(triggerDate: String, isEmptyDayReport: Bool, counter: Int,
                        insights: [Any], emptyTrend: Any, fourLayerAvg: [String: Any]) throws {
        let created = Self.nowStamp()
        let empty = isEmptyDayReport ? 1 : 0
        _ = try write { tx in
            try tx.execute(
                "INSERT OR REPLACE INTO iterate_reports(trigger_date, is_empty_day_report, counter,"
                + " insights_json, empty_trend_json, four_layer_avg_json, report_md, created_at)"
                + " VALUES(?,?,?,?,?,?,?,?)",
                [triggerDate, empty, counter, PyJSON.encode(insights),
                 PyJSON.encode(emptyTrend), PyJSON.encode(fourLayerAvg), "", created])
        }
    }

    // MARK: - 复盘所需的读

    /// 当日**全部已评分标的**（含三档）→ [(code, name, tier, selPrice)]
    ///
    /// tier 取各轮中的**最好**档位；selPrice 取**最晚一轮**的价格 —— 对齐「尾盘 14:50
    /// 那一轮买入」的真实动作。
    ///
    /// 含三档是为了让「被当前参数判为三档的标的」也能进入评估 —— 只取 tier1/2
    /// 会造成 tuner 的幸存者偏差。
    ///
    /// ⚠ 返回顺序按**首次出现顺序**（`ORDER BY slot ASC` 下的 dict 插入序）。
    public func scoredPicks(date: String) -> [[String: Any]] {
        let rows = query("SELECT slot, code, name, tier, price FROM picks WHERE date=? ORDER BY slot ASC",
                         [date])
        var order: [String] = []
        var agg: [String: [String: Any]] = [:]
        for r in rows {
            guard let code = r["code"] as? String else { continue }
            let tier = Self.intOf(r["tier"]) ?? 0
            let price = PredictRules.num(r["price"]) ?? 0
            if let cur = agg[code] {
                agg[code] = ["code": code, "name": r["name"] ?? cur["name"] ?? "",
                             "tier": min(Self.intOf(cur["tier"]) ?? tier, tier),
                             "sel_price": price]     // 后面的 slot 覆盖前面的 → 留下最晚一轮
            } else {
                order.append(code)
                agg[code] = ["code": code, "name": r["name"] ?? "",
                             "tier": tier, "sel_price": price]
            }
        }
        return order.compactMap { agg[$0] }
    }

    /// 预判行（最新一条，JSON 列已解析）
    public func predictRow(selDate: String?) -> [String: Any]? {
        let row: [String: Any]?
        if let d = selDate {
            row = query("SELECT * FROM predicts WHERE sel_date=? ORDER BY date DESC LIMIT 1", [d]).first
        } else {
            row = query("SELECT * FROM predicts WHERE sel_date="
                        + "(SELECT MAX(sel_date) FROM predicts) ORDER BY date DESC LIMIT 1").first
        }
        guard let r = row else { return nil }
        return [
            "date": r["date"] ?? "",
            "sel_date": r["sel_date"] ?? "",
            "market_env": (Self.jsonLoads(r["market_env_json"] as? String) as? [String: Any]) ?? [:],
            "stocks": (Self.jsonLoads(r["stocks_json"] as? String) as? [[String: Any]]) ?? [],
            "is_empty_day": Self.boolOf(r["is_empty_day"]),
        ]
    }

    // MARK: - stock_outcomes（次日结果台账）

    /// 落库全量已评分标的的次日结果。
    ///
    /// ⚠ **不用 `INSERT OR REPLACE`**：整行替换会让「同一天重跑复盘」把已有值抹成 NULL ——
    ///   replay 路径（目标日 ≠ 运行日）下 `disc_* / window_profit` 取不到、写 NSNull，
    ///   T+1 当天已算好的 L3 纪律标签就被 NULL 覆盖，而 tuner 正是吃这张表调参。
    ///   用 UPSERT + `COALESCE(excluded.x, 旧值)`：**本次为 NULL 时保留库中已有值**，
    ///   本次有值时正常更新。
    ///   `skipped / updated_at` 始终取本次值 —— 它们是运行态元数据，不参与"测量值不能丢"的约束。
    public func persistOutcomes(selDate: String, rows: [[String: Any]]) throws {
        let now = Self.nowISO()
        // 会被 replay 置空的测量列：NULL 不得覆盖旧值
        let coalesced = ["name", "tier", "open_pct", "disc_profit", "disc_win", "disc_hit",
                         "disc_hit_time", "window_profit", "close_profit", "high_profit",
                         "target_pct", "window_start", "window_end",
                         // T+3/T+5 的**基准价**：必须同列落库 —— 若两天后再从 `picks` 反推，
                         // 一旦 picks 被事后补写就会与 `close_profit` 用上不同基准，
                         // 三个窗不再可比（而且界面上三个数看着都正常）。
                         "sel_price"]
        let setClause = coalesced
            .map { "\($0) = COALESCE(excluded.\($0), stock_outcomes.\($0))" }
            .joined(separator: ", ")
        let batch: [[Any?]] = rows.map { r in
            [selDate, r["code"] ?? NSNull(), r["name"] ?? NSNull(), r["tier"] ?? NSNull(),
             r["open_pct"] ?? NSNull(), r["disc_profit"] ?? NSNull(),
             r["disc_win"] ?? NSNull(), r["disc_hit"] ?? NSNull(),
             r["disc_hit_time"] ?? NSNull(), r["window_profit"] ?? NSNull(),
             r["close_profit"] ?? NSNull(), r["high_profit"] ?? NSNull(),
             r["target_pct"] ?? NSNull(), r["window_start"] ?? NSNull(),
             r["window_end"] ?? NSNull(),
             PredictRules.truthy(r["skipped"]) ? 1 : 0, now,   // ⚠ 不能用 bool()：Int 1 会静默变 false
             r["sel_price"] ?? NSNull()]
        }
        _ = try write { tx in
            try tx.executeBatch(
                "INSERT INTO stock_outcomes("
                + "sel_date, code, name, tier, open_pct, disc_profit, disc_win, disc_hit,"
                + " disc_hit_time, window_profit, close_profit, high_profit,"
                + " target_pct, window_start, window_end, skipped, updated_at, sel_price)"
                + " VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)"
                + " ON CONFLICT(sel_date, code) DO UPDATE SET \(setClause),"
                + " skipped = excluded.skipped, updated_at = excluded.updated_at",
                rows: batch)
        }
    }

    /// 复盘准确度追踪行（写 `data_source_logs`）
    public func appendAccuracyTrack(detail: [String: Any]) throws {
        let ts = Self.nowISO()
        try write { tx in
            _ = try tx.execute(
                "INSERT INTO data_source_logs(ts, source, event, detail) VALUES(?, 'review', 'accuracy_track', ?)",
                [ts, PyJSON.encode(detail)])
        }
    }

    // MARK: - 多观察窗回填

    /// `stock_outcomes` 的一行「观察窗原料」。
    ///
    /// ⚠ `selPrice` 可空：`sel_price` 列加入之前的存量行没有值。
    /// 那种行算不了 T+3/T+5（没有基准价）→ 由回填器计入 `skippedNoBase` 并跳过，不猜。
    public struct OutcomeWindowRow: Sendable {
        public let selDate: String
        public let code: String
        public let selPrice: Double?
        public let t3: Double?
        public let t5: Double?

        /// 该窗当前已落库的值（`nil` = 待补）
        public func value(for window: OutcomeWindow) -> Double? {
            switch window {
            case .t3: return t3
            case .t5: return t5
            }
        }
    }

    /// 取出**窗口内**仍缺至少一个观察窗的行。
    ///
    /// ⚠ `skipped = 0`：红灯日空仓的标的不参与统计（与 `PhaseTune.actualMapFor` 同口径）。
    /// ⚠ `sel_date >= since`：有界 —— 更早的历史行由「历史日期批量重跑」负责，
    ///   混进来会让请求量随库龄线性增长。
    /// ⚠ 不过滤"到期"：那是纯日历逻辑，属 `OutcomeWindowBackfill.plan`，这里只做 SQL 能做的部分。
    public func outcomeWindowRows(since selDate: String) -> [OutcomeWindowRow] {
        let rows = query(
            "SELECT sel_date, code, sel_price, t3_close_pct, t5_close_pct"
            + " FROM stock_outcomes"
            + " WHERE skipped = 0 AND sel_date >= ?"
            + "   AND (t3_close_pct IS NULL OR t5_close_pct IS NULL)"
            + " ORDER BY sel_date ASC, code ASC", [selDate])
        return rows.map {
            OutcomeWindowRow(selDate: ($0["sel_date"] as? String) ?? "",
                             code: ($0["code"] as? String) ?? "",
                             selPrice: PredictRules.num($0["sel_price"]),
                             t3: PredictRules.num($0["t3_close_pct"]),
                             t5: PredictRules.num($0["t5_close_pct"]))
        }
    }

    /// 落库一批观察窗值。**只写 NULL**。
    ///
    /// ⚠ `AND <col> IS NULL` 写进 SQL 而不是在 Swift 里判：并发/重入下也不会覆盖已有值。
    ///   已算出的值**永不重算** —— 否则历史标签会随数据源事后修正而漂移，
    ///   同一行两次读到的数不同，"多观察窗"就失去了可比性。
    /// ⚠ 一次事务：部分成功会让"补到一半"这种状态难以解释。
    public func fillOutcomeWindows(_ fills: [(selDate: String, code: String,
                                              window: OutcomeWindow, pct: Double)]) throws {
        guard !fills.isEmpty else { return }
        try write { tx in
            for window in OutcomeWindow.allCases {
                let batch: [[Any?]] = fills
                    .filter { $0.window == window }
                    .map { [$0.pct, $0.selDate, $0.code] }
                try tx.executeBatch(
                    "UPDATE stock_outcomes SET \(window.column) = ?"
                    + " WHERE sel_date = ? AND code = ? AND \(window.column) IS NULL",
                    rows: batch)
            }
        }
    }

    // MARK: - 类型工具（DB 列 → Swift 类型）

    public static func intOf(_ v: Any?) -> Int? {
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String { return Int(s) }
        return nil
    }

    public static func boolOf(_ v: Any?) -> Bool {
        if let n = v as? NSNumber { return n.intValue != 0 }
        if let s = v as? String { return Int(s) == 1 || s.lowercased() == "true" }
        return false
    }

    public static func jsonLoads(_ s: String?) -> Any? {
        guard let s = s, let d = s.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: d)
    }

    /// 迭代计数器（缺行或非数字时给 0）
    public func counter(_ key: String) -> Int {
        let rows = query("SELECT value FROM counters WHERE key=?", [key])
        guard let s = rows.first?["value"] as? String, let v = Int(s) else { return 0 }
        return v
    }

    public func setCounter(_ key: String, _ value: Int) throws {
        _ = try write { tx in
            _ = try tx.execute("INSERT OR REPLACE INTO counters(key, value) VALUES(?, ?)",
                               [key, String(value)])
        }
    }

    // MARK: - 迭代所需的读

    /// 近 n 条复盘（按 sel_date 倒序），JSON 列已解析
    public func recentReviews(_ n: Int) -> [[String: Any]] {
        let rows = query("SELECT * FROM reviews ORDER BY sel_date DESC LIMIT ?", [n])
        return rows.map { r in
            var d = r
            d["four_layer_winrate"] = Self.jsonLoads(r["four_layer_json"] as? String) ?? NSNull()
            d["accuracy"] = Self.jsonLoads(r["accuracy_json"] as? String) ?? NSNull()
            d["stocks"] = (Self.jsonLoads(r["stocks_json"] as? String) as? [[String: Any]]) ?? []
            return d
        }
    }

    /// 某触发日的迭代报告是否已存在（幂等判定）→ (counter, insights_json)
    public func iterateReport(triggerDate: String) -> (counter: Int, insightsJSON: String?)? {
        let rows = query("SELECT counter, insights_json FROM iterate_reports WHERE trigger_date=?",
                         [triggerDate])
        guard let r = rows.first else { return nil }
        return (Self.intOf(r["counter"]) ?? 0, r["insights_json"] as? String)
    }
}