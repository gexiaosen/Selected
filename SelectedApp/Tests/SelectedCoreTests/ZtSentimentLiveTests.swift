import XCTest
@testable import SelectedCore

/// 盘中情绪：用实时价按收盘同一口径算平均/中位/晋级/亏损面，缺价单独计。
final class ZtSentimentLiveTests: XCTestCase {

    private func record(code: String, yesterdayPct: Double) -> LimitUpRecord {
        LimitUpRecord(date: "2026-10-20", code: code, name: code, price: 10,
                      changePct: yesterdayPct, amount: 0, turnoverRate: 0,
                      floatCap: 0, totalCap: 0, boards: 1, statDays: 1, statBoards: 1,
                      firstSeal: "09:25:00", lastSeal: "09:25:00", brokenCount: 0,
                      sealFund: 0, industry: "")
    }

    private func quote(code: String, price: Double, prev: Double, pct: Double) -> StockQuote {
        StockQuote(market: "sz", code: code, name: code, currentPrice: price,
                   previousClose: prev, openPrice: prev, highPrice: price, lowPrice: prev,
                   volume: 0, turnover: 0, change: price - prev, changePercent: pct,
                   turnoverRate: nil, peRatio: nil, marketCap: nil,
                   circulationMarketCap: nil, amplitude: nil, volumeRatio: nil,
                   pbRatio: nil, limitUp: nil, limitDown: nil)
    }

    func testLiveComputeUsesRealtimeQuotesAndCountsMissing() {
        let pool = [
            record(code: "300001", yesterdayPct: 20),
            record(code: "600001", yesterdayPct: 10),
            record(code: "600002", yesterdayPct: 10),
        ]
        let quotes = [
            "300001": quote(code: "300001", price: 12, prev: 10, pct: 19.9),
            "600001": quote(code: "600001", price: 9.7, prev: 10, pct: -3.0),
        ]
        let r = ZtSentimentLive.compute(date: "2026-10-21", pool: pool, quotes: quotes)
        XCTAssertEqual(r.sample, 2)
        XCTAssertEqual(r.missing, 1)
        XCTAssertEqual(r.promoted, 1, "创业板 20% 档 +19.9% 算晋级")
        XCTAssertEqual(r.lossCount, 1)
        XCTAssertEqual(r.avgPct, 8.45, accuracy: 1e-9)
        XCTAssertEqual(r.medianPct, 8.45, accuracy: 1e-9)
    }

    func testLiveComputeEmptyQuotes() {
        let pool = [record(code: "600001", yesterdayPct: 10)]
        let r = ZtSentimentLive.compute(date: "2026-10-21", pool: pool, quotes: [:])
        XCTAssertEqual(r.sample, 0)
        XCTAssertEqual(r.missing, 1)
        XCTAssertEqual(r.avgPct, 0, accuracy: 1e-9)
    }
}
