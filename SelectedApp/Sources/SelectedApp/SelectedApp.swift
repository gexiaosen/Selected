import SwiftUI
import AppKit
import SelectedCore

// MARK: - 应用入口（双入口：Dock 标准主窗口 + 菜单栏快捷菜单）

@main
struct SelectedApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        // 标准主窗口（Dock 图标 / Cmd+Tab / 关闭后点 Dock 重开）
        // ⚠ **标准标题栏**：红绿灯由系统摆放、标题栏下可容纳原生工具栏。
        WindowGroup(id: "main") {
            AppShellView()
                // 内容下界 904：侧栏 144 + 详情 760（各页排版下限）；窗口实际 minWidth 1120。
                //   ⚠ **首次打开 = 最小尺寸**（2026-10-19 老板要求）：`defaultSize` 与这里一致，
                //   真要更大用户自己拖（不设上限）。
                //   ⚠ **详情区 ≥ 760 是内容下界**（压窄会重现「右侧裁切 + 空白带」）。
                //   ⚠ 尺寸同样被 AppKit 记忆（`NSWindow Frame main-AppWindow-1`）⇒ 改默认值
                //     必须一次性清掉旧记忆，见 `resetMainWindowFrameOnce()`。
                .frame(minWidth: 1120, minHeight: 692)
        }
        // ⚠ 默认 = **最小尺寸**（1120 × 692），保持「首次打开默认为最小高度及宽度」。
        //   改这里**必须**同步 `AppShellView.body` 的 `.frame(minWidth:)` 与 `resetMainWindowFrameOnce()` 的标记。
        .defaultSize(width: 1120, height: 692)
        // ⚠ 用 `CommandGroup(replacing:)` **正式接管**菜单项（编译期生效，与系统语言无关；
        //   靠菜单标题字符串匹配的补丁在非英文系统下会静默失效）。
        //   `replacing: .newItem` 会**整组移除** File → New / New Window（含 `Cmd+N`），
        //   这正是本项目要的「单窗口」策略（`AppDelegate` 的 Dock 重开也复用已有窗口）。
        //   `replacing: .sidebar` 移除「显示/隐藏侧边栏」菜单项与 `⌃⌘S` —— 侧栏开关已整族删除，
        //   留着菜单项等于留第二条收起侧栏的路（工具栏按钮摘了它照样能收）。
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(replacing: .sidebar) { }
            // 自动更新的手动入口：放在 App 菜单「关于」之后（macOS 惯例位置）。
            // 静默每日检查由 `UpdateCenter` 在启动时拉起；这里只负责"我想现在查"。
            CommandGroup(after: .appInfo) {
                Button("检查更新…") { UpdateCenter.shared.checkForUpdates() }
            }
            // ⚠ 页面级快捷键此前**一个都没有**（全 App 只有 14 处 `keyboardShortcut`，
            //   且全是 `.defaultAction`/`.cancelAction`）：14:50 那种分时压力下，
            //   键盘用户没法从看板一步跳到刚跑完的第三轮，只能鼠标点侧栏（审查 B6）。
            CommandGroup(after: .toolbar) {
                // 快捷键必须是**字面量**（`KeyEquivalent` 不能由 `String(i)` 拼出来），
                // 所以这里逐条列出；页名一律取 `Page.title`，不重复写一份文案。
                Button(Page.dashboard.title) { Page.select(.dashboard) }
                    .keyboardShortcut("1", modifiers: .command)
                Button(Page.watch.title) { Page.select(.watch) }
                    .keyboardShortcut("2", modifiers: .command)
                Button(Page.indicators.title) { Page.select(.indicators) }
                    .keyboardShortcut("3", modifiers: .command)
                Button(Page.results.title) { Page.select(.results) }
                    .keyboardShortcut("4", modifiers: .command)
                Button(Page.predict.title) { Page.select(.predict) }
                    .keyboardShortcut("5", modifiers: .command)
                Button(Page.review.title) { Page.select(.review) }
                    .keyboardShortcut("6", modifiers: .command)
                Button(Page.history.title) { Page.select(.history) }
                    .keyboardShortcut("7", modifiers: .command)
                Button(Page.board.title) { Page.select(.board) }
                    .keyboardShortcut("8", modifiers: .command)
                Button(Page.params.title) { Page.select(.params) }
                    .keyboardShortcut("9", modifiers: .command)
                //  `Page.params` 已从早先独立第十页 `⌘0` 收进 `⌘9`：现在 `⌘0` 留空，**不补新页、也不留占位** ——
                //   「九页 + ⌘1…⌘9」是自解释的，硬凑一个 ⌘0 反而让人以为还有第十页。
                Divider()
                Button("刷新今日数据") { Store.shared.refreshToday() }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }

        // ⚠ 设置用**原生 `Settings` scene**（不是侧边栏一页）—— 否则 macOS 用户最通用的
        //   「打开设置」路径完全缺失（`Cmd+,` 无反应）。系统免费提供：
        //   ① App 菜单「设置…」（`Cmd+,`）；② 「窗口」菜单的「设置」项；
        //   ③ 独立窗口（可与主窗口同开对比参数）；④ 尺寸/位置记忆。
        //   ⚠ 设置内容零改动（`SettingsView` 及其 extension 原样复用，变的只有"谁来承载"）。
        //   ⚠ 侧栏**不得**再有设置入口（两套入口问题）。
        Settings {
            SettingsView()
                // 设置内部是「左分类 + 右内容」，一屏只看一类 ⇒ 尺寸可以紧凑。
                //   · 只锁 min、可放大：固定 frame 会让内容被钉死、窗口拉大后留白；
                //     数据源诊断/回放这类高密度页偶尔需要更宽更高。
                //   · 这里的 min 只管"可拖小的下限"，**初始尺寸由 scene 的 `.defaultSize` 决定**（同为 760 × 500）。
                //   · 空工具栏带占顶部高度开销，各栏内容留白由 `SettingsView` 内的负 padding 收回。
                // ⚠ 窗口尺寸由 AppKit 记忆在 `NSWindow Frame com_apple_SwiftUI_Settings_window`
                //   ⇒ 改默认值必须一次性清旧记忆，见 `AppDelegate.resetSettingsWindowFrameOnce()`。
                .frame(minWidth: SheetMetrics.settingsWindow.width,
                       minHeight: SheetMetrics.settingsWindow.height)
                // ⚠ **标题栏不画字**：窗口身份由内容区左上角的页名承载（`PageActionBar(title: "设置")`）
                //   —— 与 macOS 自家「系统设置」同款形态。窗口内部 title 不变（窗口菜单照旧认得出）。
                .hideWindowTitle()
                // ⚠ 设置窗口**也要挂 toast 浮层** —— 刷新/回放/调优都在这里触发，
                //   它是独立窗口，只挂主窗口 ⇒ 设置页里点刷新（失败）看不到提示（见 ToastOverlay 注释）。
                .toastOverlay()
                // 与主窗口同一个品牌 accent（设置窗口是独立 scene，需单独挂）
                .tint(Sem.brand)
        }
        // ⚠ **`.defaultSize` 挂在 scene 上、不挂在内容视图上**（与主窗口同款写法）：
        //   `Settings` scene 没有 defaultSize 时，窗口初始尺寸 = **内容理想尺寸**，
        //   而 `.frame(minWidth:)` 只约束"可拖小的下限"、从不决定"第一次开多大"。
        //   放不下时 FitScrollView 自动滚动。
        .defaultSize(width: SheetMetrics.settingsWindow.width,
                     height: SheetMetrics.settingsWindow.height)
        // ⚠ 工具栏样式由探针直接设 `window.toolbarStyle = .unified`（见 `WindowTitleHider.installEmptyToolbar`），
        //   不走 scene 配置。

        // 菜单栏快捷菜单（轻量 menu：打开主窗口 / 调度控制 / 退出）
        // ⚠ 显示名只留 `Selected`，与 Info.plist 的 CFBundleDisplayName 同一口径
        //   （这里的标题是菜单栏项的无障碍名，不显示在界面上，但改名时两处必须一起改）。
        MenuBarExtra("Selected", systemImage: "chart.line.uptrend.xyaxis") {
            MenuBarMenu()
        }
        .menuBarExtraStyle(.menu)
    }
}

