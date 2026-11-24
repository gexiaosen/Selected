import XCTest
@testable import SelectedCore

/// 四阶段实体 vs **真实引擎输出**
///
/// 夹具是 `engine/tests/fixtures/phase_outputs/{predict,verify,review,iterate}.json` ——
/// **Swift 侧真实产出**，手工捕获、不可再生。
///
/// 与 `ScanEntityTests` 用同一套验证（`EntityTestSupport`）：键覆盖 + 无损往返。
final class PhaseEntityTests: XCTestCase {

    private func load(_ phase: String) throws -> JSONValue {
        try EntityTestSupport.fixture("engine/tests/fixtures/phase_outputs/\(phase).json")
    }

    // MARK: - predict

    func testPredictCoversExactlyAndRoundTrips() throws {
        let json = try load("predict")
        try EntityTestSupport.check(PredictResult.self, json, "predict")
        let r = PredictResult(json)
        // 预判的 market_env 与扫描结果/库行**共用 `MarketEnv`` ——
        // 它只填其中 10 个键，其余键靠 `conditionalKeys` 放行
        try EntityTestSupport.check(MarketEnv.self, r.marketEnv.json, "predict.market_env")
        for (i, s) in r.stocks.enumerated() {
            try EntityTestSupport.check(PredictStock.self, s.json, "predict.stocks[\(i)]")
        }
    }

    func testPredictTypedValues() throws {
        let r = PredictResult(try load("predict"))
        XCTAssertEqual(r.status, "ok")
        XCTAssertTrue(r.isOK)
        XCTAssertFalse(r.isEmptyDay)
        XCTAssertTrue(r.persistenceVerified)
        XCTAssertEqual(r.predictDate, "2026-09-14")
        XCTAssertEqual(r.selDate, "2026-09-11")
        XCTAssertFalse(r.overall.isEmpty, "总体结论不该为空（空则说明键名读错）")

        let me = r.marketEnv
        XCTAssertEqual(me.light, "红灯")
        XCTAssertFalse(me.lightDesc.isEmpty)
        XCTAssertTrue(me.shConsecutiveDecline)
        XCTAssertEqual(me.sh3dDeclineCount, 2)
        XCTAssertNotNil(me.shChangePctOrNil)

        let s = try XCTUnwrap(r.stocks.first)
        XCTAssertEqual(s.code, "000032")
        XCTAssertEqual(s.name, "深桑达A")
        XCTAssertEqual(s.riskLevel, "极高")
        XCTAssertEqual(s.signalType, "strongest")
        XCTAssertEqual(s.signalTypeName, "最强信号")
        XCTAssertTrue(s.signalVerified)
        XCTAssertEqual(s.strategyKey, "crash")
        XCTAssertEqual(s.positionAdvice, "空仓观望")
        XCTAssertEqual(s.sellWindowStart, "--", "无卖出窗口时是 --")
        XCTAssertFalse(s.scores.isEmpty, "轮次得分不该为空")
        XCTAssertEqual(Set(s.scores.keys), ["1", "2", "3"])
    }

    // MARK: - verify

    func testVerifyCoversExactlyAndRoundTrips() throws {
        let json = try load("verify")
        try EntityTestSupport.check(VerifyResult.self, json, "verify")
        let r = VerifyResult(json)
        try EntityTestSupport.check(VerifyStats.self, r.stats.json, "verify.stats")
        try EntityTestSupport.check(VerifyGroupStats.self, r.stats.total.json, "verify.stats.total")
        try EntityTestSupport.check(VerifyGroupStats.self, r.stats.consensus.json,
                                    "verify.stats.consensus")
        try EntityTestSupport.check(VerifyGroupStats.self, r.stats.pulse.json, "verify.stats.pulse")
        for (i, d) in r.detail.enumerated() {
            try EntityTestSupport.check(VerifyDetail.self, d.json, "verify.detail[\(i)]")
        }
        for (i, d) in r.deviations.enumerated() {
            try EntityTestSupport.check(VerifyDeviation.self, d.json, "verify.deviations[\(i)]")
        }
        for (name, g) in r.groups {
            try EntityTestSupport.check(VerifyGroupStats.self, g.json, "verify.groups[\(name)]")
        }
    }

