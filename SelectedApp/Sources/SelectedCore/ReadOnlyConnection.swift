import Foundation
import SQLite3

/// 自持的**只读** SQLite 连接 —— "开连接 + 串行队列 + prepare/bind/step"的**唯一实现**。
///
/// ## 为什么必须"自持"，不能共用 `SQLiteReader.shared`
///
/// `SQLiteReader.shared` 是 `@MainActor` 的 → 从 `Task.detached` / 调度任务里读它会
/// **跨线程并发 → SIGSEGV**。所以后台读**必须**自己开一个连接。
///
/// ## 每份连接都必须做对四件事，**漏掉任何一件都是静默的**
///
/// | # | 要点 | 漏了会怎样 |
/// |---|---|---|
/// | ① | `SQLITE_OPEN_READWRITE`（**不是** `READONLY`） | WAL 的 `-shm` 索引失效时需要写权限才能重建 → **读不到 WAL 里的最新数据** |
/// | ② | `PRAGMA query_only = ON` | 真正禁写的是它（`READWRITE` 只是让 shm 可恢复）→ 读连接会**写库** |
/// | ③ | `sqlite3_busy_timeout` | 撞上写事务立刻 `SQLITE_BUSY`（不是等待） |
/// | ④ | 串行 `DispatchQueue` | 同一连接跨线程并发 → **SIGSEGV** |
///
/// 靠"各 Store 逐字复制"维持的不变量迟早会破 —— 这就是本类存在的理由。
///
/// ## 行解码：**默认一份，但可以换**
///
/// `queryRows` 提供**唯一一份**默认解码（整数→Int、文本→String、**NULL 整列跳过**）——
/// 原先 8 个 Store 各抄一份同样的 10 行，抄出了看不出来的分叉。
/// 对 NULL / BLOB 需要**别的**语义的（`SQLiteReader` 是"整列跳过"的另一份实现；
/// 几处 `*Source` 用 `NSNull()`），走 `query(_:params:decode:)` 自带闭包。
/// 强行统一所有解码会改变语义 ⇒ 本类只把**默认**收成一处，不取消逃生口。
///
/// ## ⚠ 两个 Store 有意不用本类
///
/// `HistoryBarStore` 是**读写**连接（建表 + WAL 写入，只读类不适用）；
/// `SQLiteReader` 是 @MainActor 共享连接 + `makeIndependent()` 的编译期分域（收敛会破坏契约）。
public final class ReadOnlyConnection: @unchecked Sendable {

    private let queue: DispatchQueue
    private let dbName: String
    /// 路径**懒解析**（`DataDirectory.resolve()` 在首次访问时才跑）
    private let pathProvider: () -> String
    private var db: OpaquePointer?
    private var openError: String?
    /// 最近一次**瞬时**打开失败的原因（只用于诊断日志，不作为"不再重试"的门闩）。
    private var lastOpenMessage: String?

    private let label: String

    /// - Parameters:
    ///   - label: 出错日志里用的名字（如 `"HkCache"`）
    ///   - dbName: 库文件名（如 `"selected.sqlite3"` / `"history.sqlite3"`）
    ///   - pathProvider: 数据目录的**懒**解析（每个 Store 都传 `DataDirectory.resolve`）
    public init(label: String, dbName: String = "selected.sqlite3",
                pathProvider: @escaping () -> String) {
        self.label = label
        self.dbName = dbName
        self.pathProvider = pathProvider
        self.queue = DispatchQueue(label: "com.selected.roconn.\(label)")
        // ⚠ **登记在 init 里**是这套设计的全部要点：这样"拿得到连接"与"在换库清单里"
        //   是同一件事，新增 Store 不可能只做到前者。（原先靠手写 20 行清单 + 一条 grep 护栏，
        //   实测漏过 4 个 —— 见 `DataConnections`。）
        DataConnections.register(self)
    }

    // MARK: 连接

