import Foundation
import SQLite3

/// 证券主列表缓存（库 `securities` 表）。
///
/// 为什么入库：列表缓存若是文件，原子写 / `.tmp` / 损坏回落三套逻辑要在读写两侧各维护
/// 一份，任何一侧漏改就是"读者看到半截 JSON 后静默回落基线，等于白刷一次列表"。
/// 迁库后读写共用一张表，日期随行存储（整表替换式写入，同批行日期必然一致），
/// `code` 主键天然可索引。
///
/// · 读：`SELECT ... ORDER BY code`（返回顺序确定）
/// · 写：**整表替换**（DELETE + INSERT 单事务）—— 退市/更名的股票若只 upsert 会永远留在表里
///
/// ⚠ 表为空（新库/断网）时仍有随包基线兜底（fetchStockList 第 4 层），不会丢功能。
final public class SecuritiesCache: @unchecked Sendable {
    public static let shared = SecuritiesCache()

    /// ⚠ 自持只读连接（**不能用 `SQLiteReader.shared`** —— 它是 `@MainActor` 的，
    ///   跨线程读会 SIGSEGV）。连接的生命周期 / 锁策略 / 那四件套由 `ReadOnlyConnection` 保证。
    private let conn = ReadOnlyConnection(label: "SecuritiesCache", pathProvider: DataDirectory.resolve)

    private init() {}

    // MARK: - 读

    /// 读缓存 → (缓存日期, [{code,name,market}])；空表/读失败返回 (nil, [])
    public func load() -> (date: String?, list: [[String: Any]]) {
        var date: String?
        // ⚠ 表不存在（老库未跑建库/迁移）时 prepare 失败 → `query` 记日志并返回空，由调用方走兜底
        let out = conn.query("SELECT code, name, market, cache_date FROM securities ORDER BY code") { st in
            if date == nil { date = SQLiteColumn.textOrNil(st, 3) }
            return ["code": SQLiteColumn.text(st, 0),
                    "name": SQLiteColumn.text(st, 1),
                    "market": SQLiteColumn.int(st, 2)]
        }
        return (date, out)
    }

    // MARK: - 写

    /// 整表替换式写缓存（DELETE + INSERT 单事务）。失败抛出（调用方记 cache_write_error）
    public func replace(date: String, list: [[String: Any]]) throws {
        // 一次 prepare、逐行重绑（原先每行一条 INSERT 都走 prepare/finalize，
        // 全市场 ~5200 行 ⇒ 每轮上万次多余编译；见 `WriteTx.executeBatch`）
        let rows: [[Any?]] = list.map { x in
            [x["code"] as? String ?? "",
             x["name"] as? String ?? "",
             (x["market"] as? Int) ?? 0,
             date]
        }
        try SQLiteWriter.shared.write { tx in
            try tx.execute("DELETE FROM securities")
            try tx.executeBatch("INSERT INTO securities(code, name, market, cache_date) VALUES(?,?,?,?)",
                                rows: rows)
        }
    }

    /// 关闭连接（测试用）
    public func close() {
        conn.close()
    }
}
