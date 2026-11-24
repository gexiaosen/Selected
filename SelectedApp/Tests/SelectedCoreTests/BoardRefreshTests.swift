import XCTest
@testable import SelectedCore

/// `BoardRefresh` 的窗口与节奏（板块页盘中刷新）。
///
/// 这里**刻意钉住"09:00–16:00 不是交易时段"这件事**：
///   项目里另有一份交易时段定义（`AlertWindow.sessionRanges` = 09:30–11:30 / 13:00–15:00），
///   两者语义不同。谁哪天"顺手统一"了，这条测试就该红。
final class BoardRefreshTests: XCTestCase {

    func testWindowIsNineToSixteen() {
        XCTAssertFalse(BoardRefresh.inWindow(minuteOfDay: 539))   // 08:59
        XCTAssertTrue(BoardRefresh.inWindow(minuteOfDay: 540))    // 09:00
        XCTAssertTrue(BoardRefresh.inWindow(minuteOfDay: 690))    // 11:30（午休起点，仍刷）
        XCTAssertTrue(BoardRefresh.inWindow(minuteOfDay: 780))    // 13:00
        XCTAssertTrue(BoardRefresh.inWindow(minuteOfDay: 900))    // 15:00（收盘，仍刷到 16:00）
        XCTAssertTrue(BoardRefresh.inWindow(minuteOfDay: 959))    // 15:59
        XCTAssertFalse(BoardRefresh.inWindow(minuteOfDay: 960))   // 16:00
    }

    func testWindowIsWiderThanTradingSession() {
        // 09:00–09:30 与 15:00–16:00 在**交易时段之外**，但必须在**刷新窗口之内**
        XCTAssertFalse(AlertWindow.inSession(minuteOfDay: 545))   // 09:05 不是交易时段
        XCTAssertTrue(BoardRefresh.inWindow(minuteOfDay: 545))    // 但要在刷新窗口内
        XCTAssertFalse(AlertWindow.inSession(minuteOfDay: 930))   // 15:30 已收盘
        XCTAssertTrue(BoardRefresh.inWindow(minuteOfDay: 930))    // 但源还在更新定稿值
    }

    func testIntervalDependsOnAppActive() {
        XCTAssertEqual(BoardRefresh.nextInterval(minuteOfDay: 600, appActive: true),
                       BoardRefresh.activeInterval)
        XCTAssertEqual(BoardRefresh.nextInterval(minuteOfDay: 600, appActive: false),
                       BoardRefresh.idleInterval)
        XCTAssertNil(BoardRefresh.nextInterval(minuteOfDay: 100, appActive: true))   // 01:40 窗口外
        XCTAssertNil(BoardRefresh.nextInterval(minuteOfDay: 1200, appActive: false)) // 20:00 窗口外
    }

    func testIdleIsSlowerThanActive() {
        XCTAssertGreaterThan(BoardRefresh.idleInterval, BoardRefresh.activeInterval,
                             "不活跃时应当**降频**（否则等于每 5 分钟打扰一次源）")
    }
}
