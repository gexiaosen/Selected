import XCTest
@testable import SelectedCore

/// 三轮对比实体 vs **黄金夹具（真实引擎产出）**
///
/// 夹具是 `engine/tests/fixtures/compare_outputs/{full,nodata,budget}.json` ——
/// 真实引擎产出、手工捕获、不可再生：
/// `full` 三轮齐全 / `nodata` 无数据（`stability` 是**空对象**）/ `budget` 有轮次被预算截断。
final class CompareEntityTests: XCTestCase {

    private func load(_ name: String) throws -> JSONValue {
        try EntityTestSupport.fixture("engine/tests/fixtures/compare_outputs/\(name).json")
    }

    /// 一份报告的全部嵌套结构
    private func checkAll(_ r: CompareReport, _ label: String) throws {
        try EntityTestSupport.check(CompareReport.self, r.json, label)
        try EntityTestSupport.check(CompareStability.self, r.stability.json, "\(label).stability")
        for (code, s) in r.signals {
            try EntityTestSupport.check(CompareSignal.self, s.json, "\(label).signals[\(code)]")
        }
        for (i, row) in r.tier1Matrix.enumerated() {
            try EntityTestSupport.check(CompareMatrixRow.self, row.json, "\(label).tier1[\(i)]")
        }
        for (i, row) in r.tier2Matrix.enumerated() {
            try EntityTestSupport.check(CompareMatrixRow.self, row.json, "\(label).tier2[\(i)]")
        }
        for (i, row) in r.tierChanges.enumerated() {
            try EntityTestSupport.check(CompareTierChange.self, row.json, "\(label).changes[\(i)]")
        }
        for (i, row) in r.etfMatrix.enumerated() {
            try EntityTestSupport.check(CompareEtfRow.self, row.json, "\(label).etf[\(i)]")
        }
        for (i, row) in r.excludedTable.enumerated() {
            try EntityTestSupport.check(CompareExcludedRow.self, row.json, "\(label).excluded[\(i)]")
        }
        for (i, row) in r.funnelTable.enumerated() {
            try EntityTestSupport.check(CompareFunnelRow.self, row.json, "\(label).funnel[\(i)]")
        }
        for (i, row) in r.marketEnvTable.enumerated() {
            try EntityTestSupport.check(CompareMarketEnvRow.self, row.json, "\(label).env[\(i)]")
        }
        for (i, s) in r.suggestions.enumerated() {
            try EntityTestSupport.check(CompareSuggestion.self, s.json, "\(label).suggest[\(i)]")
        }
    }

    func testFullReportCoversExactlyAndRoundTrips() throws {
        try checkAll(CompareReport(try load("full")), "full")
    }

    func testNoDataReportCoversExactlyAndRoundTrips() throws {
        try checkAll(CompareReport(try load("nodata")), "nodata")
    }

    func testBudgetLimitedReportCoversExactlyAndRoundTrips() throws {
        try checkAll(CompareReport(try load("budget")), "budget")
    }

    // MARK: - 类型化取值

