import XCTest
@testable import SelectedCore

/// 六条策略判据。
///
/// 这个文件的重点是**三件容易搞错的事**：
/// · **`skipped` ≠ "未命中"** —— 日K不够 / 上市不满时该判据**根本没跑**，不能显示成"不符合"
/// · **海龟的"前 60 日最高收盘"不含末根** —— 含了就退化成 `close >= close`（恒真，永不失败）
/// · **低 ATR 的名字与条件方向相反**（"低" vs 比值 >1.1）—— 按清单字面实现，测的也是字面
final class StrategySignalsTests: XCTestCase {

    // MARK: - 夹具

    private func bar(_ close: Double, open: Double? = nil, high: Double? = nil,
                     low: Double? = nil, volume: Double = 100) -> KLineBar {
        let o = open ?? close
        return KLineBar(day: "", open: o, high: high ?? max(o, close),
                        low: low ?? min(o, close), close: close, volume: volume)
    }

    // MARK: - ① 停机坪

    /// 5 根平台 + 启动日(+10% 放量) + 2 根高开小涨
    private func flatTopFixture(secondOpen: Double = 11.2, secondClose: Double = 11.5,
                               launchClose: Double = 11.0) -> [KLineBar] {
        var b = (0..<5).map { _ in bar(10.0, open: 10.0, volume: 100) }
        b.append(bar(launchClose, open: 10.0, volume: 250))       // 启动日：+10% 且 2.5× 量
        b.append(bar(secondClose, open: secondOpen, volume: 120)) // 次日：高开小涨
        b.append(bar(11.8, open: 11.6, volume: 110))              // 后一日：高开小涨
        return b
    }

    func testFlatTopHits() {
        let out = StrategySignals.evaluate(flatTopFixture(), listedDays: 500)
        XCTAssertTrue(out.hitKinds.contains(.flatTop))
    }

    func testFlatTopRequiresGapUp() {
        // 次日**低开**（11.1 < 启动日收盘 11.0？不 —— 取 10.9 才是低开）
        let out = StrategySignals.evaluate(flatTopFixture(secondOpen: 10.9), listedDays: 500)
        XCTAssertFalse(out.hitKinds.contains(.flatTop), "低开不该算停机坪")
    }

    /// 判别性：「小涨」有**上限**。次日从开盘再涨 7% 就不是"小涨"了。
    func testFlatTopRejectsBigFollowGain() {
        // 开 11.2、收 12.0 → 自开盘 +7.14% > 5% 上限
        let out = StrategySignals.evaluate(
            flatTopFixture(secondOpen: 11.2, secondClose: 12.0), listedDays: 500)
        XCTAssertFalse(out.hitKinds.contains(.flatTop), "次日大涨不算「小涨」")
    }

    /// 判别性：启动日涨幅用**严格大于**（9.5% 本身不算）。
    func testFlatTopLaunchGainIsStrict() {
        // 10.0 → 10.95 = 恰好 9.5%
        let out = StrategySignals.evaluate(
            flatTopFixture(launchClose: 10.95), listedDays: 500)
        XCTAssertFalse(out.hitKinds.contains(.flatTop), "9.5% 是下界（> 不是 >=）")
    }

    func testFlatTopNeedsVolume() {
        var b = flatTopFixture()
        b[5] = bar(11.0, open: 10.0, volume: 150)   // 放量倍数不足（需 ≥200）
        let out = StrategySignals.evaluate(b, listedDays: 500)
        XCTAssertFalse(out.hitKinds.contains(.flatTop))
    }

    // MARK: - ② 回踩年线

    /// 250 根平台 + 1 根突破年线 + 今日回踩缩量（共 252 根）
    private func yearLineFixture(todayClose: Double = 10.2, todayVolume: Double = 80)
        -> [KLineBar] {
        var b = (0..<250).map { _ in bar(10.0, open: 10.0, high: 10.1, low: 9.9, volume: 100) }
        b.append(bar(10.5, open: 10.0, high: 10.6, low: 9.9, volume: 200))  // 突破年线
        b.append(bar(todayClose, open: 10.5, high: todayClose + 0.1,
                     low: min(9.9, todayClose), volume: todayVolume))
        return b
    }

    func testYearLinePullbackHits() {
        let out = StrategySignals.evaluate(yearLineFixture(), listedDays: 800)
        XCTAssertTrue(out.hitKinds.contains(.yearLinePullback))
    }

    /// 判别性：**缩量**是必要条件 —— 同样的位置、放量就不算"回踩"。
    func testYearLinePullbackRequiresShrink() {
        let out = StrategySignals.evaluate(yearLineFixture(todayVolume: 300), listedDays: 800)
        XCTAssertFalse(out.hitKinds.contains(.yearLinePullback), "放量回踩不是缩量回踩")
    }

