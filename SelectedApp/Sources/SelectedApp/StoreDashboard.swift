import Foundation
import Observation
import SelectedCore

/// 看板专属的派生状态与进入动作。
///
/// 视图 body 只读这里算好的值；持仓行情轮询归 `AlertMonitor`，指数/情绪/板块
/// 盘中轮询归 `DashboardLiveMonitor` —— 看板不自己起定时器。
extension Store {

    /// 看板默认落到当天；用户手动选过日期则不覆盖。
    ///
    /// ⚠ 必须走 `dashboardFollowsToday`：`refresh()` 里有"未锁日期 → 跟随最新数据日"
    ///   的逻辑，只把 `viewDate` 改成今天会在下一次 refresh 被改回去。
    func applyDashboardDefaultDate() {
        guard !previewMode else { return }
        guard !userPinnedDate else { return }
        dashboardFollowsToday = true
        let target = dashboardDefaultDate
        guard viewDate != target else { return }
        viewDate = target
        refresh()
    }

    /// 看板的「回到当日」：清掉手动锁日期，重新跟随当天（周末落最近数据日）。
    /// 与 `backToLatest` 的区别：后者回"最近有数据日"，在尾盘扫描前可能是昨天。
    func backToDashboardToday() {
        userPinnedDate = false
        dashboardFollowsToday = true
        let target = dashboardDefaultDate
        if viewDate != target {
            viewDate = target
        }
        refresh()
    }

    /// 看板进入时的统一准备：持仓列表 + 行情轮询 + 盘中卡首刷。
    ///
    /// ⚠ `loadWatch()` 平时只在自选页进入时调用；看板新增持仓卡后必须自己补一次，
    ///   否则 `AlertMonitor` 的轮询并集里没有持仓代码，价格列永远「—」。
    func prepareDashboard() {
        guard !previewMode else { return }
        loadWatch()
        AlertMonitor.shared.kick()
        DashboardLiveMonitor.shared.kick()
        loadHistoricalIndicesIfNeeded()
    }

    /// 历史日四指数收盘回填（东财日K；最多 4 个请求，按 viewDate 缓存）。
    ///
    /// - Parameter force: 手动刷新时绕过缓存；普通切日/进页命中缓存直接返回。
    func loadHistoricalIndicesIfNeeded(force: Bool = false) {
        guard !previewMode else { return }
        let date = viewDate
        guard date != today else { return }
        // 失败也按 date 记一笔：避免同一历史日每次进页都重试 4 个请求；
        // 手动刷新传 force 才重试。
        if !force, historicalIndexQuotesDate == date {
            return
        }
        if historicalIndexQuotesFetching {
            pendingHistoricalIndexDate = date
            return
        }
        let symbols = DashboardPrefs.shared.displayedSymbols
        guard !symbols.isEmpty else { return }
        historicalIndexQuotesFetching = true
        pendingHistoricalIndexDate = nil

        Task { [weak self] in
            let snapshot = await Task.detached(priority: .utility) {
                IndexHistoryQuote.fetchAll(symbols: symbols, date: date)
            }.value
            await MainActor.run {
                guard let self else { return }
                self.historicalIndexQuotesFetching = false
                if let snapshot {
                    self.historicalIndexQuotes = snapshot.quotes
                    self.historicalIndexQuotesDate = date
                    self.historicalIndexQuotesAsOf = snapshot.asOf
                } else {
                    // 失败也记 date：避免同一日期每次进页都重试 4 个请求；手动刷新可 force
                    self.historicalIndexQuotes = [:]
                    self.historicalIndexQuotesDate = date
                    self.historicalIndexQuotesAsOf = nil
                }
                if self.pendingHistoricalIndexDate != nil {
                    self.pendingHistoricalIndexDate = nil
                    self.loadHistoricalIndicesIfNeeded(force: true)
                }
            }
        }
    }

    /// 指数选择变了：历史缓存作废（旧 symbols 的快照不完整）。
    func invalidateHistoricalIndices() {
        historicalIndexQuotes = [:]
        historicalIndexQuotesDate = nil
        historicalIndexQuotesAsOf = nil
    }

    /// 持仓当日盈亏（纯内存计算，`liveQuotes` 变化会自动让视图重算）。
    var holdingDayPnl: HoldingDayPnl? {
        let holdings = watchItems.filter(\.isHolding)
        guard !holdings.isEmpty else { return nil }
        let inputs = holdings.map { item -> HoldingPositionInput in
            let q = liveQuotes[item.code]
            return HoldingPositionInput(
                code: item.code,
                name: item.displayName,
                costPrice: item.costPrice,
                shares: item.shares,
                price: q?.currentPrice,
                previousClose: q?.previousClose)
        }
        return HoldingDayPnl.compute(inputs)
    }

    /// 今天是否展示实时卡片：查看日必须是当天，历史/最新非今天不混实时值。
    var isDashboardToday: Bool { viewDate == today }
}
