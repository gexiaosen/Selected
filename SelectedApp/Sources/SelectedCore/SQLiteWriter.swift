import Foundation
import SQLite3

private let SQLITE_TRANSIENT_W = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// 写库错误（写失败必须抛出，绝不静默 —— 静默写失败比崩溃更难查）
public struct SQLiteWriteError: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}

/// 写事务句柄（仅在 `SQLiteWriter.write` 的闭包内有效）
final public class WriteTx {
    private let db: OpaquePointer

    public init(db: OpaquePointer) { self.db = db }

    /// 执行写语句，返回受影响行数
    @discardableResult
    public func execute(_ sql: String, _ params: [Any?] = []) throws -> Int {
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw SQLiteWriteError(message: "执行失败 rc=\(rc)：\(sqlite3_errmsg(db).map { String(cString: $0) } ?? "") | SQL: \(sql)")
        }
        return Int(sqlite3_changes(db))
    }

    /// 批量写：**prepare 一次**，逐行 `reset` + 重绑（2026-10-16 审查 B3）。
    ///
    /// 为什么必须有：上面的 `execute` 每行都走一遍 prepare/finalize，
    /// 而全市场证券表（~5200 行）与指标快照（~5000 行/天）都是在循环里逐条调它
    /// ⇒ 每轮上万次多余的 SQL 编译。项目内已有正确写法（`HistoryBarStore` 的批量灌数），
    /// 这里把它收进 `WriteTx`，让所有批量写共用。
    ///
    /// 绑定语义与 `execute` **完全一致**（走同一个 `bind`），只是语句复用；
    /// ⚠ 因此各行参数个数必须相同（语句按同一套占位符准备）。
    @discardableResult
    public func executeBatch(_ sql: String, rows: [[Any?]]) throws -> Int {
        guard !rows.isEmpty else { return 0 }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let st = stmt else {
            throw SQLiteWriteError(message: "SQL 准备失败："
                                   + (sqlite3_errmsg(db).map { String(cString: $0) } ?? "") + " | SQL: \(sql)")
        }
        defer { sqlite3_finalize(st) }
        var affected = 0
        for (i, params) in rows.enumerated() {
            sqlite3_reset(st)
            sqlite3_clear_bindings(st)
            do {
                for (j, p) in params.enumerated() { try bind(st, Int32(j + 1), p) }
            } catch {
                throw SQLiteWriteError(message: "批量写绑定失败（第 \(i) 行）：\(error)")
            }
            let rc = sqlite3_step(st)
            guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
                throw SQLiteWriteError(message: "批量写失败 rc=\(rc)（第 \(i) 行）："
                                       + (sqlite3_errmsg(db).map { String(cString: $0) } ?? "") + " | SQL: \(sql)")
            }
            affected += Int(sqlite3_changes(db))
        }
        return affected
    }

    /// 事务内查询（读自己刚写的未提交数据）
    public func query(_ sql: String, _ params: [Any?] = []) throws -> [[String: Any]] {
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        var rows: [[String: Any]] = []
        var rc = SQLITE_OK
        while true {
            rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }        // 正常结束（没有更多行）
            if rc != SQLITE_ROW {
                // ⚠ step 中途失败 → **抛错**：把"出错"当"正常结尾"、返回半截结果且无报错是危险的。
                //   本函数已经是 `throws`，不用 `return []`（那会与"真的没有数据"同形）—— 直接抛。
                throw SQLiteWriteError(message: "查询中途失败 rc=\(rc)（已取 \(rows.count) 行，不返回半截）："
                                       + (sqlite3_errmsg(db).map { String(cString: $0) } ?? "") + " | SQL: \(sql)")
            }
            var row: [String: Any] = [:]
            for i in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, i))
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: row[name] = Int(sqlite3_column_int64(stmt, i))
                case SQLITE_FLOAT: row[name] = sqlite3_column_double(stmt, i)
                case SQLITE_TEXT:
                    row[name] = sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? ""
                case SQLITE_NULL: row[name] = NSNull()
                default:
                    if let b = sqlite3_column_blob(stmt, i) {
                        row[name] = Data(bytes: b, count: Int(sqlite3_column_bytes(stmt, i)))
                    } else { row[name] = NSNull() }
                }
            }
            rows.append(row)
        }
        return rows
    }

    /// 最后一次 INSERT 的 rowid
    public var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(db) }

    /// 当前连接上最后一次语句影响的行数
    public var changes: Int { Int(sqlite3_changes(db)) }

    private func prepare(_ sql: String, _ params: [Any?]) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteWriteError(message: "SQL 准备失败：\(sqlite3_errmsg(db).map { String(cString: $0) } ?? "") | SQL: \(sql)")
        }
        // 绑定失败必须先把语句 finalize 再抛：调用方（execute/query）的
        // `defer { sqlite3_finalize(stmt) }` 注册在**本方法返回之后** ——
        // 这里抛错时那个 defer 还没生效，语句就泄漏了（批量写里逐条累积）。
        do {
            for (i, p) in params.enumerated() {
                try bind(stmt, Int32(i + 1), p)
            }
        } catch {
            sqlite3_finalize(stmt)
            throw error
        }
        return stmt
    }

    private func bind(_ stmt: OpaquePointer?, _ idx: Int32, _ value: Any?) throws {
        guard let stmt = stmt else { return }
        guard let value = value else { sqlite3_bind_null(stmt, idx); return }
        // NSNull 是"显式空值"（JSON/字典取值链上很常见），与 nil 一样绑 NULL ——
        // 不能落到 default 抛错，否则调用方得在每个参数后面写 `?? nil` 才能写空值。
        if value is NSNull { sqlite3_bind_null(stmt, idx); return }
        // 展开 Optional（`Double?` 这类会被包装成 Any）
        let m = Mirror(reflecting: value)
        if m.displayStyle == .optional {
            if let child = m.children.first { try bind(stmt, idx, child.value) }
            else { sqlite3_bind_null(stmt, idx) }
            return
        }
        let rc: Int32
        switch value {
        case let b as Bool: rc = sqlite3_bind_int(stmt, idx, b ? 1 : 0)
        case let n as Int: rc = sqlite3_bind_int64(stmt, idx, Int64(n))
        case let n as Int64: rc = sqlite3_bind_int64(stmt, idx, n)
        case let n as Int32: rc = sqlite3_bind_int64(stmt, idx, Int64(n))
        case let d as Double: rc = sqlite3_bind_double(stmt, idx, d)
        case let f as Float: rc = sqlite3_bind_double(stmt, idx, Double(f))
        case let s as String: rc = sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT_W)
        case let d as Data: rc = sqlite3_bind_blob(stmt, idx, (d as NSData).bytes, Int32(d.count), SQLITE_TRANSIENT_W)
        default:
            throw SQLiteWriteError(message: "不支持的参数类型：\(type(of: value))（显式转换后再传，避免静默写成 NULL）")
        }
        if rc != SQLITE_OK {
            throw SQLiteWriteError(message: "参数绑定失败 idx=\(idx) rc=\(rc)")
        }
    }
}

