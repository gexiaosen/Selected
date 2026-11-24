import XCTest
@testable import SelectedCore

/// `ChipDistribution` 的契约测试。
///
/// 这是本模块**唯一**的自动化覆盖 —— 详情页的卡片（`StockDetailSheet.chipCard`）不在
/// 任何测试子集里，`swift build` 只做类型检查。所以"分布怎么摊、两条衰减分支各是什么行为、
/// 退化输入怎么处理"这类**真会静默出错**的部分，全部钉在本文件。
///
/// 测试**只用人工构造的 bar**，不读网络、不读夹具：筹码分布是纯算术，
/// 人工数据的期望值可以手算，比"跑一遍看看像不像"可靠得多。
final class ChipDistributionTests: XCTestCase {

    // MARK: - 构造工具

    private func bar(_ open: Double, _ high: Double, _ low: Double, _ close: Double,
                     _ volume: Double, day: String = "2026-01-05") -> KLineItem {
        KLineItem(date: day, open: open, high: high, low: low, close: close, volume: volume)
    }

    /// 一根"价格恒定"的 bar（一字板 / 横盘）
    private func flat(_ price: Double, _ volume: Double = 1000) -> KLineItem {
        bar(price, price, price, price, volume)
    }

    /// 从 `from` 线性涨到 `to` 的 `n` 根 bar，每根成交量 `volume`
    private func ramp(from: Double, to: Double, n: Int, volume: Double = 1000) -> [KLineItem] {
        (0..<n).map { i in
            let p = from + (to - from) * Double(i) / Double(max(1, n - 1))
            return bar(p, p * 1.01, p * 0.99, p, volume)
        }
    }

    // MARK: - 退化输入

    /// 少于 `minBars` 根 → nil（5 根算不出"分布"）
    func testTooFewBarsReturnsNil() {
        let nine = (0..<9).map { flat(10 + Double($0)) }
        XCTAssertNil(ChipDistribution.compute(nine, currentPrice: 15))
        XCTAssertNil(ChipDistribution.compute([], currentPrice: 15))
    }

    /// 刚好 `minBars` 根 → 可以算（边界必须**恰好**可过，否则门槛是 11 不是 10）
    func testExactlyMinBarsIsAccepted() throws {
        let bars = (0..<ChipDistribution.minBars).map { flat(10 + Double($0) * 0.1) }
        let s = try XCTUnwrap(ChipDistribution.compute(bars, currentPrice: 10.5))
        XCTAssertEqual(s.window, ChipDistribution.minBars)
    }

    /// 零成交量的 bar（停牌）不产生筹码，也不该污染网格 → 被剔除、不计入 `window`
    func testZeroVolumeBarsAreExcluded() throws {
        // 11 根有效（10.0 … 11.0）+ 9 根停牌（价格离谱且零量）
        var enough = (0..<11).map { flat(10 + Double($0) * 0.1) }
        enough += (0..<9).map { _ in flat(200, 0) }
        // 现价取 20（**高于全部有效 bar**）是有意的：若那 9 根 200 元的停牌 bar 参与了，
        //   现价 20 就会落在分布**内部**，获利盘必然远小于 1 → 这条断言才能真正抓住"没剔除"。
        let ok = try XCTUnwrap(ChipDistribution.compute(enough, currentPrice: 20))
        XCTAssertEqual(ok.window, 11, "window 只数有成交量的 bar")
        XCTAssertEqual(ok.profitRatio, 1.0, accuracy: 1e-9, "停牌那 9 根 200 元的绝不能参与")
        XCTAssertNil(ok.pressurePrice, "上方应无筹码")

        // 9 根有效 → 不足门槛 → nil
        var tooFew = (0..<9).map { flat(10 + Double($0) * 0.1) }
        tooFew += (0..<11).map { _ in flat(200, 0) }
        XCTAssertNil(ChipDistribution.compute(tooFew, currentPrice: 20))
    }

    /// 现价非正 → nil（"上方/下方"无从谈起）
    func testNonPositivePriceReturnsNil() {
        let bars = (0..<20).map { _ in flat(10) }
        XCTAssertNil(ChipDistribution.compute(bars, currentPrice: 0))
        XCTAssertNil(ChipDistribution.compute(bars, currentPrice: -1))
    }

    // MARK: - 极值场景（人工数据，期望值可手算）

