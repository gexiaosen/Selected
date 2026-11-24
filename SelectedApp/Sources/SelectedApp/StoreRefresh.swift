import Foundation
import SwiftUI
import Observation
import SelectedCore

/// 全局状态（v2 架构）：
/// - 读操作：SQLiteReader 直读（毫秒级）
/// - 写操作：全部原生（后台线程执行，不阻塞 UI）；失败就直接报错，不静默换引擎
/// - 全局查看日期 viewDate：所有页面联动；历史模式（viewDate ≠ 今天）禁用写操作
extension Store {
    // MARK: - 直读刷新（同步，毫秒级）
    //
    // ⚠ 实测维持现状：按本函数的同一顺序逐条计时（生产库量级），全部读**稳态合计 < 一帧预算**，
    //   且本函数只在启动/落库后/看板出现时调，不是每帧或定时跑
    //   ⇒ **不做后台化**（那需要 Core Store 全面 Sendable 化，风险大于收益）。

    /// 按 viewDate 刷新全部页面数据
    func refresh() {
        lastRefreshAt = Date()
        // 库完整性自检：只做一次（quick_check 只读）。**后台线程跑**：
        // 生产库是唯一不可再生资产 —— 损坏时 UI 表现为"页面全空"，极易被误读成
        // "今天还没扫描"，故主动探测并给出恢复线索。
        // 不放主线程：quick_check 随库增长可能变慢，主线程只承担毫秒级直读，启动必须秒开。
        if !dbIntegrityChecked {
            dbIntegrityChecked = true
            if let bootErr = DBBootstrap.lastError {
                // 建库/schema 迁移失败：库不可用或结构不完整，必须显式报错（不能表现成"今天还没扫描"）
                self.lastError = "数据库初始化失败：\(bootErr)"
                self.lastErrorKey = "dbBootstrap"
            }
            Task.detached(priority: .utility) { [weak self] in
                // ⚠ 后台用**独立连接**：`SQLiteReader.shared` 已 `@MainActor` 隔离，
                // 后台引用不过编译 —— 这正是那条契约的编译期形态。
                let issue = SQLiteReader.makeIndependent().integrityIssue()
                await MainActor.run {
                    guard let self, let issue else { return }
                    self.lastError = "\(issue)｜请用项目备份目录下的 Selected-backups/data-*.tar.gz 恢复"
                    self.lastErrorKey = "dbIntegrity"
                }
            }
        }
        // 先刷新数据日期集合，供跨午夜跟随与状态条使用
        dayMeta = reader.availableDays()
        // 数据源新鲜度（⑲）：参照系取 `dayMeta` 观察到的交易日，**必须在 dayMeta 之后**算
        let observedDays = DataFreshness.observedDays(dayMeta)
        let ref = DataFreshness.reference(observedDays)
        sourceFreshness = DataFreshness.derive(rows: reader.dataSourceLogs(),
                                               latest: ref.latest, previous: ref.previous)
        // 未手动选日期：看板进入过 → 跟随当天（周末回落最近数据日），否则跟随最新交易日
        if !userPinnedDate {
            viewDate = dashboardFollowsToday ? dashboardDefaultDate : latestDataDate
        }
        let d = viewDate

        let roundRows = reader.todayRounds(d)
        roundSummaries = roundRows.map(RoundSummaryRow.init)
        // ⚠ 今日轮次集合**在这里算**，不要留成计算属性给 body 反复查库（审查 B3）：
        //   常驻菜单栏的 body 每渲染一次就发一条 `todayRounds(today)`。
        //   当 viewDate == 今天时，上面那条查询正好就是它需要的结果 ⇒ 复用同一次读。
        //   命令路径（补跑 / 对比的"今日是否齐全"）要的是**实时**值，走
        //   `freshTodayDoneSlots()`，不依赖这里的刷新节奏。
        todayDoneSlots = d == today
            ? Set(roundRows.compactMap { $0["slot"].int })
            : freshTodayDoneSlots()
        todaySignals = reader.signals(date: d).map(SignalClassRow.init)


        // 全页面统一口径：所选日期 = 选股日。
        // 预判/验证/复盘/迭代全部按 sel_date=所选日期 查——
        // 选哪天就看"那天选的股票"的完整生命周期（T+1 的预判/验证/复盘挂在选股日下）。
        compareReport = reader.compareReport(date: d).map(CompareReport.init)
        predictReport = reader.predictBySelDate(d).map(PredictResult.init)
        verifyReport = reader.verifyBySelDate(d).map(VerifyResult.init)
        reviewReport = reader.reviewBySelDate(d).map(ReviewResult.init)
        iterateReport = reader.iterateByDate(d).map(IterateResult.init)

        // 开盘回退（审查 #1）：看板跟随当天且当日信号/结论未产出时，信号卡给「今日预判」、
        // 结论卡给最新历史结论 —— 否则显要一行在开盘（唯一使用时点）恒为占位文案。
        // 预判必须 predict_date=今天（今早 09:30 那份），昨天及更早的不顶上来。
        if isDashboardToday, todaySignals.isEmpty, compareReport?.suggestions.isEmpty ?? true {
            let pred = reader.latestPredict().map(PredictResult.init)
            dashboardPredictFallback = pred?.predictDate == today ? pred : nil
            let cmp = reader.latestCompareReport().map(CompareReport.init)
            dashboardConclusionFallback = (cmp?.isOK ?? false) && cmp?.date != today ? cmp : nil
        } else {
            dashboardPredictFallback = nil
            dashboardConclusionFallback = nil
        }

        // 轮次明细一次刷齐（毫秒级直读，页面切换无需再触发）
        var rd: [Int: JSONValue] = [:]
        for slot in RoundPlan.slots {
            if let detail = reader.roundDetail(date: d, slot: slot) { rd[slot] = detail }
        }
        roundDetails = rd

        historyRecord = reader.history(date: d).map(HistoryRecord.init)
        // 板块热度 / 昨涨停表现（同为按日直读，毫秒级）
        loadBoardHeat()
        // 指标快照：库级新鲜度三件套（毫秒级，只读不抓）
        loadIndicatorSnapshot()
        reloadWinrateTrend()
        multiWindow = MultiWindowSummary.make(rows: reader.recentOutcomeWindowRows(limit: 20))
        isPicklessSelDay = reader.isPicklessDay(d)
        refreshParams()

        // 实时指数：首次拉取或距上次超过 60s 则刷新
        let needRefresh = liveIndex == nil
            || (liveIndexFetchedAt.map { Date().timeIntervalSince($0) > 60 } ?? true)
        if needRefresh {
            fetchLiveIndexInBackground()
        }
        // 实时灯：已有实时涨跌时刷新（未拉取完成时由 fetch 成功后兜底）
        computeRealtimeLight()
    }

