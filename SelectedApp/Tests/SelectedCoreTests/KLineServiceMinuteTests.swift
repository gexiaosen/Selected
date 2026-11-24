import XCTest
@testable import SelectedCore

/// 分时双源解析契约：腾讯（累计量）与东财（分钟量 → 累加成累计量）。
///
/// ⚠ 两种源的 volume 口径不同：腾讯直接给累计量，东财给分钟量。
///   详情图按“后一点减前一点”算分钟量（见 `StockKLineChart.candles`），
///   所以东财必须在解析时累加 —— 这条一旦改错，成交量柱会整块错位且不报错。
final class KLineServiceMinuteTests: XCTestCase {

    func testParseTencentMinuteReadsTimePriceCumulativeVolume() throws {
        let json = """
        {"code":0,"data":{"sh600519":{"data":{"data":[
          "0930 1331.88 516 68725008.28",
          "0931 1323.36 1237 164351870.00",
          "bad 0 0"
        ]}}}}
        """
        let points = try XCTUnwrap(
            KLineService.parseTencentMinute(Data(json.utf8), fullCode: "sh600519"))
        XCTAssertEqual(points.map(\.time), ["09:30", "09:31"])
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points[0].price, 1331.88, accuracy: 1e-9)
        XCTAssertEqual(points[1].price, 1323.36, accuracy: 1e-9)
        XCTAssertEqual(points.map(\.volume), [516, 1237])
        XCTAssertEqual(points.map(\.amount), [68725008.28, 164351870.00])
    }

    func testParseTencentMinuteUnknownCodeReturnsNil() {
        let json = #"{"code":0,"data":{"sz000001":{"data":{"data":["0930 10.0 1 1"]}}}}"#
        XCTAssertNil(KLineService.parseTencentMinute(Data(json.utf8), fullCode: "sh600519"))
    }

    func testParseEastmoneyMinuteAccumulatesPerMinuteVolume() throws {
        let json = """
        {"data":{"trends":[
          "2026-10-21 09:30,1331.88,1331.88,1331.88,1331.88,516,68683720.00,1331.880",
          "2026-10-21 09:31,1330.88,1323.36,1331.98,1323.33,721,95668150.00,1328.633",
          "2026-10-21 09:32,1323.48,1326.50,1327.71,1323.48,303,40180527.00,1328.132"
        ]}}
        """
        let points = try XCTUnwrap(KLineService.parseEastmoneyMinute(Data(json.utf8)))
        XCTAssertEqual(points.map(\.time), ["09:30", "09:31", "09:32"])
        XCTAssertEqual(points[1].price, 1323.36, accuracy: 1e-9)
        XCTAssertEqual(points[2].price, 1326.50, accuracy: 1e-9)
        // 累计量 = 516 / 516+721 / 516+721+303
        XCTAssertEqual(points.map(\.volume), [516, 1237, 1540])
        // 累计额 = 68683720 / +95668150 / +40180527
        XCTAssertEqual(points.map(\.amount), [68683720, 164351870, 204532397])
    }

    func testEastmoneyMinuteURLUsesMarketPrefixAndSkipsHK() {
        XCTAssertTrue(KLineService.eastmoneyMinuteURL(fullCode: "sh600519")?
            .contains("secid=1.600519") == true)
        XCTAssertTrue(KLineService.eastmoneyMinuteURL(fullCode: "sz000001")?
            .contains("secid=0.000001") == true)
        XCTAssertTrue(KLineService.eastmoneyMinuteURL(fullCode: "bj430047")?
            .contains("secid=0.430047") == true)
        XCTAssertNil(KLineService.eastmoneyMinuteURL(fullCode: "hk00700"))
    }
}
