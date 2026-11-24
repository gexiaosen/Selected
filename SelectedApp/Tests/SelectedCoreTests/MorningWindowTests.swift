import XCTest
@testable import SelectedCore

/// 早盘窗口。
///
/// 重点是**口径**：
/// · 量比是**跨日同窗口**对比（不是"当日已交易平均" —— 那在 10:00 恒等于 1）
/// · 窗口两端都含；没有前序日 → 量比 `nil`
/// · 残缺的前序日不参与对比（否则分母被拉低 = 假信号）
final class MorningWindowTests: XCTestCase {

    private let today = "2026-09-22"

    /// 早盘 6 根（09:35 … 10:00）—— 新浪 5 分钟线的标签是**区间末端**
    private let morningTimes = ["09:35", "09:40", "09:45", "09:50", "09:55", "10:00"]

    private func mb(_ day: String, _ time: String, close: Double, high: Double? = nil,
                    low: Double? = nil, volume: Double = 100) -> MinuteBar {
        var b = MinuteBar()
        b.day = day; b.time = time
        b.open = close; b.close = close
        b.high = high ?? close
        b.low = low ?? close
        b.volume = volume
        return b
    }

    /// 一天的早盘（6 根，收盘价按 `closes` 给；缺省全平）
    private func morning(_ day: String, closes: [Double] = [], volume: Double = 100) -> [MinuteBar] {
        let cs = closes.isEmpty ? Array(repeating: 10.0, count: morningTimes.count) : closes
        precondition(cs.count == morningTimes.count, "closes 要给 6 个")
        return zip(morningTimes, cs).map { mb(day, $0, close: $1, volume: volume) }
    }

    // MARK: - 跨日同窗口对比（本项的核心口径）

    /// 今日早盘量 300/根 vs 前 4 日各 100/根 → 量比 = 3.0
    func testVolumeRatioComparesSameWindowAcrossDays() {
        var bars = morning(today, volume: 300)
        for d in ["2026-09-21", "2026-09-18", "2026-09-17", "2026-09-15"] {
            bars += morning(d, volume: 100)
        }
        let w = IntradayFeaturesCalc.morningWindow(bars, today: today)
        XCTAssertEqual(w?.volRatioVsPriorDays ?? -1, 3.0, accuracy: 1e-9)
        XCTAssertEqual(w?.priorDays, 4, "4 个前序交易日都参与了对比")
        XCTAssertEqual(w?.bars, 6)
    }

    /// 没有前序日 → 量比 `nil`（**不猜**）；其余三项照常给
    func testNoPriorDayYieldsNilRatioButOtherFieldsStillPresent() {
        let bars = morning(today)
        let w = IntradayFeaturesCalc.morningWindow(bars, today: today)
        XCTAssertNotNil(w)
        XCTAssertNil(w?.volRatioVsPriorDays, "没有前序日 → 量比必须 nil，不能拿 1.0 冒充")
        XCTAssertEqual(w?.priorDays, 0)
        XCTAssertNotNil(w?.gainPct)
        XCTAssertNotNil(w?.volShareOfDay)
    }

    /// **残缺的前序日不参与对比** —— 只走了 1 根的窗口若算进去，分母会被拉低
    /// （表现为"今日放量"，其实是那天数据缺了）
    func testIncompletePriorDayIsExcludedFromComparison() {
        var bars = morning(today, volume: 100)
        bars += morning("2026-09-21", volume: 100)                       // 完整
        bars += [mb("2026-09-18", "09:35", close: 10, volume: 100)]      // 只 1 根 → 不算
        let w = IntradayFeaturesCalc.morningWindow(bars, today: today)
        XCTAssertEqual(w?.priorDays, 1, "残缺的那天不该被算作前序日")
        XCTAssertEqual(w?.volRatioVsPriorDays ?? -1, 1.0, accuracy: 1e-9)
    }

    /// 比 today **更晚**的日期不算"历史"（真出现时算进去会让结论反向）
    func testFutureDatedBarsAreNotTreatedAsHistory() {
        var bars = morning(today, volume: 100)
        bars += morning("2026-09-23", volume: 100)     // 未来的日期
        let w = IntradayFeaturesCalc.morningWindow(bars, today: today)
        XCTAssertEqual(w?.priorDays, 0, "晚于 today 的日期不算前序")
        XCTAssertNil(w?.volRatioVsPriorDays)
    }

    // MARK: - 窗口切法

