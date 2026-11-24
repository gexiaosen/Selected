import Foundation
import SQLite3

/// 指标快照的落库与读取。
///
/// ## 为什么是主库里的 Swift-only 宽表
/// 与 `board_heat` / `limit_up_pool` 同一条路：建表挂 `DBBootstrap.ensureSwiftOnlySchema`，
/// **不写进** `engine/params/db_schema_export.json`。每日全市场 × 22 指标的末值落库，
/// 筛选页直接 `WHERE trade_date=? ORDER BY <列>` 秒开，不现场拉网络。
///
/// ## 宽表而不是长表（有意）
/// 长表（code, indicator, value）一天 ~19 万行、全量保留一年上亿；宽表一天 ~5000 行、
/// 列数固定（36 值列）。新增指标 = `ALTER TABLE ADD COLUMN`（SQLite 廉价），
/// 列名由 `IndicatorRegistry.outputs` 单一来源生成，契约测试钉死双向一致。
///
/// ## ⚠ NULL 语义（读侧纪律）
/// 值列 NULL = **预热不足/算不出**（新股、停牌段），与"值是 0"是两件事。
/// 读侧一律 `as? Double`，**禁用 `Num.doubleOrZero`**（那会把 NULL 变 0，
/// 让"算不出"伪装成"中性值"进排行）。
/// `super_trend_up` 是 INTEGER：1=上升 / 0=下降 / NULL=预热不足。
///
/// ## ⚠ 整日重插（同 `BoardHeatStore.saveDay`）
/// 盘中手动触发写盘中快照、收盘调度重算覆盖 —— 每次都是"删掉这天再整批插"，
/// 同事务保证不留半截（半截比没有更糟：排行照样出数、名次全错）。
public enum IndicatorSnapshotStore {

    public static let table = "indicator_snapshots"

    /// 一行快照：code + 列名→值（`nil` 绑 SQL NULL）。键必须来自 `columns` 白名单。
    public struct Row: Sendable {
        public let code: String
        public let values: [String: Double?]

        public init(code: String, values: [String: Double?]) {
            self.code = code
            self.values = values
        }
    }

    /// 排行查询的一行（值列 NULL 的记录在 ranking 里已被 `IS NOT NULL` 排除）
    public struct RankEntry: Sendable {
        public let code: String
        public let name: String
        public let value: Double
    }

    /// 多条件筛选的一行：`values` 与调用方传入的规则顺序**一一对应**，
    /// NULL（算不出 / 预热不足）保留为 nil —— 不许变成 0 混进排序。
    public struct ScreenRow: Sendable {
        public let code: String
        public let name: String
        /// 当日收盘价（快照基础列）
        public let close: Double?
        /// 当日涨跌幅 %（收盘 / 前一快照日收盘 − 1）；没有前一日 → nil
        public let changePct: Double?
        public let values: [Double?]

        public init(code: String, name: String, close: Double?, changePct: Double?,
                    values: [Double?]) {
            self.code = code
            self.name = name
            self.close = close
            self.changePct = changePct
            self.values = values
        }
    }

    // MARK: - 列名单一来源（注册表驱动）

    /// INTEGER 列（其余值列 REAL）。目前只有 SuperTrend 方向位。
    public static let integerColumns: Set<String> = ["super_trend_up"]

    /// 基础列（非指标，筛选规则的比价基准）：今日收盘价 + ATR 占价百分比。
    /// ⚠ 不进注册表（不是指标），但进白名单与 DDL —— `close > MA` 类规则靠它。
    public static let baseColumns: [String] = ["close_value", "atr_sma_percent"]

    /// 全部值列（注册表 36 + 基础 2），按注册表 `all` 顺序、指标内按 `outputs` 顺序。
    public static var columns: [String] {
        IndicatorRegistry.all.flatMap(\.columns) + baseColumns
    }

    /// 列名 → 所属指标 id（诊断/展示反查用）。
    public static var columnOwners: [String: String] {
        var map: [String: String] = [:]
        for m in IndicatorRegistry.all { for c in m.columns { map[c] = m.id } }
        return map
    }

    /// 建表 DDL（`IF NOT EXISTS` 幂等；列定义由注册表生成，手写只会漂）。
    public static var createSQL: String {
        var cols = ["trade_date    TEXT NOT NULL", "code       TEXT NOT NULL"]
        for c in columns {
            cols.append("\(c) \(integerColumns.contains(c) ? "INTEGER" : "REAL")")
        }
        cols.append("fetched_at TEXT NOT NULL DEFAULT ''")
        return "CREATE TABLE IF NOT EXISTS \(table) (\n        "
            + cols.joined(separator: ",\n        ")
            + ",\n        PRIMARY KEY (trade_date, code)\n    );"
            + "\n    CREATE INDEX IF NOT EXISTS idx_indicator_snapshots_code"
            + " ON \(table)(code, trade_date);"
    }

