import XCTest
@testable import SelectedCore

/// 同花顺日K兜底源（`d.10jqka.com.cn/v6/line/hs_{code}/01/last.js`）。
///
/// 这条链路的全部风险都在**单位与口径**，而不是"能不能解析"：
///   · 量是**股**（腾讯是手）⇒ 漏除 100，成交量与换手全部大 100 倍；
///   · 行的字段序是 `日,开,高,低,收,…`（腾讯是 `日,开,收,高,低`）⇒ 照抄腾讯的下标会把
///     最高价当收盘价，图上看得到但没人会怀疑；
///   · `hs_000001` 返回的是**平安银行**（同数字不同市场）⇒ 指数必须挡在 URL 之外。
/// 下面每条都用 2026-11-02 的真实响应值，并与腾讯同日行做**交叉对照**。
final class KLineService10jqkaTests: XCTestCase {

    /// 600519 2026-10-29 / 10-30 两天（真实 `01/last.js` 的 `data` 片段）
    private func payload(_ rows: [String]) -> String {
        "quotebridge_v6_line_hs_600519_01_last({\"num\":\(rows.count),\"data\":\"\(rows.joined(separator: ";"))\"})"
    }

    func testParsesRowsWithUnitConversion() throws {
        let items = KLineService.parse10jqkaKLines(payload([
            "20261029,1349.99,1356.00,1330.01,1354.00,4299231,5797980300.00,0.344,,1200.00,1624800",
            "20261030,1363.00,1393.37,1352.98,1392.05,5992729,8257381800.00,0.479,,1800.00,2505690",
        ]))
        XCTAssertEqual(items.count, 2)
        let first = try XCTUnwrap(items.first)
        XCTAssertEqual(first.date, "2026-10-29", "yyyyMMdd → yyyy-MM-dd")
        XCTAssertEqual(first.open, 1349.99)
        XCTAssertEqual(first.high, 1356.00, "第 3 字段是高、第 4 是低（腾讯的顺序不同）")
        XCTAssertEqual(first.low, 1330.01)
        XCTAssertEqual(first.close, 1354.00)
        XCTAssertEqual(first.volume, 42992.31, accuracy: 0.001, "股 → 手")
        XCTAssertEqual(first.amount, 5_797_980_300, accuracy: 0.5, "成交额本来就是元，与 KLineItem 同单位")
    }

    /// **交叉对照**：同日同票与腾讯 `newfqkline` 行逐项一致（真实抓下来的两组值）。
    /// 这条同时证明"同花顺是前复权"——除权后的票上它与腾讯前复权价逐日相等（2026-11-02 三只票 × 140 天）。
    func testMatchesTencentQfqRow() throws {
        let sinaStyle = KLineService.parse10jqkaKLines(payload([
            "20261029,1349.99,1356.00,1330.01,1354.00,4299231,5797980300.00,0.344,,1200.00,1624800",
        ]))
        let tencent = KLineService.parseTencentKLines([[
            "2026-10-29", "1349.99", "1354.00", "1356.00", "1330.01",
            "42992.00", [String: Any](), "0.34", "579798.03", "",
        ]])
        XCTAssertEqual(sinaStyle.count, tencent.count)
        let a = try XCTUnwrap(sinaStyle.first), b = try XCTUnwrap(tencent.first)
        XCTAssertEqual(a.open, b.open); XCTAssertEqual(a.high, b.high)
        XCTAssertEqual(a.low, b.low); XCTAssertEqual(a.close, b.close)
        XCTAssertEqual(a.volume, b.volume, accuracy: 1.0, "整手取整的误差不超过 1 手")
        XCTAssertEqual(a.amount, b.amount, accuracy: 0.5)
    }

