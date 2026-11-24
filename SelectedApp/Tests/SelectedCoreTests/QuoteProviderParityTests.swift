import XCTest
@testable import SelectedCore

/// 三家行情源**同一只票解析出同一套数字** —— 这是接口池能互相顶替的前提。
///
/// ## 为什么必须逐项对
/// 切换源时最坏的事故不是"没数据"，而是"数字悄悄变了"：
/// 成交量单位（手/股）、成交额单位（万元/元）、市值（亿/元）每家都不同。
/// 这里用**同一天的同一只票**（2026-10-30 收盘快照）钉住换算口径。
///
/// ⚠ **PE 不参与对比**：腾讯是静态/TTM 口径、东财是动态口径（实测 600519：21.37 vs 19.55），
///   两者本来就不是同一个数 —— 比它会得到假阳性。
final class QuoteProviderParityTests: XCTestCase {

    // MARK: - 腾讯样例（600519，2026-10-30 收盘）

    private func tencentLine() -> String {
        var f = Array(repeating: "", count: 60)
        f[0] = "1"; f[1] = "贵州茅台"; f[2] = "600519"
        f[3] = "1392.05"; f[4] = "1354.00"; f[5] = "1363.00"; f[6] = "59927"
        f[30] = "20261030161455"
        f[31] = "38.05"; f[32] = "2.81"; f[33] = "1393.37"; f[34] = "1352.98"
        f[36] = "59927"; f[37] = "825738"; f[38] = "0.48"; f[39] = "21.37"
        f[43] = "2.98"; f[44] = "17401.76"; f[45] = "17401.76"; f[46] = "6.93"
        f[47] = "1489.40"; f[48] = "1218.60"; f[49] = "1.36"; f[51] = "1377.90"
        return "v_sh600519=\"" + f.joined(separator: "~") + "\";"
    }

    private func eastmoneyJSON() -> Any {
        let row: [String: Any] = [
            "f2": 1392.05, "f3": 2.81, "f4": 38.05, "f5": 59927,
            "f6": 8_257_381_778.0, "f8": 0.48, "f9": 19.55, "f10": 1.36,
            "f12": "600519", "f13": 1, "f14": "贵州茅台",
            "f15": 1393.37, "f16": 1352.98, "f17": 1363.0, "f18": 1354.0,
            "f20": 1_740_176_092_672.0, "f21": 1_740_176_092_672.0, "f23": 6.93,
            "f124": 1_793_347_921,
        ]
        return ["data": ["diff": [row]]]
    }

    private func sinaLine() -> String {
        var f = Array(repeating: "0", count: 33)
        f[0] = "贵州茅台"; f[1] = "1363.000"; f[2] = "1354.000"; f[3] = "1392.050"
        f[4] = "1393.370"; f[5] = "1352.980"
        f[8] = "5992729"; f[9] = "8257381778.000"
        f[30] = "2026-10-30"; f[31] = "15:34:59"
        return "var hq_str_sh600519=\"" + f.joined(separator: ",") + "\";"
    }

    // MARK: - 核心字段

    func testThreeProvidersAgreeOnCoreFields() throws {
        let t = try XCTUnwrap(StockQuotes.parseBatchFullKeys(tencentLine())["sh600519"])
        let e = try XCTUnwrap(EastmoneyQuoteProvider.parse(eastmoneyJSON(),
                                                           mapping: ["1.600519": "sh600519"])["sh600519"])
        let s = try XCTUnwrap(SinaQuoteProvider.parse(sinaLine())["sh600519"])

        for q in [t, e, s] {
            XCTAssertEqual(q.currentPrice, 1392.05, accuracy: 0.001)
            XCTAssertEqual(q.previousClose, 1354.00, accuracy: 0.001)
            XCTAssertEqual(q.change, 38.05, accuracy: 0.01)
            XCTAssertEqual(q.changePercent, 2.81, accuracy: 0.01)
            XCTAssertEqual(q.highPrice, 1393.37, accuracy: 0.001)
            XCTAssertEqual(q.lowPrice, 1352.98, accuracy: 0.001)
            XCTAssertEqual(q.name, "贵州茅台")
            XCTAssertEqual(q.code, "600519")
            XCTAssertNotNil(q.quoteTime, "\(q.market) 源必须给行情时间戳，否则新鲜度打分失效")
        }
    }

    /// 成交量统一成**手**、成交额统一成**万元**
    func testVolumeAndTurnoverUnitsMatch() throws {
        let t = try XCTUnwrap(StockQuotes.parseBatchFullKeys(tencentLine())["sh600519"])
        let e = try XCTUnwrap(EastmoneyQuoteProvider.parse(eastmoneyJSON(),
                                                           mapping: ["1.600519": "sh600519"])["sh600519"])
        let s = try XCTUnwrap(SinaQuoteProvider.parse(sinaLine())["sh600519"])

        // 成交量：59927 手（新浪给的是股，已 /100）
        XCTAssertEqual(t.volume, 59927, accuracy: 0.01)
        XCTAssertEqual(e.volume, 59927, accuracy: 0.01)
        XCTAssertEqual(s.volume, 59927.29, accuracy: 0.01)

        // 成交额：825738 万元
        XCTAssertEqual(t.turnover, 825738, accuracy: 0.5)
        XCTAssertEqual(e.turnover, 825738.18, accuracy: 0.5)
        XCTAssertEqual(s.turnover, 825738.18, accuracy: 0.5)
    }