    func testVerifyTypedValues() throws {
        let r = VerifyResult(try load("verify"))
        XCTAssertEqual(r.dataMode, "live")
        XCTAssertTrue(r.persisted)
        XCTAssertEqual(r.selDate, "2026-09-11")
        XCTAssertFalse(r.warnings.isEmpty, "有告警时不该读成空")
        XCTAssertEqual(r.stats.total.verified, r.detail.count, "总体样本数应等于明细行数")
        XCTAssertEqual(r.stats.total.wins + r.stats.total.losses, r.stats.total.verified)
        // 分组键是中文（动态键）→ 用字典访问是语义正确的
        XCTAssertEqual(Set(r.groups.keys), ["最强+持续", "脉冲信号"])

        let d = try XCTUnwrap(r.detail.first)
        XCTAssertEqual(d.code, "000032")
        XCTAssertEqual(d.outcome, "亏损")
        XCTAssertFalse(d.scores.isEmpty)
        let dev = try XCTUnwrap(r.deviations.first)
        XCTAssertEqual(dev.code, "000088")
        XCTAssertFalse(dev.predicted.isEmpty)
    }

    // MARK: - review

    func testReviewCoversExactlyAndRoundTrips() throws {
        let json = try load("review")
        try EntityTestSupport.check(ReviewResult.self, json, "review")
        let r = ReviewResult(json)
        try EntityTestSupport.check(ReviewAccuracy.self, r.accuracy.json, "review.accuracy")
        try EntityTestSupport.check(ReviewFourLayer.self, r.fourLayerWinrate.json,
                                    "review.four_layer_winrate")
        for (name, w) in [("disciplined", r.fourLayerWinrate.disciplined),
                          ("gap", r.fourLayerWinrate.gap),
                          ("window", r.fourLayerWinrate.window),
                          ("close", r.fourLayerWinrate.close),
                          ("snapshot", r.fourLayerWinrate.snapshot),
                          ("ceiling", r.fourLayerWinrate.ceiling)] {
            try EntityTestSupport.check(WinRate.self, w.json, "review.four_layer_winrate.\(name)")
        }
        try EntityTestSupport.check(ReviewOutcomes.self, r.outcomes.json, "review.outcomes")
        for (i, s) in r.stocks.enumerated() {
            try EntityTestSupport.check(ReviewStock.self, s.json, "review.stocks[\(i)]")
        }
    }

    func testReviewTypedValues() throws {
        let r = ReviewResult(try load("review"))
        XCTAssertEqual(r.light, "绿灯")
        XCTAssertFalse(r.crashDay)
        XCTAssertEqual(r.disciplinedTargetPct, 1.5)
        XCTAssertEqual(r.targetDay, "2026-09-14")
        XCTAssertFalse(r.targetDayEstimated)
        XCTAssertNil(r.reference, "本夹具 reference 是 null → 应读成 nil")
        XCTAssertEqual(r.outcomes.count, 3)
        XCTAssertEqual(r.outcomes.targetPct, 1.5)
        XCTAssertEqual(r.outcomes.window.count, 2)
        XCTAssertEqual(r.fourLayerWinrate.window.total, 2)

        let s = try XCTUnwrap(r.stocks.first)
        XCTAssertEqual(s.code, "000032")
        XCTAssertFalse(s.skipped)
        XCTAssertEqual(s.sellWindow, "10:00-10:30")
        XCTAssertEqual(s.discTargetPct, 1.5)
        XCTAssertEqual(s.highTime, "10:30")
        XCTAssertNil(s.discHitTime, "本夹具 disc_hit_time 是 null → 应读成 nil（不是 \"--\"）")
        XCTAssertEqual(s.tpProfits.count, 9, "逐时点表应有 9 个时刻（动态键）")
        XCTAssertEqual(Set(s.tpProfits.keys),
                       ["09:35", "10:00", "10:30", "11:00", "11:30", "13:30", "14:00", "14:30", "15:00"])
    }

