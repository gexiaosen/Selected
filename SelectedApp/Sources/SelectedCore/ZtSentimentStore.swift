import Foundation
import SQLite3

/// 昨日涨停表现的落库与读取（纯计算在 `ZtSentiment.swift`）。
///
/// ## 为什么是主库里的扩展表
/// 与 `limit_up_pool` / `board_heat` 同一条路：建表挂 `DBBootstrap.ensureSwiftOnlySchema`，
/// **不写进** `engine/params/db_schema_export.json`（那文件与 `SchemaExportData` 生成源
/// 字节级锁死）。
///
/// ## 为什么必须落库
/// 情绪是**当日截面统计**（昨涨停池 × 今日收盘行情），明天再算就变成"昨昨涨停"的口径了。
/// 攒历史才能看"情绪连续几天冰点/沸腾"。
///
/// ⚠ store 与纯计算分文件（历史原因：上一版 `readconn_close_cover` 护栏按**文件名**识别
/// 连接持有者。现在连接由 `DataConnections` 自动登记，那条判据已经不存在，
/// 但分开摆放仍然更好读 —— 别把它们混回去）。
public enum ZtSentimentStore {

    public static let table = "zt_sentiment"

    /// 建表 DDL（`IF NOT EXISTS` 幂等）。主键 `trade_date`：一天一行汇总。
    public static let createSQL = """
    CREATE TABLE IF NOT EXISTS zt_sentiment (
        trade_date   TEXT NOT NULL PRIMARY KEY,
        sample       INTEGER NOT NULL DEFAULT 0,
        missing      INTEGER NOT NULL DEFAULT 0,
        avg_pct      REAL NOT NULL DEFAULT 0,
        median_pct   REAL NOT NULL DEFAULT 0,
        promoted     INTEGER NOT NULL DEFAULT 0,
        loss_count   INTEGER NOT NULL DEFAULT 0,
        fetched_at   TEXT NOT NULL DEFAULT ''
    );
    """

    private static let reader = ZtSentimentReader()

    public static func close() { reader.close() }

    /// 落库（一天一行，`INSERT OR REPLACE` 可重跑）。
    @discardableResult
    public static func save(_ r: ZtSentimentResult, at stamp: String) throws -> Int {
        try SQLiteWriter.shared.write { tx in
            try tx.execute(
                "INSERT OR REPLACE INTO zt_sentiment"
                + "(trade_date, sample, missing, avg_pct, median_pct, promoted, loss_count, fetched_at)"
                + " VALUES(?,?,?,?,?,?,?,?)",
                [r.date, r.sample, r.missing, r.avgPct, r.medianPct,
                 r.promoted, r.lossCount, stamp])
            return 1
        }
    }

    public static func deleteAll() throws {
        _ = try SQLiteWriter.shared.write { tx in
            try tx.execute("DELETE FROM zt_sentiment")
        }
    }

    /// 最近 `limit` 日（**按日期升序**，供趋势迷你图）
    public static func recent(_ limit: Int = 20) -> [ZtSentimentResult] {
        guard limit > 0 else { return [] }
        let rows = reader.query(
            "SELECT * FROM zt_sentiment ORDER BY trade_date DESC LIMIT ?", [limit])
        return rows.compactMap(result).reversed()
    }

    /// 某一天的记录（看板卡按 viewDate 直查；无 → nil）
    public static func day(_ date: String) -> ZtSentimentResult? {
        guard !date.isEmpty else { return nil }
        return reader.query("SELECT * FROM zt_sentiment WHERE trade_date=?", [date])
            .first.flatMap(result)
    }

    /// 某天是否已入库
    public static func hasDay(_ date: String) -> Bool {
        guard !date.isEmpty else { return false }
        return !reader.query("SELECT 1 FROM zt_sentiment WHERE trade_date=? LIMIT 1", [date])
            .isEmpty
    }

    private static func result(_ row: [String: Any]) -> ZtSentimentResult? {
        guard let date = row["trade_date"] as? String, !date.isEmpty else { return nil }
        func i(_ k: String) -> Int {
            if let n = row[k] as? Int { return n }
            if let n = row[k] as? NSNumber { return n.intValue }
            return 0
        }
        func d(_ k: String) -> Double { Num.doubleOrZero(row[k]) }
        return ZtSentimentResult(date: date, sample: i("sample"), missing: i("missing"),
                                 avgPct: d("avg_pct"), medianPct: d("median_pct"),
                                 promoted: i("promoted"), lossCount: i("loss_count"))
    }
}

/// 私有只读连接（与 `LimitUpPoolReader` / `BoardHeatReader` 同构；
/// `SQLiteReader.shared` 主线程专用，后台任务读它会 SIGSEGV）。
private final class ZtSentimentReader: @unchecked Sendable {
    private let conn = ReadOnlyConnection(label: "ZtSentimentStore", pathProvider: DataDirectory.resolve)
    func close() { conn.close() }
    func query(_ sql: String, _ params: [Any?] = []) -> [[String: Any]] {
        conn.queryRows(sql, params)
    }
}
