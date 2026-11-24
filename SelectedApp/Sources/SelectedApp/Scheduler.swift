import Foundation
import AppKit
import Observation
import SelectedCore

/// 任务调度器（F2）：三轮 + 四阶段，时间从 `ScheduleTimes` 独立配置动态读取（修改即时生效）。
///
/// ## 架构
///   · **决策全部交给 `ScheduleEngine`**（`SelectedCore` 里的纯函数，可离线单测）
///   · **单次定时器精确挂到最早的下次触发时刻**，触发后重算重挂（上限 5 分钟做时钟自愈）
///   · **单一状态表** `states`（含完成时刻 / 尝试次数 / 失败时刻 / 错过原因）持久化，
///     `completedToday` / `failedCounts` / `failureMessages` / `missedToday` 都是它的**派生只读视图**
///   · **`NSWorkspace.didWakeNotification` 唤醒补偿**：醒来立刻重算（窗口内补跑，超窗显式记错过）
///   · 漏跑策略**显式化**：超窗记 `missed` + 日志 + 通知 + UI 可见（不静默跳过）
///   · 调度活跃区间内 `beginActivity` 退出 App Nap（只退出 App Nap，**不阻止系统睡眠**）
///
/// **决策正确性由 `ScheduleEngineTests` 覆盖**。
@Observable
@MainActor
final class Scheduler {
    static let shared = Scheduler()

    struct Task: Identifiable, Sendable, Equatable {
        let id: String
        let hour: Int
        let minute: Int
        let label: String
        /// 轮次任务的槽位号；非轮次任务为 `nil`。
        /// ⚠ 派生自 `RoundPlan`，**不再从 `args` 里抠数字**（原先 `Int(args.last ?? "") ?? 1`
        ///   在 args 形状一变时会静默按第 1 轮跑 —— 而"跑成哪一轮"直接决定库里那条 `scan_rounds.slot`）。
        let slot: Int?
        let suffix: ScheduleCatalog.NotifySuffix

        var minuteOfDay: Int { hour * 60 + minute }
        var spec: ScheduleTaskSpec { ScheduleTaskSpec(id: id, minuteOfDay: minuteOfDay) }
        /// 完成通知标题（`label` + 后缀；后缀含义见 `ScheduleCatalog.NotifySuffix`）
        var notifyTitle: String { label + suffix.rawValue }
    }

    /// 任务集合的唯一来源是 `SelectedCore.ScheduleCatalog`（标签 / 出厂时刻 / 通知后缀 / 展示顺序），
    /// 本类不再持有任何任务表 —— 原先这里与 `ScheduleTimes.defaults` 各存一份 label，
    /// 漂了不报错（设置页叫一个名、失败通知叫另一个名）。

    /// 调度策略（补跑窗口 / 重试间隔 / 上限等数字集中一处，不散落在逻辑里）
    static let policy = SchedulePolicy()

    /// 当前任务表（按 `ScheduleCatalog.tasksInDisplayOrder` 排列，时刻从 `ScheduleTimes` 读，
    /// 修改调度时间后自动重建）。
    /// ⚠ 这个次序**不是时间序**（是功能分组）⇒ `nextPending` 必须自己按时刻取。
    private(set) var tasks: [Task] = []

    var runningTaskId: String?
    var lastError: String?

    /// 正在执行的后台任务句柄（`execute` 各分支统一收口到这里，`stop()` 可取消）。
    ///
    /// ⚠ 必须存句柄：否则 App 退出时 `stop()` 只能 invalidate 定时器，
    ///   **无法取消正在跑的分钟级扫描任务**（`ScanRunner.runRound` 单轮可达分钟级）。
    /// ⚠ 类型写 `Swift.Task`：本类有嵌套类型 `Task`（调度任务行），裸 `Task` 会指到它。
    /// ⚠ `@ObservationIgnored`：本句柄没有任何 View 读取 ⇒ 避免每次赋值登记/失效依赖
    ///   （与 `timer` / `wakeObserver` / `activity` 同一理由）。
    ///   ⚠ **不要**给 `runningTaskId` 也加 —— 它被 `Store.hasBusyWriteCommand` 读，
    ///     是**跨模块的公开判据**，加了会让写命令门失灵。
    @ObservationIgnored
    var runningTask: Swift.Task<Void, Never>?

