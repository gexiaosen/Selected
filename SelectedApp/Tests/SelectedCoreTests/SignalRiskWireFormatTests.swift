import XCTest
@testable import SelectedCore

/// 两个"取值收成枚举"的字段的**线上格式钉死**：
/// `signal_type`（`SignalType`）与 `risk_level`（`RiskLevel`）。
///
/// 为什么单独一个文件、且**不带 `XCTSkipUnless`**：
/// 这两个字段都是落库 / 进 JSON 的线上格式（`signals.<code>.signal_type` /
/// `compare_store` 的 `signal_classes.signal_type` / `watch_judgments.risk_level` /
/// 各阶段 JSON 的 `risk_level`），rawValue 动一个字节就是**静默破坏存量数据**。
/// 钉死它们必须**无条件跑**，不能被"参数元数据读不到就跳过"这类前置条件挡掉
/// （同类的灯级钉死在 `MarketEnvTests.testMarketLightLevelWireFormatIsFrozen`）。
final class SignalRiskWireFormatTests: XCTestCase {

    // MARK: - signal_type

    /// **强度序**：最强 → 持续 → 脉冲 → **未验证排最后**。
    ///
    /// 用途：三轮对比的「逐标的轨迹」按它排行（按**代码**排会把重点股票散在几百行里）。
    /// `unverified` 不是"弱信号"而是"**没结论**"（轮次不足）—— 必须排在脉冲**之后**，
    ///   否则"重点股票"列表里会混进一批没验证的。这条断言就是钉这个语义。
    func testSignalTypeRankPutsUnverifiedLast() {
        XCTAssertEqual(SignalType.strongest.rank, 0)
        XCTAssertEqual(SignalType.consensus.rank, 1)
        XCTAssertEqual(SignalType.pulse.rank, 2)
        XCTAssertEqual(SignalType.unverified.rank, 3)
        XCTAssertTrue(SignalType.allCases.map(\.rank) == [0, 1, 2, 3],
                      "rank 必须与声明顺序一致且互不相同（改了枚举顺序就会红）")
    }

    /// 线上值是**英文代号**，展示名单独一层
    func testSignalTypeWireFormatIsFrozen() {
        XCTAssertEqual(SignalType.strongest.rawValue, "strongest")
        XCTAssertEqual(SignalType.consensus.rawValue, "consensus")
        XCTAssertEqual(SignalType.pulse.rawValue, "pulse")
        XCTAssertEqual(SignalType.unverified.rawValue, "unverified")
        // 新增档位必须同时决定线上格式（读取侧不认识的值会让匹配红）
        XCTAssertEqual(SignalType.allCases.count, 4)

        // 展示名 = `signal_type_name` 的落库值
        XCTAssertEqual(SignalType.strongest.displayName, "最强信号")
        XCTAssertEqual(SignalType.consensus.displayName, "持续信号")
        XCTAssertEqual(SignalType.pulse.displayName, "脉冲信号")
        XCTAssertEqual(SignalType.unverified.displayName, "未验证（轮次不足）")

        for t in SignalType.allCases {
            XCTAssertEqual(SignalType(json: t.rawValue), t)
            XCTAssertEqual(SignalType(rawValue: t.rawValue), t)
        }
        // 缺失 / 空串 / 未识别 / 非字符串 → nil（各调用点据此保留自己的空串语义：
        // 多数落"非持续"，预判排序的 `?? 9` 兜底落最后）
        XCTAssertNil(SignalType(json: ""))
        XCTAssertNil(SignalType(json: "持续"))
        XCTAssertNil(SignalType(json: nil))
        XCTAssertNil(SignalType(json: 1))
    }

    /// 「已确认持续」的定义 ——
    /// 它决定 consensus / pulse 分组与策略分支，改错会让胜率统计口径静默偏移
    func testVerifiedSignalTypesAreFrozen() {
        XCTAssertEqual(SignalType.verified, [.strongest, .consensus])
        XCTAssertTrue(SignalType.strongest.isVerified)
        XCTAssertTrue(SignalType.consensus.isVerified)
        XCTAssertFalse(SignalType.pulse.isVerified)
        XCTAssertFalse(SignalType.unverified.isVerified, "未验证（轮次不足）绝不能被算作持续")
        // 空串/未识别（nil）在调用点一律落"非持续"
        XCTAssertNil(SignalType(json: ""))
    }

    // MARK: - risk_level

    /// 线上值是**中文原值**（参数表 `strategies.*.risk` 的取值）。
    /// `allCases` 的顺序同时是参数表下拉选项的顺序 —— 展示依赖它，故一并钉死
    func testRiskLevelWireFormatIsFrozen() {
        XCTAssertEqual(RiskLevel.allCases.map(\.rawValue), ["低", "中", "高", "极高"])
        XCTAssertEqual(RiskLevel.low.rawValue, "低")
        XCTAssertEqual(RiskLevel.medium.rawValue, "中")
        XCTAssertEqual(RiskLevel.high.rawValue, "高")
        XCTAssertEqual(RiskLevel.extreme.rawValue, "极高")

        for r in RiskLevel.allCases {
            XCTAssertEqual(RiskLevel(json: r.rawValue), r)
            XCTAssertEqual(RiskLevel(rawValue: r.rawValue), r)
        }
        // 缺失 / 空串 / 未识别 / 非字符串 → nil（配色落次级、复盘不加分）
        XCTAssertNil(RiskLevel(json: ""))
        XCTAssertNil(RiskLevel(json: "未知"))
        XCTAssertNil(RiskLevel(json: nil))
        XCTAssertNil(RiskLevel(json: 1))
    }
}