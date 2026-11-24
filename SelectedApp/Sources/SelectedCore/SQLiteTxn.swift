import Foundation
import SQLite3

/// 事务收尾的**共用**逻辑。
///
/// ## 为什么必须共用
/// `try? <ROLLBACK>` 是最危险的一种静默失败：回滚失败时**事务会留在连接上**，
/// 之后该连接上每一次 `BEGIN IMMEDIATE` 都报
/// `cannot start a transaction within a transaction` —— 该连接上的**所有写操作全废**，
/// 而日志只指向最初那个原始错误，看不出真凶。
///
/// "必须同构"不等于"各写一份"：只要有两份（`SQLiteWriter` / `HistoryBarStore`），
/// 下一次修 bug 必然只改到眼前那一处。故抽到这里，两边共用。
///
/// ## 判据
/// `sqlite3_get_autocommit(handle) == 0` 说明事务**仍然开着**（回滚没成功）。
/// 此时**必须丢弃连接**——但连接是各模块自持的（`SQLiteWriter.db` / `HistoryDB.handle`），
/// 所以本函数只**判定**，丢弃动作由调用方做（见返回值语义）。
enum SQLiteTxn {

    /// 回滚当前事务。
    ///
    /// - Returns: `true` = **事务仍残留在连接上，调用方必须丢弃该连接**；
    ///            `false` = 事务已结束（回滚成功，或失败但 autocommit 已恢复），连接可继续用。
    ///
    /// ⚠ 调用方在拿到 `true` 后**不能**去调 `close()` / `reset()` 这类
    /// "内部是 `queue.sync`"的方法——那时已经在该串行队列上，嵌套同步 = 死锁。
    /// 正确做法是直接操作自己持有的句柄字段（本项目两处调用点都提供了这种入口）。
    @discardableResult
    static func rollbackOrDiscard(_ handle: OpaquePointer, error: Error) -> Bool {
        do {
            try run(handle, "ROLLBACK")
            return false
        } catch let rollbackError {
            if mustDiscardConnection(afterFailedRollback: sqlite3_get_autocommit(handle) == 0) {
                NSLog("[ERROR] ROLLBACK 失败：%@ —— 事务残留在连接上，调用方应丢弃该连接重建",
                      String(describing: rollbackError))
                return true
            }
            NSLog("[ERROR] ROLLBACK 失败（但事务已结束）：%@",
                  String(describing: rollbackError))
            return false
        }
    }

    /// 判定：回滚失败后，**事务是否仍残留在连接上**（= 必须丢弃连接）。
    ///
    /// - Parameter inTransaction: 回滚失败那一刻 `sqlite3_get_autocommit(handle) == 0` 是否成立。
    ///
    /// ⚠ 抽成**纯函数**是为了能被 `swift test` 覆盖**两个方向**：
    ///   "ROLLBACK 失败且事务残留"的路径无法在单测里稳定复现（macOS 自带 libsqlite3 上，
    ///   未 finalize 的语句不会挡住 `ROLLBACK`），所以直接验**判据**——
    ///   会出错的是判据方向（"总是丢连接" vs "只在事务残留时丢"），
    ///   而不是那一行 `sqlite3_get_autocommit` 的调用。
    static func mustDiscardConnection(afterFailedRollback inTransaction: Bool) -> Bool {
        inTransaction
    }

    /// 执行单条无绑定参数的语句（`ROLLBACK` 用）。
    ///
    /// 与 `SQLiteWriter.run` 同口径（`sqlite3_exec` + `SQLiteWriteError`），
    /// 但那是实例方法且为 `private`，无法跨文件复用。
    private static func run(_ handle: OpaquePointer, _ sql: String) throws {
        var errmsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &errmsg)
        if rc != SQLITE_OK {
            let msg = errmsg.map { String(cString: $0) } ?? "rc=\(rc)"
            sqlite3_free(errmsg)
            throw SQLiteWriteError(message: "\(sql) 失败：\(msg)")
        }
    }
}
