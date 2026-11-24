import XCTest
@testable import SelectedCore

/// 自选判定实体 vs **真实引擎输出**
///
/// 夹具 `engine/tests/fixtures/watch_outputs/*.json` 是 Swift 真实产出、手工捕获、不可再生：
/// `base` / `red` / `noround` 三种场景 + `not_in_watchlist`（`judged == 0` 的另一种形态）。
final class WatchEntityTests: XCTestCase {

    private func load(_ name: String) throws -> JSONValue {
        try EntityTestSupport.fixture("engine/tests/fixtures/watch_outputs/\(name).json")
    }

    private func checkAll(_ r: WatchJudgeResult, _ label: String) throws {
        try EntityTestSupport.check(WatchJudgeResult.self, r.json, label)
        for (i, v) in r.results.enumerated() {
            try EntityTestSupport.check(WatchVerdict.self, v.json, "\(label).results[\(i)]")
        }
    }

    func testBaseCoversExactlyAndRoundTrips() throws { try checkAll(WatchJudgeResult(try load("base")), "base") }
    func testRedCoversExactlyAndRoundTrips() throws { try checkAll(WatchJudgeResult(try load("red")), "red") }
    func testNoRoundCoversExactlyAndRoundTrips() throws {
        try checkAll(WatchJudgeResult(try load("noround")), "noround")
    }

    /// `judged == 0`（代码不在自选中）时**只输出 5 键** —— 另一种形态
    func testNotInWatchlistShapeIsCovered() throws {
        let r = WatchJudgeResult(try load("not_in_watchlist"))
        XCTAssertEqual(r.judged, 0)
        XCTAssertTrue(r.isOK)
        XCTAssertTrue(r.results.isEmpty, "没有标的可判定")
        XCTAssertTrue(r.buys.isEmpty)
        XCTAssertTrue(r.sells.isEmpty)
        XCTAssertEqual(r.marketTrend, "")
        XCTAssertFalse(r.summary.isEmpty)
        XCTAssertTrue(r.summary.contains("不在自选中"))
    }

    // MARK: - 类型化取值

    func testBaseTypedValues() throws {
        let r = WatchJudgeResult(try load("base"))
        XCTAssertEqual(r.judged, 8)
        XCTAssertEqual(r.results.count, 8, "judged 应与 results 条数一致")
        XCTAssertEqual(r.marketLight, "黄灯")
        XCTAssertFalse(r.marketTrend.isEmpty)
        XCTAssertFalse(r.summary.isEmpty)
        XCTAssertEqual(r.buys.count, 1, "base 场景买入 1 只")
        XCTAssertEqual(r.sells.count, 3, "base 场景卖出 3 只")
        XCTAssertEqual(r.date, "2026-09-21")

        // 逐字段断言取值（键覆盖/无损往返验不了"取值口径"）
        let v = try XCTUnwrap(r.results.first { $0.code == "603031" })
        XCTAssertEqual(v.name, "安孚科技")
        XCTAssertEqual(v.action, "买入")
        XCTAssertEqual(v.score, 105)
        XCTAssertEqual(v.riskLevel, "高")
        XCTAssertEqual(v.positionAdvice, "轻仓")
        XCTAssertEqual(v.marketLight, "黄灯")
        XCTAssertFalse(v.isHolding, "未持仓")
        XCTAssertNil(v.costPrice, "未持仓 → 成本价是 null（不是 0）")
        XCTAssertNil(v.shares)
        XCTAssertEqual(v.baselinePrice, 43.62)
        XCTAssertEqual(v.price, 43.62)
        XCTAssertEqual(v.targetPrice, 44.06)
        XCTAssertLessThan(v.stopLossPrice, v.price, "止损价应低于现价")
        XCTAssertEqual(v.sellWindow, "09:30~10:00")
        XCTAssertFalse(v.scoreDetails.isEmpty)
        XCTAssertTrue(v.penaltyDetails.isEmpty)

        // 卖出是 `[原因, 名称]` 二元组
        let sell = try XCTUnwrap(r.sells.first)
        XCTAssertEqual(sell.count, 2)
        XCTAssertFalse(sell[0].isEmpty, "第一项是卖出原因")
        XCTAssertFalse(sell[1].isEmpty, "第二项是标的名称")
    }