    /// 在飞任务的「取消标志盒」。
    ///
    /// ⚠ `ScanRunner` 的扫描链路是**全同步**的，`runningTask?.cancel()` 打的取消标记
    /// 它读不到（无 Task 上下文）⇒ `stop()` 额外置位这个盒子，Core 每批请求前读一次
    /// （`DataSourcesQuotes.fetchTencentQuotes`）⇒ 真正可中断。
    /// ⚠ `@ObservationIgnored`：纯内部取消通道，无任何 View 读取。
    @ObservationIgnored var inFlightCancelBox: CancellationBox?

    /// **当日调度状态表 —— 唯一事实来源**（持久化到 UserDefaults，按日期分键）
    var states: [String: TaskRuntimeState] = [:]
    /// 当日"是不是交易日"的缓存（判据来自 `DataSources.tradingDayVerdict`，需联网）。
    ///
    /// ⚠ 为什么必须有（2026-10-16 审查 B5-6）：原先 `context` 直接用
    ///   `!ChinaTime.isWeekend(now)` —— 于是**所有非周末都被当交易日**，
    ///   国庆/春节/元旦这些工作日里，调度器照样到点唤醒、跑 6 个任务、发
    ///   「早盘预判就绪 / 三轮对比报告就绪 / 收盘复盘完成 / 全量判定完成」，
    ///   并把从未发生场次的 predicts/reviews/signal_classes/watch_judgments 写进库、
    ///   推进迭代计数（`ScanRunner` 自己有 `isTradingDay` 闸门，其余任务都没有）。
    ///   `context` 在 MainActor 上同步执行而判定要发网络请求 ⇒ **不能就地等**，
    ///   所以走缓存：与 `AlertMonitor.isTradingDay` 同一纪律
    ///   （`true` 缓存一整天；`false`/未确认每 60 秒复检 —— App 可能在指数
    ///   报价更新之前启动，把 `false` 缓存一整天 = 一整天都不跑且界面看不出来）。
    private var tradingDayCache: (day: String, value: Bool, checkedAt: Date)?
    private var tradingDayRefreshInFlight = false


    /// 最近一次唤醒补偿/错过的说明（诊断用，UI 可展示）
    var lastScheduleNote: String?

    /// 下一次计划唤醒时刻（诊断 + UI 展示）
    private(set) var nextRunAt: Date?

    var schedulerEnabled: Bool {
        didSet {
            UserDefaults.standard.set(schedulerEnabled, forKey: "schedulerEnabled")
            if schedulerEnabled != oldValue { tick(reason: "开关变更") }
        }
    }

    // ⚠ 以下三个是 AppKit 句柄/平台观察者，**不参与 UI 渲染**，标 `@ObservationIgnored` 退出观察注册
    //   （每次替换/注册都写一次，没有 UI 依赖它们，每次写触发全量 diff 纯属浪费）。
    //   ⚠ `states` **不能**标：UI 通过 `completedToday/failedCounts` 等派生属性读它，
    //   标了之后任务完成时界面将不再刷新（观察穿透计算属性到存储属性）。
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var activity: NSObjectProtocol?
    private var started = false
    private var currentDateKey = ""
    /// 本次进程启动时刻（用于判断"这次错过该不该打扰用户"）
    private let sessionStartedAt = Date()

    // MARK: - 派生视图（供 UI 读取；全部由 `states` 算出，不再各存一份）

    /// 当日已完成的任务 id
    var completedToday: Set<String> {
        Set(states.filter { $0.value.status == .done }.keys)
    }

    /// 任务 id → 已失败次数（含"重试耗尽 / 超窗"的终态，UI 据此显示异常）
    var failedCounts: [String: Int] {
        states.compactMapValues { st in
            (st.status == .failed || st.status == .missed) ? max(1, st.attempts) : nil
        }
    }

    /// 任务 id → 失败/错过的原因（UI 悬停展示）
    var failureMessages: [String: String] {
        states.compactMapValues { st in
            guard st.status == .failed || st.status == .missed else { return nil }
            return st.message ?? ""
        }
    }

    /// 任务 id → **当日未执行**的原因（超窗 / 重试耗尽）
    var missedToday: [String: String] {
        states.compactMapValues { $0.status == .missed ? ($0.message ?? "当日未执行") : nil }
    }

