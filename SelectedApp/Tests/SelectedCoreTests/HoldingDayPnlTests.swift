import XCTest
@testable import SelectedCore

/// 持仓当日盈亏：金额 / 比率 / 盈亏家数 / 缺行情与缺昨收的降级。
final class HoldingDayPnlTests: XCTestCase {

    func testAggregatesDayAndTotalPnl() {
        let s = HoldingDayPnl.compute([
            .init(code: "300308", name: "中际旭创", costPrice: 100, shares: 100,
                  price: 110, previousClose: 105),
            .init(code: "300750", name: "宁德时代", costPrice: 200, shares: 50,
                  price: 202, previousClose: 200),
            .init(code: "600519", name: "贵州茅台", costPrice: 1500, shares: 10,
                  price: 1490, previousClose: 1500),
        ])
        XCTAssertEqual(s.quotedCount, 3)
        XCTAssertEqual(s.missingCount, 0)
        XCTAssertEqual(s.winners, 2)
        XCTAssertEqual(s.losers, 1)
        XCTAssertEqual(s.totalCost, 35_000, accuracy: 1e-9)
        XCTAssertEqual(s.totalValue, 36_000, accuracy: 1e-9)
        XCTAssertEqual(s.totalPnl, 1_000, accuracy: 1e-9)
        XCTAssertEqual(s.dayPnl, 500 + 100 - 100, accuracy: 1e-9)
        // 当日盈亏率分母 = 昨收市值（105×100 + 200×50 + 1500×10 = 35,500），不是总成本 35,000
        XCTAssertEqual(s.dayBaseValue, 35_500, accuracy: 1e-9)
        XCTAssertEqual(s.dayPnlPct, 500.0 / 35_500 * 100, accuracy: 1e-9)
        // 贡献榜按 |当日盈亏| 降序
        XCTAssertEqual(s.topMovers.map(\.code), ["300308", "300750", "600519"])
    }

    /// 当日盈亏率分母必须是**昨收市值**：单只持仓、同一数量下，它应与该票当日涨跌幅一致，
    /// 而不是被成本价稀释（成本 55.879 / 昨收 47.00 的票，两种口径能差出好几个百分点）。
    func testDayPctUsesPreviousCloseValueNotCost() {
        let s = HoldingDayPnl.compute([
            .init(code: "600276", name: "恒瑞医药", costPrice: 55.879, shares: 900,
                  price: 47.71, previousClose: 47.00),
        ])
        // 当日盈亏 = (47.71 − 47.00) × 900 = 639
        XCTAssertEqual(s.dayPnl, (47.71 - 47.00) * 900, accuracy: 1e-6)
        // 昨收市值 = 47.00 × 900 = 42,300（总成本是 50,291.1，不能当分母）
        XCTAssertEqual(s.dayBaseValue, 42_300, accuracy: 1e-6)
        XCTAssertEqual(s.dayPnlPct, (47.71 - 47.00) / 47.00 * 100, accuracy: 1e-9)
        XCTAssertEqual(s.lines.first?.dayPct ?? -1, (47.71 - 47.00) / 47.00 * 100,
                       accuracy: 1e-9)
    }

    func testMissingQuoteIsExcludedFromMoneyButCounted() {
        let s = HoldingDayPnl.compute([
            .init(code: "000001", name: "平安银行", costPrice: 10, shares: 100,
                  price: 11, previousClose: 10.5),
            .init(code: "600000", name: "浦发银行", costPrice: 8, shares: 200,
                  price: nil, previousClose: 8),
        ])
        XCTAssertEqual(s.quotedCount, 1)
        XCTAssertEqual(s.missingCount, 1)
        XCTAssertEqual(s.totalCost, 1_000, accuracy: 1e-9)
        XCTAssertEqual(s.totalValue, 1_100, accuracy: 1e-9)
        XCTAssertEqual(s.dayPnl, 50, accuracy: 1e-9)
    }

    func testMissingPreviousCloseKeepsTotalButSkipsDay() {
        let s = HoldingDayPnl.compute([
            .init(code: "600000", name: "浦发银行", costPrice: 8, shares: 200,
                  price: 9, previousClose: nil),
        ])
        XCTAssertEqual(s.quotedCount, 1)
        XCTAssertEqual(s.missingPrevCloseCount, 1)
        XCTAssertFalse(s.hasAnyDayPnl)
        XCTAssertEqual(s.dayPnl, 0, accuracy: 1e-9)
        XCTAssertEqual(s.totalPnl, 200, accuracy: 1e-9)
        XCTAssertNil(s.lines[0].dayPnl)
    }

    func testZeroSharesAreIgnored() {
        let s = HoldingDayPnl.compute([
            .init(code: "600000", name: "浦发银行", costPrice: 8, shares: 0,
                  price: 9, previousClose: 8),
        ])
        XCTAssertTrue(s.lines.isEmpty)
        XCTAssertEqual(s.missingCount, 0)
        XCTAssertEqual(s.totalCost, 0, accuracy: 1e-9)
    }

    func testEmptyInput() {
        let s = HoldingDayPnl.compute([])
        XCTAssertTrue(s.lines.isEmpty)
        XCTAssertFalse(s.hasAnyQuote)
        XCTAssertEqual(s.dayPnlPct, 0, accuracy: 1e-9)
        XCTAssertEqual(s.totalPnlPct, 0, accuracy: 1e-9)
    }
}
