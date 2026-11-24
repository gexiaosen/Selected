import SwiftUI
import AppKit

// MARK: - 单窗口策略与窗口 Chrome（菜单栏「打开主窗口」、Dock 重开、红绿灯边距、关闭=最小化）

/// 主窗口的身份标记（`NSWindow.identifier`）。
///
/// ⚠ **为什么需要**：主窗口的"关闭"是最小化，它**永远不会销毁**，而是以
///   `isMiniaturized == true` 的状态留在 `NSApp.windows` 里；此时"哪一个是主窗口"
///   只能靠标记区分 —— 启发式判据（有 contentView / 非面板 / 非 sheet）**设置窗口全都满足**。
let mainWindowID = "main"

/// 主窗口的关闭守卫：红叉与 `Cmd+W` 一律**最小化**，窗口本身不销毁。
///
/// ## 为什么要有
/// 本 App 是**菜单栏常驻**的（调度 / 提醒 / 扫描都在后台跑），主窗口只是"看盘的那块玻璃"：
/// 关掉它不该把窗口销毁（再打开要走重建、还会丢当前页），而应该收进 Dock；点 Dock 图标即展开。
///
/// ## 为什么包一层 `NSWindowDelegate`，而不是只改红叉那个按钮
/// 关闭有**两条路**：红叉（`standardWindowButton(.closeButton)`）与 `Cmd+W`（`performClose:`）。
/// 只替换按钮的 target/action 只能盖住红叉，`Cmd+W` 照样**真关**。
/// `windowShouldClose(_:)` 是 AppKit 让**两条路都先问一遍**的那个口子
/// ⇒ 在那里 `return false` + `miniaturize(nil)` 是唯一覆盖完整的写法。
///
/// ## ⚠ 风险与对策：delegate 是 SwiftUI 自己在用的
/// 直接换掉 `window.delegate` 会**静默丢掉** SwiftUI 的窗口行为（工具栏校验 / 状态恢复 /
/// `windowWillClose` 等）——不报错、编译也过，只在某个场景下"少了个回调"。
/// ⇒ 本类做**透明代理**：`responds(to:)` 与 `forwardingTarget(for:)` 把**没自己实现的方法
///   全部转发**给原 delegate，只接管 `windowShouldClose` 这一条。
/// ⇒ 且只在**主窗口**装（`AppShellView` 上的 `.mainWindowCloseGuard()`）：设置窗口的红叉仍是标准的"关掉"。
///
/// ⚠ 退出路径不受影响：`Cmd+Q` / 菜单栏「退出」走 `NSApp.terminate`，
///   它只问 `applicationShouldTerminate`（未实现 ⇒ 直接退），**不经过** `windowShouldClose`。
@MainActor
final class MainWindowCloseGuard: NSObject, NSWindowDelegate {

    /// 被顶掉的原 delegate（"转发链"）。
    /// ⚠ `weak`：`NSWindow.delegate` 本身是 weak，链上不应该反向持有窗口侧的对象。
    /// ⚠ `nonisolated(unsafe)`：下面两个"透明代理"覆写**必须**是 `nonisolated`
    ///   （SDK 里 `responds(to:)` / `forwardingTarget(for:)` 没有 actor 标注 ⇒ 覆写带 `@MainActor`
    ///   会编译报 actor isolation 不一致），而它们要读这个属性。
    ///   安全性：只在 `init`（主线程）赋值、之后不再变，且 AppKit 对 delegate 的调用都在主线程。
    nonisolated(unsafe) private weak var originalDelegate: NSWindowDelegate?

    init(original: NSWindowDelegate?) {
        self.originalDelegate = original
        super.init()
    }

