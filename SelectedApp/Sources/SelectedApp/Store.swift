import Foundation
import SwiftUI
import Observation
import SelectedCore

/// 初始状态常量（独立于 @Observable 宏，避免存储属性初始化器引用 Self 被拒）
enum InitialState {
    /// 默认查看日期：最近有数据的交易日（首启空库回退今天）
    ///
    /// ⚠ `@MainActor`：这个惰性初始化器读的是**主线程专用**共享连接（`SQLiteReader.shared`
    /// 已 `@MainActor`）—— 谁**第一次**碰它，初始化就跑在谁的线程上，
    /// 所以必须把"只在主线程初始化"写进类型，而不是留给"调用它的地方碰巧在主线程"。
    @MainActor static let viewDate: String = {
        let days = SQLiteReader.shared.availableDays()
        if let latest = days.keys.max() { return latest }
        let f = ChinaTime.dayFormatter
        return f.string(from: Date())
    }()
}

/// 全局状态（v2 架构）：
/// - 读操作：SQLiteReader 直读（毫秒级）
/// - 写操作：全部原生（后台线程执行，不阻塞 UI）；失败就直接报错，不静默换引擎
/// - 全局查看日期 viewDate：所有页面联动；历史模式（viewDate ≠ 今天）禁用写操作
@Observable
@MainActor
final class Store {
    static let shared = Store()

    // MARK: - 全局查看日期

    /// 当前查看日期（默认最近有数据的交易日，避免打开即满屏空态；
    /// 用户手动选历史日期后固定，回最新后恢复跟随）
    var viewDate: String = InitialState.viewDate
    /// 用户手动选过日期（未选过时跨午夜自动跟随最新交易日）
    var userPinnedDate = false
    /// 看板进入后置 true：未手动锁日期时，`refresh()` 的目标从"最近有数据日"
    /// 改成"当天"（周末回落到最近有数据日）。手动选日期 / 回到最新会清掉。
    var dashboardFollowsToday = false
    /// 有数据的日期 → 环节位掩码（bit0 轮次…bit5 迭代）
    var dayMeta: [String: Int] = [:]
    /// 当前查看日是否为空仓选股日（三轮齐全且无入档）——复盘/验证无标的，空态直接说明
    var isPicklessSelDay = false

    /// 数据源新鲜度：每源最近**成功**取数日期 + 🟢🟡🔴。
    /// 判据全部来自本地（`data_source_logs` + `dayMeta`），不触网、不碰引擎输出。
    var sourceFreshness: [SourceFreshness] = []

    var today: String {
        let f = ChinaTime.dayFormatter
        return f.string(from: Date())
    }

    /// 今日（北京时间）已落库的轮次集合。**由 `refresh()` 刷新**（不是计算属性 ——
    /// 原先每次求值都发一条 SQL，而常驻菜单栏的 body 会反复求值；审查 B3）。
    /// ⚠ 不用 `private(set)`：`Store` 的实现分散在 9 个 `extension Store` 文件里，
    ///   而 `private` 是**按文件**生效的 —— 刷新点 `StoreRefresh.swift` 会写不进去。
    ///   外部请勿直接赋值，命令路径请走 `freshTodayDoneSlots()`。
    /// 补跑/菜单栏的「今日轮次」判定必须走这里：roundSummaries 的内容来自 reader.todayRounds(viewDate)，
    /// 查看昨日数据时若用它会误报"今日已齐全"，还会对昨日触发 compare。
    var todayDoneSlots: Set<Int> = []


    /// **实时**读今日轮次（命令执行前的判定用：补跑 / 对比不能依赖刷新节奏）。
    func freshTodayDoneSlots() -> Set<Int> {
        Set(reader.todayRounds(today).compactMap { $0["slot"].int })
    }


    /// 最近有数据的交易日（dayMeta 最大 key；尚无数据时兜底今天）
    var latestDataDate: String { dayMeta.keys.max() ?? today }

    /// 看板默认目标：工作日 = 当天；周末 = 最近有数据日（避免周末看板全空）。
    /// ⚠ 节假日无法在 UI 线程同步确认，仍按当天；实时卡会显示最近一笔行情并标注。
    var dashboardDefaultDate: String {
        ChinaTime.isWeekend() ? latestDataDate : today
    }

    /// 历史模式：查看「既非今天、也非最新交易日」的日期时禁用写操作。
    /// 最新交易日保留写操作——引擎的复盘/验证/对比重算按「最近选股日」计算，正好作用于它
    var isHistorical: Bool {
        guard let latest = dayMeta.keys.max() else { return false }
        return viewDate != today && viewDate != latest
    }

    /// **预览模式**：供 SwiftUI `#Preview` 使用 ——
    /// 视图照常读**真实开发库**（预览进程独立，不碰生产数据），但**抑制网络拉取**：
    /// 实时指数 / 实时灯 / 3 日趋势等 `.task` 副作用全部短路，
    /// 让 Preview 稳定渲染已落库数据（空库时正好看空态）。
    /// ⚠ 只应在 `#Preview` 闭包里置位；App 运行路径永不置位。
    var previewMode = false

    /// 引擎 T+1 动作（复盘/验证/预判重算）实际作用的选股日：最近一个早于今天的选股日。
    /// 查看该日期时，右上角重算按钮应可用（重算的正是这天，而非当前页面另算）
    var engineTargetSelDate: String? {
        dayMeta.keys.filter { $0 < today }.max()
    }

    func setViewDate(_ date: String) {
        userPinnedDate = true
        dashboardFollowsToday = false
        guard date != viewDate else { return }
        viewDate = date
        refresh()
    }

