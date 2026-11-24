import XCTest
@testable import SelectedCore

/// `ScheduleEngine` —— 调度决策的纯逻辑。
///
/// 决策、Timer、AppKit、持久化揉在一个 `@MainActor` 类里时，验收只能
/// "跑 2–3 个交易日看有没有漏跑"。抽出纯函数后，下面每一条"静默失败"
/// 路径都变成了可离线复现的断言：
///   · 到点精确启动（不再靠 30s 轮询碰运气）
///   · 窗口内补跑 / 超窗**显式标记错过**（不再悄悄不跑）
///   · 唤醒补偿一次跨过多个窗口时，每个都留下 missed 记录
///   · 失败重试优先于新任务、重试耗尽转错过
///   · 有任务在跑 / 手动写操作占用时不误伤、也不忘记下一次唤醒
///
/// 时区基准：全部走 `ChinaTime.calendar`（Asia/Shanghai），与生产一致。
/// 2026-09-21 是**周一**。
final class ScheduleEngineTests: XCTestCase {

    private let policy = SchedulePolicy(catchUpMinutes: 25, retryIntervalSeconds: 120,
                                        maxAttempts: 3, maxSleepSeconds: 300,
                                        busyRetrySeconds: 20, activityLeadSeconds: 300)

    // MARK: - 夹具

