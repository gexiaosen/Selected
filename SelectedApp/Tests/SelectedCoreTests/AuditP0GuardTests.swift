import XCTest
import SQLite3
@testable import SelectedCore

/// 非有限值 / 短行越界 / 连接丢弃判据这几类守卫的回归锁。
///
/// 本文件钉的都是"**删掉守卫不会让任何测试变红**"的那类约束 ——
/// 也正是本项目最忌讳的静默失效形态：不报错、不崩，只是**崩**（trap）或**静默错值**。
///
/// | 组 | 钉什么 | 删掉会怎样 |
/// |---|---|---|
/// | `numValue` / `jsonNum` | 非有限值折 `nil` | `Int(inf)` 在下游 trap（不可 catch） |
/// | `fmtInt` | 非有限值折 `"—"` | 同上，且调用点在**看板/大盘灯**链路上 |
/// | `klineRowClose` | 先校验行长度 | 短行越界 trap（腾讯改版 / 半截响应） |
/// | `mustDiscardConnection` | 判据**单向**（只在事务残留时丢连接） | 误丢连接（白重建）/ 该丢不丢（之后所有写全废） |
///
/// **已知未覆盖**（有意，别读成"都验了"）：
///   · `SQLiteTxn` 的 `true` 分支在**真实 SQL 路径**上无法在单测里稳定复现，
///     改为验其判据 `mustDiscardConnection`（两个方向）。
final class AuditP0GuardTests: XCTestCase {

    // MARK: - 非有限值不许流到 `Int(<Double>)`

    /// `numValue` / `jsonNum`：`"inf"` / `"1e400"` / `"nan"` 一律折 `nil`；正常值逐字不变。
    ///
    /// 折 `nil` 而**不是** `0`：`0` 在本项目里是有意义的值（如「资产负债率 0%」= 无负债），
    ///   折成 0 会让"没数据"与"真的是 0"混成一个结论。
    func testNumericParsersFoldNonFiniteToNil() {
        // 会得到 inf / nan 的输入
        XCTAssertNil(DataSources.numValue("inf"), "numValue(\"inf\") 必须是 nil，否则下游 Int(inf) 会 trap")
        XCTAssertNil(DataSources.numValue("1e400"), "溢出成 inf 的字符串也要折 nil")
        XCTAssertNil(DataSources.numValue("nan"), "nan 同样不许透传")
        XCTAssertNil(DataSources.jsonNum("inf"), "jsonNum 是新浪字段的主入口，同样要挡")
        XCTAssertNil(DataSources.jsonNum("-inf"))
        XCTAssertNil(DataSources.jsonNum("1e400"))

        // 正常值必须逐字不变（这条防"顺手把正常值也挡掉了"）
        XCTAssertEqual(DataSources.numValue("10.25"), 10.25)
        XCTAssertEqual(DataSources.numValue(3), 3.0)
        XCTAssertEqual(DataSources.jsonNum("0"), 0.0, "0 是有意义的值，不许被当成缺失")
        XCTAssertEqual(DataSources.jsonNum(-7.5), -7.5)
        XCTAssertNil(DataSources.jsonNum(""))
        XCTAssertNil(DataSources.jsonNum(nil))
    }

    /// `EngineIndicators.fmtInt`：非有限值折 `"—"`，不许 `String(Int(v))`（Swift trap，不可 catch）。
    ///
    /// 可达性：调用点传的是 `PyMath.roundInt(bodyRatio * 100)`，而 `PyMath.roundInt` 对
    ///   非有限值**原样返回**（`PyMath.swift:31`）—— 即上游不挡。正常 OHLC 因 `totalRange`
    ///   有 `+0.001` epsilon 不会算出非有限值，但**脏数据**（high/low 为 inf）会。
    func testFmtIntDoesNotTrapOnNonFinite() {
        XCTAssertEqual(EngineIndicators.fmtInt(.infinity), "—")
        XCTAssertEqual(EngineIndicators.fmtInt(-.infinity), "—")
        XCTAssertEqual(EngineIndicators.fmtInt(.nan), "—")
        // 正常值不变（含向零截断语义）
        XCTAssertEqual(EngineIndicators.fmtInt(3.7), "3")
        XCTAssertEqual(EngineIndicators.fmtInt(-3.7), "-3")
        XCTAssertEqual(EngineIndicators.fmtInt(0), "0")
    }

    // MARK: - 短行不许越界

    /// **判别性用例**：`row` 只有 0 / 1 / 2 个字段时，`klineRowClose` 必须返回 `nil` 而**不是崩**。
    ///
    /// 若哪天有人把 `guard row.count >= 3` 删掉（"看起来多余"），**只有这条会红** ——
    /// 而线上表现是：腾讯日K某一行半截（接口改版 / 响应被截断）→ 越界 trap →
    /// **看板与大盘灯整页崩**，且 Swift 的数组越界**不可 catch**，用户只能重启。
    func testKlineRowCloseRejectsShortRows() {
        let today = "2026-09-23"
        // 0 / 1 / 2 个字段 —— 全部必须是 nil，且**不许**越界
        XCTAssertNil(LiveQuotes.klineRowClose([], today: today), "空行")
        XCTAssertNil(LiveQuotes.klineRowClose(["2026-09-22"], today: today), "只有日期")
        XCTAssertNil(LiveQuotes.klineRowClose(["2026-09-22", "10.00"], today: today), "缺收盘价")

        // 3 个字段 = 够用（形态是 [date, open, close, ...]，只读 [0] 与 [2]）
        XCTAssertEqual(LiveQuotes.klineRowClose(["2026-09-22", "9.90", "10.00"], today: today), 10.0)

        // 其余拒绝条件
        XCTAssertNil(LiveQuotes.klineRowClose(["2026-09-23", "9.90", "10.00"], today: today),
                     "今天那一行要跳过（新浪/腾讯的口径差，见 fetch3DayTrend 注释）")
        XCTAssertNil(LiveQuotes.klineRowClose(["2026-09-22", "9.90", "0"], today: today),
                     "close <= 0 视为无效")
        XCTAssertNil(LiveQuotes.klineRowClose(["2026-09-22", "9.90", "-1"], today: today))
        XCTAssertNil(LiveQuotes.klineRowClose(["2026-09-22", "9.90", "abc"], today: today),
                     "非数值不许当成 0")

        // 长行（真实形态是 6+ 列）也要能读
        XCTAssertEqual(LiveQuotes.klineRowClose(
            ["2026-09-22", "9.90", "10.00", "10.20", "9.80", "123456"], today: today), 10.0)
    }