    /// 红叉 / `Cmd+W` 都先到这里：**最小化并拒绝关闭**（`false` = 不要关）。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.miniaturize(nil)
        return false
    }

    // ⚠ 下面两个覆写是"透明代理"的关键：AppKit 用 `respondsToSelector:` 判断
    //   delegate 要不要收某个回调，判真之后才发消息；我们没实现的方法靠
    //   `forwardingTarget(for:)` 转给 SwiftUI 的原 delegate。
    //   少任何一个，SwiftUI 的那部分窗口行为就没了（且没有任何报错）。
    // ⚠ `nonisolated` 是被动的：这两个方法在 `NSObject` 上就是 nonisolated，
    //   覆写**不允许**加 `@MainActor`（编译报 actor isolation 不一致）。
    nonisolated override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) { return true }
        return originalDelegate?.responds(to: aSelector) ?? false
    }

    nonisolated override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if originalDelegate?.responds(to: aSelector) == true { return originalDelegate }
        return super.forwardingTarget(for: aSelector)
    }
}

/// 给**主窗口**装「关闭 = 最小化」守卫（幂等；装过就跳过）。
///
/// ⚠ 为什么用 `NSViewRepresentable` 而不是 `NSApp.windows` 里找：这里拿到的
///   `nsView.window` 是**承载本视图的那个窗口**，天然就是主窗口，不依赖任何启发式判据。
/// ⚠ 用 `viewDidMoveToWindow` 而不是 `DispatchQueue.main.async`：`makeNSView` 返回时视图
///   还没进入窗口树（`window` 是 nil），而 `viewDidMoveToWindow` 是系统在"真的挂上去了"
///   那一刻回调的 —— 同步、不猜时机。
struct MainWindowCloseGuardInstaller: NSViewRepresentable {

    final class Probe: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }

    func makeNSView(context: Context) -> Probe {
        let probe = Probe(frame: .zero)
        probe.onWindow = { AppDelegate.installCloseGuard(on: $0) }
        return probe
    }

    func updateNSView(_ nsView: Probe, context: Context) {
        // ⚠ 每次更新都再装一次（幂等）：SwiftUI 若在某个时点换回自己的 delegate，
        //   下一次布局就会把守卫重新装回来 —— 自愈，不需要额外的时机假设。
        if let window = nsView.window { AppDelegate.installCloseGuard(on: window) }
    }
}

extension View {
    /// 给主窗口装「关闭 = 最小化」守卫 —— 挂在 `AppShellView` 上，**只挂主窗口**。
    func mainWindowCloseGuard() -> some View {
        background(MainWindowCloseGuardInstaller())
    }
}

/// 给**主窗口**装空工具栏带 —— 摘掉 sidebarToggle 后 SwiftUI 侧工具栏塌、红绿灯掉 (8,8)，
/// 与设置窗口同一问题、同一解法：AppKit 层装一条 `.unified` 空工具栏把按钮抬回 (18,18)
/// （机制与出处见 `WindowTitleHider.installEmptyToolbar`；带背景/hairline 由
/// `AppShellView` 的 `.toolbarBackground(.hidden)` 抹掉）。
/// ⚠ 幂等（`window.toolbar == nil` 才装）+ `updateNSView` 自愈：SwiftUI 若在某个布局点
///   把工具栏摘了，下一次更新补回来。
struct MainWindowToolbarBandInstaller: NSViewRepresentable {

    final class Probe: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }

    func makeNSView(context: Context) -> Probe {
        let probe = Probe(frame: .zero)
        probe.onWindow = { window in
            WindowTitleHider.installEmptyToolbar(window, id: "main.empty.titlebar")
            // 红绿灯自愈：主窗口与设置窗口同一套（设置侧由 WindowTitleHider 自己挂）
            WindowTitleHider.installTrafficLightPinning(window)
            WindowTitleHider.schedulePinTrafficLights(window)
        }
        return probe
    }

    func updateNSView(_ nsView: Probe, context: Context) {
        if let window = nsView.window {
            WindowTitleHider.installEmptyToolbar(window, id: "main.empty.titlebar")
            WindowTitleHider.installTrafficLightPinning(window)
            WindowTitleHider.schedulePinTrafficLights(window)
        }
    }
}

extension View {
    /// 给主窗口装空工具栏带（红绿灯 (18,18)）—— 挂在 `AppShellView` 上，**只挂主窗口**。
    func mainWindowToolbarBand() -> some View {
        background(MainWindowToolbarBandInstaller())
    }
}

