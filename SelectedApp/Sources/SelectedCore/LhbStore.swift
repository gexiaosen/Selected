import Foundation
import SQLite3

/// 龙虎榜的存储层：`stock_lhb`（上榜记录）+ `stock_lhb_seats`（席位明细）两张表（**Swift 独有**）。
///
/// 建表在 `DBBootstrap.ensureSwiftOnlyMigrations`（**独立于版本水位执行**），
/// 不写进 `engine/params/db_schema_export.json`。
///
/// ## ⚠ 读为什么不用 `SQLiteReader.shared`
///
/// 本类的读方法会被**后台任务**调用（`LhbJob` 在 `Task.detached` 里跑）。
/// 而 `SQLiteReader` 的共享连接是**主线程专用**的 ——
/// Apple 系统 libsqlite3 是 multi-thread 模式（非 serialized），
/// **同一个连接跨线程并发使用直接 SIGSEGV**（见 `SQLiteReader.integrityIssue` 的实现契约）。
/// → 本类自持一个 `query_only` 只读连接 + 串行队列，与 `CompareStore` / `PhaseStore` /
///   `WatchStore` / `ParamStore` / `FundFlowStore` 完全同构。
/// → 写走 `SQLiteWriter.shared`（本身就是"串行队列 + 唯一写连接"，跨线程安全）。
///
/// ## ⚠ 为什么席位表**不能**用 `INSERT OR REPLACE`
///
/// 资金流表的主键 `(trade_date, code)` 是**业务上可证明唯一**的，所以能逐行 upsert。
/// 龙虎榜席位表**没有可证明的自然键**（实测：同一营业部在同一侧会重复出现、
/// `TRADE_ID` 不唯一、返回顺序也不是金额降序）。
/// 若硬用"响应顺序 rank"当键去 upsert，一旦供应商改了排序，
/// "第 3 名"会换成另一家营业部，`REPLACE` 会把它当成**同一条记录的更新**。
/// → 写入一律走 `saveDay(_:)`：**同一事务内先 `DELETE` 该日、再整批插入**。
///   幂等（重跑同一天结果一致），且不会留下上一次排序的残影。
public enum LhbStore {

    public static let recordTable = "stock_lhb"
    public static let seatTable = "stock_lhb_seats"

    /// 建表 DDL。`ensureSwiftOnlyMigrations` 调用；`IF NOT EXISTS` 天然幂等。
    ///
    /// 索引都按 `(code, trade_date)` 建：详情页的访问模式是"某只票的最近上榜记录"，
    /// 主键索引（以 `trade_date` 打头）在"按 code 单查"上帮不上忙。
    public static let createSQL = """
    CREATE TABLE IF NOT EXISTS stock_lhb (
        trade_date        TEXT NOT NULL,
        code              TEXT NOT NULL,
        change_type       TEXT NOT NULL,
        name              TEXT NOT NULL DEFAULT '',
        explanation       TEXT NOT NULL DEFAULT '',
        market            TEXT NOT NULL DEFAULT '',
        trade_market      TEXT NOT NULL DEFAULT '',
        close             REAL NOT NULL DEFAULT 0,
        change_pct        REAL NOT NULL DEFAULT 0,
        turnover_rate     REAL NOT NULL DEFAULT 0,
        net_amount        REAL NOT NULL DEFAULT 0,
        buy_amount        REAL NOT NULL DEFAULT 0,
        sell_amount       REAL NOT NULL DEFAULT 0,
        deal_amount       REAL NOT NULL DEFAULT 0,
        accum_amount      REAL NOT NULL DEFAULT 0,
        free_market_cap   REAL NOT NULL DEFAULT 0,
        deal_amount_ratio REAL NOT NULL DEFAULT 0,
        deal_net_ratio    REAL NOT NULL DEFAULT 0,
        buy_ratio         REAL NOT NULL DEFAULT 0,
        sell_ratio        REAL NOT NULL DEFAULT 0,
        trade_id          INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (trade_date, code, change_type)
    );
    CREATE INDEX IF NOT EXISTS idx_stock_lhb_code
        ON stock_lhb(code, trade_date);
    CREATE TABLE IF NOT EXISTS stock_lhb_seats (
        trade_date  TEXT NOT NULL,
        code        TEXT NOT NULL,
        change_type TEXT NOT NULL,
        side        TEXT NOT NULL,
        rank        INTEGER NOT NULL,
        dept_code   TEXT NOT NULL DEFAULT '',
        dept_name   TEXT NOT NULL DEFAULT '',
        buy         REAL NOT NULL DEFAULT 0,
        sell        REAL NOT NULL DEFAULT 0,
        net         REAL NOT NULL DEFAULT 0,
        PRIMARY KEY (trade_date, code, change_type, side, rank)
    );
    CREATE INDEX IF NOT EXISTS idx_stock_lhb_seats_code
        ON stock_lhb_seats(code, trade_date);
    """