    /// 回到最新交易日（默认跟随态；引擎写操作对最新交易日开放）
    func backToLatest() {
        userPinnedDate = false
        dashboardFollowsToday = false
        let target = latestDataDate
        guard viewDate != target else { return }
        viewDate = target
        refresh()
    }

    /// 页面空态「最近记录」跳转：固定到目标日期，与手动选日期等价
    func jump(toDate date: String) {
        setViewDate(date)
    }

    /// 前后翻一天（不限有数据的日期）
    func stepDate(_ delta: Int) {
        guard let d = Self.shiftDate(viewDate, by: delta) else { return }
        setViewDate(d)
    }

    static func shiftDate(_ s: String, by days: Int) -> String? {
        let f = ChinaTime.dayFormatter
        guard let base = f.date(from: s) else { return nil }
        guard let shifted = ChinaTime.calendar.date(byAdding: .day, value: days, to: base) else { return nil }
        return f.string(from: shifted)
    }

    // MARK: - 直读数据

    var roundSummaries: [RoundSummaryRow] = []
    var todaySignals: [SignalClassRow] = []
    var liveIndex: JSONValue?
    /// 看板四指数的实时行情（完整 symbol `sh000001` → quote）
    var liveIndexQuotes: [String: StockQuote] = [:]
    var liveIndexFetchedAt: Date?
    /// 历史日四指数收盘快照（东财日K回填；按 viewDate 缓存）
    var historicalIndexQuotes: [String: StockQuote] = [:]
    var historicalIndexQuotesDate: String?
    var historicalIndexQuotesAsOf: String?
    var historicalIndexQuotesFetching = false
    /// ⚠ module-internal：读写方在 `StoreDashboard.swift`（跨文件 extension 看不到 private）
    @ObservationIgnored var pendingHistoricalIndexDate: String?
    var compareReport: CompareReport?
    /// 开盘回退（2026-11-09 审查 #1）：看板跟随当天、当日信号/结论尚未产出时，
    /// 信号卡回退为「今日预判」（predict_date=今天的那份），结论卡回退为最新历史结论。
    /// 由 `refresh()` 统一计算；其余时点恒 nil（历史日/当日已有内容时不回退）。
    var dashboardPredictFallback: PredictResult?
    var dashboardConclusionFallback: CompareReport?
    /// 「把结果页时间线切到三轮对比那一格」的**一次性**请求（通知深链点进来时置位，结果页消费后清掉）。
    /// ⚠ 记在 Store 而不是视图 `@State`：跨页跳进来时结果页是**新建**的，`onChange` 对"出生时就位"
    ///   的值不响应 ⇒ 只能由 `ResultsView.leg` 的初值读它；而它**必须可作废**，
    ///   否则下次进结果页又会自己跳到第四格。
    var compareLegRequested = false
    func requestCompareLeg() { compareLegRequested = true }
    func consumeCompareLeg() { compareLegRequested = false }
    // 四阶段报告与三轮对比用实体 —— 视图侧不 poke 字符串键。
    // `EntityTestSupport` 的键覆盖/无损往返测试对着真实引擎产出，保证字段与生产者一致。
    var predictReport: PredictResult?
    var reviewReport: ReviewResult?
    var verifyReport: VerifyResult?
    var iterateReport: IterateResult?
    var roundDetails: [Int: JSONValue] = [:]
    // 板块热度排行 / 昨日涨停表现（按 viewDate 加载，见 `loadBoardHeat`）
    var boardHeatRows: [BoardHeatPoint] = []
    /// 盘中「领涨板块 TopN」（单页轻量请求，只进内存；收盘由 15:10 全量任务覆盖 DB）
    var liveTopBoards: [BoardHeatPoint] = []
    var liveTopBoardsUpdatedAt: Date?
    var boardHeatCoveredDays = 0
    /// 板块行情的**最近一次成功抓取时刻**（ISO 文本）——供"盘中快照 / 收盘定稿"标记。
    /// ⚠ 只读库、在 `loadBoardHeat()` 里一次性取（视图 body 不许 poke Store 查库）
    var boardHeatFetchedAt: String?
    // 指标快照：库级新鲜度三件套（由 `loadIndicatorSnapshot` 取；
    // 具体某指标的排行留给页面按需查 —— 全市场排行不进全局状态，避免每次 refresh 都拖 36 列查询）
    var indicatorSnapshotLatestDay: String?
    /// `indicatorSnapshotPreviousDay(of:)` 的按日缓存（视图 body 不查库；见该方法注释）
    var indicatorSnapshotPrevDayFor: String?
    var indicatorSnapshotPrevDayCache: String?
    var indicatorSnapshotCoveredCount = 0

    /// 快照新鲜度每刷新一次就 +1（**含后台重算完成后的那次**）。
    ///
    /// ⚠ 为什么不能只观察 `indicatorSnapshotCoveredCount`：重算前后覆盖只数通常不变
    ///   （5217 → 5217），页面的计数/结果就不会重载 —— 周期改完却像没生效。
    var indicatorSnapshotRevision = 0