    func testFullReportTypedValues() throws {
        let r = CompareReport(try load("full"))
        XCTAssertEqual(r.date, "2026-09-14")
        XCTAssertEqual(r.status, "ok")
        XCTAssertTrue(r.isOK)
        XCTAssertEqual(r.availableSlots, [1, 2, 3])
        XCTAssertFalse(r.warnings.isEmpty)
        XCTAssertTrue(r.budgetLimitedSlots.isEmpty, "full 夹具没有预算截断")

        let st = r.stability
        XCTAssertTrue(st.persistenceVerified)
        XCTAssertEqual(st.slotsExpected, [1, 2, 3])
        XCTAssertEqual(st.slotsAvailable, [1, 2, 3])
        XCTAssertTrue(st.missingSlots.isEmpty)
        XCTAssertTrue(st.alwaysTier1.contains("600719"), "三轮均一档应含 600719")
        XCTAssertFalse(st.alwaysTier1.isEmpty)
        XCTAssertFalse(st.consensus.isEmpty)
        XCTAssertTrue(st.declining.isEmpty)
        XCTAssertTrue(st.finalNew.isEmpty)
        XCTAssertTrue(st.pulseOnly.isEmpty)
        XCTAssertTrue(st.unverified.isEmpty)

        // 逐字段断言取值：键覆盖 + 无损往返**验不了"取值口径对不对"** ——
        // 把 {"1": 110} 当数组读会得到空集合，而前两道检查全绿。
        let row = try XCTUnwrap(r.tier1Matrix.first)
        XCTAssertFalse(row.code.isEmpty)
        XCTAssertFalse(row.name.isEmpty)
        XCTAssertEqual(row.tiers, [1: 1, 2: 1, 3: 1], "tiers 是**按轮次键的对象**，不是数组")
        XCTAssertEqual(row.scores[1], 110)
        XCTAssertEqual(row.prices[1], 7.87)
        XCTAssertEqual(row.changes[1], 3.28)
        XCTAssertFalse(row.trend.isEmpty)
        XCTAssertEqual(row.signalType, "strongest")

        let funnel = try XCTUnwrap(r.funnelTable.first)
        XCTAssertEqual(funnel.slot, 1)
        XCTAssertGreaterThan(funnel.totalScanned, 0)
        XCTAssertGreaterThan(funnel.tier1Count, 0)

        let env = try XCTUnwrap(r.marketEnvTable.first)
        XCTAssertEqual(env.slot, 1)
        XCTAssertEqual(env.label, "14:00", "market_env_table.label 是**时刻**，不是灯级")
        XCTAssertGreaterThan(env.upCount, 0)
        XCTAssertGreaterThan(env.downCount, 0)

        let sig = try XCTUnwrap(r.signals["600719"])
        XCTAssertEqual(sig.name, "大连热电")
        XCTAssertEqual(sig.tiers, [1: 1, 2: 1, 3: 1])
        XCTAssertEqual(sig.scores[1], 110)
        XCTAssertEqual(sig.slotsAvailable, [1, 2, 3])
        XCTAssertEqual(sig.slotsExpected, [1, 2, 3])
        XCTAssertTrue(sig.signalVerified)
        XCTAssertFalse(sig.budgetLimited)
        XCTAssertFalse(sig.signalTypeName.isEmpty)
        XCTAssertFalse(sig.trend.isEmpty)

        let change = try XCTUnwrap(r.tierChanges.first)
        XCTAssertFalse(change.change.isEmpty, "change 是变化描述（如 `一档 → 二档 (降级)`）")

        let etf = try XCTUnwrap(r.etfMatrix.first)
        XCTAssertEqual(etf.changes[1], 1.2, "etf_matrix[].changes 也是**按轮次键的对象**")

        let ex = try XCTUnwrap(r.excludedTable.first)
        XCTAssertEqual(ex.slots, [1], "slots 是**数组**（与 reasons 的形态不同）")
        XCTAssertFalse(ex.reasons.isEmpty)
        XCTAssertFalse(try XCTUnwrap(ex.reasons[1]).isEmpty)

        let sug = try XCTUnwrap(r.suggestions.first)
        XCTAssertEqual(sug.type, "high_confidence")
        XCTAssertFalse(sug.text.isEmpty)
    }

    /// `no_data`：`stability` 是**空对象** → 全部回默认，且 `persistenceVerified` 为 false
    /// （未验证 = 不得按"高置信"解读，这正是想要的口径）
    func testNoDataReportDegradesSafely() throws {
        let r = CompareReport(try load("nodata"))
        XCTAssertEqual(r.status, "no_data")
        XCTAssertFalse(r.isOK)
        XCTAssertTrue(r.availableSlots.isEmpty)
        XCTAssertTrue(r.signals.isEmpty)
        XCTAssertTrue(r.tier1Matrix.isEmpty)
        XCTAssertTrue(r.funnelTable.isEmpty)
        XCTAssertTrue(r.marketEnvTable.isEmpty)

        XCTAssertTrue(r.stability.isEmptyObject)
        XCTAssertFalse(r.stability.persistenceVerified, "空 stability → 未验证")
        XCTAssertTrue(r.stability.alwaysTier1.isEmpty)
        XCTAssertTrue(r.stability.missingSlots.isEmpty)
        // 空对象里没有 persistence_verified 键 → **显式未验证**为 false
        XCTAssertFalse(r.stability.isExplicitlyUnverified)
    }

