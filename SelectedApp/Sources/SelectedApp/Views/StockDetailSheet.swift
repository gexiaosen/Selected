import SwiftUI
import AppKit
import SwiftTradingView
import SelectedCore

// MARK: - 个股详情弹窗（实时行情 + 指标网格 + K线/分时图）
// 任何页面个股行点击弹出；数据实时拉取（行情 5s 轮询，K线按周期加载）

struct StockDetailSheet: View {
    /// 目标个股：代码（纯数字）+ 名称
    let code: String
    let stockName: String

    @Environment(\.dismiss) private var dismiss
    @State var quote: StockQuote?
    @State var quoteFailed = false
    /// 图表周期。**默认分时**（2026-10-19 老板要求：打开详情先看当日走势）。
    ///
    /// ⚠ 默认分时不等于"日K派生卡片消失" —— 那些卡片的判据全部按「一根 bar = 一个交易日」
    ///   定义，所以它们读的是**独立加载的** `dailyKline`（见下方），与图表周期解耦。
    ///   别把它们改回 `kline`：`kline` 只在 `period == .daily` 时才是日K。
    @State var period: KLinePeriod = .minute
    /// **图表**当前周期的 K 线（分时/周K/月K 时对应周期的 bar；分时模式下为 `[]`）
    @State var kline: [KLineItem] = []
    /// **日K**（与图表周期解耦）—— 所有"按交易日定义"的派生卡片与异动量能判据都用它：
    /// 筹码分布 / K 线形态 / 技术指标 / 回撤风险 / 策略命中 / 超买超卖 / 异动提示的量能倍数。
    ///
    /// ⚠ 默认周期是分时（`kline` 为空），若这些消费方读 `kline`，卡片会整批消失、
    ///   且「放量大跌」这类异动**永远判不出来**（空数组 → 量能倍数 nil）—— 不报错、只是没有。
    /// ⚠ 只在打开详情时取一次（500 根，与图表切到日K时的请求同源同参数）；切周期不重取。
    @State var dailyKline: [KLineItem] = []
    /// `dailyKline` 是按哪个代码取的（`fullCode` 会先按推断值到达、再被行情纠正 → 变了要重取）
    @State var dailyKlineCode = ""
    /// 日K是否还在加载（首帧显示骨架，而不是"卡片整批消失再出现"）
    @State var dailyKlineLoading = true
    /// 左侧是否还有更早历史（K 线分页加载用）
    @State var hasMoreHistory = false
    /// 更早历史是否正在加载（防重复触发）
    @State var loadingMoreHistory = false
    @State var minute: [MinutePoint] = []
    @State var chartKLineSource: KLineSource? = nil
    @State var chartKLineAdjusted = true
    @State var chartMinuteFallback = false
    @State var chartLoading = true
    /// 图表区**实测宽度**（0 = 还没量到）。
    ///
    /// ⚠ 宽度没量到之前不渲染图表：库的 `candleWidth` 初值取 `initialCandleWidth`（写死 8），
    ///   而首帧 `viewportWidth` 还是 0，布局完成后才被钳到 `fitCandleWidth`
    ///   ⇒ 首帧是错的宽度、随即被改 → 视觉上"跳一下"。先量宽再渲染，一次画对；
    ///   首帧的滚动位移由 `ChartFirstFrameMask` 遮盖。
    @State var chartWidth: CGFloat = 0
    // ⚠ 「图表已画稳」的遮罩状态**不在本页面**，而是 `ChartFirstFrameMask`
    //   子视图自己的 `@State` —— 放在页面里会**跨图表重建存活**（切周期时新图第一帧可见 ⇒
    //   库的 scrollTo 滚动被看见 = 跳动）。别再把它加回页面。
    /// 是否允许「拖到最左自动加载更早历史」。
    ///
    /// ⚠ **首帧必须禁用**：库的触发条件是 `scrollOffset <= step * 3`，而首帧的
    ///   `scrollOffset` 必然是 0（库的 `scrollTo("chartEnd")` 要等 `scrollViewProxy`
    ///   被赋值后才跑，那时 `onPreferenceChange` 可能已用 0 判过一轮）
    ///   ⇒ 一打开就会误触发、白拉一页 500 根。这与「内容有没有滚动空间」无关。
    ///   ⇒ 打开后等一小段再放开（见下方 `.task { rearmLoadEarlier() }`）。
    ///   ⚠ `@State` 随 `.id(target.code)` 重建而重置 ⇒ 换股票后自动重新禁用 ✓
    @State var allowLoadEarlier = false
    /// 失败原因（nil = 无失败）。区分"请求失败"与"该周期无数据"，避免一句笼统的"加载失败"
    @State var chartError: String?
    /// 手动重试触发器（自增即触发 .task 重跑）
    @State var reloadToken = 0
    // MARK: 盘口列（图表右侧：五档常驻 + 成交明细可折叠）—— 视图与取数在 +OrderBook.swift
    //   ⚠ 分时页不放这一列，原因写在 `StockDetailSheet+OrderBook.swift` 文件头
    //   （分时的 240 槽宽度是写死的，视口变窄会把下午裁掉）。
    @State var depth: QuoteDepth?
    @State var depthLoading = true
    @State var depthFailed = false
    @State var ticks: [TickTrade] = []
    /// 该标的在分笔接口上就没有数据（北交所/港股/指数）—— 与"这次没取到"分开标
    @State var ticksUnavailable = false
    /// 分笔请求遇到瞬时网络/解析失败 —— 与 `ticksUnavailable` 分开标，避免误判"该接口无数据"
    @State var ticksFailed = false
    /// 折叠状态持久化：下次打开详情还在同一个形态（与 `ChartSubPlot.defaultsKey` 同一套惯例）
    @AppStorage(StockDetailSheet.BookPrefs.ticksOpenKey) var ticksOpen = false
    /// 该票所属的指数**显示名**（沪深300 / 中证500 / 上证50）。
    ///
    /// ⚠ 用 `@State` 缓存：本页行情每 1~5 秒轮询一次，若在 `body` 里现查库，
    /// 每一帧都会打一次 SQL（`SQLiteReader` 还是**主线程共享连接**）。
    /// 指数成份是**季度级**变化的数据，页面打开时查一次足够。
    /// ⚠ 「个股静态档案」的唯一持有者：指数徽章 / 基本面两个字段
    ///   都在这里（一次查完，View 只读不查）。
    /// ⚠ 必须用 `@State` 持有：`@Observable` 的 Observation 追踪依赖**存储在 State 里**，
    ///   裸 `let`/`private var` 属性不会订阅，View 不会因 `loadProfile` 赋值而刷新。
    @State private var detailStore = StockDetailStore()