    /// 索引名
    public static let codeIndexName = "idx_indicator_snapshots_code"

    private static let reader = IndicatorSnapshotReader()

    /// 手动释放本 Store 的连接（换库时由 `DataConnections.closeAll()` 自动覆盖，不需要点名）。
    public static func close() {
        reader.close()
    }

    // MARK: - 写

    /// **整日重插**某天全市场快照（先删后插，同一事务）。返回写入行数。
    ///
    /// ⚠ `row.values` 里出现的**非白名单键**直接抛错（写侧也守白名单——
    /// 列名漂了宁可红，不要静默少列）。
    @discardableResult
    public static func saveDay(date: String, rows: [Row], at stamp: String) throws -> Int {
        guard !date.isEmpty, !rows.isEmpty else { return 0 }
        let cols = columns
        let placeholders = Array(repeating: "?", count: cols.count + 3).joined(separator: ",")
        let sql = "INSERT OR REPLACE INTO \(table)(trade_date, code,"
            + cols.joined(separator: ",") + ",fetched_at) VALUES(" + placeholders + ")"
        // 白名单校验与参数装配放在**事务外**（原先在事务循环里，每行都对
        // `cols` 做一次 O(38) 线性 `contains` ⇒ 5000 行 × 每行每个键 = 几十万次比较）。
        let colSet = Set(cols)
        let intSet = integerColumns
        var batch: [[Any?]] = []
        batch.reserveCapacity(rows.count)
        for r in rows {
            for k in r.values.keys where !colSet.contains(k) {
                throw SQLiteWriteError(message: "快照列名不在白名单：\(k)（\(r.code)）")
            }
            var params: [Any?] = [date, r.code]
            for c in cols {
                let v = r.values[c] ?? nil
                if let v, intSet.contains(c) {
                    // 1/0 方向位；`Int(v)` 对越界值是 trap，走 Num.intSafe（见其说明）
                    params.append(Num.intSafe(v) ?? 0)
                } else {
                    params.append(v)        // Double? 或 nil → SQL NULL
                }
            }
            params.append(stamp)
            batch.append(params)
        }
        return try SQLiteWriter.shared.write { tx in
            try tx.execute("DELETE FROM \(table) WHERE trade_date=?", [date])
            try tx.executeBatch(sql, rows: batch)
            return rows.count
        }
    }

    // MARK: - 读（自持只读连接，可从任意线程调）

    /// 库里已有的交易日（**降序**，最近的在前）
    public static func days() -> [String] {
        reader.query("SELECT DISTINCT trade_date FROM \(table) ORDER BY trade_date DESC", [])
            .compactMap { $0["trade_date"] as? String }
    }

    /// 库里最近一天（无数据 → nil）
    public static func latestDay() -> String? { days().first }

    /// 不晚于 `date` 的最近快照日（筛选页在所选日无快照时回落到它，并在页顶明示）。
    ///
    /// 只用于"今天还没收盘快照"这类场景：拿**更晚**的日子顶替所选日会改变口径，
    /// 所以只往前找；一天都没有 → nil（页面显示无快照空态，不硬造）。
    public static func latestDay(onOrBefore date: String) -> String? {
        guard !date.isEmpty else { return nil }
        let rows = reader.query("SELECT MAX(trade_date) AS d FROM \(table) WHERE trade_date<=?", [date])
        return rows.first?["d"] as? String
    }

    /// 某天入库数（筛选页脚"覆盖 N 只"）
    public static func count(on date: String) -> Int {
        guard !date.isEmpty else { return 0 }
        let rows = reader.query("SELECT COUNT(*) AS n FROM \(table) WHERE trade_date=?", [date])
        return rows.first?["n"] as? Int ?? 0
    }

    /// 最近一次**成功入库**时刻（`data_source_logs`，`indsnap_ok`；无记录 → nil）。
    /// 用途：筛选页新鲜度标记（盘中手动重算 vs 收盘定稿，同板块页语义）。
    public static func lastFetchedAt() -> String? {
        reader.query("SELECT ts FROM data_source_logs WHERE source='indsnap'"
                     + " AND event='indsnap_ok' ORDER BY ts DESC LIMIT 1", [])
            .first?["ts"] as? String
    }