// MARK: - 菜单栏菜单

struct MenuBarMenu: View {
    @Environment(\.openWindow) private var openWindow
    private let scheduler = Scheduler.shared
    private let store = Store.shared

    var body: some View {
        Button("打开主窗口") {
            focusOrCreateMainWindow()
        }

        Divider()

        if let running = scheduler.runningTaskId,
           let task = Scheduler.shared.tasks.first(where: { $0.id == running }) {
            Text("执行中：\(task.label)…")
        } else if store.busy.contains("round") || store.busy.contains("compare") {
            Text("执行中：手动扫描…")
        } else if let next = scheduler.nextPending {
            Text("下一任务 \(String(format: "%02d", next.hour)):\(String(format: "%02d", next.minute))")
        } else {
            Text("今日任务已完成")
        }

        Toggle("自动调度", isOn: Binding(
            get: { scheduler.schedulerEnabled },
            set: { scheduler.schedulerEnabled = $0 }))

        Divider()

        Button("立即全轮选股") {
            Task { @MainActor in
                store.runMissingRounds()
            }
        }

        Text(roundStatusText)

        Divider()

        Button("退出") {
            NSApp.terminate(nil)
        }
    }

    /// 轮次状态行：让「立即全轮选股」的效果可读（已扫几轮 / 还缺第几轮）
    private var roundStatusText: String {
        // 菜单栏说的是「今日」轮次：必须用今日口径（roundSummaries 随 viewDate，
        // 查看昨日时会把昨日已扫误显示成今日已扫）
        let done = store.todayDoneSlots
        let missing = RoundPlan.missing(done)
        let n = RoundPlan.cn(RoundPlan.count)
        if done.isEmpty { return "今日尚未扫描" }
        if missing.isEmpty { return "今日\(n)轮已齐全" }
        return "已扫 \(done.count)/\(RoundPlan.count) 轮，缺第 \(missing.map(String.init).joined(separator: "、")) 轮"
    }

