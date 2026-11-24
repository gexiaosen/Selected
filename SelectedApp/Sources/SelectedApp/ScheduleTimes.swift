import Foundation
import Observation
import SelectedCore   // `RoundOrder`（轮次时间顺序/边界的纯函数在 Core）

/// 调度时间配置（不属于参数体系）：**只存「用户把哪个任务改到几点」**。
/// 任务集合本身（有几个、叫什么、出厂几点）唯一来源是 `SelectedCore.ScheduleCatalog`。
/// 存 UserDefaults，修改即时生效（Scheduler 每 tick 动态读取）。
@Observable
@MainActor
final public class ScheduleTimes {
    public static let shared = ScheduleTimes()

    public struct Entry: Equatable {
        public var key: String
        public var label: String
        public var hour: Int
        public var minute: Int
    }

    /// 调度项（**按时刻升序**，与设置页展示顺序一致）。
    ///
    /// ⚠ 顺序**不承载语义**：`Scheduler` 挑"下一个待跑任务"走的是**按时刻取最早**
    ///   （`nextPending`），不是数组序 ⇒ 不要引入"下标 = 先后"的假设。
    public private(set) var entries: [Entry] = []

    /// 调度项变化回调（Scheduler 重载任务表用）。
    /// ⚠ `@ObservationIgnored`：非 Sendable 闭包被 @Observable 包装后每次 set/get 都走观察
    ///   accessor，而 UI 从不读它 ⇒ 退出观察注册（所有读写都在主线程，无数据竞争）。
    @ObservationIgnored public var onReload: (() -> Void)?

    private let defaultsKey = "scheduleTimes"

    private init() {
        load()
    }

    // MARK: 默认值

    /// 出厂默认表 = `SelectedCore.ScheduleCatalog` 的注册表（**每个任务的时点为什么选在这里、
    /// 同刻冲突怎么处理，都写在那些行旁边 —— 不在这里复述**）。
    ///
    /// ⚠ 本表按**时刻升序**排列 —— 与设置页展示一致（展示侧还会再**稳定**排一次，
    ///   见 `RoundOrder.sortedByMinuteOfDay`）。重排**不影响存量用户**：`load()` 按 `key` 合并、不按下标。
    ///
    /// ⚠ **这里不再写第二份 label**：原先 `ScheduleTimes` 与 `Scheduler.taskTemplates` 各存一份，
    ///   漂了不报错（设置页叫一个名、失败通知叫另一个名）。
    ///   现在本类只管「用户改过的时刻」，任务集合与名字归注册表。
    private static let defaults: [Entry] = ScheduleCatalog.tasks.map {
        .init(key: $0.id, label: $0.label, hour: $0.hour, minute: $0.minute)
    }

    private func load() {
        // 按 key 合并：存量无该 key 的新任务用默认时间（插入新项不会错位到别的任务）
        if let raw = UserDefaults.standard.array(forKey: defaultsKey) as? [[String: Any]] {
            var list = Self.defaults
            for d in raw {
                guard let h = d["hour"] as? Int, let m = d["minute"] as? Int,
                      (0...23).contains(h), (0...59).contains(m) else { continue }
                // ⚠ 旧格式（无 `key` 字段）**整批丢弃回落默认**：按下标对齐会让 defaults 顺序一变
                //   就把时间写到**别的任务**上且界面看不出来。丢一次自定义回到默认是**安全方向**
                //   （与下面"三轮倒挂就回落默认"同一取舍）。
                guard let k = d["key"] as? String else {
                    NSLog("[NOTICE] 调度时间存量数据缺 key 字段（旧格式）→ 整批回落默认")
                    entries = Self.defaults
                    return
                }
                // key 未知（例如降级后存量里还留着一个本版本已删掉的键）→ **只跳过该项**，
                // 不动其它任务的时刻（与"整批丢弃"区分：这不是格式问题，是版本差异）
                guard let idx = list.firstIndex(where: { $0.key == k }) else { continue }
                list[idx].hour = h
                list[idx].minute = m
            }
            // ⚠ 存量数据可能是"三轮顺序倒挂"的 → **安全方向回落默认**。留着它会让第 2 轮
            //   的轮次归属不可达（那轮永远选不出票），而界面上一切正常、没有任何报错。
            //   代价是丢一次自定义的三轮时间 —— 与"让引擎跑在非法配置上"相比，这是安全方向。
            if let err = Self.roundOrderError(list) {
                NSLog("[NOTICE] 调度时间三轮顺序倒挂（%@）→ 三轮已回落默认", err)
                for k in Self.roundKeys {
                    if let i = list.firstIndex(where: { $0.key == k }),
                       let d = Self.defaults.first(where: { $0.key == k }) {
                        list[i].hour = d.hour
                        list[i].minute = d.minute
                    }
                }
            }
            entries = list
        } else {
            entries = Self.defaults
        }
    }