    var nextPending: Task? {
        let minutes = ChinaTime.minutesOfDay()
        let open = tasks.filter { !(states[$0.id] ?? TaskRuntimeState()).isTerminal }
        // ⚠ 按**时刻**取，不依赖数组序：展示顺序虽然已由 `ScheduleCatalog` 按时刻派生，
        //   但"下一个该跑谁"是调度语义，不该跟着版式走 —— 版式哪天再改，这里不能跟着错。
        return open.filter { $0.minuteOfDay > minutes }
                   .min { $0.minuteOfDay < $1.minuteOfDay }
            ?? open.min { $0.minuteOfDay < $1.minuteOfDay }
    }

    /// 当日所有任务都已到终态（完成或错过）
    var allDone: Bool {
        !tasks.isEmpty && tasks.allSatisfy { (states[$0.id] ?? TaskRuntimeState()).isTerminal }
    }

    // MARK: - 初始化

    private init() {
        currentDateKey = Self.dateKey()          // 必须先于任何 saveStates
        schedulerEnabled = UserDefaults.standard.object(forKey: "schedulerEnabled") as? Bool ?? true
        loadStates()
        rebuildTasks()
        // 调度时间修改 → 任务表实时重建 + 立刻重算（并重挂定时器）
        ScheduleTimes.shared.onReload = { [weak self] in
            self?.rebuildTasks()
            self?.tick(reason: "调度时间变更")
        }
    }

    private static func dateKey(_ date: Date = Date()) -> String { ChinaTime.day(date) }

    private var taskSpecs: [ScheduleTaskSpec] { tasks.map(\.spec) }

    /// 当前决策上下文
    private func context(now: Date = Date()) -> ScheduleContext {
        ScheduleContext(enabled: schedulerEnabled,
                        tradingDay: cachedTradingDay(now: now),
                        running: runningTaskId,
                        busy: Store.shared.hasBusyWriteCommand)
    }

    /// 缓存的交易日判定；没有缓存时退回"非周末即开盘"（= 改动前的行为，不新增风险）。
    private func cachedTradingDay(now: Date) -> Bool {
        let day = Self.dateKey(now)
        guard let c = tradingDayCache, c.day == day else { return !ChinaTime.isWeekend(now) }
        if c.value { return true }
        if now.timeIntervalSince(c.checkedAt) >= 60 { return !ChinaTime.isWeekend(now) }
        return false
    }

