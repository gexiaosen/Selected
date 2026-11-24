import XCTest
@testable import SelectedCore

/// 历史指数回填：取 viewDate 或之前最近交易日，涨跌幅按前一根收盘算。
final class IndexHistoryQuoteTests: XCTestCase {

    private func bar(_ day: String, close: Double, pct: Double = 0) -> HistoryBar {
        HistoryBar(code: "sh000001", day: day, open: close, close: close,
                   high: close + 1, low: close - 1, volume: 100, amount: 1_000_000,
                   amplitude: 1, changePct: pct, turnover: 1)
    }

    func testExactDayUsesPreviousClose() {
        let bars = [bar("2026-10-17", close: 100), bar("2026-10-20", close: 110)]
        let r = IndexHistoryQuote.quote(symbol: "sh000001", bars: bars, date: "2026-10-20")
        XCTAssertEqual(r?.asOf, "2026-10-20")
        XCTAssertEqual(r?.quote.currentPrice ?? 0, 110, accuracy: 1e-9)
        XCTAssertEqual(r?.quote.previousClose ?? 0, 100, accuracy: 1e-9)
        XCTAssertEqual(r?.quote.changePercent ?? 0, 10, accuracy: 1e-9)
        XCTAssertEqual(r?.quote.turnover ?? 0, 100, accuracy: 1e-9, "元 → 万元")
    }

    func testWeekendFallsBackToPreviousTradingDay() {
        let bars = [bar("2026-10-17", close: 100), bar("2026-10-20", close: 110)]
        let r = IndexHistoryQuote.quote(symbol: "sh000001", bars: bars, date: "2026-10-24")
        XCTAssertEqual(r?.asOf, "2026-10-20", "周末不伪造 viewDate")
        XCTAssertEqual(r?.quote.currentPrice ?? 0, 110, accuracy: 1e-9)
    }

    func testNoBarOnOrBeforeDateReturnsNil() {
        let bars = [bar("2026-10-20", close: 110)]
        XCTAssertNil(IndexHistoryQuote.quote(symbol: "sh000001", bars: bars, date: "2026-10-19"))
    }

    func testSingleBarFallsBackToSourcePct() {
        let bars = [bar("2026-10-20", close: 110, pct: 3.5)]
        let r = IndexHistoryQuote.quote(symbol: "sh000001", bars: bars, date: "2026-10-20")
        XCTAssertEqual(r?.quote.previousClose ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(r?.quote.changePercent ?? 0, 3.5, accuracy: 1e-9)
    }
}
