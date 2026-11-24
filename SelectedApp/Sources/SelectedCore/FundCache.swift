import Foundation
import SQLite3

/// 场内基金列表缓存 —— 自选页「搜索添加」按名称模糊匹配基金用
///
/// 为什么独立成表/独立缓存：`securities`（`SecuritiesCache`）是**选股扫描的 A 股票池**，
/// 混入场内基金会污染扫描池（扫描器会去给基金打分）。基金只服务于自选页的搜索/加自选，
/// 与扫描链路完全隔离。
///
/// 与 `SecuritiesCache` 同构（读=独立只读连接、写=SQLiteWriter 事务、整表替换）：
///   · 读：`SELECT ... ORDER BY code`（返回顺序 = 代码升序，与 A 股列表一致）
///   · 写：**整表替换**（DELETE + INSERT 单事务）—— 退市/清盘的基金若只 upsert 会永远留在表里
///
/// 连接管理（`READWRITE` / `query_only` / `busy_timeout` / 串行队列四件套）由
/// `ReadOnlyConnection` 一处保证，本类只负责行解码。
final public class FundCache: @unchecked Sendable {
    public static let shared = FundCache()

    /// ⚠ 自持只读连接（**不能用 `SQLiteReader.shared`** —— 它是 `@MainActor` 的，
    ///   跨线程读会 SIGSEGV）。连接的生命周期 / 锁策略 / 那四件套由 `ReadOnlyConnection` 保证。
    private let conn = ReadOnlyConnection(label: "FundCache", pathProvider: DataDirectory.resolve)

    private init() {}

    // MARK: - 读

    /// 读缓存 → (缓存日期, [{code,name,market,kind}])；空表/读失败返回 (nil, [])
    public func load() -> (date: String?, list: [[String: Any]]) {
        var date: String?
        // ⚠ 表不存在（老库未跑建库/迁移）时 prepare 失败 → `query` 记日志并返回空，
        //   由调用方触发抓取。
        let out = conn.query("SELECT code, name, market, kind, cache_date FROM funds ORDER BY code") { st in
            if date == nil { date = SQLiteColumn.textOrNil(st, 4) }
            return ["code": SQLiteColumn.text(st, 0),
                    "name": SQLiteColumn.text(st, 1),
                    "market": SQLiteColumn.int(st, 2),
                    "kind": SQLiteColumn.text(st, 3)]
        }
        return (date, out)
    }

    /// 空表判断（避免为了判空把整表读进内存）
    public func isEmpty() -> Bool {
        // ⚠ 连接不可用 / prepare 失败 → 当作**空**（调用方据此触发抓取）
        !conn.hasRows("SELECT 1 FROM funds LIMIT 1")
    }

    // MARK: - 写

    /// 整表替换式写缓存（DELETE + INSERT 单事务）。失败抛出（调用方记 fund_list_write_error）
    public func replace(date: String, list: [[String: Any]]) throws {
        try SQLiteWriter.shared.write { tx in
            try tx.execute("DELETE FROM funds")
            let rows: [[Any?]] = list.map { x in
                [x["code"] as? String ?? "",
                 x["name"] as? String ?? "",
                 (x["market"] as? Int) ?? 0,
                 x["kind"] as? String ?? "",
                 date]
            }
            try tx.executeBatch(
                "INSERT INTO funds(code, name, market, kind, cache_date) VALUES(?,?,?,?,?)",
                rows: rows)
        }
    }

    /// 关闭连接（测试用）
    public func close() {
        conn.close()
    }
}
