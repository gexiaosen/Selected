import XCTest
@testable import SelectedCore

/// 市场状态机 —— `PredictRules.classifyRegime` / `isRedLight` 的专项测试
///
/// 状态机是**纯附加**（往 `market_env` 多写 `regime` / `ma_period_used`），
/// 所以测试分两半：
///   ① 状态机本身对不对（五态 / MA 阶梯 / 历史不足 / 剔除当日未完成 bar）
///   ② **判定没被改**（`light` 与 `buildStrategy` 的输出与加 regime 之前逐字一致）
///
/// 为什么 ② 必须单独立一条：唯一能出的差错就是"顺手改了判定"，
///   而状态机单测再多也证明不了"判定没被动过"。
final class MarketRegimeTests: XCTestCase {

    private let rules: [String: Any] = ["red_decline_days": 2]

    // MARK: - 造数

    /// 已完成日K：`day` 一律落在 2026-08，**不等于** `today`
    private func done(_ closes: [Double]) -> [KLineBar] {
        closes.enumerated().map { i, c in
            KLineBar(day: String(format: "2026-08-%02d", i + 1),
                     open: c, high: c, low: c, close: c, volume: 0)
        }
    }

    /// 升序 / 降序序列（差值为 1）
    private func ramp(_ from: Int, _ to: Int) -> [Double] {
        let step = from <= to ? 1 : -1
        return stride(from: from, through: to, by: step).map(Double.init)
    }

    private func classify(_ closes: [Double], decline: Bool = false, count: Int = 0,
                          today: String = "2026-09-14") -> PredictRules.MarketRegime {
        PredictRules.classifyRegime(kline: done(closes), today: today,
                                    consecutiveDecline: decline, declineCount: count,
                                    rules: rules)
    }

    // MARK: - MA 阶梯

    /// 阶梯是 60/20/10，**取历史能支持的最长**；"支持"= 够算 MA 且够算它的 5 日斜率
    /// （`根数 ≥ P + 5`）
    func testLadderPicksLongestSupportedPeriod() {
        XCTAssertEqual(classify(ramp(1, 70)).maPeriodUsed, 60, "70 根 ≥ 60+5 → 用 60")
        XCTAssertEqual(classify(ramp(1, 65)).maPeriodUsed, 60, "恰好 65 根 → 60（边界）")
        XCTAssertEqual(classify(ramp(1, 64)).maPeriodUsed, 20, "64 根不够 60+5 → 退到 20")
        XCTAssertEqual(classify(ramp(1, 30)).maPeriodUsed, 20)
        XCTAssertEqual(classify(ramp(1, 25)).maPeriodUsed, 20, "恰好 25 根 → 20（边界）")
        XCTAssertEqual(classify(ramp(1, 24)).maPeriodUsed, 10, "24 根不够 20+5 → 退到 10")
        XCTAssertEqual(classify(ramp(1, 15)).maPeriodUsed, 10, "恰好 15 根 → 10（边界）")
    }

    /// 连 10 都支持不了 → `UNKNOWN` / 0，但**两个键照常产出**
    /// （键存在性比"有没有值"更重要：消费方靠它区分"没报"与"值是 0"）
    func testUnknownWhenHistoryTooShort() {
        let r = classify(ramp(1, 14))
        XCTAssertEqual(r.regime, "UNKNOWN")
        XCTAssertEqual(r.maPeriodUsed, 0)
        XCTAssertEqual(Set(r.json.keys), ["regime", "ma_period_used"])
    }

    // MARK: - 五态