    /// ⚠ **必须在 `queue` 上调用**（调用方一律经 `queue.sync`）—— 名字里的 `Locked` 就是这个意思。
    private func openLocked() -> OpaquePointer? {
        if let db = db { return db }
        if openError != nil { return nil }
        let path = pathProvider() + "/" + dbName
        guard FileManager.default.fileExists(atPath: path) else {
            openError = "数据库不存在：\(path)"
            return nil
        }
        var handle: OpaquePointer?
        // ① READWRITE（不是 READONLY）：WAL 的 -shm 需要写权限才能重建
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let opened = handle else {
            let why = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "未知"
            if let h = handle { sqlite3_close(h) }
            // ⚠ 瞬时打开失败**不写 openError**（2026-10-16 审查 B2）：openError 是
            //   "永久放弃重试"的门闩（只有 `close()` 会清），一次 `SQLITE_BUSY` /
            //   磁盘 momentarily full / 备份进程占用就会让这个 Store 的**所有读**
            //   在本次会话内一直返回空 —— 而库本身是好的。
            //   改记进 lastOpenMessage：诊断日志仍然看得到原因，但不拦重试。
            lastOpenMessage = "数据库打开失败：\(why)"
            return nil
        }
        // ③ 撞锁时等待而不是立刻失败
        sqlite3_busy_timeout(opened, 30_000)
        // ② 真正禁写的是这一句
        sqlite3_exec(opened, "PRAGMA query_only = ON", nil, nil, nil)
        db = opened
        return opened
    }

    /// 连接是否已打开（**不含**"打开失败"的判别 —— 那由 `query` 的返回码表达）
    public var isOpen: Bool { queue.sync { db != nil } }

    public func close() {
        queue.sync {
            if let h = db { sqlite3_close(h) }
            db = nil
            openError = nil
        }
    }

    // MARK: 读

    /// `prepare` + `bind` + `step`（**带返回码判断**）+ 逐行交给 `decode`。
    ///
    /// - Returns: 行数组。⚠ 连接不可用 / `prepare` 失败 / `step` 中途失败 → **`[]`**，
    ///   但**每一种都记 `NSLog`**（这三种与"真的没有数据"在返回值上同形，日志里必须分得开）。
    /// - Parameter decode: 一行 → 一个字典。**各 Store 自己写**（NULL 处置有意不同，见类型注释）。
    public func query(_ sql: String, _ params: [Any?] = [],
                      decode: (OpaquePointer) -> [String: Any]) -> [[String: Any]] {
        queue.sync {
            guard let handle = openLocked() else {
                NSLog("[ERROR] %@.query 连接不可用（返回空）：%@", label,
                      openError ?? lastOpenMessage ?? "未知")


                return []
            }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let st = stmt else {
                NSLog("[ERROR] %@.query prepare 失败（返回空）：%@", label,
                      String(cString: sqlite3_errmsg(handle)))
                return []
            }
            defer { sqlite3_finalize(st) }
            Self.bindAll(st, params, label: label)
            var rows: [[String: Any]] = []
            var rc = SQLITE_OK
            while true {
                rc = sqlite3_step(st)
                if rc == SQLITE_DONE { break }        // 正常结束（没有更多行）
                if rc != SQLITE_ROW {
                    // ⚠ step 中途失败 → **丢弃已取到的部分行**：
                    //   把"出错"当"正常结尾"、返回半截结果且无报错，比返回空更危险。
                    NSLog("[ERROR] %@.query step 失败 rc=%d → 丢弃已取的 %d 行（不回半截）",
                          label, rc, rows.count)
                    return []
                }
                rows.append(decode(st))
            }
            return rows
        }
    }

    /// 有没有行（`SELECT ... LIMIT 1` 这类）。⚠ 与 `query` 同口径：出错也返回 `false` + 日志。
    public func hasRows(_ sql: String, _ params: [Any?] = []) -> Bool {
        !queryRows(sql, params).isEmpty
    }

