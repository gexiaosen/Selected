import XCTest
@testable import SelectedCore

/// 样本门槛 —— `SampleGate` 与 `TuneResult` 上的取值契约
///
/// 这一条针对的缺陷形态是"**给了没有依据的结论**"：调优在 7 个样本上算出
/// "候选比基线好 3 分"，界面照样把它当推荐摆出来。所以门槛的判据必须能被断言，
/// 而不是靠一句文案提示。
final class SampleGateTests: XCTestCase {

    // MARK: - 判据

    /// 边界：恰好等于阈值算"够"（`>=`，与 `PhaseTune` 既有 `<30` 告警互补）
    func testThresholdBoundary() {
        XCTAssertFalse(SampleGate.sufficient(samples: 29))
        XCTAssertTrue(SampleGate.sufficient(samples: 30))
        XCTAssertTrue(SampleGate.sufficient(samples: 31))
        XCTAssertTrue(SampleGate.sufficient(samples: 0, threshold: 0))
    }

    /// 写进结果 JSON 的三个键
    func testJSONShape() {
        let ok = SampleGate.json(samples: 100)
        XCTAssertEqual(ok["sufficient"] as? Bool, true)
        XCTAssertEqual(ok["samples"] as? Int, 100)
        XCTAssertEqual(ok["threshold"] as? Int, 30)

        let bad = SampleGate.json(samples: 7, threshold: 50)
        XCTAssertEqual(bad["sufficient"] as? Bool, false)
        XCTAssertEqual(bad["threshold"] as? Int, 50)
    }

    /// 文案：样本够 → 空串（调用方据此不显示提示）；不够 → 带上实际样本数与门槛
    func testMessage() {
        XCTAssertEqual(SampleGate.message(samples: 30), "")
        XCTAssertEqual(SampleGate.message(samples: 300), "")
        let msg = SampleGate.message(samples: 7)
        XCTAssertTrue(msg.contains("7"), "要写清实际样本数：\(msg)")
        XCTAssertTrue(msg.contains("30"), "要写清门槛：\(msg)")
        XCTAssertTrue(msg.contains("不出结论"), "要说清结论被抑制：\(msg)")
    }

    // MARK: - 实体取值

    /// 有判据时按判据走
    func testTuneResultReadsGate() {
        let t = TuneResult(JSONValue([
            "status": "ok", "pool_size": 7,
            "sample_gate": ["sufficient": false, "samples": 7, "threshold": 30],
        ]))
        XCTAssertNotNil(t.sampleGateOrNil)
        XCTAssertFalse(t.sampleSufficient)
        XCTAssertEqual(t.sampleCount, 7)
        XCTAssertEqual(t.sampleThreshold, 30)
        XCTAssertFalse(t.sampleGateMessage.isEmpty)
    }

    /// 没有判据（空池早退 / 老落库的调优结果）时 **必须按"不足"处理** ——
    /// 宁可不给结论，也不把"没判过"当成"样本够"。但**文案给空串**：
    /// 老结果不该凭空多出一条"样本不足"的提示（那是行为变更，不是补信息）。
    func testMissingGateIsTreatedAsInsufficientButSilent() {
        let t = TuneResult(JSONValue(["status": "ok", "pool_size": 7]))
        XCTAssertNil(t.sampleGateOrNil)
        XCTAssertFalse(t.sampleSufficient, "缺判据 → 不敢说样本够")
        XCTAssertEqual(t.sampleCount, 0)
        XCTAssertEqual(t.sampleGateMessage, "", "缺判据 → 不显示提示（避免给老结果凭空加告警）")
    }

    /// 空池早退（`status=no_data`）只产出 `status` + `error` —— 不应崩、也不该有判据
    func testNoDataEarlyReturnHasNoGate() {
        let t = TuneResult(JSONValue(["status": "no_data", "error": "历史评估池为空"]))
        XCTAssertNil(t.sampleGateOrNil)
        XCTAssertFalse(t.sampleSufficient)
    }
}
