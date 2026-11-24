import XCTest
@testable import SelectedCore

/// Screener 画像避雷、区间自检、ETF 筛选与全量打分合成回归测试。
final class ScreenerScoringAndFilterTests: XCTestCase {

    override func setUpWithError() throws {
        try EntityTestSupport.requireParamSchema()
    }

    private func makeQuote(
        code: String = "600000",
        name: String = "浦发银行",
        price: Double = 10.5,
        preClose: Double = 10.0,
        changePct: Double = 4.0,
        volumeRatio: Double = 1.5,
        turnover: Double = 4.0,
        amplitude: Double = 4.0,
        avgPrice: Double = 10.3,
        amount: Double = 50_000_000
    ) -> EngineQuote {
        var q = EngineQuote()
        q.code = code
        q.name = name
        q.price = price
        q.preClose = preClose
        q.changePct = changePct
        q.volumeRatio = volumeRatio
        q.turnover = turnover
        q.amplitude = amplitude
        q.avgPrice = avgPrice
        q.amount = amount
        return q
    }

    private func makeDeep(
        ma20: Double? = 10.0,
        maPass: Bool = true,
        volMult5d: Double = 1.6,
        consecUp: Int = 2,
        cum5d: Double? = 7.0,
        prev1d: Double = 2.0,
        distFromLow: Double = 10.0,
        distFromHigh: Double = -8.0,
        ma20SlopeUp: Bool = true,
        maDeviation: Double = 1.5,
        gainRatio: Double = 0.8,
        shadowBodyRatio: Double = 0.5
    ) -> DeepInfo {
        DeepInfo(
            ma5: 10.4,
            ma10: 10.2,
            ma20: ma20,
            maPass: maPass,
            volMult5d: volMult5d,
            consecUp: consecUp,
            cum5d: cum5d,
            prev1d: prev1d,
            distFromLow: distFromLow,
            distFromHigh: distFromHigh,
            ma20SlopeUp: ma20SlopeUp,
            maDeviation: maDeviation,
            gainRatio: gainRatio,
            shadowBodyRatio: shadowBodyRatio
        )
    }

    // MARK: - profileRangeProblem & passesProfileRisk

    func testProfileRangeProblemCatchesEmptyInvertedAndNonNumeric() {
        XCTAssertNil(Screener.profileRangeProblem([:]))
        XCTAssertNil(Screener.profileRangeProblem([
            "change_pct": [1.0, 6.0],
            "volume_ratio": [0.8, 3.0],
            "turnover": [1.0, 10.0],
        ]))

        XCTAssertNotNil(Screener.profileRangeProblem(["change_pct": [2.0]]))
        XCTAssertNotNil(Screener.profileRangeProblem(["volume_ratio": ["bad", 3.0]]))
        XCTAssertNotNil(Screener.profileRangeProblem(["turnover": [8.0, 2.0]]))
        XCTAssertNotNil(Screener.profileRangeProblem(["turnover": [Double.nan, 5.0]]))
    }

    func testPassesProfileRiskEnforcesFiltersAndReplayFlags() throws {
        let pf: [String: Any] = [
            "change_pct": [1.0, 6.0],
            "volume_ratio": [0.8, 3.0],
            "turnover": [1.0, 8.0],
            "amplitude_max": 7.0,
            "price_ge_avg": true,
        ]
        let rf: [String: Any] = [
            "volume_ratio_hard_max": 2.5,
            "turnover_hard_max": 6.0,
        ]
        let stRegex = try NSRegularExpression(pattern: "ST|退")

        XCTAssertTrue(Screener.passesProfileRisk(
            code: "600000", q: makeQuote(), pf: pf, rf: rf,
            stPattern: stRegex, bsePrefix: "8"))

        // ST 与北交所前缀剔除
        XCTAssertFalse(Screener.passesProfileRisk(
            code: "600001", q: makeQuote(name: "*ST样本"), pf: pf, rf: rf,
            stPattern: stRegex, bsePrefix: "8"))
        XCTAssertFalse(Screener.passesProfileRisk(
            code: "830001", q: makeQuote(code: "830001"), pf: pf, rf: rf,
            stPattern: stRegex, bsePrefix: "8"))

        // 风险硬上限（落在画像内但超过 rf 硬上限）
        XCTAssertFalse(Screener.passesProfileRisk(
            code: "600002", q: makeQuote(volumeRatio: 2.8), pf: pf, rf: rf,
            stPattern: stRegex, bsePrefix: "8"))
        XCTAssertFalse(Screener.passesProfileRisk(
            code: "600003", q: makeQuote(turnover: 7.0), pf: pf, rf: rf,
            stPattern: stRegex, bsePrefix: "8"))

        // 重放标记：checkTurnover=false 跳过换手画像与换手硬上限
        XCTAssertTrue(Screener.passesProfileRisk(
            code: "600003", q: makeQuote(turnover: 25.0), pf: pf, rf: rf,
            stPattern: stRegex, bsePrefix: "8", checkTurnover: false))

        // price_ge_avg 检查与 checkAvgPrice=false 跳过
        let belowAvg = makeQuote(price: 10.0, avgPrice: 10.5)
        XCTAssertFalse(Screener.passesProfileRisk(
            code: "600004", q: belowAvg, pf: pf, rf: rf,
            stPattern: stRegex, bsePrefix: "8", checkAvgPrice: true))
        XCTAssertTrue(Screener.passesProfileRisk(
            code: "600004", q: belowAvg, pf: pf, rf: rf,
            stPattern: stRegex, bsePrefix: "8", checkAvgPrice: false))

        // 振幅上限
        XCTAssertFalse(Screener.passesProfileRisk(
            code: "600005", q: makeQuote(amplitude: 7.5), pf: pf, rf: rf,
            stPattern: stRegex, bsePrefix: "8"))
    }

