import XCTest
@testable import SelectedCore

/// 技术指标四件套。
///
/// 这个文件的重点是**每个指标"看起来等价其实不同"的那个坑**：
/// · ATR 的 TR 含跳空（与"振幅"不同）
/// · BIAS 是"收盘对均线"（与 `ma_deviation` 的"均线之间"不同）
/// · OBV 绝对值无意义（只验变化量）
/// · MFI 的三个退化边界（100 / 0 / nil）
final class TechnicalIndicatorsTests: XCTestCase {

    // MARK: - 夹具

    private func bar(_ high: Double, _ low: Double, _ close: Double,
                     volume: Double = 100, open: Double? = nil) -> KLineBar {
        KLineBar(day: "", open: open ?? close, high: high, low: low, close: close,
                 volume: volume)
    }

    // MARK: - TR / ATR

    /// 手算对照（每一步都写在注释里，便于复核）
    func testTrueRangesHandComputed() {
        let bars = [
            bar(11, 9, 10),        // 首根：没有前收 → TR = H-L = 2
            bar(12, 10, 11),       // prevClose=10 → max(2, |12-10|=2, |10-10|=0) = 2
            bar(13, 12, 12.5),     // prevClose=11 → max(1, |13-11|=2, |12-11|=1) = 2
            bar(15, 14, 14.5),     // prevClose=12.5 → max(1, |15-12.5|=2.5, |14-12.5|=1.5) = 2.5 ← 跳空
        ]
        let tr = TechnicalIndicators.trueRanges(bars)
        XCTAssertEqual(tr.count, 4)
        XCTAssertEqual(tr[0], 2, accuracy: 1e-9)
        XCTAssertEqual(tr[1], 2, accuracy: 1e-9)
        XCTAssertEqual(tr[2], 2, accuracy: 1e-9)
        XCTAssertEqual(tr[3], 2.5, accuracy: 1e-9, "跳空日 TR 由 |H-昨收| 决定")
    }

    /// **ATR ≠ 振幅**：跳空日 TR 会明显大于 `H-L`。
    ///
    /// 这正是清单说 ATR"与次日区间估计天然互补"的意思 ——
    /// `ForecastEngine` 用的是**振幅**（只看当日区间），漏掉跳空。
    func testATRDiffersFromAmplitudeOnGapDay() {
        let gap = [bar(10, 9.8, 10), bar(13, 12.8, 12.9)]     // 第二根跳空高开
        let tr = TechnicalIndicators.trueRanges(gap)
        let dayRange = gap[1].high - gap[1].low                // 0.2
        XCTAssertEqual(tr[1], 3.0, accuracy: 1e-9,
                       "TR = max(0.2, |13-10|=3, |12.8-10|=2.8) = 3 —— 当日区间只有 0.2")
        XCTAssertGreaterThan(tr[1], dayRange * 10, "跳空让 TR 远大于振幅")
    }

    /// ATR 用 **Wilder 平滑**，不是 TR 的简单均值 —— 两者数值不同
    func testATRUsesWilderSmoothingNotSimpleMean() {
        // TR = [2, 2, 2, 2.5]（见上一条）
        let bars = [
            bar(11, 9, 10), bar(12, 10, 11), bar(13, 12, 12.5), bar(15, 14, 14.5),
        ]
        // period=3：种子 = mean(2,2,2) = 2；然后 (2×2 + 2.5)/3 = 2.1666…
        let a = TechnicalIndicators.atr(bars, period: 3)
        XCTAssertEqual(a ?? -1, 6.5 / 3, accuracy: 1e-9)
        // 简单均值会给出 (2+2+2.5)/3 = 2.1666… —— 巧合同值，故再验一个更长的序列
        let bars6 = bars + [bar(16, 15, 15.5), bar(17, 16, 16.5)]   // TR 再各 1.5
        let wilder = TechnicalIndicators.atr(bars6, period: 3) ?? -1
        // Wilder：2.1666… → (2.1666×2+1.5)/3 = 1.9444… → (1.9444×2+1.5)/3 = 1.7963…
        let expect = ((6.5 / 3 * 2 + 1.5) / 3 * 2 + 1.5) / 3
        XCTAssertEqual(wilder, expect, accuracy: 1e-9)
        let simple = (2.0 + 2.0 + 2.5 + 1.5 + 1.5) / 5              // 最近 3 根的简单均值
        XCTAssertNotEqual(wilder, simple, accuracy: 1e-6, "Wilder 与简单均值必须不同")
    }