    /// 某天某列的排行（筛选页主查询）。
    ///
    /// ⚠ `column` **必须**是 `columns` 白名单成员 —— 列名要拼进 SQL，
    /// 白名单是唯一防线（值一律参数绑定）。非白名单 → 空数组（调用方拿 nil/[] 自行报错，
    /// 不 trap：这是查询面不是断言面）。
    /// ⚠ `IS NOT NULL`：预热不足的票**不进排行**（NULL 参与 ORDER BY 会沉底/置顶
    ///   取决于方言，SQLite 里 NULL 最小 —— desc 时"看不见"、asc 时"排最前"，都错）。
    public static func ranking(date: String, column: String,
                               ascending: Bool = false, limit: Int = 200) -> [RankEntry] {
        guard !date.isEmpty, limit > 0, columns.contains(column) else { return [] }
        let rows = reader.query(
            "SELECT t.code AS code, COALESCE(q.name, '') AS name, t.\(column) AS value"
            + " FROM \(table) t LEFT JOIN securities q ON q.code = t.code"
            + " WHERE t.trade_date=? AND t.\(column) IS NOT NULL"
            + " ORDER BY t.\(column) \(ascending ? "ASC" : "DESC"), t.code ASC"
            + " LIMIT ?", [date, limit])
        return rows.compactMap { r in
            guard let code = r["code"] as? String, let v = Num.doubleOrNil(r["value"]) else { return nil }
            return RankEntry(code: code, name: (r["name"] as? String) ?? "", value: v)
        }
    }

    /// 某天单只票的全部指标值（详情卡；无行 → nil）。
    /// 值列 `as? Double`：NULL 列在行字典里缺席 → 读回 nil（**不是 0**）。
    public static func row(date: String, code: String) -> [String: Double?]? {
        guard !date.isEmpty, !code.isEmpty else { return nil }
        let rows = reader.query("SELECT * FROM \(table) WHERE trade_date=? AND code=?", [date, code])
        guard let r = rows.first else { return nil }
        var out: [String: Double?] = [:]
        for c in columns {
            out[c] = Num.doubleOrNil(r[c])
        }
        return out
    }

    // MARK: - 筛选查询

    /// 库里 `date` **之前**最近的一个快照日（金叉类规则的前一日；没有 → nil）。
    public static func previousDay(of date: String) -> String? {
        guard !date.isEmpty else { return nil }
        return days().first { $0 < date }
    }

    /// 按规则筛某天。规则的 `whereSQL` 里 `IndicatorScreener.thresholdToken` 出现处
    /// 以**绑定参数**注入阈值（不拼数字字符串），其余 SQL 片段是代码常量。
    /// 绑定顺序 = SQL 文本顺序：joins(prev) → trade_date → threshold → LIMIT。
    ///
    /// ⚠ 规则带 token 但未传阈值 → 空数组（调用方口径错误，不猜值）。
    /// ⚠ 规则需要前一日而库里没有 → 返回空数组（"没有可比的前日"不是"没有命中"，
    ///   界面按空命中展示并在口径里说明，不硬造金叉）。
    public static func screen(rule: IndicatorScreener.Rule, date: String,
                              limit: Int = 300, threshold: Double? = nil) -> [RankEntry] {
        guard !date.isEmpty, limit > 0 else { return [] }
        let token = IndicatorScreener.thresholdToken
        let parts = rule.whereSQL.components(separatedBy: token)
        let hasToken = parts.count == 2
        if hasToken, threshold == nil { return [] }
        // 契约：token 要么没有、要么恰好一个（多段说明规则写错，宁可不查）
        guard parts.count <= 2 else { return [] }
        var joins = " LEFT JOIN securities q ON q.code = t.code"
        var params: [Any?] = []
        if rule.needsPreviousDay {
            guard let prev = previousDay(of: date) else { return [] }
            joins += " JOIN \(table) p ON p.code = t.code AND p.trade_date=?"
            params.append(prev)
        }
        let whereJoined = parts.joined(separator: "?")
        let sql = "SELECT t.code AS code, COALESCE(q.name, '') AS name,"
            + " \(rule.valueSQL) AS value"
            + " FROM \(table) t" + joins
            + " WHERE t.trade_date=? AND \(whereJoined)"
            + " ORDER BY value \(rule.ascending ? "ASC" : "DESC"), t.code ASC"
            + " LIMIT ?"
        params.append(date)
        if hasToken { params.append(threshold) }
        params.append(limit)
        return reader.query(sql, params).compactMap { r in
            guard let code = r["code"] as? String, let v = Num.doubleOrNil(r["value"]) else { return nil }
            return RankEntry(code: code, name: (r["name"] as? String) ?? "", value: v)
        }
    }

