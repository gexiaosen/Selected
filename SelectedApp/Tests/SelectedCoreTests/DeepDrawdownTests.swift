import XCTest
@testable import SelectedCore

/// 无大幅回撤判定。
///
/// 重点是**口径**与**与既有量的区别**：
/// · 全程**收盘对收盘**（与 `cum_5d` / `consec_up` 同口径）
/// · "60 日涨幅"需要 **61 个收盘价**（与 `cumGain5d` 用 6 个算 5 日同一口径）
/// · 与 `distFromHigh60d`（下跌侧）**不是同一个量** —— 构造用例证明结论会相反
final class DeepDrawdownTests: XCTestCase {

    /// 一根 bar（只有收盘价有意义）
    private func bar(_ close: Double, day: String = "") -> KLineBar {
        KLineBar(day: day, open: close, high: close, low: close, close: close, volume: 100)
    }

    /// 一段收盘价 → bars
    private func series(_ closes: [Double]) -> [KLineBar] { closes.map { bar($0) } }

    // MARK: - 手算对照

    /// 累计涨幅 = 末收 ÷ 首收 − 1；61 个收盘 = 60 个交易日的涨幅
    func testCumGainHandComputed() {
        // 从 10 一路到 16 → 60 个间隔里涨 60%
        var closes = Array(stride(from: 10.0, through: 16.0, by: 6.0 / 60))
        XCTAssertEqual(closes.count, 61, "构造：61 个收盘价")
        closes[closes.count - 1] = 16.0        // 收尾对齐，避免浮点尾差
        let s = DeepDrawdown.stats(series(closes))
        XCTAssertEqual(s?.days, 60)
        XCTAssertEqual(s?.bars, 61)
        XCTAssertEqual(s?.cumGain ?? -1, 60.0, accuracy: 1e-9, "(16−10)/10×100 = 60%")
    }

    /// 最大单日跌幅 = 相邻两两里跌得最狠的那一次（**正值**表示跌了多少）
    func testMaxDropHandComputed() {
        // 10 → 10 → 9（跌 10%）→ 10（涨）→ 9.5（跌 5%）
        let closes = [10.0, 10, 9, 10, 9.5]
        let s = DeepDrawdown.stats(series(closes), days: 4)
        XCTAssertEqual(s?.maxDrop1d ?? -1, 10.0, accuracy: 1e-9, "最大跌 10%")
        XCTAssertEqual(s?.maxDropAgoBars, 2, "发生在倒数第 2 个间隔 → 距今 2 根")
        XCTAssertEqual(s?.cumGain ?? -1, -5.0, accuracy: 1e-9, "(9.5−10)/10 = −5%")
    }

    /// 只涨不跌 → 最大跌幅是**负的**（那只是"涨得最少的一天"），`clean` 照样成立
    func testMonotonicRiseHasNegativeMaxDrop() {
        let closes = [10.0, 10.1, 10.2, 10.3, 10.4]
        let s = DeepDrawdown.stats(series(closes), days: 4)
        XCTAssertLessThan(s?.maxDrop1d ?? 0, 0, "只涨时'最大跌幅'为负")
        XCTAssertTrue(s?.clean == true)
    }

    // MARK: - 判定

    /// 两个阈值都满足 → clean；任一越界 → 不 clean
    func testCleanRequiresBothConditions() {
        // 平稳上涨：无暴跌、累计 +20% → clean
        var ok = Array(stride(from: 10.0, through: 12.0, by: 2.0 / 60))
        ok[ok.count - 1] = 12.0
        XCTAssertEqual(DeepDrawdown.stats(series(ok))?.clean, true)

        // 有单日暴跌 9%（>7%）→ 不 clean（即使累计涨幅很小）
        var withCrash = Array(repeating: 10.0, count: 61)
        withCrash[30] = 9.0        // 10 → 9 = 跌 10%
        withCrash[31] = 10.0
        let s1 = DeepDrawdown.stats(series(withCrash))
        XCTAssertEqual(s1?.maxDrop1d ?? -1, 10.0, accuracy: 1e-9)
        XCTAssertEqual(s1?.clean, false, "暴跌过 → 不满足")

        // 累计涨幅 > 60%（无暴跌）→ 不 clean
        var hot = Array(stride(from: 10.0, through: 18.0, by: 8.0 / 60))
        hot[hot.count - 1] = 18.0   // +80%
        let s2 = DeepDrawdown.stats(series(hot))
        XCTAssertEqual(s2?.cumGain ?? -1, 80.0, accuracy: 1e-9)
        XCTAssertEqual(s2?.clean, false, "涨太多 → 不满足")
    }

    /// 阈值**恰好等于** → 满足（`<=` 不是 `<`）
    func testThresholdsAreInclusive() {
        // 构造"恰好跌 7%"：10 → 9.3
        var exact = Array(repeating: 10.0, count: 61)
        exact[30] = 9.3
        exact[31] = 10.0
        XCTAssertEqual(DeepDrawdown.stats(series(exact))?.maxDrop1d ?? -1, 7.0, accuracy: 1e-9)
        XCTAssertEqual(DeepDrawdown.stats(series(exact))?.clean, true, "恰好 7% 应算满足")

        // 构造"恰好涨 60%"：10 → 16
        var exactGain = Array(stride(from: 10.0, through: 16.0, by: 6.0 / 60))
        exactGain[exactGain.count - 1] = 16.0
        XCTAssertEqual(DeepDrawdown.stats(series(exactGain))?.clean, true, "恰好 60% 应算满足")
    }

