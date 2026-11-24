import XCTest
@testable import SelectedCore

/// 五档盘口与分笔成交的解析口径（2026-11-02 真实响应取样，数值都是当天实测值）。
///
/// 这三条最容易出错的地方不是"解析不出来"，而是**解析错了看不出来**：
///   · 买/卖档顺序颠倒 → 盘口整列反向，数字都还是"真实存在的价"；
///   · 空档位当成 0 价 → 涨停时显示"卖一 0.00"；
///   · 港股 78 字段按 A 股 88 字段的布局读 → 把现价当成买一。
/// 所以每条都配一个**判别性**用例（改回错误写法只会有一条变红）。
final class QuoteBookTests: XCTestCase {

    // MARK: - 造响应

    private func line(symbol: String, count: Int = 88, set: [Int: String]) -> String {
        var f = Array(repeating: "", count: count)
        for (i, v) in set { f[i] = v }
        return "v_\(symbol)=\"\(f.joined(separator: "~"))\";"
    }

    /// 2026-11-02 10:09 实测 sz000001 的买五档 / 卖五档
    private func pingAnLine() -> String {
        line(symbol: "sz000001", set: [
            1: "平安银行", 2: "000001", 3: "11.67", 4: "11.64", 30: "20261102100957",
            9: "11.70", 10: "2727", 11: "11.69", 12: "2754", 13: "11.68", 14: "2141",
            15: "11.67", 16: "4841", 17: "11.66", 18: "1929",
            19: "11.71", 20: "5245", 21: "11.72", 22: "5643", 23: "11.73", 24: "7298",
            25: "11.74", 26: "4029", 27: "11.75", 28: "9192",
        ])
    }

    // MARK: - 五档

    func testDepthReadsBuyThenSellInOrder() throws {
        let parsed = try XCTUnwrap(QuoteBook.parseDepthBatch(pingAnLine())["sz000001"])
        XCTAssertEqual(parsed.bids.map(\.price), [11.70, 11.69, 11.68, 11.67, 11.66],
                       "f9…f18 是买一→买五（价格**递减**）；颠倒会让盘口整列反向")
        XCTAssertEqual(parsed.asks.map(\.price), [11.71, 11.72, 11.73, 11.74, 11.75])
        XCTAssertEqual(parsed.bids.first?.volumeLots, 2727, "档位量单位是手")
        XCTAssertEqual(parsed.bestBid, 11.70)
        XCTAssertEqual(parsed.bestAsk, 11.71)
        XCTAssertNotNil(parsed.quoteTime, "f30 的行情时间要带出来（新鲜度打分要用）")
    }

    /// **判别性用例**：涨停时卖档恒 `0.00/0` → 必须是**空数组**，不是"卖一 0 元"。
    func testEmptyLevelsAreDroppedNotZeroed() throws {
        let line = self.line(symbol: "sh600519", set: [
            1: "贵州茅台", 2: "600519", 3: "1425.34", 4: "1410.00",
            9: "1425.34", 10: "2", 11: "1425.29", 12: "1",
            // 13…28 全空 = 没有更多买档、卖档全空（涨停形态）
        ])
        let depth = try XCTUnwrap(QuoteBook.parseDepthBatch(line)["sh600519"])
        XCTAssertEqual(depth.bids.count, 2, "只保留有量有价的档位")
        XCTAssertTrue(depth.asks.isEmpty, "涨停没有卖盘 ⇒ 空数组，而不是 (0.00, 0)")
        XCTAssertNil(depth.bestAsk)
    }

    /// 指数（f9…f28 全零）与港股（78 字段、f9 是现价）都**不该**产出五档。
    func testIndexAndHkProduceNoDepth() {
        let zeros = line(symbol: "sh000001", set: [
            1: "上证指数", 2: "000001", 3: "3614.80", 4: "3600.00",
            9: "0.00", 10: "0", 19: "0.00", 20: "0",
        ])
        XCTAssertTrue(QuoteBook.parseDepthBatch(zeros).isEmpty, "指数没有盘口")

        let hk = line(symbol: "hk00700", count: 78, set: [
            1: "腾讯控股", 2: "00700", 3: "389.400", 4: "388.000", 9: "389.400",
        ])
        XCTAssertTrue(QuoteBook.parseDepthBatch(hk).isEmpty,
                      "港股 f9 是现价，按 A 股布局读会把现价当成买一")
    }