    // MARK: - 多条件筛选（AND）

    /// 多条件 AND 筛选：每条规则一个 `WHERE` 片段、一个 `valueSQL` 结果列。
    ///
    /// - 规则按传入顺序去重；`sortBy` 缺省 = 第一条（方向取该规则的 `ascending`）。
    /// - 任一规则需要前一日 → 只加**一个** `p` join；库里没有前一日 → 空数组
    ///   （与单条件口径一致：没有可比的前日不是"没有命中"）。
    /// - 阈值仍在 `IndicatorScreener` 解析后传入；token 按 SQL 文本顺序绑定。
    /// - `whereSQL` / `valueSQL` 都来自 `IndicatorScreener.rules` 常量，列名已被契约测试
    ///   钉在白名单里（本函数不拼任何用户输入）。
    public static func screen(rules input: [IndicatorScreener.Rule], date: String,
                              limit: Int = 300, sortBy: String? = nil,
                              thresholds: [String: Double] = [:]) -> [ScreenRow] {
        guard !date.isEmpty, limit > 0 else { return [] }
        let rules = uniqueRules(input)
        guard !rules.isEmpty else { return [] }
        // 前一日：规则需要它（金叉/唐奇安）时是**必需**的；不需要时若存在也 LEFT JOIN，
        // 只为多带一列「前收」算当日涨跌幅（没有前一日 → 涨跌幅为 nil，不硬造 0）。
        let prev = previousDay(of: date)
        if rules.contains(where: \.needsPreviousDay), prev == nil { return [] }
        var joins = " LEFT JOIN securities q ON q.code = t.code"
        var prevParam: Any?
        if let prev {
            joins += " LEFT JOIN \(table) p ON p.code = t.code AND p.trade_date=?"
            prevParam = prev
        }
        var wheres: [String] = []
        var whereParams: [Any?] = []
        for r in rules {
            guard let f = whereFragment(r, thresholds: thresholds) else { return [] }
            wheres.append("(" + f.sql + ")")
            whereParams.append(contentsOf: f.params)
        }
        let selects = rules.enumerated()
            .map { "\($0.element.valueSQL) AS v\($0.offset)" }
            .joined(separator: ", ")
        let sortIndex = rules.firstIndex { $0.indicatorId == sortBy } ?? 0
        let sortRule = rules[sortIndex]
        // 没有前一日就没有 p 表 —— 前收列必须写 NULL，不能引用不存在的别名
        let prevClose = prev == nil ? "NULL" : "p.close_value"
        let sql = "SELECT t.code AS code, COALESCE(q.name, '') AS name,"
            + " t.close_value AS close, \(prevClose) AS prev_close,"
            + " \(selects) FROM \(table) t" + joins
            + " WHERE t.trade_date=? AND " + wheres.joined(separator: " AND ")
            + " ORDER BY v\(sortIndex) \(sortRule.ascending ? "ASC" : "DESC") NULLS LAST, t.code ASC"
            + " LIMIT ?"
        var params: [Any?] = []
        if let prevParam { params.append(prevParam) }
        params.append(date)
        params.append(contentsOf: whereParams)
        params.append(limit)
        return reader.query(sql, params).compactMap { r in
            guard let code = r["code"] as? String else { return nil }
            var values: [Double?] = []
            values.reserveCapacity(rules.count)
            for i in rules.indices {
                values.append(Num.doubleOrNil(r["v\(i)"]))
            }
            let close = Num.doubleOrNil(r["close"])
            let prevClose = Num.doubleOrNil(r["prev_close"])
            var change: Double?
            if let close, let prevClose, prevClose != 0 {
                change = (close / prevClose - 1) * 100
            }
            return ScreenRow(code: code, name: (r["name"] as? String) ?? "",
                             close: close, changePct: change, values: values)
        }
    }

