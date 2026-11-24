import XCTest
@testable import SelectedCore

/// 全链路记录 vs **真实读取结果**
///
/// 夹具全在 `engine/tests/fixtures/override_history_outputs/`：
/// · `history.json` / `history_review.json` / `history_verify.json` / `history_iterate.json`
///   —— 三个不同的阶段库各一份，覆盖 `predict` / `review` / `verify` / `iterate` 四种非 null 子形态
///   （**没有哪个库同时齐全**，所以要几份）
final class OverrideHistoryEntityTests: XCTestCase {

    private func load(_ name: String) throws -> JSONValue {
        try EntityTestSupport.fixture("engine/tests/fixtures/override_history_outputs/\(name).json")
    }
    private func loadArray(_ name: String) throws -> [JSONValue] { try load(name).array }

    /// 单条记录夹具（文件是 `[ {…} ]`）——**必须取出内层 dict**
    ///
    /// 必须显式断言"取到了一条非空记录"：整个数组塞进 `HistoryRecord` 时
    /// `json.dict` 为空 → `rounds` 空 → 而键覆盖对**空对象会跳过** → 测试会**静默通过**（假绿）。
    private func loadRecord(_ name: String) throws -> JSONValue {
        let rows = try loadArray(name)
        let first = try XCTUnwrap(rows.first, "\(name) 夹具应是含 1 条记录的数组")
        XCTAssertFalse(first.dict.isEmpty, "\(name) 夹具记录不能是空对象（否则键覆盖会静默跳过）")
        return first
    }

    // MARK: - 全链路记录

    /// 五个子对象**各自可能为 null** —— 这是这个实体的核心形状
    func testHistoryCoversExactlyAndRoundTrips() throws {
        for name in ["history", "history_review", "history_verify", "history_iterate"] {
            let h = HistoryRecord(try loadRecord(name))
            try EntityTestSupport.check(HistoryRecord.self, h.json, "\(name)")
            for (i, r) in h.rounds.enumerated() {
                try EntityTestSupport.check(HistoryRoundRow.self, r.json, "\(name).rounds[\(i)]")
            }
            if let v = h.verify { try EntityTestSupport.check(HistoryVerifyRow.self, v.json, "\(name).verify") }
            if let r = h.review { try EntityTestSupport.check(HistoryReviewRow.self, r.json, "\(name).review") }
            if let it = h.iterate { try EntityTestSupport.check(HistoryIterateRow.self, it.json, "\(name).iterate") }
            if let p = h.predict { try EntityTestSupport.check(PredictResult.self, p.json, "\(name).predict") }
        }
    }

    func testHistoryTypedValues() throws {
        let h = HistoryRecord(try loadRecord("history_review"))
        XCTAssertEqual(h.date, "2026-09-11")
        XCTAssertFalse(h.rounds.isEmpty)
        XCTAssertTrue(h.exists("predict"))
        XCTAssertTrue(h.exists("review"))
        XCTAssertFalse(h.exists("compare"), "该库没有 compare_reports")
        XCTAssertFalse(h.exists("verify"))
        XCTAssertFalse(h.exists("iterate"))

        let p = try XCTUnwrap(h.predict, "predict 应解出来")
        XCTAssertEqual(p.status, "ok")
        XCTAssertFalse(p.stocks.isEmpty, "history 里的 predict 带完整标的")

        let r = try XCTUnwrap(h.review)
        XCTAssertFalse(r.reviewTime.isEmpty)
        XCTAssertTrue(r.hasRun)
        XCTAssertEqual(r.selDate, "2026-09-11")
        // `four_layer` 与 ReviewFourLayer 同构
        XCTAssertNotEqual(r.fourLayer.window.total, 0, "有样本的复盘日 total 应 > 0")

        XCTAssertNil(h.verify)
        XCTAssertNil(h.iterate)
        XCTAssertNil(h.compare)
    }

    func testHistoryVerifyAndIterateShapes() throws {
        let v = HistoryRecord(try loadRecord("history_verify"))
        let vv = try XCTUnwrap(v.verify, "verify 子对象应解出来")
        XCTAssertFalse(vv.verifyTime.isEmpty)
        XCTAssertTrue(vv.hasRun)
        XCTAssertFalse(v.exists("review"))

        let it = HistoryRecord(try loadRecord("history_iterate"))
        let iv = try XCTUnwrap(it.iterate, "iterate 子对象应解出来")
        XCTAssertFalse(iv.triggerDate.isEmpty)
        XCTAssertFalse(iv.insights.isEmpty)
        XCTAssertTrue(it.exists("review"), "该库同时有 review")
    }

    /// `history.rounds` 与 `todayRounds` 是**同一张表的两条读路径**，形状不同 —— 别混用
    func testHistoryRoundRowIsNotTheSameShapeAsRoundSummaryRow() throws {
        let h = HistoryRecord(try loadRecord("history"))
        let r = try XCTUnwrap(h.rounds.first)
        XCTAssertFalse(r.runTime.isEmpty)
        XCTAssertFalse(r.slotLabel.isEmpty)
        XCTAssertGreaterThan(r.tier1Count, 0)
        // 口径：去掉 "2026-09-21 " 这 11 个字符 → 得到 **"14:50:00"**（带秒），不是 "14:50"。
        //   实体逐字复刻该口径。
        XCTAssertEqual(r.runTimeClock, "14:50:00")
        XCTAssertNotEqual(HistoryRoundRow.declaredKeys, RoundSummaryRow.declaredKeys,
                          "两条读路径形状不同（history 少 round_id/param_version/market_env）")
    }

    /// `compare` 子对象复用 `CompareReport` —— 用**真实的** compare 报告注入验证
    func testHistoryCompareReusesCompareReport() throws {
        let real = try EntityTestSupport.fixture("engine/tests/fixtures/compare_outputs/full.json")
        let h = HistoryRecord(JSONValue(["date": "2026-09-14", "rounds": [Any](), "compare": real.raw]))
        let c = try XCTUnwrap(h.compare, "compare 应解出来")
        XCTAssertTrue(c.isOK)
        XCTAssertFalse(c.tier1Matrix.isEmpty)
        XCTAssertEqual(c.date, "2026-09-14")
        try EntityTestSupport.assertLossless(h, h.json, "history-with-compare")
    }

    func testMissingKeysFallBackWithoutCrash() throws {
        let empty = HistoryRecord(JSONValue([:]))
        XCTAssertEqual(empty.dateDash, "-")
        XCTAssertTrue(empty.rounds.isEmpty)
        XCTAssertNil(empty.predict)
        XCTAssertNil(empty.compare)
        XCTAssertNil(empty.verify)
        XCTAssertNil(empty.review)
        XCTAssertNil(empty.iterate)
        XCTAssertFalse(empty.exists("predict"))
        try EntityTestSupport.assertLossless(empty, JSONValue([:]), "history-empty")
    }
}
