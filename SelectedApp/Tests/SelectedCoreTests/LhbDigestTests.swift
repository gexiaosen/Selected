import XCTest
@testable import SelectedCore

/// `LhbDigest`（龙虎榜详情卡的派生数据）的契约测试。
///
/// 覆盖三件**真会静默出错**的事：
///   1. **同一天多条口径** —— 实测 `600721` 一天三条上榜口径，其中两条金额**完全相同**。
///      逐条展示会像"重复抓取"；只取一条又不能丢掉"为什么上榜"。
///   2. **净额全为负时取错** —— 当日净卖出时直接 `max` 会挑到"亏得最少"的那条，
///      与"最显著"正好相反，而且界面上看起来完全正常。
///   3. **比率是百分数还是小数** —— 东财的 `*_RATIO` 是 `31.47`（= 31.47%）。
///      误当 0–1 小数再乘 100 → 显示 3147.9%，肉眼一眼假，但**没有任何断言会红**。
final class LhbDigestTests: XCTestCase {

    // MARK: - 夹具

    private static let fixturesDir: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")

    /// 缺失 → **失败**（不是 `XCTSkip`）：本夹具**已纳入版本管理**，
    /// 缺失 = 仓库不完整 / 被误删，**不是"当前环境不具备"** ——
    /// 跳过会把这件事伪装成"全绿"。
    private func fixtureText(_ name: String) throws -> String {
        let url = Self.fixturesDir.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw EntityTestSupport.FixtureMissing(
                path: "Tests/SelectedCoreTests/Fixtures/\(name)")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// 只关心"日期 / 口径 / 原因 / 净额"这几个字段，其余给中性默认值
    private func rec(_ date: String, _ changeType: String, _ explanation: String,
                     net: Double, code: String = "600721",
                     buy: Double = 0, sell: Double = 0) -> LhbRecord {
        LhbRecord(date: date, code: code, changeType: changeType, name: "测试",
                  explanation: explanation, market: "SH", tradeMarket: "上交所主板",
                  close: 10, changePct: 10, turnoverRate: 20,
                  netAmount: net, buyAmount: buy, sellAmount: sell,
                  dealAmount: 0, accumAmount: 0, freeMarketCap: 0,
                  dealAmountRatio: 0, dealNetRatio: 0,
                  buyRatio: 0, sellRatio: 0, tradeId: 0)
    }

    // MARK: - 日期选择

    /// 取**最近一天**（调用方按 `trade_date DESC` 传入，取首条日期）
    func testCardPicksNewestDay() {
        let c = LhbDigest.card(from: [
            rec("2026-09-21", "A", "最新一天", net: 100),
            rec("2026-09-18", "B", "更早一天", net: 999),
        ])
        XCTAssertEqual(c?.date, "2026-09-21")
        // 即使更早那天的净额更大，也不能被选中 —— 卡片的主题是"最近一次上榜"
        XCTAssertEqual(c?.primary.changeType, "A")
    }

    func testCardUsesOnlyRecordsOfThatDay() {
        let c = LhbDigest.card(from: [
            rec("2026-09-21", "A", "原因甲", net: 100),
            rec("2026-09-21", "B", "原因乙", net: 200),
            rec("2026-09-18", "C", "旧原因", net: 300),
        ])
        XCTAssertEqual(c?.caliberCount, 2)                       // 不含 09-18 那条
        XCTAssertEqual(c?.reasons, ["原因甲", "原因乙"])
        XCTAssertEqual(c?.primary.changeType, "B")
    }

    // MARK: - primary 的取法

    /// 核心陷阱：净额**全为负**时按绝对值取最大，而不是按数值取 max
    func testPrimaryUsesAbsoluteNetNotRawMax() {
        let c = LhbDigest.card(from: [
            rec("2026-09-21", "A", "净卖出多", net: -300),
            rec("2026-09-21", "B", "净卖出少", net: -50),
        ])
        // 直接 `max { $0.netAmount < $1.netAmount }` 会得到 -50（"亏得最少"），是反的
        XCTAssertEqual(c?.primary.changeType, "A")
        XCTAssertEqual(c?.primary.netAmount ?? 0, -300, accuracy: 1e-9)
    }

    func testPrimaryPicksLargestAbsoluteAmongMixedSigns() {
        let c = LhbDigest.card(from: [
            rec("2026-09-21", "A", "小额净买", net: 20),
            rec("2026-09-21", "B", "大额净卖", net: -900),
            rec("2026-09-21", "C", "中额净买", net: 300),
        ])
        XCTAssertEqual(c?.primary.changeType, "B")
    }

    // MARK: - 原因去重

    /// 同一日**两条口径文案相同** → 只列一次，但 `caliberCount` 仍是 2
    func testReasonsDeduplicatedButCaliberCountKeepsAll() {
        let c = LhbDigest.card(from: [
            rec("2026-09-21", "A", "同一条文案", net: 100),
            rec("2026-09-21", "B", "同一条文案", net: 100),
        ])
        XCTAssertEqual(c?.reasons, ["同一条文案"])
        XCTAssertEqual(c?.caliberCount, 2)
    }

    func testBlankExplanationIsNotListedButStillCounted() {
        let c = LhbDigest.card(from: [
            rec("2026-09-21", "A", "", net: 100),
            rec("2026-09-21", "B", "有文案", net: 200),
        ])
        XCTAssertEqual(c?.reasons, ["有文案"])
        XCTAssertEqual(c?.caliberCount, 2)
    }

    /// 顺序保持调用方给的顺序（= `LhbStore.records` 的 `change_type ASC`）
    func testReasonsKeepInputOrder() {
        let c = LhbDigest.card(from: [
            rec("2026-09-21", "A", "甲", net: 1),
            rec("2026-09-21", "B", "乙", net: 2),
            rec("2026-09-21", "C", "丙", net: 3),
        ])
        XCTAssertEqual(c?.reasons, ["甲", "乙", "丙"])
    }

    // MARK: - 退化输入

    func testNilOnEmptyOrBlankDate() {
        XCTAssertNil(LhbDigest.card(from: []))
        XCTAssertNil(LhbDigest.card(from: [rec("", "A", "无日期", net: 1)]))
    }

    // MARK: - 真实夹具（多口径那一只）

    /// `600721 百花医药` 在 2026-09-21 同时命中**三条**上榜口径，
    /// 其中「日涨幅偏离 7%」与「日换手率 20%」的金额**逐字段完全相同**。
    func testRealMultiCaliberStock() throws {
        let all = LhbSource.parseDay(try fixtureText("lhb_day.json"))
        let rows = all.filter { $0.code == "600721" }
        XCTAssertEqual(rows.count, 3)

        let c = try XCTUnwrap(LhbDigest.card(from: rows))
        XCTAssertEqual(c.date, "2026-09-21")
        XCTAssertEqual(c.caliberCount, 3)
        XCTAssertEqual(c.reasons.count, 3)          // 三条文案各不相同 → 都列出来
        XCTAssertEqual(Set(c.reasons), Set(rows.map(\.explanation)))

        // 净额最大的是「连续三日累计涨幅偏离达 20%」那条（227,505,700.25）
        XCTAssertEqual(c.primary.changeType, "137001002001002")
        XCTAssertEqual(c.primary.netAmount, 227_505_700.25, accuracy: 0.01)
    }

    /// 同一日两条口径**金额完全相同**（真实数据，非构造）—— 这条锁住"为什么不能逐条展示"
    func testRealDuplicateAmountsAcrossCalibers() throws {
        let rows = LhbSource.parseDay(try fixtureText("lhb_day.json"))
            .filter { $0.code == "600721" }
        let a = try XCTUnwrap(rows.first { $0.changeType == "137001002001001" })
        let b = try XCTUnwrap(rows.first { $0.changeType == "137001004001" })
        XCTAssertNotEqual(a.changeType, b.changeType)
        XCTAssertNotEqual(a.explanation, b.explanation)
        XCTAssertEqual(a.netAmount, b.netAmount, accuracy: 0.01)      // ← 金额一样
        XCTAssertEqual(a.buyAmount, b.buyAmount, accuracy: 0.01)
        XCTAssertEqual(a.sellAmount, b.sellAmount, accuracy: 0.01)
    }

    /// 锁住**比率口径**：`*_RATIO` / `*_RATE` 是**百分数**（`31.47` = 31.47%），
    /// 不是 0–1 小数。界面用 `String(format: "%.1f%%", v)` 直接显示；
    /// 若哪天有人"顺手"除以 100，这条断言会先红（否则界面上会出现 3147.9%）。
    func testRatiosAreAlreadyPercentNotFraction() throws {
        let rows = LhbSource.parseDay(try fixtureText("lhb_day.json"))
            .filter { $0.code == "600721" }
        let r = try XCTUnwrap(rows.first { $0.changeType == "137001002001001" })

        XCTAssertGreaterThan(r.dealAmountRatio, 1)      // 百分数 → 必然 > 1
        XCTAssertEqual(r.dealAmountRatio, 31.478792078775, accuracy: 1e-9)
        XCTAssertGreaterThan(r.changePct, 1)            // 涨停 10%，不是 0.1
        XCTAssertEqual(r.changePct, 10.0418, accuracy: 1e-9)
        XCTAssertGreaterThan(r.turnoverRate, 1)
        XCTAssertEqual(r.turnoverRate, 29.0224, accuracy: 1e-9)
    }
}