    // MARK: 静态档案的只读转发（数据只存在于 detailStore，View 不存副本）
    //
    // ⚠ 可见性**必须**是 module-internal（不能 `private`）—— 读写方在
    //   `StockDetailSheet+Oscillator.swift`（`stockFundamentals`）这个**跨文件 extension** 里，
    //   而 Swift 的 `private` 只对**同一文件**可见。
    var indexBadges: [String] { detailStore.indexBadges }
    var stockFundamentals: Fundamental.Item? { detailStore.stockFundamentals }
    // 指数徽章：表里没有该票 → `nil` → 徽章不显示。
    // 基本面：打开时查一次即可 —— 基本面是**季度级**慢变量，不必轮询；表里没有/没抓过 → `nil` → 卡片不显示。
    // 行情轮询不再需要独立句柄：整个循环在 `.task { await runQuoteLoop() }` 里跑，
    // 由 SwiftUI 的生命周期负责取消
    // 次日高低点区间（统计估计）：点开详情即算，不用手输代码
    @State var fc: ForecastResult?
    @State var fcLoading = true
    @State var fcError: String?
    @State var showForecastSheet = false
    /// Oscillators 判读阈值（B 域 `indicator_params`）。
    /// ⚠ 用 `@State` 缓存 + `.task` 取：body 里现查库违反"视图不 poke 库"纪律
    ///   （本页行情 1~5 秒轮询，每次 body 求值都查一遍 = 白刷磁盘）。
    @State var oscConfig = Oscillators.Config()
    /// "去掉自选"的确认弹窗：详情页与自选页同为不可撤销操作，必须先确认再删。
    @State private var showRemoveConfirm = false
    /// 「拖到最左加载更早历史」的进行中任务句柄。
    ///
    /// ⚠ 必须有句柄：裸 `Task { }` 时快速连续拖到最左会并发多个 `loadEarlierHistory`，
    ///   且关闭详情页后请求还在飞；收口到句柄后，详情页消失 / 切周期时取消。
    ///   ⚠ 不加 `private`：`onLoadEarlier` 闭包与 `.onDisappear` 在跨文件 extension 里。
    @State var loadEarlierTask: Task<Void, Never>?
    /// 「加载更早历史」解锁任务的句柄（切周期时会重新上锁；onDisappear 取消）
    @State var rearmTask: Task<Void, Never>?
    /// 近 N 日资金流（升序）。库里有就用库，不够时回源一次并落库 —— 见 `loadFundFlow()`。
    @State var fundFlow: [FundFlowPoint] = []
    @State var fundFlowLoading = true
    /// 该代码不在 `securities` 里（ETF / 指数 / 冷门代码）→ 整张卡隐藏。
    /// `stock_fund_flows` 的口径是「A 股个股」，见 `FundFlowStore.isKnownStock`。
    @State var fundFlowUnsupported = false
    /// 龙虎榜：最近一次上榜的**派生**视图（原因 / 金额 / 席位）。
    /// **只读库、不回源** —— 理由见 `lhbCard` 的「数据从哪来」。
    @State var lhb: LhbDigest.Card?
    /// `primary` 那条口径的席位明细（买 5 + 卖 5）
    @State var lhbSeats: [LhbSeat] = []
    /// `stock_lhb` 表内的最新日期。**没有记录时靠它区分「未上榜」与「还没抓」** —— 见 `loadLhb()`。
    @State var lhbCoverage: String?
    @State var lhbLoading = true
    /// 最近一次涨停的记录。
    ///
    /// ⚠ 表只覆盖**最近约 10 余个交易日**（源的限制，不是实现）→ 卡上必须写清"库内最近 N 天"，
    /// 否则"没有涨停记录"会被读成"从来没涨停过"。
    @State var limitUpRecord: LimitUpRecord?
    /// 库里已有多少个交易日的涨停池（0 = 还没抓过 → 整张卡不显示）
    @State var limitUpCoveredDays = 0
    /// 尾盘结构。**只读展示**，按需取一次 5 分钟线 —— 见 `loadIntraday()`。
    @State var intraday: IntradayFeatures?
    /// 该特征对应的交易日（可能是**上一个交易日** —— 周末/开盘前也看得到完整尾盘结构）
    @State var intradayDay = ""
    /// 行情是否取自**实时**；false = 由当日 bar 重建（见 `IntradayDigest`）
    @State var intradayLive = false
    /// 计算时**实际用的**参数（显示在口径里：否则"界面窗口 ≠ 引擎窗口"看不出来）
    @State var intradayWindowMin = 30
    @State var intradayMinBars = 20
    @State var intradayLoading = true
    /// 该代码不在 `securities` 里（ETF / 指数）→ 整张卡隐藏：引擎的尾盘结构只对 A 股个股算
    @State var intradayUnsupported = false
    /// **原始** 5 分钟线（含前几天）。
    ///
    /// ⚠ 必须留着：`IntradayDigest.pickLatest` 只返回**选中那一天**的 bar，
    /// 而「早盘抢筹」的量比是**跨日同窗口对比**（今日早盘量 ÷ 前 N 日同时段均量）
    /// —— 需要前几天的 bar。同一份响应里本来就有（新浪一次给约 4~5 天），零额外请求。
    @State var intradayRawBars: [MinuteBar] = []
    /// K 线形态的识别阈值。从 `scoring.patterns` 读一次并缓存 ——
    /// ⚠ 不在计算属性里现读：`activeParams()` 每次都查库，而形态会随行情轮询重算。
    @State var patternCfg = PatternConfig()
    /// 形态的**打分配置**（`scoring.patterns` 的另一半：开关与分值）。
    ///
    /// ⚠ 同样必须缓存：详情页行情 1s/5s 轮询，若在 body 的渲染路径里现调
    ///   `PatternScoreConfig.from(ParamStore.shared.activeParams())` = 每秒一次读库 + JSON 解析。
    ///   与 `patternCfg` 在**同一次** `activeParams()` 里一起读（省一次查库）。
    @State var patternScoreCfg = PatternScoreConfig()