/// 设置窗口探针：隐藏标题栏文字 + 钉内部标题「Selected 设置」+ 装空工具栏带。
/// ⚠ 红绿灯摆位与主窗口**同一套**（左 / 上各 18，2026-10-23 老板要求对齐）：
///   观察器发现不在位 → `schedulePinTrafficLights` 在**下一轮 runloop** 摆一次。
///   ⚠ 不可在布局回合里同步摆：AppKit 的 `NSTitlebarView.layout()` 会在同一轮末尾
///   把按钮摆回 12/13.5 ⇒ 每次重绘都摆一次/退一次，红绿灯持续跳动（0.5.98 实测）。
///
/// ## 探针管三件事
/// ① **内部标题**：SwiftUI 把 `Settings` 窗口自动命名成「Selected设置」（无空格），而 Dock
///    悬浮预览画的就是内部标题 ⇒ 钉成「Selected 设置」。
///    ⚠ **只在开窗时钉**（探针写完 → SwiftUI 盖回自动命名 → 再补一次），此后**永不写标题**：
///    写 `window.title` 会触发标题栏重排，AppKit 顺势把红绿灯摆回 12/13.5 —— 这正是
///    「点标签切分类时红绿灯跳一下」的真因（0.5.99 实机复现）。主窗口从不写标题，所以不跳。
/// ② **空工具栏带**（`installEmptyToolbar`）：摘掉 sidebarToggle 后 SwiftUI 侧工具栏塌、
///    红绿灯掉 (8,8)；AppKit 层装一条 `.unified` 空工具栏把按钮垂直居中抬回 (18,18)
///    （手摆按钮 frame 争不过 AppKit 的标题栏布局）。带的可见背景/hairline 由
///    `SettingsView` 的 `.toolbarBackground(.hidden, for: .windowToolbar)` 抹掉。
/// ③ **titleVisibility=.hidden**：标题栏不画字。
/// ④ **开窗淡入**：见 `hideThenRevealOpeningTrafficLights` —— 首帧前灯是 alpha 0，
///    等标题栏布局落定、摆到 18 后才淡入，消除「刚打开时红绿灯跳一次」。
/// ⚠ 取窗口的方式与 `MainWindowCloseGuardInstaller` 同一套（`viewDidMoveToWindow`
///   + `updateNSView` 幂等重设）—— SwiftUI 若在某次布局里把外观属性改回去，下一次自愈。
struct WindowTitleHider: NSViewRepresentable {

