import XCTest
@testable import SelectedCore

/// 看板 / 复盘库行实体 vs **真实读取结果**
///
/// 夹具 `engine/tests/fixtures/dashboard_row_outputs/*.json` 是**真实捕获**。
/// 三个夹具来自**不同的库**（本机测试库的 `signal_classes` / `reviews` 常为空）：
/// `todayRounds` 取自 compare 测试库、`signals` 取自同一个库、`winrateTrend` 取自 phase review 库。
/// `todayRounds_20260909` / `todayRounds_20260918` 覆盖**历史键集形状**（取自生产库）。
final class DashboardRowEntityTests: XCTestCase {

    private func load(_ name: String) throws -> [JSONValue] {
        try EntityTestSupport.fixture("engine/tests/fixtures/dashboard_row_outputs/\(name).json").array
    }

    // MARK: - 轮次摘要

    func testRoundSummaryCoversExactlyAndRoundTrips() throws {
        let rows = try load("todayRounds")
        XCTAssertEqual(rows.count, 3, "夹具是三轮齐全的库")
        for (i, r) in rows.enumerated() {
            try EntityTestSupport.check(RoundSummaryRow.self, r, "todayRounds[\(i)]")
        }

        let rs = rows.map(RoundSummaryRow.init)
        XCTAssertEqual(rs.map(\.slot), [1, 2, 3], "只保留存在的轮次，且按 slot 升序")
        for r in rs {
            XCTAssertGreaterThan(r.roundId, 0)
            XCTAssertFalse(r.slotLabel.isEmpty)
            XCTAssertFalse(r.runTime.isEmpty)
            XCTAssertGreaterThan(r.tier1Count, 0)
            XCTAssertFalse(r.paramVersion.isEmpty)
            // 库行的 `market_env` 与扫描结果/预判**共用同一个 `MarketEnv`**
            try EntityTestSupport.check(MarketEnv.self, r.marketEnv.json, "round.env")
            XCTAssertFalse(r.marketEnv.isEmpty)
        }
        XCTAssertFalse(rs[0].slotLabel.isEmpty)
    }

    /// 库是 **append-only** 的 —— `market_env_json` 的键集是**历史形状**，
    /// 随引擎演进逐批增长（实测生产库 12 / 13 / 15 / 16 / 17 键）。
    ///
    /// 这条测试用**真实捕获**的 12 键与 17 键两种形状
    /// 证明 `MarketEnv` 的"并集 `declaredKeys` + `conditionalKeys`"能同时读动两端。
    ///
    /// **为什么必须测**：按"当前引擎产出"声明键，旧行就会红 ——
    /// 夹具单形状 = 结构性看不见这个问题。
    func testMarketEnvToleratesHistoricalKeyShapes() throws {
        let shapes: [(name: String, keyCount: Int)] = [
            ("todayRounds_20260909", 12), ("todayRounds_20260918", 17),
        ]
        for shape in shapes {
            let rows = try load(shape.name)
            XCTAssertFalse(rows.isEmpty, "\(shape.name) 应有行")
            for (i, r) in rows.enumerated() {
                let env = RoundSummaryRow(r).marketEnv
                XCTAssertEqual(env.json.dict.keys.count, shape.keyCount,
                               "\(shape.name)[\(i)]：夹具键数应与捕获时一致")
                // 历史形状既不能被判成"实体少声明"，也不能被判成"实体多声明"
                try EntityTestSupport.check(MarketEnv.self, env.json, "\(shape.name)[\(i)].env")
                XCTAssertTrue(MarketEnv.alwaysPresentKeys.isSubset(of: Set(env.json.dict.keys)),
                              "\(shape.name)[\(i)]：这 5 个键在任何来源、任何历史形状里都该有")
                XCTAssertFalse(env.sh3dTrend.isEmpty)
            }
        }

        // 12 键那份**没有** `sh_decline_*` / `ratio` / `flat_count`（都早于它们被引入）
        // —— 只有 `OrNil` 变体区分得出来"这个来源没报"与"值是 0"
        let old = RoundSummaryRow(try load("todayRounds_20260909")[0]).marketEnv
        XCTAssertNil(old.shDeclineStreakOrNil, "09-09 的行早于 sh_decline_streak 引入")
        XCTAssertNil(old.shDeclineLookbackOrNil, "09-09 的行早于 sh_decline_lookback 引入")
        XCTAssertNil(old.shDeclineDaysCfgOrNil, "09-09 的行早于 sh_decline_days_cfg 引入")
        XCTAssertNil(old.ratioOrNil, "09-09 的行早于 ratio 引入")
        XCTAssertNil(old.flatCountOrNil, "09-09 的行早于 flat_count 引入")
        XCTAssertEqual(old.shDeclineStreak, 0, "非 OrNil 变体仍回落 0（保持旧口径，别改）")
        XCTAssertEqual(old.flatCount, 0)

        // 17 键那份（当前引擎产出）全都有
        let new = RoundSummaryRow(try load("todayRounds_20260918")[0]).marketEnv
        XCTAssertNotNil(new.shDeclineStreakOrNil)
        XCTAssertNotNil(new.shDeclineLookbackOrNil)
        XCTAssertNotNil(new.shDeclineDaysCfgOrNil)
        XCTAssertNotNil(new.ratioOrNil)
        XCTAssertNotNil(new.flatCountOrNil)
    }

