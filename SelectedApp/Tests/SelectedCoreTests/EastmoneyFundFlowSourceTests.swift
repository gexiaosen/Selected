import XCTest
@testable import SelectedCore

/// 东财口径资金流（`push2his…/fflow/daykline/get`）。
///
/// 这个文件存在的意义是**把"它和新浪不是一回事"钉成测试**：
/// 两家都叫"主力净流入"，但 2026-09-21 的 600000 上新浪 `r0_net` = -89,652,312.56、
/// 东财 = -31,464,037.00（差 2.9 倍；10-30 那天甚至**反号**）。
/// 分档阈值与主动买卖认定规则不同 ⇒ 把东财的行写进 `stock_fund_flows.main_net`
/// 就是**同一列混两种定义**，而且数字看着完全正常、没有任何测试能发现。
/// 所以下面既有"解析正确"的用例，也有一条**反合并**用例：证明收盘价/涨跌幅能对齐、
/// 而净额对不齐 —— 谁想合并，这条会先红。
final class EastmoneyFundFlowSourceTests: XCTestCase {

    /// 真实响应片段（600000，2026-09-21 / 10-30）
    private func response(_ klines: [String]) -> String {
        let joined = klines.map { "\"\($0)\"" }.joined(separator: ",")
        return "{\"rc\":0,\"data\":{\"code\":\"600000\",\"name\":\"浦发银行\",\"klines\":[\(joined)]}}"
    }

    private let day0921 =
        "2026-09-21,-31464037.0,-25310200.0,56774239.0,12970967.0,-44435004.0,"
        + "-5.30,-4.26,9.57,2.19,-7.49,9.01,-0.66,0.00,0.00"
    private let day1030 =
        "2026-10-30,7525885.0,-47578525.0,40052640.0,-12045144.0,19571029.0,"
        + "1.16,-7.35,6.18,-1.86,3.02,10.02,0.30,0.00,0.00"

    func testParsesFieldsInEndpointOrderWithIdentities() throws {
        let rows = EastmoneyFundFlowSource.parseHistory(response([day0921, day1030]), code: "600000")
        XCTAssertEqual(rows.count, 2)
        let a = try XCTUnwrap(rows.first)
        XCTAssertEqual(a.date, "2026-09-21")
        XCTAssertEqual(a.code, "600000")
        XCTAssertEqual(a.close, 9.01)
        XCTAssertEqual(a.mainNet, -31_464_037)
        XCTAssertEqual(a.largeNet, 12_970_967)
        XCTAssertEqual(a.superLargeNet, -44_435_004)
        XCTAssertEqual(a.mediumNet, 56_774_239)
        XCTAssertEqual(a.smallNet, -25_310_200)
        // 字段顺序的恒等式（接口改版 → 顺序一变，这两条立刻红，而不是静默错位）
        XCTAssertEqual(a.mainNet, a.largeNet + a.superLargeNet, accuracy: 1,
                       "主力 = 大单 + 超大单")
        XCTAssertEqual(a.smallNet + a.mediumNet + a.mainNet, 0, accuracy: 5,
                       "东财把全市场看成零和 ⇒ 它没有「总净流入」这个概念（元级四舍五入，实测差 ≤2）")
    }

    /// 百分数 → 小数（与 `FundFlowPoint.changePct` / `mainRatio` 全项目口径一致）。
    func testPercentsAreNormalizedToFraction() throws {
        let rows = EastmoneyFundFlowSource.parseHistory(response([day1030]), code: "600000")
        let b = try XCTUnwrap(rows.first)
        XCTAssertEqual(b.changePct, 0.0030, accuracy: 0.00005, "接口给 0.30（百分数）")
        XCTAssertEqual(b.mainRatio, 0.0116, accuracy: 0.00005, "接口给 1.16（百分数）")
    }