    /// 多条件 AND 的命中数（`nil` = 不可算：需要前一日但库里没有）。
    ///
    /// 0 命中页的"去掉哪个条件能有多少只"也走这里（对每个去掉一项的子集各调一次，
    /// ≤6 次查询，毫秒级）。
    public static func count(rules input: [IndicatorScreener.Rule], date: String,
                             thresholds: [String: Double] = [:]) -> Int? {
        guard !date.isEmpty else { return nil }
        let rules = uniqueRules(input)
        guard !rules.isEmpty else { return nil }
        var joins = ""
        var prevParam: Any?
        if rules.contains(where: \.needsPreviousDay) {
            guard let prev = previousDay(of: date) else { return nil }
            joins = " JOIN \(table) p ON p.code = t.code AND p.trade_date=?"
            prevParam = prev
        }
        var wheres: [String] = []
        var whereParams: [Any?] = []
        for r in rules {
            guard let f = whereFragment(r, thresholds: thresholds) else { return nil }
            wheres.append("(" + f.sql + ")")
            whereParams.append(contentsOf: f.params)
        }
        let sql = "SELECT COUNT(*) AS n FROM \(table) t" + joins
            + " WHERE t.trade_date=? AND " + wheres.joined(separator: " AND ")
        var params: [Any?] = []
        if let prevParam { params.append(prevParam) }
        params.append(date)
        params.append(contentsOf: whereParams)
        guard let row = reader.query(sql, params).first else { return nil }
        return (row["n"] as? Int) ?? 0
    }

    /// 每条规则在 `date` 的**单日命中数**（勾选面板右侧那个数）。
    ///
    /// 一次 SQL 出 22 个 `SUM(CASE WHEN …)`；需要前一日的规则单独一组查询 ——
    /// 库里没有前一日时，那几条不给数（界面显示「—」，不拿 0 冒充）。
    public static func singleCounts(date: String,
                                    thresholds: [String: Double] = [:]) -> [String: Int] {
        guard !date.isEmpty else { return [:] }
        let all = IndicatorScreener.rules
        var out: [String: Int] = [:]
        let prev = previousDay(of: date)
        for needsPrev in [false, true] {
            let rules = all.filter { $0.needsPreviousDay == needsPrev }
            guard !rules.isEmpty else { continue }
            if needsPrev, prev == nil { continue }
            var joins = ""
            if needsPrev { joins = " JOIN \(table) p ON p.code = t.code AND p.trade_date=?" }
            var selects: [String] = []
            var whereParams: [Any?] = []
            for (i, r) in rules.enumerated() {
                guard let f = whereFragment(r, thresholds: thresholds) else { continue }
                selects.append("SUM(CASE WHEN (\(f.sql)) THEN 1 ELSE 0 END) AS c\(i)")
                whereParams.append(contentsOf: f.params)
            }
            guard !selects.isEmpty else { continue }
            let sql = "SELECT " + selects.joined(separator: ", ")
                + " FROM \(table) t" + joins + " WHERE t.trade_date=?"
            // 绑定顺序 = SQL 文本顺序：SELECT 里的阈值 → JOIN 的前一日 → WHERE 的日期
            var params: [Any?] = whereParams
            if needsPrev { params.append(prev) }
            params.append(date)
            guard let row = reader.query(sql, params).first else { continue }
            for (i, r) in rules.enumerated() {
                if let n = row["c\(i)"] as? Int { out[r.indicatorId] = n }
            }
        }
        return out
    }

    /// 规则去重（保序：同一 id 只留第一次出现）。
    static func uniqueRules(_ rules: [IndicatorScreener.Rule]) -> [IndicatorScreener.Rule] {
        var seen = Set<String>()
        var out: [IndicatorScreener.Rule] = []
        for r in rules where seen.insert(r.indicatorId).inserted { out.append(r) }
        return out
    }

    /// 把一条规则的 whereSQL 变成可绑定片段；token 恰好一处才合法（与单条件版本同契约）。
    static func whereFragment(_ rule: IndicatorScreener.Rule,
                              thresholds: [String: Double]) -> (sql: String, params: [Any?])? {
        let token = IndicatorScreener.thresholdToken
        let parts = rule.whereSQL.components(separatedBy: token)
        guard parts.count <= 2 else { return nil }
        if parts.count == 2 {
            let v = rule.thresholdKey.flatMap { thresholds[$0] } ?? rule.defaultThreshold
            return (parts[0] + "?" + parts[1], [v])
        }
        return (rule.whereSQL, [])
    }
}

/// 指标快照的**私有只读连接**（与 `BoardHeatReader` / `LimitUpPoolReader` 同构）。
///
/// 存在的唯一理由：`SQLiteReader.shared` 是主线程专用，而 `ranking/row/latestDay`
/// 会被后台任务与主线程同时调 → 必须自持连接（跨线程共用 = SIGSEGV）。
private final class IndicatorSnapshotReader: @unchecked Sendable {

    private let conn = ReadOnlyConnection(label: "IndicatorSnapshotStore",
                                          pathProvider: DataDirectory.resolve)

    func close() {
        conn.close()
    }

    func query(_ sql: String, _ params: [Any?] = []) -> [[String: Any]] {
        conn.queryRows(sql, params)
    }
}
