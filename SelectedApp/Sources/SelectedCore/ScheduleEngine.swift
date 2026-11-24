import Foundation

// MARK: - 调度决策（纯逻辑，可单测）
//
// 为什么把"该不该跑、什么时候唤醒"从 `Scheduler` 里抽出来：
// 决策、Timer、AppKit、持久化、任务执行揉在一个 `@MainActor` 类里就没有任何东西可以
// 离线验证，而这条链路恰好是"**静默失败**"的重灾区：
//   · Timer 注册在 default run loop 模式 → 滚动/拖拽/菜单跟踪期间不触发
//   · 补跑窗口有限 → 延迟跨过窗口后该任务当天不执行，若无显式终态就无日志无通知
//   · 没有唤醒补偿 → 合盖过夜后醒来，错过的任务只能靠补跑窗口兜
//
// 把决策抽成**纯函数**之后：
//   · 「到点启动 / 窗口内补跑 / 超窗标记错过 / 失败重试 / 下次唤醒时刻」全部可单测
//   · `Scheduler` 只剩"读状态 → 问引擎 → 执行 / 挂定时器 / 落盘"这点编排
//   · 唤醒补偿与定时器精度这两件事仍需真机观察，但**决策正确性不再依赖观察**
//
// ⚠ 本文件属于 `SelectedCore`：不许 import 任何 UI 框架，也不许持有 Timer / 状态。
//
// 两个入口的分工（刻意不合并成一个返回值）：
//   `decide(...)`    → 现在该做什么（启动哪个 / 把哪些标记为错过）
//   `nextFire(...)`  → 下一次该在什么时刻醒来
// 调用方必须**先应用 `decide` 的结果、再调 `nextFire`**；否则算出的唤醒时刻
// 会基于"还没标记错过"的旧状态，多醒一次。分成两个函数是为了让这个顺序显式可见。

/// 任务当日状态。
///
/// `missed` 是**显式**终态："超出补跑窗口"不能悄悄不跑（UI 永远停在"待执行"、
/// 无任何通知）—— 必须记下来、让用户看见。
public enum ScheduleStatus: String, Sendable, Equatable, CaseIterable {
    case pending
    case done
    case failed
    case missed

    /// 当日不会再变化的状态（`pending` / `failed` 仍可能推进）
    public var isTerminal: Bool { self == .done || self == .missed }
}

/// 任务规格：只保留决策需要的两样东西（时间与 id）
public struct ScheduleTaskSpec: Sendable, Equatable {
    public let id: String
    /// 计划时刻（北京时间当日分钟数，0..1439）
    public let minuteOfDay: Int

    public init(id: String, minuteOfDay: Int) {
        self.id = id
        self.minuteOfDay = minuteOfDay
    }
}

/// 任务运行期状态（**可持久化**：全部是值类型 + 可编码的基本类型）
public struct TaskRuntimeState: Sendable, Equatable {
    public var status: ScheduleStatus
    /// 已尝试次数（含首次）
    public var attempts: Int
    /// 最近一次失败时刻（算重试间隔）
    public var lastFailureAt: Date?
    /// 终态的说明文字（错过原因 / 放弃原因），供 UI 悬停展示
    public var message: String?
    /// 状态最近一次变更时刻（完成/错过）
    public var changedAt: Date?

    public init(status: ScheduleStatus = .pending, attempts: Int = 0,
                lastFailureAt: Date? = nil, message: String? = nil, changedAt: Date? = nil) {
        self.status = status
        self.attempts = attempts
        self.lastFailureAt = lastFailureAt
        self.message = message
        self.changedAt = changedAt
    }

    public var isTerminal: Bool { status.isTerminal }
}

/// 调度策略
public struct SchedulePolicy: Sendable, Equatable {
    /// 补跑窗口：计划时刻之后多久之内仍可执行（分钟）。
    /// 不能无限大 —— 这些任务取的是**实时行情**，收盘后补跑等于扫到一份错的数据。
    public var catchUpMinutes: Int
    /// 失败后重试间隔（秒）
    public var retryIntervalSeconds: Int
    /// 单任务最大尝试次数（含首次）
    public var maxAttempts: Int
    /// 单次定时器最长睡眠（秒）。不是"轮询间隔"：定时器**精确**挂到 `nextFire`，
    /// 只有当下次触发还早于该上限时才用它兜底（系统时钟被校正、配置被外部改动时自愈）。
    public var maxSleepSeconds: Int
    /// 已到点但暂不能启动（有任务在跑 / 手动写操作占用）时的重新评估间隔（秒）
    public var busyRetrySeconds: Int
    /// App Nap 活跃区间相对首个任务的提前量（秒）
    public var activityLeadSeconds: Int