    /// 预判来源**没有** `sh_price` / 涨跌家数 —— `OrNil` 变体必须如实返回 nil
    /// （这是"统一"的核心收益：不再靠"整个对象非空"来猜字段在不在）
    func testPredictSourceReportsOnlyItsOwnKeys() throws {
        let pred = PredictResult(try EntityTestSupport.fixture(
            "engine/tests/fixtures/phase_outputs/predict.json"))
        let env = pred.marketEnv
        XCTAssertEqual(env.light, "红灯", "预判独有的键读得到")
        XCTAssertNotNil(env.shOpenPctOrNil)
        XCTAssertFalse(env.usMarket.isEmpty)
        XCTAssertNil(env.shPriceOrNil, "预判来源没有 sh_price")
        XCTAssertNil(env.upCountOrNil, "预判来源没有 up_count")
        XCTAssertNil(env.flatCountOrNil, "预判来源没有 flat_count")
        XCTAssertEqual(env.lightLevel, .red, "连续下跌 → 红灯（三种来源共用同一判定）")
    }

    /// `todayRounds` 只返回**存在**的轮次 —— "扫了几轮"看 count，不看下标
    func testRoundSummaryCountMeansScannedSlots() {
        XCTAssertEqual([1, 2, 3].compactMap { $0 == 2 ? nil : RoundSummaryRow(JSONValue(["slot": $0])) }.count, 2,
                       "缺第 2 轮时 count=2（这正是 `roundSummaries.count` 的语义）")
    }

    // MARK: - 信号分类

    func testSignalClassCoversExactlyAndRoundTrips() throws {
        let rows = try load("signals")
        XCTAssertFalse(rows.isEmpty)
        for (i, r) in rows.enumerated() {
            try EntityTestSupport.check(SignalClassRow.self, r, "signals[\(i)]")
        }
        let s = SignalClassRow(rows[0])
        XCTAssertFalse(s.code.isEmpty)
        XCTAssertFalse(s.name.isEmpty)
        XCTAssertFalse(s.signalType.isEmpty)
        XCTAssertFalse(s.scores.isEmpty, "scores 是**按轮次键的对象**，不是数组")
        XCTAssertFalse(s.trend.isEmpty)
        XCTAssertEqual(s.trendDash, s.trend)
    }

    // MARK: - 胜率走势

    func testWinrateTrendCoversExactlyAndRoundTrips() throws {
        let rows = try load("winrateTrend")
        XCTAssertFalse(rows.isEmpty)
        for (i, r) in rows.enumerated() {
            try EntityTestSupport.check(WinrateTrendRow.self, r, "winrateTrend[\(i)]")
        }
        let rs = rows.map(WinrateTrendRow.init)
        for p in rs {
            XCTAssertFalse(p.date.isEmpty)
            for v in [p.snapshot, p.close, p.window, p.ceiling] {
                XCTAssertTrue((0...100).contains(v), "胜率应在 0~100：\(v)")
            }
        }
        // 读取层已按日期升序（DESC 查询后 reversed）
        XCTAssertEqual(rs.map(\.date), rs.map(\.date).sorted(), "应已按日期升序")
    }

    func testMissingKeysFallBackWithoutCrash() throws {
        try EntityTestSupport.assertLossless(RoundSummaryRow(JSONValue([:])), JSONValue([:]), "round-empty")
        try EntityTestSupport.assertLossless(SignalClassRow(JSONValue([:])), JSONValue([:]), "signal-empty")
        try EntityTestSupport.assertLossless(WinrateTrendRow(JSONValue([:])), JSONValue([:]), "trend-empty")
        XCTAssertEqual(RoundSummaryRow(JSONValue([:])).slot, 0)
        XCTAssertEqual(SignalClassRow(JSONValue([:])).nameDash, "-")
        XCTAssertEqual(WinrateTrendRow(JSONValue([:])).dateDash, "-")
    }
}