    /// 两端都含：`09:30` 与 `10:00` 都在窗口内，`09:25` / `10:05` 不在
    func testWindowBoundsAreInclusive() {
        var bars = [
            mb(today, "09:25", close: 10, volume: 999),    // 窗口前 → 不计
            mb(today, "09:30", close: 10, volume: 100),    // 边界（含）
        ]
        bars += morning(today)
        bars.append(mb(today, "10:05", close: 10, volume: 999))   // 窗口后 → 不计
        let w = IntradayFeaturesCalc.morningWindow(bars, today: today)
        // 09:30 + 6 根早盘 = 7 根
        XCTAssertEqual(w?.bars, 7, "09:30 与 10:00 都含；09:25 / 10:05 不含")
        XCTAssertEqual(w?.lastTime, "10:00")
    }

    /// 窗口内不足两根 → `nil`（只有一根时"窗口内涨幅"无从谈起）
    func testWindowNeedsAtLeastTwoBars() {
        let bars = [mb(today, "09:35", close: 10)]
        XCTAssertNil(IntradayFeaturesCalc.morningWindow(bars, today: today))
        XCTAssertNil(IntradayFeaturesCalc.morningWindow([MinuteBar](), today: today))
    }

    /// 没有该交易日的 bar → `nil`；`from`/`to` 非法 → `nil`
    func testMissingDayOrBadWindowYieldsNil() {
        let bars = morning(today)
        XCTAssertNil(IntradayFeaturesCalc.morningWindow(bars, today: "2026-01-01"))
        XCTAssertNil(IntradayFeaturesCalc.morningWindow(bars, today: ""))
        XCTAssertNil(IntradayFeaturesCalc.morningWindow(bars, today: today,
                                                        from: "10:00", to: "09:30"),
                     "to <= from → nil")
        XCTAssertNil(IntradayFeaturesCalc.morningWindow(bars, today: today, from: "bad"))
    }

    // MARK: - 价格行为

    /// 窗口内涨幅 = 末收 ÷ 首收 − 1
    func testGainPctUsesWindowFirstAndLastClose() {
        // 首 10.0 → 末 10.5 → +5%
        let bars = morning(today, closes: [10.0, 10.1, 10.2, 10.3, 10.4, 10.5])
        let w = IntradayFeaturesCalc.morningWindow(bars, today: today)
        XCTAssertEqual(w?.gainPct ?? -1, 5.0, accuracy: 1e-9)
    }

    /// 早盘新高：窗口内最高 ≥ **当日**最高（当日高点若出现在下午，则不算）
    func testNewHighComparesAgainstWholeDay() {
        // 早盘最高 10.5，当日（含午后）最高 10.5 → 是新高
        var bars = morning(today, closes: [10.0, 10.2, 10.5, 10.3, 10.4, 10.5])
        bars.append(mb(today, "14:00", close: 10.2, high: 10.4, volume: 100))
        XCTAssertEqual(IntradayFeaturesCalc.morningWindow(bars, today: today)?.newHigh, true)

        // 午后创了更高的高点 → 早盘那根不是当日新高
        var bars2 = morning(today, closes: [10.0, 10.2, 10.5, 10.3, 10.4, 10.5])
        bars2.append(mb(today, "14:00", close: 10.8, high: 11.0, volume: 100))
        XCTAssertEqual(IntradayFeaturesCalc.morningWindow(bars2, today: today)?.newHigh, false,
                       "当日高点在午后 → 早盘不是新高")
    }

    /// 「早盘量占当日比」的分母是**今日全部** bar（含窗口之后）
    func testVolShareUsesWholeDayAsDenominator() {
        var bars = morning(today, volume: 100)          // 早盘 600
        bars.append(mb(today, "14:00", close: 10, volume: 600))   // 当日共 1200
        let w = IntradayFeaturesCalc.morningWindow(bars, today: today)
        XCTAssertEqual(w?.volShareOfDay ?? -1, 0.5, accuracy: 1e-9)
    }

    /// 窗口可换（不写死 09:30~10:00）—— 清单原话是"早盘抢筹"，但口径应当可调
    func testWindowIsConfigurable() {
        let bars = morning(today, volume: 100)
        // 09:35 ~ 09:45 → 3 根
        let w = IntradayFeaturesCalc.morningWindow(bars, today: today, from: "09:35", to: "09:45")
        XCTAssertEqual(w?.bars, 3)
        XCTAssertEqual(w?.from, "09:35")
        XCTAssertEqual(w?.to, "09:45")
        XCTAssertEqual(w?.lastTime, "09:45")
    }
}