    /// `disc_hit_time` 是"可能没有"（不是空串、不是 `--`）—— 保留 null 语义
    func testNullableReviewFieldsKeepNullDistinct() {
        let s = ReviewStock(JSONValue(["disc_hit_time": NSNull()]))
        XCTAssertNil(s.discHitTime)
        XCTAssertEqual(ReviewStock(JSONValue(["disc_hit_time": "10:30"])).discHitTime, "10:30")
        XCTAssertNil(ReviewStock(JSONValue([:])).discHitTime, "键缺失也是 nil")
    }

    /// `reference` 在夹具里恒为 `null`，键覆盖 / 往返测试**证明不了它的类型**。
    /// 这里用**构造数据**把类型钉死（对照生产者 `PhaseReview.swift:491` 的
    /// `{close_winrate, ceiling_winrate}` 与消费者 `ReviewView` 的读法）。
    func testReferenceIsANestedObjectNotAString() throws {
        XCTAssertNil(ReviewResult(JSONValue(["reference": NSNull()])).reference,
                     "null → nil")
        XCTAssertNil(ReviewResult(JSONValue([:])).reference, "键缺失 → nil")

        let r = ReviewResult(JSONValue([
            "reference": ["close_winrate": 42.5, "ceiling_winrate": 78.0],
        ]))
        let ref = try XCTUnwrap(r.reference, "非 null 时应解出对象")
        try EntityTestSupport.check(ReviewReference.self, ref.json, "review.reference")
        XCTAssertEqual(ref.closeWinrate, 42.5)
        XCTAssertEqual(ref.ceilingWinrate, 78.0)
        XCTAssertFalse(ref.isEmptyObject)

        // 消费者用它决定"要不要显示参考卡片"：缺 close_winrate 就不显示
        XCTAssertNil(ReviewReference(JSONValue(["ceiling_winrate": 1.0])).closeWinrateOrNil)
    }

    // MARK: - iterate

    func testIterateCoversExactlyAndRoundTrips() throws {
        let json = try load("iterate")
        try EntityTestSupport.check(IterateResult.self, json, "iterate")
        let r = IterateResult(json)
        try EntityTestSupport.check(IterateEmptyTrend.self, r.emptyTrend.json,
                                    "iterate.empty_trend")
        for (i, d) in r.emptyTrend.daily.enumerated() {
            try EntityTestSupport.check(IterateEmptyDay.self, d.json, "iterate.empty_trend.daily[\(i)]")
        }
        try EntityTestSupport.check(IterateFourLayerAvg.self, r.fourLayerAvg.json,
                                    "iterate.four_layer_avg")
        for (name, g) in r.groupAnalysis {
            try EntityTestSupport.check(IterateGroup.self, g.json, "iterate.group_analysis[\(name)]")
        }
    }

    func testIterateTypedValues() throws {
        let r = IterateResult(try load("iterate"))
        XCTAssertEqual(r.status, "ok")
        XCTAssertEqual(r.counter, 0)
        XCTAssertFalse(r.isEmptyDayReport)
        XCTAssertFalse(r.insights.isEmpty)
        XCTAssertEqual(r.emptyTrend.totalDays, 4)
        XCTAssertEqual(r.emptyTrend.daily.count, 4)
        XCTAssertEqual(r.fourLayerAvg.window, 62.0)
        XCTAssertEqual(Set(r.groupAnalysis.keys), ["consensus", "pulse"])
        XCTAssertEqual(r.groupAnalysis["consensus"]?.count, 3)

        // 展示口径
        XCTAssertEqual(r.triggerDate, "2026-09-14")
        XCTAssertEqual(r.triggerDateDash, r.triggerDate, "键存在时 dash 口径与 str 一致")
        XCTAssertEqual(r.statusDash, r.status, "键存在时 dash 口径与 str 一致")
    }