    /// 私有只读连接（**不要**换成 `SQLiteReader.shared`，见类注释）
    private static let reader = LhbReader()

    /// 转发到 `LhbReader.close()`。
    /// 手动释放本 Store 的连接。
    /// ⚠ 换库清单**不需要**再点名本 Store：连接在 `ReadOnlyConnection.init` 里已登记进
    /// `DataConnections`，`closeAll()` 自动覆盖（原先靠人往清单里加一行，实测漏过 4 个）。
    public static func close() {
        reader.close()
    }

    // MARK: - 写

    /// 整日重写（**先删该日再插入**，见类注释）。返回 `(上榜记录数, 席位数)`。
    ///
    /// 单事务：要么整天进去、要么一行都不进 —— 避免留下"有记录没席位"的半截交易日。
    @discardableResult
    public static func saveDay(_ day: LhbDay) throws -> (records: Int, seats: Int) {
        try SQLiteWriter.shared.write { tx in
            try tx.execute("DELETE FROM stock_lhb WHERE trade_date = ?", [day.date])
            try tx.execute("DELETE FROM stock_lhb_seats WHERE trade_date = ?", [day.date])
            let recordRows: [[Any?]] = day.records.map { r in
                [r.date, r.code, r.changeType, r.name, r.explanation, r.market,
                 r.tradeMarket, r.close, r.changePct, r.turnoverRate, r.netAmount,
                 r.buyAmount, r.sellAmount, r.dealAmount, r.accumAmount, r.freeMarketCap,
                 r.dealAmountRatio, r.dealNetRatio, r.buyRatio, r.sellRatio, r.tradeId]
            }
            try tx.executeBatch(
                "INSERT OR REPLACE INTO stock_lhb"
                + "(trade_date, code, change_type, name, explanation, market,"
                + " trade_market, close, change_pct, turnover_rate, net_amount,"
                + " buy_amount, sell_amount, deal_amount, accum_amount, free_market_cap,"
                + " deal_amount_ratio, deal_net_ratio, buy_ratio, sell_ratio, trade_id)"
                + " VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                rows: recordRows)
            let seatRows: [[Any?]] = day.seats.map { s in
                [s.date, s.code, s.changeType, s.side, s.rank,
                 s.deptCode, s.deptName, s.buy, s.sell, s.net]
            }
            try tx.executeBatch(
                "INSERT OR REPLACE INTO stock_lhb_seats"
                + "(trade_date, code, change_type, side, rank,"
                + " dept_code, dept_name, buy, sell, net)"
                + " VALUES(?,?,?,?,?,?,?,?,?,?)",
                rows: seatRows)
            return (recordRows.count, seatRows.count)
        }
    }

    // MARK: - 读

    /// 某日已落库的上榜记录数（幂等检查用）
    ///
    /// ⚠ 读取层对 `SQLITE_INTEGER` 列返回的是 **`Int`**（不是 `NSNumber`）。
    public static func count(date: String) -> Int {
        reader.query("SELECT COUNT(*) AS n FROM stock_lhb WHERE trade_date = ?", [date])
            .first?["n"] as? Int ?? 0
    }

    /// 某日已落库的席位数（幂等检查用）
    public static func seatCount(date: String) -> Int {
        reader.query("SELECT COUNT(*) AS n FROM stock_lhb_seats WHERE trade_date = ?", [date])
            .first?["n"] as? Int ?? 0
    }

    /// 表内最新的交易日（无数据返回 nil）
    ///
    /// ⚠ 空表时 `MAX()` 返回 NULL，而读取层对 `SQLITE_NULL` 是**整列跳过**（不进字典），
    /// 所以既可能拿到 `nil` 也可能拿到空串，两种都要当"没有"。
    public static func latestDate() -> String? {
        let d = reader.query("SELECT MAX(trade_date) AS d FROM stock_lhb", []).first?["d"] as? String
        return (d?.isEmpty ?? true) ? nil : d
    }

    /// 某只票的最近 `limit` 条上榜记录，**最近的在前**（DESC）。
    ///
    /// ⚠ 与 `FundFlowStore.history` 的升序约定**不同**，这是有意的：
    /// 资金流是"连续时间序列"（画趋势要旧→新），龙虎榜是"离散事件列表"
    /// （用户要看的是最近一次为什么上榜）。方法名与注释都写明方向，避免混用。
    public static func records(code: String, limit: Int = 30) -> [LhbRecord] {
        guard limit > 0 else { return [] }
        let rows = reader.query(
            "SELECT trade_date, code, change_type, name, explanation, market, trade_market,"
                + " close, change_pct, turnover_rate, net_amount, buy_amount, sell_amount,"
                + " deal_amount, accum_amount, free_market_cap, deal_amount_ratio,"
                + " deal_net_ratio, buy_ratio, sell_ratio, trade_id"
                + " FROM stock_lhb WHERE code = ?"
                + " ORDER BY trade_date DESC, change_type ASC LIMIT ?", [code, limit])
        return rows.compactMap { row in
            guard let d = row["trade_date"] as? String, !d.isEmpty else { return nil }
            return LhbRecord(
                date: d,
                code: row["code"] as? String ?? code,
                changeType: row["change_type"] as? String ?? "",
                name: row["name"] as? String ?? "",
                explanation: row["explanation"] as? String ?? "",
                market: row["market"] as? String ?? "",
                tradeMarket: row["trade_market"] as? String ?? "",
                close: num(row["close"]),
                changePct: num(row["change_pct"]),
                turnoverRate: num(row["turnover_rate"]),
                netAmount: num(row["net_amount"]),
                buyAmount: num(row["buy_amount"]),
                sellAmount: num(row["sell_amount"]),
                dealAmount: num(row["deal_amount"]),
                accumAmount: num(row["accum_amount"]),
                freeMarketCap: num(row["free_market_cap"]),
                dealAmountRatio: num(row["deal_amount_ratio"]),
                dealNetRatio: num(row["deal_net_ratio"]),
                buyRatio: num(row["buy_ratio"]),
                sellRatio: num(row["sell_ratio"]),
                tradeId: Int(num(row["trade_id"])))
        }
    }

    /// 某条上榜记录的席位明细，按 `side`（BUY 在前）与 `rank` 升序
    public static func seats(date: String, code: String, changeType: String) -> [LhbSeat] {
        let rows = reader.query(
            "SELECT trade_date, code, change_type, side, rank, dept_code, dept_name,"
                + " buy, sell, net FROM stock_lhb_seats"
                + " WHERE trade_date = ? AND code = ? AND change_type = ?"
                + " ORDER BY side ASC, rank ASC", [date, code, changeType])
        return rows.compactMap { row in
            guard let d = row["trade_date"] as? String, !d.isEmpty else { return nil }
            return LhbSeat(
                date: d,
                code: row["code"] as? String ?? code,
                changeType: row["change_type"] as? String ?? changeType,
                side: row["side"] as? String ?? "",
                rank: row["rank"] as? Int ?? 0,
                deptCode: row["dept_code"] as? String ?? "",
                deptName: row["dept_name"] as? String ?? "",
                buy: num(row["buy"]),
                sell: num(row["sell"]),
                net: num(row["net"]))
        }
    }

    /// REAL 列 → Double。
    ///
    /// ⚠ 首选 `Double`：读取层对 `SQLITE_FLOAT` 返回的就是 `Double`。
    /// 不用 `n.doubleValue` 做首选 —— 那对长小数**不是正确舍入**（NSDecimalNumber 平台怪癖）。
    /// ⚠ 实现已收敛到 `Num.doubleOrZero`（带 `isFinite` 守卫）。
    ///   折 0 是安全的：`stock_lhb` 的主键是 `(trade_date, code, change_type)`，
    ///   `trade_id` 只是普通列（DDL 里 `INTEGER NOT NULL DEFAULT 0`），不会撞键。
    private static func num(_ v: Any?) -> Double { Num.doubleOrZero(v) }
}

/// 龙虎榜的**私有只读连接**（与 `CompareStore` / `PhaseStore` / `WatchStore` /
/// `ParamStore` / `FundFlowStore` 同构）。
///
/// 存在的唯一理由：`SQLiteReader.shared` 是主线程专用的共享连接，
/// 而本模块的读会被后台任务调用 → 复用它会跨线程并发用同一连接 → SIGSEGV。
private final class LhbReader: @unchecked Sendable {

    /// ⚠ 自持只读连接（**不能用 `SQLiteReader.shared`** —— 它是 `@MainActor` 的，
    ///   跨线程读会 SIGSEGV）。四件套（`READWRITE` / `PRAGMA query_only` / `busy_timeout` /
    ///   串行队列）由 `ReadOnlyConnection` **一处**保证。
    ///   数据目录解析的唯一实现见 `DataDirectory.resolve()`。
    private let conn = ReadOnlyConnection(label: "LhbStore", pathProvider: DataDirectory.resolve)

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
