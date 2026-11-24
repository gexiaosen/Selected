import XCTest
@testable import SelectedCore

/// `IntradayDigest`（详情页「尾盘结构」卡的派生输入）的契约测试。
///
/// 覆盖两件**真会静默出错**的事：
///   1. **挑错日子** —— 5 分钟线一次给约 5 个交易日，若固定用"今天"，周末/开盘前卡片整个空掉。
///   2. **混口径** —— `compute` 的 `close_position = (quote.price − 当日最低) ÷ (当日最高 − 当日最低)`
///      用的是**同一天**的高低点。若把"今天的实时价"配"上一个交易日的高低点"，
///      得到的是一个毫无意义的分位（实测可以 >1），**不报错、不越界**，界面上看着像个正常数字。
final class IntradayDigestTests: XCTestCase {

    // MARK: - 造数据

    /// 一个完整交易日：48 根（09:35–11:30 + 13:05–15:00，与新浪返回的形态一致）
    ///
    /// 尾盘（≥14:30）给更大量，便于断言"尾盘放量"。
    private func fullDay(_ day: String, close: Double = 11, high: Double = 12, low: Double = 10,
                         tailVolume: Double = 300, baseVolume: Double = 100) -> [MinuteBar] {
        var out: [MinuteBar] = []
        var t = 9 * 60 + 35
        while out.count < 48 {
            var b = MinuteBar()
            b.day = day
            b.time = String(format: "%02d:%02d", t / 60, t % 60)
            b.open = close; b.close = close; b.high = high; b.low = low
            b.volume = t >= 14 * 60 + 30 ? tailVolume : baseVolume
            out.append(b)
            t += 5
            if t > 11 * 60 + 30 && t < 13 * 60 + 5 { t = 13 * 60 + 5 }   // 跨午休
        }
        return out
    }

    private func quote(price: Double, volume: Double) -> EngineQuote {
        var q = EngineQuote()
        q.price = price; q.volume = volume
        return q
    }

    // MARK: - 挑哪一天

    func testPicksLatestDayAcrossMultipleDays() {
        let bars = fullDay("2026-09-17") + fullDay("2026-09-18") + fullDay("2026-09-21")
        let picked = IntradayDigest.pickLatest(bars, today: "2026-09-22", liveQuote: nil)
        XCTAssertEqual(picked?.day, "2026-09-21")
        XCTAssertEqual(picked?.bars.count, 48)
        XCTAssertTrue(picked?.bars.allSatisfy { $0.day == "2026-09-21" } ?? false)
    }

    func testNilOnEmptyOrAllJunk() {
        XCTAssertNil(IntradayDigest.pickLatest([], today: "2026-09-22", liveQuote: nil))

        // 日期或时间为空的 bar 一律不算（与 `compute` 的筛选口径一致）
        var noDay = MinuteBar(); noDay.time = "09:35"
        var noTime = MinuteBar(); noTime.day = "2026-09-21"
        XCTAssertNil(IntradayDigest.pickLatest([noDay, noTime], today: "2026-09-22", liveQuote: nil))
    }

    func testJunkBarsDoNotDecideTheDay() {
        // 混入一根"日期为空但时间正常"的脏 bar：不能被它带偏
        var junk = MinuteBar(); junk.time = "09:35"; junk.close = 999
        let bars = fullDay("2026-09-21") + [junk]
        let picked = IntradayDigest.pickLatest(bars, today: "2026-09-22", liveQuote: nil)
        XCTAssertEqual(picked?.day, "2026-09-21")
        XCTAssertEqual(picked?.bars.count, 48)
    }

    // MARK: - 盘中当天的 bar 不够 → 回退到上一个"够算"的交易日
    //
    // 上午（09:55）当天只有 6 根 bar，
    // 若"固定取最近一天"，整个上午卡片都只会显示"数据不足" ——
    // 而同一份响应里上一个交易日的**完整**尾盘结构是现成的。

