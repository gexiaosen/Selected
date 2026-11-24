import Foundation
import SelectedCore

/// 看板盘中轮询器：四指数 / 昨涨停情绪 / 领涨板块 TopN。
///
/// ## 为什么单独一个轮询器
/// `AlertMonitor` 管自选行情与提醒，`BoardMonitor` 管 5 分钟全量板块；
/// 看板新增的 60 秒级数据若塞进任何一个都会把各自的节奏搅乱。
/// 本类沿用同一套"常驻 Task + 时段门控 + 失败保留旧值"的模式。
///
/// ## 节奏
/// | 数据 | 窗口（北京时间） | 间隔 |
/// |------|------------------|------|
/// | 四指数 | 09:15–15:05 | 60s |
/// | 昨涨停盘中 | 09:30–15:05 | 60s |
/// | 领涨板块 TopN | 09:00–15:00 | 60s |
///
/// ⚠ 只在"查看日 == 今天"时跑情绪/板块/指数；历史日不拿实时值冒充。
/// ⚠ 回放/预览/周末全部短路；写库只发生在"补昨日涨停池"且调度器空闲时。
@MainActor
final class DashboardLiveMonitor {
    static let shared = DashboardLiveMonitor()
    private init() {}

    private var loop: Task<Void, Never>?
    private var ticking = false

    private var lastIndexAt: Date?
    private var lastZtAt: Date?
    private var lastBoardAt: Date?

    private var ztFetching = false
    private var boardFetching = false
    /// 昨日涨停池缺失时的退避（源只覆盖约 10 个交易日，缺了就不是每分钟重试能解决的）
    private var poolMissDay: String?
    private var poolRetryAt: Date?

    private static let tickSeconds: TimeInterval = 15
    private static let indexInterval: TimeInterval = 60
    private static let ztInterval: TimeInterval = 60
    private static let boardInterval: TimeInterval = 60

    /// 09:15–11:30 / 13:00–15:05（含集合竞价与收盘后几分钟的定稿值；午休不空转）
    private static let indexMinutes: [ClosedRange<Int>] = [555...690, 780...905]
    /// 09:30–11:30 / 13:00–15:05（开盘才有"今日涨跌幅"）
    private static let ztMinutes: [ClosedRange<Int>] = [570...690, 780...905]
    /// 09:00–11:30 / 13:00–15:00（板块聚合在集合竞价阶段已有值）
    private static let boardMinutes: [ClosedRange<Int>] = [540...690, 780...900]

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                // 接口池探针：交易时段每 5 分钟测一遍三家源（池内部自己判间隔），
                // 丢进独立 Task —— 探针再慢也不能拖住 15s 的看板节拍
                Task { await QuoteAPI.probeIfNeeded() }
                guard !Task.isCancelled else { break }
                try? await Task.sleep(for: .seconds(Self.tickSeconds))
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// 看板进入时踢一轮（把最长 60 秒的等待压掉）
    func kick() {
        lastIndexAt = nil
        lastZtAt = nil
        lastBoardAt = nil
        Task { await tick() }
    }

    private func tick() async {
        guard !ticking else { return }
        ticking = true
        defer { ticking = false }

        let store = Store.shared
        guard !store.previewMode else { return }
        guard !HistoryReplayMode.isBusy else { return }
        let now = Date()
        guard !ChinaTime.isWeekend(now) else { return }
        guard store.isDashboardToday else { return }

        let minute = ChinaTime.minutesOfDay(now)
        if Self.isIn(Self.indexMinutes, minute),
           Self.isDue(lastIndexAt, interval: Self.indexInterval, now: now) {
            lastIndexAt = now
            // Store 内部有 `liveIndexFetching` 互斥，这里不 await
            store.fetchLiveIndexInBackground()
        }
        if Self.isIn(Self.ztMinutes, minute),
           Self.isDue(lastZtAt, interval: Self.ztInterval, now: now) {
            lastZtAt = now
            await refreshZtSentiment(allowWrite: Scheduler.shared.runningTaskId == nil)
        }
        if Self.isIn(Self.boardMinutes, minute),
           Self.isDue(lastBoardAt, interval: Self.boardInterval, now: now) {
            lastBoardAt = now
            await refreshTopBoards()
        }
    }

    private static func isIn(_ ranges: [ClosedRange<Int>], _ minute: Int) -> Bool {
        ranges.contains { $0.contains(minute) }
    }

    private static func isDue(_ last: Date?, interval: TimeInterval, now: Date) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= interval
    }

    // MARK: - 昨涨停盘中

    private struct ZtOutcome: Sendable {
        let snapshot: ZtSentimentLiveSnapshot?
        let error: String?
        let poolMissing: Bool
    }

    private func refreshZtSentiment(allowWrite: Bool) async {
        guard !ztFetching else { return }
        ztFetching = true
        defer { ztFetching = false }

        let day = Store.shared.today
        let now = Date()
        let fetchIfMissing = !(poolMissDay == day && (poolRetryAt.map { now < $0 } ?? false))
        let outcome = await Task.detached(priority: .utility) { () -> ZtOutcome in
            guard let prev = ZtSentimentLive.previousTradingDay(today: day) else {
                return ZtOutcome(snapshot: nil, error: "交易日历不可用，无法确定昨日",
                                 poolMissing: false)
            }
            let ensured = ZtSentimentLive.ensurePreviousPool(
                prevDay: prev, allowWrite: allowWrite, fetchIfMissing: fetchIfMissing)
            guard !ensured.pool.isEmpty else {
                return ZtOutcome(snapshot: nil,
                                 error: "前一交易日（\(prev)）涨停池缺失",
                                 poolMissing: true)
            }
            let codes = ensured.pool.map(\.code)
            let quotes = await QuoteAPI.batch(codes)
            guard !quotes.isEmpty else {
                return ZtOutcome(snapshot: nil, error: "实时行情为空，保留上一笔",
                                 poolMissing: false)
            }
            let result = ZtSentimentLive.compute(date: day, pool: ensured.pool, quotes: quotes)
            return ZtOutcome(snapshot: ZtSentimentLiveSnapshot(
                result: result,
                prevTradingDay: prev,
                updatedAt: Date(),
                poolCount: ensured.pool.count,
                backfilledPool: ensured.backfilled), error: nil, poolMissing: false)
        }.value

        let store = Store.shared
        if let snapshot = outcome.snapshot {
            store.ztSentimentLive = snapshot
            store.ztSentimentLiveError = nil
            poolMissDay = nil
            poolRetryAt = nil
        } else if let error = outcome.error {
            store.ztSentimentLiveError = error
            if outcome.poolMissing {
                poolMissDay = day
                poolRetryAt = Date().addingTimeInterval(600)
            }
        }
    }

    // MARK: - 领涨板块 TopN

    private func refreshTopBoards() async {
        guard !boardFetching else { return }
        boardFetching = true
        defer { boardFetching = false }

        let rows = await Task.detached(priority: .utility) {
            BoardHeatSource.fetchTop(limit: 6)
        }.value
        guard let rows, !rows.isEmpty else { return }
        let store = Store.shared
        store.liveTopBoards = rows
        store.liveTopBoardsUpdatedAt = Date()
    }
}