    // MARK: - 回滚失败只在"事务真的残留"时才要求丢连接

    /// 干净连接（无事务）上回滚失败 → 返回 `false`（**不丢连接**）。
    ///
    /// 这条防的是**反向错误**：判据若写成"ROLLBACK 报错就丢连接"，
    ///   每次 `COMMIT` 后误调回滚都会白重建一次连接（丢缓存 + 重跑建表）。
    func testRollbackOrDiscardFalseWhenNoTransactionActive() throws {
        var h: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &h), SQLITE_OK)
        guard let db = h else { return XCTFail("内存库必须能打开") }
        defer { sqlite3_close(db) }

        // autocommit 开启、没有事务 → ROLLBACK 会失败（"no transaction is active"），
        // 但事务本来就不在，所以**不该**要求丢连接。
        XCTAssertEqual(sqlite3_get_autocommit(db), 1, "前提：此刻处于 autocommit")
        let err = NSError(domain: "test", code: 1, userInfo: nil)
        XCTAssertFalse(SQLiteTxn.rollbackOrDiscard(db, error: err),
                       "没有事务残留时不许要求丢连接")

        // 连接必须仍然可用（证明没被误丢 / 误关）
        XCTAssertEqual(sqlite3_get_autocommit(db), 1)
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE t(a)", nil, nil, nil), SQLITE_OK)
    }

    /// 回滚**成功**的正常路径 → 返回 `false`，且事务确实结束了。
    func testRollbackOrDiscardFalseAfterSuccessfulRollback() throws {
        var h: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &h), SQLITE_OK)
        guard let db = h else { return XCTFail("内存库必须能打开") }
        defer { sqlite3_close(db) }

        XCTAssertEqual(sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_get_autocommit(db), 0, "前提：事务已开")
        let err = NSError(domain: "test", code: 1, userInfo: nil)
        XCTAssertFalse(SQLiteTxn.rollbackOrDiscard(db, error: err), "回滚成功不该要求丢连接")
        XCTAssertEqual(sqlite3_get_autocommit(db), 1, "回滚后必须回到 autocommit（事务真的结束了）")
    }

    /// **判据方向**的判别性用例（`true` 分支的唯一可行验法）。
    ///
    /// 会出错的不是那一行 `sqlite3_get_autocommit` 调用，而是**判据方向**：
    ///   · 写成"ROLLBACK 报错就丢连接" → 每次 `COMMIT` 后误调回滚都白重建连接（丢缓存 + 重跑建表）；
    ///   · 写成"从不丢连接" → 事务残留，之后该连接**所有写操作全废**且无日志指向真凶。
    /// 所以这里把判据单独钉死，两个方向都验。
    ///
    /// **为什么不真造"ROLLBACK 失败且事务残留"**：macOS 自带 libsqlite3 上，
    ///   未 finalize 的语句**挡不住** `ROLLBACK`，该分支在单测里无法稳定复现
    ///   （硬造只会让断言两边都是 `false` 而"空转通过"）。所以这里验判据纯函数。
    func testMustDiscardConnectionDecisionIsOneWayOnly() {
        // 事务仍残留（autocommit == 0）→ **必须**丢连接
        XCTAssertTrue(SQLiteTxn.mustDiscardConnection(afterFailedRollback: true),
                      "事务残留时必须要求丢连接 —— 否则之后该连接所有写操作全废")
        // 事务已结束（autocommit == 1）→ **不许**丢连接
        XCTAssertFalse(SQLiteTxn.mustDiscardConnection(afterFailedRollback: false),
                       "事务已结束时不许丢连接 —— 否则每次误调回滚都白重建一次连接")
    }

    /// 真实连接上的**反向**验证：回滚失败但事务已结束 → 必须返回 `false`，且连接仍然可用。
    ///
    /// 这条走的是真实 SQL 路径（不是纯函数），钉住"不会误丢连接"。
    func testRollbackOrDiscardDoesNotDiscardWhenTransactionAlreadyGone() throws {
        var h: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &h), SQLITE_OK)
        guard let db = h else { return XCTFail("内存库必须能打开") }
        defer { sqlite3_close(db) }

        // ① 先真开一个事务再手动回滚掉 → 之后 autocommit == 1
        XCTAssertEqual(sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "ROLLBACK", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_get_autocommit(db), 1)

        // ② 此刻再调 rollbackOrDiscard：ROLLBACK 会失败（"no transaction is active"），
        //    但事务本来就不在 → 必须返回 false，且连接必须仍可用。
        let err = NSError(domain: "test", code: 1, userInfo: nil)
        XCTAssertFalse(SQLiteTxn.rollbackOrDiscard(db, error: err),
                       "事务已结束时不许要求丢连接")
        XCTAssertEqual(sqlite3_get_autocommit(db), 1, "连接必须仍然处于 autocommit")
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE t(a)", nil, nil, nil), SQLITE_OK,
                       "连接必须仍然可用（证明没有被误关）")
    }
}