    /// 单窗口策略：有主窗口则激活置前，无才开新（判据集中在 `focusExistingMainWindow()`）
    private func focusOrCreateMainWindow() {
        if focusExistingMainWindow() { return }
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - 主窗口：侧边栏导航

/// 详情列**这一帧实际渲染的是哪一页** —— 只给快照装置做断言用。
///
/// ⚠ 为什么需要它（2026-10-22 实测）：`Page.select()` 写的是 `UserDefaults`，
///   而扫掠拿到的截图**有时是别的页**，文件名却写着目标页 —— **文件名会撒谎**。
///   唯一可信的证据是"视图自己画了谁"，所以渲染处记一笔、出图前拿它对一次。
///   （同一条教训的另一种形态：让被验的进程自报数值，别只反向读它的外部状态。）
enum PageProbe {
    static var rendered: Page?
}

/// 主窗口侧边栏的页面枚举。`CaseIterable` 顺序 = 侧栏顺序。
///
/// ⚠ **`settings` 不在本枚举**：设置是独立的 `Settings` scene（见 `SelectedApp.body`），
///   由系统提供「设置…」（`Cmd+,`）菜单项与「窗口 → 设置」。
///   **不要**为了「侧栏也能进设置」而把它加回来 —— 那样就是两套入口。
/// ⚠ 「参数中心」是选股参数的唯一入口（从设置窗口搬出，单一入口纪律）。
enum Page: String, CaseIterable, Identifiable, Hashable {
    /// 声明顺序 = 侧栏顺序 = ⌘1…⌘9 的顺序（三处一起走，别只改一处）。
    /// ⚠ 2026-10-23 老板把「自选」提到第二位（看板之后）；`rawValue` 是**字符串**不是序号，
    ///   所以换序不动任何持久化数据。
    /// ⚠ 2026-10-29 去掉 `.compare`（三轮对比并入「选股结果」尾段，见 `CompareSection`）：
    ///   老用户持久域里可能还存着 `"compare"` ⇒ 回落逻辑见 `AppShellView` 的 `category` 同款口径
    ///   （`Page(rawValue:) ?? .dashboard`），窗口不会空白。
    case dashboard, watch, indicators, results, predict, review, history, board, params

    var id: String { rawValue }

    /// 当前页在 `UserDefaults` 里的键（`@AppStorage` 与快捷键命令**共用这一个常量**，
    /// 不再各处写字面量字符串）。
    static let storageKey = "sidebar.page"

    /// 切换当前页（供「前往页面 ⌘1…⌘9」菜单命令用）。
    ///
    /// `@AppStorage` 观察同一个键 ⇒ 写这里，`AppShellView` 会即时跟着换页。
    static func select(_ p: Page) {
        UserDefaults.standard.set(p.rawValue, forKey: storageKey)
    }

    var title: String {
        switch self {
        case .dashboard: return "看板"
        case .indicators: return "指标筛选"
        case .results: return "选股结果"
        case .predict: return "早盘预判"
        case .review: return "复盘验证"
        case .history: return "历史迭代"
        case .board: return "板块热度"
        case .params: return "参数中心"
        case .watch: return "自选"
        }
    }

    var icon: String {
        switch self {
        case .dashboard: return "square.grid.2x2"
        case .indicators: return "chart.xyaxis.line"
        case .results: return "doc.text.magnifyingglass"
        case .predict: return "sunrise"
        case .review: return "chart.bar.doc.horizontal"
        case .history: return "clock.arrow.circlepath"
        case .board: return "square.3.layers.3d"
        case .params: return "slider.horizontal.3"
        case .watch: return "star.circle"
        }
    }
}

/// 标准窗口内的侧边栏 + 详情区（`FixedTwoColumnShell` 固定两列骨架）
/// ⚠ 侧栏用自绘 `SidebarTab`（MiscKit 玻璃 pill），不再用原生 `List(selection:)`：
///   系统选中胶囊在 macOS 26 上不吃 `.tint`，也做不出不上色的玻璃观感。
///   侧栏**固定宽 144、禁止拖拽**（没有原生拖拽手柄）。
struct AppShellView: View {
    /// 当前页的持久化载体（`@AppStorage` → UserDefaults）—— 启动恢复上次停留页。
    /// ⚠ **不要用 `@SceneStorage`**：它依赖 Scene 状态恢复，而 macOS 默认「退出应用时关闭窗口」
    ///   ⇒ `Cmd+Q` 后再开根本不走窗口恢复路径，值永远回到默认。`@AppStorage` 不依赖它。
    /// ⚠ 存 `rawValue` 字符串而不是 `Page?`：值域简单、坏值（枚举改名 / 存储被手改）能回落
    ///   —— 见 `currentPage` 的 `?? .dashboard`。
    @AppStorage(Page.storageKey) var pageRaw = Page.dashboard.rawValue

    /// 当前页（默认看板）
    var currentPage: Page { Page(rawValue: pageRaw) ?? .dashboard }
    // 侧栏**没有开合**（2026-10-15 老板拍板删除）：工具栏开关按钮已摘
    // （`sidebar.toolbar(removing: .sidebarToggle)`）、菜单命令与 ⌃⌘S 快捷键已删
    // （`CommandGroup(replacing: .sidebar)`），"开合撑宽窗口 / 开合动画卡顿"两族问题
    // 结构性不存在。曾经的 `SidebarWidthLock` 宽度锁与 `.transaction` 硬切随之全部拆除，
    // 由护栏 `sidebar_notoggle` 钉住删除态（不得重新引入）。详见 docs/specs/README.md。
    /// 外观档位（自动 / 白天 / 黑夜），在侧栏左下角。
    /// ⚠ `AppearanceStore` 不是 `@Observable`，所以用本地 `@State` 驱动重绘；
    ///   落盘与生效仍然只有 `AppearanceStore.set` 一条路。
    @State var appearance: AppearanceStore.Mode = AppearanceStore.shared.mode
    /// 新手引导：首次启动 / 设置页重看
    @State private var showOnboarding = false
    /// 侧栏底部「调度任务」popover 开关
    @State var showScheduleList = false
    @Environment(\.openWindow) private var openWindow
    /// 窗口的撤销管理器：注入给 `Store`（「移出自选 / 清仓」的 Cmd+Z 入口）
    @Environment(\.undoManager) private var undoManager
    let scheduler = Scheduler.shared

    var body: some View {
        // 固定两列骨架（替代 NavigationSplitView，理由见 `FixedTwoColumnShell` 注释：
        // 原生分栏的分隔条光标/拖拽/收起整族问题三轮 AppKit 补丁全失败，结构性拆除）。
        FixedTwoColumnShell(sidebarWidth: 144) {
            sidebar
        } detail: {
            detailView(currentPage)
                // ⚠ 详情区下限用**内容真实最小宽 760**（看板两张卡并排、行文本不可再压，
                //   压窄会出现「右侧裁切 + 空白带」）。
                // ⚠ maxHeight: .infinity 保证 detail 列内容**垂直撑满**窗口（ScrollView 页面拿到全高视口）。
                // ⚠ 详情列不设 minHeight（沿革：macOS 26 分栏时代它会让系统少算列高出底部白条；
                //   骨架下无此坑，但窗口最小高已由根 frame 保证，不需要它）。
                .frame(minWidth: 760, maxHeight: .infinity)
                // ⚠ 线 = 系统统一工具栏的分隔线，由挂在下方的 `.toolbarBackground(.hidden)` 抹掉。
                //   留白 = 详情列顶部那段**空工具栏带**（红绿灯所在的标题栏区，详情列这侧没内容，
                //   带高 34pt —— 开关按钮摘掉后由探针装回空工具栏，带高与设置窗口同款）
                //   ⇒ 负 padding 回收，把每页的 `PageActionBar`（日期 + 刷新那一排）提到顶。
                //   ⚠ 不会压住红绿灯：它在侧栏那 144pt 内，详情内容起点 x≥160pt
                //     ⇒ 上提只填带**右侧**的空档。
                //   ⚠ 回收量（0.5.38 骨架重校准，窗口本体截图像素实测）：
                //   带高 30（unifiedCompact）下 -50 把顶行拽进带区（按钮顶 y=5）⇒ 收到
                //   **-37**，按钮顶 ≈ 18 —— 与红绿灯顶缘齐平（老板 0.5.34 终拍"上面留 18pt"，
                //   目标不随骨架变，变的是回收量）。旧分栏的 -42→-50 链全部作废。
                //   ⚠ 上提有底：再深会把页栏底边线顶进窗口顶圆角区（会被切成右侧一小截
                //   竖灰线）。红绿灯在侧栏 144pt 内、详情 x≥160，同排不冲突。
                .padding(.top, -37)
                // ⚠ 切页**不做淡入**：交叉淡入要求过渡期间**同时渲染旧页与新页**（图表页 body 很重，
                //   单帧 ~85~100ms）⇒ 双页并渲占满主线程，点击的选中反馈被排在重渲染之后，
                //   用户以为没点上、再点一次。直切只付新页一次渲染、选中态即时跟随。
                //   （与"侧栏开合动效被整族删除"同一实测结论：动效本身就是这类卡顿来源。）
        }
        .frame(minWidth: 1120, minHeight: 692)
        // 全局 accent 统一到品牌色：分段控件 / Toggle 等系统控件跟随品牌。
        // 若跟随系统 accent，会和 `Sem.brand` 的主按钮、`Sem.selection` 的日期格
        // 并出两三种蓝。业务语义色（涨跌/灯级/信号）仍是显式赋色。
        // ⚠ List 选中胶囊不受 `.tint` 影响（macOS 26 平台行为），仍由系统绘制。
        .tint(Sem.brand)
        // ⚠ 详情区左上角那行字是**窗口标题**（取自 App 名）。
        //   用原生 `.toolbar(removing: .title)` 摘掉标题项 —— 只摘这一项，红绿灯位置不动；
        //   窗口自身的 `title` 仍保留（窗口菜单认得出）。
        //   ⚠ 别改用 `.windowStyle(.hiddenTitleBar)`：那是退回来的老路（红绿灯自绘偏移的根源）。
        .toolbar(removing: .title)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .task { Store.shared.refreshToday() }
        // 注入窗口的 UndoManager（只做一次；`Store.undoManager` 是 weak 引用，不做保留）
        .task { Store.shared.undoManager = undoManager }
        // 注册主窗口重开句柄：Dock 点击无窗口时（AppDelegate.applicationShouldHandleReopen）调用
        .task {
            // ⚠ 句柄**无条件覆盖**（不要加 `== nil` 守卫）：关窗后句柄仍指向**旧视图**的
            //   `openWindow`，有守卫时新视图就不会覆盖 ⇒ 句柄一直指向已销毁视图（重开偶发无反应、不报错）。
            //   ⚠ 也别改成「`.onDisappear` 置 nil」：那会让 Dock 重开时句柄为 nil、什么都不做
            //     （关窗后点 Dock 不再出窗口，比原问题更严重的回归）。
            AppDelegate.reopenMainWindow = {
                // 已有主窗口则激活，否则开新的（与菜单栏「打开主窗口」**同一个实现**：`focusExistingMainWindow()`）
                if focusExistingMainWindow() { return }
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        // 全局正向反馈 toast（顶部居中，最多 3 条；**自动消失、无关闭按钮**）——
        // ⚠ **同时挂到设置窗口**（它是独立窗口，只挂主窗口 ⇒ 设置页点刷新失败看不到任何提示，见 `ToastOverlay` 注释）。
        .toastOverlay()
        // 主窗口「关闭 = 最小化」：红叉 / Cmd+W 收进 Dock，不销毁窗口；
        // 点 Dock 图标由 `applicationShouldHandleReopen` → `focusExistingMainWindow()` 里
        // `deminiaturize` 展开。⚠ **只挂主窗口** —— 设置窗口的红叉仍是"关掉"。
        .mainWindowCloseGuard()
        // 主窗口空工具栏带（红绿灯 (18,18)）：侧栏开关摘掉后工具栏塌，AppKit 层装回
        .mainWindowToolbarBand()
        // 全局个股详情弹窗：任何页面个股行点击触发（Store.showStockDetail）
        .sheet(item: Binding(
            get: { Store.shared.stockDetail },
            set: { if $0 == nil { Store.shared.closeStockDetail() } }
        )) { target in
            // ⚠⚠ 必须按 code 隔离身份：`.sheet(item:)` 在 item **变化**时（sheet 已开着、又点了另一只）
            //   **不保证重建内容视图** ⇒ `StockDetailSheet` 的 `@State kline / minute / quote / …`
            //   会**沿用上一只股票的值** —— 中间那段时间显示的是另一只股票的 K 线（错误数据）。
            //   ⚠ 判据：**凡是 `.sheet(item:)` / `.fullScreenCover(item:)` 里承载了带 `@State`
            //     的视图，且 item 的 id 会变，就必须显式 `.id(item.id)`** ——
            //     SwiftUI 的"复用还是重建"取决于它是否认为"同一呈现位置"，不能靠默认行为。
            StockDetailSheet(code: target.code, stockName: target.name)
                .id(target.code)
                // ⚠ sheet 内容根必须自己挂 toast 层（2026-10-16 审查 B6）：
                //   `toastOverlay()` 原先只挂在主窗口与设置窗口两处 scene 根上，
                //   而 sheet 是**盖在窗口之上的独立层级** —— 详情页里点「重算指标快照」
                //   等带 toast 的写操作失败时，提示在主窗口顶部生成、被 sheet 挡住，
                //   表现就是"按了没反应"。
                .toastOverlay()
        }
        // 首次启动新手引导：仅无 onboardingCompleted 标记时弹出；
        // 设置页「重看新手引导」通过 reopenOnboarding 句柄复用同一 sheet
        .sheet(isPresented: $showOnboarding) { OnboardingSheet() }
        .task {
            if !UserDefaults.standard.bool(forKey: OnboardingFlag.defaultsKey) {
                showOnboarding = true
            }
            // ⚠ 同 `reopenMainWindow` —— **无条件覆盖**、不加 `== nil` 守卫：
            //   否则句柄一直捕获旧视图的 `@State showOnboarding`，「重看新手引导」写进已释放的存储 → 偶发无反应。
            AppDelegate.reopenOnboarding = { showOnboarding = true }
        }
    }

    // MARK: 详情区

    private func detailView(_ page: Page) -> some View {
        // 快照装置断言用：先记"这一帧画的是谁"，再交给分派函数。
        PageProbe.rendered = page
        return detailSwitch(page)
    }

    /// 详情列分派。⚠ 从 `detailView` 拆出来**只是为了那行赋值**：
    ///   `@ViewBuilder` 函数里不能夹普通语句，别把它当成一次"顺手重构"合回去。
    @ViewBuilder
    private func detailSwitch(_ page: Page) -> some View {
        // 切页直切（无淡入，理由见 body 的 detail 列注释）。
        // ⚠ `settings` 不在本 switch（独立 `Settings` scene），侧栏与详情区都不再有设置页。
        // （各 case 本就是不同视图类型，切页天然重建，不需要 `.id`/`.transition`。）
        switch page {
        case .dashboard: DashboardView()
        case .results: ResultsView()
        case .predict: PredictView()
        case .review: ReviewView()
        case .history: HistoryView()
        case .board: BoardView()
        case .indicators: IndicatorScreenerView()
        case .params: ParamsCenterView()
        case .watch: WatchlistView()
        }
    }
}