    /// `predict` 的大盘灯：`marketLightDash` 只能来自 `market_env.light`
    ///
    /// `market_light` 是**自选判定**的键，`PhasePredict` **从不产出**它（本断言即证据）
    /// —— 回退链前半段是**死分支**，`marketLightDash` 只能来自 `market_env.light`。
    func testPredictMarketLightDashIsNotADeadFallback() throws {
        let r = PredictResult(try load("predict"))
        XCTAssertFalse(r.json.dict.keys.contains("market_light"),
                       "PhasePredict 从不产出 market_light（它是 WatchJudge 的键）")
        XCTAssertEqual(r.marketLightDash, r.marketEnv.lightDash)
        XCTAssertEqual(r.marketLightDash, "红灯")
    }

    /// 回归锁：**`predict_date` 是纯日期，时刻在 `predict_time` 里**
    ///
    /// `predict_date` 只有 10 个字符，想切出时刻而 `dropFirst(11)` 得**空串**。
    /// 这条断言把"哪个字段是时刻"钉死，防止再有人把两者搞混。
    func testPredictDateIsDateOnlyWhileTimeHoldsTheClock() throws {
        let r = PredictResult(try load("predict"))
        XCTAssertEqual(r.predictDate, "2026-09-14")
        XCTAssertEqual(r.predictDate.count, 10, "纯日期，没有时间部分")
        XCTAssertEqual(String(r.predictDate.dropFirst(11)), "",
                       "旧写法得空串 —— 这就是那个显示缺陷本身")
        XCTAssertEqual(r.predictTime, "10:22", "时刻在 predict_time 里")
        XCTAssertTrue(r.predictTime.contains(":"), "形如 09:30 / 10:22")
    }

    // MARK: - 早退分支与缺键退化

    func testEarlyReturnShapesTolerateMissingKeys() throws {
        // 各阶段早退时往往只返回 status + 少量键
        for json in [JSONValue(["status": "no_sel_data"]),
                     JSONValue(["status": "not_trading_day"]),
                     JSONValue(["status": "empty_day", "is_empty_day": true])] {
            let p = PredictResult(json)
            XCTAssertEqual(p.status, json["status"].string)
            XCTAssertFalse(p.isOK)
            XCTAssertTrue(p.stocks.isEmpty)
            XCTAssertEqual(p.marketEnv.light, "")
            try EntityTestSupport.assertLossless(p, json, "predict-early")

            let v = VerifyResult(json)
            XCTAssertTrue(v.detail.isEmpty)
            XCTAssertEqual(v.stats.total.verified, 0)
            try EntityTestSupport.assertLossless(v, json, "verify-early")

            let rv = ReviewResult(json)
            XCTAssertTrue(rv.stocks.isEmpty)
            XCTAssertEqual(rv.fourLayerWinrate.window.total, 0)
            try EntityTestSupport.assertLossless(rv, json, "review-early")

            let it = IterateResult(json)
            XCTAssertTrue(it.insights.isEmpty)
            XCTAssertEqual(it.emptyTrend.totalDays, 0)
            try EntityTestSupport.assertLossless(it, json, "iterate-early")
        }
    }

    func testEmptyObjectsFallBackWithoutCrash() {
        let p = PredictResult(JSONValue([:]))
        XCTAssertEqual(p.status, "ok", "status 缺省 ok")
        XCTAssertEqual(p.marketEnv.shChangePct, 0)
        XCTAssertNil(p.marketEnv.shChangePctOrNil)
        XCTAssertTrue(p.scores(for: "nope").isEmpty)

        let r = ReviewResult(JSONValue([:]))
        XCTAssertNil(r.reference)
        XCTAssertEqual(r.fourLayerWinrate.disciplined.winrate, 0)
        XCTAssertEqual(r.outcomes.window, [])

        let v = VerifyResult(JSONValue([:]))
        XCTAssertTrue(v.groups.isEmpty)
        XCTAssertEqual(v.stats.total.verified, 0)
    }

    // MARK: - 库读取路径（键集与阶段产出**不同**）