    /// 后台拉取看板四指数（一次腾讯批量请求）。拉到才覆盖，失败保留旧值不闪空。
    ///
    /// ⚠ 始终额外带上 `sh000001`：盘中实时灯 / 3 日趋势仍以上证为口径，
    ///   用户把上证取消勾选后这两块不能失去数据源。
    func fetchLiveIndexInBackground() {
        // ⚠ 预览模式抑制网络拉取（#Preview 只渲染已落库数据）
        guard !previewMode else { return }
        guard !isHistorical else { return }
        guard !liveIndexFetching else { return }
        var symbols = DashboardPrefs.shared.displayedSymbols
        if !symbols.contains("sh000001") { symbols.insert("sh000001", at: 0) }
        liveIndexFetching = true
        Task { [weak self] in
            let quotes = await QuoteAPI.indexes(symbols)
            await MainActor.run {
                guard let self else { return }
                self.liveIndexFetching = false
                guard !quotes.isEmpty else { return }
                // 只覆盖本批拿到的 symbol；失败的那只保留旧值（不闪空）
                for (symbol, q) in quotes { self.liveIndexQuotes[symbol] = q }
                if let sh = quotes["sh000001"] ?? quotes["sh000001".lowercased()] {
                    self.liveIndex = JSONValue([
                        "price": sh.currentPrice,
                        "pre_close": sh.previousClose,
                        "change_pct": sh.changePercent,
                        "high": sh.highPrice,
                        "low": sh.lowPrice,
                    ])
                }
                self.liveIndexFetchedAt = Date()
                self.computeRealtimeLight(force: true)
            }
        }
    }

    /// 重新拉取四层胜率走势（范围变了要重拉）。
    ///
    /// ⚠ 数据就在库里，多拉几十行**很便宜**（`reviews` 一天一行）⇒ 不做增量缓存。
    /// ⚠ `range == 0` 表示"全部" ⇒ 传一个足够大的上限（`recentReviewWinrates` 内部会
    ///   再乘 2 去过滤无样本日，所以这里给 10 万足够覆盖几十年）。
    func reloadWinrateTrend() {
        let n = winrateTrendRange > 0 ? winrateTrendRange : 100_000
        winrateTrend = reader.recentReviewWinrates(limit: n).map(WinrateTrendRow.init)
    }

    /// 强制刷新实时指数（绕过 60s 缓存；看板页每次出现时调用，保证打开即最新）
    func forceRefreshLiveIndex() {
        guard !isHistorical else { return }
        fetchLiveIndexInBackground()
    }

}
