import XCTest
@testable import SelectedCore

/// `HistoryReplayMode` 与回放模式下的 `DataSources` 取数契约。
///
/// 这一组测试盯的是**两件真会静默出错的事**：
///   1. 回放开关**退出后行为必须逐字回到原样**（否则会污染实时链路）
///   2. 回放模式下的取数**绝不回落网络**（否则就是"拿今天冒充历史"且不报错）
///
/// 只测**不依赖缓存内容**的分支：缓存（`HistoryBarStore`）需要真实 SQLite 文件，
/// 由 `Tools/` 下的一次性驱动覆盖（那里把 `SELECTED_DATA_DIR` 指到临时目录）。
final class HistoryReplayModeTests: XCTestCase {

    override func setUp() {
        super.setUp()
        HistoryReplayMode.end()          // 任何用例都不该把开关漏给下一个
    }

    override func tearDown() {
        HistoryReplayMode.end()
        super.tearDown()
    }

    // MARK: - 开关本身

    func testStartsInactive() {
        XCTAssertFalse(HistoryReplayMode.isActive)
        XCTAssertNil(HistoryReplayMode.activeDay)
    }

    func testBeginActivatesAndEndClears() {
        XCTAssertTrue(HistoryReplayMode.begin("2026-01-05"))
        XCTAssertTrue(HistoryReplayMode.isActive)
        XCTAssertEqual(HistoryReplayMode.activeDay, "2026-01-05")
        HistoryReplayMode.end()
        XCTAssertFalse(HistoryReplayMode.isActive)
        XCTAssertNil(HistoryReplayMode.activeDay)
    }

    /// **不可嵌套**：已激活时 `begin` 必须失败且**不覆盖**已有回放日。
    /// 覆盖了不会报错，只会让两个回放日共用同一份全局状态、后进入的静默改写前一个。
    func testBeginRefusesNestingAndDoesNotOverwrite() {
        XCTAssertTrue(HistoryReplayMode.begin("2026-01-05"))
        XCTAssertFalse(HistoryReplayMode.begin("2026-02-06"))
        XCTAssertEqual(HistoryReplayMode.activeDay, "2026-01-05", "不能被后一次覆盖")
        HistoryReplayMode.end()
        XCTAssertTrue(HistoryReplayMode.begin("2026-02-06"), "退出后可以重新激活")
        XCTAssertEqual(HistoryReplayMode.activeDay, "2026-02-06")
    }

    func testBeginRejectsEmptyDay() {
        XCTAssertFalse(HistoryReplayMode.begin(""))
        XCTAssertFalse(HistoryReplayMode.isActive)
    }

    func testEndIsIdempotent() {
        HistoryReplayMode.end()
        HistoryReplayMode.end()
        XCTAssertFalse(HistoryReplayMode.isActive)
    }

    /// `withDay` 必须在**正常返回**与**抛错**两条路径上都退出回放 ——
    /// 漏了任一条，回放开关会永久卡在"激活"状态，之后每一次实时任务都被拒绝。
    func testWithDayRestoresOnSuccess() {
        let r = HistoryReplayMode.withDay("2026-01-05") { 42 }
        XCTAssertEqual(r, 42)
        XCTAssertFalse(HistoryReplayMode.isActive)
    }

    func testWithDayRestoresOnThrow() {
        struct Boom: Error {}
        XCTAssertThrowsError(try HistoryReplayMode.withDay("2026-01-05") { throw Boom() })
        XCTAssertFalse(HistoryReplayMode.isActive, "抛错路径也必须退出回放")
    }

    /// 已在回放中 → `withDay` **不嵌套**，直接返回 `nil`（外层状态不被破坏）
    func testWithDayDoesNotNest() {
        XCTAssertTrue(HistoryReplayMode.begin("2026-01-05"))
        let r = HistoryReplayMode.withDay("2026-02-06") { 7 }
        XCTAssertNil(r)
        XCTAssertEqual(HistoryReplayMode.activeDay, "2026-01-05", "外层回放日不变")
        HistoryReplayMode.end()
    }

    // MARK: - 自然日位移（取窗口用）

    func testShiftCalendarDaysForwardAndBackward() {
        XCTAssertEqual(HistoryReplay.shiftCalendarDays("2026-01-15", -20), "2025-12-26")
        XCTAssertEqual(HistoryReplay.shiftCalendarDays("2026-01-15", 20), "2026-02-04")
        XCTAssertEqual(HistoryReplay.shiftCalendarDays("2026-01-15", 0), "2026-01-15")
    }