    var indicatorSnapshotFetchedAt: String?
    /// 当日涨停池**按行业名分组**（`limit_up_pool.industry` ↔ `board_heat.board_name` 同源）。
    /// 用途：板块页的「涨停家数徽章 / 强度第四因子」（详情页强势股走成份接口，见 `boardMembersByCode`）。
    /// ⚠ 按名称匹配（不是 id），且**只对上一部分**：涨停池 `hybk` 实测被截断到 4 个汉字、
    ///   又是申万二级口径，板块名混了 Ⅰ/Ⅱ/Ⅲ 三级（`BoardHeatSource` 的粒度警告）。
    ///   对不上的只是拿不到涨停加分，不会算错别的。
    var boardLimitUpByIndustry: [String: [LimitUpRecord]] = [:]
    /// 板块四因子强度（`boardCode → Breakdown`）。
    /// ⚠ 由 `loadBoardHeat()` **算好一次**存这里，视图只读 ——
    ///   不要在 `BoardView.content` 里现算（body 会随任何 store 变化与搜索框每次击键重渲染，
    ///   而强度分数与 `query` 无关；见 2026-10-16 审查 B3）。
    var boardStrength: [String: BoardStrength.Breakdown] = [:]

    /// 板块成份涨幅榜缓存（板块详情「强势股」）：`boardCode → 成份按涨幅降序`。
    /// 由 `loadBoardMembers(for:)` **按需现抓**（选中哪个板块抓哪个）；源只给实时行情，
    /// 历史口径不抓（视图回退涨停池列表）。
    var boardMembersByCode: [String: [BoardMemberPoint]] = [:]
    /// 成份缓存对应的日期（`yyyy-MM-dd`）。⚠ 只在**切日**时清空（同日的例行刷新/手动
    /// 「更新」不清 —— 清了之后 `.task(id:)` 不会重触发，详情会一直空到下次点板块）。
    var boardMembersDate: String?
    /// 正在抓取成份的板块代码集合（视图据此显示"加载中…"）。
    /// ⚠ 不进 `busy`：那是**写命令互斥**（调度器反向互斥看它），本抓取是只读展示数据。
    var boardMembersLoadingCodes: Set<String> = []
    var ztSentimentToday: ZtSentimentResult?
    /// 盘中昨涨停快照（只进内存；15:15 收盘任务落 `zt_sentiment`）
    var ztSentimentLive: ZtSentimentLiveSnapshot?
    var ztSentimentLiveError: String?
    var ztSentimentTrend: [ZtSentimentResult] = []

    /// 该选股日**全部轮次**的分数快照（`code → [slot: score]`）—— 结果页「三轮分」列用。
    /// ⚠ 与 `roundDetails` 同一次刷新（都在 `loadRound`），且**一次查完**（不是每行一次查询）。
    private(set) var roundScores: [String: [Int: Double]] = [:]
    var historyRecord: HistoryRecord?
    /// 四层胜率跨日走势（近 N 个有样本复盘日，升序；历史页与复盘页同口径）
    var winrateTrend: [WinrateTrendRow] = []
    /// 走势的**范围**（近 N 个有样本选股日；**0 = 全部**）。
    ///
    /// ⚠ 默认 **20**：加范围切换时**刻意保持默认不变**（"加个功能"不该顺带换掉所有人看到的东西）。
    /// ⚠ 这个值只影响**取样范围**，不影响任何评分/判定（纯展示）。
    var winrateTrendRange: Int = 20
    /// 多观察窗跨日汇总：回答「**次日午前卖，还是拿三天更对**」。
    ///
    /// 与 `winrateTrend` 的区别：那条来自 `reviews.four_layer_json`（六层胜率，只含 T+1 口径），
    /// 这条来自 `stock_outcomes` **原始行**（含三档标的 → 解幸存者偏差），且带 T+3/T+5。
    /// ⚠ 两边的样本集合不同，胜率数字**不该互相印证**。
    var multiWindow: MultiWindowSummary?
    private(set) var paramVersions: [ParamVersionRow] = []
    var selftestReport: JSONValue?

    var busy: Set<String> = []

    /// 只读命令的 busy key（不写库，不参与「写操作互斥」判定）；其余 key 一律视为写命令
    /// ⚠ `selftest` 是纯网络探针（PhaseOps.selftest 不落库）：误归类为写命令会让每小时
    ///   自检的约 2 分钟内到点调度任务拒启、超窗记 missed（2026-11-09 审查 #3）。
    private static let readOnlyBusyKeys: Set<String> = ["param_meta", "selftest"]

    /// 是否有**写命令**正在执行（供调度器做反向互斥）。
    /// 调度器与手动入口必须互见，否则同一动作被并发跑两条（同一 (date, slot) 落两条轮次记录）。
    var hasBusyWriteCommand: Bool { busy.contains { !Self.readOnlyBusyKeys.contains($0) } }

    /// 调度任务执行中则拒绝手动写操作（返回 true = 已拒绝并给出提示）
    func blockedByScheduler(_ action: String) -> Bool {
        guard let running = Scheduler.shared.runningTaskId else { return false }
        let msg = "调度任务（\(running)）正在执行，请等它结束后再\(action)"
        lastError = msg
        lastErrorKey = "scheduler"
        ToastCenter.shared.show(msg, style: .warning)
        return true
    }

    /// 最近一次失败的写操作 key —— 仅当**同一个**操作再次成功时才清除 lastError
    /// （无条件清会把"先失败、后随便成功一次"的失败提示抹掉，失败无感知）。
    var lastErrorKey: String?
    var lastError: String?
    /// 页顶横幅**唯一显示判据**：非空 + 白名单（`ToastPolicy.allowsBanner`，只有库级故障）。
    /// ⚠ `PageActionBar` 与 `SettingsView` 两处渲染**只许读这一个属性** —— 判据写两份必然漂。
    var bannerError: String? {
        guard let err = lastError, !err.isEmpty,
              ToastPolicy.allowsBanner(key: lastErrorKey) else { return nil }
        return err
    }
    /// 库完整性自检是否已跑过（只跑一次）
    var dbIntegrityChecked = false
    /// 最近一次数据刷新完成时间（页面“更新 HH:mm:ss”标识）
    var lastRefreshAt: Date?