    public init(catchUpMinutes: Int = 25, retryIntervalSeconds: Int = 120,
                maxAttempts: Int = 3, maxSleepSeconds: Int = 300,
                busyRetrySeconds: Int = 20, activityLeadSeconds: Int = 300) {
        self.catchUpMinutes = catchUpMinutes
        self.retryIntervalSeconds = retryIntervalSeconds
        self.maxAttempts = maxAttempts
        self.maxSleepSeconds = maxSleepSeconds
        self.busyRetrySeconds = busyRetrySeconds
        self.activityLeadSeconds = activityLeadSeconds
    }
}

/// 一次决策的输入上下文（把"能不能跑"的四件事打包，避免两个入口参数列表漂移）
public struct ScheduleContext: Sendable, Equatable {
    /// 用户在设置里是否开启了调度
    public var enabled: Bool
    /// 今天是不是交易日（周末/休市日不调度）
    public var tradingDay: Bool
    /// 本调度器**正在执行**的任务 id。执行期间不动它的状态
    /// （否则任务跑着跑着窗口关闭，会被自己标记成"错过"）
    public var running: String?
    /// 有**手动写操作**占用（`Store.hasBusyWriteCommand`）。此时不启动新任务，
    /// 但仍会计算错过 —— 标记错过不碰数据库，不必等
    public var busy: Bool

    public init(enabled: Bool = true, tradingDay: Bool = true,
                running: String? = nil, busy: Bool = false) {
        self.enabled = enabled
        self.tradingDay = tradingDay
        self.running = running
        self.busy = busy
    }
}

/// 一次"错过"的记录（任务当天不会再有数据产出）
public struct MissedTask: Sendable, Equatable {
    public let id: String
    public let reason: String

    public init(id: String, reason: String) {
        self.id = id
        self.reason = reason
    }
}

/// 引擎给出的行动方案
public struct SchedulePlan: Sendable, Equatable {
    /// 至多启动一个任务（重试优先于新任务）
    public let run: String?
    /// 本次要标记为错过的任务（可多个：唤醒后可能一次跨过好几个窗口）
    public let missed: [MissedTask]

    public init(run: String? = nil, missed: [MissedTask] = []) {
        self.run = run
        self.missed = missed
    }

    public var isEmpty: Bool { run == nil && missed.isEmpty }
}

public enum ScheduleEngine {

    // MARK: - 时刻换算

    /// 计划时刻在指定自然日的绝对时间
    public static func dueDate(_ spec: ScheduleTaskSpec, on day: Date,
                               calendar: Calendar = ChinaTime.calendar) -> Date {
        let start = calendar.startOfDay(for: day)
        return calendar.date(byAdding: .minute, value: spec.minuteOfDay, to: start) ?? start
    }

    /// 1430 → "14:30"
    public static func hhmm(_ minuteOfDay: Int) -> String {
        String(format: "%02d:%02d", minuteOfDay / 60, minuteOfDay % 60)
    }

    // MARK: - 处境判定（`decide` 与 `nextFire` 的**唯一**依据）
    //
    // 两份逻辑各判一次是这类代码最容易出的 bug：`decide` 认为"该跑"、`nextFire` 却不安排唤醒，
    // 任务就一直等不到人来跑。抽成同一套判定后不可能不一致。
    enum Disposition: Equatable {
        case terminal                    // done / missed
        case notDue(due: Date)           // 还没到点
        case runnable(due: Date)         // 到点、在窗口内、可以执行（含重试就绪）
        case retryWaiting(due: Date, retryAt: Date)   // 到点、但在等重试间隔
        case exhausted(due: Date)        // 到点、重试次数耗尽 → 待标记错过
        case outOfWindow(due: Date)      // 到点但已超窗口 → 待标记错过
    }

