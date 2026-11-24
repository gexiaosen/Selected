import Foundation
import SQLite3

/// 板块热度的落库与读取。
///
/// ## 为什么是主库里的 Swift-only 表
/// 与 `limit_up_pool` / `stock_fund_flows` / `stock_lhb` 同一条路：
/// 建表挂 `DBBootstrap.ensureSwiftOnlySchema`，**不写进** `engine/params/db_schema_export.json`。
///
/// ## 为什么必须落库（而不是每次现抓）
/// 板块行情是**当日时点数据**——今天的排行明天就取不回历史名次。
/// 存历史才能回答"这个板块连续热了几天"（热度趋势）
/// （对比：筹码分布能从日K重算，所以不落库）。
///
/// ## ⚠ 整日重插（不是增量）
/// 盘中板块行情一直在变，收盘后抓到的才是终态。`saveDay` 是"删掉这一天再整批插"，
/// 可安全重跑。
public enum BoardHeatStore {

    public static let table = "board_heat"

    /// 建表 DDL（`IF NOT EXISTS` 天然幂等，每次打开都跑一遍）
    ///
    /// 主键 `(trade_date, board_code)`：一天一个板块只有一行。
    /// 二级索引 `(board_code, trade_date)` 服务"按板块查历史"（`boardHistory`）；
    /// 排行页"这一天的板块按涨幅排序"已走主键索引（trade_date 在前）。
    public static let createSQL = """
    CREATE TABLE IF NOT EXISTS board_heat (
        trade_date    TEXT NOT NULL,
        board_code    TEXT NOT NULL,
        board_name    TEXT NOT NULL DEFAULT '',
        board_index   REAL NOT NULL DEFAULT 0,
        change_pct    REAL NOT NULL DEFAULT 0,
        amount        REAL NOT NULL DEFAULT 0,
        turnover_rate REAL NOT NULL DEFAULT 0,
        total_cap     REAL NOT NULL DEFAULT 0,
        main_net      REAL NOT NULL DEFAULT 0,
        up_count      INTEGER NOT NULL DEFAULT 0,
        down_count    INTEGER NOT NULL DEFAULT 0,
        flat_count    INTEGER NOT NULL DEFAULT 0,
        leader_name   TEXT NOT NULL DEFAULT '',
        leader_code   TEXT NOT NULL DEFAULT '',
        leader_market INTEGER NOT NULL DEFAULT -1,
        fetched_at    TEXT NOT NULL DEFAULT '',
        PRIMARY KEY (trade_date, board_code)
    );
    CREATE INDEX IF NOT EXISTS idx_board_heat_board ON board_heat(board_code, trade_date);
    """

    /// 索引名（自检登记用）
    public static let boardIndexName = "idx_board_heat_board"

    private static let reader = BoardHeatReader()

    /// 手动释放本 Store 的连接（换库时由 `DataConnections.closeAll()` 自动覆盖，不需要点名）。
    public static func close() {
        reader.close()
    }

    // MARK: - 写

