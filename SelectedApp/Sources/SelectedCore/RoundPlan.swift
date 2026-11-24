import Foundation

/// 选股**轮次计划**的唯一来源（槽位号 + 轮次标签）。
///
/// ## 为什么要有这个文件（2026-10-16 审查 B8-1 的第一片）
/// "一共几轮、每轮叫什么"这件事原先在 Core 里**各写一份**：
/// · `[1, 2, 3]` 字面量：`Signals.expectedSlots` / `SQLiteReader.roundDetail`
///   / `CompareStore.loadRounds` / `DashboardRowEntities`（4 处）
/// · `14:00 / 14:30 / 14:50` 标签表：`ScanRunner.slotLabels`
///   / `PhaseOps.slotLabels`（该别名已随「源系统导入」于 2026-10-27 删除）
///   / `Signals` 里的**函数内局部副本**
///   / `Screener.resolveSlot` 里直接写进三个 return（4 份）
/// 加第 4 轮时这些不会编译报错，而是**静默产出错误结论**：
/// `slots.count >= expectedSlots.count` 恒假 ⇒ 所有信号都被判"未持续验证"；
/// `resolveSlot` 返回一个没有标签的槽位 ⇒ 落库 `slot_label` 为空串。
///
/// ## 第二片补上的（2026-10-16）
/// `ScheduleTimes` 的默认调度表与 `roundKeys`、`RoundOrder.error/boundaries`（改成**数组签名**，
/// 不再只校验前三轮）、`Screener.resolveSlot`（沿边界升序，不再写死两档）、`Scheduler` 与
/// `OnboardingSheet` 的任务表、`ResultsView` 的分段控件、`Components+PageControls` 的环节代表键。
/// `RoundPlanTests.testNoRoundKeyLiteralsInSources` 守住（并用"扫描器在本文件上必须扫得到"
/// 的反向断言防它空转）。
///
/// ## 仍**没有**覆盖的部分（刻意留下，不是遗漏）
/// · `scan_rounds.tier1_count/tier2_count` 两列 —— 那是**梯队**维度，与轮次无关（见下）。
/// · `ResultsView` 分段控件 `width: 344`（按当前 3 格调出来的视觉值，轮数变了要重调，属视觉适配）。
/// · **产品口径本身**：compare / review 里"三轮稳定标的""三轮对比"这类判据与措辞是**按三轮设计的**，
///   加第 4 轮要先回答"持续"定义成几轮 —— 那不是常量派生能解决的。
///
/// ⚠ **别把 `1...3` 一律当成轮次**：`SQLiteReader.roundDetail` 里的 `for t in 1...3`
///   是**梯队**（tier1/2/3，按分数分档），与轮次只是数字相同。改轮次时扫过去会误伤它。
/// 本文件的职责是：**把"数字、时刻、任务键"收成一处**，
/// 让"几轮"这件事改一个常量就能贯通到调度、引擎、界面。
public enum RoundPlan {

    /// 一轮的完整定义 —— **本文件唯一的真值表**，下面所有出口都从它派生。
    public struct Slot: Sendable, Equatable {
        /// 槽位号（落库 `scan_rounds.slot` 的取值域）
        public let num: Int
        /// **默认**时刻（用户可在设置页改，实际时刻以 `ScheduleTimes` 为准）
        public let hour: Int
        public let minute: Int
        public init(num: Int, hour: Int, minute: Int) {
            self.num = num
            self.hour = hour
            self.minute = minute
        }
    }

    /// 轮次计划（**升序**，下标即"第几个触发"）
    public static let plan: [Slot] = [
        .init(num: 1, hour: 14, minute: 0),
        .init(num: 2, hour: 14, minute: 30),
        .init(num: 3, hour: 14, minute: 50),
    ]

    /// 轮次槽位号（升序，也是落库 `scan_rounds.slot` 的取值域）
    public static let slots: [Int] = plan.map(\.num)

    /// 槽位号 → 展示标签（默认时刻，`HH:mm`）。
    /// 与各轮默认时间**同源** ⇒ 不存在"标签说 14:00、调度跑 14:05"的漂移。
    public static let labels: [Int: String] = Dictionary(
        uniqueKeysWithValues: plan.map { ($0.num, RoundOrder.hhmm($0.hour * 60 + $0.minute)) })