    /// ⚠ `@ObservationIgnored`：`SQLiteReader.shared` 是**连接对象**（`@MainActor`），
    ///   Store 内部大量 `reader.query(...)` 调用，但**没有任何 View / body 读它**
    ///   ⇒ 标上可避免每次访问登记依赖。⚠ 代价：改动后**必须逐页验证** UI 仍会更新
    ///   （建议配合 `_printChanges()`）。
    @ObservationIgnored
    let reader = SQLiteReader.shared

    // MARK: - 盘中实时灯（今日未扫描时看板 hero 用）
    // 引擎正式灯以尾盘扫描为准；盘中实时上涨/下跌也应实时反映，故按
    // "今日实时涨跌 + 最近交易日日K" 实时判定灯级，供未扫描时段展示。

    /// 盘中实时灯级（`.green` / `.yellow` / `.red`；nil = 尚无实时数据）
    private(set) var realtimeLightLevel: MarketLightLevel?
    /// 实时连续下跌天数（含今日，从今往前连续为负的天数）
    private(set) var realtimeLightDecline = 0
    /// ⚠ `@ObservationIgnored`：这是**纯内部的 60 秒去重时间戳**，只被 `stale` 判定与赋值读写，
    ///   **没有任何 View / body 读它** ⇒ 标上避免每次刷新都登记 / 失效依赖。
    ///   ⚠ **不要**给上一行的 `realtimeLightDecline` 加 —— 它是公开的展示字段。
    @ObservationIgnored
    private var realtimeLightFetchedAt: Date?

    /// 计算/刷新盘中实时灯：结合今日实时涨跌与最近交易日日K判定连续下跌。
    /// 规则镜像引擎 predict/classify_market_light：
    /// 连续跌≥2日→红灯；今日跌或平盘（sh_change_pct ≤ 0）→黄灯；今日涨→绿灯。
    /// 平盘归黄灯而非绿灯：引擎侧 sh_ok = (change_pct > threshold)，threshold 默认 0，
    /// 平盘 0 > 0 = False → sh_ok=False → 黄灯，App 实时灯须对齐此口径。
    /// 实时灯是否正在拉取中（**在飞去重**标志）。
    ///
    /// ⚠ 需要去重：`realtimeLightFetchedAt` 在任务**开始前**已写入，同一秒内多次进入
    ///   （看板 .task + 手动刷新 + 指数拉取完成回调同时触发）若不去重会并发发多个重复请求。
    ///   ⚠ 不改 async 的取舍：调用方 `refresh()` 是**同步**入口（全 App 几十处），改成 async
    ///     要一路传播；而 Store 是进程级单例，"随视图取消"本身无意义，真正的风险（重复请求）
    ///     由本标志 + 60s stale 守卫闭合。
    /// ⚠ `@ObservationIgnored`：纯内部"飞去重"标记，**没有任何 View / body 读它**
    ///   ⇒ 避免每次状态翻转都登记 / 失效依赖（与 `selftestTimer` 同理由）。
    @ObservationIgnored
    private var realtimeLightFetching = false

    func computeRealtimeLight(force: Bool = false) {
        // ⚠ 预览模式抑制网络拉取（#Preview 只渲染已落库数据）
        guard !previewMode else { return }
        guard !isHistorical else { realtimeLightLevel = nil; return }
        guard let todayPct = liveIndex?["change_pct"].double else { return }
        let stale = realtimeLightFetchedAt.map { Date().timeIntervalSince($0) > 60 } ?? true
        guard force || stale else { return }
        guard !realtimeLightFetching else { return }
        realtimeLightFetching = true
        realtimeLightFetchedAt = Date()
        Task { [weak self] in
            defer { self?.realtimeLightFetching = false }
            guard let diffs = await LiveQuotes.fetchRecentDiffs() else { return }
            let seq = [todayPct] + diffs
            var streak = 0
            for d in seq {
                if d < 0 { streak += 1 }
                else { break }
            }
            let level: MarketLightLevel
            if streak >= 2 { level = .red }
            else if todayPct <= 0 { level = .yellow }
            else { level = .green }
            await MainActor.run {
                guard let self else { return }
                self.realtimeLightLevel = level
                self.realtimeLightDecline = streak
            }
        }
    }

    /// 实时 3 日趋势（腾讯日K回填）：按交易日缓存——同一天内反复进看板不重拉
    private(set) var live3dTrend: String?
    /// ⚠ `@ObservationIgnored`：纯内部缓存日期，**没有任何 View / body 读它** ⇒ 避免登记依赖。
    @ObservationIgnored
    private var live3dTrendDate: String?
    /// 3 日趋势是否正在拉取中（在飞去重；取舍同 `realtimeLightFetching`）
    /// ⚠ `@ObservationIgnored`：纯内部"飞去重"标记，**没有任何 View / body 读它** ⇒ 避免每次状态翻转登记 / 失效依赖。
    @ObservationIgnored
    private var live3dTrendFetching = false

    /// 拉取（或复用当日缓存）3 日趋势；看板 .task 调用
    func loadLive3dTrendIfNeeded(force: Bool = false) {
        // ⚠ 预览模式抑制网络拉取（#Preview 只渲染已落库数据）
        guard !previewMode else { return }
        let key = today
        if !force, live3dTrendDate == key, live3dTrend != nil { return }
        // ⚠ 在飞去重：两处进入（手动刷新按钮 + .task）同时触发时，缓存键在任务完成前仍是旧的，
        //   不去重会并发重复请求。
        guard !live3dTrendFetching else { return }
        live3dTrendFetching = true
        Task { [weak self] in
            defer { self?.live3dTrendFetching = false }
            if let t = await LiveQuotes.fetch3DayTrend() {
                await MainActor.run {
                    self?.live3dTrend = t
                    self?.live3dTrendDate = key
                }
            }
        }
    }

