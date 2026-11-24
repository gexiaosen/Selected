import Foundation
import Observation
import SelectedCore

/// 板块热度 + 昨日涨停表现的**加载与手动触发**。
///
/// ## 为什么单独一个 extension
/// 与 `StoreStockDetail` 同一思路：**一次查完 → 收进存储属性 → View 只读不查**
/// （视图 body 里 poke Store 查库就是主线程同步 I/O）。
/// 加载入口 `loadBoardHeat()` 由 `refresh()` 调用，与其余页面数据同一节奏。
///
/// ## 口径：跟随 viewDate
/// 两者都是**按日落库**的展示型数据 —— 选哪天看哪天（历史模式下照常可看）。
/// 手动「更新」按钮只在**今天**口径下触发抓取（源只有当日截面，历史日重抓=拿今天数据冒充历史）。
extension Store {

    /// 按 viewDate 加载板块排行 / 昨涨停表现（由 `refresh()` 调用）
    func loadBoardHeat() {
        boardHeatRows = BoardHeatStore.dayRows(viewDate)
        ztSentimentToday = ZtSentimentStore.day(viewDate)
        ztSentimentTrend = ZtSentimentStore.recent(20)
        boardHeatCoveredDays = BoardHeatStore.days().count
        boardHeatFetchedAt = BoardHeatStore.lastFetchedAt()
        // 当日涨停池（板块页的涨停徽章 / 强度都靠它）——
        // ⚠ 与板块同一天：`limit_up_pool` 也是按日落库，viewDate 一致才配套
        boardLimitUpByIndustry = Dictionary(
            grouping: LimitUpPoolStore.dayRecords(viewDate), by: \.industry)
        // ⚠ 成份缓存**只在切日时清空**：源只给**实时**行情，昨天的涨幅榜今天抓不到
        //   （宁缺勿错，不拿今天的成份冒充历史日 —— 与板块行情"源只有当日截面"同一纪律）。
        //   同日刷新不清：清了之后 `.task(id:)` 不会重触发，详情会一直空到下次点板块。
        if boardMembersDate != viewDate {
            boardMembersByCode = [:]
            boardMembersDate = viewDate
        }
        // ⚠ 强度**在这里算一次**，不在 `BoardView` 的 body 里算（2026-10-16 审查 B3）：
        //   `content` 随 store 任何变化与搜索框每次击键重渲染，原先每次都重算四因子分位；
        //   而分数与 `query` 无关。算好放进 Store，视图只读。
        boardStrength = BoardStrength.compute(rows: boardHeatRows,
                                              limitUpByIndustry: boardLimitUpByIndustry)
    }