    /// 离主线程刷新交易日缓存（判定内部是同步 `httpGet`，绝不能在 `tick` 里直接调）。
    /// ⚠ 判不出来（`.unknown`）时**不写缓存**：宁可继续用"非周末"口径把今天当开盘，
    ///   也不能把一次网络抖动缓存成"今天不开盘"—— 那会一整天不跑且界面看不出来。
    private func refreshTradingDayCache(now: Date) {
        guard !tradingDayRefreshInFlight else { return }
        let day = Self.dateKey(now)
        if let c = tradingDayCache, c.day == day,
           c.value || now.timeIntervalSince(c.checkedAt) < 60 { return }
        tradingDayRefreshInFlight = true
        // ⚠ 必须写 `Swift.Task`：本类型内有个嵌套的 `Task`（任务表条目），
        //   裸写 `Task.detached` 会解析到它并报"没有 detached 成员"。
        Swift.Task.detached(priority: .background) { [weak self] in
            let verdict = DataSources.tradingDayVerdict()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.tradingDayRefreshInFlight = false
                switch verdict {
                case .trading: self.tradingDayCache = (day, true, Date())
                case .closed: self.tradingDayCache = (day, false, Date())
                case .unknown: break
                }
            }
        }

    }



    // MARK: - 任务表

    private func rebuildTasks() {
        let times = ScheduleTimes.shared
        let newTasks = ScheduleCatalog.tasksInDisplayOrder.map { t -> Task in
            // ⚠ 取不到时刻时**回落出厂默认**、不丢任务：`defaults` 与注册表同源，
            //   正常不可能缺；真缺了（存量数据被外部改坏）丢任务的后果是"这个任务从此不再排、
            //   界面上连一格圆点都没有"，而按出厂时刻跑至少还是对的日期。
            let tm = times.time(of: t.id) ?? (t.hour, t.minute)
            return Task(id: t.id, hour: tm.hour, minute: tm.minute,
                        label: t.label, slot: RoundPlan.slot(forKey: t.id), suffix: t.suffix)
        }
        // 时间被改动的任务 → 重置当日状态。
        // 否则"把 14:00 改到 16:00"会继承旧状态（可能已是 missed/done）→ 改了时间却永远不跑。
        for t in newTasks {
            if let old = tasks.first(where: { $0.id == t.id }), old.minuteOfDay != t.minuteOfDay {
                states.removeValue(forKey: t.id)
            }
        }
        // 已从配置里消失的任务 → 清掉状态，避免 nextPending / allDone 算错
        let ids = Set(newTasks.map(\.id))
        states = states.filter { ids.contains($0.key) }
        tasks = newTasks
        saveStates()
    }

    // MARK: - 持久化
    //
    // 编解码本体在 `ScheduleStateCodec`（`SelectedCore`，纯函数、可单测）——
    // 这里只负责"从哪儿读、往哪儿写"。

    private static let statePrefix = "scheduleState_"

    private func loadStates() {
        let key = Self.statePrefix + Self.dateKey()
        if let loaded = ScheduleStateCodec.fromJSON(UserDefaults.standard.string(forKey: key)) {
            states = loaded
            return
        }
        // 升级当天：把旧版本的两套键迁移过来，否则"今天已经跑过的任务"会被重跑一遍
        // （旧键 `completedTasks_<date>` + `retryState_<date>` → 新状态表）
        states = Self.migrateLegacyState()
        if !states.isEmpty { saveStates() }
    }

    func saveStates() {
        guard let json = ScheduleStateCodec.toJSON(states) else { return }
        UserDefaults.standard.set(json, forKey: Self.statePrefix + Self.dateKey())
    }

    /// 旧版本的 `completedTasks_<date>` + `retryState_<date>` 两套键 → 新状态表
    private static func migrateLegacyState() -> [String: TaskRuntimeState] {
        let day = dateKey()
        let defaults = UserDefaults.standard
        let completed = defaults.stringArray(forKey: "completedTasks_\(day)") ?? []
        let p = defaults.dictionary(forKey: "retryState_\(day)") ?? [:]
        return ScheduleStateCodec.migrateLegacy(
            completed: completed,
            retryCounts: (p["retryCounts"] as? [String: Int]) ?? [:],
            failureMessages: (p["failureMessages"] as? [String: String]) ?? [:],
            lastFailureAt: (p["lastFailureAt"] as? [String: Double]) ?? [:])
    }

    // MARK: - 生命周期

    func start() {
        guard !started else { return }
        started = true
        installWakeObserver()
        tick(reason: "启动")
    }

    func stop() {
        started = false
        timer?.invalidate()
        timer = nil
        // ⚠ 一并取消在飞的后台任务（ScanRunner/WatchJudge 等分钟级任务），
        //   否则退出瞬间任务仍在写库，进程终止丢掉本轮结果。
        runningTask?.cancel()
        runningTask = nil
        // ⚠ `cancel()` 只是给 Task 打标记，任务执行体（全同步）读不到
        //   ⇒ 必须**额外**置位取消盒，Core 才会真的停下来。这一行才是「取消在飞任务」生效的地方。
        //   审查 #12：取消盒现在在 `execute()` 里**所有分支**统一创建并接线
        //   （原先只有轮次分支有，watch/compare/fundflow 等只能"标记了但停不下"）。
        inFlightCancelBox?.cancel()
        // 闭包式观察者必须显式移除（NSWorkspace.notificationCenter 会一直持有它）
        if let o = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(o)
            wakeObserver = nil
        }
        releaseActivity()
    }

    /// 监听系统唤醒：合盖过夜后醒来，立刻重算 —— 窗口内补跑，超窗显式记错过。
    /// 这是"不静默丢任务"的关键一步。
    private func installWakeObserver() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // queue: .main 保证在主队列执行；`assumeIsolated` 让它同步进入 MainActor
            // （用 `Task {}` 会晚一拍，而这里希望立刻重算并重挂定时器）
            MainActor.assumeIsolated {
                self?.tick(reason: "系统唤醒")
            }
        }
    }

    // MARK: - 主循环（单次定时器，精确挂到下次触发时刻）

    /// 一次调度评估：读状态 → 问引擎 → 应用（标记错过 / 启动任务）→ 重挂定时器。
    ///
    /// - Parameter reason: 触发来源（启动 / 定时器 / 系统唤醒 / 配置变更 / 任务结束），
    ///   仅用于诊断输出 —— 排查"任务为什么没跑"时这一行很关键。
    func tick(reason: String = "定时器") {
        rolloverIfNeeded()

        let now = Date()
        // 交易日判定离主线程刷新（首次/跨日/false 满 60 秒才会真发请求）
        refreshTradingDayCache(now: now)
        guard schedulerEnabled else {

            nextRunAt = nil
            armTimer(nextFire: nil, now: now)
            updateActivity(now: now)
            return
        }

        let ctx = context(now: now)
        let plan = ScheduleEngine.decide(now: now, day: now, tasks: taskSpecs,
                                         states: states, policy: Self.policy, context: ctx)

        // 先落 missed（不碰数据库），再启动任务
        if !plan.missed.isEmpty {
            applyMissed(plan.missed, now: now, reason: reason)
        }
        if let id = plan.run, let task = tasks.first(where: { $0.id == id }) {
            execute(task)
        }

        // ⚠ 必须在应用 missed **之后**算下次唤醒，否则会把已经决定错过的任务再算一次候选
        let after = Date()
        let next = ScheduleEngine.nextFire(now: after, day: after, tasks: taskSpecs,
                                           states: states, policy: Self.policy,
                                           context: context(now: after))
        nextRunAt = next
        armTimer(nextFire: next, now: after)
        updateActivity(now: after)
    }

    private func rolloverIfNeeded() {
        let key = Self.dateKey()
        guard key != currentDateKey else { return }
        settleMissedBeforeRollover(oldKey: currentDateKey)
        currentDateKey = key
        states = [:]
        nextRunAt = nil
        saveStates()
        pruneStaleStateKeys(keepFrom: key)
        NSLog("[NOTICE] [Scheduler] 跨日，调度状态已重置（%@）", key)
    }

    /// 跨日清零前把昨日仍在场的任务落 missed（2026-11-09 审查 #5）：合盖过夜时引擎
    /// 没机会评估昨日，直接清空会让「未执行」无声消失（文档承诺超窗显式记录并通知）。
    /// 只评估**已有非终态状态**的任务：无状态条目 = 昨日非交易日/调度未开，本就没有任务在场，
    /// 不能补假 missed。状态此刻仍挂在昨日键下，`applyMissed` 的 saveStates 正好落回昨日。
    private func settleMissedBeforeRollover(oldKey: String) {
        let inPlay = states.filter { !$0.value.isTerminal }
        guard !inPlay.isEmpty, let day = ChinaTime.dayFormatter.date(from: oldKey) else { return }
        let now = Date()
        let plan = ScheduleEngine.decide(now: now, day: day, tasks: taskSpecs, states: states,
                                         policy: Self.policy,
                                         context: ScheduleContext(running: runningTaskId))
        let missed = plan.missed.filter { inPlay[$0.id] != nil }
        guard !missed.isEmpty else { return }
        applyMissed(missed, now: now, reason: "跨日", notifyDay: day)
    }

    /// 回收**按日**的调度状态键（审查 B6/B5-16）。
    ///
    /// ⚠ 为什么必须回收：这些键只写不删 —— 每天新增 1 个 `scheduleState_<date>`
    ///   （外加历史遗留的 `completedTasks_<date>` / `retryState_<date>`），
    ///   一年 365 个键，周末与节假日也照写。而 `SelectedApp.swift` 的启动前置
    ///   会 `enumerate(dictionaryRepresentation())`，`ScheduleTimes`/`AppearanceStore`
    ///   也各自读一遍 ⇒ 偏好文件与启动成本只增不减（纯泄漏：不会崩，只是越来越慢、
    ///   越来越难看清"到底存了什么"）。
    /// 读侧只用**当日**键（`loadStates` / `migrateLegacyState` 都只拼今天的日期），
    /// 所以回收是安全的；仍保留 7 天缓冲，防未来出现"回看昨天状态"的用法。
    private func pruneStaleStateKeys(keepFrom today: String) {
        let cutoff = ChinaTime.shiftDays(today, -7) ?? today
        let defaults = UserDefaults.standard
        let prefixes = [Self.statePrefix, "completedTasks_", "retryState_"]
        var removed = 0
        for name in defaults.dictionaryRepresentation().keys {
            guard let pre = prefixes.first(where: { name.hasPrefix($0) }) else { continue }
            let day = String(name.dropFirst(pre.count))
            guard day.count == 10 else { continue }      // yyyy-MM-dd
            // yyyy-MM-dd 的字符串序就是时间序
            if day < cutoff {
                defaults.removeObject(forKey: name)
                removed += 1
            }
        }


        if removed > 0 { NSLog("[NOTICE] [Scheduler] 回收过期调度状态键 %d 个（早于 %@）", removed, cutoff) }
    }


    private func armTimer(nextFire: Date?, now: Date) {
        timer?.invalidate()
        timer = nil
        guard started, schedulerEnabled else { return }

        let delay = ScheduleEngine.sleepSeconds(now: now, nextFire: nextFire, policy: Self.policy)
        let t = Timer(timeInterval: max(0.05, delay), repeats: false) { [weak self] _ in
            Swift.Task { @MainActor in self?.tick(reason: "定时器") }
        }
        // ⚠ 单次定时器同样默认注册在 default 模式，而滚动/拖拽/菜单跟踪跑在
        // `NSEventTrackingRunLoopMode` —— 必须显式加到 `.common`。
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func applyMissed(_ missed: [MissedTask], now: Date, reason: String, notifyDay: Date? = nil) {
        var notify: [String] = []
        for m in missed {
            var st = states[m.id] ?? TaskRuntimeState()
            st.status = .missed
            st.message = m.reason
            st.changedAt = now
            states[m.id] = st

            let label = tasks.first { $0.id == m.id }?.label ?? m.id
            NSLog("[NOTICE] [Scheduler] 任务未执行（%@）：%@ —— %@", reason, label, m.reason)
            // notifyDay：跨日补录时窗口要按**昨日**算（按今日算则窗口在未来，判定恒真）
            if let spec = tasks.first(where: { $0.id == m.id })?.spec,
               ScheduleEngine.shouldNotifyMissed(spec, on: notifyDay ?? now, policy: Self.policy,
                                                 sessionStartedAt: sessionStartedAt) {
                notify.append("\(label)：\(m.reason)")
            }
        }
        saveStates()
        lastScheduleNote = missed.map { m in
            (tasks.first { $0.id == m.id }?.label ?? m.id) + " " + m.reason
        }.joined(separator: "；")

        guard !notify.isEmpty else { return }
        // 聚合为一条通知：唤醒后一次可能跨过好几个窗口，逐条弹会刷屏
        let title = notify.count == 1 ? "有任务未执行" : "有 \(notify.count) 个任务未执行"
        // ⚠ 显式 id 带日期：**日内**重复触发仍是"替换"（保住防刷屏），跨天不互相覆盖
        //   （不带 id 会被 `Notifier` 回落成 `selected.\(title)` ⇒ 通知中心只留最新一天）。
        Notifier.shared.send(title: title, body: notify.joined(separator: "\n"),
                             identifier: "selected.sched.missed.\(ChinaTime.day())")
    }

    private func updateActivity(now: Date) {
        let hold = ScheduleEngine.shouldHoldActivity(
            now: now, day: now, tasks: taskSpecs, states: states,
            policy: Self.policy, context: context(now: now))
        if hold, activity == nil {
            // ⚠ 只用 `.userInitiated`（退出 App Nap），**不加** `.idleSystemSleepDisabled`
            // —— 后者会阻止系统睡眠，为一个选股工具付这个代价不值得。
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated],
                reason: "尾盘调度窗口内保持准时")
        } else if !hold {
            releaseActivity()
        }
    }

    private func releaseActivity() {
        if let a = activity {
            ProcessInfo.processInfo.endActivity(a)
            activity = nil
        }
    }
}

extension Notification.Name {
    static let engineTaskCompleted = Notification.Name("engineTaskCompleted")
}