    /// 五态各自的最小构造（P=10；15 根已完成日K）
    ///
    /// 判据：`ma = mean(close[5...14])`、`maPrev = mean(close[0...9])`、`price = close[14]`
    func testFiveStates() {
        // 升序：MA 上行（10.5 > 5.5）且价在上（15 > 10.5）
        XCTAssertEqual(classify(ramp(1, 15)).regime, "BULL_TREND")

        // 升序后最后一根砸下来：MA 仍上行（9.5 > 5.5）但价在下（5 < 9.5）
        XCTAssertEqual(classify(ramp(1, 14) + [5]).regime, "BULL_CORRECTION")

        // 降序：MA 下行（5.5 < 10.5）且价在下（1 < 5.5）
        XCTAssertEqual(classify(ramp(15, 1)).regime, "BEAR_TREND")

        // 降序后最后一根拉起来：MA 仍下行（6.6 < 10.5）但价在上（12 > 6.6）
        XCTAssertEqual(classify(ramp(15, 2) + [12]).regime, "RECOVERY")
    }

    /// 红灯优先：连跌条件成立时，**不管价格与 MA 的关系**都判 `PANIC`
    func testRedLightOverridesPriceAndSlope() {
        // 明明是 BULL_TREND 的形状，但连跌条件成立 → PANIC
        XCTAssertEqual(classify(ramp(1, 15), decline: true, count: 2).regime, "PANIC")
        // 阈值来自参数：red_decline_days=2，count=1 不够
        XCTAssertEqual(classify(ramp(1, 15), decline: true, count: 1).regime, "BULL_TREND")
        // 连跌标志为 false 时，count 再大也不算红灯（与 classifyMarketLight 同口径）
        XCTAssertEqual(classify(ramp(1, 15), decline: false, count: 9).regime, "BULL_TREND")
    }

    /// `isRedLight` 与 `classifyMarketLight` 的第一分支**必须是同一个判据**
    ///
    /// 这条是"PANIC ⟺ 红灯"的结构性保证 —— 两处各写一遍必然漂移出
    /// "预判页红灯、状态机说 BEAR_TREND"。
    func testIsRedLightMatchesLightClassification() {
        for (decline, count) in [(true, 2), (true, 3), (true, 1), (false, 0), (false, 9)] {
            let lastEnv: [String: Any] = ["sh_consecutive_decline": decline,
                                          "sh_3d_decline_count": count, "sh_ok": true]
            let mc = PredictRules.classifyMarketLight(marketData: [:], lastEnv: lastEnv,
                                                      rules: rules)
            let red = PredictRules.isRedLight(consecutiveDecline: decline,
                                              declineCount: count, rules: rules)
            XCTAssertEqual(red, (mc["light"] as? String) == "红灯",
                           "decline=\(decline) count=\(count)：isRedLight 与 light 判据不一致")
        }
    }

    // MARK: - 口径

    /// 与 `marketConsecutiveDecline` 同口径：**当日未完成 bar 必须剔除**
    /// （否则盘中那根会被当成收盘价，状态机随分钟跳动）
    func testTodayBarIsExcluded() {
        let closes = ramp(1, 15)
        let base = classify(closes)
        var kline = done(closes)
        kline.append(KLineBar(day: "2026-09-14", open: 999, high: 999, low: 999,
                              close: 999, volume: 0))
        let withToday = PredictRules.classifyRegime(kline: kline, today: "2026-09-14",
                                                    consecutiveDecline: false, declineCount: 0,
                                                    rules: rules)
        XCTAssertEqual(withToday.regime, base.regime)
        XCTAssertEqual(withToday.maPeriodUsed, base.maPeriodUsed)
    }

    /// 收盘价为 0 的坏 bar 也要剔（与 `marketConsecutiveDecline` 的 `close != 0` 一致）
    func testZeroCloseBarsAreDropped() {
        var kline = done(ramp(1, 15))
        kline.insert(KLineBar(day: "2026-07-31", open: 0, high: 0, low: 0, close: 0, volume: 0),
                     at: 0)
        let r = PredictRules.classifyRegime(kline: kline, today: "2026-09-14",
                                            consecutiveDecline: false, declineCount: 0,
                                            rules: rules)
        XCTAssertEqual(r.maPeriodUsed, 10)
        XCTAssertEqual(r.regime, "BULL_TREND", "坏 bar 被剔掉后仍是升序 15 根")
    }

    // MARK: - 判定未被改（回归锁）