    /// 完整代码：优先用行情返回的（权威），未到达时用归一化推断（含北交所）。
    /// 注意 fullCode 变化会触发图表重载（见下方 .task(id:)），所以推断错了也能自愈。
    var fullCode: String { quote?.fullCode ?? StockQuotes.fullCode(code) }

    var body: some View {
        VStack(spacing: 0) {
            // 固定头部：名称 / 现价 / 涨跌 / 关键价。看 K 线时不随滚动消失（成熟行情软件的通行做法）
            priceHeader
            Divider()          // 全页只留这一条分割线，其余靠卡片与间距分组
            ScrollView {
                VStack(spacing: 12) {
                    chartCard       // 最常看的东西置顶
                    anomalyCard     // 异动提示（涨跌停/一字板/放量大跌；只在命中时出现）
                    watchCard       // 今日动作（仅自选股显示）
                    forecastCard    // 次日区间
                    chipCard        // 筹码分布（仅日K时显示；只展示、不参与评分）
                    patternCard     // K 线形态（仅日K时显示；只展示、不参与评分）
                    indicatorCard   // 技术指标四件套（仅日K时显示；只展示、不参与评分）
                    drawdownCard    // 回撤风险（仅日K时显示；只展示、不参与筛选）
                    strategyCard    // 策略命中（六条独立策略；仅日K时显示；只展示、不参与评分/筛选）
                    oscillatorCard  // 超买超卖（六条固定阈值信号；仅日K时显示；只展示、不参与评分）
                    intradayCard    // 尾盘结构（按需取一次 5 分钟线）
                    morningCard     // 早盘抢筹（同一份 5 分钟线，跨日同窗口口径）
                    fundFlowCard    // 资金流向（只展示、不参与评分）
                    lhbCard         // 龙虎榜（只展示、不参与评分）
                    limitUpCard     // 涨停统计（只展示、不参与评分）
                    metricsGrid     // 估值 / 活跃度
                    fundamentalCard // 基本面（★ C1；五组。只展示、不进评分/筛选）
                }
                .padding(14)
            }
            // macOS 浮层滚动条默认只在滚动时出现；详情页内容很长（图表下方还有 14 张卡），
            // 常显滚动条，打开就能看出下面还有内容。
            .scrollIndicators(.visible)
        }
        .frame(width: SheetMetrics.stockDetail.width)
        // 宽度固定 640（分时 240 槽按这个宽度算），高度可从 720 往下拖到 600。
        // ⚠ 内容根**不能**设 minHeight：窗口被拖到低于该值时，内容仍按 minHeight 布局，
        //   顶部固定头部会被裁掉（2026-10-20 实机反馈）。改为给**窗口**设下限；
        //   这里只声明「理想高度」720，让 SwiftUI 呈现时优先按 720 开，而不是拿窗口下限 600 当初始高度。
        .frame(minHeight: 0,
               idealHeight: SheetMetrics.stockDetail.height,
               maxHeight: .infinity)
        .background(SheetHeightResizer(minWidth: SheetMetrics.stockDetail.width,
                                       minHeight: stockDetailMinHeight,
                                       initialHeight: SheetMetrics.stockDetail.height))
        // ⚠ Esc 的归属（实测结论，**别凭直觉删任何一条**）：
        //   SwiftUI 的 sheet 自己就吃 Esc（不需要 `.cancelAction`）；「完整口径」是 `.popover`，
        //   而 popover 不吃 Esc ⇒ 一次 Esc 会同时关掉两层。三条实测：
        //   ① 只撤按钮的 Esc 绑定（`keyboardShortcutIf`）→ **照样关**：
        //      Esc 落回 sheet 自己的默认关闭路径（两个 handler 都没跑，sheet 就没了）
        //   ② 只加 `.interactiveDismissDisabled` → **照样关**：
        //      按钮的 keyEquivalent 先命中，而它的 `dismiss()` 是**程序化**关闭 ——
        //      本行只挡"交互式关闭"，挡不住它
        //   ③ **两件一起** → popover 关、详情页留着 ✅（连按第二次 Esc 才关详情页）
        //
        // ⚠ 本行**不挡**鼠标点「关闭」（那条也走 `dismiss()`）—— 加了它之后详情页仍关得掉，
        //   只是"按 Esc"这条路径被按层分派了。
        .interactiveDismissDisabled(showForecastSheet)
        .task(id: "\(code)|\(period)") { await runQuoteLoop() }
        // 当尾盘结构按降级重建（打开时 quote 还没到），首帧行情到达后增量重算一次
        .onChange(of: quote?.currentPrice) { _, _ in refreshIntradayWithQuoteIfNeeded() }
        .onChange(of: quote?.volume) { _, _ in refreshIntradayWithQuoteIfNeeded() }
        // 盘口列：打开取一次 + 每 30s 复检（与 Core 的 30s TTL 对齐）。
        // ⚠ 不并进 1 秒行情轮询：分笔是分页请求，每秒重取等于白打。
        .task { await runOrderBookLoop() }
        .task {
            let cfg = await Task.detached(priority: .userInitiated) {
                IndicatorParamStore.oscConfig()
            }.value
            guard !Task.isCancelled else { return }
            oscConfig = cfg
        }
        // ⚠ 切周期必须重新上锁 `allowLoadEarlier`：图表被 `.id(period)` 重建后，库又会在首帧
        //   报一次「偏移≈0」⇒ 此时若已放开，会误触发"加载更早历史"、白拉一页 500 根。
        //   与首帧误触发同一个成因（"库把首帧的 offset=0 当真"）。
        .onChange(of: period) { _, _ in rearmLoadEarlier() }
        .onDisappear { rearmTask?.cancel() }
        // 关键：id 同时含 fullCode 与 period —— 若只看 period，行情到达后 fullCode 与推断值
        // 不同（如北交所股票）时不会重载，表现为"打开详情经常无 K 线数据"。
        .task(id: "\(fullCode)|\(period)|\(reloadToken)") { await loadChart() }
        // ⚠ 打开后延迟放开「加载更早历史」（避开首帧 scrollOffset=0 的误触发，见 `allowLoadEarlier`）。
        //   ⚠ 代价：这 1.5 秒内用户若真拖到最左，不会立刻加载（松手再拖即可）。
        //     比「每次打开都白拉一页 500 根」划算。
        //   ⚠ 切周期时由 `.onChange(of: period)` 再上一遍锁（同一个成因，见那里的注释）。
        .task { rearmLoadEarlier() }
        .task(id: code) { await loadForecast() }
        .task(id: code) { await loadFundFlow() }
        .task(id: code) { await loadLhb() }
        .task(id: code) { await loadLimitUp() }
        .task(id: code) { await loadIntraday() }
        // 日K（供"按交易日定义"的派生卡片用）—— 与图表周期解耦，见 `dailyKline` 的注释。
        // ⚠ 用 `fullCode` 做 id：北交所等票的推断代码与行情返回的不一致，变了要重取。
        .task(id: fullCode) { await loadDailyBars() }
        // ⚠ 两个形态配置在**同一次** `activeParams()` 里读出（一次查库喂两个缓存）——
        //   见 `loadPatternConfigs()` 与 `patternScoreCfg` 的注释。
        .task(id: code) {
            let c = await Task.detached(priority: .userInitiated) {
                Self.loadPatternConfigs()
            }.value
            guard !Task.isCancelled else { return }
            patternCfg = c.cfg
            patternScoreCfg = c.scoreCfg
        }
        // 指数成份徽章 + 基本面：**一次查完**，收口到 `StockDetailStore.loadProfile`（后台独立只读连接）
        // —— View 里分开多次主线程同步查询违反「视图不 poke 库」纪律。
        // ⚠ 表不存在（老库未跑 Swift-only 迁移）时 `indicesOf` 返回空 → 徽章不显示、不报错。
        .task(id: code) { await detailStore.loadProfile(code: code) }
        // ⚠ "去掉自选"确认 —— 文案与自选页「移出自选」弹窗逐字一致。
        //   ⚠ 不挂 `.sheet`（本页就是 sheet，再套一层会 sheet-on-sheet），
        //      `.alert` 是模态卡片，无焦点陷阱，与 sheet 弹窗互不干扰。
        .alert("移出自选", isPresented: $showRemoveConfirm) {
            Button("移出自选", role: .destructive) {
                Store.shared.removeWatch(code: code)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将把「\(stockName)」从自选移除，判定历史保留，可按 ⌘Z 撤销。")
        }
        // ⚠ 详情页消失时取消"加载更早历史"在飞任务（孤儿请求收口）
        .onDisappear { loadEarlierTask?.cancel() }
        // ⚠ 这里**故意不再挂 `.sheet`**：详情页本身就是一个 `.sheet`，在它里面再 `.sheet` =
        //   sheet-on-sheet —— 焦点被套两层，关掉要"退两次"。
        //   ⇒ 改成把 `.popover` 挂在**触发它的按钮**上（见 `StockDetailSheet+Cards.swift` 的
        //     「完整口径」）—— popover **不是模态**：没有焦点陷阱、焦点始终在详情页
        //     （项目先例：`DateChip` 的日期选择器就是 popover）。
        //   ⚠ 但 popover **不吃 Esc**，而 **SwiftUI 的 sheet 自己就吃 Esc** →
        //     一次 Esc 会**同时**关掉两层。Esc 的归属靠**两件一起**：`priceHeader` 里撤掉
        //     关闭按钮的 Esc 绑定 ＋ 上面那行 `.interactiveDismissDisabled(showForecastSheet)`。
        //     ⚠ 完整的**三条实测**写在 `frame(...)` 下面那段注释里，别只读这里。
        // 轮询由上面 `.task(id: "\(code)|\(period)")` 的生命周期负责取消，无需手动 cancel
    }

    // MARK: 自选判定卡（在自选中才显示：动作/得分/持仓盈亏）

    @ViewBuilder
    private var watchCard: some View {
        if let item = Store.shared.watchItems.first(where: { $0.code == code }) {
            let j = Store.shared.watchJudgments.first { $0.code == code }
            // ⚠ 保持旧口径：`action` 缺失（无判定行）才是 nil，**空串仍是空串**
            let action: String? = j.map(\.action)
            let score: Int? = j.map(\.score)
            let isHold = item.isHolding
            let cost = item.costPrice
            let shares = item.shares
            let price = quote?.currentPrice
            Card("自选判定") {
            HStack(spacing: 16) {
                // 今日判定
                // ⚠ `Text + Text` 的 `+` 在 macOS 26 已废弃（"Use string interpolation on Text instead"），
                //   但这里**不能**换成字符串插值 —— 两段是**不同样式**（caption 灰 + callout 粗彩），
                //   插值会丢掉各自的字体与颜色 ⇒ 用 `HStack`，`.firstTextBaseline` 与原 `+` 的对齐一致。
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("今日判定 ").font(.caption).foregroundStyle(.secondary)
                    Text(action ?? "待判定").font(.callout.bold())
                        .foregroundStyle(Sem.actionColor(action))
                }
                if let s = score, s > 0 {
                    ScoreBadge(score: s, tier1: Store.shared.tier1Min, tier2: Store.shared.tier2Min)
                }
                Divider().frame(height: 14)
                // 引擎信号的目标/止损（有买入信号才有）
                if let t = j?.targetPriceOrNil, t > 0,
                   let st = j?.stopLossPriceOrNil, st > 0 {
                    Text("目标 \(StockFmt.price(t, code: code))").font(.callout)
                        .foregroundStyle(Sem.up)
                    Text("止损 \(StockFmt.price(st, code: code))").font(.callout)
                        .foregroundStyle(Sem.down)
                }
                Spacer()
                // 手动持仓盈亏（有持仓标记才有）
                if isHold, cost > 0, shares > 0 {
                    let p = price ?? cost
                    let pnlPct = (p - cost) / cost * 100
                    // ⚠ 成本价 3 位小数（摊薄成本/ETF 净值就是 3 位），金额另给一行
                    Text("持仓 \(String(format: "%.0f", shares))股 × \(StockFmt.costPrice(cost))")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(String(format: "%+.2f%%", pnlPct))
                        .font(.callout.bold().monospacedDigit())
                        .foregroundStyle(Sem.pnl(pnlPct))
                }
                }
            }
        }
    }

