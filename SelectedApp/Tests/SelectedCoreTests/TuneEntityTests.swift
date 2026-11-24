import XCTest
@testable import SelectedCore

/// 调优实体 vs **真实引擎输出**
///
/// 夹具是 `engine/tests/fixtures/tune_outputs/{global,nodata}.json` ——
/// Swift 真实产出、手工捕获、不可再生：
/// `global`（全局）/ `nodata`（**空池早退，只 2 键**）。
final class TuneEntityTests: XCTestCase {

    private func load(_ name: String) throws -> JSONValue {
        try EntityTestSupport.fixture("engine/tests/fixtures/tune_outputs/\(name).json")
    }

    private func checkAll(_ r: TuneResult, _ label: String) throws {
        try EntityTestSupport.check(TuneResult.self, r.json, label)
        if r.isOK {
            try EntityTestSupport.check(TuneBaseline.self, r.baseline.json, "\(label).baseline")
            try EntityTestSupport.check(TuneMetrics.self, r.baseline.metrics.json, "\(label).baseline.metrics")
            try EntityTestSupport.check(TuneTierStats.self, r.baseline.metrics.tier1.json,
                                        "\(label).baseline.metrics.tier1")
            try EntityTestSupport.check(TuneTierStats.self, r.baseline.metrics.tier2.json,
                                        "\(label).baseline.metrics.tier2")
            for (name, m) in r.baseline.metrics.byMetric {
                try EntityTestSupport.check(TuneMetricStat.self, m.json, "\(label).by_metric[\(name)]")
            }
            for (i, s) in r.baseline.metrics.perStock.enumerated() {
                try EntityTestSupport.check(TunePerStockRow.self, s.json, "\(label).per_stock[\(i)]")
            }
            for (i, c) in r.candidates.enumerated() {
                try EntityTestSupport.check(TuneCandidate.self, c.json, "\(label).candidates[\(i)]")
                try EntityTestSupport.check(TuneBacktest.self, c.backtest.json, "\(label).cand[\(i)].backtest")
                try EntityTestSupport.check(TuneBacktestSummary.self, c.backtest.summary.json,
                                            "\(label).cand[\(i)].summary")
                try EntityTestSupport.check(TuneSideStats.self, c.backtest.summary.old.json,
                                            "\(label).cand[\(i)].summary.old")
                try EntityTestSupport.check(TuneSideStats.self, c.backtest.summary.new.json,
                                            "\(label).cand[\(i)].summary.new")
                for (j, row) in c.backtest.rows.enumerated() {
                    try EntityTestSupport.check(TuneBacktestRow.self, row.json, "\(label).cand[\(i)].rows[\(j)]")
                }
            }
        }
    }

    func testGlobalCoversExactlyAndRoundTrips() throws { try checkAll(TuneResult(try load("global")), "global") }

    /// 空池（`status = no_data`）**只输出 2 键**：`status` + `error`
    func testNoDataShapeIsCovered() throws {
        let r = TuneResult(try load("nodata"))
        try EntityTestSupport.check(TuneResult.self, r.json, "nodata")
        XCTAssertEqual(r.status, "no_data")
        XCTAssertFalse(r.isOK)
        XCTAssertFalse(r.error.isEmpty, "空池必须给出原因（空池是**有效结论**，不是错误）")
        XCTAssertFalse(r.errorDash.isEmpty)
        // 正常分支的字段全部缺席 → 回默认
        XCTAssertTrue(r.dims.isEmpty)
        XCTAssertEqual(r.poolSize, 0)
        XCTAssertTrue(r.candidates.isEmpty)
        XCTAssertEqual(r.baseline.metrics.total, 0)
        XCTAssertNil(r.poolWindowOrNil)
    }