    /// `regime == "UNKNOWN"`（历史不足）时**逐字复现旧行为** —— 这条锁死
    /// "市场状态机在拿不到状态时什么都不做"。
    ///
    /// `regime` **已知**时会按 `regime_thresholds` 浮动目标价/止损价
    /// （见 `testRegimeThresholdsShiftTargetAndStop`），所以这条只对 `UNKNOWN` 成立。
    func testUnknownRegimeLeavesBuildStrategyUntouched() {
        let strategies = Self.strategyMatrix
        let mc: [String: Any] = ["light": "绿灯", "sh_ok": true, "sh_consecutive_decline": false]
        for signal: SignalType in [.strongest, .pulse] {
            let base = PredictRules.buildStrategy(marketClass: mc, signalType: signal,
                                                  selPrice: 10, strategies: strategies)
            var withUnknown = mc
            for (k, v) in PredictRules.MarketRegime(regime: "UNKNOWN", maPeriodUsed: 0).json {
                withUnknown[k] = v
            }
            let got = PredictRules.buildStrategy(marketClass: withUnknown, signalType: signal,
                                                 selPrice: 10, strategies: strategies)
            XCTAssertEqual(got["strategy_key"] as? String, base["strategy_key"] as? String)
            XCTAssertEqual(got["target_price"] as? Double, base["target_price"] as? Double)
            XCTAssertEqual(got["stop_loss_price"] as? Double, base["stop_loss_price"] as? Double)
        }
    }

    /// 红灯日仍走 `crash` 分支（空仓）—— 与 regime 无关；且 `PANIC` 的偏移**结构上不生效**
    func testRedLightStillCrashesAndPanicAdjustmentIsInert() {
        let strategies = Self.strategyMatrix
        let lastEnv: [String: Any] = ["sh_consecutive_decline": true,
                                      "sh_3d_decline_count": 2, "sh_ok": false]
        let mc = PredictRules.classifyMarketLight(marketData: [:], lastEnv: lastEnv, rules: rules)
        XCTAssertEqual(mc["light"] as? String, "红灯")

        for signal: SignalType in [.strongest, .pulse] {
            let before = PredictRules.buildStrategy(marketClass: mc, signalType: signal,
                                                    selPrice: 10, strategies: strategies)
            var withPanic = mc
            for (k, v) in PredictRules.MarketRegime(regime: "PANIC", maPeriodUsed: 20).json {
                withPanic[k] = v
            }
            let after = PredictRules.buildStrategy(marketClass: withPanic, signalType: signal,
                                                   selPrice: 10, strategies: strategies)
            XCTAssertEqual(before["strategy_key"] as? String, "crash")
            XCTAssertEqual(after["strategy_key"] as? String, "crash",
                           "红灯日必须仍走 crash 分支（空仓）")
            XCTAssertEqual(after["target_price"] as? Double, before["target_price"] as? Double)
            XCTAssertEqual(after["stop_loss_price"] as? Double, before["stop_loss_price"] as? Double)
        }
    }

    /// 已知状态时目标价 / 止损价按 `regime_thresholds` 浮动（含符号方向）
    func testRegimeThresholdsShiftTargetAndStop() {
        let strategies = Self.strategyMatrix
        let mc: [String: Any] = ["light": "绿灯", "sh_ok": true, "sh_consecutive_decline": false]
        let signal: SignalType = .strongest   // → up_consensus：target 5 / stop -3
        func target(_ regime: String) -> (Double, Double) {
            var m = mc
            for (k, v) in PredictRules.MarketRegime(regime: regime, maPeriodUsed: 20).json { m[k] = v }
            let s = PredictRules.buildStrategy(marketClass: m, signalType: signal,
                                               selPrice: 100, strategies: strategies)
            return ((s["target_price"] as? Double) ?? 0, (s["stop_loss_price"] as? Double) ?? 0)
        }
        XCTAssertEqual(target("BULL_TREND").0, 105, "基准：不动")
        XCTAssertEqual(target("BULL_TREND").1, 97)
        // 多头回调：目标下调 1pt（105 → 104）、止损放宽 0.5pt（97 → 97.5）
        XCTAssertEqual(target("BULL_CORRECTION").0, 104)
        XCTAssertEqual(target("BULL_CORRECTION").1, 97.5)
        // 空头：目标上调 1pt（105 → 106）、止损收紧 0.5pt（97 → 96.5）
        XCTAssertEqual(target("BEAR_TREND").0, 106)
        XCTAssertEqual(target("BEAR_TREND").1, 96.5)
        // 修复：目标下调 0.5pt（105 → 104.5）、止损不动
        XCTAssertEqual(target("RECOVERY").0, 104.5)
        XCTAssertEqual(target("RECOVERY").1, 97)
    }

