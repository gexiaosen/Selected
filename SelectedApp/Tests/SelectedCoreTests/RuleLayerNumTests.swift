import Foundation
import Testing
@testable import SelectedCore

/// 规则层取数口径的回归锁。
///
/// ## 为什么这个文件值得存在
///
/// `PredictRules.num` 与 `ScanRunner.num` 都委托 `Num.doubleOrNilKeepingNonFinite`，
/// 本文件把它的语义逐条钉住，防的是"下次有人顺手把它并进 `Num.doubleOrNil`"：
/// 那会把**保留 `inf`** 改成**折 `nil`**（边界行为变更，两者合计 40+ 调用点
/// 在打分/预判/迭代路径）。
struct RuleLayerNumTests {

    /// 与 `Num.doubleOrNil` 的**唯一**差别：非有限值保留，不折 `nil`。
    /// 这条是"判别性"用例：若哪天有人把委托改成 `Num.doubleOrNil`，**只有它 + 上面那条会红**。
    @Test("非有限值保留（与 Num.doubleOrNil 的差别就在这一条）")
    func keepsNonFinite() {
        #expect(PredictRules.num(Double.infinity) == Double.infinity)
        #expect(ScanRunner.num(Double.infinity) == Double.infinity)
        #expect(ScanRunner.num(-Double.infinity) == -Double.infinity)
        // 从 String 来的 inf（外部数据里 "inf" / "1e400" 都可能出现）
        #expect(PredictRules.num("inf" as Any) == Double.infinity)
        #expect(ScanRunner.num("1e400" as Any) == Double.infinity)
        // 对照：标准口径折 nil
        #expect(Num.doubleOrNil(Double.infinity) == nil)
    }

    /// `Bool` → 1/0 —— 与 `Screener.numPy`（Bool 不算数）相反。
    @Test("Bool 折算为 1 / 0")
    func boolFoldsToOneZero() {
        #expect(PredictRules.num(true) == 1)
        #expect(PredictRules.num(false) == 0)
        #expect(ScanRunner.num(true as Any) == 1)
        #expect(ScanRunner.num(false as Any) == 0)
        #expect(NSNumber(value: true) as Any is NSNumber, "前提：Bool 会桥接成 NSNumber（CFBoolean）")
    }

    @Test("字符串数字可解析，非数字串得 nil")
    func parsesNumericStrings() {
        #expect(PredictRules.num("12.5" as Any) == 12.5)
        #expect(ScanRunner.num("-3" as Any) == -3)
        #expect(PredictRules.num("abc" as Any) == nil)
        #expect(ScanRunner.num("" as Any) == nil)
    }

    @Test("数字类型原样取数（Int / Double / NSNumber）")
    func keepsNumericTypes() {
        #expect(PredictRules.num(7) == 7)
        #expect(PredictRules.num(7.25) == 7.25)
        #expect(PredictRules.num(NSNumber(value: 1.5)) == 1.5)
        #expect(ScanRunner.num(-2) == -2)
    }

    @Test("缺失即 nil（nil / NSNull 都算缺失）")
    func missingYieldsNil() {
        #expect(PredictRules.num(nil) == nil)
        #expect(PredictRules.num(NSNull()) == nil)
        #expect(ScanRunner.num(nil) == nil)
        #expect(ScanRunner.num(NSNull()) == nil)
        // 不可转换的类型（数组/字典）→ nil，不崩
        #expect(PredictRules.num([1, 2]) == nil)
        #expect(ScanRunner.num(["a": 1]) == nil)
    }

    /// 两条委托者必须与共享实现**逐点一致**（防"只改了一处"）。
    @Test("两条旧实现与共享实现逐点一致")
    func delegatesAgreeWithShared() {
        let samples: [Any?] = [nil, NSNull(), true, false, 0, 7, 7.25, -3.5,
                               "12.5", "abc", "", Double.infinity, -Double.infinity,
                               NSNumber(value: 42), [1, 2], ["k": "v"]]
        for v in samples {
            let shared = Num.doubleOrNilKeepingNonFinite(v)
            #expect(PredictRules.num(v) == shared, "PredictRules.num 与共享实现不一致：\(String(describing: v))")
            #expect(ScanRunner.num(v) == shared, "ScanRunner.num 与共享实现不一致：\(String(describing: v))")
        }
    }
}