import Foundation
import SQLite3

/// 涨停池的落库与读取。
///
/// ## 为什么必须落库
/// 涨停统计是**外部时点数据**，而且源**只覆盖最近约 10 余个交易日**（实测）——
/// 今天不记下来，**以后永远取不回**（对比：筹码分布能从日K重算，所以它不落库）。
///
/// ## 为什么是主库里的 Swift-only 表
/// 与 `stock_fund_flows` / `stock_lhb` / `index_members` 同一条路：
/// 建表挂 `DBBootstrap.ensureSwiftOnlySchemaOnDisk`。
/// ⚠ **不写进** `engine/params/db_schema_export.json`。
///
/// ## ⚠ 整日重插（不是增量）
/// 涨停池**盘中一直在变**（新涨停 / 炸板），收盘后抓到的才是终态。
/// 所以 `saveDay` 是"**删掉这一天再整批插**"，可安全重跑。
public enum LimitUpPoolStore {

    /// 建表 DDL（`IF NOT EXISTS` 天然幂等，每次打开都跑一遍）
    ///
    /// 主键 `(trade_date, code)`：一天一只票只有一行（一只票当天只有一种"涨停类型"）。
    /// 另建 `idx_limit_up_pool_code`：详情页问的是"**这只票**最近涨停过吗"，
    /// 主键索引（trade_date 在前）帮不上忙。
    public static let createSQL = """
    CREATE TABLE IF NOT EXISTS limit_up_pool (
        trade_date    TEXT NOT NULL,
        code          TEXT NOT NULL,
        name          TEXT NOT NULL DEFAULT '',
        price         REAL NOT NULL DEFAULT 0,
        change_pct    REAL NOT NULL DEFAULT 0,
        amount        REAL NOT NULL DEFAULT 0,
        turnover_rate REAL NOT NULL DEFAULT 0,
        float_cap     REAL NOT NULL DEFAULT 0,
        total_cap     REAL NOT NULL DEFAULT 0,
        boards        INTEGER NOT NULL DEFAULT 0,
        stat_days     INTEGER NOT NULL DEFAULT 0,
        stat_boards   INTEGER NOT NULL DEFAULT 0,
        first_seal    TEXT NOT NULL DEFAULT '',
        last_seal     TEXT NOT NULL DEFAULT '',
        broken_count  INTEGER NOT NULL DEFAULT 0,
        seal_fund     REAL NOT NULL DEFAULT 0,
        industry      TEXT NOT NULL DEFAULT '',
        fetched_at    TEXT NOT NULL DEFAULT '',
        PRIMARY KEY (trade_date, code)
    );
    CREATE INDEX IF NOT EXISTS idx_limit_up_pool_code ON limit_up_pool(code, trade_date);
    """

    /// 索引名
    public static let codeIndexName = "idx_limit_up_pool_code"

    private static let reader = LimitUpPoolReader()

    /// 转发到 `LimitUpPoolReader.close()`。
    /// 手动释放本 Store 的连接。
    /// ⚠ 换库清单**不需要**再点名本 Store：连接在 `ReadOnlyConnection.init` 里已登记进
    /// `DataConnections`，`closeAll()` 自动覆盖（原先靠人往清单里加一行，实测漏过 4 个）。
    public static func close() {
        reader.close()
    }

    // MARK: - 写