    /// `budget`：`budget_limited_slots` 是**条件键**（只有被截断的轮次才有）
    func testBudgetLimitedReportExposesTruncatedSlots() throws {
        let r = CompareReport(try load("budget"))
        XCTAssertEqual(r.budgetLimitedSlots, [2])
        XCTAssertTrue(r.status == "ok")
        // 被截断轮次里的标的会被标 budget_limited（信号分类据此判"未验证"）
        XCTAssertFalse(r.stability.unverified.isEmpty)
        XCTAssertTrue(r.signals.values.contains { $0.budgetLimited })
    }

    /// 逐标的信号是**动态键**（键是证券代码）—— 语义正确，不是偷懒。
    /// `CompareView` 用 `signals.keys.sorted()` 当行 id、再按 code 查值（见 `CompareView:99`），
    /// 所以这里断言"键是 6 位代码 + 值里有名称"。
    func testSignalsAreKeyedByCode() throws {
        let r = CompareReport(try load("full"))
        XCTAssertFalse(r.signals.isEmpty)
        for (code, sig) in r.signals {
            XCTAssertEqual(code.count, 6, "A 股代码应为 6 位：\(code)")
            XCTAssertFalse(sig.name.isEmpty, "\(code) 缺名称")
            XCTAssertFalse(sig.tiers.isEmpty, "\(code) 缺逐轮档位")
        }
        XCTAssertEqual(r.signals["600719"]?.name, "大连热电")
    }

    // MARK: - 缺键退化

    func testEmptyReportFallsBackWithoutCrash() throws {
        let r = CompareReport(JSONValue([:]))
        XCTAssertEqual(r.status, "")
        XCTAssertFalse(r.isOK)
        XCTAssertTrue(r.availableSlots.isEmpty)
        XCTAssertTrue(r.signals.isEmpty)
        XCTAssertEqual(r.stability.alwaysTier1, [])
        XCTAssertEqual(r.stability.slotsExpected, [])
        try EntityTestSupport.assertLossless(r, r.json, "compare-empty")
    }

    /// 只有 `status` 的最小形状（引擎早退）
    func testMinimalShapeIsTolerated() throws {
        let r = CompareReport(JSONValue(["status": "no_data", "date": "2026-09-21"]))
        XCTAssertEqual(r.status, "no_data")
        XCTAssertEqual(r.date, "2026-09-21")
        try EntityTestSupport.assertLossless(r, r.json, "compare-minimal")
    }

    func testFlatMarketChangesDoNotWarnWeakening() {
        func roundWithChange(_ pct: Double) -> [String: Any] {
            ["market_env": ["sh_change_pct": pct], "stats": [:]]
        }
        let flatReport = SignalClassifier.compare([1: roundWithChange(0.0),
                                                   2: roundWithChange(0.0),
                                                   3: roundWithChange(0.0)], date: "2026-09-21")
        let flatWarnings = (flatReport["warnings"] as? [String]) ?? []
        XCTAssertFalse(flatWarnings.contains { $0.contains("大盘逐轮走弱") },
                       "大盘持平时不应误报走弱：\(flatWarnings)")

        let weakReport = SignalClassifier.compare([1: roundWithChange(1.0),
                                                   2: roundWithChange(0.5),
                                                   3: roundWithChange(0.5)], date: "2026-09-21")
        let weakWarnings = (weakReport["warnings"] as? [String]) ?? []
        XCTAssertTrue(weakWarnings.contains { $0.contains("大盘逐轮走弱") },
                      "存在严格下降的 nonIncreasing 序列应报走弱：\(weakWarnings)")
    }
}