    private func save() {
        let raw: [[String: Any]] = entries.map {
            ["key": $0.key, "label": $0.label, "hour": $0.hour, "minute": $0.minute]
        }
        UserDefaults.standard.set(raw, forKey: defaultsKey)
    }

    // MARK: 修改（即时生效）

    /// 三轮扫描的时间键 —— **顺序校验只对这几轮生效**（理由见 `roundOrderError`）
    static let roundKeys = RoundPlan.roundKeys

    /// 各轮扫描必须**依次递增**。`nil` = 合法；否则返回用户可读的原因。
    ///
    /// ⚠ **判定逻辑在 `SelectedCore.RoundOrder`（纯函数），不在这里**：这条约束是"删掉不会变红"的那类，
    ///   纯计算进 Core 才能被 `swift test` 覆盖；这里只负责把 `entries` 映射成分钟数。
    ///
    /// ⚠ 为什么必须挡：`roundBoundaries` 取**相邻两轮的中点**，顺序一旦倒挂（`round1 > round2`）
    ///   → 边界倒挂 → **第 2 轮归属分支不可达** —— 表现是"第二轮永远选不出票"，
    ///   而界面上一切正常、没有任何报错。
    ///   按本项目纪律（**要挡就做成阻断性错误，不要只告警**），调用方拿到非 nil 时**拒绝写入**。
    ///
    /// ⚠ 轮次集合按 `RoundPlan.roundKeys` 取（不是写死 `round1/2/3`）：漏一轮 = 那一轮的时间
    ///   非法也不拦，正是这条校验本来要防的事。
    static func roundOrderError(_ list: [Entry]) -> String? {
        RoundOrder.error(minutes: roundKeys.map { k in
            list.first { $0.key == k }.map { $0.hour * 60 + $0.minute }
        })
    }

    /// 修改某个任务的时间（**即时生效**：`Scheduler` 每 tick 动态读取）。
    ///
    /// - Returns: `nil` = 已应用；非 `nil` = **被拒绝**（用户可读的原因），**不改任何状态**。
    ///
    /// ⚠ 顺序校验**只在该次改动涉及三轮之一时**才跑：若对任意改动都校验，存量倒挂数据会让用户
    ///   **连无关任务的时间都改不了**。只在碰三轮时挡 —— 既防新增非法态，也不堵住无关操作。
    @discardableResult
    public func update(key: String, hour: Int, minute: Int) -> String? {
        guard let idx = entries.firstIndex(where: { $0.key == key }) else { return nil }
        var trial = entries
        trial[idx].hour = max(0, min(23, hour))
        trial[idx].minute = max(0, min(59, minute))
        if Self.roundKeys.contains(key), let err = Self.roundOrderError(trial) { return err }
        entries = trial
        save()
        onReload?()
        return nil
    }

    public func reset() {
        entries = Self.defaults
        save()
        onReload?()
    }

    public func time(of key: String) -> (hour: Int, minute: Int)? {
        entries.first { $0.key == key }.map { ($0.hour, $0.minute) }
    }

    /// 任务键 → `"HH:mm"`（读不到 → `"—"`）。**视图里嵌调度时刻一律走这里**。
    ///
    /// ⚠ 为什么要有这个入口：把时刻写死在文案里，用户在设置页改完时刻后文案**全部失真**
    ///   （引导页教的是错的时刻、空态提示指向不存在的时点）。
    public func clock(_ key: String) -> String {
        guard let t = time(of: key) else { return "—" }
        return RoundOrder.hhmm(t.hour * 60 + t.minute)
    }

    /// 各轮的当前调度时刻（与 `RoundPlan.slots` 同序）。
    ///
    /// ⚠ **文案里逐轮嵌时刻一律走这里**：手写 `clock("round1")/clock("round2")/clock("round3")`
    ///   在加第 4 轮后不会编译报错，只会**悄悄少说一轮** —— 而这类文案是给用户做决策用的
    ///   （"扫描在几点跑、那时尾盘窗口还没走完"），少一轮就是错的口径说明。
    public var roundClocks: [String] { Self.roundKeys.map(clock) }

    /// 各轮时间 → 引擎轮次归属边界（供手动/自动扫描时传给引擎）
    /// 边界 i = (第 i 轮 与 第 i+1 轮 的中点)，共 `RoundPlan.count - 1` 个
    ///
    /// ⚠ 算法在 `SelectedCore.RoundOrder.boundaries`（纯函数，可被 `swift test` 覆盖）。
    ///   它**依赖各轮依次递增**（由 `roundOrderError` 在写入时保证）——
    ///   倒挂会让边界也倒挂，中间轮次的归属分支随之不可达。
    public var roundBoundaries: [String] {
        func mins(_ k: String) -> Int? { time(of: k).map { $0.0 * 60 + $0.1 } }
        return RoundOrder.boundaries(minutes: Self.roundKeys.map(mins))
            ?? RoundPlan.defaultBounds.map { RoundOrder.hhmm($0) }
    }
}