/// SQLite 写库层。
///
/// **为什么单独一个类、不复用 SQLiteReader**：
///   · 只读层是**主线程专用**的共享连接（Apple 系统 libsqlite3 为 multi-thread 模式，
///     非 serialized —— 单连接跨线程并发使用会 SIGSEGV）
///   · 写操作会被后台线程/异步任务调用，必须有自己的连接
///
/// **线程模型**：一条**串行队列**持有唯一写连接，所有写操作 `queue.sync` 排队执行。
/// 这同时满足两个约束：单连接不跨线程并发、写操作天然串行（不会自我死锁）。
///
/// **与同库的其它写进程并发**：
///   · 打开即设 `busy_timeout=30000` → 撞锁时等待而非立刻失败
///   · 事务用 `BEGIN IMMEDIATE`（立即取写锁）→ 避免"读事务升级为写"造成的死锁窗口
///   · WAL 模式（读写不互斥；写后只读层能立即看到新数据）
final public class SQLiteWriter: @unchecked Sendable, DataConnection {
    public static let shared = SQLiteWriter()

    private let queue = DispatchQueue(label: "com.selected.sqlite.writer")
    private var db: OpaquePointer?
    private var dirPath: String?
    /// 打开失败原因（缓存，避免反复重试造成日志刷屏）
    private var openError: String?

    private init() {
        // ⚠ 登记 ⇒ 换库时写连接一定被放掉（`close()` 连 `dirPath` / `openError` 一起清，
        //   否则新库既写不进去也看不到原因）。
        DataConnections.register(self)
    }

    // MARK: - DataConnection

    public var connectionName: String { "SQLiteWriter.shared" }
    public func releaseConnection() { close() }

    // MARK: 路径（与 SQLiteReader 同一套解析规则）

    /// 数据目录解析 —— 唯一实现见 `DataDirectory.resolve()`
    private func resolveDirUnlocked() -> String { DataDirectory.resolve() }

    // MARK: 打开