    /// 兼容入口：引擎任务完成 / 手动刷新今天
    func refreshToday() { refresh() }

    func loadRound(slot: Int, date: String? = nil) {
        let d = date ?? viewDate
        roundDetails[slot] = reader.roundDetail(date: d, slot: slot)
        // ⚠ 顺带刷「该日全部轮次的分数快照」（结果页每行的「三轮分」列用）：
        //   一次查询（该日 picks 只有几十行）而不是每行一次；与 `roundDetails` 同一次触发。
        roundScores = reader.roundScores(date: d)
    }

    func loadHistory(date: String) {
        historyRecord = reader.history(date: date).map(HistoryRecord.init)
    }

    /// 生效参数的**档位门槛**（一档 / 二档），供界面判定"是否达标"。
    ///
    /// ⚠ **必须缓存，不许在视图里现算**：`ParamStore.shared.activeParams()` 每次都会
    ///   `ensureBuiltinSeeded()` + 读库 + 解析 JSON —— 在视图 `body` 里读它等于每次重绘查一次库。
    ///   故在 `refreshParams()` 里刷新，而它是**所有参数写操作的唯一收口**
    ///   （`runParamWrite` 激活/删除、`runParamWriteValue` 保存版本都调它）。
    ///
    /// ⚠ `nil` = **读不到参数** → 界面**不表态**（不画"达标"胶囊、不给档位色，落中性灰），
    ///   而不是拿一个写死的数冒充生效门槛。
    ///
    /// ⚠ 界面硬编码门槛会与参数生效值漂移（引擎侧都从参数读）→ 界面会给出**错误的"达标"结论**。
    private(set) var tier1Min: Int?
    private(set) var tier2Min: Int?

    func refreshParams() {
        // ⚠ 必须走 `ParamStore.listVersions()`（唯一权威实现）：它才带 `deletable` 裁决字段。
        //   读不含 deletable 的只读副本会让界面回退到旧规则、把"可删的出厂版本"显示成不可删
        //   （规则写两份必然漂移）。
        paramVersions = ParamStore.shared.listVersions().map { ParamVersionRow(JSONValue($0)) }
        // 档位门槛与版本列表同批刷新（见 `tier1Min` 的注释：这里也是**唯一**的刷新点）
        let tiers = ((ParamStore.shared.activeParams()?["scoring"] as? [String: Any])?["tiers"]
                     as? [String: Any]) ?? [:]
        tier1Min = ParamStore.intOf(tiers["tier1_min"])
        tier2Min = ParamStore.intOf(tiers["tier2_min"])
    }

    /// 参数快照（参数中心：编辑器表单基线、「与激活版本差异」比对）。
    ///
    /// **故意不缓存**：若把 schema 存成全局值、只在 nil 时拉取，打开「编辑指定版本」会把它
    /// 永久替换成该版本的 schema，之后再开全局编辑器时 diff 基线是**上一个版本的值**
    /// → 另存出的新版本参数错误（写坏参数，比崩溃更危险）。
    /// ⇒ 调用方（`ParamEditor`）自己持有（@State），每次切目标都重取。
    ///
    /// 元数据随包 + 参数直读库 → **原生拼装**。元数据/参数不可读时明确报错，不静默给空表单。
    func paramsSnapshot(version: String? = nil) -> [String: Any]? {
        guard ParamSchema.shared.isAvailable, ParamStore.shared.paramsForSchema(version: version) != nil
        else {
            lastError = ParamSchema.shared.isAvailable
                ? "激活参数不可读（数据库与随包文件都读不到），无法打开参数编辑器"
                : "参数元数据不可用（随包 JSON 缺失或损坏），无法打开参数编辑器"
            lastErrorKey = "param_meta"
            ToastCenter.shared.show(lastError ?? "打开失败", style: .error)
            return nil
        }
        return ParamStore.shared.paramsForSchema(version: version)
    }

    /// 个股搜索数据源（securities 表缓存，本地读取）
    private(set) var stockList: [JSONValue] = []

    func loadStockList() {
        guard stockList.isEmpty else { return }
        stockList = reader.stockList()
        if stockList.isEmpty {
            // 表为空（升级后首次取数前 / 全新安装未取数）→ 回落**随包基线**（纯本地、不触网）。
            // 不兜底的话 `addWatch` 会因 code→name 解析不到而直接拒绝加自选。
            stockList = DataSources.baselineStockList().map {
                JSONValue(["code": $0["code"] ?? "", "name": $0["name"] ?? ""])
            }
        }
    }

    // MARK: 基金列表（F15：自选页搜索按名称匹配场内基金）

    /// 场内基金 [{code,name,market,kind}]（懒加载；与扫描池 securities 完全隔离）
    private(set) var fundList: [JSONValue] = []
    /// 是否正在抓取基金列表（UI 显示"正在加载基金列表…"）
    private(set) var fundListLoading = false
    /// ⚠ `@ObservationIgnored`：纯内部"已加载"标记，**没有任何 View / body 读它** ⇒ 避免状态翻转登记依赖。
    @ObservationIgnored
    private var fundListLoaded = false