    /// 北交所与场内基金用同一套布局（实测 2026-11-02 都有真五档）⇒ 必须收进来。
    func testBjAndEtfHaveDepth() {
        let bj = line(symbol: "bj920819", count: 87, set: [
            1: "颖泰生物", 2: "920819", 3: "2.65", 4: "2.64",
            9: "2.64", 10: "317", 19: "2.65", 20: "440",
        ])
        let etf = line(symbol: "sh510300", set: [
            1: "沪深300ETF华泰柏瑞", 2: "510300", 3: "4.083", 4: "4.080",
            9: "4.083", 10: "113108", 19: "4.084", 20: "205812",
        ])
        let merged = QuoteBook.parseDepthBatch(bj + "\n" + etf)
        XCTAssertEqual(Set(merged.keys), ["bj920819", "sh510300"])
        XCTAssertEqual(merged["sh510300"]?.bids.first?.volumeLots, 113108)
    }

    // MARK: - 分笔

    /// 实测响应（600519，2026-11-02 开盘段）。
    private let detailSample = """
    v_detail_data_sh600519=[0,"0/09:25:01/1410.00/-10.00/2207/311256090/S|\
    1/09:30:02/1404.98/-5.02/458/64310944/S|\
    2/09:30:04/1399.58/-5.40/607/85228624/S|\
    3/09:30:07/1399.64/0.06/247/34549659/B"]
    """

    func testParseTicksReadsSevenFields() {
        let ticks = QuoteBook.parseTicks(detailSample)
        XCTAssertEqual(ticks.count, 4)
        XCTAssertEqual(ticks[0].index, 0)
        XCTAssertEqual(ticks[0].time, "09:25:01")
        XCTAssertEqual(ticks[0].price, 1410.00)
        XCTAssertEqual(ticks[0].delta, -10.00, "第 4 字段是**较上一笔**的价差")
        XCTAssertEqual(ticks[0].volumeLots, 2207)
        XCTAssertEqual(ticks[0].amount, 311256090)
        XCTAssertEqual(ticks[0].side, .sell)
        XCTAssertEqual(ticks[3].side, .buy)
    }

    /// 单位判据（不是相等判据）：一笔是几秒窗口的聚合，`价×量` 与 `额` 有零点几个百分点出入，
    /// 但**量按手算比值 ≈1、按股算比值 ≈100** —— 这条钉的是量级，不是精度。
    func testTickAmountMatchesPriceTimesLotsInMagnitude() {
        for t in QuoteBook.parseTicks(detailSample) {
            let impliedByLots = t.price * t.volumeLots * 100
            XCTAssertGreaterThan(t.amount, impliedByLots * 0.9, "把量当手才是这个量级")
            XCTAssertLessThan(t.amount, impliedByLots * 1.1,
                              "若哪天把量当成股（不 ×100），比值会掉到 0.01 附近")
        }
    }

    func testParseTicksSkipsMalformedRows() {
        let text = "v_detail_data_sh600519=[0,\"0/09:25:01/1410.00/-10.00/2207/311256090/S|坏行|9/25:99/1/1/1/1/B\"]"
        XCTAssertEqual(QuoteBook.parseTicks(text).count, 1, "坏行跳过，不整批作废")
        XCTAssertTrue(QuoteBook.parseTicks("没有中括号").isEmpty)
    }

    func testTickSideUnknownLetterIsNeutralNotBuy() {
        XCTAssertEqual(TickSide(code: "B"), .buy)
        XCTAssertEqual(TickSide(code: "S"), .sell)
        XCTAssertEqual(TickSide(code: "M"), .neutral, "M = 中性盘（含集合竞价）")
        XCTAssertEqual(TickSide(code: "?"), .neutral, "认不出的字母不硬猜方向")
    }

    // MARK: - 行情日与页数

    /// 真实响应（2026-11-02 10:25，600519）：`action=last` 按页给出每页的时间跨度 ⇒ 16 段 = 16 页。
    func testParseSessionGivesExactPageCount() throws {
        let text = "v_detail_time_sh600519=[20261102,\"09:25:01~09:33:25|09:33:28~09:36:55|"
            + "09:36:58~09:40:25|09:40:28~09:43:55|09:43:58~09:47:25|09:47:28~09:50:55|"
            + "09:50:58~09:54:25|09:54:28~09:57:55|09:57:58~10:01:25|10:01:28~10:04:55|"
            + "10:04:58~10:08:25|10:08:28~10:11:55|10:11:58~10:15:25|10:15:28~10:18:55|"
            + "10:18:58~10:22:28|10:22:31~10:25:40\"]"
        let s = try XCTUnwrap(QuoteBook.parseSession(text))
        XCTAssertEqual(s.date, "20261102")
        XCTAssertEqual(s.pageCount, 16)
        XCTAssertEqual(s.lastPage, 15, "末页 = 段数-1（不是估出来的）")
        XCTAssertEqual(s.pageRanges.last, "10:22:31~10:25:40")
    }

