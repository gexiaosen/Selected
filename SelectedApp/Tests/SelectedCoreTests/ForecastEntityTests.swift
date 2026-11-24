import XCTest
@testable import SelectedCore

/// 预报实体 vs **黄金夹具（真实引擎产出）**
///
/// 夹具 `engine/tests/fixtures/forecast_outputs/*.json`，手工捕获、不可再生：
/// `normal`（正常，16 键）/ `warned`（带涨跌停提示，17 键）/ `early`（日K不足早退，7 键）。
final class ForecastEntityTests: XCTestCase {

    private func load(_ name: String) throws -> JSONValue {
        try EntityTestSupport.fixture("engine/tests/fixtures/forecast_outputs/\(name).json")
    }

    private func checkAll(_ r: ForecastResult, _ label: String) throws {
        try EntityTestSupport.check(ForecastResult.self, r.json, label)
        try EntityTestSupport.check(ForecastParams.self, r.params.json, "\(label).params")
        if let b = r.baseline {
            try EntityTestSupport.check(ForecastBaseline.self, b.json, "\(label).baseline")
            try EntityTestSupport.check(ForecastBand.self, b.highPct.json, "\(label).baseline.high_pct")
            try EntityTestSupport.check(ForecastBand.self, b.lowPct.json, "\(label).baseline.low_pct")
        }
        if let rec = r.recent {
            try EntityTestSupport.check(ForecastRecent.self, rec.json, "\(label).recent")
        }
        if let bt = r.backtest {
            try EntityTestSupport.check(ForecastBacktest.self, bt.json, "\(label).backtest")
        }
    }

    func testNormalCoversExactlyAndRoundTrips() throws {
        try checkAll(ForecastResult(try load("normal")), "normal")
    }

    func testWarnedCoversExactlyAndRoundTrips() throws {
        try checkAll(ForecastResult(try load("warned")), "warned")
    }

    func testEarlyCoversExactlyAndRoundTrips() throws {
        try checkAll(ForecastResult(try load("early")), "early")
    }

    // MARK: - 类型化取值

    func testNormalTypedValues() throws {
        let r = ForecastResult(try load("normal"))
        XCTAssertEqual(r.code, "000001")
        XCTAssertEqual(r.name, "平安银行")
        XCTAssertEqual(r.status, "ok")
        XCTAssertTrue(r.isOK)
        XCTAssertTrue(r.adjusted)
        XCTAssertEqual(r.asOf, "2026-09-18")
        XCTAssertEqual(r.baseClose, 11.7)
        XCTAssertEqual(r.highCentral, 11.83)
        XCTAssertEqual(r.lowCentral, 11.61)
        XCTAssertGreaterThan(r.highOptimistic, r.highCentral)
        XCTAssertLessThan(r.lowOptimistic, r.lowCentral)
        XCTAssertGreaterThan(r.expectedRangePct, 0)
        XCTAssertEqual(r.caveats.count, 3, "口径说明（不是错误信息）")
        XCTAssertTrue(r.warnings.isEmpty, "normal 夹具无涨跌停提示")
        XCTAssertEqual(r.dataError, "")

        XCTAssertEqual(r.params.baseDays, 30)
        XCTAssertEqual(r.params.recentDays, 3)
        XCTAssertEqual(r.params.testDays, 30)

        let b = try XCTUnwrap(r.baseline)
        XCTAssertEqual(b.days, 30)
        XCTAssertEqual(b.avgRangePct, 1.53)
        XCTAssertEqual(b.atrPct, b.avgRangePct, "atr_pct 是 avg_range_pct 的**同口径别名**")
        XCTAssertEqual(b.closeUpRatio, 0.5)
        XCTAssertEqual(b.maxRangePct, 2.65)
        XCTAssertLessThan(b.highPct.p25, b.highPct.p50)
        XCTAssertLessThan(b.highPct.p50, b.highPct.p75)
        XCTAssertLessThan(b.lowPct.p25, b.lowPct.p50)

        let rec = try XCTUnwrap(r.recent)
        XCTAssertEqual(rec.days, 3)
        XCTAssertEqual(rec.k, 1.3)
        XCTAssertEqual(rec.kRaw, 1.3)
        XCTAssertFalse(rec.kClamped)
        XCTAssertEqual(rec.streak, 1)
        XCTAssertEqual(rec.volMult, 0.91)
        XCTAssertEqual(rec.note, "", "正常分支**不带** note（P2-16）")

        let bt = try XCTUnwrap(r.backtest)
        XCTAssertEqual(bt.n, 30)
        XCTAssertEqual(bt.highWithinUpper, 0.633)
        XCTAssertEqual(bt.lowAboveLower, 0.8)
        XCTAssertEqual(bt.bothCovered, 0.433)
        XCTAssertEqual(bt.highInBand, 0.133)
        XCTAssertEqual(bt.lowInBand, 0.333)
        XCTAssertEqual(bt.highMedianErrPct, 0.53)
        XCTAssertEqual(bt.lowMedianErrPct, 0.18)
        XCTAssertEqual(bt.note, "", "正常分支**不带** note（P2-16）")
    }

    func testWarnedExposesWarnings() throws {
        let r = ForecastResult(try load("warned"))
        XCTAssertTrue(r.isOK)
        XCTAssertFalse(r.warnings.isEmpty, "涨跌停提示应能读到")
        XCTAssertNotNil(r.baseline)
        XCTAssertNotNil(r.backtest)
    }