    // MARK: 弹窗头部

    /// 详情页右上角的「加自选 / 去掉自选」
    @ViewBuilder
    private var watchToggleButton: some View {
        let isInWatch = Store.shared.watchItems.contains { $0.code == code }
        Button {
            if isInWatch {
                // ⚠ 先弹确认 —— 与自选页"移出自选"同一套语言，避免误点即删（此操作不可撤销）。
                showRemoveConfirm = true
            } else {
                Store.shared.addWatch(code: code, name: stockName)
            }
        } label: {
            Label(isInWatch ? "去掉自选" : "加自选",
                  systemImage: isInWatch ? "star.slash" : "star")
        }
        // 角色随状态变：未自选 = 主操作（加）；已自选 = 破坏性（从自选里移出，与列表行的红叉同语义）
        .btn(isInWatch ? .danger : .primary)
        .help(isInWatch ? "从自选中移除 \(stockName)" : "把 \(stockName) 加入自选")
    }

    /// 固定头部：名称/代码/实时状态 + 现价大字 + 涨跌 + 关键价（今开/昨收/最高/最低）。
    private var priceHeader: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text(stockName).font(.headline)
                Text(code).font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                // 实时状态：分时 1s 轮询 / 其余 5s（与实际轮询间隔同步，不误导）
                if quote != nil {
                    HStack(spacing: 4) {
                        Circle().fill(Sem.down).frame(width: 6, height: 6)
                        Text(period == .minute ? "实时 · 每秒刷新" : "实时")
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                    .help(period == .minute ? "行情与分时每 1 秒自动刷新" : "行情每 5 秒自动刷新")
                } else if quoteFailed {
                    Text("行情获取失败").font(.caption2).foregroundStyle(Sem.warn)
                }
                // 指数成份徽章：只展示身份，不进筛选。
                // ⚠ 数据来自 `detailStore` 缓存，不在渲染路径现查库（本页行情每 1~5 秒轮询）。
                // offset 作 id：indexBadges 打开详情页时一次赋值、期间不增删，offset 稳定；
                // 且可防名称重复（同名指数也会是不同 offset，不撞 id）
                ForEach(Array(indexBadges.enumerated()), id: \.offset) { _, name in
                    Text(name)
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Tok.tint(Sem.info), in: Capsule())
                        .foregroundStyle(Sem.info)
                        .help("该票属于「\(name)」成份（数据来自新浪，可在设置页刷新）")
                }
                Spacer()
                // 自选开关：**每个详情页右上角都有**，已加就变成"去掉自选"。
                // ⚠ 状态直接读 `Store.shared.watchItems`，不另存本地态 ——
                //   否则在别处加了自选、这里不会变。
                // ⚠ 文案「加自选 / 去掉自选」；图标 `star` / `star.slash` 与自选页一致。
                watchToggleButton
                // ⚠ Esc 的归属 · 上半：popover 开着时**撤掉**本按钮的 Esc 绑定 —— 否则它的
                //   keyEquivalent 先命中，而按钮动作是 `dismiss()`（**程序化**关闭），body 上那行
                //   `.interactiveDismissDisabled` **挡不住它**。撤的只是 **Esc 绑定**，
                //   按钮动作仍是 `dismiss()` —— 鼠标点「关闭」照旧关详情页。
                //   完整的三条实测与结论见 body 上那段注释。
                Button("关闭") { dismiss() }
                    .keyboardShortcutIf(!showForecastSheet, .cancelAction)
                    .btnSecondary()
            }

            HStack(alignment: .center, spacing: 10) {
                if let q = quote {
                    Text(StockFmt.price(q.currentPrice, code: code))
                        .font(AppFont.display(30, weight: .bold))
                        .monospacedDigit()
                        // 数字滚动需要 animation 驱动（`contentTransition` 只声明过渡形态、不带时长）。
                        // `motionAware` 顺带满足减弱动态：开关打开时 animation 传 nil → 数字瞬时到位。
                        .contentTransition(.numericText(value: q.currentPrice))
                        .motionAware(Mot.value, value: q.currentPrice)
                        .foregroundStyle(q.isRising ? Sem.up : Sem.down)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(StockFmt.signedPrice(q.change, code: code))
                        Text(Self.fmtSigned(q.changePercent) + "%")
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Tok.tint(q.isRising ? Sem.up : Sem.down),
                                        in: RoundedRectangle(cornerRadius: 5))
                    }
                    .font(AppFont.displayNumeric(13))
                    .monospacedDigit()
                    .foregroundStyle(q.isRising ? Sem.up : Sem.down)
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 3) {
                        HStack(spacing: 12) {
                            quotePair("今开", q.openPrice, nil)
                            quotePair("昨收", q.previousClose, nil)
                        }
                        HStack(spacing: 12) {
                            quotePair("最高", q.highPrice, Sem.up)
                            quotePair("最低", q.lowPrice, Sem.down)
                        }
                    }
                    .font(.caption)
                } else {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Tok.skeleton)
                        .frame(width: 150, height: 34)
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func quotePair(_ label: String, _ value: Double, _ color: Color?) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            Text(StockFmt.price(value, code: code))
                .monospacedDigit()
                .foregroundStyle(color ?? .primary)
        }
    }

    // MARK: 指标网格（估值/活跃度）

    private var metricsGrid: some View {
        Card("估值 · 活跃度") {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
            if let q = quote {
                metricCell("成交量", StockFmt.volume(q.volume))
                metricCell("成交额", StockFmt.turnover(q.turnover))
                metricCell("振幅", StockFmt.percent(q.amplitude))
                metricCell("量比", StockFmt.num(q.volumeRatio))
                metricCell("换手率", StockFmt.percent(q.turnoverRate))
                metricCell("市盈率", StockFmt.num(q.peRatio))
                metricCell("市净率", StockFmt.num(q.pbRatio))
                metricCell("总市值", StockFmt.marketCap(q.marketCap))
                metricCell("流通市值", StockFmt.marketCap(q.circulationMarketCap))
            } else {
                ForEach(0..<9, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Tok.skeleton)
                        .frame(height: 40)
                }
            }
        }
        }
    }

    /// ⚠ 实现已收敛到 `MetricCell`（`Components.swift`）。这里保留**同名薄包装**是为了不动调用点；
    ///   参数保留各处形态差异（`boxed`/`spacing`），**视觉逐像素不变**。
    func metricCell(_ label: String, _ value: String) -> some View {
        MetricCell(label: label, value: value, boxed: true, spacing: 3)
    }

    // MARK: 异动提示卡（涨跌停 / 一字板 / 放量大跌；只展示、不参与评分）

    /// 量能倍数（今日量 ÷ 前 5 日均量）。
    ///
    /// ⚠ 详情页的日K来自 `KLineService`（**腾讯**），而腾讯日K**含当日 bar**
    /// （实测末根日期就是今天、量与本页实时快照逐位一致）；
    /// 引擎侧用的新浪日K**不含**当日 bar。`PriceLimits.volumeMultiple` 按**日期**自证，
    /// 所以这里不必（也不该）声明来源 —— 判错方向会让倍数整体错位一个交易日且不报错。
    private var volMult5d: Double? {
        guard let q = quote else { return nil }
        // ⚠ 用 `dailyKline`（不是 `kline`）：图表切到分时/周K/月K 时 `kline` 不是日K，
        //   拿它算"前 5 日均量"口径就错了（周K 时等于拿 5 周比），而且空数组会让判据静默失效。
        return PriceLimits.volumeMultiple(
            klineDays: dailyKline.map(\.date), klineVolumes: dailyKline.map(\.volume),
            today: ChinaTime.day(), todayVolume: q.volume)
    }

    /// 命中才显示；没命中整张卡不出现（不占位、不写"无异常"这种空话）
    private var anomalyVerdict: PriceLimits.Verdict? {
        guard let q = quote else { return nil }
        let v = PriceLimits.verdict(q, volMult5d: volMult5d)
        return v.isEmpty ? nil : v
    }

    @ViewBuilder
    private var anomalyCard: some View {
        if let v = anomalyVerdict {
            Card("异动提示") {
                VStack(alignment: .leading, spacing: 8) {
                    // 标签行：风险侧用警示色，涨停用涨色
                    HStack(spacing: 6) {
                        ForEach(v.anomalies, id: \.rawValue) { a in
                            Text(a.label)
                                .font(AppFont.detail.weight(.semibold))
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Tok.tint(a.isRisk ? Sem.warn : Sem.up, .chip),
                                            in: Capsule())
                                .foregroundStyle(a.isRisk ? AnyShapeStyle(Sem.warn)
                                                          : AnyShapeStyle(Sem.up))
                        }
                        Spacer()
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)],
                              spacing: 8) {
                        metricCell("涨停价", StockFmt.num(v.limitUp))
                        metricCell("跌停价", StockFmt.num(v.limitDown))
                        metricCell("量能倍数", StockFmt.num(v.volMult5d))
                        metricCell("涨跌幅", StockFmt.percent(quote?.changePercent))
                    }
                    // 口径写在卡上：判据是**该板块**的涨跌停价（主板 ±10% / 创业板·科创板 ±20% /
                    // 北交所 ±30%），不是固定 10%；放量大跌的阈值是清单原文口径。
                    // ⚠ 这里是 `+` 拼出来的 String → 走 `Text(verbatim:)`，**不解析 Markdown**
                    //   （星号会原样显示），所以不要在这里写 `**粗体**`。
                    Text("涨跌停按该板块的规则判定（腾讯给的价：主板 10% / 创业板·科创板 20% / "
                         + "北交所 30%）。放量大跌 = 跌幅 ≤ \(PriceLimits.heavyVolumeDownPct)% "
                         + "且成交额 ≥ 2 亿且量能倍数 ≥ \(PriceLimits.heavyVolumeMinMult) 倍。")
                        .font(AppFont.detailSmall)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: K 线图卡
}

