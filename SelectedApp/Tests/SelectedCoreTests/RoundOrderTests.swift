import XCTest
@testable import SelectedCore

/// 「三轮扫描时间必须依次递增」这条约束的回归锁。
///
/// ## 为什么这条约束值得一个测试文件
///
/// `ScheduleTimes.roundBoundaries` 取**相邻两轮的中点**，而 `Screener.resolveSlot` 的判定是
/// 顺序比较：
/// ```
/// if t < b1 { 第1轮 }        // b1 = (第1轮 + 第2轮) / 2
/// if t < b2 { 第2轮 }        // b2 = (第2轮 + 第3轮) / 2
/// else      { 第3轮 }
/// ```
/// 三轮时间一旦**倒挂**（如第1轮 14:50、第2轮 14:30）→ `b1 > b2` → **第 2 轮分支不可达**：
/// `t < b2` 在 `t >= b1 > b2` 的前提下永远为假。表现是"**第二轮永远选不出票**"，
/// 而界面上一切正常、日志里什么都没有。
///
/// 这就是为什么判定必须做成**阻断性错误**（写入时拒绝）而不是"存下来再告警"——
///   告警会被忽略，而后果是静默的。
///
/// `RoundOrder` 放在 `SelectedCore` 而不是 `ScheduleTimes`（App 层）的原因：
///   `Tests/SelectedCoreTests` 只依赖 `SelectedCore` —— App 层的类型**结构上无法**被本套件覆盖，
///   而这条约束恰恰是"删掉不会变红"的那类。
final class RoundOrderTests: XCTestCase {

    private func m(_ h: Int, _ min: Int) -> Int { h * 60 + min }

    // MARK: - 判定本身

    /// 合法（默认值 14:00 / 14:30 / 14:50）→ 不报错。
    func testDefaultTimesAreValid() {
        XCTAssertNil(RoundOrder.error(minutes: [m(14, 0), m(14, 30), m(14, 50)]))
    }

    /// **判别性用例**：任何非递增的组合都必须被拒（含**相等**）。
    ///
    /// 若哪天有人把校验放宽成 `a <= b, b <= c`（"相等应该没问题"），
    /// **只有这条会红** —— 而相等会让 `b1 == 第1轮 == 第2轮`，
    /// 第 1/2 轮之间**没有任何时刻**归属第 1 轮（边界退化到轮次点本身）。
    func testNonIncreasingOrderIsRejected() {
        // 倒挂
        XCTAssertNotNil(RoundOrder.error(minutes: [m(14, 50), m(14, 30), m(15, 0)]),
                        "第1轮晚于第2轮必须被拒")
        XCTAssertNotNil(RoundOrder.error(minutes: [m(14, 0), m(15, 0), m(14, 30)]),
                        "第2轮晚于第3轮必须被拒")
        // 相等
        XCTAssertNotNil(RoundOrder.error(minutes: [m(14, 30), m(14, 30), m(15, 0)]),
                        "第1轮与第2轮相等必须被拒")
        XCTAssertNotNil(RoundOrder.error(minutes: [m(14, 0), m(14, 30), m(14, 30)]),
                        "第2轮与第3轮相等必须被拒")
        // 全同
        XCTAssertNotNil(RoundOrder.error(minutes: [m(14, 0), m(14, 0), m(14, 0)]))
    }

    /// 键缺失（`nil`）→ **不报错**（无从判定，不误报）。
    ///
    /// 这条防的是"把缺键也当成非法"→ 用户会看到一条无法理解、也无法修好的错误。
    func testMissingKeyIsNotReported() {
        XCTAssertNil(RoundOrder.error(minutes: [nil, m(14, 30), m(14, 50)]))
        XCTAssertNil(RoundOrder.error(minutes: [m(14, 0), nil, m(14, 50)]))
        XCTAssertNil(RoundOrder.error(minutes: [nil, nil, nil]))
    }

    /// 报错文案要**带上当前三个值**（用户得知道现在是几点才能改）。
    func testErrorMessageCarriesCurrentValues() {
        let err = RoundOrder.error(minutes: [m(14, 50), m(14, 30), m(15, 0)])
        guard let e = err else { return XCTFail("倒挂必须报错") }
        XCTAssertTrue(e.contains("14:50"), "文案里要有第1轮的当前值：\(e)")
        XCTAssertTrue(e.contains("14:30"), "文案里要有第2轮的当前值：\(e)")
        XCTAssertTrue(e.contains("15:00"), "文案里要有第3轮的当前值：\(e)")
    }