    /// 参数里的 `predict_rules.regime_thresholds` 覆盖默认表；缺某一态时**逐态回落**
    ///
    /// 本测试**必须跟着键路径走**：键路径变了而测试不改，它会静默退化成
    /// "覆盖值被忽略、全回落默认"，而两条断言恰好都指向默认值时会**假绿**。
    func testRegimeThresholdsOverrideAndPerStateFallback() {
        let overridden = PredictRules.regimeThresholds(from: [
            "predict_rules": [
                "regime_thresholds": ["BEAR_TREND": ["target_adj": 9.0, "score_adj": 7.0]],
            ],
        ])
        XCTAssertEqual(overridden["BEAR_TREND"]?["target_adj"], 9.0)
        XCTAssertEqual(overridden["BEAR_TREND"]?["score_adj"], 7.0)
        XCTAssertEqual(overridden["BEAR_TREND"]?["stop_adj"],
                       PredictRules.defaultRegimeThresholds["BEAR_TREND"]?["stop_adj"],
                       "只覆盖了 target/score，stop 必须回落默认")
        XCTAssertEqual(overridden["PANIC"]?["score_adj"],
                       PredictRules.defaultRegimeThresholds["PANIC"]?["score_adj"],
                       "没提到的状态整体回落默认")

        // 参数里完全没有这一组 → 全用默认表
        XCTAssertEqual(PredictRules.regimeThresholds(from: [:]).count,
                       PredictRules.defaultRegimeThresholds.count)
    }

    /// 未知 / 空 regime 的偏移必须是 0（不猜）
    func testRegimeAdjustmentIsZeroForUnknown() {
        let t = PredictRules.defaultRegimeThresholds
        for r in ["", "UNKNOWN", "NOT_A_STATE"] {
            let a = PredictRules.regimeAdjustment(regime: r, thresholds: t)
            XCTAssertEqual(a.targetAdj, 0)
            XCTAssertEqual(a.stopAdj, 0)
            XCTAssertEqual(a.scoreAdj, 0)
        }
    }

    /// B3：自选的三条线按状态**整体浮动**（同一份 `score_adj`）
    func testWatchScoreThresholdsShiftByRegime() {
        let params: [String: Any] = ["scoring": ["tiers": ["tier1_min": 85, "tier2_min": 60]]]
        let base = WatchJudge.scoreThresholds(params, regime: "BULL_TREND")
        XCTAssertEqual(base.buy, 85)
        XCTAssertEqual(base.watch, 60)
        XCTAssertEqual(base.decay, 60)
        // 多头回调：放松 3 分（降门槛）
        let corr = WatchJudge.scoreThresholds(params, regime: "BULL_CORRECTION")
        XCTAssertEqual(corr.buy, 82)
        XCTAssertEqual(corr.watch, 57)
        XCTAssertEqual(corr.decay, 57)
        // 空头：收紧 5 分
        let bear = WatchJudge.scoreThresholds(params, regime: "BEAR_TREND")
        XCTAssertEqual(bear.buy, 90)
        XCTAssertEqual(bear.decay, 65)
        // 未知状态 / 不传 regime → 逐字复现旧行为
        XCTAssertEqual(WatchJudge.scoreThresholds(params, regime: "UNKNOWN").buy, 85)
        XCTAssertEqual(WatchJudge.scoreThresholds(params).buy, 85)
        XCTAssertEqual(WatchJudge.scoreThresholds(params).watch, 60)
    }