    /// 一字板：全部筹码在现价上 → 获利盘 100%、上方 0、无压力位
    ///
    /// 这条同时是「网格退化只许向下扩」的回归锁 —— 对称扩会算出 50%。
    func testAllChipsAtCurrentPriceMeansNoOverhead() throws {
        let bars = (0..<20).map { _ in flat(10) }
        let s = try XCTUnwrap(ChipDistribution.compute(bars, currentPrice: 10))
        XCTAssertEqual(s.profitRatio, 1.0, accuracy: 1e-9, "一字板不应凭空出现上方套牢盘")
        XCTAssertEqual(s.aboveMass, 0.0, accuracy: 1e-9)
        XCTAssertNil(s.pressurePrice, "上方没有筹码 → 没有压力位")
        XCTAssertTrue(s.isAboveVacuum)
        XCTAssertEqual(s.avgCost, 10.0, accuracy: 0.02)
    }

    /// 现价高于窗口内全部价格 → 全部获利、上方真空
    func testPriceAboveAllBarsIsFullyProfit() throws {
        let bars = (0..<30).map { flat(10 + Double($0) * 0.1) }   // 10.0 … 12.9
        let s = try XCTUnwrap(ChipDistribution.compute(bars, currentPrice: 30))
        XCTAssertEqual(s.profitRatio, 1.0, accuracy: 1e-9)
        XCTAssertEqual(s.aboveMass, 0.0, accuracy: 1e-9)
        XCTAssertNil(s.pressurePrice)
        XCTAssertTrue(s.isAboveVacuum)
    }

    /// 现价低于窗口内全部价格 → 全部套牢、压力位就在下方筹码最密集处（≈ 最低价一带）
    func testPriceBelowAllBarsIsFullyTrapped() throws {
        let bars = (0..<30).map { flat(30 + Double($0) * 0.1) }   // 30.0 … 32.9
        let s = try XCTUnwrap(ChipDistribution.compute(bars, currentPrice: 20))
        XCTAssertEqual(s.profitRatio, 0.0, accuracy: 1e-9)
        XCTAssertEqual(s.aboveMass, 1.0, accuracy: 1e-9)
        let pp = try XCTUnwrap(s.pressurePrice, "上方全是筹码 → 必有压力位")
        XCTAssertGreaterThan(pp, 20, "压力位必须在现价之上")
        XCTAssertLessThan(pp, 31.5, "第一道压力应落在最低价一带（自下方累计 5% 筹码处）")
        XCTAssertEqual(try XCTUnwrap(s.pressureGapPct), (pp / 20 - 1) * 100, accuracy: 1e-9)
    }

    // MARK: - 不变量

    /// 获利盘 + 上方筹码 == 1（网格按 `≤ 现价` / `> 现价` 二分，必须无缝隙、无重叠）
    func testProfitAndAboveMassSumToOne() throws {
        let bars = ramp(from: 10, to: 20, n: 80)
        for price in [9.0, 12.0, 15.0, 18.0, 22.0] {
            let s = try XCTUnwrap(ChipDistribution.compute(bars, currentPrice: price))
            XCTAssertEqual(s.profitRatio + s.aboveMass, 1.0, accuracy: 1e-9,
                           "现价 \(price) 处两块筹码之和应为 1")
        }
    }

    /// 现价越高，获利盘越多（单调不减）—— 分布函数的基本性质，错了说明分档有洞
    func testProfitRatioIsMonotonicInPrice() throws {
        let bars = ramp(from: 10, to: 20, n: 80)
        var last = -1.0
        for i in 0...40 {
            let price = 8.0 + Double(i) * 0.35
            let s = try XCTUnwrap(ChipDistribution.compute(bars, currentPrice: price))
            XCTAssertGreaterThanOrEqual(s.profitRatio, last - 1e-12, "现价 \(price) 处获利盘不应下降")
            last = s.profitRatio
        }
        XCTAssertEqual(last, 1.0, accuracy: 1e-9, "现价高过全部分布后应满格")
    }

    /// 90% 成本区间必须**包含**平均成本，且下沿 ≤ 上沿
    func testCost90RangeBracketsAverageCost() throws {
        let bars = ramp(from: 10, to: 20, n: 80)
        let s = try XCTUnwrap(ChipDistribution.compute(bars, currentPrice: 15))
        XCTAssertLessThanOrEqual(s.cost90Low, s.cost90High)
        XCTAssertGreaterThanOrEqual(s.avgCost, s.cost90Low)
        XCTAssertLessThanOrEqual(s.avgCost, s.cost90High)
        XCTAssertGreaterThan(s.cost90High - s.cost90Low, 0, "涨了 100% 的窗口，90% 区间不可能退化成一个点")
    }