    /// **整日重插**某一天的涨停池（先删后插，同一事务）。
    ///
    /// ⚠ 先删后插必须同事务：半截提交会留下"这天只有一半涨停股"——
    /// 那种数据比没有更糟（界面上照样显示"涨停了"，只是连板数/封板时间可能缺）。
    @discardableResult
    public static func saveDay(date: String, records: [LimitUpRecord],
                               at stamp: String) throws -> Int {
        guard !date.isEmpty else { return 0 }
        return try SQLiteWriter.shared.write { tx in
            try tx.execute("DELETE FROM limit_up_pool WHERE trade_date=?", [date])
            let rows: [[Any?]] = records.map { r in
                [r.date, r.code, r.name, r.price, r.changePct, r.amount, r.turnoverRate,
                 r.floatCap, r.totalCap, r.boards, r.statDays, r.statBoards,
                 r.firstSeal, r.lastSeal, r.brokenCount, r.sealFund, r.industry, stamp]
            }
            try tx.executeBatch(
                "INSERT OR REPLACE INTO limit_up_pool("
                + "trade_date, code, name, price, change_pct, amount, turnover_rate,"
                + " float_cap, total_cap, boards, stat_days, stat_boards,"
                + " first_seal, last_seal, broken_count, seal_fund, industry, fetched_at)"
                + " VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                rows: rows)
            return records.count
        }
    }

    /// 清空（涨停池是可重取的公开数据，但**只能取到最近 10 余天**）
    public static func deleteAll() throws {
        _ = try SQLiteWriter.shared.write { tx in
            try tx.execute("DELETE FROM limit_up_pool")
        }
    }

    // MARK: - 读（自持只读连接，可从任意线程调）

    /// 某天是否已入库（`LimitUpPoolJob` 的回看补漏据此跳过已有日子）
    public static func hasDay(_ date: String) -> Bool {
        guard !date.isEmpty else { return false }
        return !reader.query("SELECT 1 FROM limit_up_pool WHERE trade_date=? LIMIT 1", [date])
            .isEmpty
    }

    /// 库里已有的交易日（**降序**，最近的在前）
    public static func days() -> [String] {
        reader.query("SELECT DISTINCT trade_date FROM limit_up_pool ORDER BY trade_date DESC", [])
            .compactMap { $0["trade_date"] as? String }
    }

    /// 某只票最近一次涨停的记录（详情页用）。
    ///
    /// - Parameter upTo: 只看这一天及更早（`nil` = 不限）
    /// - Returns: 最近的一条；从未涨停过 → `nil`
    public static func latestRecord(code: String, upTo: String? = nil) -> LimitUpRecord? {
        guard !code.isEmpty else { return nil }
        let sql = "SELECT * FROM limit_up_pool WHERE code=?"
            + (upTo == nil ? "" : " AND trade_date<=?")
            + " ORDER BY trade_date DESC LIMIT 1"
        let params: [Any?] = upTo == nil ? [code] : [code, upTo!]
        return reader.query(sql, params).first.flatMap(record)
    }

    /// 某只票在最近 `limit` 个交易日内的涨停记录（升序，供"最近涨停过几次"）
    public static func recentRecords(code: String, limit: Int = 20) -> [LimitUpRecord] {
        guard !code.isEmpty, limit > 0 else { return [] }
        return reader.query(
            "SELECT * FROM limit_up_pool WHERE code=? ORDER BY trade_date DESC LIMIT ?",
            [code, limit]).compactMap(record).reversed()
    }

    /// 某一天的涨停池（升序：首封时间靠前的在前）
    public static func dayRecords(_ date: String) -> [LimitUpRecord] {
        guard !date.isEmpty else { return [] }
        return reader.query(
            "SELECT * FROM limit_up_pool WHERE trade_date=?"
            + " ORDER BY first_seal ASC, code ASC", [date]).compactMap(record)
    }

    /// 各交易日的涨停家数（`date → 条数`）
    public static func counts() -> [String: Int] {
        var out: [String: Int] = [:]
        for r in reader.query(
            "SELECT trade_date, COUNT(*) AS n FROM limit_up_pool GROUP BY trade_date", []) {
            guard let d = r["trade_date"] as? String else { continue }
            out[d] = (r["n"] as? Int) ?? 0
        }
        return out
    }

    // MARK: - 内部

    /// 行 → 记录（列名与 DDL 必须逐字对上，错了只会**静默读到 0**）
    private static func record(_ row: [String: Any]) -> LimitUpRecord? {
        guard let date = row["trade_date"] as? String, !date.isEmpty,
              let code = row["code"] as? String, !code.isEmpty else { return nil }
        func i(_ k: String) -> Int {
            if let n = row[k] as? Int { return n }
            if let n = row[k] as? NSNumber { return n.intValue }
            return 0
        }
        func d(_ k: String) -> Double {
            if let v = row[k] as? Double { return v }
            if let v = row[k] as? Int { return Double(v) }
            if let v = row[k] as? NSNumber { return v.doubleValue }
            return 0
        }
        return LimitUpRecord(
            date: date, code: code, name: (row["name"] as? String) ?? "",
            price: d("price"), changePct: d("change_pct"), amount: d("amount"),
            turnoverRate: d("turnover_rate"), floatCap: d("float_cap"),
            totalCap: d("total_cap"), boards: i("boards"),
            statDays: i("stat_days"), statBoards: i("stat_boards"),
            firstSeal: (row["first_seal"] as? String) ?? "",
            lastSeal: (row["last_seal"] as? String) ?? "",
            brokenCount: i("broken_count"), sealFund: d("seal_fund"),
            industry: (row["industry"] as? String) ?? "")
    }
}

/// 涨停池的**私有只读连接**（与 `LhbReader` / `FundFlowStore` / `PhaseStore` 同构）。
///
/// 存在的唯一理由：`SQLiteReader.shared` 是**主线程专用**的共享连接，
/// 而本模块的读会被**后台任务**调用（`LimitUpPoolJob` 的回看补漏要查 `hasDay`）
/// → 复用它会跨线程并发用同一连接 → **SIGSEGV**。
private final class LimitUpPoolReader: @unchecked Sendable {

    /// ⚠ 自持只读连接（**不能用 `SQLiteReader.shared`** —— 它是 `@MainActor` 的，
    ///   跨线程读会 SIGSEGV）。四件套（`READWRITE` / `PRAGMA query_only` / `busy_timeout` /
    ///   串行队列）由 `ReadOnlyConnection` **一处**保证。
    ///   数据目录解析的唯一实现见 `DataDirectory.resolve()`。
    private let conn = ReadOnlyConnection(label: "LimitUpPoolStore", pathProvider: DataDirectory.resolve)

    /// 关闭只读连接。
    ///
    /// ⚠ 换库时这条连接**一定会被放掉**：`ReadOnlyConnection.init` 把它登记进 `DataConnections`。
    ///   原先靠人记得往清单里加一行，漏了就是**换库后继续读旧库**而界面显示新库数据；
    ///   且 `openLocked()` 缓存 openError，旧路径失败一旦缓存就**永不重试**。
    func close() {
        conn.close()
    }

    func query(_ sql: String, _ params: [Any?] = []) -> [[String: Any]] {
        conn.queryRows(sql, params)
    }
}