    /// **数据缺失**形态（行情取不到）：13 键、缺 5 个、价位字段为 `null`。
    /// 这是键覆盖测试抓出来的第二种 `WatchVerdict` 形状。
    func testDataMissingVerdictDegradesSafely() throws {
        let r = WatchJudgeResult(try load("base"))
        let v = try XCTUnwrap(r.results.first { $0.code == "999998" })
        XCTAssertTrue(v.isDataMissing)
        XCTAssertEqual(v.action, "数据缺失")
        XCTAssertEqual(v.name, "不存在")
        XCTAssertNil(v.priceOrNil, "行情取不到 → price 键缺失 → nil（不是 0）")
        XCTAssertNil(v.scoreOrNil, "评分是 null（不是 0 分）")
        XCTAssertNil(v.riskLevelDash == "-" ? nil : "", "risk_level 为 null → 展示破折号")
        XCTAssertNil(v.targetPriceOrNil)
        XCTAssertNil(v.stopLossPriceOrNil)
        XCTAssertNil(v.baselinePriceOrNil)
        XCTAssertEqual(v.sellWindowDash, "-")
        XCTAssertEqual(v.scoreDetails, ["行情获取失败"], "失败原因写在加分明细里")
        XCTAssertFalse(v.isHolding, "缺键 → false")
        // 正常条目仍有这些键
        let normal = try XCTUnwrap(r.results.first { $0.code == "603031" })
        XCTAssertNotNil(normal.scoreOrNil)
        XCTAssertNotNil(normal.priceOrNil)
        XCTAssertFalse(normal.isDataMissing)
    }

    func testRedScenarioHasNoBuys() throws {
        let r = WatchJudgeResult(try load("red"))
        XCTAssertEqual(r.marketLight, "红灯")
        XCTAssertTrue(r.buys.isEmpty, "红灯日不买入")
        XCTAssertEqual(r.results.count, r.judged)
        XCTAssertTrue(r.results.allSatisfy { $0.marketLight == "红灯" })
    }

    func testNoRoundScenarioStillJudges() throws {
        let r = WatchJudgeResult(try load("noround"))
        XCTAssertEqual(r.judged, 8, "无轮次数据也应完成判定（走兜底口径）")
        XCTAssertFalse(r.summary.isEmpty)
    }

    // MARK: - 可空字段：`null` 与 `0` 必须能区分

    func testHoldingFieldsKeepNullDistinctFromZero() {
        let notHolding = WatchVerdict(JSONValue(["cost_price": NSNull(), "shares": NSNull()]))
        XCTAssertNil(notHolding.costPrice)
        XCTAssertNil(notHolding.shares)

        let holding = WatchVerdict(JSONValue(["cost_price": 12.5, "shares": 0.0]))
        XCTAssertEqual(holding.costPrice, 12.5)
        XCTAssertEqual(holding.shares, 0, "份额 0 是真实值，不是\"没有\"")
        XCTAssertTrue(holding.isHolding == false, "is_holding 缺省 false（与引擎一致）")
    }

    // MARK: - 缺键退化

    func testEmptyResultFallsBackWithoutCrash() throws {
        let r = WatchJudgeResult(JSONValue([:]))
        XCTAssertEqual(r.status, "ok", "status 缺省 ok")
        XCTAssertEqual(r.judged, 0)
        XCTAssertTrue(r.results.isEmpty)
        XCTAssertTrue(r.sells.isEmpty)
        XCTAssertEqual(r.marketLightDash, "-")
        try EntityTestSupport.assertLossless(r, r.json, "watch-empty")
    }
}