    /// 同一个逻辑实体在**两条路径**上键集不同。夹具只覆盖"阶段产出"，
    /// 而视图读的 `store.verifyReport` / `reviewReport` / `predictReport` 走的是**库读取**
    /// （`SQLiteReader.*Row`）。这里按 `SQLiteReader` 的真实形状构造数据，把那条路径也钉住 ——
    /// 否则 `ReviewView` 读 `verifyReport.isEmptyDay` 这类键会踩空（而且**不报错**，只是永远 false）。
    ///
    /// 形状照抄 `SQLiteReader.swift:344-409`。
    func testDatabaseReadPathKeySetsAreCovered() throws {
        // predictRow
        let predictDB = JSONValue([
            "status": "ok", "predict_date": "2026-09-14", "sel_date": "2026-09-11",
            "predict_time": "10:22", "market_env": [String: Any](),
            "stocks": [Any](), "is_empty_day": 0, "overall": [Any](),
        ])
        try EntityTestSupport.check(PredictResult.self, predictDB, "predict(db)")
        let p = PredictResult(predictDB)
        XCTAssertTrue(p.isOK)
        XCTAssertFalse(p.isExplicitlyUnverified, "库读取路径没有 persistence_verified → 不该算未验证")
        XCTAssertFalse(p.isEmptyDay)

        // verifyRow
        let verifyDB = JSONValue([
            "status": "ok", "sel_date": "2026-09-11", "verify_time": "10:22",
            "stats": [String: Any](), "detail": [Any](), "deviations": [Any](),
            "warnings": [Any](), "is_empty_day": false,
        ])
        try EntityTestSupport.check(VerifyResult.self, verifyDB, "verify(db)")
        let v = VerifyResult(verifyDB)
        XCTAssertTrue(v.isOK)
        XCTAssertFalse(v.isEmptyDay)
        XCTAssertEqual(v.stats.total.verified, 0)

        // reviewRow
        let reviewDB = JSONValue([
            "status": "ok", "sel_date": "2026-09-11", "review_time": "15:05",
            "four_layer_winrate": [String: Any](), "accuracy": [String: Any](),
            "stocks": [Any](), "is_empty_day": 0, "insights": [Any](),
            "reference": [String: Any](),
        ])
        try EntityTestSupport.check(ReviewResult.self, reviewDB, "review(db)")
        let r = ReviewResult(reviewDB)
        XCTAssertTrue(r.isOK)
        XCTAssertFalse(r.isEmptyDay)
        // 库读取路径把 reference 解析成 `{}`（不是 null）→ 必须被 isEmptyObject 挡住，
        // 否则"暴跌日参考数据"卡片会在无参考时凭空出现
        let ref = try XCTUnwrap(r.reference)
        XCTAssertTrue(ref.isEmptyObject)
        XCTAssertNil(ref.closeWinrateOrNil)

        // iterateRow
        let iterateDB = JSONValue([
            "trigger_date": "2026-09-14", "is_empty_day_report": 0, "counter": 0,
            "insights": [Any](), "empty_trend": [String: Any](),
            "four_layer_avg": [String: Any](),
        ])
        try EntityTestSupport.check(IterateResult.self, iterateDB, "iterate(db)")
        let it = IterateResult(iterateDB)
        XCTAssertEqual(it.counter, 0)
        XCTAssertTrue(it.groupAnalysis.isEmpty, "库读取路径没有 group_analysis")
    }

    /// 库读取路径把 `reference` 存成 `{}`（`jdict`），阶段产出是 `null` —— 两种都要能处理
    func testReferenceHandlesBothNullAndEmptyObject() throws {
        XCTAssertNil(ReviewResult(JSONValue(["reference": NSNull()])).reference)
        let empty = try XCTUnwrap(ReviewResult(JSONValue(["reference": [String: Any]()])).reference)
        XCTAssertTrue(empty.isEmptyObject)
        XCTAssertNil(empty.closeWinrateOrNil)
    }
}

private extension PredictResult {
    /// 便于上面断言用的空值探针（`stocks` 为空时自然也是空）
    func scores(for code: String) -> [String: Double] {
        stocks.first { $0.code == code }?.scores ?? [:]
    }
}