    func testFallsBackToLastCompleteDayWhenTodayIsPartial() {
        let yesterday = fullDay("2026-09-21")          // 48 根
        let todayPartial = Array(fullDay("2026-09-22").prefix(6))   // 上午只走了 6 根
        let picked = IntradayDigest.pickLatest(yesterday + todayPartial,
                                               today: "2026-09-22", liveQuote: nil)
        XCTAssertEqual(picked?.day, "2026-09-21", "当天不够算时必须回退到上一个完整交易日")
        XCTAssertEqual(picked?.bars.count, 48)
        XCTAssertEqual(picked?.usedLiveQuote, false, "回退到非当日 → 不能再用实时行情")
    }

    func testUsesTodayOnceItHasEnoughBars() {
        // 下午（比如 14:00 之后）当天 bar 够了 → 用当天 + 实时行情
        let yesterday = fullDay("2026-09-21")
        let todayEnough = Array(fullDay("2026-09-22").prefix(24))   // 上午走完 = 24 根 ≥ 20
        let live = quote(price: 11.5, volume: 800)
        let picked = IntradayDigest.pickLatest(yesterday + todayEnough,
                                               today: "2026-09-22", liveQuote: live)
        XCTAssertEqual(picked?.day, "2026-09-22")
        XCTAssertEqual(picked?.usedLiveQuote, true)
    }

    func testFallsBackToLatestDayWhenNothingQualifies() {
        // 三天都不够 minBars → 退回最近一天，让调用方拿到真实 bar 数去显示"不足 N 根"
        let a = Array(fullDay("2026-09-18").prefix(5))
        let b = Array(fullDay("2026-09-21").prefix(3))
        let picked = IntradayDigest.pickLatest(a + b, today: "2026-09-22", liveQuote: nil,
                                               minBars: 20)
        XCTAssertEqual(picked?.day, "2026-09-21")
        XCTAssertEqual(picked?.bars.count, 3)
        // 顺带确认：这种情况 compute 确实算不出来（卡片显示"不足 N 根"）
        XCTAssertNil(IntradayFeaturesCalc.compute(picked!.bars, today: picked!.day,
                                                 quote: picked!.quote, minBars: 20))
    }

    func testMinBarsZeroAlignsWithComputeFallback() {
        // `compute` 对 `minBars == 0` 兜底成 20；`pickLatest` 必须**同样**兜底，
        // 否则会出现"这里挑了够算的一天、那边却算不出来"的错位
        let a = Array(fullDay("2026-09-18").prefix(5))
        let b = fullDay("2026-09-21")                 // 48 根
        let picked = IntradayDigest.pickLatest(a + b, today: "2026-09-22", liveQuote: nil,
                                               minBars: 0)
        XCTAssertEqual(picked?.day, "2026-09-21")
    }

    // MARK: - 用哪份行情

    func testUsesLiveQuoteWhenDayIsToday() {
        let bars = fullDay("2026-09-22")
        let live = quote(price: 11.8, volume: 12345)
        let picked = IntradayDigest.pickLatest(bars, today: "2026-09-22", liveQuote: live)
        XCTAssertEqual(picked?.usedLiveQuote, true)
        XCTAssertEqual(picked?.quote.price ?? 0, 11.8, accuracy: 1e-9)
        XCTAssertEqual(picked?.quote.volume ?? 0, 12345, accuracy: 1e-9)
    }

    func testRebuildsQuoteWhenDayIsNotToday() {
        let bars = fullDay("2026-09-21", close: 11)
        let stale = quote(price: 20, volume: 999_999)      // 今天的实时价，与那日无关
        let picked = IntradayDigest.pickLatest(bars, today: "2026-09-22", liveQuote: stale)
        XCTAssertEqual(picked?.day, "2026-09-21")
        XCTAssertEqual(picked?.usedLiveQuote, false)
        // 收盘价取该日末根 close；量 = 当日 bar 量之和 ÷ 100（抵消 compute 内部的 *100）
        XCTAssertEqual(picked?.quote.price ?? 0, 11, accuracy: 1e-9)
        XCTAssertEqual(picked?.quote.volume ?? 0, 62, accuracy: 1e-9)   // (41×100 + 7×300) / 100
    }