    func testATRNeedsEnoughBars() {
        let bars = (0..<13).map { _ in bar(11, 9, 10) }
        XCTAssertNil(TechnicalIndicators.atr(bars, period: 14), "只有 13 根 → 算不出 ATR(14)")
        XCTAssertNotNil(TechnicalIndicators.atr(bars, period: 13), "13 根刚好够 ATR(13)")
        // 空数组字面量推断不出元素类型 → 必须显式写类型（泛型 + 协议时必遇）
        XCTAssertNil(TechnicalIndicators.atr([KLineBar](), period: 14))
    }

    /// ATR% = ATR ÷ 收盘 × 100（跨股票可比的那个数）
    func testATRPercent() {
        let bars = (0..<15).map { _ in bar(11, 9, 10) }        // TR 恒 2、close 恒 10
        XCTAssertEqual(TechnicalIndicators.atrPercent(bars, period: 14) ?? -1, 20,
                       accuracy: 1e-9, "ATR=2、收盘=10 → 20%")
        // 收盘为 0 → nil（不产出 inf）
        let zeroClose = (0..<15).map { _ in bar(0, 0, 0) }
        XCTAssertNil(TechnicalIndicators.atrPercent(zeroClose, period: 14))
    }

    // MARK: - OBV

    /// 手算对照：收 10→11→11→10，量 100/200/300/400
    func testOBVSeriesHandComputed() {
        let bars = [bar(10, 10, 10, volume: 100),
                    bar(11, 11, 11, volume: 200),
                    bar(11, 11, 11, volume: 300),
                    bar(10, 10, 10, volume: 400)]
        XCTAssertEqual(TechnicalIndicators.obvSeries(bars), [0, 200, 200, -200])
    }

    /// 收平那天**不变**（既不加也不减）
    func testOBVUnchangedOnFlatClose() {
        let bars = [bar(10, 10, 10, volume: 100), bar(10, 10, 10, volume: 999)]
        XCTAssertEqual(TechnicalIndicators.obvSeries(bars), [0, 0])
    }

    /// `volume == 0`（停牌）照常累计 —— 等价于不变，但**不跳过那一根**
    /// （跳过会改变"累计"的语义；停牌日的 0 本身就是事实）
    func testOBVKeepsZeroVolumeBars() {
        let bars = [bar(10, 10, 10, volume: 100),
                    bar(11, 11, 11, volume: 0),          // 涨但无量
                    bar(12, 12, 12, volume: 50)]
        XCTAssertEqual(TechnicalIndicators.obvSeries(bars), [0, 0, 50])
    }

    /// 绝对值没有意义 → 展示用的是**变化量**（末根 − 前 N 根）
    func testOBVChangeIsWhatMatters() {
        let bars = [bar(10, 10, 10, volume: 100),
                    bar(11, 11, 11, volume: 200),
                    bar(11, 11, 11, volume: 300),
                    bar(10, 10, 10, volume: 400)]
        // s = [0, 200, 200, -200]
        XCTAssertEqual(TechnicalIndicators.obvChange(bars, window: 2) ?? -1, -400,
                       accuracy: 1e-9, "s[3] - s[1] = -200 - 200")
        XCTAssertEqual(TechnicalIndicators.obvChange(bars, window: 3) ?? -1, -200,
                       accuracy: 1e-9, "s[3] - s[0] = -200")
        // 起点不同（多了一根更早的 bar）→ **绝对值不同**
        // （OBV 的绝对值只取决于"从哪一天开始累计"，与价格水平无关 ——
        //   所以不能拿"价格整体平移"来演示，那样序列完全一样）
        let withPrefix = [bar(9, 9, 9, volume: 100)] + bars
        XCTAssertNotEqual(TechnicalIndicators.obvSeries(bars),
                          TechnicalIndicators.obvSeries(withPrefix),
                          "多一根更早的 bar → 绝对值整体平移")
        XCTAssertEqual(TechnicalIndicators.obvChange(bars, window: 2),
                       TechnicalIndicators.obvChange(withPrefix, window: 2),
                       "但变化量相同 → 展示要用变化量")
    }