    /// 懒加载基金列表：先读缓存（毫秒级），缓存为空/过期时**后台**抓主源（约 10s，不阻塞 UI）。
    /// 搜索框获得焦点时调用；重复调用无副作用。
    func loadFundList() {
        guard !fundListLoaded, !fundListLoading else { return }
        let (cacheDate, cached) = FundCache.shared.load()
        fundList = cached.map { JSONValue($0) }
        fundListLoaded = true
        // 缓存新鲜 → 直接用（免网络）；否则后台抓一次（约 10s，不阻塞 UI）
        guard cached.isEmpty || !DataSources.isFundCacheFresh(cacheDate) else { return }

        fundListLoading = true
        Task.detached(priority: .utility) { [weak self] in
            let list = DataSources.fetchFundList()          // 同步阻塞，跑在后台
            await MainActor.run {
                guard let self else { return }
                self.fundList = list.map { JSONValue($0) }
                self.fundListLoading = false
                if list.isEmpty {
                    self.lastError = "基金列表获取失败（可稍后在搜索框重试）"
                    self.lastErrorKey = "fundList"
                    // 横幅已门控到库级故障 → 这里不补 toast 就静默了（非关键列表，中性提醒档）
                    ToastCenter.shared.show("基金列表获取失败（可稍后在搜索框重试）", style: .warning)
                }
            }
        }
    }

    /// 手动刷新基金列表（搜索框内的刷新按钮；绕过 7 天 TTL 强制抓一次）
    func refreshFundList() {
        guard !fundListLoading else { return }
        fundListLoading = true
        Task.detached(priority: .utility) { [weak self] in
            let list = DataSources.fetchFundList(refresh: true)
            await MainActor.run {
                guard let self else { return }
                self.fundList = list.map { JSONValue($0) }
                self.fundListLoaded = true
                self.fundListLoading = false
                // ⚠ 失败与成功**必须分档**：走默认 `.success` 会让"获取失败"是**绿色**的（看着像成功）。
                if list.isEmpty {
                    ToastCenter.shared.show("基金列表获取失败", style: .error)
                } else {
                    ToastCenter.shared.show("基金列表已更新（\(list.count) 只）")
                }
            }
        }
    }

    // MARK: 港股列表（自选页搜索按名称匹配港股）

    /// 港股 [{code,name}]（懒加载；只服务自选搜索，不进扫描池也不进基金池）
    private(set) var hkList: [JSONValue] = []
    /// 是否正在抓取港股列表（UI 显示"正在加载港股列表…"）
    private(set) var hkListLoading = false
    /// ⚠ `@ObservationIgnored`：纯内部"已加载"标记，**没有任何 View / body 读它** ⇒ 避免状态翻转登记依赖。
    @ObservationIgnored
    private var hkListLoaded = false

    /// 懒加载港股列表：先读缓存（毫秒级），缓存为空/过期时**后台**抓主源
    /// （~2600 只约 44 页、约 10s，不阻塞 UI）。重复调用无副作用。
    func loadHkList() {
        guard !hkListLoaded, !hkListLoading else { return }
        let (cacheDate, cached) = HkCache.shared.load()
        hkList = cached.map { JSONValue($0) }
        hkListLoaded = true
        guard cached.isEmpty || !DataSources.isHkCacheFresh(cacheDate) else { return }

        hkListLoading = true
        Task.detached(priority: .utility) { [weak self] in
            let list = DataSources.fetchHkList()            // 同步阻塞，跑在后台
            await MainActor.run {
                guard let self else { return }
                self.hkList = list.map { JSONValue($0) }
                self.hkListLoading = false
                if list.isEmpty {
                    self.lastError = "港股列表获取失败（可稍后在搜索框重试）"
                    self.lastErrorKey = "hkList"
                    ToastCenter.shared.show("港股列表获取失败（可稍后在搜索框重试）", style: .warning)
                }
            }
        }
    }

    /// 手动刷新港股列表（搜索框内的重试入口；绕过 7 天 TTL 强制抓一次）
    func refreshHkList() {
        guard !hkListLoading else { return }
        hkListLoading = true
        Task.detached(priority: .utility) { [weak self] in
            let list = DataSources.fetchHkList(refresh: true)
            await MainActor.run {
                guard let self else { return }
                self.hkList = list.map { JSONValue($0) }
                self.hkListLoaded = true
                self.hkListLoading = false
                // ⚠ 同上（基金列表那处的注释）：失败不许走默认的成功样式
                if list.isEmpty {
                    ToastCenter.shared.show("港股列表获取失败", style: .error)
                } else {
                    ToastCenter.shared.show("港股列表已更新（\(list.count) 只）")
                }
            }
        }
    }

    /// 保存全局编辑：diff 另存为新版本并激活
    /// - Parameters:
    ///   - name: 新版本名
    ///   - diff: 点路径→新值的差异表（与激活版本合并；校验通过才落库）
    ///   - note: 备注
    ///   - activate: 保存后是否立即激活
    /// - Returns: 新版本是否已成功落库（校验失败 / 写入抛错返 false；若已落库但仅激活失败返 true，
    ///            此时版本已在库里，界面不应保留会触发重名的未保存草稿）
    ///
    /// 校验（类型/范围/区间倒挂/跨参数一致性）+ 合并 + 落库全在原生完成。
    /// 校验结论直接展示、**不回落**（回落只会得到同一条拒绝）；
    /// 只看进程退出码会把校验失败当成功 → 假成功。
    @discardableResult
    func saveGlobalParams(name: String, diff: [String: Any], note: String = "", activate: Bool = true) -> Bool {
        runParamWriteValue(
            native: { try ParamStore.shared.saveEditedVersion(name: name, diff: diff, note: note) },
            successMessage: activate ? "参数已保存并激活 \(name)" : "参数已保存",
            onSuccess: {
                guard activate else { return "" }
                // 激活结论必须显式回传：`try?` 会把抛错与 `false` 返回值**一起吞掉** ——
                // 校验与落库都成功、但激活没生效时，界面照样弹"参数已保存并激活"（假成功）。
                // 与 `runParamWrite` 的 `guard ok else` 同口径：激活失败必须报出，不允许静默。
                // 注意措辞：版本此时**已落库**，所以是"已保存但未生效"，不是"保存失败"。
                do {
                    if try !ParamStore.shared.activate(name) {
                        return "已保存「\(name)」，但激活失败：版本不存在（仍在使用原参数）"
                    }
                } catch {
                    let why = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                    return "已保存「\(name)」，但激活失败：\(why)（仍在使用原参数）"
                }
                return ""
            })
    }