    /// 只有腾讯有涨跌停价 / PE / PB / 市值 —— 能力声明必须与实现一致
    func testCapabilityDifferencesAreReal() throws {
        let t = try XCTUnwrap(StockQuotes.parseBatchFullKeys(tencentLine())["sh600519"])
        let e = try XCTUnwrap(EastmoneyQuoteProvider.parse(eastmoneyJSON(),
                                                           mapping: ["1.600519": "sh600519"])["sh600519"])
        let s = try XCTUnwrap(SinaQuoteProvider.parse(sinaLine())["sh600519"])

        XCTAssertEqual(t.limitUp, 1489.40)
        XCTAssertNil(e.limitUp, "东财 ulist 不给涨跌停价 —— 能力声明里也没有")
        XCTAssertNil(s.limitUp)

        XCTAssertEqual(e.pbRatio ?? 0, 6.93, accuracy: 0.001)
        XCTAssertEqual(t.pbRatio ?? 0, 6.93, accuracy: 0.001)
        XCTAssertNil(s.pbRatio)

        XCTAssertEqual(e.marketCap ?? 0, 17401.76, accuracy: 0.01)
        XCTAssertNil(s.marketCap)

        XCTAssertTrue(TencentQuoteProvider().capabilities.contains(.limitPrices))
        XCTAssertFalse(EastmoneyQuoteProvider().capabilities.contains(.limitPrices))
        XCTAssertFalse(SinaQuoteProvider().capabilities.contains(.valuation))
    }

    // MARK: - 港股

    func testHongKongTurnoverIsWanYuanEverywhere() throws {
        // 腾讯 hk00700：f37 是**元**（8,540,915,574），模型里必须是万元
        var f = Array(repeating: "", count: 60)
        f[0] = "100"; f[1] = "腾讯控股"; f[2] = "00700"; f[3] = "383.600"; f[4] = "377.600"
        f[5] = "376.400"; f[6] = "22269954"; f[30] = "20261030162000"
        f[31] = "6.000"; f[32] = "1.59"; f[33] = "387.600"; f[34] = "375.200"
        f[36] = "22269954"; f[37] = "8540915574.008"; f[38] = "0.24"; f[39] = "13.07"
        f[43] = "3.28"; f[44] = "34879.39"; f[45] = "34879.39"; f[46] = "2.67"
        f[49] = "1.10"; f[51] = "383.400"
        let t = try XCTUnwrap(StockQuotes.parseBatchFullKeys(
            "v_hk00700=\"" + f.joined(separator: "~") + "\";")["hk00700"])
        XCTAssertEqual(t.turnover, 854091.56, accuracy: 1)
        XCTAssertEqual(t.volume, 22_269_954, accuracy: 1)
        XCTAssertNil(t.limitUp, "港股没有涨跌停 —— 不能把 f47/f48 的 52 周高当成涨跌停")

        let emRow: [String: Any] = ["f2": 383.6, "f3": 1.59, "f4": 6.0, "f5": 22_269_954,
                                    "f6": 8_540_915_456.0, "f12": "00700", "f13": 116,
                                    "f14": "腾讯控股", "f15": 387.6, "f16": 375.2,
                                    "f17": 376.4, "f18": 377.6, "f124": 1_793_347_686]
        let e = try XCTUnwrap(EastmoneyQuoteProvider.parse(["data": ["diff": [emRow]]],
                                                           mapping: ["116.00700": "hk00700"])["hk00700"])
        XCTAssertEqual(e.turnover, 854091.55, accuracy: 1)
        XCTAssertEqual(e.currentPrice, 383.6, accuracy: 0.001)
    }

    /// 新浪港股 11/12 顺序与 A 股相反（成交额在前、成交量在后）
    func testSinaHongKongFieldOrder() throws {
        var f = Array(repeating: "0", count: 19)
        f[0] = "TENCENT"; f[1] = "腾讯控股"
        f[2] = "376.400"; f[3] = "377.600"; f[4] = "387.600"; f[5] = "375.200"
        f[6] = "383.800"; f[7] = "6.200"; f[8] = "1.642"
        f[11] = "6854609974"; f[12] = "17873954"
        f[17] = "2026/10/30"; f[18] = "16:05"
        let line = "var hq_str_hk00700=\"" + f.joined(separator: ",") + "\";"
        let q = try XCTUnwrap(SinaQuoteProvider.parse(line)["hk00700"])
        XCTAssertEqual(q.name, "腾讯控股")
        XCTAssertEqual(q.currentPrice, 383.8, accuracy: 0.001)
        XCTAssertEqual(q.volume, 17_873_954, accuracy: 1)          // 12 = 成交量
        XCTAssertEqual(q.turnover, 685460.9974, accuracy: 0.01)    // 11 = 成交额 → 万元
    }

    // MARK: - 指数

    /// 指数成交量三条源给的是同一个数 —— 新浪那条**不能再 /100**
    func testSinaIndexVolumeIsNotConverted() throws {
        var f = Array(repeating: "0", count: 33)
        f[0] = "上证指数"; f[1] = "3605.6451"; f[2] = "3651.4337"; f[3] = "3599.0166"
        f[4] = "3660.2061"; f[5] = "3595.2584"
        f[8] = "497973940"; f[9] = "764227190865"
        f[30] = "2026-10-30"; f[31] = "15:36:00"
        let line = "var hq_str_sh000001=\"" + f.joined(separator: ",") + "\";"
        let q = try XCTUnwrap(SinaQuoteProvider.parse(line)["sh000001"])
        XCTAssertEqual(q.volume, 497_973_940, accuracy: 1)
        XCTAssertEqual(q.turnover, 76_422_719.0865, accuracy: 0.01)
    }
}