    /// 盘中任务的补跑上界收回到**当段收盘**。
    ///
    /// - Returns: 需要收窄时返回收窄后的时刻；不在盘中（收盘后任务）或本就没越过 ⇒ nil。
    static func capWindowToSession(dueMinuteOfDay: Int, close: Date, due: Date,
                                   calendar: Calendar) -> Date? {
        // 只看"计划时刻落在哪一段交易时段里"（时段定义全项目只有一份）
        guard let range = AlertWindow.sessionRanges.first(where: { $0.contains(dueMinuteOfDay) }),
              range.upperBound > dueMinuteOfDay else { return nil }
        let cal = calendar
        var comps = cal.dateComponents([.year, .month, .day], from: due)
        comps.hour = range.upperBound / 60
        comps.minute = range.upperBound % 60
        guard let sessionEnd = cal.date(from: comps) else { return nil }
        return close > sessionEnd ? sessionEnd : nil
    }

    /// 任务当日补跑窗口的**实际**关闭时刻（单一事实来源，审查 #18）：
    /// 收盘后任务 = 计划时刻 + `catchUpMinutes`；盘中任务收回到**当段收盘**。
    ///
    /// ⚠ 盘中任务的补跑窗口**不得越过当段收盘**（2026-10-16 审查 B5-15）：
    ///   三轮定在 14:00/14:30/14:50，统一 25 分钟窗口 ⇒ 第三轮最迟可在 **15:15** 自动补跑。
    ///   而 14:57–15:00 是收盘集合竞价：那一轮扫的是**已定稿收盘价**，
    ///   同一天的第 1/2 轮是**盘中价** —— 三轮对比的"持续信号"取交集时
    ///   混进两种口径，库里又留不下痕迹（`Scheduler` 那边的 slot3 例外是
    ///   **手动**补跑的刻意设计，不是自动重用来**说服自己的理由）。
    ///   另外 `EngineIndicators.elapsedMinutesAt` 在 ≥15:00 恒返回 240，
    ///   量比归一化 (`volMultNormalize`) 会**只在这一轮**静默失效。
    ///   收盘边界只有 `AlertWindow.sessionRanges` 一份，这里不重写。
    ///
    /// ⚠ `Scheduler.markRetry` 的窗口判定也必须走这里（审查 #18）：原先它用**未截断**的
    ///   `dueDate + catchUpMinutes`，第三轮 15:00 后失败时被判"窗口未过"、通知承诺
    ///   "将自动重试"，而引擎下一次评估即 `outOfWindow` → 永不重试（谎报）。
    public static func effectiveWindowClose(_ spec: ScheduleTaskSpec, on day: Date,
                                            policy: SchedulePolicy,
                                            calendar: Calendar = ChinaTime.calendar) -> Date {
        let due = dueDate(spec, on: day, calendar: calendar)
        let close = due.addingTimeInterval(Double(policy.catchUpMinutes) * 60)
        return capWindowToSession(dueMinuteOfDay: spec.minuteOfDay, close: close,
                                  due: due, calendar: calendar) ?? close
    }

    static func disposition(_ spec: ScheduleTaskSpec, states: [String: TaskRuntimeState],

                            now: Date, day: Date, policy: SchedulePolicy,
                            calendar: Calendar) -> Disposition {
        let st = states[spec.id] ?? TaskRuntimeState()
        if st.isTerminal { return .terminal }

        let due = dueDate(spec, on: day, calendar: calendar)
        if now < due { return .notDue(due: due) }

        // 窗口口径唯一事实来源：`effectiveWindowClose`（含盘中截窗，审查 #18 统一）
        if now > effectiveWindowClose(spec, on: day, policy: policy, calendar: calendar) {
            return .outOfWindow(due: due)
        }


        if st.status == .failed {
            if st.attempts >= policy.maxAttempts { return .exhausted(due: due) }
            // 失败时刻缺失（老版本残留状态 / 外部清掉了）→ 视为已过间隔，
            // 不因为"算不出间隔"就永久放弃重试。
            if let f = st.lastFailureAt {
                let retryAt = f.addingTimeInterval(Double(policy.retryIntervalSeconds))
                if retryAt > now { return .retryWaiting(due: due, retryAt: retryAt) }
            }
        }
        return .runnable(due: due)
    }