// MARK: - 条件式快捷键

extension View {
    /// 条件式快捷键：`active` 为假时**完全不注册**该快捷键。
    ///
    /// ⚠ 为什么需要它：`keyboardShortcut` 没有"传 nil 即注销"的形态（参数非可选），
    ///   而这里要的是「popover 开着时把 Esc **让出去**」—— 见 `priceHeader` 的注释。
    ///   ⚠ 代价：`if/else` 两个分支是不同的视图类型，`active` 翻转时这个按钮会**换 identity**
    ///   （重建一次）。对"关闭"这种无状态按钮无影响；**别**用在带 `@FocusState` /
    ///   编辑态的控件上 —— 那会让输入焦点在翻转时丢掉。
    @ViewBuilder
    func keyboardShortcutIf(_ active: Bool, _ shortcut: KeyboardShortcut) -> some View {
        if active { self.keyboardShortcut(shortcut) } else { self }
    }
}


// MARK: - 详情 sheet 高度可调

/// 详情页窗口最小高度：低于此值时图表会被压得过扁（2026-10-21 实机反馈）。
/// 初始仍按 720 打开，用户只能在 600...屏幕可用高度 之间调整。
private let stockDetailMinHeight: CGFloat = 600

/// 只放开高度：宽度固定（分时固定 240 槽的槽宽依赖 640 宽度，横向拉伸会失真）。
/// 这是一个 debug 也能用的 AppKit 小探针，不引入读屏修饰符。
private struct SheetHeightResizer: NSViewRepresentable {
    let minWidth: CGFloat
    let minHeight: CGFloat
    let initialHeight: CGFloat