    /// ⚠ **入参是数组**（审查 B8-1 第二片）：arity-3 的签名等于把"几轮"又写死一次。
    /// 这条锁的就是"第 4 轮也在校验范围内" —— 形参个数改成 3 个时它会红。
    func testValidatorCoversEveryRoundNotJustThree() {
        XCTAssertNil(RoundOrder.error(minutes: [m(14, 0), m(14, 30), m(14, 50), m(15, 10)]))
        // 只有**最后一轮**倒挂 —— arity-3 版本对这种输入根本无能为力
        XCTAssertNotNil(RoundOrder.error(minutes: [m(14, 0), m(14, 30), m(14, 50), m(14, 40)]),
                        "第 4 轮早于第 3 轮必须被拒")
        // 边界个数 = 轮数 - 1
        XCTAssertEqual(RoundOrder.boundaries(minutes: [m(14, 0), m(14, 30), m(14, 50), m(15, 10)])?.count, 3)
    }

    /// 少于两轮无从判定（`nil`），不崩也不"算出个半个边界"
    func testShortInputsAreInconclusive() {
        XCTAssertNil(RoundOrder.error(minutes: []))
        XCTAssertNil(RoundOrder.error(minutes: [m(14, 0)]))
        XCTAssertNil(RoundOrder.boundaries(minutes: []))
        XCTAssertNil(RoundOrder.boundaries(minutes: [m(14, 0)]))
    }

    // MARK: - 后果（这条约束存在的唯一理由）

    /// 把 `RoundOrder.boundaries` 的输出转成分钟数
    private func bounds(_ m: [Int?]) -> [Int] {
        guard let r = RoundOrder.boundaries(minutes: m) else {
            XCTFail("都给了值，必须能算出边界"); return []
        }
        return r.map { s in
            let p = s.split(separator: ":").compactMap { Int($0) }
            return p.count == 2 ? p[0] * 60 + p[1] : 0
        }
    }

    /// 复刻 `Screener.resolveSlot` 的判定顺序（它就是沿边界升序比较）
    private func slot(at t: Int, _ b: [Int]) -> Int {
        for (i, edge) in b.enumerated() where t < edge { return i + 1 }
        return b.count + 1
    }

    /// **判别性用例**：**严重倒挂**（第 1 轮晚于第 3 轮）→ 第 2 轮**在数学上不可达**。
    ///
    /// 判据是 **`b1 > b2` ⟺ `r1 > r3`** —— 不是 `r1 > r2`。
    func testSevereInversionMakesSecondRoundUnreachable() {
        // 第1轮 15:00 / 第2轮 14:30 / 第3轮 14:40 → b1 = 14:45、b2 = 14:35（b1 > b2）
        let bad = bounds([m(15, 0), m(14, 30), m(14, 40)])
        XCTAssertEqual(bad.count, 2)
        XCTAssertGreaterThan(bad[0], bad[1], "r1 > r3 时 b1 必须大于 b2 —— 这是不可达的前提")
        let probes = [0, m(9, 30), m(14, 15), m(14, 30), m(14, 35), m(14, 45), m(15, 0), m(23, 59)]
        XCTAssertFalse(probes.contains { slot(at: $0, bad) == 2 },
                       "第 2 轮分支必须不可达（**这就是要挡的后果**）")

        // 反向断言（防空转）：合法顺序下第 2 轮**必须**可达
        let good = bounds([m(14, 0), m(14, 30), m(14, 50)])
        XCTAssertLessThan(good[0], good[1])
        XCTAssertTrue(probes.contains { slot(at: $0, good) == 2 },
                      "合法顺序下第 2 轮必须可达（否则本用例在空转）")
    }

    /// **判别性用例**：**部分倒挂**（`r1 > r2` 但 `r1 < r3`）时边界**仍然递增** ——
    /// 所以它不会被"第 2 轮不可达"那条发现，但**第 1 轮自己的触发时刻会落进第 3 轮**。
    ///
    /// 例：第1轮 14:50 / 第2轮 14:30 / 第3轮 15:00 → `b1 = 14:40`、`b2 = 14:45`
    /// → 14:50 触发的那一轮被 `resolveSlot` 记成 **slot 3**（而不是 slot 1）。
    /// 后果是三轮对比里的"轮次"整体错位，而**界面上看不出来**。
    func testPartialInversionMisclassifiesFirstRound() {
        let r1 = m(14, 50)
        let b = bounds([r1, m(14, 30), m(15, 0)])
        XCTAssertLessThan(b[0], b[1], "部分倒挂时边界仍递增 —— 所以它躲过了'不可达'那条检查")
        XCTAssertEqual(slot(at: r1, b), 3,
                       "⚠ 第 1 轮**自己的触发时刻**被归到了第 3 轮（这才是部分倒挂的后果）")
        // 反向断言：合法顺序下第 1 轮的触发时刻必须归到第 1 轮
        let good = bounds([m(14, 0), m(14, 30), m(14, 50)])
        XCTAssertEqual(slot(at: m(14, 0), good), 1)
    }

    /// 边界就是"相邻两轮中点"（默认值 → 14:15 / 14:40）。
    func testBoundariesAreMidpointsOfAdjacentRounds() {
        let r = RoundOrder.boundaries(minutes: [m(14, 0), m(14, 30), m(14, 50)])
        guard let b = r else { return XCTFail("都给了值，必须能算出边界") }
        XCTAssertEqual(b, ["14:15", "14:40"])
        // 缺键 → nil（由调用方回落默认）
        XCTAssertNil(RoundOrder.boundaries(minutes: [nil, m(14, 30), m(14, 50)]))
    }