    // MARK: - screenEtf

    func testScreenEtfFiltersSortsPreservesTiesAndTruncates() {
        let params: [String: Any] = [
            "etf": [
                "change_pct_min": 0.5,
                "volume_ratio_min": 1.0,
                "top_n": 2,
            ]
        ]
        let quotes: [(code: String, quote: EngineQuote)] = [
            ("510300", makeQuote(code: "510300", name: "沪深300", price: 4.0, changePct: 1.5, volumeRatio: 1.2)),
            ("510500", makeQuote(code: "510500", name: "中证500", price: 6.0, changePct: 1.5, volumeRatio: 1.2)),
            ("512100", makeQuote(code: "512100", name: "中证1000", price: 2.5, changePct: 2.1, volumeRatio: 1.3)),
            ("510050", makeQuote(code: "510050", name: "量比不够", price: 3.0, changePct: 3.0, volumeRatio: 0.8)),
            ("588000", makeQuote(code: "588000", name: "停牌无效", price: 0.0, changePct: 2.0, volumeRatio: 1.5)),
        ]
        let out = Screener.screenEtf(params: params, quotes: quotes)
        XCTAssertEqual(out.compactMap { $0["code"] as? String }, ["512100", "510300"],
                       "应按涨幅降序且并列保持输入序，并截断至 top_n")

        var zeroTop = params
        zeroTop["etf"] = ["change_pct_min": 0.5, "volume_ratio_min": 1.0, "top_n": 0]
        XCTAssertTrue(Screener.screenEtf(params: zeroTop, quotes: quotes).isEmpty)
    }

    // MARK: - scoreStock & ScoreAcc & TrendState