    /// **判别性用例**：少一段就等于少数一页 ⇒ 末页会退到**旧的一页**，
    /// 界面上只是"分笔停在几十分钟前"，看不出任何异常。所以形状不完整就整体判失败。
    func testSessionRejectsPartialOrForeignShapes() {
        XCTAssertNil(QuoteBook.parseSession("v_detail_time_sh600519=[20261102,\"09:25:01~09:33:25|坏段\"]"))
        XCTAssertNil(QuoteBook.parseSession("v_detail_time_sh600519=[20261102,\"\"]"), "空跨度 = 没数据")
        XCTAssertNil(QuoteBook.parseSession("v_detail_time_sh600519=[09:25:01~09:33:25]"), "没有 8 位行情日")
        XCTAssertNil(QuoteBook.parseSession(detailSample),
                     "data 响应的第一段是页码（1 位），不能被当成本响应解析成\"只有 1 页\"")
    }

    // MARK: - URL 闸门

    func testTickURLMarkets() throws {
        let url = try XCTUnwrap(QuoteBookSource.tickURL("sh600519", page: 3))
        XCTAssertTrue(url.contains("c=sh600519"), url)
        XCTAssertTrue(url.hasSuffix("&p=3"), url)
        XCTAssertNotNil(QuoteBookSource.tickURL("sz000001", page: 0))
        // 实测这三家在该接口一律空 body（2026-11-02）⇒ 不发请求
        XCTAssertNil(QuoteBookSource.tickURL("bj920819", page: 0))
        XCTAssertNil(QuoteBookSource.tickURL("hk00700", page: 0))
        XCTAssertNil(QuoteBookSource.tickURL("sh000001", page: 0), "指数不发请求")
        XCTAssertNil(QuoteBookSource.tickURL("sh60051", page: 0), "代码形状非法")
        XCTAssertNil(QuoteBookSource.tickURL("sh600519", page: -1), "负页码不拼进 URL")
    }

    // MARK: - TicksOutcome 区分不支持 / 确认空 / 网络失败 / 成功

    private final class MockTicksProtocol: URLProtocol {
        nonisolated(unsafe) static var handler: ((URL) -> (Int, Data, Error?))?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}

        override func startLoading() {
            guard let url = request.url, let handler = Self.handler else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            let (status, data, err) = handler(url)
            if let err {
                client?.urlProtocol(self, didFailWithError: err)
                return
            }
            let resp = HTTPURLResponse(url: url, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    func testTicksOutcomeDistinguishesUnsupportedEmptyAndTimeout() async {
        // 北交所不受该分笔接口支持 → 直接 .unsupported（无网络请求）
        let bjOutcome = await QuoteBookSource.latestTicksOutcome("bj920819", limit: 60)
        XCTAssertEqual(bjOutcome, .unsupported)

        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockTicksProtocol.self]
        HTTPFetch.sessionOverride = URLSession(configuration: cfg)
        defer {
            HTTPFetch.sessionOverride = nil
            MockTicksProtocol.handler = nil
        }

        // 超时（sh600991 独享测试代码，避免与 TTL 缓存碰撞）→ .failed，不得误标 .unsupported
        MockTicksProtocol.handler = { _ in
            (0, Data(), URLError(.timedOut))
        }
        let timedOut = await QuoteBookSource.latestTicksOutcome("sh600991", limit: 60)
        XCTAssertEqual(timedOut, .failed)

        // 接口明确返回当日无页数 span → .empty
        MockTicksProtocol.handler = { _ in
            (200, Data(#"v_detail_time_sh600992=[20261102,""]"#.utf8), nil)
        }
        let emptyDay = await QuoteBookSource.latestTicksOutcome("sh600992", limit: 60)
        XCTAssertEqual(emptyDay, .empty)

        // 正常拿到 session + 末页数据 → .loaded
        MockTicksProtocol.handler = { url in
            if url.absoluteString.contains("action=last") {
                return (200, Data(#"v_detail_time_sh600993=[20261102,"09:25:01~09:33:25"]"#.utf8), nil)
            }
            return (200, Data(#"v_detail_data_sh600993=[0,"0/09:25:01/10.00/0.00/100/100000/B"]"#.utf8), nil)
        }
        let loaded = await QuoteBookSource.latestTicksOutcome("sh600993", limit: 60)
        if case .loaded(let rows) = loaded {
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(rows.first?.price, 10.0)
        } else {
            XCTFail("期望 .loaded，实际：\(loaded)")
        }
    }
}