    /// `pressureGapPct` 必须与 `pressurePrice` 自洽（同一份数据不能给出两个口径）
    func testPressureGapIsConsistentWithPressurePrice() throws {
        let bars = ramp(from: 10, to: 20, n: 80)
        let s = try XCTUnwrap(ChipDistribution.compute(bars, currentPrice: 15))
        let pp = try XCTUnwrap(s.pressurePrice, "现价 15 落在 10→20 的中段，上方必有筹码")
        XCTAssertEqual(try XCTUnwrap(s.pressureGapPct), (pp / 15 - 1) * 100, accuracy: 1e-9)
    }

    // MARK: - 窗口截断

    /// 超过 window 的 bar 必须**不参与** —— 且 `window` 字段如实报告用了多少根
    func testWindowTruncationUsesOnlyTheTail() throws {
        // 前 200 根在 5 元（极低价），后 60 根在 20 元
        let bars = (0..<200).map { _ in flat(5, 1000) } + (0..<60).map { _ in flat(20, 1000) }

        let tail = try XCTUnwrap(ChipDistribution.compute(bars, currentPrice: 20, window: 60))
        XCTAssertEqual(tail.window, 60)
        XCTAssertEqual(tail.profitRatio, 1.0, accuracy: 1e-9,
                       "只取尾部 60 根（全在 20 元）→ 现价 20 处应全部获利")
        XCTAssertEqual(tail.avgCost, 20.0, accuracy: 0.05)

        // 不截断时那 200 根 5 元筹码会大幅拉低均价 —— 证明截断真的生效了
        let all = try XCTUnwrap(ChipDistribution.compute(bars, currentPrice: 20, window: 1000))
        XCTAssertLessThan(all.avgCost, 19.0, "全窗口时低价筹码应拉低均价")
    }

    // MARK: - 两条衰减分支

    /// `decayed` 标志必须如实反映走了哪条分支
    func testDecayedFlagFollowsFloatShares() throws {
        let bars = ramp(from: 10, to: 20, n: 40)
        XCTAssertTrue(try XCTUnwrap(ChipDistribution.compute(bars, currentPrice: 15, floatShares: 1e9)).decayed)
        XCTAssertFalse(try XCTUnwrap(ChipDistribution.compute(bars, currentPrice: 15, floatShares: nil)).decayed)
        XCTAssertFalse(try XCTUnwrap(ChipDistribution.compute(bars, currentPrice: 15, floatShares: 0)).decayed,
                       "0 不是合法流通股本 → 走半衰期分支，而不是除以 0")
        XCTAssertFalse(try XCTUnwrap(ChipDistribution.compute(bars, currentPrice: 15, floatShares: -1)).decayed)
    }

    /// **换手衰减真的会冲掉旧筹码**：流通盘很小时，早年 10 元的筹码应被洗掉 → 均价上移
    ///
    /// 这是两条分支**唯一**的差别，必须有一条断言证明它真的生效 —— 否则两套代码长得一样，
    /// 分支写错了也没人知道。
    func testTurnoverDecayWashesOutOldChips() throws {
        // 40 根从 10 涨到 20，每根成交量 1000 手 = 10 万股
        let bars = ramp(from: 10, to: 20, n: 40, volume: 1000)
        // 流通盘 100 万股 vs 每日成交 10 万股 → 单日换手 10%，40 天后旧筹码基本洗光
        let heavy = try XCTUnwrap(ChipDistribution.compute(bars, currentPrice: 20, floatShares: 1e6))
        let none = try XCTUnwrap(ChipDistribution.compute(bars, currentPrice: 20, floatShares: nil))

        XCTAssertGreaterThan(heavy.avgCost, none.avgCost,
                             "高换手下旧低价筹码应被冲掉 → 均价更高")
        // 手算参考：权重 = 0.9^(距最新根数) → 均价 ≈ 17.85（不是"贴近 20"，
        // 因为 0.9 的衰减仍给中段留了可观权重）。半衰期分支 ≈ 15.5。
        XCTAssertGreaterThan(heavy.avgCost, 17.0, "换手 10%/日 × 40 日 → 均价应被抬到 17 以上")
        XCTAssertGreaterThan(heavy.avgCost - none.avgCost, 1.0,
                             "两条分支的差别必须是**可观测的量级**，不能只是小数点后几位")
    }

    /// 同一份数据、同一个参数 → 同一个结果（项目核心不变量「同快照同结果」）
    func testDeterministic() {
        let bars = ramp(from: 10, to: 20, n: 80)
        XCTAssertEqual(ChipDistribution.compute(bars, currentPrice: 15, floatShares: 5e8),
                       ChipDistribution.compute(bars, currentPrice: 15, floatShares: 5e8))
    }