    final class Probe: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }

    /// 幂等：值已经是目标值时不重复写（写窗口外观属性会触发一次重绘）
    private static func apply(to window: NSWindow) {
        if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
        // ⚠ 那条"横条"是详情列**空工具栏的底边 hairline**（工具栏项摘光后宿主仍在、照样画线）。
        //   解法是 `.toolbarBackground(.hidden, for: .windowToolbar)`（只隐工具栏背景/hairline、
        //   保留工具栏宿主与红绿灯），见 `SettingsView.body`。
        //   ⚠ 别用 `.toolbar(.hidden, for: .windowToolbar)`（会把红绿灯一起隐掉），
        //   也别用 `titlebarAppearsTransparent`（只压得住聚焦态的线，非聚焦态复现）。
        //
        // 红绿灯：与主窗口 `MainWindowToolbarBandInstaller` **完全同一套**（装带 → 挂观察器 →
        // 排队补摆），没有设置窗口专属逻辑。空工具栏带只到 12/13.5，18 由下一轮 runloop 摆；
        // ⚠ 本方法在 SwiftUI 布局回合里被调 —— 同步摆会与 AppKit 的标题栏布局互相拉扯 ⇒ 抖动。
        installEmptyToolbar(window)
        installTrafficLightPinning(window)
        schedulePinTrafficLights(window)
        // 标题只钉开窗这一次（见类型注释 ①）。
        pinTitleOnce(window)
    }

    func makeNSView(context: Context) -> Probe {
        let probe = Probe(frame: .zero)
        probe.onWindow = { Self.apply(to: $0) }
        return probe
    }

    func updateNSView(_ nsView: Probe, context: Context) {
        if let window = nsView.window { Self.apply(to: window) }
    }

    /// 已钉过标题的窗口（`apply` 会被 updateNSView 反复调，只做一次）。
    @MainActor private static var titledWindows: Set<ObjectIdentifier> = []

    /// 开窗时把内部标题钉成「Selected 设置」（带空格）——只此一次，之后**绝不**再写标题。
    ///
    /// ⚠ SwiftUI 会在探针写完标题之后把自动命名「Selected设置」盖回来一次 ⇒ 200ms 时补钉一次。
    ///   补钉会触发一次标题栏重排（红绿灯被摆回 12/13.5）⇒ 由开窗序列在 350ms 统一摆位后淡入。
    /// ⚠ 切分类时**不再**补写标题：那会在每次切换时重排标题栏，红绿灯肉眼可见地跳（0.5.99 实机）。
    @MainActor
    private static func pinTitleOnce(_ window: NSWindow) {
        let key = ObjectIdentifier(window)
        guard titledWindows.insert(key).inserted else { return }
        let target = "Selected 设置"
        if window.title != target { window.title = target }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            if window.title != target { window.title = target }
        }
    }

    /// 红绿灯摆位（上边和左边各留 **18pt**，2026-10-19 老板定，与侧栏/页栏的 18pt 边距同一套）。
    ///
    /// ⚠ **工具栏带只能到 12 / 13.5**（`.unifiedCompact` 空带，截图像素实测）——
    ///   系统把三颗按钮摆在它自己的标题栏布局里，`toolbarStyle` 与 SwiftUI 的 titlebar 修饰
    ///   都改不动这个位置。⇒ 带装好之后由 `schedulePinTrafficLights` 在下一轮 runloop
    ///   手摆按钮 frame（**不在布局回合里摆**，否则与 AppKit 互相拉扯 ⇒ 持续跳动）。
    ///   带仍然必须有：它撑出标题栏区、给红绿灯一个"站在材质上"的落点。
    ///   带的**可见性**（背景色 + 底边 hairline）由
    ///   `SettingsView` / `AppShellView` 的 `.toolbarBackground(.hidden, for: .windowToolbar)` 抹掉。
    ///   内容因带多出的顶部安全区，由两列各自 `.ignoresSafeArea(.container, edges: .top)` 收回。
    static func installEmptyToolbar(_ window: NSWindow, id: String = "settings.empty.titlebar") {
        // ⚠ 骨架版（0.5.38）起 SwiftUI 可能**已经**建了一条 `.automatic` 样式的工具栏
        //   （分栏宿主没了之后它不再自动用 unified）⇒ 旧版"有 toolbar 就整个跳过"会让
        //   样式设置一起被跳过，带高退化成 标题栏28+工具栏28=56 的双层带（真机实测），
        //   红绿灯/顶距全部掉坑。⇒ **样式必设**，只在没有工具栏时才补装空带。
        if window.toolbar == nil {
            let bar = NSToolbar(identifier: id)
            // ⚠ 不设 `bar.showsBaselineSeparator`：该属性 macOS 15 起废弃且被系统忽略，
            //   hairline 的隐藏由 `.toolbarBackground(.hidden)` 提供。
            window.toolbar = bar
        }
        // ⚠ 样式**必设为 `.unifiedCompact`**（0.5.39 骨架重校准，窗口本体截图像素实测）：
        //   `.unified` 在空带下实测带高 56（红绿灯顶被抬到 20，旧校准全漂）；
        //   `.unifiedCompact` 带高 ~30、红绿灯顶 13 —— 与旧终拍（红绿灯顶 13）齐。
        //   ⚠ **幂等**：本函数会被 didUpdate / updateNSView 高频调用，重复写同一个
        //   toolbarStyle 会触发一次标题栏重排（设置页切分类时红绿灯闪一下的真因）。
        if window.toolbarStyle != .unifiedCompact {
            window.toolbarStyle = .unifiedCompact
        }
    }

    /// 红绿灯的**目标边距**（左 / 上，单位 pt）。
    /// ⚠ 与侧栏 `sidebarFooter` 的 18、`PageActionBar` 的 18 是同一套值 —— 改一处要一起改。
    static let trafficLightInset: CGFloat = 18

    /// 当前按钮相对目标的偏差（`nil` = 取不到按钮 / 容器）。
    /// ⚠ 用**按钮相对标题栏容器**的坐标量（container 左缘 = 窗口左缘、container 顶 = 窗口顶，
    ///   实测 `bounds.height − frame.maxY` 正好 13.5，与截图像素一致）。
    ///   ⚠⚠ 别再改成 `convert(_:to: nil)` + `window.frame`：那个 nil 是**内容区**坐标系
    ///   （不含标题栏），与窗口 frame 差一个标题栏高 ⇒ 量出 -63 的 topGap，
    ///   按钮被整体推到窗口上方（0.5.55 踩过，症状是"三颗灯整组消失"）。
    @MainActor
    private static func trafficLightDelta(_ window: NSWindow) -> (buttons: [NSButton], dx: CGFloat, dy: CGFloat)? {
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
        guard let close = buttons.first, let container = close.superview else { return nil }
        let topGap = container.bounds.height - close.frame.maxY
        let leftGap = close.frame.minX
        return (buttons, trafficLightInset - leftGap, topGap - trafficLightInset)
    }

    /// 把三颗红绿灯挪到「左 18 / 上 18」。
    ///
    /// ⚠ 为什么必须手摆：`.unifiedCompact` 空带实测落在 **左 12 / 上 13.5**，
    ///   而老板要求 18 —— 差的这 6 / 4.5pt 系统不给调（按钮位置由 AppKit 标题栏布局决定）。
    /// ⚠ **整体平移**，不逐个摆坐标：按钮间距（实测步距 ~23）是系统定的，改它反而更不像原生。
    /// ⚠ 目标 y 用「距容器顶」算，不用硬编码 13.5 —— 容器坐标系原点在左下，
    ///   `bounds.height − frame.maxY` 才是"按钮上缘距顶"。
    /// ⚠ 幂等：已在目标位置就直接返回。
    /// ⚠⚠ **禁止在窗口布局回合里（`didUpdate` 等通知内）同步调用**：AppKit 的
    ///   `NSTitlebarView.layout()` 会在同一轮末尾把按钮摆回 12/13.5 ⇒ 每次重绘都
    ///   "摆到 18 又被摆回 12"，肉眼就是红绿灯持续跳动（0.5.98 实测）。
    ///   自愈统一走 `schedulePinTrafficLights`（下一轮 runloop 再摆）。
    ///   **唯一例外**：开窗淡入后紧接着的一次（alpha 0→1 会同步触发重排，必须在其后同轮补摆，
    ///   见 `hideThenRevealOpeningTrafficLights`）—— 那次不在通知回调里。
    @MainActor
    static func pinTrafficLights(_ window: NSWindow) {
        guard let m = trafficLightDelta(window) else { return }
        let dx = m.dx, dy = m.dy
        guard abs(dx) > 0.5 || abs(dy) > 0.5 else { return }
        // 防呆：单次位移超过 50pt 说明量算出错（正常只有 6 / 4.5）—— 宁可不挪，也别把按钮送走
        guard abs(dx) < 50, abs(dy) < 50 else {
            NSLog("[ERROR] 红绿灯位移异常 dx=%.1f dy=%.1f", dx, dy)
            return
        }
        for b in m.buttons {
            // ⚠ 容器坐标原点在左下 ⇒ **下移是 origin.y 减小**，即 `+= dy`（dy>0 表示要下移）
            b.frame.origin.x += dx
            b.frame.origin.y += dy
        }
    }

    /// 已排队补摆的窗口（同一窗口同时只排一个，避免每帧堆 Task）。
    @MainActor private static var pinScheduled: Set<ObjectIdentifier> = []

    /// 下一轮 runloop 把红绿灯摆到 18。
    ///
    /// ⚠ 这是唯一的自愈入口：观察器只负责"发现 + 排队"，
    ///   绝不在通知回调里同步移动按钮（那会与 AppKit 的标题栏布局互相拉扯 ⇒ 持续跳动）。
    /// - `force`: 跳过"当前是否不在位"的判断 —— 用于**刚发生过标题栏布局**的时机
    ///   （AppKit 的复位发生在 didUpdate 通知之后，通知里量到的可能还是旧位置）。
    /// - `delay`: 布局可能还没跑完时（切分类），等它落定再摆。
    @MainActor
    static func schedulePinTrafficLights(_ window: NSWindow, force: Bool = false,
                                         delay: Duration = .zero) {
        let key = ObjectIdentifier(window)
        guard !pinScheduled.contains(key) else { return }
        if !force, let m = trafficLightDelta(window),
           abs(m.dx) <= 0.5, abs(m.dy) <= 0.5 { return }
        pinScheduled.insert(key)
        Task { @MainActor in
            if delay > .zero { try? await Task.sleep(for: delay) }
            pinScheduled.remove(key)
            pinTrafficLights(window)
        }
    }

    /// 给窗口挂"红绿灯位置自愈"观察器（**幂等**，每个窗口只挂一次）。
    ///
    /// ⚠ 为什么必须自愈：AppKit 的 `NSTitlebarView.layout()` 每次重排都会把三颗按钮
    ///   摆回它自己的位置（实测：装完带立刻摆到 18，下一次布局后回到 12/13.5）。
    ///   ⇒ 监听 `didUpdate` / `didResize`，但**只负责发现 + 排队**，实际移动交给
    ///   `schedulePinTrafficLights` 在下一轮 runloop 做。
    ///   ⚠⚠ **绝不能在通知回调里同步 `pinTrafficLights`**：同一轮布局末尾 AppKit 会把它
    ///   摆回去，于是每次重绘都"摆到 18 又被摆回 12" ⇒ 红绿灯持续跳动（0.5.98 实测）。
    /// ⚠ 主窗口与设置窗口**都挂**（2026-10-23 起设置窗口也对齐 18/18）。
    /// ⚠ 首次挂载还会跑一次开窗序列（先藏灯 → 上屏后淡入并在同一轮摆位，见
    ///   `hideThenRevealOpeningTrafficLights`），两个窗口共用、只有一处实现。
    /// ⚠ 观察器登记在 `trafficObservers`，退出时统一移除（闭包式观察者不移除即永久持有）。
    @MainActor private static var trafficObservers: [ObjectIdentifier: [NSObjectProtocol]] = [:]

    @MainActor
    static func installTrafficLightPinning(_ window: NSWindow) {
        let key = ObjectIdentifier(window)
        guard trafficObservers[key] == nil else { return }
        let nc = NotificationCenter.default
        var tokens: [NSObjectProtocol] = []
        for name in [NSWindow.didUpdateNotification, NSWindow.didResizeNotification] {
            tokens.append(nc.addObserver(forName: name, object: window, queue: .main) { _ in
                // ⚠ 只"发现 + 排队"，**不在这里同步摆**：AppKit 的 `NSTitlebarView.layout()`
                //   在同一轮更新末尾会把按钮摆回 12/13.5 ⇒ 同步摆会在每次重绘时
                //   "摆到 18 又被摆回" ⇒ 红绿灯持续跳动（0.5.98 实测）。
                //   下一轮 runloop 再摆才留得住（见 `schedulePinTrafficLights`）。
                //   resize 强制排队：复位可能发生在 didResize 之后，此刻量到的还是旧位置。
                let isResize = (name == NSWindow.didResizeNotification)
                MainActor.assumeIsolated {
                    schedulePinTrafficLights(window, force: isResize)
                }
            })
        }
        trafficObservers[key] = tokens
        hideThenRevealOpeningTrafficLights(window)
    }

    /// 开窗时先藏灯，等窗口上屏、首轮布局落定后再淡入 —— 消除"刚打开时红绿灯跳一次"。
    ///
    /// ⚠ **顺序是修复的核心**：`alphaValue` 从 0 变 1 会**同步触发** AppKit 的标题栏重排
    ///   （实测：淡入那一毫秒按钮被摆回 12/13.5）。⇒ 必须**先启动淡入、紧接着在同一轮
    ///   runloop 摆位**：重排与摆位都发生在下一次绘制之前，肉眼不会看到 12/13.5 那一帧。
    ///   反过来（先摆位再淡入）= 复位把摆位顶掉，下一轮补摆 → 开窗跳一下（0.5.101 的症状）。
    /// ⚠ 已经可见的窗口不藏：探针晚挂到已显示的窗口时闪灯比跳位更糟。
    @MainActor
    private static func hideThenRevealOpeningTrafficLights(_ window: NSWindow) {
        guard !window.isVisible else { return }
        let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for t in types { window.standardWindowButton(t)?.alphaValue = 0 }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            let buttons = types.compactMap { window.standardWindowButton($0) }
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0.1
            for b in buttons { b.animator().alphaValue = 1 }
            NSAnimationContext.endGrouping()
            pinTrafficLights(window)
        }
    }

    /// 退出时统一移除红绿灯自愈观察器（`applicationWillTerminate` 调用）。
    @MainActor
    static func removeAllTrafficLightObservers() {
        let nc = NotificationCenter.default
        for tokens in trafficObservers.values { tokens.forEach(nc.removeObserver) }
        trafficObservers.removeAll()
    }
}