    private func at(_ h: Int, _ m: Int, _ s: Int = 0) -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 9; c.day = 21; c.hour = h; c.minute = m; c.second = s
        return ChinaTime.calendar.date(from: c)!
    }

    private var day: Date { at(0, 0) }

    private func spec(_ id: String, _ h: Int, _ m: Int) -> ScheduleTaskSpec {
        ScheduleTaskSpec(id: id, minuteOfDay: h * 60 + m)
    }

    private func ctx(enabled: Bool = true, tradingDay: Bool = true,
                     running: String? = nil, busy: Bool = false) -> ScheduleContext {
        ScheduleContext(enabled: enabled, tradingDay: tradingDay, running: running, busy: busy)
    }

    private func decide(_ now: Date, _ tasks: [ScheduleTaskSpec],
                        states: [String: TaskRuntimeState] = [:],
                        _ c: ScheduleContext = ScheduleContext()) -> SchedulePlan {
        ScheduleEngine.decide(now: now, day: day, tasks: tasks, states: states,
                              policy: policy, context: c)
    }

    private func next(_ now: Date, _ tasks: [ScheduleTaskSpec],
                      states: [String: TaskRuntimeState] = [:],
                      _ c: ScheduleContext = ScheduleContext()) -> Date? {
        ScheduleEngine.nextFire(now: now, day: day, tasks: tasks, states: states,
                                policy: policy, context: c)
    }

    // MARK: - 到点精确启动

    func testDoesNothingBeforeScheduledMinute() {
        let p = decide(at(9, 0), [spec("predict", 9, 30)])
        XCTAssertNil(p.run)
        XCTAssertTrue(p.missed.isEmpty)
        XCTAssertEqual(next(at(9, 0), [spec("predict", 9, 30)]), at(9, 30),
                       "应精确挂到计划时刻，而不是等下一个轮询点")
    }

    func testFiresExactlyAtScheduledMinute() {
        let p = decide(at(9, 30), [spec("predict", 9, 30)])
        XCTAssertEqual(p.run, "predict")
        XCTAssertTrue(p.missed.isEmpty)
    }

    func testDoesNotFireOneSecondEarly() {
        XCTAssertNil(decide(at(9, 29, 59), [spec("predict", 9, 30)]).run)
        XCTAssertEqual(next(at(9, 29, 59), [spec("predict", 9, 30)]), at(9, 30))
    }

    // MARK: - 补跑窗口

    func testRunsInsideCatchUpWindow() {
        let p = decide(at(9, 50), [spec("predict", 9, 30)])   // 迟 20 分钟，窗口 25
        XCTAssertEqual(p.run, "predict")
        XCTAssertTrue(p.missed.isEmpty)
    }

    func testWindowBoundaryIsInclusive() {
        let p = decide(at(9, 55), [spec("predict", 9, 30)])   // 恰好 25 分钟
        XCTAssertEqual(p.run, "predict", "窗口边界应可执行（now > close 才算超窗）")
    }

    func testPastWindowIsMarkedMissedNotSilentlySkipped() {
        let p = decide(at(9, 55, 1), [spec("predict", 9, 30)])
        XCTAssertNil(p.run)
        XCTAssertEqual(p.missed.count, 1)
        XCTAssertEqual(p.missed.first?.id, "predict")
        XCTAssertTrue(p.missed.first?.reason.contains("超出补跑窗口") ?? false,
                      "错过必须带可展示的原因，实得：\(p.missed.first?.reason ?? "nil")")
        XCTAssertTrue(p.missed.first?.reason.contains("09:30") ?? false, "原因里应含计划时刻")
    }

    /// 关键：不唤醒就没人去写那条 missed 记录。所以窗口关闭时刻本身必须是唤醒候选。
    func testNextFireIncludesWindowCloseSoMissIsRecorded() {
        // 09:54:59 时若被占用（busy），最近的候选是"窗口关闭"（09:55:01）而不是 20s 之后
        let c = ctx(busy: true)
        XCTAssertEqual(next(at(9, 54, 59), [spec("predict", 9, 30)], c),
                       at(9, 55, 1))
        // 到点后确实会记录错过
        XCTAssertEqual(decide(at(9, 55, 1), [spec("predict", 9, 30)]).missed.count, 1)
    }

    // MARK: - 失败重试

    func testFailedTaskRetriesAfterInterval() {
        let st = ["predict": TaskRuntimeState(status: .failed, attempts: 1,
                                              lastFailureAt: at(13, 57))]
        // 13:57 + 120s = 13:59，14:00 已过间隔
        XCTAssertEqual(decide(at(14, 0), [spec("predict", 14, 0)], states: st).run, "predict")
    }

    func testFailedTaskWaitsForRetryInterval() {
        let st = ["predict": TaskRuntimeState(status: .failed, attempts: 1,
                                              lastFailureAt: at(14, 0, 30))]
        let tasks = [spec("predict", 14, 0)]
        XCTAssertNil(decide(at(14, 1), tasks, states: st).run)     // 只过了 30s
        XCTAssertEqual(next(at(14, 1), tasks, states: st), at(14, 2, 30),
                       "应精确挂到重试时刻（14:00:30 + 120s），而不是每 20s 空醒一次")
    }

    /// 失败时刻缺失（老版本残留状态 / 状态被外部清掉）→ 不因为"算不出间隔"就永久放弃
    func testFailedTaskWithoutTimestampIsRetriedImmediately() {
        let st = ["predict": TaskRuntimeState(status: .failed, attempts: 1, lastFailureAt: nil)]
        XCTAssertEqual(decide(at(14, 5), [spec("predict", 14, 0)], states: st).run, "predict")
    }

    func testRetryExhaustedBecomesMissed() {
        let st = ["predict": TaskRuntimeState(status: .failed, attempts: 3,
                                              lastFailureAt: at(13, 0))]
        let p = decide(at(14, 5), [spec("predict", 14, 0)], states: st)
        XCTAssertNil(p.run)
        XCTAssertEqual(p.missed.count, 1)
        XCTAssertTrue(p.missed.first?.reason.contains("已重试 2 次") ?? false,
                      "原因应说明重试次数，实得：\(p.missed.first?.reason ?? "nil")")
    }

    func testRetryTakesPriorityOverNewlyDueTask() {
        let st = ["round1": TaskRuntimeState(status: .failed, attempts: 1,
                                             lastFailureAt: at(14, 8))]
        let p = decide(at(14, 10),
                       [spec("round1", 14, 0), spec("round2", 14, 10)],
                       states: st)
        XCTAssertEqual(p.run, "round1", "失败重试不该被后面的新任务挤掉")
    }

    // MARK: - 互斥（串行执行）

    func testBusyBlocksStartButStillSchedulesReevaluation() {
        let c = ctx(busy: true)
        let tasks = [spec("round1", 14, 0)]
        XCTAssertNil(decide(at(14, 5), tasks, c).run, "手动写操作占用时不得并发启动")
        XCTAssertEqual(next(at(14, 5), tasks, c), at(14, 5, 20),
                       "但必须安排重新评估，不能睡死")
    }

    /// 调度器**串行**执行：同一时刻只允许一个任务（避免并发写库争用）。
    /// 这是**有意保留**的既有语义，不是缺陷 —— 用测试把它显式化。
    func testOnlyOneTaskRunsAtATime() {
        let c = ctx(running: "round1")
        let tasks = [spec("round2", 14, 30)]
        XCTAssertNil(decide(at(14, 32), tasks, c).run)
        XCTAssertEqual(next(at(14, 32), tasks, c), at(14, 32, 20),
                       "当前任务结束后应尽快重新评估（finish 也会重挂，这里是双保险）")
    }

    /// 任务执行期间窗口关闭 → 不能把它自己标记成"错过"
    func testRunningTaskIsNeverMarkedMissed() {
        let c = ctx(running: "round1")
        let tasks = [spec("round1", 14, 0)]
        let p = decide(at(15, 0), tasks, c)
        XCTAssertNil(p.run)
        XCTAssertTrue(p.missed.isEmpty, "正在跑的任务状态归 finish 管，不该被判错过")
        XCTAssertNil(next(at(15, 0), tasks, c), "running 任务不参与唤醒候选（finish 时会重挂）")
    }

    /// 但**其它**任务的错过判定不受影响
    func testOtherTasksAreStillMarkedMissedWhileOneRuns() {
        let c = ctx(running: "round1")
        let p = decide(at(15, 0), [spec("round1", 14, 0), spec("round2", 14, 30)], c)
        XCTAssertNil(p.run)
        XCTAssertEqual(p.missed.map(\.id), ["round2"])
    }

    // MARK: - 唤醒补偿（一次跨过多个窗口）

    func testWakeAfterLongSleepMarksEveryMissedWindow() {
        let tasks = [spec("predict", 9, 30), spec("verify", 10, 0),
                     spec("round1", 14, 0), spec("round2", 14, 30)]
        let p = decide(at(16, 0), tasks)        // 合盖一整天后醒来
        XCTAssertNil(p.run, "全部超窗，不该启动任何一个（实时行情已过期）")
        XCTAssertEqual(Set(p.missed.map(\.id)), ["predict", "verify", "round1", "round2"],
                       "每个错过的窗口都要留下记录，不能只报最后一个")
        XCTAssertNil(next(at(16, 0), tasks), "今天没有待办了")
    }

    func testWakeInsideWindowStillRuns() {
        XCTAssertEqual(decide(at(14, 20), [spec("round1", 14, 0)]).run, "round1",
                       "迟到 20 分钟仍在窗口内 → 补跑")
    }

    // MARK: - 终态与开关

    func testTerminalTasksAreSkipped() {
        let st = ["predict": TaskRuntimeState(status: .done, attempts: 1)]
        let tasks = [spec("predict", 9, 30)]
        let p = decide(at(10, 0), tasks, states: st)
        XCTAssertNil(p.run)
        XCTAssertTrue(p.missed.isEmpty)
        XCTAssertNil(next(at(10, 0), tasks, states: st))
    }

    func testMissedTaskIsNotRetried() {
        let st = ["predict": TaskRuntimeState(status: .missed, attempts: 1)]
        let tasks = [spec("predict", 9, 30)]
        XCTAssertTrue(decide(at(10, 0), tasks, states: st).isEmpty)
        XCTAssertNil(next(at(10, 0), tasks, states: st))
    }

    func testDisabledSchedulerDoesNothing() {
        let c = ctx(enabled: false)
        let tasks = [spec("round1", 14, 0)]
        XCTAssertTrue(decide(at(14, 5), tasks, c).isEmpty)
        XCTAssertNil(next(at(14, 5), tasks, c), "停用时不得安排唤醒（否则整天空醒）")
    }

    func testNonTradingDayDoesNothing() {
        let c = ctx(tradingDay: false)
        let tasks = [spec("round1", 14, 0)]
        let p = decide(at(14, 5), tasks, c)
        XCTAssertTrue(p.isEmpty)
        XCTAssertNil(next(at(14, 5), tasks, c))
        XCTAssertTrue(p.missed.isEmpty, "休市日不该把任务记成错过（不是漏跑，是本来就不跑）")
    }

    // MARK: - 定时器睡眠时长

    func testSleepSecondsIsExactWhenCloseAndCappedWhenFar() {
        XCTAssertEqual(ScheduleEngine.sleepSeconds(now: at(9, 0), nextFire: at(9, 0, 30),
                                                   policy: policy), 30, accuracy: 0.01)
        XCTAssertEqual(ScheduleEngine.sleepSeconds(now: at(9, 0), nextFire: at(14, 0),
                                                   policy: policy), 300, accuracy: 0.01,
                       "远期目标用上限兜底（时钟校正/配置外部改动的自愈）")
        XCTAssertEqual(ScheduleEngine.sleepSeconds(now: at(9, 0), nextFire: nil,
                                                   policy: policy), 300, accuracy: 0.01)
        XCTAssertLessThanOrEqual(ScheduleEngine.sleepSeconds(now: at(9, 0), nextFire: at(8, 59),
                                                             policy: policy), 0.06,
                                 "已过时刻不得返回 0（会变成忙转）")
    }

    // MARK: - App Nap 活跃区间

    func testHoldActivityOnlyInsideActiveWindow() {
        let tasks = [spec("predict", 9, 30), spec("iterate", 15, 30)]
        func hold(_ h: Int, _ m: Int, _ states: [String: TaskRuntimeState] = [:]) -> Bool {
            ScheduleEngine.shouldHoldActivity(now: at(h, m), day: day, tasks: tasks,
                                              states: states, policy: policy)
        }
        XCTAssertFalse(hold(8, 0), "区间外不持有（省电）")
        XCTAssertTrue(hold(9, 26), "首个任务前 5 分钟起持有")
        XCTAssertTrue(hold(12, 0), "区间内持续持有")
        XCTAssertTrue(hold(15, 54), "最后一个任务的补跑窗口关闭前仍持有")
        XCTAssertFalse(hold(15, 56), "最后一个窗口关闭后释放")
    }

    func testHoldActivityReleasedWhenAllTerminalOrOff() {
        let tasks = [spec("predict", 9, 30)]
        let done = ["predict": TaskRuntimeState(status: .done)]
        func hold(_ c: ScheduleContext, _ states: [String: TaskRuntimeState]) -> Bool {
            ScheduleEngine.shouldHoldActivity(now: at(9, 40), day: day, tasks: tasks,
                                              states: states, policy: policy, context: c)
        }
        XCTAssertFalse(hold(ScheduleContext(), done), "全部完成 → 释放")
        XCTAssertFalse(hold(ScheduleContext(enabled: false), [:]))
        XCTAssertFalse(hold(ScheduleContext(tradingDay: false), [:]))
    }

    // MARK: - 通知抑制（避免"历史欠账"刷屏）

    func testNotifyMissedOnlyWhenAppWasAlreadyRunning() {
        let s = spec("predict", 9, 30)      // 窗口 09:30 ~ 09:55
        // App 在窗口关闭前就在跑 → 是我们的调度没兜住，必须通知
        XCTAssertTrue(ScheduleEngine.shouldNotifyMissed(s, on: day, policy: policy,
                                                        sessionStartedAt: at(8, 0)))
        XCTAssertTrue(ScheduleEngine.shouldNotifyMissed(s, on: day, policy: policy,
                                                        sessionStartedAt: at(9, 55)))
        // App 是关着的，用户晚上才打开 → 只记录不打扰
        XCTAssertFalse(ScheduleEngine.shouldNotifyMissed(s, on: day, policy: policy,
                                                         sessionStartedAt: at(20, 0)))
        XCTAssertFalse(ScheduleEngine.shouldNotifyMissed(s, on: day, policy: policy,
                                                         sessionStartedAt: at(9, 55, 1)))
    }

    // MARK: - 换算

    func testDueDateAndFormatting() {
        XCTAssertEqual(ScheduleEngine.hhmm(0), "00:00")
        XCTAssertEqual(ScheduleEngine.hhmm(9 * 60 + 5), "09:05")
        XCTAssertEqual(ScheduleEngine.hhmm(14 * 60 + 50), "14:50")
        XCTAssertEqual(ScheduleEngine.dueDate(spec("x", 14, 50), on: day), at(14, 50))
        XCTAssertEqual(ScheduleEngine.dueDate(spec("x", 0, 0), on: day), day)
    }
}