    /// 按需抓取某板块成份涨幅榜（板块详情「强势股」）。
    ///
    /// ## 为什么是"选中才抓"而不是随 `loadBoardHeat` 一起抓
    /// 496 个板块全量成份 = 数百个请求，而用户一屏只看一个板块；按需抓一个板块一次请求。
    ///
    /// ## 护栏（与 `refreshBoardHeat` 同一套前置）
    /// · 历史口径不抓（源只给实时值，历史日抓回来是"今天的数据冒充昨天"）；
    /// · 预览模式不抓（`#Preview` 禁网络）；
    /// · 同板块在途 / 已有缓存 ⇒ 直接返回（切走再切回不重复请求）。
    func loadBoardMembers(for boardCode: String) {
        guard !boardCode.isEmpty, !previewMode, !isHistorical else { return }
        guard boardMembersByCode[boardCode] == nil,
              !boardMembersLoadingCodes.contains(boardCode) else { return }
        boardMembersLoadingCodes.insert(boardCode)
        Task.detached(priority: .userInitiated) { [weak self] in
            let rows = BoardMembersSource.fetchTop(boardCode: boardCode)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.boardMembersLoadingCodes.remove(boardCode)
                // ⚠ 失败**不弹 toast**：这是选中板块的就地展示，抓不到就显示
                //   "暂无数据"即可（同「手动就地动作」的口径，全局横幅留给后台失败）。
                if let rows { self.boardMembersByCode[boardCode] = rows }
            }
        }
    }

    /// 更新板块热度（当日截面抓取）。
    ///
    /// 与调度任务同一份 `BoardHeatJob.run()`（**每次都重抓覆盖**，15:10 定稿同理），
    /// 不另写一条取数路径。休市时任务返回 `not_trading_day`（不抛错）→ 如实提示，
    /// 不能报"已更新（0 个板块）"。
    ///
    /// - Parameter silent: **后台轮询**用（`BoardMonitor`）：
    ///   ① 不弹任何 toast（5 分钟一次的自动刷新弹提示 = 噪声）、不写 `lastError`；
    ///   ② 被前置条件挡住时**静默跳过**而不是提示（调度器在跑 / 回放中 / 历史口径）；
    ///   ③ 成功只刷本页数据（`loadBoardHeat`），不做全量 `refresh()`（那是手动点击的语义）。
    func refreshBoardHeat(silent: Bool = false) {
        if silent {
            // ⚠ 静默路径的"挡住就跳过"：不调 `blockedByScheduler`（它会写 lastError + 弹 toast）
            guard Scheduler.shared.runningTaskId == nil else { return }
            guard !isHistorical, !HistoryReplayMode.isBusy else { return }
        } else {
            guard !blockedByScheduler("更新板块热度") else { return }
            guard !isHistorical else {
                ToastCenter.shared.show("历史模式下不可抓取板块行情（源只有当日截面），请先回到最新交易日",
                                        style: .warning)
                return
            }
            if HistoryReplayMode.isBusy {
                ToastCenter.shared.show("历史回放进行中，暂不可抓取板块行情", style: .warning)
                return
            }
        }
        let key = "boardheat"
        guard !busy.contains(key) else { return }
        busy.insert(key)
        Task.detached(priority: silent ? .utility : .userInitiated) { [weak self] in
            let outcome: (JSONValue?, String?) = {
                do { return (JSONValue(try BoardHeatJob.run()), nil) }
                catch { return (nil, (error as? LocalizedError)?.errorDescription
                                ?? String(describing: error)) }
            }()
            await MainActor.run {
                guard let self else { return }
                self.busy.remove(key)
                guard let json = outcome.0 else {
                    // ⚠ 手动抓取失败**不写 lastError**：横幅只留给库级故障，
                    //   写进去既不显示（被白名单挡）又是死状态。走**钉住的 error toast**（点别处才走）。
                    // ⚠ 文案**自己出、不复用 `BoardHeatJob.Failure` 的**：那份写着"调度器将自动重试"，
                    //   那是调度路径的语义；手动点击没有任何东西会替你重试，照抄就是骗人。
                    // ⚠ 后台轮询（silent）不弹：失败只靠 `data_source_logs` 与页面上的更新时刻体现
                    if !silent {
                        ToastCenter.shared.show("板块热度抓取失败：\(outcome.1 ?? "未知")（源可能限流或尚未返回当日数据，可稍后再点一次「更新」）",
                                                style: .error)
                    }
                    return
                }
                // 休市：任务不抛错而是返回 not_trading_day（与调度路径同一结构化判据）
                if json["status"].string == "not_trading_day" {
                    if !silent {
                        let why = json["trading_day_reason"].string ?? "休市"
                        ToastCenter.shared.show("今日非交易日（\(why)），无板块行情可抓", style: .warning)
                    }
                    return
                }
                if !silent {
                    ToastCenter.shared.show("板块热度已更新（\(json["records"].int ?? 0) 个板块）")
                    self.refresh()
                } else {
                    self.loadBoardHeat()   // 后台轮询：只刷本页数据（不做全量 refresh）
                }
            }
        }
    }
}
