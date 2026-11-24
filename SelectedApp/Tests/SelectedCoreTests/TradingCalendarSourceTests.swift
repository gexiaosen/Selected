import XCTest
@testable import SelectedCore

/// 深交所官方交易日历（`monthList`）。
///
/// 这里最危险的一条是**把"没发布"读成"整月休市"**：
/// 2027-01 及以后的月份该接口返回 `{"data":[],"nowdate":"…"}` —— HTTP 200、形状完全合法、
/// 只是没有条目。如果把它当成"这个月一天都不开盘"，节假日判定会反过来错一整天，
/// 而 `isTradingDay()` 的 fail-open 会把它折叠成"开盘"，界面上看不出任何异常。
/// 所以下面用真实响应体钉住"空 = 未知"，并让 `verdict` 在未知时**返回 nil 交回旧判据**。
final class TradingCalendarSourceTests: XCTestCase {

    /// 真实响应（2026-11-02 抓，节选：11-01 周日休、11-02..06 交易日、11-07/08 休）
    private let november = """
    {"data":[{"zrxh":1,"jybz":"0","jyrq":"2026-11-01"},{"zrxh":2,"jybz":"1","jyrq":"2026-11-02"},\
    {"zrxh":3,"jybz":"1","jyrq":"2026-11-03"},{"zrxh":4,"jybz":"1","jyrq":"2026-11-04"},\
    {"zrxh":5,"jybz":"1","jyrq":"2026-11-05"},{"zrxh":6,"jybz":"1","jyrq":"2026-11-06"},\
    {"zrxh":7,"jybz":"0","jyrq":"2026-11-07"},{"zrxh":1,"jybz":"0","jyrq":"2026-11-08"}],\
    "nowdate":"2026-11-02"}
    """

    func testParsesTradingAndClosedDays() throws {
        let cal = try XCTUnwrap(TradingCalendarSource.parse(november, month: "2026-11"))
        XCTAssertEqual(cal.entryCount, 8)
        XCTAssertEqual(cal.tradingDays, ["2026-11-02", "2026-11-03", "2026-11-04",
                                         "2026-11-05", "2026-11-06"])
        XCTAssertEqual(cal.closedDays, ["2026-11-01", "2026-11-07", "2026-11-08"])
        XCTAssertEqual(cal.verdict("2026-11-02"), true)
        XCTAssertEqual(cal.verdict("2026-11-07"), false)
        XCTAssertNil(cal.verdict("2026-11-30"), "表里没有这天 = 不知道，不是休市")
    }

    /// **判别性用例**：`data` 为空 = 该月尚未发布，必须整体判"取不到"，
    /// 而不是返回一张"整月都休市"的空表。
    func testUnpublishedMonthIsUnknownNotClosed() {
        XCTAssertNil(TradingCalendarSource.parse(#"{"data":[],"nowdate":"2026-11-02"}"#,
                                                 month: "2027-01"))
        XCTAssertNil(TradingCalendarSource.parse("{}", month: "2026-11"))
        XCTAssertNil(TradingCalendarSource.parse("不是 JSON", month: "2026-11"))
        XCTAssertNil(TradingCalendarSource.parse(#"{"data":"意外形状"}"#, month: "2026-11"))
    }

    /// `jybz` 只认 `"1"` / `"0"`；其它值（改版/缺字段）落在"未知"里，不硬归为开盘或休市。
    func testUnexpectedFlagIsNotRecorded() throws {
        let text = #"""
        {"data":[{"jybz":"1","jyrq":"2026-11-02"},{"jybz":"","jyrq":"2026-11-09"},
        {"jybz":"2","jyrq":"2026-11-10"},{"jyrq":"2026-11-11"},{"jybz":"0","jyrq":"坏日期"}]}
        """#
        let cal = try XCTUnwrap(TradingCalendarSource.parse(text, month: "2026-11"))
        XCTAssertEqual(cal.tradingDays, ["2026-11-02"])
        XCTAssertEqual(cal.closedDays, [])
        XCTAssertNil(cal.verdict("2026-11-09"))
        XCTAssertNil(cal.verdict("2026-11-10"))
    }

    // MARK: - 进 URL 的形状闸门

    func testMonthAndDayShapeGates() {
        XCTAssertTrue(TradingCalendarSource.isMonthString("2026-11"))
        XCTAssertTrue(TradingCalendarSource.isMonthString("2027-01"))
        XCTAssertFalse(TradingCalendarSource.isMonthString("2026-13"), "月份越界")
        XCTAssertFalse(TradingCalendarSource.isMonthString("2026-1"), "必须两位")
        XCTAssertFalse(TradingCalendarSource.isMonthString("202611"))
        XCTAssertFalse(TradingCalendarSource.isMonthString("２026-11"), "全角数字不许进 URL")
        // 审查 B4 同一条纪律：含 `&` 的原串会往 query 里追加参数、改变请求语义
        XCTAssertFalse(TradingCalendarSource.isMonthString("2026-11&month=2020-01"))
        XCTAssertTrue(TradingCalendarSource.isDayString("2026-11-02"))
        XCTAssertFalse(TradingCalendarSource.isDayString("2026-11-2"))
        XCTAssertFalse(TradingCalendarSource.isDayString("2026-11-0"))
        XCTAssertFalse(TradingCalendarSource.isDayString("2026-11-02x"))
        XCTAssertFalse(TradingCalendarSource.isDayString("2026-11-02&x=1"))
    }

    /// 回放 / fixture 模式**一个请求都不发**：离线快照是唯一事实来源，
    /// 结论不能取决于日历接口通不通（「同快照必同结果」）。
    func testReplayModeDoesNotFetch() {
        XCTAssertTrue(HistoryReplayMode.begin("2026-01-05"))
        defer { HistoryReplayMode.end() }
        XCTAssertNil(TradingCalendarSource.calendar(forMonth: "2026-11"))
        XCTAssertNil(TradingCalendarSource.isTradingDay("2026-11-02"))
        XCTAssertNil(TradingCalendarSource.verdict(for: Date()))
    }

    /// 表里没有的日子 = 未知（不是"某天都开过盘"），月末 31 号这种也要能如实落到 nil。
    func testDayAbsentFromTableIsUnknown() throws {
        let cal = try XCTUnwrap(TradingCalendarSource.parse(november, month: "2026-11"))
        XCTAssertNil(cal.verdict("2026-11-30"))
        XCTAssertNil(cal.verdict(""))
        XCTAssertNil(cal.verdict("2026-12-01"), "别的月份的日期不归本表管")
    }
}
