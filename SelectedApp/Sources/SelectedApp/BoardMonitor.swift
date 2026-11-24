import Foundation
import AppKit
import SelectedCore

/// 板块行情的**盘中后台刷新**（每 5 分钟，交易日 09:00–16:00）。
///
/// ## 为什么单独一个轮询器，而不是塞进 `Scheduler`
/// `Scheduler` 是"**每天固定时刻**"模型（任务表 + `ScheduleTimes`）——加间隔任务要改模型、
/// 还要同步 `sched_timer` 护栏口径。这里照 `AlertMonitor.pollInterval` 的既有模式写：
/// 常驻 `Task` + 时段门控 + App 不活跃降频。
///
/// ## 三道闸门（缺一不可）
/// 1. **窗口**：`BoardRefresh.nextInterval`（09:00–15:59，**不是**交易时段 —— 理由见 Core 注释）；
/// 2. **交易日**：`BoardHeatJob.run()` 自带（非交易日返回 `not_trading_day`，不抛错、只留痕）；
/// 3. **口径**：`viewDate == today`、非历史、非回放 —— 用户在看历史时不该被刷新打断。
///
/// ## 为什么 tick 用 30 秒粒度 + "距上次够久才刷"
/// 窗口边界（09:00 / 16:00）、App 活跃度变化都能在半分钟内生效；
/// 一次失败的抓取不会把节奏带偏（失败也照样等满间隔，不做紧密重试）。
@MainActor
final class BoardMonitor {
    static let shared = BoardMonitor()

    private var loop: Task<Void, Never>?
    /// 上次**发起**刷新的时刻（只在真正发起时更新）
    private var lastRunAt: Date?
    /// tick 粒度（窗口/活跃度变化的感知延迟上限）
    private static let tickSeconds: TimeInterval = 30

    /// 启动常驻轮询（App 入口调用一次；重复调用无副作用）
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(Self.tickSeconds))
            }
        }
    }

    /// 停止轮询（退出时调用；与 `AlertMonitor.stop()` 同一收尾纪律）
    func stop() {
        loop?.cancel()
        loop = nil
    }

    private func tick() async {
        let now = Date()
        guard let interval = BoardRefresh.nextInterval(
                minuteOfDay: ChinaTime.minutesOfDay(now),
                appActive: NSApp?.isActive == true) else { return }   // 窗口外：不刷
        if let last = lastRunAt, now.timeIntervalSince(last) < interval { return }
        let store = Store.shared
        guard store.viewDate == store.today, !store.isHistorical else { return }
        guard !HistoryReplayMode.isBusy else { return }
        lastRunAt = now
        // ⚠ `silent: true` —— 后台轮询**不弹任何提示**（5 分钟一次的 toast 会变噪声）；
        //   成功时它仍会把页面数据刷新（`loadBoardHeat`）
        store.refreshBoardHeat(silent: true)
    }
}