    /// 判别性：**"回踩"与"破位"是两回事** —— 跌到年线下方 5% 不该命中。
    func testYearLinePullbackRejectsBreakdown() {
        let out = StrategySignals.evaluate(yearLineFixture(todayClose: 9.5), listedDays: 800)
        XCTAssertFalse(out.hitKinds.contains(.yearLinePullback), "跌破年线不是回踩")
    }

    /// **日K不足 → `skipped`，不是"未命中"**。
    func testYearLineSkippedWhenBarsInsufficient() {
        let out = StrategySignals.evaluate(flatTopFixture(), listedDays: 500)
        XCTAssertFalse(out.hitKinds.contains(.yearLinePullback))
        XCTAssertNotNil(out.skipped[.yearLinePullback], "必须报出「没评估」而不是沉默")
        XCTAssertTrue(out.skipped[.yearLinePullback]!.contains("日K不足"))
    }

    // MARK: - ③ 突破平台

    /// 120 根平台 + 今日（MA60 落在开盘与收盘之间 + 放量）
    private func platformFixture(todayVolume: Double = 250, spikeAt: Int? = nil) -> [KLineBar] {
        var b = (0..<120).map { i -> KLineBar in
            let c = (i == spikeAt) ? 13.0 : 10.0
            return bar(c, open: 9.9, high: c + 0.2, low: 9.8, volume: 100)
        }
        b.append(bar(10.05, open: 9.9, high: 10.1, low: 9.85, volume: todayVolume))
        return b
    }

    func testPlatformBreakoutHits() {
        let out = StrategySignals.evaluate(platformFixture(), listedDays: 900)
        XCTAssertTrue(out.hitKinds.contains(.platformBreakout))
    }

    func testPlatformBreakoutNeedsVolume() {
        let out = StrategySignals.evaluate(platformFixture(todayVolume: 120), listedDays: 900)
        XCTAssertFalse(out.hitKinds.contains(.platformBreakout))
    }

    /// 判别性：**平台约束**（前期偏离 ≤ +20%）—— 前 60 根里有过 +29% 的偏离就不是平台了。
    func testPlatformRejectsPriorDeviation() {
        let out = StrategySignals.evaluate(platformFixture(spikeAt: 100), listedDays: 900)
        XCTAssertFalse(out.hitKinds.contains(.platformBreakout),
                       "前期已经涨飞了，不叫「平台」")
    }

    // MARK: - ④ 海龟交易法则

    private func turtleFixture(todayClose: Double) -> [KLineBar] {
        var b = (0..<60).map { _ in bar(10.0, open: 9.9, volume: 100) }
        b.append(bar(todayClose, open: 10.0, volume: 100))
        return b
    }

    func testTurtleHitsOnNewHigh() {
        let out = StrategySignals.evaluate(turtleFixture(todayClose: 10.5), listedDays: 900)
        XCTAssertTrue(out.hitKinds.contains(.turtleBreakout))
    }

    /// 判别性：**"前 60 日最高收盘"必须不含末根**。
    /// 若含末根，`close >= max(含自己)` 恒真 → 这条判据**永远不会失败**。
    func testTurtleExcludesTodayFromTheWindow() {
        let out = StrategySignals.evaluate(turtleFixture(todayClose: 9.99), listedDays: 900)
        XCTAssertFalse(out.hitKinds.contains(.turtleBreakout),
                       "未创新高就不该命中（含末根会退化成恒真）")
    }

    // MARK: - ⑤ 高而窄的旗形

    /// 平台（前 24~10 日最低 = 9.0）+ 抬升 + 连续两天 +10%
    private func flagFixture(secondPoleClose: Double = 15.62) -> [KLineBar] {
        var b = (0..<36).map { _ in bar(9.4, open: 9.3, high: 9.5, low: 9.2, volume: 100) }
        b += (0..<15).map { _ in bar(9.5, open: 9.4, high: 9.6, low: 9.0, volume: 100) }
        b += (0..<8).map { i in
            let c = 9.8 + Double(i) * 0.5
            return bar(c, open: c - 0.1, high: c + 0.2, low: 9.6, volume: 100)
        }
        b.append(bar(14.2, open: 13.0, high: 14.3, low: 13.0, volume: 100))
        b.append(bar(secondPoleClose, open: 14.2, high: secondPoleClose + 0.1,
                     low: 14.2, volume: 100))
        b.append(bar(17.18, open: secondPoleClose, high: 17.3, low: 15.6, volume: 100))
        return b
    }

    func testHighTightFlagHits() {
        let out = StrategySignals.evaluate(flagFixture(), listedDays: 300)
        XCTAssertTrue(out.hitKinds.contains(.highTightFlag))
    }