    func testGlobalTypedValues() throws {
        let r = TuneResult(try load("global"))
        XCTAssertEqual(r.status, "ok")
        XCTAssertTrue(r.isOK)
        XCTAssertGreaterThan(r.poolSize, 0)
        XCTAssertGreaterThan(r.poolDates, 0)
        XCTAssertFalse(r.poolWindow.isEmpty)
        XCTAssertNotNil(r.poolWindowOrNil)
        XCTAssertEqual(r.dims.count, 21, "评分类调优维度 21 项")
        XCTAssertTrue(r.dims.allSatisfy { $0.hasPrefix("scoring.") })
        XCTAssertFalse(r.metric.isEmpty)
        XCTAssertFalse(r.metricLabel.isEmpty)
        XCTAssertFalse(r.warning.isEmpty, "样本少时应给出统计意义提示")
        XCTAssertFalse(r.labelSources.isEmpty, "label_sources 是**按来源名**的动态键")
        XCTAssertTrue(r.labelSources.keys.contains("outcomes"))

        // 逐字段断言取值（键覆盖/无损往返验不了"取值口径"）
        let m = r.baseline.metrics
        XCTAssertEqual(m.metric, r.metric)
        XCTAssertGreaterThan(m.poolSize, 0)
        XCTAssertGreaterThan(m.validSize, 0)
        XCTAssertGreaterThan(m.total, 0)
        XCTAssertEqual(m.metricFallback, 0, "本夹具没有标签回退")
        XCTAssertEqual(m.scoreErrors, 0)
        XCTAssertFalse(m.byMetric.isEmpty, "by_metric 的键是**口径名**（动态键）")
        XCTAssertTrue(m.byMetric.keys.contains(m.metric), "实际口径应在 by_metric 里")
        let stat = try XCTUnwrap(m.byMetric[m.metric])
        XCTAssertFalse(stat.label.isEmpty)
        XCTAssertGreaterThan(stat.tier1N, 0)
        XCTAssertEqual(m.tier1.n, m.tier1.wins + (m.tier1.n - m.tier1.wins), "n = wins + 其余")
        XCTAssertGreaterThan(m.tier1.n, 0)
        XCTAssertFalse(m.perStock.isEmpty)
        XCTAssertEqual(m.perStock.count, m.poolSize, "per_stock 条数应等于池大小")

        let ps = try XCTUnwrap(m.perStock.first)
        XCTAssertFalse(ps.code.isEmpty)
        XCTAssertFalse(ps.date.isEmpty)
        XCTAssertGreaterThanOrEqual(ps.tier, 1)

        // 候选：diff 的键是**参数点路径**
        let c = try XCTUnwrap(r.candidates.first)
        XCTAssertGreaterThan(c.diffCount, 0)
        XCTAssertTrue(c.diff.keys.allSatisfy { $0.contains(".") }, "diff 键是点路径")
        XCTAssertFalse(c.metrics.metric.isEmpty)

        let bt = c.backtest
        XCTAssertFalse(bt.rows.isEmpty)
        let row = try XCTUnwrap(bt.rows.first)
        XCTAssertFalse(row.code.isEmpty)
        XCTAssertFalse(row.change.isEmpty)
        XCTAssertGreaterThan(row.oldScore, 0)
        XCTAssertGreaterThan(row.newScore, 0)
        XCTAssertGreaterThanOrEqual(row.oldTier, 1)
        XCTAssertGreaterThanOrEqual(row.newTier, 1)

        let s = bt.summary
        XCTAssertGreaterThan(s.old.total, 0)
        XCTAssertGreaterThan(s.new.total, 0)
        XCTAssertEqual(s.totalDelta, s.new.total - s.old.total, accuracy: 1e-9,
                       "total_delta 应等于 new − old")
        XCTAssertGreaterThan(s.old.tier1.n, 0)
    }

    func testMissingKeysFallBackWithoutCrash() throws {
        let empty = TuneResult(JSONValue([:]))
        XCTAssertEqual(empty.status, "")
        XCTAssertFalse(empty.isOK)
        XCTAssertEqual(empty.errorDash, "-")
        XCTAssertEqual(empty.warningDash, "-")
        XCTAssertTrue(empty.dims.isEmpty)
        XCTAssertTrue(empty.candidates.isEmpty)
        XCTAssertTrue(empty.labelSources.isEmpty)
        XCTAssertEqual(empty.baseline.metrics.total, 0)
        XCTAssertEqual(empty.baseline.metrics.byMetric.count, 0)
        try EntityTestSupport.assertLossless(empty, JSONValue([:]), "tune-empty")
    }

    // MARK: - 参数时代诊断（Swift-only）

    /// 键是**版本名**（动态），值是样本数 —— 与 `labelSources` 同形态
    func testParamErasReadsDynamicKeys() {
        let t = TuneResult(JSONValue([
            "status": "ok",
            "param_eras": ["backtest-1.2.0": 5, "backtest-1.3.0": 2, "(未记录)": 1],
            "param_era_warning": "⚠ 跨了 3 个版本",
        ]))
        XCTAssertEqual(t.paramEraCount, 3)
        XCTAssertEqual(t.paramEras["backtest-1.2.0"], 5)
        XCTAssertEqual(t.paramEras["(未记录)"], 1)
        XCTAssertFalse(t.paramEraWarning.isEmpty)
    }

    /// 单版本窗口：`paramEraCount == 1`（UI 据此不显示"混合时代"），且没有告警键
    func testSingleEraHasNoWarning() {
        let t = TuneResult(JSONValue([
            "status": "ok", "param_eras": ["backtest-1.3.0": 7],
        ]))
        XCTAssertEqual(t.paramEraCount, 1)
        XCTAssertEqual(t.paramEraWarning, "")
    }

    /// 空池早退 / 老结果 → 空字典、0、空串（不崩、不误报"混了时代"）
    func testMissingParamErasDegradesSafely() {
        let t = TuneResult(JSONValue(["status": "no_data", "error": "历史评估池为空"]))
        XCTAssertTrue(t.paramEras.isEmpty)
        XCTAssertEqual(t.paramEraCount, 0)
        XCTAssertEqual(t.paramEraWarning, "")
    }
}