    // MARK: - 现在该做什么

    public static func decide(now: Date, day: Date, tasks: [ScheduleTaskSpec],
                              states: [String: TaskRuntimeState], policy: SchedulePolicy,
                              context: ScheduleContext = ScheduleContext(),
                              calendar: Calendar = ChinaTime.calendar) -> SchedulePlan {
        guard context.enabled, context.tradingDay else { return SchedulePlan() }

        let ordered = tasks.sorted { ($0.minuteOfDay, $0.id) < ($1.minuteOfDay, $1.id) }
        var missed: [MissedTask] = []
        var runnable: [(spec: ScheduleTaskSpec, isRetry: Bool)] = []

        for spec in ordered {
            if spec.id == context.running { continue }      // 正在跑：状态归 finish 管
            switch disposition(spec, states: states, now: now, day: day,
                               policy: policy, calendar: calendar) {
            case .terminal, .notDue, .retryWaiting:
                continue
            case .outOfWindow:
                missed.append(MissedTask(
                    id: spec.id,
                    reason: "超出补跑窗口未执行（计划 \(hhmm(spec.minuteOfDay))，"
                          + "窗口 \(policy.catchUpMinutes) 分钟）"))
            case .exhausted:
                let attempts = states[spec.id]?.attempts ?? policy.maxAttempts
                missed.append(MissedTask(
                    id: spec.id,
                    reason: "已重试 \(max(0, attempts - 1)) 次仍失败，当日不再自动重试"))
            case .runnable:
                runnable.append((spec, states[spec.id]?.status == .failed))
            }
        }

        let canStart = (context.running == nil) && !context.busy
        let chosen = canStart ? (runnable.first(where: { $0.isRetry }) ?? runnable.first) : nil
        return SchedulePlan(run: chosen?.spec.id, missed: missed)
    }

    // MARK: - 下一次该在什么时刻醒来

    /// 四类候选（取最早）：
    ///   1. 未到点的任务 → 它的计划时刻（**精确启动**，不再靠轮询碰运气）
    ///   2. 到点、可执行 → `now + busyRetrySeconds` 重新评估（通常紧接着就会被启动）
    ///   3. 到点、正在等重试 → 重试时刻（**不**产生 20s 轮询）
    ///   4. 任何未关闭窗口的**关闭时刻** → 到点即醒来标记错过
    ///      （这是"不再静默"的关键：不唤醒就没人去写那条 missed 记录）
    ///
    /// ⚠ 必须在应用 `decide` 的 `missed` **之后**调用，否则会把已经决定错过的任务
    /// 再算一次候选。
    public static func nextFire(now: Date, day: Date, tasks: [ScheduleTaskSpec],
                                states: [String: TaskRuntimeState], policy: SchedulePolicy,
                                context: ScheduleContext = ScheduleContext(),
                                calendar: Calendar = ChinaTime.calendar) -> Date? {
        guard context.enabled, context.tradingDay else { return nil }

        var candidates: [Date] = []
        let busyAt = now.addingTimeInterval(Double(policy.busyRetrySeconds))

        for spec in tasks {
            if spec.id == context.running { continue }
            switch disposition(spec, states: states, now: now, day: day,
                               policy: policy, calendar: calendar) {
            case .terminal, .outOfWindow, .exhausted:
                break
            case .notDue(let due):
                candidates.append(due)
            case .runnable:
                candidates.append(busyAt)
            case .retryWaiting(_, let retryAt):
                candidates.append(retryAt)
            }
            // 窗口关闭时刻：只要还没关，就安排一次唤醒去落 missed 记录
            let close = effectiveWindowClose(spec, on: day, policy: policy, calendar: calendar)
            if close > now { candidates.append(close.addingTimeInterval(1)) }
        }

        return candidates.min()
    }

    /// 定时器本次应当睡多久：精确挂到 `nextFire`，但不超过 `maxSleepSeconds`。
    ///
    /// 上限的作用不是"轮询"，而是**自愈**：系统时钟被 NTP 校正、时区变化、
    /// `ScheduleTimes` 被外部改写等情况下，长睡眠会整体偏掉；有上限最多偏 5 分钟。
    public static func sleepSeconds(now: Date, nextFire: Date?,
                                    policy: SchedulePolicy) -> TimeInterval {
        let cap = Double(policy.maxSleepSeconds)
        guard let next = nextFire else { return cap }
        let delta = next.timeIntervalSince(now)
        if delta <= 0 { return 0.05 }          // 已经该醒了（避免 0 间隔忙转）
        return min(delta, cap)
    }

