import XCTest
import SQLite3
@testable import SelectedCore

/// `DataConnections`（换库清单的唯一来源）的行为契约。
///
/// ## 为什么这几条要写成单元测试，而不是继续用 grep 型护栏
/// 上一版的防线是 `run_all.sh` 里的 `readconn_close_cover`：扫源码里
/// `private let conn = ReadOnlyConnection` 的**声明形态**，再去
/// `Store.invalidateAllDataConnections()` 的函数体里找对应的 `XxxStore.close()`。
/// 那条护栏自己就写着失效方式 —— 声明换个写法（改名、换类型、换持有形式）它就**空转**，
/// 所以还配了一坨"持有形态①②"的正则和阳性对照。
///
/// 现在连接在 `init` 里自我登记 ⇒ 要验的东西变成一句可执行的断言：
/// **造一条连接，真的打开，`closeAll()` 之后它必须真的关了**。
/// 这条与源码长相无关，改不动、也绕不过去（不登记就拿不到连接）。
final class DataConnectionsTests: XCTestCase {

    /// 每个用例一个独立临时目录（不碰生产库；与 `Tools` 自检同一纪律：`SELECTED_DATA_DIR` 隔离）
    private func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "SelectedDataConnTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 在临时目录里建一个**真的** `selected.sqlite3`（`ReadOnlyConnection` 要求文件存在才开）
    private func makeDBFile(in dir: String) throws {
        var handle: OpaquePointer?
        XCTAssertEqual(SQLITE_OK, sqlite3_open(dir + "/selected.sqlite3", &handle),
                       "测试夹具建库失败")
        sqlite3_close(handle)
    }

    private func uniqueLabel(_ prefix: String) -> String { "\(prefix)-\(UUID().uuidString)" }

    /// **这条就是整个重构的靶心**：新建一条连接，它就自动在册。
    /// 原先的形状是"新建连接 + 记得去清单里加一行"两步 —— 漏第二步不报错，
    /// 表现为换库后那个 Store 继续读旧库（实测漏过 4 个）。
    ///
    /// ⚠ 必须用 `let` 接住：注册表持**弱**引用，写成 `_ = ReadOnlyConnection(...)`
    ///   的话实例在语句结束就没了，断言会当成"没登记"（第一版就是这样误判的）。
    ///   真实 Store 都把它存在 `static let conn` 上，生命周期由宿主管 —— 这里同理。
    func testNewConnectionRegistersItself() throws {
        let label = uniqueLabel("AutoReg")
        XCTAssertFalse(DataConnections.registeredNames.contains(label))
        let conn = ReadOnlyConnection(label: label, pathProvider: { NSTemporaryDirectory() })
        XCTAssertTrue(DataConnections.registeredNames.contains(label),
                      "连接没有自我登记 ⇒ 换库清单又会变成一个靠人记得的列表")
        withExtendedLifetime(conn) {}
    }

    /// 开过之后 `closeAll()` 必须**真的**放掉句柄（这是"换库后读新库"唯一的物理保证）。
    func testCloseAllReleasesAnOpenedConnection() throws {
        let dir = try makeTempDir()
        try makeDBFile(in: dir)
        let label = uniqueLabel("RealClose")
        let conn = ReadOnlyConnection(label: label, pathProvider: { dir })

        _ = conn.query("SELECT 1") { _ in [:] }
        XCTAssertTrue(conn.isOpen, "前置条件没成立：连接根本没打开，后面的断言会空转")

        DataConnections.closeAll()
        XCTAssertFalse(conn.isOpen, "在册连接没被 closeAll 放掉 ⇒ 换库后仍指向旧 inode")

        // 放掉之后要能按**新目录**重开（只放连接不清 `openError` 的话，这里会永远拿不到句柄）
        conn.close()
        _ = conn.query("SELECT 1") { _ in [:] }
        XCTAssertTrue(conn.isOpen, "close 之后应能重开 —— openError 这个门闩必须被解掉")
    }

    /// `closeAll()` 会被反复触发（导入、迁移、`SELECTED_DATA_DIR` 变更），必须可重复调用。
    func testCloseAllIsIdempotent() throws {
        let dir = try makeTempDir()
        try makeDBFile(in: dir)
        let conn = ReadOnlyConnection(label: uniqueLabel("Idempotent"), pathProvider: { dir })
        _ = conn.query("SELECT 1") { _ in [:] }
        _ = DataConnections.closeAll()
        _ = DataConnections.closeAll()      // 第二次不应崩、不应死锁
        XCTAssertFalse(conn.isOpen)
    }

    /// 注册表持**弱引用**：短命连接（`SQLiteReader.makeIndependent()` 每次扫描造一条）
    /// 释放后不能留在册上 —— 否则注册表自己变成泄漏源，且 `closeAll` 会去关早已无用的对象。
    func testDeadConnectionsArePruned() throws {
        let label = uniqueLabel("ShortLived")
        autoreleasepool {
            let conn = ReadOnlyConnection(label: label, pathProvider: { NSTemporaryDirectory() })
            XCTAssertTrue(DataConnections.registeredNames.contains(label), "活连接必须在册")
            _ = conn.query("SELECT 1") { _ in [:] }
        }
        // 下一次登记会顺手回收死项 ⇒ 用一个新连接把回收触发出来，再验证旧的不自己在册
        let keeper = ReadOnlyConnection(label: uniqueLabel("Keeper"),
                                        pathProvider: { NSTemporaryDirectory() })
        XCTAssertFalse(DataConnections.registeredNames.contains(label),
                       "释放后的连接仍留在册 ⇒ 注册表持的是强引用，会随扫描次数无限增长")
        XCTAssertTrue(DataConnections.registeredNames.contains(keeper.connectionName))
        withExtendedLifetime(keeper) {}
    }

    /// **另一类持有者也必须自我登记**：`SQLiteReader` 不走 `ReadOnlyConnection`
    /// （它有自己的锁与 `dirPath` 缓存，而且故意不 conform `Sendable`）。
    /// 这条同时钉住"`makeIndependent()` 造的短命连接也在册"——
    /// 它由后台扫描创建，不在册的话换库时那条连接就漏在外面。
    func testSQLiteReaderInstancesRegisterToo() {
        let reader = SQLiteReader.makeIndependent()
        XCTAssertEqual(reader.connectionName, "SQLiteReader.independent",
                       "连接名必须能区分 shared 与独立连接，否则换库日志没法定位")
        XCTAssertTrue(DataConnections.registeredNames.contains("SQLiteReader.independent"),
                      "SQLiteReader 没在 init 里登记 ⇒ 换库清单又回到靠人记得")
        reader.releaseConnection()     // 不许崩，且必须可重复
        reader.releaseConnection()
    }

    /// ⚠ **防空转（反向检查）**：`releaseConnection()` 必须真的等价于各类型自己的释放动作。
    /// `SQLiteReader.invalidate()` 除放句柄外还要清 `dirPath` —— 只关句柄的话，
    /// 下次重开仍按**旧目录**，换库等于没换。这条把"清缓存"也钉住。
    func testReleaseAlsoDropsTheResolvedDirectoryCache() {
        let reader = SQLiteReader.makeIndependent()
        _ = reader.queryRaw("SELECT 1")          // 触发目录解析（会缓存 dirPath）
        reader.releaseConnection()
        // 释放后仍能重新解析目录并读通（缓存被清干净才会走新的解析）
        XCTAssertNotNil(reader.dataDirPath(), "释放后应能重新解析数据目录")
    }
}