    /// 只改版本描述（不碰参数）。出厂与用户版本都可改：出厂行落库后即用户数据，
    /// 启动补种不会覆盖（恢复出厂设置才会）。
    @discardableResult
    func setParamNote(name: String, note: String) -> Bool {
        runParamWriteValue(
            native: { try ParamStore.shared.setNote(name: name, note: note) ? "" : "版本不存在：\(name)" },
            successMessage: "描述已更新")
    }

    /// 恢复出厂设置：出厂清单版本用随包文件覆盖（参数 + 描述），用户版本不动。
    func restoreFactoryParams() {
        runParamWriteValue(
            native: {
                let n = try ParamStore.shared.restoreBuiltins()
                return n == 0 ? "没有可恢复的出厂版本（随包文件不可用）" : ""
            },
            successMessage: "出厂版本已恢复为随包默认")
    }

    /// 参数写入（返回错误串、空串=成功）的统一入口。
    ///
    /// 关键取舍：非空错误串是**有效结论**（校验不过 / 出厂版本名 / 空名），直接展示；
    /// 元数据不可用或抛错（I/O）则明确报错。
    ///
    /// `onSuccess` 是**后置步骤**（落库成功后的激活等），同样按"错误串、空串=成功"
    /// 回传结论：它的失败发生在写入**之后**，措辞必须由它自己给（"已保存但未生效"），
    /// 不能并进上面的"写入失败"。
    /// - Returns: 主写入是否已成功落库（用于调用方决定是否清空草稿/关闭编辑态）
    @discardableResult
    private func runParamWriteValue(native: () throws -> String,
                                    successMessage: String,
                                    onSuccess: @MainActor () -> String = { "" }) -> Bool {
        let key = "param"
        guard !busy.contains(key) else { return false }
        guard ParamSchema.shared.isAvailable else {
            lastError = "参数元数据不可用（随包 JSON 缺失或损坏），无法保存"
            lastErrorKey = key
            ToastCenter.shared.show("保存失败：参数元数据不可用", style: .error)
            return false
        }
        busy.insert(key)
        do {
            let err = try native()
            busy.remove(key)
            guard err.isEmpty else {
                lastError = err
                lastErrorKey = key
                ToastCenter.shared.show(err, style: .error)
                return false
            }
            if lastErrorKey == key { lastError = nil; lastErrorKey = nil }
            let postError = onSuccess()
            // 后置步骤失败也要刷新：版本**已经落库**（native 成功），列表得显示出来，
            // 否则用户看到报错后会以为这次保存整个丢了
            refreshParams()
            guard postError.isEmpty else {
                lastError = postError
                lastErrorKey = key
                ToastCenter.shared.show(postError, style: .error)
                return true
            }
            ToastCenter.shared.show(successMessage)
            return true
        } catch {
            busy.remove(key)
            let why = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            lastError = "参数写入失败：\(why)"
            lastErrorKey = key
            ToastCenter.shared.show(lastError ?? "写入失败", style: .error)
            return false
        }
    }

    // MARK: - 跨文件 extension 共享的存储属性
    //
    // ⚠ Swift 的存储属性**不能声明在 extension 里**，而它们的读写方拆在
    // StoreWatch / StoreRefresh / StoreTune / StoreRounds 等文件，故集中到这里；
    // 同时从 `private(set)` / `private` 放宽到 module-internal ——
    // 跨文件的 extension 访问不到另一个文件里的 private 成员。
    var stockDetail: StockDetailTarget?
    /// 自选分组（库行实体）
    var watchGroups: [WatchGroupRow] = []
    /// 自选列表（含分组与手动持仓信息；库行实体）
    var watchItems: [WatchItemRow] = []
    /// **分组归属**（`code → 该股所属的全部分组 id`）。
    ///
    /// ⚠ 为什么不能只看 `WatchItemRow.groupId`：那一列是**主分组**
    ///   （`watchlist.group_id`，同步为归属里**最小**的那个）。
    ///   **列表按分组过滤**必须用本字段，否则"复制到分组"出来的票在目标分组里看不见。
    /// ⚠ 消费方**只有自选列表的过滤**；持仓视图 / 判定 / 提醒仍按 `watchItems`（一只一次）。
    var watchMemberships: [String: Set<Int>] = [:]
    /// 今日（或最近判定日）判定结果（库行实体）
    var watchJudgments: [WatchJudgmentRow] = []
    /// 判定日（展示口径）
    var watchDate: String = ""
    /// 自选实时行情（code → quote）。
    ///
    /// ⚠ **由 `AlertMonitor` 轮询并写入，视图只读**。"显示"与"告警"共用**同一批**行情，
    /// 不会出现两路各拉一次拿到同一时刻两个价的情况（轮询也不能挂视图 `.task` —— 切页即取消）。
    var liveQuotes: [String: StockQuote] = [:]
    /// 自选/持仓行情最近一次成功写入时刻（看板持仓卡显示"实时 HH:mm:ss"用）
    var liveQuotesUpdatedAt: Date?
    /// 配了提醒的代码 → 规则（铃铛图标"已设置 / 未设置"的判据）。
    ///
    /// ⚠ 这里**只放规则，不放触发状态**（`last_fired_*`）—— 触发状态每次评估都在变，
    /// 写进 `@Observable` 会让整页 body 每 5 秒重算一次（设置页卡顿的同一类成因）。
    var alertRulesByCode: [String: [AlertRule]] = [:]
    /// 配了提醒的代码 → 提醒时间窗。
    ///
    /// ⚠ 与 `alertRulesByCode` **同一个理由**必须上到 Store：设置页的「提醒一览」要逐行显示
    ///   时间窗，而在 `body` 里逐行调 `AlertStore.window(code:)` 就是**主线程同步 I/O**（每行一次 SQLite 查询）。
    var alertWindowsByCode: [String: AlertWindow] = [:]
    /// 实时指数是否拉取中（看板 hero 占位用：首次无数据时显示骨架而非"—"）
    var liveIndexFetching = false
    var tuneReport: TuneResult?
    var tuneRunning = false
    /// 自检报告最近一次成功时间
    var lastSelftestAt: Date?
    /// 1 小时定时自检（设置页常驻数据源健康）。
    /// ⚠ `@ObservationIgnored`：AppKit 句柄不参与 UI 渲染 ——
    ///   UI 依赖的是派生属性 `lastSelftestAt/selftestReport`，此属性被观察纯属浪费。
    @ObservationIgnored var selftestTimer: Timer?