    func testEarlyReturnDegradesSafely() throws {
        let r = ForecastResult(try load("early"))
        XCTAssertEqual(r.status, "insufficient_data")
        XCTAssertFalse(r.isOK)
        XCTAssertFalse(r.dataError.isEmpty, "早退必须带 data_error")
        XCTAssertEqual(r.asOf, "", "早退没有 as_of")
        XCTAssertNil(r.baseline, "早退没有基线")
        XCTAssertNil(r.recent)
        XCTAssertNil(r.backtest)
        XCTAssertEqual(r.baseClose, 0)
        XCTAssertFalse(r.caveats.isEmpty, "早退也带口径说明")
        XCTAssertEqual(r.params.baseDays, 30, "早退仍带参数")
    }

    // MARK: - 回归锁：键集必须与生产者的分支逐键一致

    /// 正常分支 **7 键、不带 `note`**；早退分支 **只 3 键** —— 未设置的键不许写成 `null`。
    func testRecentKeySetMatchesPythonBranches() throws {
        let normal = try XCTUnwrap(ForecastResult(try load("normal")).recent)
        XCTAssertEqual(Set(normal.json.dict.keys),
                       ["days", "avg_range_pct", "k_raw", "k", "k_clamped", "streak", "vol_mult"],
                       "正常分支必须 7 键且不含 note（P2-16）")

        // 早退形态：用构造数据钉死（真实夹具里 normal 走不到 noSamples）
        var s = ForecastEngine.RecentState()
        s.shape = .noSamples
        s.note = "近期无样本，按基线原样输出"
        XCTAssertEqual(Set(s.json.keys), ["days", "k", "note"],
                       "早退分支必须只 3 键（P2-16）")
        XCTAssertEqual(s.json["days"] as? Int, 0)
        XCTAssertEqual(s.json["k"] as? Double, 1.0)
    }

    /// `vol_mult` 在正常分支**总是设键**（`base_vol` 为 0 时是 `null`）—— 不能省略
    func testRecentAlwaysEmitsVolMultInNormalShape() {
        var s = ForecastEngine.RecentState()
        s.shape = .normal
        s.days = 3
        s.k = 1.0
        s.avgRangePct = 1.0
        s.kRaw = 1.0
        s.kClamped = false
        s.streak = 0
        s.volMult = nil                       // base_vol 为 0
        XCTAssertTrue(s.json.keys.contains("vol_mult"), "键必须在，值可以是 null")
        XCTAssertTrue(s.json["vol_mult"] is NSNull)
    }

    /// 早退只 **2 键** —— 统计量为 nil 时不许写 `null` 凑成 9 键。
    func testBacktestKeySetMatchesPythonBranches() throws {
        let normal = try XCTUnwrap(ForecastResult(try load("normal")).backtest)
        XCTAssertEqual(Set(normal.json.dict.keys),
                       ["n", "high_within_upper", "low_above_lower", "both_covered",
                        "high_in_band", "low_in_band", "high_median_err_pct", "low_median_err_pct"],
                       "正常分支必须 8 键且不含 note（P2-16）")

        // 早退形态：真实夹具里 normal 走不到，用引擎实际调一次（K 线不足）
        let short = ForecastEngine.backtest([], baseDays: 30, recentDays: 3, testDays: 30)
        XCTAssertEqual(Set(short.json.keys), ["n", "note"], "早退分支必须只 2 键（P2-16）")
        XCTAssertEqual(short.json["n"] as? Int, 0)
        XCTAssertNotNil(short.json["note"])
    }

    // MARK: - 缺键退化

    func testEmptyResultFallsBackWithoutCrash() throws {
        let r = ForecastResult(JSONValue([:]))
        XCTAssertEqual(r.status, "")
        XCTAssertFalse(r.isOK)
        XCTAssertNil(r.baseline)
        XCTAssertNil(r.recent)
        XCTAssertNil(r.backtest)
        XCTAssertTrue(r.caveats.isEmpty)
        XCTAssertTrue(r.warnings.isEmpty)
        try EntityTestSupport.assertLossless(r, r.json, "forecast-empty")
    }

    /// `note` / `vol_mult` 的"没有"要能区分
    func testNullableFieldsKeepNullDistinct() {
        XCTAssertNil(ForecastRecent(JSONValue(["vol_mult": NSNull()])).volMult)
        XCTAssertEqual(ForecastRecent(JSONValue(["vol_mult": 0])).volMult, 0)
        XCTAssertNil(ForecastRecent(JSONValue([:])).volMult)
        XCTAssertEqual(ForecastRecent(JSONValue(["note": "x"])).note, "x")
        XCTAssertEqual(ForecastRecent(JSONValue([:])).noteDash, "-")
    }

    func testPredictFromZeroCloseReturnsNilAndErrorMessageMatchesThreshold() {
        var bars = (1...32).map { i in
            KLineBar(day: String(format: "2026-01-%02d", i),
                     open: 10, high: 10.5, low: 9.8, close: 10.2, volume: 1000)
        }
        bars[bars.count - 1] = KLineBar(day: "2026-02-01",
                                        open: 10, high: 10.5, low: 9.8, close: 0, volume: 1000)
        XCTAssertNil(ForecastEngine.predictFrom(bars, baseDays: 30, recentDays: 3),
                     "末根收盘价为 0 时不得除零产生 NaN/Inf")

        let shortOut = ForecastEngine.forecast(code: "600000", bars: Array(bars.prefix(10)), baseDays: 30)
        let msg = (shortOut["data_error"] as? String) ?? ""
        XCTAssertTrue(msg.contains("基线 30 + 2"), "不足提示应写基线 + 2：实得 \(msg)")
    }
}