    /// 跨月 / 跨年 / 闰年 2 月 —— 手算期望值
    func testShiftCalendarDaysCrossesMonthYearAndLeapDay() {
        XCTAssertEqual(HistoryReplay.shiftCalendarDays("2026-03-01", -1), "2026-02-28")
        XCTAssertEqual(HistoryReplay.shiftCalendarDays("2026-01-01", -1), "2025-12-31")
        XCTAssertEqual(HistoryReplay.shiftCalendarDays("2026-12-31", 1), "2027-01-01")
        // 2024 是闰年（本模块不依赖"当前年份"，但闰年逻辑必须对）
        XCTAssertEqual(HistoryReplay.shiftCalendarDays("2024-03-01", -1), "2024-02-29")
    }

    /// 非法输入**原样返回**，不猜、不崩
    func testShiftCalendarDaysRejectsMalformedInput() {
        XCTAssertEqual(HistoryReplay.shiftCalendarDays("", -5), "")
        XCTAssertEqual(HistoryReplay.shiftCalendarDays("2026-01", -5), "2026-01")
        XCTAssertEqual(HistoryReplay.shiftCalendarDays("not-a-date", -5), "not-a-date")
        // 越界分量必须**拦下**，不能交给 Calendar 规范化：
        //     实测 `Calendar` 会把 `2026-13-45` 变成 `2027-02-14`（然后 -5 天 = 2027-02-09）。
        //     真放行的话，用户在区间选择器里输错一位就会静默回放一段完全无关的日期。
        XCTAssertEqual(HistoryReplay.shiftCalendarDays("2026-13-45", -5), "2026-13-45")
        XCTAssertEqual(HistoryReplay.shiftCalendarDays("2026-00-10", -5), "2026-00-10")
        XCTAssertEqual(HistoryReplay.shiftCalendarDays("2026-02-30", -5), "2026-02-30", "2 月没有 30 日")
    }

    /// 取窗口要往前留够 `warmupBars` 个**交易日**；用自然日近似时必须留足余量
    /// （6 个交易日最多跨一个长假）。留少了量比会静默退化 —— 数字偏低但看起来正常。
    func testWarmupCalendarDaysLeavesRoomForHolidays() {
        XCTAssertGreaterThanOrEqual(HistoryReplay.warmupCalendarDays, HistoryReplay.warmupBars)
        // 一个长假最多约 9 天不交易 → 6 个交易日最坏要跨约 15 个自然日
        XCTAssertGreaterThanOrEqual(HistoryReplay.warmupCalendarDays, 15)
    }

    // MARK: - 回放模式下的取数

    func testRunDateFollowsReplayDay() {
        HistoryReplayMode.end()
        let before = DataSources.runDate()
        XCTAssertEqual(HistoryReplayMode.withDay("2026-01-05") { DataSources.runDate() },
                       "2026-01-05")
        XCTAssertEqual(DataSources.runDate(), before, "退出后 runDate 必须回到原样")
    }

    /// 回放日恒为交易日。
    /// 若让它走常规判定，会拿**实时**指数报价比对 `quoteDate < 今天` →
    /// 回放日的报价日期必然 < 今天 → 被判"休市" → 整轮回放当场作废。
    func testIsTradingDayIsAlwaysTrueDuringReplay() {
        HistoryReplayMode.withDay("2026-01-05") {
            let r = DataSources.isTradingDay()
            XCTAssertTrue(r.trading)
            XCTAssertEqual(r.reason, "回放 2026-01-05")
        }
        // 回放日是周末也照样为真 —— 回放日由缓存交易日历挑出，日历里就没有周末
        HistoryReplayMode.withDay("2026-01-03") {          // 2026-01-03 是周六
            XCTAssertTrue(DataSources.isTradingDay().trading)
        }
    }

    /// 分时不可回溯 → **恒空**。空会让 `IntradayFeaturesCalc.compute` 返回 nil，
    /// 进而让 `Screener` 的整个分时块（含扣分）被跳过（既有机制）。
    /// 返回任何数据都会让尾盘分时结构用上"别的一天"的分时。
    func testFiveMinuteBarsAreAlwaysEmptyDuringReplay() {
        HistoryReplayMode.withDay("2026-01-05") {
            XCTAssertTrue(DataSources.fetch5minBars("600519").isEmpty)
        }
    }

    /// 外盘无历史端点 → 恒空。照常取网络会把**今天**的美股涨跌写进历史日的大盘环境。
    func testOverseasIsEmptyDuringReplay() {
        HistoryReplayMode.withDay("2026-01-05") {
            XCTAssertTrue(DataSources.fetchOverseas().isEmpty)
        }
    }

