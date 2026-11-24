import XCTest
@testable import SelectedCore

/// `MarketBreadth`（大盘环境的涨跌家数）专项测试
///
/// 背景（见 `MarketBreadth` 的类型文档）：用 **±0.1% 死区**判平盘，
/// 会把「一跳落在死区内」的票算成平盘 —— 实测平盘数虚高一倍多。本文件盯的就是这条：
/// **只要有人把死区加回来，`testOneTickMoveOnHighPricedStockIsNotFlat` 立刻报红。**
final class MarketBreadthTests: XCTestCase {

    /// 造一条行情：只关心 现价 / 昨收 / 成交量
    private func quote(_ code: String, price: Double, preClose: Double,
                       volume: Double = 1000) -> (String, EngineQuote) {
        let q = EngineQuote(json: ["code": code, "price": price, "pre_close": preClose,
                                   "volume": volume])
        return (code, q)
    }

    private func counts(_ items: [(String, EngineQuote)]) -> MarketBreadth.Counts {
        MarketBreadth.counts(Dictionary(uniqueKeysWithValues: items))
    }

    // MARK: - 核心反例

    /// 回归锁：**一跳的涨跌必须按涨跌额符号判**，与"这一跳占价格的百分比"无关。
    ///
    /// 样本取自真实行情（这三只都会被死区口径算成平盘）：
    /// `12.20 → 12.21` = +0.08%、`14.26 → 14.25` = −0.07%、`85.15 → 85.20` = +0.06%。
    ///
    /// 反向验证：把判据改回 `chg > 0.001 / < -0.001` → 本用例报
    /// `up` 少 2、`flat` 多 3。
    func testOneTickMoveOnHighPricedStockIsNotFlat() {
        let c = counts([
            quote("603506", price: 12.21, preClose: 12.20),   // +0.08%
            quote("605008", price: 14.25, preClose: 14.26),   // −0.07%
            quote("301557", price: 85.20, preClose: 85.15),   // +0.06%
        ])
        XCTAssertEqual(c.up, 2, "涨 0.01 元就是涨 —— 哪怕只占 0.06%")
        XCTAssertEqual(c.down, 1, "跌 0.01 元就是跌")
        XCTAssertEqual(c.flat, 0, "死区口径会把这 3 只全算成平盘（本断言的防回归意义就在这）")
    }

    /// 死区**不该**再有任何特殊含义：0.1% 上下两侧按同一规则走
    func testNoDeadBandAroundZeroPointOnePercent() {
        let c = counts([
            quote("a", price: 10.01, preClose: 10.00),   // +0.10%（死区边界上）
            quote("b", price: 9.99, preClose: 10.00),    // −0.10%（死区边界上）
            quote("c", price: 10.02, preClose: 10.00),   // +0.20%
            quote("d", price: 9.98, preClose: 10.00),    // −0.20%
        ])
        XCTAssertEqual(c.up, 2)
        XCTAssertEqual(c.down, 2)
        XCTAssertEqual(c.flat, 0)
    }

    // MARK: - 平盘的定义

    func testExactlyEqualCountsAsFlat() {
        let c = counts([quote("x", price: 12.20, preClose: 12.20)])
        XCTAssertEqual(c.flat, 1)
        XCTAssertEqual(c.up, 0)
        XCTAssertEqual(c.down, 0)
    }

    /// 停牌 / 无成交：最新价就是昨收 → **平盘**（口径有意如此，与修正前一致）
    func testSuspendedStockCountsAsFlat() {
        let c = counts([quote("y", price: 8.88, preClose: 8.88, volume: 0)])
        XCTAssertEqual(c.flat, 1, "停牌不是'没数据' —— 它的最新价确实等于昨收")
        XCTAssertEqual(c.total, 1)
    }

    // MARK: - 边界与守恒

    /// `现价 <= 0` 或 `昨收 <= 0` 的行情不参与统计（与修正前一致）
    func testInvalidQuotesAreExcludedFromTheDenominator() {
        let c = counts([
            quote("ok", price: 10.00, preClose: 9.90),
            quote("noPrice", price: 0, preClose: 9.90),
            quote("noPreClose", price: 10.00, preClose: 0),
        ])
        XCTAssertEqual(c.total, 1, "两条非法行情都不该进分母")
        XCTAssertEqual(c.up, 1)
    }

    func testEmptyInputGivesZero() {
        let c = MarketBreadth.counts([:])
        XCTAssertEqual(c.total, 0)
        XCTAssertEqual(c.up, 0)
        XCTAssertEqual(c.down, 0)
        XCTAssertEqual(c.flat, 0)
    }

    /// 守恒：`total == up + down + flat`，且恰好等于"合法行情"的条数
    func testCountsPartitionTheValidQuotes() {
        var items: [(String, EngineQuote)] = []
        for i in 0..<40 {
            // 轮流造 涨 / 跌 / 平，混入非法行情
            let base = 10.0 + Double(i)
            switch i % 4 {
            case 0: items.append(quote("u\(i)", price: base + 0.01, preClose: base))
            case 1: items.append(quote("d\(i)", price: base - 0.01, preClose: base))
            case 2: items.append(quote("f\(i)", price: base, preClose: base))
            default: items.append(quote("z\(i)", price: 0, preClose: base))
            }
        }
        let c = counts(items)
        XCTAssertEqual(c.total, 30, "40 条里 10 条非法（price=0）")
        XCTAssertEqual(c.up + c.down + c.flat, c.total)
        XCTAssertEqual(c.up, 10)
        XCTAssertEqual(c.down, 10)
        XCTAssertEqual(c.flat, 10)
    }

    // MARK: - 涨跌比

    func testRatioIsUpOverDown() {
        let c = MarketBreadth.Counts(up: 2821, down: 2190, flat: 211)
        XCTAssertEqual(PyMath.round(MarketBreadth.ratio(c), 2), 1.29)
    }

    /// 除零分支 = `999`（**与冻结基准一致的既有形态**，不是"随便定的兜底"）
    func testRatioDivisionByZeroIs999() {
        XCTAssertEqual(MarketBreadth.ratio(MarketBreadth.Counts(up: 100, down: 0, flat: 5)), 999)
        XCTAssertEqual(MarketBreadth.ratio(MarketBreadth.Counts()), 999)
    }
}