    // MARK: - 历史回放（动作在 StoreReplay.swift）

    /// 日K缓存概况（codes / bars / 首尾日）
    var replayCache: HistoryBarStore.Stats?
    /// 正在读取缓存概况的任务数（>0 = 读取中）。
    ///
    /// ⚠ 用**计数**而不是 `Bool`：快速连点「刷新」会有多个读取在飞，
    /// 用 Bool 会被先完成的那个提前清掉 → 界面在还有读取没回来时就显示"缓存为空"。
    var replayCacheLoadsInFlight = 0
    /// 已记录"请求过哪个窗口"的代码数（含指数符号）
    var replayCoveredCodes = 0
    /// 指数缓存里的交易日数 —— 也就是**能回放的历史长度上限**
    var replayIndexDayCount = 0
    /// 下载进度：已完成 / 总数（`total == 0` = 没在下载）
    var replayDownloadDone = 0
    var replayDownloadTotal = 0
    /// 正在回放的日期（`nil` = 没在回放）
    var replayRunningDay: String?
    /// 回放进度：第几天 / 共几天（`total == 0` = 没在回放）
    var replayProgressIndex = 0
    var replayProgressTotal = 0
    /// 逐日结果（与 `days` 等长同序，跳过的也在里面）
    var replayResults: [HistoryReplayJob.DayResult] = []
    /// 结果摘要（一行）
    var replaySummary: String?
    /// 下载 / 回放的取消标志。
    ///
    /// ⚠ 必须是**跨线程可读**的独立对象：它由后台线程轮询、由主 actor 写，
    /// 而 `@Observable` 的属性只能在主 actor 上安全访问（直接读会数据竞争）。
    /// ⚠ `@ObservationIgnored`：UI 从不直接读它（UI 依赖的是 `replayDownloadDone/Total` 等转发值）——
    ///   每次赋值都触发 observation 通知，下载全市场约 5000 只时构成数千次无效 diff。
    @ObservationIgnored var replayCancel = ReplayCancelFlag()
    /// 下载进度中转（后台线程 → 主 actor）。理由同上。
    @ObservationIgnored var replayProgressRelay = ReplayProgressRelay()

    /// 窗口的 `UndoManager`（由 `AppShellView` 在 `.task` 里注入）——「移出自选 / 清仓」的撤销入口。
    ///
    /// ## 为什么放 Store 而不是在各视图里注册
    /// 移出自选有 **3 个入口**（自选行右键 / 悬停按钮 / 个股详情页的"去掉自选"），
    /// 写操作全部经 Store ⇒ 撤销注册也在**同一层**，否则"每个视图各写一份"必然漏一处（两套入口两套标准）。
    /// ⚠ `weak`：`UndoManager` 归窗口所有，而 Store 是与 App 同命的单例 ——
    ///   强引用会把窗口的生命周期绑到单例上（窗口关了还被句柄持有）。
    /// ⚠ 标 `@ObservationIgnored`：它不是 UI 状态，标了才不会让每次注入触发一次全量重绘。
    @ObservationIgnored weak var undoManager: UndoManager?

    // MARK: - 指数成份（动作在 StoreProfile.swift）

    /// 各指数的成份数（`index_code → 只数`）
    var indexMemberCounts: [String: Int] = [:]
    /// 各指数最近一次刷新时间
    var indexMembersFetchedAt: [String: String] = [:]
    /// 正在刷新
    var indexMembersRefreshing = false

    // MARK: - 基本面（动作在 StoreProfile.swift）

    /// 基本面表覆盖的只数（0 = 还没抓过 → 详情页卡片不显示）
    var fundamentalStockCount = 0
    /// 其中**至少一项有值**的只数（⚠ 与总数分开 —— 退市/停牌票会全 `-`）
    var fundamentalWithData = 0
    var fundamentalRefreshing = false
    /// 最近一次**成功**刷新的时间（`yyyy-MM-dd HH:mm:ss`）—— 卡上只显示它，不显示结果摘要
    /// （摘要只由 toast 说一处；卡上留时间当参考）
    var fundamentalLastFetched: String?

}