    /// 判别性：**旗杆必须连续两天** ≥9.5%（第二根只涨 5.6% 就不算）。
    func testHighTightFlagNeedsTwoPoleDays() {
        let out = StrategySignals.evaluate(flagFixture(secondPoleClose: 15.0), listedDays: 300)
        XCTAssertFalse(out.hitKinds.contains(.highTightFlag))
    }

    /// **上市不满 60 日 → `skipped`**（"没能力判断" ≠ "不符合"）。
    func testHighTightFlagSkippedWhenListedTooShort() {
        let out = StrategySignals.evaluate(flagFixture(), listedDays: 30)
        XCTAssertFalse(out.hitKinds.contains(.highTightFlag))
        XCTAssertNotNil(out.skipped[.highTightFlag])
        XCTAssertTrue(out.skipped[.highTightFlag]!.contains("上市不满"))
    }

    // MARK: - ⑥ 低 ATR 成长

    private func lowAtrFixture(_ closes: [Double]) -> [KLineBar] {
        closes.map { bar($0, open: $0, volume: 100) }
    }

    func testLowAtrGrowthHits() {
        let closes = [10.0, 10.2, 10.5, 10.8, 11.0, 10.9, 11.2, 11.1, 10.6, 10.4]
        let out = StrategySignals.evaluate(lowAtrFixture(closes), listedDays: 300)
        XCTAssertTrue(out.hitKinds.contains(.lowAtrGrowth))
    }

    /// 判别性：比值用**严格大于**（恰好 1.1 不算）。
    func testLowAtrRangeIsStrict() {
        let out = StrategySignals.evaluate(lowAtrFixture([10.0, 11.0]), listedDays: 300)
        XCTAssertFalse(out.hitKinds.contains(.lowAtrGrowth), "1.1 是下界（> 不是 >=）")
    }

    func testLowAtrGrowthSkippedWhenListedTooShort() {
        let closes = [10.0, 10.2, 10.5, 10.8, 11.0, 10.9, 11.2, 11.1, 10.6, 10.4]
        let out = StrategySignals.evaluate(lowAtrFixture(closes), listedDays: 100)
        XCTAssertFalse(out.hitKinds.contains(.lowAtrGrowth))
        XCTAssertNotNil(out.skipped[.lowAtrGrowth])
    }

    // MARK: - 上市天数的口径

    /// `listedDays == nil` 时**回落成"日K根数"**，且 `skipped` 文案要**写明是推断的**。
    func testNilListedDaysFallsBackToBarCountAndSaysSo() {
        let closes = [10.0, 10.2, 10.5, 10.8, 11.0, 10.9, 11.2, 11.1, 10.6, 10.4]
        let out = StrategySignals.evaluate(lowAtrFixture(closes))
        XCTAssertFalse(out.hitKinds.contains(.lowAtrGrowth))
        let why = try? XCTUnwrap(out.skipped[.lowAtrGrowth])
        XCTAssertTrue(why?.contains("按日K根数推断") ?? false,
                      "回落口径必须写在文案里，不能静默等同上市天数")
    }

    /// 同样的 10 根 bar，**显式给足上市天数**就命中 —— 证明差异只来自上市天数这一项。
    func testExplicitListedDaysFlipsTheSameFixture() {
        let closes = [10.0, 10.2, 10.5, 10.8, 11.0, 10.9, 11.2, 11.1, 10.6, 10.4]
        let bars = lowAtrFixture(closes)
        XCTAssertFalse(StrategySignals.evaluate(bars).hitKinds.contains(.lowAtrGrowth))
        XCTAssertTrue(StrategySignals.evaluate(bars, listedDays: 300)
            .hitKinds.contains(.lowAtrGrowth))
    }

    // MARK: - 集合完整性

    func testSixKindsAndTitlesAreCovered() {
        XCTAssertEqual(StrategySignals.Kind.allCases.count, 6)
        for k in StrategySignals.Kind.allCases {
            XCTAssertFalse(k.title.isEmpty, "\(k.rawValue) 缺展示名")
        }
    }

    /// 六条**互不排斥** —— 同一天可以同时命中多条（与 12 个「形状」的互斥设计相反）。
    func testKindsAreNotMutuallyExclusive() {
        // 一根大阳线同时满足海龟（创新高）与突破平台（MA60 落在开收盘之间）
        var b = (0..<60).map { _ in bar(10.0, open: 9.9, volume: 100) }
        b.append(bar(11.5, open: 9.9, volume: 300))
        let out = StrategySignals.evaluate(b, listedDays: 900)
        XCTAssertTrue(out.hitKinds.contains(.turtleBreakout))
        XCTAssertTrue(out.hitKinds.contains(.platformBreakout))
        XCTAssertGreaterThan(out.hits.count, 1, "六条策略之间不该互斥")
    }
}