extension View {
    /// 隐藏窗口标题栏的文字（窗口身份改由内容区左上角的页名承载）。
    /// ⚠ 目前**只有设置窗口**用：主窗口那侧走的是 `.toolbar(removing: .title)`（另一套机制，
    ///   它摘的是工具栏里的 title 项）。
    func hideWindowTitle() -> some View {
        background(WindowTitleHider())
    }
}

/// 单窗口策略：把已有主窗口揭开并置前；**没有**主窗口时返回 false（调用方决定要不要开新的）。
/// 菜单栏「打开主窗口」与 `AppDelegate.reopenMainWindow` 句柄**共用这一份实现**。
///
/// ⚠ 判据：
///   · **第一条按 `mainWindowID` 身份标记精确命中**：主窗口最小化后永远不销毁，
///     而"已最小化"的窗口下面三条启发式全满足、设置窗口也全满足 ⇒ 分不出哪个是主窗口；
///     找不到才回落启发式（如守卫还没装上）。
///   · `contentView != nil` —— 无内容的不是可展示窗口；
///   · `!isKind(of: NSPanel.self)` —— 排除菜单栏 `MenuBarExtra` 的面板；
///   · `sheetParent == nil` —— **排除 sheet**：`.sheet`（个股详情 / 参数编辑）在 macOS 上是
///     **独立普通窗口**，开着弹窗时点「打开主窗口」若不排除会把**弹窗**置前，而用户要主窗口。
/// ⚠ 不能是 `private`：点通知跳页（`Notifier.didReceive`）也要走这同一条路，
///   在那里只有 `openWindow` 环境值的持有者（`MenuBarMenu`）才拿得到"开新窗口"的能力，
///   所以两边共用这个"只揭开已有窗口"的判据，而不是各写一份找窗逻辑。
@MainActor
func focusExistingMainWindow() -> Bool {
    if let main = NSApp.windows.first(where: { $0.identifier?.rawValue == mainWindowID }),
       main.contentView != nil {
        revealWindow(main)
        return true
    }
    for window in NSApp.windows {
        if window.contentView != nil,
           !window.isKind(of: NSPanel.self),
           window.sheetParent == nil {
            revealWindow(window)
            return true
        }
    }
    return false
}

/// 把窗口**从 Dock 里放出来**并置前。
///
/// ⚠ 必须显式 `deminiaturize`：最小化的窗口 `makeKeyAndOrderFront` 是**不放它出来**的
///   （`isVisible` 仍为 false、窗口仍躺在 Dock 里）⇒ 只调它，现象是「点了 Dock 图标什么都没发生」。
@MainActor
private func revealWindow(_ window: NSWindow) {
    if window.isMiniaturized { window.deminiaturize(nil) }
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
}