    func makeNSView(context: Context) -> ResizerView {
        ResizerView(minWidth: minWidth, minHeight: minHeight, initialHeight: initialHeight)
    }

    func updateNSView(_ nsView: ResizerView, context: Context) {}

    final class ResizerView: NSView {
        private let minWidth: CGFloat
        private let minHeight: CGFloat
        private let initialHeight: CGFloat
        private var configured = false
        private var attempts = 0
        private weak var sheet: NSWindow?
        private var observers: [NSObjectProtocol] = []
        private var userResized = false
        private var settleChecks = 0
        private var stopping = false

        init(minWidth: CGFloat, minHeight: CGFloat, initialHeight: CGFloat) {
            self.minWidth = minWidth
            self.minHeight = minHeight
            self.initialHeight = initialHeight
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if newWindow == nil {
                stopping = true
                observers.forEach(NotificationCenter.default.removeObserver)
                observers.removeAll()
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureSheetIfNeeded()
        }

        /// `viewDidMoveToWindow` 可能早于 sheet 挂到父窗口；直接扫 sheet 窗口并重试几次，
        /// 不依赖 `self.window` 的时序。
        private func configureSheetIfNeeded() {
            guard !configured else { return }
            guard let sheet = NSApp.windows.first(where: { $0.sheetParent != nil }) else {
                attempts += 1
                if attempts < 30 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        self?.configureSheetIfNeeded()
                    }
                }
                return
            }
            configured = true
            self.sheet = sheet
            applyConstraints()
            sheet.setContentSize(NSSize(width: minWidth, height: initialHeight))

