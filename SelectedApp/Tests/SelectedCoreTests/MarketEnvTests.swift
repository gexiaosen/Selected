import XCTest
@testable import SelectedCore

/// `MarketEnv`（大盘环境，**三种来源共用一个类型**）的专项测试
///
/// 三种来源：扫描结果（17 键）/ 库 `scan_rounds.market_env_json`（**12–17 键的历史形状**）/
/// 预判（10 键，键集几乎不重叠）。这里测的是**跨来源的契约**，
/// 各来源自己的键覆盖/往返分别由 `ScanEntityTests` / `PhaseEntityTests` /
/// `DashboardRowEntityTests` 负责。
final class MarketEnvTests: XCTestCase {

    private func load(_ relative: String) throws -> JSONValue {
        try EntityTestSupport.fixture(relative)
    }

    /// `declaredKeys` 必须是"三源并集"，`conditionalKeys` 恰好是"非普适"的那 19 个
    func testDeclaredKeysIsTheUnionOfAllSources() {
        XCTAssertEqual(MarketEnv.declaredKeys.count, 24)
        XCTAssertEqual(MarketEnv.alwaysPresentKeys.count, 5)
        XCTAssertEqual(MarketEnv.conditionalKeys, MarketEnv.declaredKeys.subtracting(MarketEnv.alwaysPresentKeys))
        // 交叉验证：5 个"普适键"必须真的分散在三种来源里（不是某一源独有的）
        for key in MarketEnv.alwaysPresentKeys {
            XCTAssertTrue(["sh_change_pct", "sh_consecutive_decline", "sh_ok",
                           "sh_3d_decline_count", "sh_3d_trend"].contains(key))
        }
    }

    /// 三种来源的真实夹具里，`alwaysPresentKeys` **都**必须在 —— 这条是
    /// "普适"这个说法的唯一证据。少了它，`lightLevel` 就可能读到默认值而误判灯色。
    func testAlwaysPresentKeysExistInEverySource() throws {
        let scan = ScanResult(try load("engine/tests/fixtures/2026-09-14/expected_scan_result.json"))
        let pred = PredictResult(try load("engine/tests/fixtures/phase_outputs/predict.json"))
        let dbRows = try load("engine/tests/fixtures/dashboard_row_outputs/todayRounds_20260909.json").array

        let sources: [(String, JSONValue)] = [
            ("扫描结果", scan.marketEnv.json),
            ("预判", pred.marketEnv.json),
            ("库行(12 键)", dbRows[0]["market_env"]),
        ]
        for (name, json) in sources {
            let keys = Set(json.dict.keys)
            let missing = MarketEnv.alwaysPresentKeys.subtracting(keys)
            XCTAssertTrue(missing.isEmpty, "\(name) 缺普适键 \(missing.sorted())")
        }
    }

    /// `lightLevel` 的**规则顺序**必须保留：连续下跌优先于 `sh_ok`
    ///
    /// 反例（夹具）：扫描来源 `sh_ok = false`、预判来源 `sh_ok = true`，
    /// 但两边 `sh_consecutive_decline = true`。若先看 `sh_ok`，同一份行情会因为
    /// "数据来自哪个来源"而变色。所以顺序是：连续下跌 → 红；`sh_ok` 非真 → 黄；否则绿。
    func testLightLevelPrefersConsecutiveDeclineOverShOK() {
        let red = MarketEnv(JSONValue([
            "sh_consecutive_decline": true, "sh_ok": true,
            "sh_change_pct": -0.19, "sh_3d_decline_count": 2, "sh_3d_trend": "连续3日下跌",
        ]))
        XCTAssertEqual(red.lightLevel, .red, "sh_ok=true 也不能盖过连续下跌")

        let yellow = MarketEnv(JSONValue([
            "sh_consecutive_decline": false, "sh_ok": false,
            "sh_change_pct": 0.4, "sh_3d_decline_count": 0, "sh_3d_trend": "震荡",
        ]))
        XCTAssertEqual(yellow.lightLevel, .yellow)

        let green = MarketEnv(JSONValue([
            "sh_consecutive_decline": false, "sh_ok": true,
            "sh_change_pct": 0.4, "sh_3d_decline_count": 0, "sh_3d_trend": "震荡",
        ]))
        XCTAssertEqual(green.lightLevel, .green)

        // `sh_ok` 缺失（不是 false）→ 也按"非真"处理（等价于 `env["sh_ok"].bool != true`）
        let missingOk = MarketEnv(JSONValue(["sh_consecutive_decline": false]))
        XCTAssertEqual(missingOk.lightLevel, .yellow)
    }

    /// 两个真实来源对同一份行情给出**不同**的 `sh_ok` —— 记录这个事实，
    /// 并证明"按 `sh_consecutive_decline` 优先"能让两边得到同一个灯色
    func testBothRealSourcesAgreeOnLightDespiteDifferentShOK() throws {
        let scan = ScanResult(try load("engine/tests/fixtures/2026-09-14/expected_scan_result.json")).marketEnv
        let pred = PredictResult(try load("engine/tests/fixtures/phase_outputs/predict.json")).marketEnv
        XCTAssertNotEqual(scan.shOK, pred.shOK, "实测：扫描 false / 预判 true（两个引擎口径不同）")
        XCTAssertTrue(scan.shConsecutiveDecline)
        XCTAssertTrue(pred.shConsecutiveDecline)
        XCTAssertEqual(scan.lightLevel, pred.lightLevel,
                       "灯色必须与来源无关 —— 这正是规则顺序要保留的原因")
    }

