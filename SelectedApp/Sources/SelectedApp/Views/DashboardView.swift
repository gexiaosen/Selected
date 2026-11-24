import SwiftUI
import SelectedCore

// MARK: - P1 看板

struct DashboardView: View {
    let store = Store.shared

    /// 显式把当前外观传进 hero（`ViewThatFits`）与信号分类卡 —— 两张卡都靠 `.primary/.secondary` 铺文字。
    /// ⚠ 实测：深色冷启动下，`ViewThatFits` 选中的子树会按**系统外观**解析
    ///   `.primary / .secondary`（整张 hero 卡黑字压在 #1E1E1E 上，价格不可读），
    ///   而页面其余文字正常。这里把父视图拿到的 colorScheme 强制注入子树兜底；
    ///   根因在 macOS 26 + ViewThatFits + NSApp.appearance 的解析链，别删这条。
    @Environment(\.colorScheme) var colorScheme

    // MARK: 信号分类交互
    //
    // 语义：**悬停**堆叠条的某一列（数字 + 胶囊段）→ 提示"该档多少只"；
    //       **点击**该列 → 右侧清单只看该档；再点一次当前档 → 恢复全部。
    //       默认 = **全部**标的，按**强度序**展示（最强 → 持续 → 脉冲 → 其他）。
    /// 当前筛选的信号档（nil = 全部）。口径与图表同源：`chartKey`（`"other"` = 其他）
    @State var signalFilter: String?
    /// 当前悬停的信号档（nil = 未悬停）
    @State var signalHover: String?
    /// 信号分类清单的**实测内容高**（只用于反推"恰好放下 5 行"的固定窗口高，不参与展示）
    @State var signalListContentH: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            PageActionBar {
                DateChip()
                ActionBarButton(title: "刷新") {
                    refreshDashboard()
                }
                .disabled(store.busy.contains("round"))
            }
            // ⚠ 用共享组件 `FitScrollView`：`ScrollView{VStack}` 内容不足一屏时底部露白，
            //   且滚动容器内的 `.frame(maxHeight:.infinity)` 无法让卡片拉伸。
            //   FitScrollView 的行为：自然高度 ≤ 视口 → **等高铺满**（卡片按 maxHeight
            //   拉满到底部，无留白）；自然高度 > 视口 → 真实滚动，不裁切。
            FitScrollView {
                naturalColumn
                    .padding(16)
            }
        }
        // 每次进入看板：默认落到当天；补自选/持仓数据；拉四指数与 3 日趋势；
        // 盘中情绪/板块/指数交给常驻 `DashboardLiveMonitor`（切页不取消）
        .task {
            store.applyDashboardDefaultDate()
            store.prepareDashboard()
            store.forceRefreshLiveIndex()
            store.loadLive3dTrendIfNeeded()
        }
        // 设置里改了指数的选择/顺序 → 今天补拉实时，历史日作废缓存并按新列表回填
        .onChange(of: DashboardPrefs.shared.displayedSymbols) { _, _ in
            if store.isDashboardToday {
                store.forceRefreshLiveIndex()
            } else {
                store.invalidateHistoricalIndices()
                store.loadHistoricalIndicesIfNeeded()
            }
        }
        // 切日：回到今天拉实时；历史日按该日收盘回填四指数
        .onChange(of: store.viewDate) { _, _ in
            if store.isDashboardToday {
                store.forceRefreshLiveIndex()
                DashboardLiveMonitor.shared.kick()
            } else {
                store.loadHistoricalIndicesIfNeeded()
            }
        }
    }

    // MARK: 内容柱（自然布局，供「铺满」与「滚动」两种模式共用）
    // ⚠ `maxHeight: .infinity` 的「拉伸」只在铺满模式（有界提案）生效；
    //   测量叠放时提案无界 ⇒ 自动回落为内容尺寸，不影响自然高度测量。
    private var naturalColumn: some View {
        VStack(spacing: 14) {
            marketHero
            // 持仓当日盈亏：盘中最高频的"我怎么样"，紧跟大盘 Hero
            holdingsCard
            if isEmptyDashboard {
                // 所有来源都无数据（无扫描、无持仓、无实时情绪/板块）→ 合并成一张可操作引导卡
                dashboardEmptyCard
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                // 昨涨停表现（盘中 60s）+ 领涨板块（盘中 60s）
                // ⚠ **只展示、不进评分/大盘灯**（与基本面/资金流同一姿势）。
                // 2026-11-05 与下面那行换位：这两张开盘就有数据，放中间会让
                // 「还没扫所以空着」的信号分类/今日结论卡在页面正中，看着像坏了。
                HStack(alignment: .top, spacing: 14) {
                    ztSentimentCard
                        .frame(maxHeight: hasSentimentContent ? .infinity : nil, alignment: .top)
                    topBoardsCard
                        .frame(maxHeight: hasSentimentContent ? .infinity : nil, alignment: .top)
                }
                // 信号分类 / 今日结论：即使今天尚未扫描也保留空态卡，
                // 让盘中页面结构稳定（而不是整行突然消失/出现）。
                // ⚠ 无内容时不拉伸：否则 FitScrollView 会把空卡撑成一大块空白。
                HStack(alignment: .top, spacing: 14) {
                    signalsCard
                        .frame(maxHeight: hasSignalContent ? .infinity : nil, alignment: .top)
                    conclusionCard
                        .frame(maxHeight: hasSignalContent ? .infinity : nil, alignment: .top)
                }
                // ⚠ 「各轮次摘要」卡已下线（2026-11-05 用户要求）：那一行行档位/参数/用时
                //   要到收盘三轮跑完才有内容，而看板的使用时点是**开盘** —— 展示得比看到得早。
                //   原先这张卡还兼作「吸收剩余高度、页面底部不露白」的角色，现在这个角色
                //   交给上面那行情绪/板块卡（它有内容时就拉伸，行为与今天一致）。
                //   数据链一律保留：`store.roundSummaries` 仍供大盘 Hero 的回退链
                //   （`latestEnv`）、「已扫描 N/3 轮」与空态判定使用；删的只是这张卡。
            }
        }
    }

    private func refreshDashboard() {
        store.refresh()
        // 手动刷新时强制重拉实时行情（绕过当日缓存）
        store.forceRefreshLiveIndex()
        store.loadLive3dTrendIfNeeded(force: true)
        // 盘中情绪/板块也立刻补一轮，不必等下一个 60s
        DashboardLiveMonitor.shared.kick()
        AlertMonitor.shared.kick()
        // 历史日手动刷新：重试四指数日K回填
        store.loadHistoricalIndicesIfNeeded(force: true)
    }

    /// 信号/结论行是否有内容（决定是否让两卡等高拉伸）。开盘回退内容同样算有内容。
    private var hasSignalContent: Bool {
        !store.todaySignals.isEmpty || !(store.compareReport?.suggestions.isEmpty ?? true)
            || store.dashboardPredictFallback != nil || store.dashboardConclusionFallback != nil
    }

    /// 昨涨停/领涨板块行是否有内容（决定是否让两卡等高拉伸）。
    private var hasSentimentContent: Bool {
        (store.ztSentimentLive?.result.sample ?? 0) > 0
            || (store.ztSentimentToday?.sample ?? 0) > 0
            || !store.liveTopBoards.isEmpty
            || !store.boardHeatRows.isEmpty
    }

    /// 首页所有来源都无数据（今日尚未扫描 / 历史日无记录 / 无持仓 / 无实时情绪与板块）。
    ///
    /// ⚠ 必须把持仓与盘中快照算进来：10:00 尚未扫描但已有持仓/情绪/板块时，
    ///   不能再落"整页空看板"的合并空态。
    private var isEmptyDashboard: Bool {
        let hasHoldings = store.watchItems.contains(where: \.isHolding)
        let hasZt = (store.ztSentimentLive?.result.sample ?? 0) > 0
            || (store.ztSentimentToday?.sample ?? 0) > 0
        let hasBoards = !store.liveTopBoards.isEmpty || !store.boardHeatRows.isEmpty
        return store.roundSummaries.isEmpty
            && store.todaySignals.isEmpty
            && !hasHoldings
            && !hasZt
            && !hasBoards
            && (store.compareReport?.suggestions.isEmpty ?? true)
    }

    private var dashboardEmptyCard: some View {
        let times = RoundPlan.slots
            .map { ScheduleTimes.shared.clock(RoundPlan.roundKey($0)) }
            .joined(separator: " / ")
        let viewingPast = store.viewDate != store.today
        let backTitle = store.dashboardDefaultDate == store.today ? "回到当日" : "回到最近交易日"
        return Card(viewingPast ? "该日无扫描数据" : "今日尚未扫描",
                    subtitle: viewingPast ? "未落库轮次结果" : "交易日尾盘自动运行") {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: viewingPast ? "calendar.badge.exclamationmark" : "clock.badge.checkmark")
                    .font(AppFont.glyph(24))
                    .foregroundStyle(viewingPast ? Sem.warn : Sem.info)
                VStack(alignment: .leading, spacing: 8) {
                    Text(viewingPast
                         ? "该日没有落库的三轮结果；指数已按该日收盘回填，信号分类与结论没有快照。可切换日期或回到当日。"
                         : "尾盘 \(times) 自动跑三轮选股；盘中这里会先显示指数、持仓盈亏、昨涨停表现与领涨板块。")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        if viewingPast {
                            Button(backTitle) { store.backToDashboardToday() }
                                .btnSecondary()
                        } else {
                            Button("刷新数据") { refreshDashboard() }
                                .btnSecondary()
                                .disabled(store.busy.contains("round"))
                        }
                        Button("查看选股结果") { Page.select(.results) }
                            .btnSecondary()
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// 「今天几号 星期几」—— **北京时间**口径。
    ///
    /// ⚠ 原先这里是 `Text(Date.now, format: .dateTime.month().day().weekday(.wide))`
    ///   （2026-10-16 审查 B5-13）：`Date.now` + `.dateTime` 走的是**设备时区与设备日历**，
    ///   而同一个 VStack 的兄弟分支用的是 `store.viewDate`（`ChinaTime` 钉死 Asia/Shanghai），
    ///   全 App 其余日期也一律 `ChinaTime`。于是设备不在东八区时，
    ///   这块作为"今天"锚点的看板卡会显示**前一天/错误星期**（且星期名还跟随设备语言，
    ///   与"中文为唯一界面语言"的既定口径不符）。
    /// 盘中卡片统一用 `HH:mm:ss`（北京时间）—— 与顶栏更新时间同格式。
    private static let clockFmt = ChinaTime.formatter("HH:mm:ss")
    static func clockText(_ date: Date) -> String { clockFmt.string(from: date) }

    static func beijingTodayLabel(_ now: Date = Date()) -> String {
        let parts = ChinaTime.day(now).split(separator: "-")     // yyyy-MM-dd（北京时间）
        guard parts.count == 3, let month = Int(parts[1]), let day = Int(parts[2]) else {
            return ChinaTime.day(now)
        }
        // 与 `.weekday(.wide)` 的原显示保持一致（星期日 … 星期六）
        let names = ["星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六"]
        // `ChinaTime.weekday` 与 `Calendar.weekday` 同口径：1=周日 … 7=周六
        let w = names[max(0, min(6, ChinaTime.weekday(now) - 1))]
        return "\(month)月\(day)日 \(w)"
    }
}

// MARK: - SwiftUI Preview
// ⚠ 预览读**真实开发库**（`Store.shared`），仅置 `previewMode` 抑制网络拉取；
//   空库时正好看各卡片空态。预览进程独立，不写生产数据。
#Preview("看板（真实库 · 禁网络）") {
    Store.shared.previewMode = true
    return DashboardView()
        .frame(width: 900, height: 620)
}