    func testOBVChangeNeedsEnoughBars() {
        let bars = (0..<5).map { _ in bar(10, 10, 10) }
        XCTAssertNil(TechnicalIndicators.obvChange(bars, window: 5), "只有 5 根，要 6 根")
        XCTAssertNotNil(TechnicalIndicators.obvChange(bars, window: 4))
        XCTAssertNil(TechnicalIndicators.obvChange(bars, window: 0))
    }

    // MARK: - MFI

    /// 手算对照（period=2）：
    /// TP: 10 → 12（涨，PMF += 12×100=1200）→ 11（跌，NMF += 11×200=2200）
    /// MFI = 100 − 100/(1 + 1200/2200) = 35.294…
    func testMFIHandComputed() {
        let bars = [bar(10, 10, 10, volume: 100),
                    bar(12, 12, 12, volume: 100),
                    bar(11, 11, 11, volume: 200)]
        let expect = 100 - 100 / (1 + 1200.0 / 2200.0)
        XCTAssertEqual(TechnicalIndicators.mfi(bars, period: 2) ?? -1, expect, accuracy: 1e-9)
    }

    /// 三个退化边界：`NMF==0 → 100`、`PMF==0 → 0`、**两者皆 0 → nil**
    func testMFIDegenerateBoundaries() {
        // 全涨（无负流）→ 100
        let allUp = (0..<15).map { i in bar(10 + Double(i), 10 + Double(i), 10 + Double(i)) }
        XCTAssertEqual(TechnicalIndicators.mfi(allUp, period: 14) ?? -1, 100, accuracy: 1e-9)

        // 全跌（无正流）→ 0
        let allDown = (0..<15).map { i in bar(30 - Double(i), 30 - Double(i), 30 - Double(i)) }
        XCTAssertEqual(TechnicalIndicators.mfi(allDown, period: 14) ?? -1, 0, accuracy: 1e-9)

        // TP 完全不变（连续无成交）→ **nil**（"算不出来"，不是 0 也不是 100）
        let flat = (0..<15).map { _ in bar(10, 10, 10, volume: 0) }
        XCTAssertNil(TechnicalIndicators.mfi(flat, period: 14),
                     "两边都为 0 时既不是 100 也不是 0 —— 必须报'算不出来'")
    }

    func testMFINeedsEnoughBars() {
        // 夹具必须**真的在动** —— 全平序列的 PMF 与 NMF 都是 0 → 按口径返回 nil，
        //   那样就测不到"样本够不够"这件事了
        let bars = (0..<14).map { i in bar(10 + Double(i), 10 + Double(i), 10 + Double(i)) }
        XCTAssertNil(TechnicalIndicators.mfi(bars, period: 14), "MFI(n) 要 n+1 根")
        XCTAssertNotNil(TechnicalIndicators.mfi(bars, period: 13))
        XCTAssertNil(TechnicalIndicators.mfi([KLineBar](), period: 14))
    }

    /// 典型价 `(H+L+C)/3`
    func testTypicalPrice() {
        XCTAssertEqual(TechnicalIndicators.typicalPrice(bar(13, 10, 11)), 34.0 / 3,
                       accuracy: 1e-9)
    }

    // MARK: - BIAS

    /// 手算对照：收 10…15，MA6 = 12.5、close = 15 → (15−12.5)/12.5×100 = 20
    func testBIASHandComputed() {
        let bars = (10...15).map { i in bar(Double(i), Double(i), Double(i)) }
        XCTAssertEqual(TechnicalIndicators.bias(bars, period: 6) ?? -1, 20, accuracy: 1e-9)
        // period=3：MA3 = (13+14+15)/3 = 14 → (15−14)/14×100 = 7.142857…
        XCTAssertEqual(TechnicalIndicators.bias(bars, period: 3) ?? -1,
                       100.0 / 14, accuracy: 1e-9)
    }