    /// 轮数（"该有几轮"的判据）
    public static var count: Int { slots.count }

    /// 某槽位的标签；未知槽位 → 空串（与原 `slotLabels[x] ?? ""` 行为一致）
    public static func label(of slot: Int) -> String { labels[slot] ?? "" }

    // MARK: 调度任务键

    /// 槽位号 → `ScheduleTimes` / `Scheduler` 里的任务键（`round1` / `round2` / …）
    public static func roundKey(_ slot: Int) -> String { "round\(slot)" }

    /// 全部轮次的任务键（与 `slots` 同序）
    public static var roundKeys: [String] { slots.map(roundKey) }

    /// 是否**轮次任务键**（`round1` / `round2` / …）。
    ///
    /// ⚠ 判据用集合、不用 `hasPrefix("round")`：后者会把任何以 round 开头的键都认成轮次
    ///   （包括"这一轮其实没排上"的键），而轮次键的合法取值域就是 `slots`。
    public static func isRound(key: String) -> Bool { roundKeys.contains(key) }

    /// 任务键 → 槽位号（非轮次键 → `nil`）。``isRound(key:)`` 的取值配套出口，
    /// 用来替代从前 `Int(args.last ?? "") ?? 1` 那种"从命令参数里抠轮号"的写法。
    public static func slot(forKey key: String) -> Int? {
        roundKeys.firstIndex(of: key).flatMap { slot(atOrdinal: $0) }
    }

    /// **默认**轮次归属边界（相邻两轮的中点，当日分钟数，升序 `count-1` 个）。
    ///
    /// 3 轮 → `[855, 880]`（14:15 / 14:40），与原 `resolveSlot` 里手写的默认值逐位相同。
    /// ⚠ 这里派生的是**默认**边界（用户没传时用）；实际调度用的来自 `ScheduleTimes.roundBoundaries`。
    public static let defaultBounds: [Int] = {
        let mins = plan.map { $0.hour * 60 + $0.minute }
        guard mins.count >= 2 else { return [] }
        return zip(mins, mins.dropFirst()).map { ($0 + $1) / 2 }
    }()

    // MARK: 中文数字（文案派生用）

    /// 阿拉伯数字 → 中文数字（`1 → 一`）；超出表内 → 原样返回数字串。
    ///
    /// ⚠ 为什么要有：界面文案写的是「三轮已齐全」「第一轮」这样的**汉字**，
    ///   而 `\(count)` 插值出来是「3 轮」—— 直接换写法会**改动用户看得见的字**。
    ///   派生走这一层，`3` 轮时输出与今天逐字相同，加第 4 轮时自动变成「四轮」。
    public static func cn(_ n: Int) -> String {
        let digits = ["零", "一", "二", "三", "四", "五", "六", "七", "八", "九", "十"]
        guard n >= 0, n < digits.count else { return String(n) }
        return digits[n]
    }

    /// 「第 N 轮」（汉字序数）—— 消费方是分段控件与提示文案
    public static func ordinal(_ n: Int) -> String { "第\(cn(n))轮" }

    /// 第 i 个槽位（0 基）；越界 → nil
    public static func slot(atOrdinal i: Int) -> Int? {
        guard slots.indices.contains(i) else { return nil }
        return slots[i]
    }

    /// 按槽位序返回 `(slot, label)`（`Screener.resolveSlot` 的分支出口）
    public static func resolved(atOrdinal i: Int) -> (slot: Int, label: String)? {
        guard let s = slot(atOrdinal: i) else { return nil }
        return (s, label(of: s))
    }

    /// 缺了哪几轮（供 compare 的 `missing_slots` 与告警文案用）。
    ///
    /// 返回顺序恒按 `slots` 升序 —— 消费方手上是 `Set`（`Store.freshTodayDoneSlots`）
    /// 或 `Dictionary.Keys`（`Signals`），两者的枚举序都不可靠。
    public static func missing<T: Sequence>(_ present: T) -> [Int] where T.Element == Int {
        let has = Set(present)
        return slots.filter { !has.contains($0) }
    }
}