    /// 空对象是"该来源没有环境数据"，不是"环境全是 0"
    func testEmptyObjectMeansNoDataNotZero() {
        let empty = MarketEnv(JSONValue([:]))
        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(empty.shChangePct, 0)
        XCTAssertNil(empty.shChangePctOrNil, "OrNil 变体必须能区分'没数据'与 0")
        XCTAssertNil(empty.shPriceOrNil)
        XCTAssertNil(empty.upCountOrNil)

        // `has(_:)` 是逐字段版的同一判断
        XCTAssertFalse(empty.has("sh_ok"))
        XCTAssertTrue(MarketEnv(JSONValue(["sh_ok": false])).has("sh_ok"),
                      "显式 false 也算'报了'（区别于键缺失）")
    }

    /// 24 个键的访问器都要能读出来（防"声明了但访问器拼错"）
    func testAllDeclaredKeysAreReachable() {
        let env = MarketEnv(JSONValue([
            "sh_price": 3120.5, "sh_change_pct": 0.42, "sh_amplitude": 0.86,
            "up_count": 2680, "down_count": 2310, "flat_count": 210,
            "ratio": 1.16, "ratio_ok": true,
            "sh_consecutive_decline": false, "sh_3d_decline_count": 1, "sh_3d_trend": "震荡",
            "sh_d1": 0.31, "sh_d2": -0.22, "sh_ok": true,
            "sh_decline_streak": 3, "sh_decline_lookback": 3, "sh_decline_days_cfg": 2,
            "light": "绿灯", "light_desc": "可正常操作", "open_status": "高开",
            "sh_open_pct": 0.54, "us_market": "道琼斯+1.0%",
            "regime": "BULL_TREND", "ma_period_used": 60,
        ]))
        XCTAssertEqual(env.shPrice, 3120.5)
        XCTAssertEqual(env.shAmplitude, 0.86)
        XCTAssertEqual(env.upCount, 2680)
        XCTAssertEqual(env.downCount, 2310)
        XCTAssertEqual(env.flatCount, 210)
        XCTAssertEqual(env.ratio, 1.16)
        XCTAssertTrue(env.ratioOK)
        XCTAssertEqual(env.sh3dDeclineCount, 1)
        XCTAssertEqual(env.sh3dTrend, "震荡")
        XCTAssertEqual(env.shD1, 0.31)
        XCTAssertEqual(env.shD2, -0.22)
        XCTAssertTrue(env.shOK)
        XCTAssertEqual(env.shDeclineStreak, 3)
        XCTAssertEqual(env.shDeclineLookback, 3)
        XCTAssertEqual(env.shDeclineDaysCfg, 2)
        XCTAssertEqual(env.light, "绿灯")
        XCTAssertEqual(env.lightDesc, "可正常操作")
        XCTAssertEqual(env.openStatus, "高开")
        XCTAssertEqual(env.shOpenPct, 0.54)
        XCTAssertEqual(env.usMarket, "道琼斯+1.0%")
        XCTAssertEqual(env.regime, "BULL_TREND")
        XCTAssertEqual(env.maPeriodUsed, 60)
        XCTAssertFalse(env.isEmpty)
    }

    /// 后加的两个键在**历史库行**里没有 → `OrNil` 变体必须能区分"没报"与 0
    func testRegimeKeysAreAbsentInHistoricalRows() {
        let old = MarketEnv(JSONValue(["sh_ok": true, "sh_consecutive_decline": false]))
        XCTAssertEqual(old.regime, "", "缺失 → 空串（`str` 的退化语义）")
        XCTAssertEqual(old.regimeDash, "-")
        XCTAssertEqual(old.maPeriodUsed, 0)
        XCTAssertNil(old.maPeriodUsedOrNil, "OrNil 必须能区分'这个来源没报'与'真的是 0'")
        XCTAssertFalse(old.has("regime"))
    }

    /// 灯级枚举的**线上格式**钉死
    ///
    /// `light` 是落库键：这三个中文串写进 `scan_rounds.market_env_json` /
    /// `predictions.market_env_json` / `watch_judgments.market_light` ——
    /// rawValue 动一个字节即静默破坏存量数据与读取侧匹配。
    /// 所以这里正面钉住中文原值本身，而不是只测 Swift 内部行为。
    func testMarketLightLevelWireFormatIsFrozen() {
        XCTAssertEqual(MarketLightLevel.red.rawValue, "红灯")
        XCTAssertEqual(MarketLightLevel.yellow.rawValue, "黄灯")
        XCTAssertEqual(MarketLightLevel.green.rawValue, "绿灯")
        // 新增档位必须同时决定线上格式（读取侧不认识的值会静默落空）
        XCTAssertEqual(MarketLightLevel.allCases.count, 3)

        // 解析：三值可往返；空串 / 未识别 / 非字符串 / 缺失 → nil
        // （各调用点据此保留自己原有的回落：灰 / 未知 / 非 crash / 实时默认绿灯）
        for level in MarketLightLevel.allCases {
            XCTAssertEqual(MarketLightLevel(json: level.rawValue), level)
            XCTAssertEqual(MarketLightLevel(rawValue: level.rawValue), level)
        }
        XCTAssertNil(MarketLightLevel(json: ""))
        XCTAssertNil(MarketLightLevel(json: "紫灯"))
        XCTAssertNil(MarketLightLevel(json: nil))
        XCTAssertNil(MarketLightLevel(json: 1))
        XCTAssertNil(MarketLightLevel(rawValue: "red"), "英文代号不是线上格式")
    }
}
