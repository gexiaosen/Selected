import XCTest
@testable import SelectedCore

/// `Num` 三条语义的回归锁。
///
/// ## 为什么这个文件值得存在
///
/// 数值转换散落全仓取数链路，缺 `isFinite` 守卫时 `Int(inf)` 会 **trap**
/// （不可 catch、整个 App 崩）；把 `0` 当"缺失"折掉则会把「资产负债率 0%」
/// （无负债）显示成"没数据"。
///
/// 这个文件钉三件事：
/// 1. **非有限值不许流到 `Int(...)`** —— 判别性：删掉守卫 → `Int(inf)` **崩**（不是断言失败）
/// 2. **`0` 是有意义的值**，不许被当成"缺失"（本项目里「资产负债率 0%」= 无负债，
///    与"没数据"是**完全不同的结论**）
/// 3. **折 `nil` 与折 `0` 是两种语义**，分别对应 `doubleOrNil` 与 `doubleOrZero`
final class NumTests: XCTestCase {

    // MARK: - intOrNil：最硬的一条（`Int(inf)` 是 trap，不是"奇怪的值"）

    /// **判别性用例**：非有限值必须返回 `nil`，**不许** `Int(inf)`。
    ///
    /// 若哪天有人把守卫改回 `if let d = v as? Double { return Int(d) }`，
    /// **本用例会直接崩**（`Fatal error: Double value cannot be converted to Int`），
    /// 而不是安静地失败。
    func testIntOrNilRejectsNonFiniteInsteadOfTrapping() {
        XCTAssertNil(Num.intOrNil(Double.infinity), "Int(inf) 会 trap —— 必须挡在前面")
        XCTAssertNil(Num.intOrNil(-Double.infinity))
        XCTAssertNil(Num.intOrNil(Double.nan))
        // 从 String 来的 inf（外部数据里 `"inf"` / `"1e400"` 都可能出现）
        XCTAssertNil(Num.intOrNil("inf" as Any))
        XCTAssertNil(Num.intOrNil("1e400" as Any))
    }

    /// 正常值逐字不变（防"顺手把正常值也挡掉了"）。
    func testIntOrNilKeepsNormalValues() {
        XCTAssertEqual(Num.intOrNil(3), 3)
        XCTAssertEqual(Num.intOrNil(3.7), 3, "向零截断")
        XCTAssertEqual(Num.intOrNil(-3.7), -3)
        XCTAssertEqual(Num.intOrNil(0), 0, "0 是有效值，不是缺失")
        XCTAssertEqual(Num.intOrNil(NSNumber(value: 42)), 42)
        XCTAssertNil(Num.intOrNil(nil))
        XCTAssertNil(Num.intOrNil("abc"))
    }

    // MARK: - doubleOrZero：DB 行解码用（缺省 0）

    func testDoubleOrZeroFoldsNonFiniteToZero() {
        XCTAssertEqual(Num.doubleOrZero(Double.infinity), 0)
        XCTAssertEqual(Num.doubleOrZero(Double.nan), 0)
        XCTAssertEqual(Num.doubleOrZero("inf" as Any), 0, "Double(\"inf\") 得 inf → 折 0")
        XCTAssertEqual(Num.doubleOrZero("1e400" as Any), 0)
    }

    func testDoubleOrZeroKeepsNormalValues() {
        XCTAssertEqual(Num.doubleOrZero(10.25), 10.25)
        XCTAssertEqual(Num.doubleOrZero(3), 3.0)
        XCTAssertEqual(Num.doubleOrZero("7.5" as Any), 7.5)
        XCTAssertEqual(Num.doubleOrZero(nil), 0, "缺省 0（这是本函数与 doubleOrNil 的分工）")
        XCTAssertEqual(Num.doubleOrZero("abc" as Any), 0)
    }

    // MARK: - doubleOrNil：外部数据用（缺省 nil，**不折 0**）

    /// **判别性用例**：`0` 必须原样返回 `0`，不许被当成"缺失"。
    ///
    /// 若哪天有人把实现改成 `guard d != 0 else { return nil }`（"0 看起来像没值"），
    /// **只有这条会红** —— 而它会让界面把「资产负债率 0%」（无负债）
    /// 显示成"没数据"，两个结论完全不同。
    func testDoubleOrNilPreservesZero() {
        XCTAssertEqual(Num.doubleOrNil(0), 0, "0 是有意义的值（如资产负债率 0% = 无负债）")
        XCTAssertEqual(Num.doubleOrNil("0" as Any), 0)
        XCTAssertEqual(Num.doubleOrNil(0.0), 0)
    }

    func testDoubleOrNilFoldsNonFiniteToNil() {
        XCTAssertNil(Num.doubleOrNil(Double.infinity))
        XCTAssertNil(Num.doubleOrNil(Double.nan))
        XCTAssertNil(Num.doubleOrNil("inf" as Any))
        XCTAssertNil(Num.doubleOrNil("1e400" as Any))
        XCTAssertNil(Num.doubleOrNil(nil))
        XCTAssertNil(Num.doubleOrNil("abc" as Any))
    }

    func testDoubleOrNilKeepsNormalValues() {
        XCTAssertEqual(Num.doubleOrNil(10.25), 10.25)
        XCTAssertEqual(Num.doubleOrNil(3), 3.0)
        XCTAssertEqual(Num.doubleOrNil("7.5" as Any), 7.5)
        XCTAssertEqual(Num.doubleOrNil(NSNumber(value: 1.5)), 1.5)
    }

    // MARK: - 两条语义的分工（别混用）

    /// `nil` 输入时两条的差别就是它们存在的理由。
    func testTwoSemanticsDifferExactlyOnMissingInput() {
        XCTAssertEqual(Num.doubleOrZero(nil), 0, "行解码：已知该列必有值 → 缺省 0")
        XCTAssertNil(Num.doubleOrNil(nil), "外部数据：源没给 → 必须能区分出来")
    }
}