    /// **默认行解码**（`query` 的便捷形态）：整数→`Int`、浮点→`Double`、文本→`String`
    /// （NULL 文本→`""`），**NULL 列整列跳过**。
    ///
    /// 原先这 10 行解码在 8 个 Store 里各抄了一份 —— 抄出来的分叉肉眼看不出来：
    /// `IndicatorParamStore` 那份把 INTEGER 解成 `Double`（它的 `value` 列是 REAL 亲和，
    /// 那个分支其实到不了），其余 7 份解成 `Int`。语义相同、长相不同的两份代码，
    /// 评审时没人会发现其中一份在动。
    ///
    /// ⚠ **NULL 整列跳过**是刻意的，不要改成塞 `NSNull`：调用侧普遍写
    ///   `row["x"] as? Int ?? 0`，一旦有 `NSNull` 进来，`as? Int` 失败但 `?? 0` 生效 ⇒
    ///   "缺值"与"真的是 0"分不开（跳过之后 `row["x"] == nil`，两种语义都还在）。
    /// 需要别的 NULL / BLOB 语义时，用 `query(_:params:decode:)` 自带解码器 —— 本类
    /// 不强迫所有调用方共用一种解码，只是把**默认那一份**收在唯一地方。
    public func queryRows(_ sql: String, _ params: [Any?] = []) -> [[String: Any]] {
        query(sql, params) { stmt in
            var row: [String: Any] = [:]
            for i in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, i))
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: row[name] = Int(sqlite3_column_int64(stmt, i))
                case SQLITE_FLOAT: row[name] = sqlite3_column_double(stmt, i)
                case SQLITE_TEXT: row[name] = SQLiteColumn.text(stmt, i)
                // NULL / BLOB：整列跳过（理由见上面注释）
                default: continue
                }
            }
            return row
        }
    }

    // MARK: 绑定（**穷举类型**，兜底不猜）

    /// ⚠ 与 `SQLiteReader.query` / `SQLiteWriter.bind` 的**同一份**类型清单与顺序。
    ///   顺序刻意保持 `Int` 在前（`Int64` 在 64 位与 `Int` 同型），
    ///   `Bool` / `Float` / `Int32` **必须显式列**（它们不会自动桥到 `Int`/`Double`）。
    static func bindAll(_ stmt: OpaquePointer?, _ params: [Any?], label: String) {
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            guard let v = p else { sqlite3_bind_null(stmt, idx); continue }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            switch v {
            case let s as String: sqlite3_bind_text(stmt, idx, s, -1, transient)
            case let n as Int: sqlite3_bind_int64(stmt, idx, Int64(n))
            case let d as Double: sqlite3_bind_double(stmt, idx, d)
            case let b as Bool: sqlite3_bind_int64(stmt, idx, b ? 1 : 0)
            case let n as Int64: sqlite3_bind_int64(stmt, idx, n)
            case let n as Int32: sqlite3_bind_int64(stmt, idx, Int64(n))
            case let f as Float: sqlite3_bind_double(stmt, idx, Double(f))
            default:
                // ⚠ 兜底**不写文本**（那是"看起来合法的错值"），写 NULL + 可检索日志
                NSLog("[NOTICE] %@.query 不支持的参数类型 %@（占位符 %d 写 NULL）",
                      label, String(describing: type(of: v)), idx)
                sqlite3_bind_null(stmt, idx)
            }
        }
    }
}

// MARK: - DataConnection（换库清单的唯一来源）

/// 由 `init` 自动登记 ⇒ 用这个类拿连接的 Store **不可能**不在换库清单里。
/// 释放动作就是既有的 `close()`：走串行队列、可重复调用、顺带清 `openError`
/// （那是"永久放弃重试"的门闩，换库后必须解掉，否则新库也读不到）。
extension ReadOnlyConnection: DataConnection {
    public var connectionName: String { label }
    public func releaseConnection() { close() }
}

// MARK: - 行解码的三个**共用**小工具

/// 各 Store 的行解码里反复出现的三个动作。⚠ 它们是**工具**，不是"统一解码器" ——
/// 用不用、怎么组合由各 Store 自己决定（NULL 处置有意不同，见 `ReadOnlyConnection` 的注释）。
public enum SQLiteColumn {

    /// TEXT 列 → `String`（NULL → `""`）。⚠ 判 nil：OOM 等边界下 `sqlite3_column_text`
    /// 可能返回 NULL 指针，裸解引用会**崩**。
    public static func text(_ stmt: OpaquePointer?, _ i: Int32) -> String {
        sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? ""
    }

    /// TEXT 列 → `String?`（NULL → `nil`）。用于"**缺值**与空串要分开"的列（如 `cache_date`）。
    public static func textOrNil(_ stmt: OpaquePointer?, _ i: Int32) -> String? {
        sqlite3_column_text(stmt, i).map { String(cString: $0) }
    }

    public static func int(_ stmt: OpaquePointer?, _ i: Int32) -> Int {
        Int(sqlite3_column_int64(stmt, i))
    }

    public static func double(_ stmt: OpaquePointer?, _ i: Int32) -> Double {
        sqlite3_column_double(stmt, i)
    }
}