    func testSkipsMalformedRowsAndRejectsGarbage() {
        let items = KLineService.parse10jqkaKLines(payload([
            "20261030,1363.00,1393.37,1352.98,1392.05,5992729,8257381800.00,0.479,,1800.00,2505690",
            "坏行",
            "202610,1,1,1,1,1,1",                       // 日期不合法
            "20261031,0,0,0,0,1,1",                      // 开收为 0
        ]))
        XCTAssertEqual(items.count, 1, "只跳过坏行，不整批作废")
        XCTAssertTrue(KLineService.parse10jqkaKLines("").isEmpty)
        XCTAssertTrue(KLineService.parse10jqkaKLines("not jsonp").isEmpty)
        XCTAssertTrue(KLineService.parse10jqkaKLines(#"{"data":""}"#).isEmpty,
                      "没有 JSONP 包裹 / data 为空 → 空，不猜")
    }

    func testURLCoversStocksEtfAndBjButNotIndexOrHk() throws {
        XCTAssertEqual(KLineService.thsKLineURL(fullCode: "sh600519"),
                       DataSourceEndpoints.thsKLine + "hs_600519/01/last.js")
        XCTAssertNotNil(KLineService.thsKLineURL(fullCode: "sz000001"))
        XCTAssertNotNil(KLineService.thsKLineURL(fullCode: "bj920819"), "北交所实测可用（颖泰生物）")
        XCTAssertNotNil(KLineService.thsKLineURL(fullCode: "sh510300"), "场内基金实测可用")
        // 判别性用例：hs_000001 返回平安银行，放过去就是把上证指数画成一只银行股且不报错
        XCTAssertNil(KLineService.thsKLineURL(fullCode: "sh000001"))
        XCTAssertNil(KLineService.thsKLineURL(fullCode: "hk00700"))
        XCTAssertNil(KLineService.thsKLineURL(fullCode: "sh60051"))
    }

    /// 读 `Sources/SelectedCore/<file>`（与 `QuotePoolGuardTests` 同一套定位方式：
    /// 从本文件往上三层是 `SelectedApp`，再进 Sources）。
    private func coreSource(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // SelectedCoreTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // SelectedApp
        return try String(contentsOf: root.appendingPathComponent("Sources/SelectedCore/\(name)"),
                          encoding: .utf8)
    }

    /// 兜底顺序必须是 **腾讯 → 同花顺 → 新浪**（顺序反了就变成"先用不复权的那条"，
    /// 除权股图上会出现假跳空；同花顺与主源同为前复权，理应排在前面）。
    func testFallbackOrderIsQfqBeforeUnadjusted() throws {
        let src = try coreSource("KLineService.swift")
        guard let tencent = src.range(of: "await fetchTencentKLine("),
              let ths = src.range(of: "await fetch10jqkaKLine("),
              let sina = src.range(of: "await fetchSinaKLine(") else {
            return XCTFail("三条链路都在 fetchKLineImpl 里，少一条就是接线被改了")
        }
        XCTAssertLessThan(tencent.lowerBound, ths.lowerBound, "主源必须仍是腾讯")
        XCTAssertLessThan(ths.lowerBound, sina.lowerBound, "前复权的同花顺要排在不复权的新浪之前")
    }

    /// 走了同花顺就**不许**把降级标记写成"不复权"（口径不同），且不再使用进程级共享静态标记。
    func testFallbackFlagsSetPerSource() throws {
        let src = try coreSource("KLineService.swift")
        XCTAssertFalse(src.contains("_lastFallbackSource"), "已消除全局共享降级源状态")
        XCTAssertFalse(src.contains("_lastFallbackUnadjusted"), "已消除全局共享复权状态")
        XCTAssertTrue(src.contains("KLineResult(items: items, source: .ths, adjusted: true)"),
                      "同花顺是前复权，adjusted 必须是 true")
        XCTAssertTrue(src.contains("KLineResult(items: items, source: .sina, adjusted: false)"),
                      "新浪是不复权，adjusted 必须是 false")
        XCTAssertTrue(src.contains("kline_fallback"), "换源必须写 data_source_logs")
    }

    // MARK: - 并发拉取口径隔离（离线 URLProtocol 拦截）

    private final class MockKLineProtocol: URLProtocol {
        nonisolated(unsafe) static var responder: ((URL) -> (Int, Data, Error?))?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}

        override func startLoading() {
            guard let url = request.url, let responder = Self.responder else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            let (status, data, err) = responder(url)
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

    func testConcurrentFetchesPreservePerCallFallbackMetadata() async throws {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockKLineProtocol.self]
        HTTPFetch.sessionOverride = URLSession(configuration: cfg)
        defer {
            HTTPFetch.sessionOverride = nil
            MockKLineProtocol.responder = nil
        }

        // sh600519：腾讯失败 + 同花顺失败 → 走新浪（不复权 adjusted=false）
        // sz000001：腾讯失败 → 走同花顺（前复权 adjusted=true）
        // sh600036：腾讯直接成功（.tencent, adjusted=true）
        MockKLineProtocol.responder = { url in
            let s = url.absoluteString
            if s.contains("proxy.finance.qq.com") {
                if s.contains("sh600036") {
                    let body = #"{"data":{"sh600036":{"qfqday":[["2026-10-30","40.0","41.0","41.5","39.5","1000",{},"0.5","400.0",""]]}}}"#
                    return (200, Data(body.utf8), nil)
                }
                return (500, Data("err".utf8), nil)
            }
            if s.contains("d.10jqka.com.cn") {
                if s.contains("hs_000001") {
                    let body = #"quotebridge({"num":1,"data":"20261030,10.0,10.5,9.9,10.4,10000,104000.0"})"#
                    return (200, Data(body.utf8), nil)
                }
                return (500, Data("err".utf8), nil)
            }
            if s.contains("quotes.sina.cn") && s.contains("sh600519") {
                let body = #"var _=([{"day":"2026-10-30","open":"1350.0","close":"1360.0","high":"1365.0","low":"1345.0","volume":"5000"}]);"#
                return (200, Data(body.utf8), nil)
            }
            return (404, Data(), nil)
        }

        async let rSina = KLineService.fetchKLine(fullCode: "sh600519", period: .daily, count: 10)
        async let rThs = KLineService.fetchKLine(fullCode: "sz000001", period: .daily, count: 10)
        async let rTen = KLineService.fetchKLine(fullCode: "sh600036", period: .daily, count: 10)
        let (sina, ths, tencent) = await (rSina, rThs, rTen)

        XCTAssertEqual(sina?.source, .sina)
        XCTAssertEqual(sina?.adjusted, false)
        XCTAssertEqual(ths?.source, .ths)
        XCTAssertEqual(ths?.adjusted, true)
        XCTAssertEqual(tencent?.source, .tencent)
        XCTAssertEqual(tencent?.adjusted, true)
    }
}