    /// 缓存为空时：日K/指数K 都返回空，**且不回落网络**
    /// （回落的后果是"拿今天的 K 线冒充历史"而且不报错）。
    ///
    /// 这条会真的打开 `history.sqlite3`（按需建表）。它落在被 `.gitignore` 的
    /// `data/` 下，是缓存文件本身，不是测试产物。
    func testKlineIsEmptyWhenCacheHasNoData() {
        HistoryReplayMode.withDay("1990-01-05") {      // 缓存里不可能有这个日期
            XCTAssertTrue(DataSources.fetchDailyKline("600519", datalen: 65).isEmpty)
            XCTAssertTrue(DataSources.fetchIndexDailyKline(symbol: "sh000001").isEmpty)
        }
    }

    /// 指数K在回放模式下**忽略 datalen**（与 fixture 模式同规则）：
    /// `TradingCalendar` 靠长历史，只给 260 根会让历史日的 `nextTradingDay` 静默退化。
    /// 缓存为空时两者都返回空 —— 这条断言钉的是"两条分支走的是同一个查询"，
    /// 即 datalen 不参与（否则小 datalen 会先被截断）。
    func testIndexKlineIgnoresDatalenInReplayMode() {
        HistoryReplayMode.withDay("1990-01-05") {
            XCTAssertEqual(DataSources.fetchIndexDailyKline(symbol: "sh000001", datalen: 5).count,
                           DataSources.fetchIndexDailyKline(symbol: "sh000001", datalen: 9999).count)
        }
    }

    /// 「当日」的取法：正常模式 = 墙上时钟，
    /// 回放模式 = 回放日
    func testCurrentDayIsReplayAware() {
        HistoryReplayMode.end()
        XCTAssertEqual(HistoryReplayMode.currentDay, ChinaTime.day())
        HistoryReplayMode.withDay("2026-01-05") {
            XCTAssertEqual(HistoryReplayMode.currentDay, "2026-01-05")
        }
        XCTAssertEqual(HistoryReplayMode.currentDay, ChinaTime.day(), "退出后必须回到墙上时钟")
    }

    // MARK: - 整段会话（跨天占位）

    /// `isBusy` 必须在**没有 activeDay 的空隙**里也为真。
    ///
    /// 编排器每天 `begin`/`end` 两次（扫描用 D、预判/复盘用 D+1），**天与天之间
    /// `activeDay` 是空的**。调度器正好可能在那一刻触发 —— 那时若只查 `activeDay`，
    /// 就会放行一轮**实时扫描**，把实盘行情写进库，而回放正跑到一半（事后无法区分）。
    func testSessionFlagCoversTheGapBetweenDays() {
        HistoryReplayMode.end(); HistoryReplayMode.endSession()
        XCTAssertFalse(HistoryReplayMode.isBusy, "静默时不该忙")

        XCTAssertTrue(HistoryReplayMode.beginSession())
        XCTAssertFalse(HistoryReplayMode.isActive, "会话开着但此刻没有回放日")
        XCTAssertTrue(HistoryReplayMode.isRunning)
        XCTAssertTrue(HistoryReplayMode.isBusy, "⚠ 空隙里 isBusy 也必须为真（这就是它存在的理由）")

        // 空隙：某一天的两段都跑完了
        XCTAssertTrue(HistoryReplayMode.begin("2026-08-12"))
        HistoryReplayMode.end()
        XCTAssertNil(HistoryReplayMode.activeDay)
        XCTAssertTrue(HistoryReplayMode.isBusy, "一天跑完、下一天还没开始时仍必须为真")

        HistoryReplayMode.endSession()
        XCTAssertFalse(HistoryReplayMode.isBusy)
        XCTAssertFalse(HistoryReplayMode.isRunning)
    }

    /// 会话不嵌套；重复结束是空操作（便于 `defer`）
    func testSessionDoesNotNestAndEndIsIdempotent() {
        HistoryReplayMode.end(); HistoryReplayMode.endSession()
        XCTAssertTrue(HistoryReplayMode.beginSession())
        XCTAssertFalse(HistoryReplayMode.beginSession(), "已有会话 → 不覆盖")
        XCTAssertTrue(HistoryReplayMode.isRunning, "被拒绝的那次不该把会话关掉")
        HistoryReplayMode.endSession()
        HistoryReplayMode.endSession()
        XCTAssertFalse(HistoryReplayMode.isRunning)
    }

    /// 会话与回放日**互相独立**：会话开着也能正常进出单日（编排器就是这么用的）
    func testSessionAndDayAreIndependent() {
        HistoryReplayMode.end(); HistoryReplayMode.endSession()
        XCTAssertTrue(HistoryReplayMode.beginSession())
        XCTAssertTrue(HistoryReplayMode.begin("2026-08-12"))
        XCTAssertEqual(HistoryReplayMode.activeDay, "2026-08-12")
        HistoryReplayMode.end()
        XCTAssertTrue(HistoryReplayMode.isRunning, "结束单日不该结束会话")
        HistoryReplayMode.endSession()
    }
}
