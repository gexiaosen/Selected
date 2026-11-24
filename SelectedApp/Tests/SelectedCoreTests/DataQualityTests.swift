import XCTest
@testable import SelectedCore

/// 「K 线数据质量标记」的行为契约。
///
/// `DataQuality` 是**纯诊断**（不参与判定），判定类回归**证明不了它对不对** ——
/// 判定只看判定字段。
/// 而它要抓的恰恰是最难发现的一类问题：**根数够、跨度异常**（长期停牌），
/// 数值看起来完全正常。判据写松了会漏报，写紧了会把长假误报成停牌。
final class DataQualityTests: XCTestCase {

    /// 连续工作日（跳过周末）。`2026-01-05` 是周一 —— 用固定基准，避免"哪天跑"影响结果。
    private func weekdaySeries(_ count: Int, start: String = "2026-01-05") -> [String] {
        var out: [String] = []
        var d = TradingCalendar.parse(start)!
        while out.count < count {
            if TradingCalendar.pythonWeekday(d) < 5 { out.append(TradingCalendar.format(d)) }
            d = TradingCalendar.addDays(d, 1)
        }
        return out
    }

    /// 前 `head` 根连续工作日 → 空 `gapDays` 天 → 再 `tail` 根（用于精确控制 maxGap）
    private func seriesWithGap(head: Int, gapDays: Int, tail: Int) -> [String] {
        var days = weekdaySeries(head)
        let from = TradingCalendar.addDays(TradingCalendar.parse(days.last!)!, gapDays)
        days += weekdaySeries(tail, start: TradingCalendar.format(from))
        return days
    }

    private func bars(_ days: [String]) -> [KLineBar] {
        days.map { KLineBar(day: $0, open: 10, high: 10, low: 10, close: 10, volume: 1) }
    }

    // MARK: - ① 正常序列

    func testWeekdayOnlySeriesIsOk() {
        let q = DataQuality.evaluate(bars(weekdaySeries(20)))
        XCTAssertEqual(q.bars, 20)
        XCTAssertEqual(q.spanDays, 26, "2026-01-05(周一) ~ 2026-01-30(周五) = 26 个日历日")
        XCTAssertEqual(q.maxGapDays, 3, "正常最大间隔是周末（周五→周一）")
        XCTAssertEqual(q.level, "ok")
        XCTAssertFalse(q.isSparse)
    }

    // MARK: - ② 长期停牌（本模块要抓的核心情形）

    /// 200 根、中间空 20 天：`maxGap` 规则命中，且**跨度比仍正常** → 证明是缺口规则在起作用
    func testSingleBigGapIsSparseWhileRatioStaysNormal() {
        let days = seriesWithGap(head: 100, gapDays: 20, tail: 100)
        let q = DataQuality.evaluate(bars(days))
        XCTAssertEqual(q.bars, 200)
        XCTAssertEqual(q.maxGapDays, 20)
        XCTAssertLessThan(Double(q.spanDays) / Double(q.bars), DataQuality.sparseSpanRatio,
                          "跨度比正常 → 本次 sparse 只能由 maxGap 规则触发（否则这条测试证明不了缺口规则）")
        XCTAssertEqual(q.level, "sparse")
    }

    /// 同样 200 根、只空 10 天 → 两条规则都不命中 → ok（证明阈值不是过紧的）
    func testSmallGapStaysOk() {
        let q = DataQuality.evaluate(bars(seriesWithGap(head: 100, gapDays: 10, tail: 100)))
        XCTAssertEqual(q.maxGapDays, 10)
        XCTAssertEqual(q.level, "ok")
    }

    /// 20 根但每根隔 10 天（跨度 191 天）：`maxGap` 只有 10（不触发缺口规则）
    /// → 只能靠**跨度比**规则抓出来
    func testSparseSpanRatioFiresIndependentlyOfMaxGap() {
        var days: [String] = []
        var d = TradingCalendar.parse("2026-01-05")!
        for _ in 0..<20 {
            days.append(TradingCalendar.format(d))
            d = TradingCalendar.addDays(d, 10)
        }
        let q = DataQuality.evaluate(bars(days))
        XCTAssertEqual(q.maxGapDays, 10)
        XCTAssertLessThanOrEqual(q.maxGapDays, DataQuality.sparseMaxGapDays,
                                 "缺口规则不该命中 → 本次 sparse 只能由跨度比触发")
        XCTAssertEqual(q.spanDays, 191)
        XCTAssertEqual(q.level, "sparse")
    }

    // MARK: - ③ 日期本身不可信

    /// 有 `day` 解析不出来 → 日期都读不出的 K 线不可信，直接 sparse
    func testUnparsableDayIsSparse() {
        var days = weekdaySeries(20)
        days[7] = "not-a-date"
        let q = DataQuality.evaluate(bars(days))
        XCTAssertEqual(q.bars, 20)
        XCTAssertEqual(q.level, "sparse")
    }

    // MARK: - ④ 根数不足 / 空

    func testTooFewBarsIsSparse() {
        // 0 根 / 1 根：跨度与间隔都无从判断，如实给 0（不猜），但根数规则照常生效
        for n in [0, 1] {
            let q = DataQuality.evaluate(bars(weekdaySeries(n)))
            XCTAssertEqual(q.bars, n)
            XCTAssertEqual(q.spanDays, 0, "少于两根时跨度无从判断，应如实给 0（不猜）")
            XCTAssertEqual(q.maxGapDays, 0)
            XCTAssertEqual(q.level, "sparse")
        }
        // 5 根：跨度(5)与间隔(1)都**完全正常**，只是根数不够 ——
        // 这是"只判间隔与跨度"的实现会漏掉的一档，必须单独钉住
        let five = DataQuality.evaluate(bars(weekdaySeries(5)))
        XCTAssertEqual(five.bars, 5)
        XCTAssertEqual(five.spanDays, 5)
        XCTAssertEqual(five.maxGapDays, 1)
        XCTAssertEqual(five.level, "sparse",
                       "根数不足以支撑深度指标，门槛须与 computeDeepInfo 的 <10 一致")
    }

    // MARK: - ⑤ 展示文案

    func testWarningTextOnlyWhenSparse() {
        XCTAssertNil(DataQuality.evaluate(bars(weekdaySeries(20))).warningText,
                     "正常时不该占位")
        XCTAssertNotNil(DataQuality.evaluate(
            bars(seriesWithGap(head: 100, gapDays: 20, tail: 100))).warningText)
        XCTAssertNotNil(DataQuality.evaluate(bars(weekdaySeries(3))).warningText)
    }

    // MARK: - ⑥ 落库形态

    func testJSONShape() {
        let q = DataQuality.evaluate(bars(weekdaySeries(20)))
        XCTAssertEqual(Set(q.json.keys), ["bars", "span_days", "max_gap_days", "level"],
                       "键集必须与 ScanDataQuality.declaredKeys 一致（否则键覆盖测试/消费方会踩空）")
        XCTAssertEqual(Set(q.json.keys), ScanDataQuality.declaredKeys)
        XCTAssertEqual(q.json["bars"] as? Int, 20)
        XCTAssertEqual(q.json["level"] as? String, "ok")
    }
}