    /// `RoundPlan.defaultBounds` 必须就是原 `resolveSlot` 里手写的 `14:15 / 14:40`
    /// —— 派生改动不许动口径（这是"回落默认"那条路径的实际取值）。
    func testRoundPlanDefaultBoundsMatchLegacyValues() {
        XCTAssertEqual(RoundPlan.defaultBounds, [m(14, 15), m(14, 40)])
        XCTAssertEqual(RoundPlan.defaultBounds.count, RoundPlan.count - 1,
                       "边界个数 = 轮数 - 1，否则 resolveSlot 的回落路径会错位")
    }

    // MARK: - sortedByMinuteOfDay

    /// 乱序 → 升序。用真实的调度项形状（key + 时刻），但**不复制 `ScheduleTimes.defaults`**
    /// —— 那份数据在 App 层，复制过来会漂；这里只锁函数本身的行为。
    func testSortsByMinuteOfDay() {
        let items = [("fundflow", m(15, 20)), ("watch", m(14, 50)), ("lhb", m(17, 30)), ("limitup", m(15, 15))]
        let got = RoundOrder.sortedByMinuteOfDay(items) { $0.1 }.map(\.0)
        XCTAssertEqual(got, ["watch", "limitup", "fundflow", "lhb"],
                       "⚠ 这正是 P2-26 的现场：按声明序渲染时 15:20 会排在 14:50 前面")
    }

    /// 并列时**必须稳定**：`round3` 与 `watch` 默认同为 14:50。
    /// 不稳定 → 这两格每次重排都可能换位，用户会以为设置被改了。
    func testStableWhenMinutesTie() {
        let items = [("round3", m(14, 50)), ("watch", m(14, 50)), ("compare", m(15, 2))]
        let got = RoundOrder.sortedByMinuteOfDay(items) { $0.1 }.map(\.0)
        XCTAssertEqual(got, ["round3", "watch", "compare"], "同刻必须保持传入顺序")
        // 反向：把两者对调，结果也必须跟着对调（证明是"保序"而不是"碰巧正确"）
        let flipped = [("watch", m(14, 50)), ("round3", m(14, 50))]
        XCTAssertEqual(RoundOrder.sortedByMinuteOfDay(flipped) { $0.1 }.map(\.0), ["watch", "round3"])
    }

    func testEmptyAndSingleAreIdentity() {
        XCTAssertTrue(RoundOrder.sortedByMinuteOfDay([Int]()) { $0 }.isEmpty)
        XCTAssertEqual(RoundOrder.sortedByMinuteOfDay([7]) { $0 }, [7])
    }

    // MARK: - Screener.parseBounds / resolveSlot 的显式边界

    /// 纯函数"字符串 → 当日分钟数"——从 `resolveSlot` 内联抽出，因此可单测。
    func testParseBounds() {
        XCTAssertEqual(Screener.parseBounds("14:15,14:40"), [855, 880])
        XCTAssertEqual(Screener.parseBounds(" 09:30 , 15:00 "), [570, 900], "两侧空白要容错")
        XCTAssertEqual(Screener.parseBounds("9:5,10:0"), [545, 600], "个位数小时/分钟也认")
    }

    /// 格式不对一律 `nil`（调用方回落默认），**不许"尽力解析"** ——
    ///   用半个边界会让 slot 判定错位，而错位的表现是"某轮永远选不出票"（界面上看不出来）。
    func testParseBoundsRejectsMalformed() {
        XCTAssertNil(Screener.parseBounds(nil))
        XCTAssertNil(Screener.parseBounds(""))
        XCTAssertNil(Screener.parseBounds("   "))
        XCTAssertNil(Screener.parseBounds("14:15"), "只有一个")
        XCTAssertNil(Screener.parseBounds("14:15,14:40,14:50"), "有三个")
        XCTAssertNil(Screener.parseBounds("14:15,14:4x"), "分钟不是数字")
        XCTAssertNil(Screener.parseBounds("1415,1440"), "缺冒号")
    }

    /// 边界个数不对 → `resolveSlot` **回落默认**（14:15/14:40），不是崩、也不是用半个。
    func testResolveSlotFallsBackOnBadBounds() {
        let d = ChinaTime.calendar.date(from: DateComponents(year: 2026, month: 9, day: 14,
                                                            hour: 14, minute: 30))!
        XCTAssertEqual(Screener.resolveSlot(now: d, bounds: nil).slot, 2, "默认边界下 14:30 属第 2 轮")
        XCTAssertEqual(Screener.resolveSlot(now: d, bounds: [1]).slot, 2, "个数不对 → 回落默认")
        XCTAssertEqual(Screener.resolveSlot(now: d, bounds: [900, 901]).slot, 1,
                       "显式边界 15:00/15:01 → 14:30 属第 1 轮（证明参数真的生效了）")
    }
}