    func testScoreStockCoversBonusPenaltyIntradayAndTierLock() {
        let factory = ParamSchema.shared.factoryParams
        let env: [String: Any] = ["sh_ok": true, "ratio_ok": true]

        // 1. 正常多头 + 尾盘特征：触发多头、连涨、5日累计、位置、形态满分、大盘、MA20上翘与尾盘加分
        var metaBull: [String: Any] = [:]
        let intradayGood: [String: Any] = [
            "tail_vol_ratio": 2.0,
            "tail_gain_pct": 0.6,
            "close_position": 0.95,
            "tail_new_high": true,
            "high_age_ratio": 0.2,
            "day_high_time": "14:50",
        ]
        let bull = Screener.scoreStock(
            quote: makeQuote(volumeRatio: 1.6),
            deep: makeDeep(maPass: true, volMult5d: 1.6, consecUp: 2, cum5d: 7.0,
                           distFromLow: 10.0, distFromHigh: -8.0, ma20SlopeUp: true),
            intraday: intradayGood,
            patterns: nil,
            formScore: 3,
            marketEnv: env,
            params: factory,
            meta: &metaBull
        )
        XCTAssertGreaterThan((bull.score as? NSNumber)?.doubleValue ?? 0, 60)
        XCTAssertEqual(metaBull["ma_qualified"] as? Bool, true)
        XCTAssertEqual(metaBull["tier_lock_applied"] as? Bool, false)
        XCTAssertEqual(metaBull["trend_state"] as? String, "BULL_ALIGNED")
        XCTAssertEqual(metaBull["lock_confidence"] as? String, "none")
        XCTAssertTrue(bull.details.contains { $0.hasPrefix("均线多头 +") })
        XCTAssertTrue(bull.details.contains { $0.hasPrefix("尾盘拉升") })
        XCTAssertTrue(bull.details.contains { $0.hasPrefix("收盘强度") })

        // 2. cum5d == nil 不能误拿 le8 加分，且标记 INSUFFICIENT
        var metaInsuf: [String: Any] = [:]
        let insuf = Screener.scoreStock(
            quote: makeQuote(),
            deep: makeDeep(maPass: false, cum5d: nil, ma20SlopeUp: false),
            intraday: nil,
            patterns: nil,
            formScore: 2,
            marketEnv: ["sh_ok": true, "ratio_ok": false],
            params: factory,
            meta: &metaInsuf
        )
        XCTAssertTrue(insuf.details.contains { $0.contains("5日累计数据不足 +0(不参与)") })
        XCTAssertEqual(metaInsuf["trend_state"] as? String, "INSUFFICIENT")

        // 3a. 非多头但高位回踩（原始分超过 tier_lock.max_score）→ 触发 tier_lock 与 MA_PULLBACK / likely_blunt
        var metaLocked: [String: Any] = [:]
        let locked = Screener.scoreStock(
            quote: makeQuote(price: 10.5, volumeRatio: 1.6),
            deep: makeDeep(ma20: 10.0, maPass: false, volMult5d: 1.6, consecUp: 1, cum5d: 5.0,
                           prev1d: 2.0, distFromLow: 8.0, distFromHigh: -6.0,
                           ma20SlopeUp: true, maDeviation: 1.0, gainRatio: 0.8, shadowBodyRatio: 0.3),
            intraday: intradayGood,
            patterns: nil,
            formScore: 3,
            marketEnv: env,
            params: factory,
            meta: &metaLocked
        )
        XCTAssertEqual(metaLocked["tier_lock_applied"] as? Bool, true)
        XCTAssertEqual(metaLocked["trend_state"] as? String, "MA_PULLBACK")
        XCTAssertEqual(metaLocked["lock_confidence"] as? String, "likely_blunt")
        let rawVal = (metaLocked["score_raw"] as? NSNumber)?.doubleValue ?? 0
        let lockedVal = (locked.score as? NSNumber)?.doubleValue ?? 0
        XCTAssertGreaterThan(rawVal, lockedVal)
        XCTAssertTrue(locked.penalties.contains { $0.contains("均线未多头排列") })

        // 3b. BEAR_TREND + 高原始分 → 触发 tier_lock 且 lock_confidence = high
        var metaBearLock: [String: Any] = [:]
        _ = Screener.scoreStock(
            quote: makeQuote(price: 9.5, volumeRatio: 1.6),
            deep: makeDeep(ma20: 10.0, maPass: false, volMult5d: 1.6, consecUp: 1, cum5d: 5.0,
                           prev1d: 2.0, distFromLow: 8.0, distFromHigh: -6.0,
                           ma20SlopeUp: false, maDeviation: 1.0, gainRatio: 0.8, shadowBodyRatio: 0.3),
            intraday: intradayGood,
            patterns: nil,
            formScore: 3,
            marketEnv: env,
            params: factory,
            meta: &metaBearLock
        )
        XCTAssertEqual(metaBearLock["trend_state"] as? String, "BEAR_TREND")
        XCTAssertEqual(metaBearLock["tier_lock_applied"] as? Bool, true)
        XCTAssertEqual(metaBearLock["lock_confidence"] as? String, "high")

        // 3c. 全套扣分项命中（启用 cum_5d_low + 放量滞涨/长上影/前日大涨/缩量/高点陈旧）
        var penParams = factory
        if var sc = penParams["scoring"] as? [String: Any],
           var pen = sc["penalty"] as? [String: Any] {
            pen["cum_5d_low"] = ["threshold": -3.0, "score": -8]
            sc["penalty"] = pen
            penParams["scoring"] = sc
        }
        var metaBear: [String: Any] = [:]
        let bear = Screener.scoreStock(
            quote: makeQuote(price: 9.5, volumeRatio: 2.5),
            deep: makeDeep(ma20: 10.0, maPass: false, volMult5d: 0.4, consecUp: 1, cum5d: -5.0,
                           prev1d: 8.5, distFromLow: 8.0, distFromHigh: -6.0,
                           ma20SlopeUp: false, maDeviation: 6.0, gainRatio: 0.1, shadowBodyRatio: 3.0),
            intraday: ["high_age_ratio": 0.9, "day_high_time": "10:15"],
            patterns: nil,
            formScore: 3,
            marketEnv: env,
            params: penParams,
            meta: &metaBear
        )
        XCTAssertEqual(metaBear["trend_state"] as? String, "BEAR_TREND")
        XCTAssertTrue(bear.penalties.contains { $0.contains("前日涨") })
        XCTAssertTrue(bear.penalties.contains { $0.contains("量能萎缩") })
        XCTAssertTrue(bear.penalties.contains { $0.contains("动能不足") })
        XCTAssertTrue(bear.penalties.contains { $0.contains("放量滞涨") })
        XCTAssertTrue(bear.penalties.contains { $0.contains("放量长上影") })
        XCTAssertTrue(bear.penalties.contains { $0.contains("高点陈旧") })
    }

    func testScoreAccumulatorDistinguishesIntAndDoubleModes() {
        var acc = Screener.ScoreAcc()
        acc.add(NSNumber(value: Int64(20)))
        acc.add(NSNumber(value: Int64(15)))
        XCTAssertTrue(acc.value is Int, "全整数相加应保持 Int 语义")
        XCTAssertEqual(acc.value as? Int, 35)

        acc.add(NSNumber(value: 1.5))
        XCTAssertFalse(acc.value is Int, "混入浮点加项后应升为 Double")
        XCTAssertEqual(acc.value as? Double, 36.5)

        acc.set(NSNumber(value: Int64(54)))
        XCTAssertEqual(acc.value as? Int, 54, "set 整数锁分应恢复 Int 语义")
    }
}