    /// 阈值可调（`0.6` 读作 60% 是个**读数**，所以必须可调）
    func testThresholdsAreConfigurable() {
        var hot = Array(stride(from: 10.0, through: 18.0, by: 8.0 / 60))
        hot[hot.count - 1] = 18.0                       // +80%
        XCTAssertEqual(DeepDrawdown.stats(series(hot))?.clean, false)
        XCTAssertEqual(DeepDrawdown.stats(series(hot), cumGainLimit: 100)?.clean, true,
                       "把上限放到 100% → 满足")
        XCTAssertEqual(DeepDrawdown.stats(series(hot), days: 60,
                                          maxDropLimit: 7, cumGainLimit: 80)?.clean, true,
                       "恰好 80% → 满足")
    }

    // MARK: - 与既有量的区别（判别性用例）

    /// **本项 ≠ `distFromHigh60d`**：
    /// · `distFromHigh60d` 量**下跌侧**（现价距 60 日最高收盘）
    /// · 本项的"累计涨幅"量**上涨侧**（首收 → 末收）
    ///
    /// 构造：一路从 5 涨到 20（累计 +300%，且**就在最高点**）→
    /// `distFromHigh60d ≈ 0`（"距高点 0%"看起来毫无风险），而本项 `cumGain = 300%`（严重追高）。
    func testNotTheSameAsDistFromHigh() {
        var closes = Array(stride(from: 5.0, through: 20.0, by: 15.0 / 60))
        closes[closes.count - 1] = 20.0
        let closesArr = closes
        let s = DeepDrawdown.stats(series(closesArr))
        let dist = EngineIndicators.distFromHigh60d(closesArr, 20.0)
        XCTAssertEqual(dist, 0, accuracy: 1e-9, "就在 60 日最高点 → 距高点 0%")
        XCTAssertEqual(s?.cumGain ?? -1, 300.0, accuracy: 1e-9, "但 60 日累计涨了 300%")
        XCTAssertEqual(s?.clean, false, "两种口径给出的结论**相反** —— 证明不是同一个量")
    }

    // MARK: - 边界

    /// 样本不足（< days + 1）→ `nil`（不返回 0 —— "算不出来"与"没跌过"是两件事）
    func testInsufficientBarsYieldNil() {
        XCTAssertNil(DeepDrawdown.stats([KLineBar]()))
        XCTAssertNil(DeepDrawdown.stats(series(Array(repeating: 10.0, count: 60))),
                     "只有 60 根，60 日涨幅要 61 个收盘")
        XCTAssertNotNil(DeepDrawdown.stats(series(Array(repeating: 10.0, count: 61))))
        XCTAssertNil(DeepDrawdown.stats(series(Array(repeating: 10.0, count: 61)), days: 0))
    }

    /// 前收非正（脏数据）→ 那一格跳过；**首收非正** → 累计涨幅算不出 → `clean = false`
    /// （不声称一个验证不了的"安全"）
    func testNonPositiveBaseIsNotTreatedAsClean() {
        var closes = Array(repeating: 10.0, count: 61)
        closes[0] = 0                      // 首收为 0 → 累计涨幅算不出
        let s = DeepDrawdown.stats(series(closes))
        XCTAssertNil(s?.cumGain)
        XCTAssertEqual(s?.clean, false, "算不出累计涨幅 → 不能声称'无大幅回撤'")
        XCTAssertNotNil(s?.maxDrop1d, "单日跌幅仍可算（其余前收都正常）")
    }

    /// 全平序列（长期停牌）→ 最大跌幅 0、累计涨幅 0 → `clean` 成立（确实"没跌过"）
    func testFlatSeriesIsClean() {
        let s = DeepDrawdown.stats(series(Array(repeating: 10.0, count: 61)))
        XCTAssertEqual(s?.maxDrop1d ?? -1, 0.0, accuracy: 1e-9)
        XCTAssertEqual(s?.cumGain ?? -1, 0.0, accuracy: 1e-9)
        XCTAssertEqual(s?.clean, true)
    }

    /// `KLineItem`（详情页）与 `KLineBar`（引擎）**同一条路径** → 同结论
    func testKLineItemAgreesWithKLineBar() {
        let bars = series(Array(stride(from: 10.0, through: 12.0, by: 2.0 / 60)))
        let items = bars.map { KLineItem(date: $0.day, open: $0.open, high: $0.high,
                                        low: $0.low, close: $0.close, volume: $0.volume) }
        XCTAssertEqual(DeepDrawdown.stats(bars)?.cumGain, DeepDrawdown.stats(items)?.cumGain)
        XCTAssertEqual(DeepDrawdown.stats(bars)?.clean, DeepDrawdown.stats(items)?.clean)
    }
}