    /// 门槛表只有**一个来源**：`PredictRules.defaultRegimeThresholds`（Swift 侧）。
    /// 出厂参数文件**不带**这组键 —— 若带就是两套来源：改一边另一边不变，
    /// **没有任何测试会红**。
    ///
    /// 本测试必须**显式断言当前形状**（键若被加回来则要求逐值与默认表一致），
    /// 不能写成"`fromJSON` 必然等于默认表"那种恒真式 —— 那是静默假绿。
    func testDefaultTableMatchesFactoryParams() throws {
        let json = try EntityTestSupport.fixture("engine/params/backtest_v1_3_0.json")
        let raw = (json.raw as? [String: Any]) ?? [:]

        // 键在 `predict_rules.regime_thresholds`（schema 项，进参数中心）。
        guard let inFile = (raw["predict_rules"] as? [String: Any])?["regime_thresholds"]
                as? [String: Any] else {
            // 当前形状：出厂文件不带这组键 → 必须逐态回落默认表（行为不变）
            XCTAssertEqual(PredictRules.regimeThresholds(from: raw),
                           PredictRules.defaultRegimeThresholds,
                           "出厂文件缺该键时必须逐态回落默认表")
            return
        }
        // 有人把键加回来了（须同时更新 test_param_schema 的白名单）→ 值必须与默认表一致，
        // 否则"参数里写着"与"回落默认"会给出两个不同的行为（漂移且不报错）
        XCTAssertEqual(Set(inFile.keys), Set(PredictRules.defaultRegimeThresholds.keys),
                       "出厂文件的状态集必须与默认表完全一致")
        for (regime, row) in PredictRules.defaultRegimeThresholds {
            let got = inFile[regime] as? [String: Any] ?? [:]
            for k in ["target_adj", "stop_adj", "score_adj"] {
                XCTAssertEqual(got[k] as? Double, row[k], "\(regime).\(k) 与默认表不一致")
            }
        }
    }

    /// 测试用的五分支矩阵（`up_consensus` 是 target 5 / stop -3）。
    /// 写成**计算属性**而不是 `static let`：`[String: Any]` 不是 `Sendable`，
    /// 存储型全局会被 Swift 6 并发检查拒绝（`static property ... not concurrency-safe`）。
    private static var strategyMatrix: [String: Any] { [
        "crash": ["window": ["09:30", "10:00"], "target_pct": 0, "stop_pct": -3,
                  "risk": "高", "position": "空仓", "direction": "下跌"],
        "up_pulse": ["window": ["09:35", "10:30"], "target_pct": 3, "stop_pct": -2,
                     "risk": "中", "position": "轻仓", "direction": "冲高"],
        "down_pulse": ["window": ["09:35", "10:30"], "target_pct": 2, "stop_pct": -2,
                       "risk": "中", "position": "轻仓", "direction": "反弹"],
        "up_consensus": ["window": ["10:00", "14:30"], "target_pct": 5, "stop_pct": -3,
                         "risk": "低", "position": "半仓", "direction": "上涨"],
        "down_consensus": ["window": ["10:00", "14:30"], "target_pct": 4, "stop_pct": -3,
                           "risk": "低", "position": "半仓", "direction": "反弹"],
    ] }

    /// `classifyMarketLight` 的输出键集**不受 regime 影响**（regime 是调用方另加的）
    func testClassifyMarketLightStillProducesExactlyItsOwnKeys() {
        let mc = PredictRules.classifyMarketLight(
            marketData: ["sh_open_pct": 0.5], lastEnv: ["sh_ok": true], rules: rules)
        XCTAssertEqual(Set(mc.keys), ["sh_open_pct", "sh_change_pct", "open_status", "sh_ok",
                                      "sh_3d_trend", "sh_consecutive_decline",
                                      "sh_3d_decline_count", "light", "light_desc", "us_market"])
        XCTAssertFalse(mc.keys.contains("regime"), "regime 由调用方合并，不在这里产出")
    }
}
