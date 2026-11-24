import XCTest
@testable import SelectedCore

/// 反事实覆盖诊断 —— `CounterfactualCoverage` 与 `TuneResult` 上的取值契约
///
/// 针对的缺陷形态是「**假装覆盖了**」：调优的结论只建立在"入档且已评分"的样本上，
/// 而被淘汰的样本从未落库特征、根本进不了评估池 —— 覆盖状况必须可度量、可在界面看见，
/// 不能只靠 `scope_note` 的一句散文。
final class CounterfactualCoverageTests: XCTestCase {

    /// 真实库的 `excluded_stocks` 只有这三列 → 缺 5 个重评分必需的列
    func testMissingColumnsForRealSchema() {
        let real: Set<String> = ["id", "round_id", "date", "slot", "code", "name", "reason"]
        XCTAssertEqual(CounterfactualCoverage.missingColumns(from: real),
                       ["change_pct", "deep_info_json", "score_details_json",
                        "turnover", "volume_ratio"])
    }

    /// 列补齐后 `missingColumns` 必须为空 —— 这条是"判据来自实际列名、不是写死的 0"的证据
    func testMissingColumnsEmptyWhenSchemaHasThem() {
        let full = Set(CounterfactualCoverage.requiredColumns)
        XCTAssertTrue(CounterfactualCoverage.missingColumns(from: full).isEmpty)
    }

    /// 未覆盖：`excluded_rescoreable` 归零、说明里点出缺哪些列与"未并入"
    func testJSONWhenNotCovered() {
        let missing = ["change_pct", "deep_info_json"]
        let d = CounterfactualCoverage.json(excludedInWindow: 26, excludedRescoreable: 0,
                                            poolSize: 7, missingColumns: missing)
        XCTAssertEqual(d["excluded_in_window"] as? Int, 26)
        XCTAssertEqual(d["excluded_rescoreable"] as? Int, 0)
        XCTAssertEqual(d["pool_from_picks"] as? Int, 7)
        XCTAssertEqual(d["covered"] as? Bool, false)
        let note = (d["note"] as? String) ?? ""
        XCTAssertTrue(note.contains("26"), "要写出缺口有多大：\(note)")
        XCTAssertTrue(note.contains("未并入"), "要明说未并入：\(note)")
        XCTAssertTrue(note.contains("change_pct"), "要点出缺哪些列：\(note)")
    }

    /// 已覆盖：说明改成"可并入 N 条"，不再说未并入
    func testJSONWhenCovered() {
        let d = CounterfactualCoverage.json(excludedInWindow: 26, excludedRescoreable: 26,
                                            poolSize: 7, missingColumns: [])
        XCTAssertEqual(d["covered"] as? Bool, true)
        let note = (d["note"] as? String) ?? ""
        XCTAssertFalse(note.contains("未并入"))
        XCTAssertTrue(note.contains("26"))
    }

    // MARK: - 实体取值

    func testTuneResultReadsCounterfactual() {
        let t = TuneResult(JSONValue([
            "status": "ok", "pool_size": 7,
            "counterfactual": [
                "excluded_in_window": 26, "excluded_rescoreable": 0,
                "pool_from_picks": 7, "missing_columns": ["change_pct"],
                "covered": false, "note": "…未并入评估池…",
            ],
        ]))
        XCTAssertNotNil(t.counterfactualOrNil)
        XCTAssertEqual(t.counterfactualExcluded, 26)
        XCTAssertEqual(t.counterfactualRescoreable, 0)
        XCTAssertTrue(t.counterfactualNote.contains("未并入"))
    }

    /// 空池早退 / 老结果 → nil，且各数值退化为 0（不崩、不误报"已覆盖"）
    func testMissingCounterfactualDegradesSafely() {
        let t = TuneResult(JSONValue(["status": "no_data", "error": "历史评估池为空"]))
        XCTAssertNil(t.counterfactualOrNil)
        XCTAssertEqual(t.counterfactualExcluded, 0)
        XCTAssertEqual(t.counterfactualRescoreable, 0)
        XCTAssertEqual(t.counterfactualNote, "")
    }
}