    // MARK: - 真实形状的夹具上断言取值（不是"跑通了"，是"值对不对"）

    /// 一段接近真实的 120 根数据：先横盘、再放量上台阶、最后回踩。
    /// 断言的是**关系**而不是魔数：回踩后的获利盘应小于最高点处的获利盘，
    /// 且压力位应落在"上台阶"那一带的成本区（而不是最高点）。
    func testRealisticShapeInvariants() throws {
        var bars: [KLineItem] = []
        bars += (0..<40).map { bar(10, 10.2, 9.8, 10 + Double($0 % 3) * 0.05, 800) }     // 横盘
        bars += (0..<40).map { i in                                                       // 上台阶
            let p = 10 + Double(i) * 0.25
            return bar(p, p * 1.03, p * 0.97, p, 3000)
        }
        bars += (0..<40).map { i in                                                       // 回踩
            let p = 20 - Double(i) * 0.15
            return bar(p, p * 1.01, p * 0.99, p, 1200)
        }

        let atTop = try XCTUnwrap(ChipDistribution.compute(bars, currentPrice: 20))
        let afterPullback = try XCTUnwrap(ChipDistribution.compute(bars, currentPrice: 14))

        XCTAssertGreaterThan(atTop.profitRatio, afterPullback.profitRatio,
                             "20 元处几乎全部筹码获利；回踩到 14 元后获利盘必然缩水")
        XCTAssertGreaterThan(afterPullback.aboveMass, 0.3,
                             "回踩到 14 元后，上方筹码应占相当比例")

        let pp = try XCTUnwrap(afterPullback.pressurePrice, "回踩后上方必有压力")
        XCTAssertGreaterThan(pp, 14)
        XCTAssertLessThan(pp, 21, "第一道压力应落在上台阶的成本区，不会越过最高价")

        // 90% 区间应覆盖"横盘 10 元"到"台阶顶 20 元"的大部分
        XCTAssertLessThan(afterPullback.cost90Low, 12)
        XCTAssertGreaterThan(afterPullback.cost90High, 17)
    }

    // MARK: - estimateFloatShares

    /// 三个分支 + 单位换算（「手→股」别漏，漏了结果小 100 倍）
    func testEstimateFloatSharesBranches() {
        // 流通股本 1 亿股，今日成交 100 手（1 万股）→ 换手率 0.01%
        let byTurnover = ChipDistribution.estimateFloatShares(
            turnoverRate: 0.01, volumeInLots: 100, circulationMarketCapYi: nil, price: 10)
        XCTAssertEqual(byTurnover ?? 0, 1e8, accuracy: 1)

        // 换手率缺失 → 回落流通市值（50 亿 / 10 元 = 5 亿股）
        let byCap = ChipDistribution.estimateFloatShares(
            turnoverRate: nil, volumeInLots: 100, circulationMarketCapYi: 50, price: 10)
        XCTAssertEqual(byCap ?? 0, 5e8, accuracy: 1)

        // 换手率优先于流通市值（两者同源时以直接给出的为准）
        let prefer = ChipDistribution.estimateFloatShares(
            turnoverRate: 0.01, volumeInLots: 100, circulationMarketCapYi: 50, price: 10)
        XCTAssertEqual(prefer ?? 0, 1e8, accuracy: 1)

        // 都拿不到 → nil（调用方退化为半衰期衰减）
        XCTAssertNil(ChipDistribution.estimateFloatShares(
            turnoverRate: 0, volumeInLots: 0, circulationMarketCapYi: nil, price: 10))
        XCTAssertNil(ChipDistribution.estimateFloatShares(
            turnoverRate: nil, volumeInLots: nil, circulationMarketCapYi: nil, price: 0))
    }

    /// 用估出来的流通股本算一遍，结果必须落在**物理上说得通**的范围里
    func testEstimatedFloatSharesProducesSaneResult() throws {
        let bars = ramp(from: 10, to: 20, n: 120, volume: 1000)
        let fs = try XCTUnwrap(ChipDistribution.estimateFloatShares(
            turnoverRate: 0.5, volumeInLots: 1000, circulationMarketCapYi: nil, price: 20))
        let s = try XCTUnwrap(ChipDistribution.compute(bars, currentPrice: 20, floatShares: fs))
        XCTAssertTrue(s.decayed)
        XCTAssertGreaterThanOrEqual(s.profitRatio, 0)
        XCTAssertLessThanOrEqual(s.profitRatio, 1)
        XCTAssertTrue(s.avgCost.isFinite && s.avgCost > 0)
        XCTAssertGreaterThanOrEqual(s.cost90Low, 0)
    }
}
