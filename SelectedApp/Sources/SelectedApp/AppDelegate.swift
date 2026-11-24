import SwiftUI
import AppKit
import SelectedCore

// MARK: - 应用生命周期代理

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 主窗口重开句柄：Dock 点击/菜单栏「打开主窗口」共用（delegate 接管 reopen 后
    /// SwiftUI WindowGroup 的自动重建不再可靠，必须显式 openWindow）
    @MainActor static var reopenMainWindow: (() -> Void)?
    /// 新手引导重开句柄：设置页「重看新手引导」→ AppShellView 的 sheet
    @MainActor static var reopenOnboarding: (() -> Void)?
    /// 主窗口的关闭守卫实例。
    ///
    /// ⚠ **必须强引用**：`NSWindow.delegate` 是 **weak** —— 只 `window.delegate = 守卫`
    ///   而不持有的话，守卫在 `installCloseGuard` 返回后就被释放，
    ///   `windowShouldClose` **永远不会被调用**（现象：红叉照旧真关，且没有任何报错）。
    @MainActor private static var closeGuard: MainWindowCloseGuard?

    /// 给主窗口装「关闭 = 最小化」守卫（**幂等**：装过就跳过）。
    ///
    /// 只在**主窗口**装 —— 调用点是 `AppShellView` 上的 `.mainWindowCloseGuard()`；
    /// 设置窗口（`Settings` scene）走不到这里，红叉仍是标准的"关掉"。
    @MainActor static func installCloseGuard(on window: NSWindow) {
        // 普通窗口才装：sheet / 弹出面板都不是"主窗口"（`.sheet` 在 macOS 上是独立窗口）
        guard window.sheetParent == nil, !window.isKind(of: NSPanel.self) else { return }
        guard !(window.delegate is MainWindowCloseGuard) else { return }
        let guardObject = MainWindowCloseGuard(original: window.delegate)
        closeGuard = guardObject
        window.delegate = guardObject
        // 打身份标记：`focusExistingMainWindow()` 靠它区分"最小化的主窗口"与设置窗口
        // （关窗=最小化之后，主窗口不会销毁，只靠"有 contentView / 非面板 / 非 sheet"
        //   分不出这两个窗口）。
        window.identifier = NSUserInterfaceItemIdentifier(mainWindowID)
    }

    /// 引擎任务完成通知的观察者令牌。
    /// ⚠ 闭包式观察者会被 NotificationCenter 永久持有 ⇒ 必须显式移除；本类是 App 级单例、
    ///   随 App 存活，故在 `applicationWillTerminate` 移除即为最合适的时机（deinit 实际不会先跑到）。
    private var engineTaskObserver: NSObjectProtocol?

    /// 设置窗口尺寸的**一次性重置**。
    ///
    /// ## 为什么需要
    /// 设置窗口的尺寸/位置由 AppKit 自动记忆（`UserDefaults` 的
    /// `NSWindow Frame com_apple_SwiftUI_Settings_window`）—— 改窗口默认尺寸后，
    /// **旧记忆会让新默认永远不生效**（看起来像"改了没反应"）。
    /// ⇒ 删掉旧记忆**一次**（打标记），之后用户自己调过的尺寸仍照常记忆
    ///   （不打标记就会每次启动都清掉用户调好的尺寸，那是另一个 bug）。
    ///
    /// ⚠ 键名是 SwiftUI 内部的（`com_apple_SwiftUI_Settings_window`），换系统版本可能变 ——
    ///   所以按「前缀 `NSWindow Frame ` + 名字含 Settings」匹配，不写死整串；
    ///   匹配不到时**什么都不做**（最坏情况是新默认不生效，用户手动拖一下即可）。
    /// ⚠ 只删设置窗口的键：主窗口那份（`NSWindow Frame main-AppWindow-1`）**不动**。
    /// ⚠ **每次改默认尺寸都要换新标记**再清一次（旧标记保留：它记录"那次决策已执行过"，
    ///   删了会让更早的记忆复活）。
    @MainActor
    static func resetSettingsWindowFrameOnce() {
        let marker = "settingsWindowFrameReset.20261112.a"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: marker) else { return }
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix("NSWindow Frame ") && key.contains("Settings") {
            defaults.removeObject(forKey: key)
        }
        defaults.set(true, forKey: marker)
    }

    /// ⚠ 必须早于 SwiftUI 建窗（以及 AppKit 的状态恢复）—— `applicationWillFinishLaunching`
    ///   是 AppKit **最早**的 delegate 回调，`applicationDidFinishLaunching` 时窗口可能已经好了。
    @MainActor
    func applicationWillFinishLaunching(_ notification: Notification) {
        // 单实例守卫最先跑（审查 #13）：重复实例连建库都不必发生
        AppDelegate.enforceSingleInstance()
        AppDelegate.resetSettingsWindowFrameOnce()
        AppDelegate.resetMainWindowFrameOnce()
        AppDelegate.removeLegacyPaletteOnce()
    }

    /// 单实例守卫（审查 #13）：`open -n` / 再启动一份 .app 会起第二个进程 ——
    /// 两个调度器同时写**同一个库**（SQLite 串行事务只保证库不损坏，调度状态、
    /// 通知、轮次落库会互相打架）。发现同 bundle id 的已有实例 ⇒ 激活它、本进程退出。
    ///
    /// ⚠ 两类豁免，**都必须保留**：
    ///   - **快照进程**（DEBUG，`VisualSnapshot.isRequested`）：`visual_snapshot.sh`
    ///     刻意并跑一份副本（临时数据目录 + 独立偏好域），它不是"重复实例"；
    ///   - **直跑二进制**（`swift run`/测试）：无 bundle 身份可比对 ⇒ 放行。
    /// ⚠ 同时启动两个实例的极端竞态（互相看不见对方）不在本守卫射程内 ——
    ///   事务保底不损坏，这里只挡日常形态的重复启动。
    @MainActor
    static func enforceSingleInstance() {
        #if DEBUG
        if VisualSnapshot.isRequested { return }
        #endif
        guard let myID = Bundle.main.bundleIdentifier else { return }
        let me = getpid()
        guard let other = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == myID && $0.processIdentifier != me && !$0.isTerminated
        }) else { return }
        NSLog("[NOTICE] [Selected] 单实例守卫：已有实例 pid=\(other.processIdentifier)，本次启动退出")
        other.activate(options: [.activateAllWindows])
        NSApp.terminate(nil)
    }

    /// 一次性清掉旧的「配色档位」持久化键（主题功能已下线，2026-10-30）。
    ///
    /// 留着虽无读取方，但会让快照/旧版本把用户以前选的档位"复活"。
    /// 与上面两个 reset 同一个 marker 模式：只执行一次，旧标记保留。
    @MainActor
    static func removeLegacyPaletteOnce() {
        let marker = "paletteRemoved.20261030.a"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: marker) else { return }
        defaults.removeObject(forKey: "palette")
        defaults.set(true, forKey: marker)
    }

    /// 主窗口尺寸的**一次性重置**（与设置窗口那份同一个坑：AppKit 记忆旧尺寸会让新默认永远不生效）。
    ///
    /// ⚠ 与 `resetSettingsWindowFrameOnce` **分开、各自一个标记**：它们是独立决策，
    ///   合用一个标记会让"后改的那次"连带把"先改的那次"的用户尺寸也清掉。
    /// ⚠ 键名匹配用「前缀 `NSWindow Frame ` + 含 AppWindow」，不写死整串
    ///   （SwiftUI 内部命名可能变；匹配不到时什么都不做）。
    /// ⚠ **每次改默认尺寸都要换新标记**再清一次（旧标记保留，它记录"那次决策已执行过"）。
    @MainActor
    static func resetMainWindowFrameOnce() {
        let marker = "mainWindowFrameReset.20261023.a"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: marker) else { return }
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix("NSWindow Frame ") && key.contains("AppWindow") {
            defaults.removeObject(forKey: key)
        }
        defaults.set(true, forKey: marker)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 外观偏好先落地（设置页可切 跟随系统/浅色/深色）：必须在建窗口前设置，
        // 否则首屏会先按系统外观画一帧再跳变
        AppearanceStore.shared.apply()
        // 建库 / schema 迁移：「首次建库 + 存量库迁移 + 出厂参数补种」由 Swift 完成 ——
        // 否则新机器无库可用（各 Store 的读路径只能报"数据库不存在"）。
        DBBootstrap.ensureReady()
        // ⚠ 通知授权的**唯一入口**（不在 `Notifier.init` 里再调一处；两处都写等于没人知道哪处是权威）。
        Notifier.shared.requestAuth()
        // ⚠ **快照进程一条后台轮询都不启动**（判据与实测原因见 `VisualSnapshot.isRequested`）：
        //   `Scheduler.start()` 内部同步 `tick(reason: "启动")` 会当场补跑到点任务，
        //   等第 132 行的 `runIfRequested()` 再 `stop()` 已经晚了 —— 2026-10-23 实锤：
        //   一次深色扫掠中途执行了「早盘预判」，把结果写进了快照自己的偏好域。
        #if DEBUG
        let startBackgroundWork = !VisualSnapshot.isRequested
        #else
        let startBackgroundWork = true
        #endif
        if startBackgroundWork {
            Scheduler.shared.start()
            // 自选提醒的常驻轮询：**唯一**的行情轮询方，写 `Store.liveQuotes`。
            // ⚠ 必须在这里启动而不是在自选页 —— 靠视图驱动的轮询切页即静默失效。
            AlertMonitor.shared.start()
            // 板块行情的**盘中后台刷新** —— 与 `AlertMonitor` 同一模式（时段门控 + 不活跃降频），互不干扰
            BoardMonitor.shared.start()
            // 看板盘中数据（四指数 / 昨涨停情绪 / 领涨板块 TopN）—— 60 秒级，独立于全量板块任务
            DashboardLiveMonitor.shared.start()
            // 自动更新：Sparkle 约定必须在启动完成之后 start（菜单/绑定尚未就绪）。
            // ⚠ 放在 `startBackgroundWork` 里 = 快照进程不查更新（快照不该有网络副作用）。
            UpdateCenter.shared.start()
        }
        Store.shared.scheduleInitialSelftest()
        Store.shared.startSelftestLoop()
        FocusDismissMonitor.shared.start()
        // 启动即刷：不等主窗口视图的 .task（窗口恢复场景下 SwiftUI task 时机不可靠，
        // 曾表现为打开 app 首屏空、手点刷新才出现）。refresh 毫秒级且幂等，双触发无害
        Task { @MainActor in
            Store.shared.refresh()
        }
        engineTaskObserver = NotificationCenter.default.addObserver(
            forName: .engineTaskCompleted, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                Store.shared.refreshToday()
            }
        }
        // 「禁用新建窗口」由场景上的 `.commands { CommandGroup(replacing: .newItem) { } }`
        // 处理（编译期接管，与系统语言无关），不在这里动菜单。
        #if DEBUG
        VisualSnapshot.runIfRequested()
        #endif
    }

    /// Dock 图标点击：有窗口则激活，无则显式重建主窗口。
    ///
    /// ⚠⚠ 签名必须 `-> Bool`（`NSApplicationDelegate` 的 requirement）：写成 `-> Void`
    ///   只会得到一句 `nearly matches optional requirement` 警告，**protocol 不认它、从不调用**。
    ///   **判据：`nearly matches optional requirement` 必须当错误看** —— 它意味着"你写的方法没生效"。
    ///
    /// ⚠ 「关闭 = 最小化」之后**主窗口可能已最小化**：`isVisible == false` ⇒ 系统给的 `flag`
    ///   仍是 `false`，走下面这条路径；由 `focusExistingMainWindow()` 里的 `deminiaturize`
    ///   把窗口从 Dock 里放出来（**不能**只 `makeKeyAndOrderFront` —— 那不放它出来）。
    ///   ⚠ `flag == true`（有可见窗口，如只开着设置窗口）时**不做任何事**：与系统一致 ——
    ///     macOS 上"点 Dock 图标"只把可见窗口带到前面，不会去展开 Dock 里缩着的那一个。
    @MainActor func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        AppDelegate.reopenMainWindow?()
        return true
    }

    /// 关闭最后一个窗口：应用驻留后台（调度继续），不退出
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// App 退出收尾（释放各类定时器/观察者/令牌）
    func applicationWillTerminate(_ notification: Notification) {
        // 移除闭包式观察者：NotificationCenter 会一直持有它，不移除即永久泄漏
        if let token = engineTaskObserver {
            NotificationCenter.default.removeObserver(token)
            engineTaskObserver = nil
        }
        // 停掉调度器：释放定时器、`NSWorkspace` 唤醒观察者与 App Nap activity token
        // （都属于"不释放就泄漏"的闭包/令牌）
        Scheduler.shared.stop()
        // 停掉自选轮询、板块刷新、看板盘中刷新与"点空白失焦"事件监视器
        // （stop() 均幂等；terminate 是唯一的显式收尾路径。审查 #14：`DashboardLiveMonitor`
        //   随后台工作启动、原先收尾清单漏了它 —— 它自己的轮询 Task 会活到进程最后一刻）
        AlertMonitor.shared.stop()
        BoardMonitor.shared.stop()
        DashboardLiveMonitor.shared.stop()
        FocusDismissMonitor.shared.stop()
        // 红绿灯自愈观察器（只注册不移除会泄漏，见 installTrafficLightPinning 注释）
        WindowTitleHider.removeAllTrafficLightObservers()
    }
}
