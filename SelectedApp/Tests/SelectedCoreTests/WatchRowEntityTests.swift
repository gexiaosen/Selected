import XCTest
@testable import SelectedCore

/// 自选**库行**实体 vs **真实读取结果**
///
/// 夹具 `engine/tests/fixtures/watch_row_outputs/*.json` 是**真实捕获**：
/// 用临时驱动（链接 `SelectedCore`）对测试库跑 `SQLiteReader.watchGroups()/watchlist()/
/// watchJudgments(date:)`，把输出打成 JSON —— 不是照着代码手写的。
///
/// 与 `WatchEntityTests`（判定**产出**）的区别：库行里 `is_holding` 是 **Int 0/1**、
/// `cost_price`/`shares` 的 NULL 被折成 **0**；判定产出里前者是 `Bool`、后者是 `null`。
final class WatchRowEntityTests: XCTestCase {

    private func load(_ name: String) throws -> [JSONValue] {
        try EntityTestSupport.fixture("engine/tests/fixtures/watch_row_outputs/\(name).json").array
    }

    func testGroupsCoverExactlyAndRoundTrip() throws {
        let rows = try load("groups")
        XCTAssertFalse(rows.isEmpty, "夹具应含分组（临时驱动前先往库里插了 2 个）")
        for (i, r) in rows.enumerated() {
            try EntityTestSupport.check(WatchGroupRow.self, r, "groups[\(i)]")
        }
        let g = WatchGroupRow(rows[0])
        XCTAssertEqual(g.id, 1)
        XCTAssertEqual(g.name, "默认分组")
        XCTAssertEqual(g.stockCount, 8)
        XCTAssertEqual(g.holdingCount, 5)
        let g2 = WatchGroupRow(rows[1])
        XCTAssertEqual(g2.id, 2)
        XCTAssertEqual(g2.name, "核心持仓")
        XCTAssertEqual(g2.stockCount, 0)
    }

    func testItemsCoverExactlyAndRoundTrip() throws {
        let rows = try load("items")
        XCTAssertEqual(rows.count, 8)
        for (i, r) in rows.enumerated() {
            try EntityTestSupport.check(WatchItemRow.self, r, "items[\(i)]")
        }

        let holding = WatchItemRow(try XCTUnwrap(rows.first { $0["code"].string == "603031" }))
        XCTAssertEqual(holding.name, "安孚科技")
        XCTAssertEqual(holding.groupId, 1)
        XCTAssertEqual(holding.isHoldingRaw, 1, "库行里 is_holding 是 **Int 0/1**，不是 Bool")
        XCTAssertTrue(holding.isHolding)
        XCTAssertEqual(holding.costPrice, 12.34)
        XCTAssertEqual(holding.shares, 1000)
        XCTAssertTrue(holding.hasAction, "603031 有最近一次判定动作")

        let notHolding = WatchItemRow(try XCTUnwrap(rows.first { $0["code"] == "688690" }))
        XCTAssertEqual(notHolding.isHoldingRaw, 0)
        XCTAssertFalse(notHolding.isHolding)
        XCTAssertEqual(notHolding.costPrice, 0, "库里 NULL → 读取层折成 0（不是 nil）")
        XCTAssertEqual(notHolding.shares, 0)
        XCTAssertEqual(notHolding.addedAt, "2026-09-01 09:31:00")
    }

    /// `LEFT JOIN` 无判定时后 4 个字段是空串 / 0 —— 也要能读
    func testItemWithoutJudgmentDegradesSafely() {
        let r = WatchItemRow(JSONValue(["code": "000001", "name": "", "group_id": 1]))
        XCTAssertEqual(r.action, "")
        XCTAssertFalse(r.hasAction)
        XCTAssertEqual(r.score, 0)
        XCTAssertEqual(r.targetPrice, 0)
        XCTAssertEqual(r.displayName, "000001", "名称为空 → 回落代码")
        XCTAssertEqual(r.groupId, 1)
    }

    func testJudgmentsCoverExactlyAndRoundTrip() throws {
        let rows = try load("judgments")
        XCTAssertFalse(rows.isEmpty)
        for (i, r) in rows.enumerated() {
            try EntityTestSupport.check(WatchJudgmentRow.self, r, "judgments[\(i)]")
        }

        let j = WatchJudgmentRow(rows[0])
        XCTAssertFalse(j.code.isEmpty)
        XCTAssertFalse(j.name.isEmpty)
        XCTAssertFalse(j.action.isEmpty)
        XCTAssertGreaterThan(j.score, 0)
        XCTAssertFalse(j.marketLight.isEmpty, "库行里 market_light 一定有值（判定时写入）")
        // `details` 是嵌套对象（`score_details` / `penalty_details`）
        XCTAssertEqual(Set(j.details.dict.keys).isSubset(of: ["score_details", "penalty_details"]), true,
                       "details 只含这两个键")
    }

    /// 库行里 `sell_window` / `position_advice` / `risk_level` 可能是 **NULL → 空串**
    /// （写入时该字段就没有值）。
    ///
    /// `*Dash` 的口径是 `string ?? "-"`：
    /// **空串仍是空串**，只有**键缺失/非字符串**才兜破折号。这里两种都断言，
    /// 免得以后有人把它改成"空串也兜破折号"（那是行为变更）。
    func testJudgmentNullishTextFieldsFallBackToDash() {
        let blank = WatchJudgmentRow(JSONValue([
            "code": "000088", "name": "盐田港", "action": "买入",
            "sell_window": "", "position_advice": "", "risk_level": "",
        ]))
        XCTAssertEqual(blank.sellWindow, "")
        XCTAssertEqual(blank.sellWindowDash, "", "空串保持空串（`string ?? \"-\"` 的口径）")
        XCTAssertEqual(blank.positionAdviceDash, "")
        XCTAssertEqual(blank.riskLevelDash, "")

        // 键缺失（不是空串）→ 兜破折号
        let missing = WatchJudgmentRow(JSONValue([:]))
        XCTAssertEqual(missing.sellWindowDash, "-")
        XCTAssertEqual(missing.nameDash, "-")
        XCTAssertEqual(missing.positionAdviceDash, "-")
        // 非字符串（DB 里 NULL 经 jdict 后可能是 NSNull）→ 也兜破折号
        let nulled = WatchJudgmentRow(JSONValue(["sell_window": NSNull()]))
        XCTAssertEqual(nulled.sellWindowDash, "-")
    }

    func testEmptyRowFallsBackWithoutCrash() throws {
        try EntityTestSupport.assertLossless(WatchGroupRow(JSONValue([:])), JSONValue([:]), "group-empty")
        try EntityTestSupport.assertLossless(WatchItemRow(JSONValue([:])), JSONValue([:]), "item-empty")
        try EntityTestSupport.assertLossless(WatchJudgmentRow(JSONValue([:])), JSONValue([:]), "judgment-empty")
        XCTAssertEqual(WatchItemRow(JSONValue([:])).groupId, 1, "group_id 缺省 1（与读取层 `?? 1` 一致）")
    }
}