    private func openLocked() throws -> OpaquePointer {
        if let db = db { return db }
        if let err = openError { throw SQLiteWriteError(message: err) }
        let dir = dirPath ?? {
            let r = resolveDirUnlocked(); dirPath = r; return r
        }()
        let path = dir + "/selected.sqlite3"
        guard FileManager.default.fileExists(atPath: path) else {
            let msg = "数据库不存在（\(path)）—— 尚未初始化，请先运行一次引擎扫描"
            openError = msg
            throw SQLiteWriteError(message: msg)
        }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let opened = handle else {
            let msg = "数据库打开失败：\(handle.map { String(cString: sqlite3_errmsg($0)) } ?? "未知")"
            if let h = handle { sqlite3_close(h) }
            // ⚠ 打开失败**不写 openError**（2026-10-16 审查 B2）：
            //   `openError` 只在显式 `close()` 时清除，把它当成"永久失败"缓存下来后，
            //   一次瞬时故障（磁盘 momentarily full、备份/杀软正占用文件、`SQLITE_BUSY`）
            //   就会让**本次会话内所有写操作**持续抛同一个错 —— 而库本身是好的，
            //   用户只能退出重开。只有"文件不存在"才是值得缓存的持久状态（上面那条）。
            NSLog("[ERROR] DB 写连接打开失败（下次调用会重试）: %@", msg)

            throw SQLiteWriteError(message: msg)
        }
        // 同库并发写所需的三项设置
        sqlite3_busy_timeout(opened, 30_000)
        exec(opened, "PRAGMA journal_mode=WAL")      // 返回一行，必须 step
        exec(opened, "PRAGMA foreign_keys=ON")
        db = opened
        return opened
    }

    private func exec(_ handle: OpaquePointer, _ sql: String) {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    // MARK: 写接口

    /// 在**单个事务**内执行写操作。闭包抛错 → 自动回滚。
    ///
    /// 同步语义：从主线程调用会阻塞到写完（通常毫秒级）。批量写请用 `writeAsync`。
    public func write<T>(_ body: (WriteTx) throws -> T) throws -> T {
        try queue.sync { try performWrite(body) }
    }

    /// 事务主体（**不含任何队列同步**）。
    ///
    /// ⚠ 必须与 `queue.sync` / `queue.async` 分离：
    ///   `writeAsync` 在 `queue.async` 的闭包内执行，若那里再调 `write`（其首行是
    ///   `queue.sync`），就是对**同一串行队列**嵌套同步 → libdispatch 必然 trap / 挂死。
    ///   两个入口共用本方法即可各自只做一次队列操作。
    private func performWrite<T>(_ body: (WriteTx) throws -> T) throws -> T {
        let handle = try openLocked()
        // BEGIN IMMEDIATE：立即取写锁。用普通 BEGIN（deferred）时，
        // 事务内第一次写才升级锁 —— 若期间另一进程已持写锁，会以 SQLITE_BUSY
        // 立刻返回（busy_timeout 对锁升级不生效），表现为随机写失败。
        try run(handle, "BEGIN IMMEDIATE")
        do {
            let result = try body(WriteTx(db: handle))
            try run(handle, "COMMIT")
            return result
        } catch {
            // ROLLBACK 失败不能静默吞：若回滚也失败，事务会**留在连接上**，
            // 下一次 `BEGIN IMMEDIATE` 直接报 "cannot start a transaction within a transaction"，
            // 之后所有写操作全废，且没有任何日志指向真凶。
            // ⚠ 判定与日志走 `SQLiteTxn.rollbackOrDiscard`，与 `HistoryBarStore.save` **共用** ——
            //   只要有两份实现，下次修 bug 必然只改到眼前那一处。
            if SQLiteTxn.rollbackOrDiscard(handle, error: error) {
                // 事务真的留在连接上了 → 就地丢弃连接，让下次写入重新打开一个干净的。
                // ⚠ 这里**不能调 close()**：它内部是 `queue.sync`，而我们已经在该队列上
                //   （嵌套同步 = 死锁）。直接操作字段即可。
                sqlite3_close(handle)
                db = nil
            }
            throw error
        }
    }

    /// 异步写（不阻塞调用线程）。
    ///
    /// 只提供 async 版本、不提供 completion 回调版：回调需要把闭包跨隔离域送回
    /// 主线程，在 Swift 6 严格并发下会触发 "sending 'completion' risks causing
    /// data races"（闭包本身必须 Sendable，而事务闭包捕获的上下文未必是）。
    /// async 版本由调用方在自身隔离域里 await，语义清晰且无该问题。
    public func writeAsync<T: Sendable>(_ body: @escaping @Sendable (WriteTx) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    // 走 performWrite 而非 write：本闭包已在 queue 上，不能再 queue.sync
                    cont.resume(returning: try self.performWrite(body))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func run(_ handle: OpaquePointer, _ sql: String) throws {
        var errmsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &errmsg)
        if rc != SQLITE_OK {
            let msg = errmsg.map { String(cString: $0) } ?? "rc=\(rc)"
            sqlite3_free(errmsg)
            throw SQLiteWriteError(message: "\(sql) 失败：\(msg)")
        }
    }

    /// 关闭连接（测试与换库用；生产路径一般不需要）
    public func close() {
        queue.sync {
            if let h = db { sqlite3_close(h) }
            db = nil
            dirPath = nil
            openError = nil
        }
    }

    /// 库文件路径（诊断用）
    public func dbPath() -> String? {
        queue.sync {
            (dirPath ?? resolveDirUnlocked()) + "/selected.sqlite3"
        }
    }
}