    func testRebuildsQuoteWhenTodayButLiveIsEmpty() {
        // 当日、但实时行情还没到达（price/volume 都是 0）→ 也要重建，不能用一份空行情
        let bars = fullDay("2026-09-22", close: 11)
        let empty = quote(price: 0, volume: 0)
        let picked = IntradayDigest.pickLatest(bars, today: "2026-09-22", liveQuote: empty)
        XCTAssertEqual(picked?.usedLiveQuote, false)
        XCTAssertEqual(picked?.quote.price ?? 0, 11, accuracy: 1e-9)
    }

    // MARK: - 混口径（本层存在的理由）

    func testRebuiltQuoteKeepsClosePositionInRange() throws {
        // 上一个交易日：最低 10 / 最高 12 / 收 11 → 正确的收盘位置 = (11−10)/(12−10) = 0.50
        let bars = fullDay("2026-09-21", close: 11, high: 12, low: 10)
        let stale = quote(price: 20, volume: 999_999)

        let picked = try XCTUnwrap(IntradayDigest.pickLatest(bars, today: "2026-09-22",
                                                              liveQuote: stale))
        let ok = try XCTUnwrap(IntradayFeaturesCalc.compute(picked.bars, today: picked.day,
                                                             quote: picked.quote))
        let cp = try XCTUnwrap(ok.closePosition)
        XCTAssertEqual(cp, 0.5, accuracy: 1e-9)
        XCTAssertTrue(cp >= 0 && cp <= 1, "收盘位置是分位，必须在 0–1；实际 \(cp)")

        // 反证：**直接**把"今天的实时价"配"那日的高低点"会得到 5.0 这种荒谬分位，
        // 而且 compute 不会报错 —— 这就是本层要挡的静默错误。
        let bad = try XCTUnwrap(IntradayFeaturesCalc.compute(picked.bars, today: picked.day,
                                                              quote: stale))
        XCTAssertGreaterThan(try XCTUnwrap(bad.closePosition), 1)
    }

    func testRebuiltQuoteDoesNotCorruptTailVolumeRatio() throws {
        // 尾盘放量（尾盘 300 / 平时 100）→ 尾盘量能应 > 1.00x
        let bars = fullDay("2026-09-21", close: 11, high: 12, low: 10)
        let picked = try XCTUnwrap(IntradayDigest.pickLatest(bars, today: "2026-09-22",
                                                              liveQuote: nil))
        let f = try XCTUnwrap(IntradayFeaturesCalc.compute(picked.bars, today: picked.day,
                                                            quote: picked.quote))
        let ratio = try XCTUnwrap(f.tailVolRatio)
        XCTAssertGreaterThan(ratio, 1.0, "尾盘量能是倍数，1.00x = 与全日持平")

        // 反证：用一份"量巨大"的实时行情会把全日强度抬高，倍数被压到 1 以下（假信号）
        let inflated = try XCTUnwrap(IntradayFeaturesCalc.compute(
            picked.bars, today: picked.day, quote: quote(price: 11, volume: 999_999)))
        XCTAssertLessThan(try XCTUnwrap(inflated.tailVolRatio), 1.0)
    }

    // MARK: - 与 compute 的衔接

    func testFeaturesReflectThatDayOnly() throws {
        // 两天的高低点不同：特征必须只反映被选中的那一天
        let older = fullDay("2026-09-18", close: 8, high: 9, low: 7)     // 高点 9
        let newer = fullDay("2026-09-21", close: 11, high: 12, low: 10)  // 高点 12
        let picked = try XCTUnwrap(IntradayDigest.pickLatest(older + newer, today: "2026-09-22",
                                                              liveQuote: nil))
        let f = try XCTUnwrap(IntradayFeaturesCalc.compute(picked.bars, today: picked.day,
                                                            quote: picked.quote))
        XCTAssertEqual(picked.day, "2026-09-21")
        XCTAssertEqual(f.barsToday, 48)
        XCTAssertEqual(f.tailStart, "14:30")
        XCTAssertEqual(f.lastBarTime, "15:00")
        XCTAssertEqual(f.tailWindowMin, 30)
        // 若误把两天混在一起，当日最高会算成 12 但最低会变成 7 → 收盘位置 = (11−7)/(12−7) = 0.8
        XCTAssertEqual(try XCTUnwrap(f.closePosition), 0.5, accuracy: 1e-9)
    }
}