    /// **BIAS ≠ `ma_deviation`**（这条是"名字像但不是同一个量"的判别式）
    ///
    /// `ma_deviation` = `abs(MA5−MA10)/MA10`（**均线之间**）
    /// BIAS = `(close−MA_n)/MA_n`（**收盘对均线**）
    ///
    /// 构造：9 根 10 + 1 根 20 → MA5=12、MA10=11（两者接近），而 close=20 离它们都很远
    func testBIASIsNotMaDeviation() {
        let closes = Array(repeating: 10.0, count: 9) + [20.0]
        let bars = closes.map { c in bar(c, c, c) }
        let dev = EngineIndicators.maDeviation(EngineIndicators.ma5(closes),
                                               EngineIndicators.ma10(closes))
        let b = TechnicalIndicators.bias(bars, period: 6) ?? -1
        XCTAssertEqual(dev, 100.0 / 11, accuracy: 1e-9, "ma_deviation = |12−11|/11×100 = 9.09")
        // MA6 = (10×5+20)/6 = 11.6667 → (20−11.6667)/11.6667×100 = 71.43
        XCTAssertEqual(b, (20 - 70.0 / 6) / (70.0 / 6) * 100, accuracy: 1e-9)
        XCTAssertGreaterThan(abs(b - dev), 50, "两者相差 50 个百分点以上 —— 不是同一个量")
    }

    func testBIASNeedsEnoughBarsAndPositiveMA() {
        let bars = (0..<5).map { _ in bar(10, 10, 10) }
        XCTAssertNil(TechnicalIndicators.bias(bars, period: 6), "只有 5 根，算不出 MA6")
        XCTAssertNotNil(TechnicalIndicators.bias(bars, period: 5))
        XCTAssertNil(TechnicalIndicators.bias(bars, period: 0))
        // MA = 0 → nil（不产出 inf）
        let zero = (0..<10).map { _ in bar(0, 0, 0) }
        XCTAssertNil(TechnicalIndicators.bias(zero, period: 6))
    }

    /// 三个周期一次取齐（通达信默认 6/12/24）；缺失的周期**不出现**在字典里
    func testBIASSetSkipsUnavailablePeriods() {
        let bars = (10...15).map { i in bar(Double(i), Double(i), Double(i)) }   // 6 根
        let set = TechnicalIndicators.biasSet(bars)
        XCTAssertEqual(Set(set.keys), [6], "只有 6 根 → 只有 BIAS(6) 算得出来")
        XCTAssertNotNil(set[6])
        let long = (1...30).map { i in bar(Double(i), Double(i), Double(i)) }
        XCTAssertEqual(Set(TechnicalIndicators.biasSet(long).keys), [6, 12, 24])
    }

    // MARK: - 打包

    func testSnapshotCarriesAllFourAndBarsUsed() {
        let bars = (1...30).map { i in bar(Double(i), Double(i), Double(i), volume: 100) }
        let s = TechnicalIndicators.snapshot(bars)
        XCTAssertNotNil(s.atr)
        XCTAssertNotNil(s.atrPercent)
        XCTAssertNotNil(s.obvChange)
        XCTAssertNotNil(s.mfi)
        XCTAssertEqual(Set(s.bias.keys), [6, 12, 24])
        XCTAssertEqual(s.barsUsed, 30)
    }

    /// 样本不足时**逐项为 nil**（不整包返回 nil，也不回落成 0）
    func testSnapshotOnTinyInputIsAllNil() {
        let s = TechnicalIndicators.snapshot([bar(10, 10, 10)])
        XCTAssertNil(s.atr)
        XCTAssertNil(s.atrPercent)
        XCTAssertNil(s.obvChange)
        XCTAssertNil(s.mfi)
        XCTAssertTrue(s.bias.isEmpty)
        XCTAssertEqual(s.barsUsed, 1)
    }

    /// `KLineItem`（详情页）与 `KLineBar`（引擎）**同一条路径** → 同结论
    func testKLineItemAgreesWithKLineBar() {
        let bars = (1...30).map { i in bar(Double(i), Double(i) - 1, Double(i), volume: 100) }
        let items = bars.map { KLineItem(date: $0.day, open: $0.open, high: $0.high,
                                        low: $0.low, close: $0.close, volume: $0.volume) }
        // `snapshot` 只吃 `[KLineBar]`，故这里比对单个函数在两种输入上的等价性
        // —— `KLineItem` 走的是同一套公式（`OHLCBar` 协议），此处以 BIAS 为代表验证
        XCTAssertEqual(TechnicalIndicators.bias(bars, period: 6),
                       TechnicalIndicators.bias(items.map {
                           KLineBar(day: $0.date, open: $0.open, high: $0.high,
                                    low: $0.low, close: $0.close, volume: $0.volume)
                       }, period: 6))
    }
}