    /// **整日重插**某一天的板块行情（先删后插，同一事务）。
    ///
    /// ⚠ 先删后插必须同事务：半截提交会留下"这天只有一半板块"——
    /// 那种数据比没有更糟（排行页照样出数，只是名次全错）。
    @discardableResult
    public static func saveDay(date: String, rows: [BoardHeatPoint],
                               at stamp: String) throws -> Int {
        guard !date.isEmpty, !rows.isEmpty else { return 0 }
        return try SQLiteWriter.shared.write { tx in
            try tx.execute("DELETE FROM board_heat WHERE trade_date=?", [date])
            let batch: [[Any?]] = rows.map { r in
                [r.date, r.boardCode, r.boardName, r.index, r.changePct,
                 r.amount, r.turnoverRate, r.totalCap, r.mainNet,
                 r.upCount, r.downCount, r.flatCount,
                 r.leaderName, r.leaderCode, r.leaderMarket, stamp]
            }
            try tx.executeBatch(
                "INSERT OR REPLACE INTO board_heat("
                + "trade_date, board_code, board_name, board_index, change_pct,"
                + " amount, turnover_rate, total_cap, main_net,"
                + " up_count, down_count, flat_count,"
                + " leader_name, leader_code, leader_market, fetched_at)"
                + " VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                rows: batch)
            return rows.count
        }
    }

    /// 清空（板块行情是可重取的公开数据，但源只给**当天**截面）
    public static func deleteAll() throws {
        _ = try SQLiteWriter.shared.write { tx in
            try tx.execute("DELETE FROM board_heat")
        }
    }

    // MARK: - 读（自持只读连接，可从任意线程调）

    /// 某天是否已入库
    public static func hasDay(_ date: String) -> Bool {
        guard !date.isEmpty else { return false }
        return !reader.query("SELECT 1 FROM board_heat WHERE trade_date=? LIMIT 1", [date])
            .isEmpty
    }

    /// 库里已有的交易日（**降序**，最近的在前）
    public static func days() -> [String] {
        reader.query("SELECT DISTINCT trade_date FROM board_heat ORDER BY trade_date DESC", [])
            .compactMap { $0["trade_date"] as? String }
    }

    /// 某一天的全部板块（**按涨跌幅降序** —— 排行页的默认排序）
    public static func dayRows(_ date: String) -> [BoardHeatPoint] {
        guard !date.isEmpty else { return [] }
        return reader.query(
            "SELECT * FROM board_heat WHERE trade_date=? ORDER BY change_pct DESC, board_code ASC",
            [date]).compactMap(point)
    }

    /// 库里最近一天（无数据 → nil）
    public static func latestDay() -> String? { days().first }

    /// 最近一次**成功抓取**的时刻（ISO 文本 `yyyy-MM-ddTHH:mm:ss`；无记录 → nil）。
    ///
    /// 用途：板块页的「盘中快照 / 收盘定稿」标记——源只给当日截面，盘中抓的是盘中值、
    /// 15:10 抓的是收盘定稿值，界面上必须能区分。
    /// ⚠ 表里**没有** `updated_at` 列 ⇒ 日志是唯一带时刻的记录。
    /// ⚠ 事件名现用 `boardheat_ok`；库里更早的行仍是旧名 `daily_ok` ⇒ **两个都认**。
    /// ⚠ `data_source_logs` 不存在时 `query` 返回空数组 ⇒ nil（与其余读路径同口径）。
    public static func lastFetchedAt() -> String? {
        reader.query("SELECT ts FROM data_source_logs WHERE source='boardheat'"
                     + " AND event IN ('boardheat_ok', 'daily_ok')"
                     + " ORDER BY ts DESC LIMIT 1", [])
            .first?["ts"] as? String
    }

    /// 某板块的最近 `limit` 个交易日（**按日期升序**，供"连续热度"）
    public static func boardHistory(boardCode: String, limit: Int = 10) -> [BoardHeatPoint] {
        guard !boardCode.isEmpty, limit > 0 else { return [] }
        return reader.query(
            "SELECT * FROM board_heat WHERE board_code=?"
            + " ORDER BY trade_date DESC LIMIT ?", [boardCode, limit])
            .compactMap(point).reversed()
    }

    // MARK: - 内部

    /// 行 → 记录（列名与 DDL 必须逐字对上，错了只会**静默读到 0**）
    private static func point(_ row: [String: Any]) -> BoardHeatPoint? {
        guard let date = row["trade_date"] as? String, !date.isEmpty,
              let code = row["board_code"] as? String, !code.isEmpty else { return nil }
        func i(_ k: String) -> Int {
            if let n = row[k] as? Int { return n }
            if let n = row[k] as? NSNumber { return n.intValue }
            return 0
        }
        func d(_ k: String) -> Double { Num.doubleOrZero(row[k]) }
        return BoardHeatPoint(
            date: date, boardCode: code,
            boardName: (row["board_name"] as? String) ?? "",
            index: d("board_index"), changePct: d("change_pct"),
            amount: d("amount"), turnoverRate: d("turnover_rate"),
            totalCap: d("total_cap"), mainNet: d("main_net"),
            upCount: i("up_count"), downCount: i("down_count"), flatCount: i("flat_count"),
            leaderName: (row["leader_name"] as? String) ?? "",
            leaderCode: (row["leader_code"] as? String) ?? "",
            leaderMarket: i("leader_market"))
    }
}

/// 板块热度的**私有只读连接**。
///
/// 存在的唯一理由：`SQLiteReader.shared` 是**主线程专用**的共享连接，
/// 而本模块的读可能被**后台任务**调用
/// → 复用它会跨线程并发用同一连接 → **SIGSEGV**。
private final class BoardHeatReader: @unchecked Sendable {

    /// ⚠ 自持只读连接。四件套（`READWRITE` / `PRAGMA query_only` / `busy_timeout` /
    ///   串行队列）由 `ReadOnlyConnection` 一处保证；数据目录解析唯一实现
    ///   `DataDirectory.resolve()`。
    private let conn = ReadOnlyConnection(label: "BoardHeatStore", pathProvider: DataDirectory.resolve)

    /// 关闭只读连接（换库时由 `DataConnections.closeAll()` 自动覆盖）。
    func close() {
        conn.close()
    }

    func query(_ sql: String, _ params: [Any?] = []) -> [[String: Any]] {
        conn.queryRows(sql, params)
    }
}