    /// 这次"错过"是否值得打扰用户。
    ///
    /// 判据：**App 在窗口关闭之前就已经在运行** → 说明是我们的调度没兜住（定时器被 run loop
    /// 模式挡住、睡眠没补偿），必须弹通知让人知道。
    /// 反之（App 本来就是关着的，用户晚上才打开）→ 只记录、不弹通知 ——
    /// 否则每次开机都会被"历史欠账"刷屏，通知很快就没人看了。
    public static func shouldNotifyMissed(_ spec: ScheduleTaskSpec, on day: Date,
                                          policy: SchedulePolicy, sessionStartedAt: Date,
                                          calendar: Calendar = ChinaTime.calendar) -> Bool {
        let close = effectiveWindowClose(spec, on: day, policy: policy, calendar: calendar)
        return sessionStartedAt <= close
    }

    /// 是否需要在此期间阻止 App Nap（`ProcessInfo.beginActivity`）。
    /// 只在**当日确实还有待办、且当前处于调度活跃区间**时持有：
    /// 区间 = 首个未完成任务前 `activityLeadSeconds` 起，到最后一个任务的补跑窗口关闭为止。
    /// 区间之外（例如凌晨）不持有，避免整天占着电量。
    public static func shouldHoldActivity(now: Date, day: Date, tasks: [ScheduleTaskSpec],
                                          states: [String: TaskRuntimeState],
                                          policy: SchedulePolicy,
                                          context: ScheduleContext = ScheduleContext(),
                                          calendar: Calendar = ChinaTime.calendar) -> Bool {
        guard context.enabled, context.tradingDay else { return false }
        let open = tasks.filter { !(states[$0.id] ?? TaskRuntimeState()).isTerminal }
        guard !open.isEmpty else { return false }
        let dues = open.map { dueDate($0, on: day, calendar: calendar) }
        guard let first = dues.min(), let last = dues.max() else { return false }
        let from = first.addingTimeInterval(-Double(policy.activityLeadSeconds))
        let to = last.addingTimeInterval(Double(policy.catchUpMinutes) * 60)
        return now >= from && now <= to
    }
}

// MARK: - 轮次时间顺序

/// 「各轮扫描时间必须**依次递增**」这条约束的纯函数实现。
///
/// ⚠ **为什么必须挡**：`boundaries(...)` 取**相邻两轮的中点**
///   （`b1 = (r1+r2)/2`、`b2 = (r2+r3)/2`），而 `Screener.resolveSlot` 的判定是顺序比较：
///   `if t < b1 { 第1轮 }` / `if t < b2 { 第2轮 }` / `else { 第3轮 }`。
///
///   ⚠ 倒挂的后果分两档（**判据是 `b1 > b2` ⟺ `r1 > r3`，不是 `r1 > r2`**）：
///
///   | 情形 | 边界 | 后果 |
///   |---|---|---|
///   | `r1 > r2` 但 `r1 < r3`（部分倒挂） | `b1 < b2`，**仍递增** | 边界语义错乱：**第 1 轮自己的触发时刻会落进第 3 轮**。例：`r1=14:50, r2=14:30, r3=15:00` → `b1=14:40, b2=14:45` → 14:50 触发的那轮被记成 **slot 3** |
///   | `r1 > r3`（严重倒挂） | `b1 > b2` | **第 2 轮分支不可达**：`t < b2` 在 `t >= b1 > b2` 下永远为假 → "第二轮永远选不出票" |
///
///   两种都**不报错、界面上看不出来**。而"依次递增"是能同时挡住这两者的**最小约束**。
///   按本项目纪律（**要挡就做成阻断性错误，不要只告警**），
///   调用方拿到非 `nil` 时必须**拒绝写入**。
///
/// ⚠ **为什么放在 `SelectedCore` 而不是 `ScheduleTimes`（App 层）**：
///   `Tests/SelectedCoreTests` 只依赖 `SelectedCore` —— App 层的类型**结构上无法**被
///   `swift test` 覆盖，而这条约束恰恰是"删掉不会变红"的那一类。
///   按本项目纪律：**纯计算进 Core**，视图/App 层只负责调它。
///
/// ⚠ **入参是数组、不是 `round1/round2/round3` 三个形参**（审查 B8-1 第二片）：
///   arity-3 的签名等于把"几轮"又写死一次 —— `RoundPlan` 加到 4 轮后，
///   这里只校验前 3 轮，第 4 轮的时刻**非法也不报错**。数组按 `RoundPlan.slots` 同序传入即可。
public enum RoundOrder {

