import Foundation

/// 一条**可在换库时释放**的连接。
///
/// 之所以是协议而不是让注册表直接持 `ReadOnlyConnection`：
/// 本项目有三类连接持有者，形态各不一样 —— `ReadOnlyConnection`（11 个 Store 共用）、
/// `SQLiteReader` / `SQLiteWriter`（@MainActor 契约 + 自带目录缓存）、
/// `HistoryBarStore` 的 `HistoryDB`（**读写**，且是**另一个库文件** `history.sqlite3`）。
/// 它们各自的释放动作都不同（`close()` / `invalidate()` / `reset()`），
/// 但"换库时都要放掉"这一条是共同的。
/// ⚠ **刻意不要求 `Sendable`**：`SQLiteReader` 正是靠"自己不 Sendable"让
///   `Task.detached { r.queryRaw(...) }` 这种跨线程复用同一连接的写法**编译不过**
///   （已知 SIGSEGV 形态，见该类注释）。协议一旦要求 Sendable， conform 上去就等于
///   把那条编译期防线拆掉。注册表自身用锁串行化，不依赖元素可跨线程传递。
public protocol DataConnection: AnyObject {
    /// 诊断用名字。⚠ 用**实例**给的 label 而不是类型名 —— `SQLiteReader` 会有多个实例
    /// （`shared` + 每次扫描 `makeIndependent()` 的那条），日志里必须分得开。
    var connectionName: String { get }
    /// 释放连接。**必须可重复调用**（没打开过时调它也应安全），且**线程安全**。
    func releaseConnection()
}

/// **数据连接注册表** —— 「换库时要把哪些连接放掉」的唯一来源。
///
/// ## 为什么要有这个文件（2026-10-16 审查 B8 · 连接注册表）
/// 换库（导入 / 迁移 / 改 `SELECTED_DATA_DIR`）时，所有持有连接的 Store 都要放掉旧 inode 的连接，
/// 否则**主库重开、附属库仍指旧文件** ⇒ 两套数据混着读，且没有任何报错。
/// 原先这份清单是 `Store.invalidateAllDataConnections()` 里**手写的 20 行**，
/// 而"谁持有连接"是散在 12 处声明里的另一件事 —— 两处靠人记着同步。
/// **实测漏过 4 个**（提醒规则 / 资金流 / 涨停池 / 龙虎榜），补漏后又靠一条 grep 型护栏
/// （`readconn_close_cover`）去数声明形态 —— 而那条护栏一旦代码换个写法就静默空转
/// （它自己注释里就写着这个风险，所以配了阳性对照）。
///
/// ## 现在的形状
/// 连接在**自己的 init 里登记** ⇒ 拿不到一条不在册的连接，也就不存在"忘了关"。
/// `Store.invalidateAllDataConnections()` 收缩成一句 `DataConnections.closeAll()`。
/// 行为契约由 `DataConnectionsTests` 钉（真的开、真的关、新造的连接自动在册），
/// 不再靠"扫源码声明形态"这种与代码长相绑定的判据。
///
/// ## ⚠ 注册表持**弱引用**
/// `SQLiteReader.makeIndependent()` 每次扫描造一条短命连接。持强引用会让这些连接
/// 永远留在册上（既泄漏、又让 closeAll 去关早已无用的对象），所以 entry 存 `weak`，
/// 并在每次登记/关闭时顺手回收死项。单例连接由各自宿主持有，不受影响。
public enum DataConnections {

    private struct Entry {
        let name: String
        weak var conn: DataConnection?
    }

    /// 登记动作会在任意线程发生（后台扫描里 `makeIndependent()`），所以必须自带互斥。
    private static let lock = NSLock()
    nonisolated(unsafe) private static var entries: [Entry] = []

    /// 登记一条连接。由各连接类型的 `init` 自己调用 —— **不要**在业务代码里手动调它。
    public static func register(_ conn: DataConnection) {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll { $0.conn == nil }
        entries.append(Entry(name: conn.connectionName, conn: conn))
    }

    /// 释放**所有**在册连接（换库 / 导入后调用）。
    ///
    /// ⚠ 只放连接、**不注销登记**：连接是懒重开的（下次读时按新目录再开），
    ///   放掉之后就当无事发生；注销会让重开出来的那条变成"不在册"，正是要防的回归。
    @discardableResult
    public static func closeAll() -> Int {
        lock.lock()
        let alive = entries.compactMap(\.conn)
        entries.removeAll { $0.conn == nil }
        lock.unlock()
        // 按名字排：日志在两次运行间可比对（登记序取决于首次访问序，本身不稳定）
        for c in alive.sorted(by: { $0.connectionName < $1.connectionName }) {
            c.releaseConnection()
        }
        NSLog("[NOTICE] [DataConnections] 换库：已释放 %@ 条连接（%@）",
              String(alive.count), alive.map(\.connectionName).joined(separator: "、"))
        return alive.count
    }

    /// 当前在册且仍存活的连接名（诊断与回归测试用）
    public static var registeredNames: [String] {
        lock.lock(); defer { lock.unlock() }
        return entries.compactMap(\.conn).map(\.connectionName).sorted()
    }
}