    /// **反合并用例**：与新浪同一天对照 —— 收盘价/涨跌幅能对齐（证明字段读对了），
    /// 主力净额却差 2.9 倍（证明**不能**当成同一个数互换）。
    /// 新浪那两个值取自仓库夹具 `fundflow_history.json`（真实捕获）。
    func testCaliberDiffersFromSinaSoNoSwapping() throws {
        let sina = FundFlowSource.parseHistory(try fixtureText("fundflow_history.json"), code: "600000")
        let sina0921 = try XCTUnwrap(sina.first { $0.date == "2026-09-21" })
        let em0921 = try XCTUnwrap(
            EastmoneyFundFlowSource.parseHistory(response([day0921]), code: "600000").first)

        XCTAssertEqual(em0921.close, sina0921.close, accuracy: 0.005, "收盘价同源同值")
        XCTAssertEqual(em0921.changePct, sina0921.changePct, accuracy: 0.0001, "涨跌幅同值（单位已对齐）")
        XCTAssertNotEqual(em0921.mainNet, sina0921.mainNet, "主力净额**不是**同一个定义")
        XCTAssertGreaterThan(abs(sina0921.mainNet - em0921.mainNet) / abs(em0921.mainNet), 1.0,
                             "差到一倍以上 ⇒ 谁想把两条链路合并成一个源，这条先红")
    }

    func testBadRowsAreSkipped() {
        let rows = EastmoneyFundFlowSource.parseHistory(
            response(["坏行", "2026-13-45,1,1,1,1,1", day0921]), code: "600000")
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(EastmoneyFundFlowSource.parseHistory("{}", code: "600000").isEmpty)
        XCTAssertTrue(EastmoneyFundFlowSource.parseHistory(
            "{\"data\":{\"klines\":[]}}", code: "600000").isEmpty, "空序列不是解析失败，就是没数据")
    }

    func testURLShapeAndCodeGate() throws {
        let url = try XCTUnwrap(EastmoneyFundFlowSource.historyURL(code: "600000", days: 20))
        XCTAssertTrue(url.hasPrefix(DataSourceEndpoints.eastmoneyPush2His + "/api/qt/stock/fflow/daykline/get"),
                      url)
        XCTAssertTrue(url.contains("secid=1.600000"), "沪市 secid 前缀 1")
        XCTAssertTrue(url.contains("lmt=20"), url)
        XCTAssertTrue(url.contains(EastmoneyFundFlowSource.fields2), "fields2 顺序是解析依赖的口径")
        XCTAssertTrue(try XCTUnwrap(EastmoneyFundFlowSource.historyURL(code: "000001", days: 5))
                      .contains("secid=0.000001"), "深市 secid 前缀 0")
        XCTAssertTrue(try XCTUnwrap(EastmoneyFundFlowSource.historyURL(code: "430017", days: 5))
                      .contains("secid=0.430017"), "北交所也是 0")
        XCTAssertNil(EastmoneyFundFlowSource.historyURL(code: "60000", days: 5), "代码形状非法不拼 URL")
        XCTAssertNil(EastmoneyFundFlowSource.historyURL(code: "sh600000", days: 5))
        XCTAssertTrue(EastmoneyFundFlowSource.historyURL(code: "600000", days: 0) == nil
                        || EastmoneyFundFlowSource.historyURL(code: "600000", days: 0)!.contains("lmt=1"),
                      "days<=0 由 fetchHistory 直接拒，URL 侧也要夹住")
    }

    /// 越界 `days` 必须夹住（不能把 999999 拼进 URL 去打源）
    func testDaysAreClamped() throws {
        let url = try XCTUnwrap(EastmoneyFundFlowSource.historyURL(code: "600000", days: 99_999))
        XCTAssertTrue(url.contains("lmt=\(EastmoneyFundFlowSource.maxDays)"), url)
    }

    /// 与 `FundFlowTests` 同一套夹具约定：文件缺失 = **失败**，不是跳过
    /// （跳过会把"仓库不完整"伪装成全绿）。
    private static let fixturesDir: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")

    private func fixtureText(_ name: String) throws -> String {
        let url = Self.fixturesDir.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw EntityTestSupport.FixtureMissing(
                path: "Tests/SelectedCoreTests/Fixtures/\(name)")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
