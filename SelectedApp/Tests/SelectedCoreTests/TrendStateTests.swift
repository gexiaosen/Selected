import XCTest
@testable import SelectedCore

/// 「指标钝化保护」：趋势状态 / 锁档信心的行为契约。
///
/// 为什么需要这组测试：这两个字段是**纯诊断**（不参与判定），判定类回归
/// **证明不了它们对不对**；而"只加信息"这类改动恰恰最容易出的错是：
/// 分类边界写反、或默认值把"老数据没这个键"与"数据不足"混成一个值。
///
/// 两个方向都要守住：
///   ① 信息必须留存（分类结果要能被读出来）
///   ② 判定必须不变 —— 由判定字段的回归保证，这里不重复
final class TrendStateTests: XCTestCase {

    /// 构造 `DeepInfo`：只暴露本测试关心的三个维度，其余给固定值。
    private func deep(cum5d: Double? = 10.0, maPass: Bool,
                      ma20SlopeUp: Bool, ma20: Double? = 10.0) -> DeepInfo {
        DeepInfo(ma5: 10.5, ma10: 10.2, ma20: ma20, maPass: maPass, volMult5d: 1.5,
                 consecUp: 1, cum5d: cum5d, prev1d: 1.0, distFromLow: 5.0,
                 distFromHigh: -8.0, ma20SlopeUp: ma20SlopeUp, maDeviation: 1.0,
                 gainRatio: 0.8, shadowBodyRatio: 0.3)
    }

    // MARK: - ① 趋势状态五态

    func testBullAligned() {
        XCTAssertEqual(Screener.classifyTrendState(
            deep(maPass: true, ma20SlopeUp: true), price: 10.6), "BULL_ALIGNED")
    }

    func testBullWeakening() {
        // 仍多头排列，但 MA20 走平/下弯 → 与"完整多头"区分开
        XCTAssertEqual(Screener.classifyTrendState(
            deep(maPass: true, ma20SlopeUp: false), price: 10.6), "BULL_WEAKENING")
    }

    func testMaPullback() {
        // 未多头，但 MA20 上翘且现价仍在 MA20 之上 → 上升途中回踩（本项的核心价值）
        XCTAssertEqual(Screener.classifyTrendState(
            deep(maPass: false, ma20SlopeUp: true, ma20: 10.0), price: 10.5), "MA_PULLBACK")
    }

    func testBearTrend() {
        XCTAssertEqual(Screener.classifyTrendState(
            deep(maPass: false, ma20SlopeUp: false), price: 10.5), "BEAR_TREND")
    }

    /// MA20 上翘但**现价已跌破 MA20** → 不是回踩，是走坏。这是 MA_PULLBACK 的反例，
    /// 少了这条断言，一个"只看 ma20SlopeUp"的错误实现也能全绿。
    func testBelowRisingMa20IsBearNotPullback() {
        XCTAssertEqual(Screener.classifyTrendState(
            deep(maPass: false, ma20SlopeUp: true, ma20: 10.0), price: 9.8), "BEAR_TREND")
    }

    /// `ma20` 缺失（K 线极短）时不得崩，且不得误判成回踩
    func testNilMa20IsBearNotPullback() {
        XCTAssertEqual(Screener.classifyTrendState(
            deep(maPass: false, ma20SlopeUp: true, ma20: nil), price: 10.5), "BEAR_TREND")
    }

    /// 数据不足优先于一切：`cum_5d == nil`（K 线不足 6 根）时均线不可信 → INSUFFICIENT
    func testInsufficientWinsOverOtherSignals() {
        XCTAssertEqual(Screener.classifyTrendState(
            deep(cum5d: nil, maPass: true, ma20SlopeUp: true), price: 10.6), "INSUFFICIENT")
        XCTAssertEqual(Screener.classifyTrendState(
            deep(cum5d: nil, maPass: false, ma20SlopeUp: false), price: 9.0), "INSUFFICIENT")
    }

    // MARK: - ② 锁档信心

    /// 未被锁时该字段不适用 —— 必须与"被锁但信心未知"区分
    func testNotLockedIsNoneRegardlessOfTrend() {
        for s in ["BULL_ALIGNED", "BULL_WEAKENING", "MA_PULLBACK", "BEAR_TREND", "INSUFFICIENT"] {
            XCTAssertEqual(Screener.classifyLockConfidence(trendState: s, locked: false), "none",
                           "未锁档时不应给出信心标签（\(s)）")
        }
    }

    func testLockedMapping() {
        // 回踩被锁 = 疑似钝化误伤；明确走坏 = 锁得对；数据不足 = 不猜
        XCTAssertEqual(Screener.classifyLockConfidence(trendState: "MA_PULLBACK", locked: true),
                       "likely_blunt")
        XCTAssertEqual(Screener.classifyLockConfidence(trendState: "BEAR_TREND", locked: true),
                       "high")
        XCTAssertEqual(Screener.classifyLockConfidence(trendState: "INSUFFICIENT", locked: true),
                       "unknown")
        // 理论上锁档只可能发生在 ma_pass 为假时；真出现多头+被锁，也只能是 unknown（不猜）
        XCTAssertEqual(Screener.classifyLockConfidence(trendState: "BULL_ALIGNED", locked: true),
                       "unknown")
    }

    // MARK: - ③ 实体读取：老数据缺键必须与"有值"区分

    func testEntityAccessorsKeepMissingKeyDistinctFromValue() {
        let present = ScanDeepInfo(JSONValue([
            "trend_state": "MA_PULLBACK", "lock_confidence": "likely_blunt",
        ]))
        XCTAssertEqual(present.trendStateOrNil, "MA_PULLBACK")
        XCTAssertEqual(present.lockConfidenceOrNil, "likely_blunt")

        // 更早落库的行没有这两个键 → nil（不是 INSUFFICIENT / none）
        let legacy = ScanDeepInfo(JSONValue(["ma_pass": true]))
        XCTAssertNil(legacy.trendStateOrNil, "老行缺键必须是 nil，不能回落成某个状态值")
        XCTAssertNil(legacy.lockConfidenceOrNil, "老行缺键必须是 nil，不能回落成 none")
    }
}