    /// - Parameter minutes: 各轮的**当日分钟数**（与 `RoundPlan.slots` 同序）；
    ///   任一为 `nil`（该键缺失）→ 无从判定 → 返回 `nil`（不误报）
    /// - Returns: `nil` = 合法；否则返回**用户可读**的原因（调用方应拒绝写入）
    public static func error(minutes: [Int?]) -> String? {
        guard let m = all(minutes) else { return nil }
        guard m.count >= 2 else { return nil }
        guard zip(m, m.dropFirst()).allSatisfy({ pair in pair.0 < pair.1 }) else {
            let detail = m.enumerated()
                .map { "第\($0.offset + 1)轮 \(hhmm($0.element))" }
                .joined(separator: " / ")
            return "\(RoundPlan.cn(m.count))轮扫描时间必须依次递增（当前 \(detail)）"
                + " —— 顺序倒挂会让某几轮的轮次归属不可达，那些轮永远选不出票"
        }
        return nil
    }

    /// 缺键 → `nil`（调用方据此不误报）；否则 compact 成升序分钟数数组
    private static func all(_ minutes: [Int?]) -> [Int]? {
        minutes.contains(where: { $0 == nil }) ? nil : minutes.compactMap { $0 }
    }

    /// 一天中的分钟数 → `"HH:mm"`
    public static func hhmm(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    /// 各轮时间 → 轮次归属边界（格式 `"HH:mm"`，**升序 `轮数-1` 个**）。
    ///
    /// `b[i] = (r[i] + r[i+1]) / 2`；任一键缺失（`nil`）→ `nil`。
    ///
    /// ⚠ 它**依赖各轮依次递增**（由 `error(...)` 在写入时保证）。倒挂的后果见 `RoundOrder` 的
    ///   类型注释 —— 关键判据是 **`b1 > b2` ⟺ `r1 > r3`**（不是 `r1 > r2`）：
    ///   · `r1 > r3` → `b1 > b2` → `Screener.resolveSlot` 的**第 2 轮分支不可达**；
    ///   · `r1 > r2` 但 `r1 < r3` → 边界仍递增，但**第 1 轮自己的触发时刻会落进第 3 轮**。
    public static func boundaries(minutes: [Int?]) -> [String]? {
        guard let m = all(minutes), m.count >= 2 else { return nil }
        return zip(m, m.dropFirst()).map { pair in hhmm((pair.0 + pair.1) / 2) }
    }

    /// 按「一天中的分钟数」**稳定**升序排（同刻保持传入顺序）。
    ///
    /// ⚠ 为什么放在这里：它与 ``hhmm(_:)`` / ``boundaries(minutes:)`` 同属
    ///   「调度时刻的纯计算」—— 只有放在 Core 才能被 `swift test` 覆盖
    ///   （`ScheduleTimes` 在 App 层，`Tests/SelectedCoreTests` 结构上看不到它）。
    ///
    /// ⚠ 为什么必须**稳定**：调度项里 `round3` 与 `watch` 默认**同为 14:50**。
    ///   `Swift.sorted` **不保证稳定** → 这两格每次重排都可能换位，用户会以为自己的设置被改了。
    ///   所以这里显式用 `enumerated()` 的下标做并列时的次序键。
    public static func sortedByMinuteOfDay<T>(_ items: [T], _ minuteOfDay: (T) -> Int) -> [T] {
        items.enumerated()
            .sorted { a, b in
                let (x, y) = (minuteOfDay(a.element), minuteOfDay(b.element))
                return x == y ? a.offset < b.offset : x < y
            }
            .map(\.element)
    }
}