            // ⚠ SwiftUI 呈现 sheet 时会用自己的尺寸覆盖（实测：打开即落到 600 下限），
            //   并在随后布局里清掉 contentMinSize。呈现后 2 秒内反复自愈：
            //   仍停在下限、且用户还没拖过 ⇒ 钉回 720；用户一拖就停手。
            scheduleInitialSizeCheck()

            // ⚠ 用户拖动后兜底下限：只在低于下限时拉回；正常拉伸**不碰尺寸**。
            //   上一版在 resize 里无条件读内容高度并 setContentSize，读到滞后值 → 一拖就跳。
            let nc = NotificationCenter.default
            for name in [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification] {
                observers.append(nc.addObserver(forName: name, object: sheet, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.handleResize() }
                })
            }
        }

        /// 呈现后的初始高度自愈（10 次 × 0.2s）。只在下限附近纠偏，不覆盖用户的拖动。
        private func scheduleInitialSizeCheck() {
            guard !stopping else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, !self.stopping, !self.userResized else { return }
                self.settleChecks += 1
                guard self.settleChecks <= 10 else { return }
                self.applyConstraints()
                if let sheet = self.sheet,
                   (sheet.contentView?.frame.height ?? 0) <= self.minHeight + 1 {
                    sheet.setContentSize(NSSize(width: self.minWidth, height: self.initialHeight))
                }
                self.scheduleInitialSizeCheck()
            }
        }

        private func handleResize() {
            guard let sheet else { return }
            if sheet.inLiveResize { userResized = true }
            applyConstraints()
            // 呈现阶段不兜底：避免和 SwiftUI 的初始布局互相拉扯
            guard userResized else { return }
            // ⚠ 用窗口 frame 判断，不读内容视图高度：拖动时后者可能滞后，
            //   上一版就是因此把正常拉伸瞬间拽回下限（实测"一拖就跳"）。
            let frameHeight = sheet.frame.height
            guard frameHeight > 0, frameHeight < minHeight - 0.5 else { return }
            sheet.setContentSize(NSSize(width: minWidth, height: minHeight))
        }

        private func applyConstraints() {
            guard let sheet else { return }
            let maxH = (sheet.screen ?? NSScreen.main)?.visibleFrame.height ?? (minHeight + 400)
            let maxSize = NSSize(width: minWidth, height: max(minHeight, maxH - 80))
            let minSize = NSSize(width: minWidth, height: minHeight)
            if !sheet.styleMask.contains(.resizable) { sheet.styleMask.insert(.resizable) }
            if sheet.minSize != minSize { sheet.minSize = minSize }
            if sheet.contentMinSize != minSize { sheet.contentMinSize = minSize }
            if sheet.maxSize != maxSize { sheet.maxSize = maxSize }
            if sheet.contentMaxSize != maxSize { sheet.contentMaxSize = maxSize }
        }
    }
}
