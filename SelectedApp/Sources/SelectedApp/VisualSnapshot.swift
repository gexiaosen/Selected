#if DEBUG
import Foundation
import SwiftUI
import AppKit
import SelectedCore

// MARK: - 调试用视觉快照（release 编译为空）
//
// 触发：环境变量 `SELECTED_SNAPSHOT_DIR` 非空（由 Tools/visual_snapshot.sh 设置）。
// 只读隔离数据副本；不启动调度/轮询，不碰生产库。
// ⚠ 本项目不做读屏无障碍 / 不写裸 .white / 字号走 AppFont —— 与静态护栏同一口径。

@MainActor
enum VisualSnapshot {
    /// 本次进程是不是快照进程（**只读环境变量，无副作用**）。
    ///
    /// ⚠ 为什么要把判据单独暴露出来（2026-10-23 实测）：`AppDelegate` 里
    ///   `Scheduler.shared.start()` 在第 106 行，而 `runIfRequested()` 在第 132 行 ——
    ///   `start()` 内部会**同步 `tick(reason: "启动")`**，于是"到点就补跑"的活儿在
    ///   `stop()` 之前就已经跑起来了。实锤：09:30 那次快照进程真的执行了「早盘预判」，
    ///   并把 `scheduleState_2026-10-23` 写进了快照自己的偏好域。
    ///   ⇒ 扫掠中途数据被改，出图不可复现。**光 `stop()` 不够，得从一开始就不启动。**
    static var isRequested: Bool {
        !(ProcessInfo.processInfo.environment["SELECTED_SNAPSHOT_DIR"] ?? "").isEmpty
    }

    static func runIfRequested() {
        guard let dir = ProcessInfo.processInfo.environment["SELECTED_SNAPSHOT_DIR"],
              !dir.isEmpty else { return }
        UserDefaults.standard.set(true, forKey: "onboardingCompleted")
        Store.shared.previewMode = true
        // 兜底（正常路径下 `AppDelegate` 已经因为 `isRequested` 根本没启动它们）
        Scheduler.shared.stop()
        AlertMonitor.shared.stop()
        BoardMonitor.shared.stop()
        // ⚠ 这一条 2026-10-23 才补上：`DashboardLiveMonitor`（盘中 60s 拉指数/情绪/板块）
        //   原本**从来没被这个入口停过** —— 三个 stop 里漏了它，于是扫掠跑到第 60 秒
        //   它就刷新一次，卡片内容当场变化。
        DashboardLiveMonitor.shared.stop()
        log("start mode=\(AppearanceStore.shared.mode.rawValue)")
        startPageWriteProbe()

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            let out = URL(fileURLWithPath: dir, isDirectory: true)
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            guard let window = mainWindow() else {
                log("no main window")
                exit(0)
            }
            window.setFrame(NSRect(x: 80, y: 80, width: 1360, height: 860), display: true)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .seconds(1.0))
            // 固定查看日：否则 Store 会恢复上次的日期，两次快照的数据/空态可能不同，
            // 基线 diff 会被“今天/历史”状态污染。默认取库里最近有数据的交易日。
            if let d = ProcessInfo.processInfo.environment["SELECTED_SNAPSHOT_DATE"], !d.isEmpty {
                Store.shared.setViewDate(d)
            } else {
                let latest = Store.shared.latestDataDate
                if Store.shared.viewDate != latest {
                    Store.shared.setViewDate(latest)
                }
            }
            try? await Task.sleep(for: .seconds(0.8))

            for page in [Page.dashboard, .results, .indicators, .predict, .review,
                         .board, .watch, .params, .history] {
                try? await Task.sleep(for: .seconds(0.6))
                if await selectPage(page, label: page.rawValue) {
                    await snap(window: window, to: out, name: page.rawValue)
                } else {
                    await snap(window: window, to: out, name: "BADPAGE-\(page.rawValue)")
                }
                // 窄窗口另外抓两张（页面下界 920×560）
                if page == .dashboard || page == .results {
                    window.setFrame(NSRect(x: 80, y: 80, width: 920, height: 560), display: true)
                    try? await Task.sleep(for: .seconds(1.0))
                    await snap(window: window, to: out, name: "min-\(page.rawValue)")
                    window.setFrame(NSRect(x: 80, y: 80, width: 1360, height: 860), display: true)
                    try? await Task.sleep(for: .seconds(0.5))
                }
            }

            // 可选：个股详情 sheet（验证高度可调 + 价格轴标签不叠）
            if let code = ProcessInfo.processInfo.environment["SELECTED_SNAPSHOT_CODE"], !code.isEmpty {
                Store.shared.showStockDetail(code: code, name: code)
                try? await Task.sleep(for: .seconds(2.5))
                if let sheet = NSApp.windows.first(where: { $0.sheetParent != nil }) {
                    log("detail sheet resizable=\(sheet.isResizable) min=\(sheet.contentMinSize) max=\(sheet.contentMaxSize)")
                    await snap(window: sheet, to: out, name: "stock-detail-720")
                    sheet.setContentSize(NSSize(width: SheetMetrics.stockDetail.width, height: 900))
                    try? await Task.sleep(for: .seconds(0.8))
                    await snap(window: sheet, to: out, name: "stock-detail-900")
                }
                Store.shared.closeStockDetail()
                try? await Task.sleep(for: .seconds(0.6))
            }

            // 设置窗口（两种分类）
            UserDefaults.standard.set("schedule", forKey: "settings.category")
            if openSettingsViaMenu() {
                try? await Task.sleep(for: .seconds(1.6))
                if let settings = settingsWindow() {
                    NSApp.activate(ignoringOtherApps: true)
                    settings.makeKeyAndOrderFront(nil)
                    settings.setContentSize(SheetMetrics.settingsWindow)
                    try? await Task.sleep(for: .seconds(0.8))
                    await snap(window: settings, to: out, name: "settings-schedule")
                    UserDefaults.standard.set("dashboard", forKey: "settings.category")
                    try? await Task.sleep(for: .seconds(1.0))
                    await snap(window: settings, to: out, name: "settings-display")
                    UserDefaults.standard.set("sources", forKey: "settings.category")
                    try? await Task.sleep(for: .seconds(1.0))
                    await snap(window: settings, to: out, name: "settings-sources")
                    UserDefaults.standard.set("about", forKey: "settings.category")
                    try? await Task.sleep(for: .seconds(1.0))
                    await snap(window: settings, to: out, name: "settings-about")
                    settings.orderOut(nil)
                } else {
                    log("settings window missing")
                }
            } else {
                log("settings menu action failed")
            }

            // 新手引导
            try? await Task.sleep(for: .seconds(0.5))
            window.makeKeyAndOrderFront(nil)
            AppDelegate.reopenOnboarding?()
            try? await Task.sleep(for: .seconds(1.4))
            if let sheet = NSApp.windows.first(where: { $0.sheetParent != nil }) {
                await snap(window: sheet, to: out, name: "onboarding")
            }

            log("done")
            // 快照进程不承载任何生产状态：直接退出，避免 SwiftUI sheet/窗口的终止路径偶发挂住
            exit(0)
        }
    }

    /// 选页 + **等视图自己承认画到了那一页**（`PageProbe.rendered`），最多重试 3 次。
    ///
    /// ⚠ 为什么不能写完 `UserDefaults` 就当成功（2026-10-22 实测）：扫掠里出现过
    ///   文件名写着 `results`、内容却是「参数中心」的图 —— **文件名会撒谎**。
    ///   ⇒ 每张图都必须由视图侧自报的页面对一次；对不上就换 `BADPAGE-` 前缀落盘。
    ///
    /// **2026-10-23 量到的那条滞后**：写完存储到视图跟上约 **180ms**
    /// （`page 存储=dashboard 视图=history` → 182ms 后 `视图=dashboard`），重试循环吸收得掉。
    /// 当天两趟扫掠（18+20 张）0 个 BADPAGE，且探针没抓到任何"我们之外的人"写这个键。
    /// ⚠ 原先这里写着"调度器/告警/板块监视在入口开头就 stop() 了，所以不是它们抢的" ——
    ///   **那句判据是错的**：`Scheduler.start()` 的同步 `tick()` 在 `stop()` 之前就把到点任务跑了
    ///   （见 `isRequested` 的注释）。中途改数据的是它，不是"未知来源"。
    ///   残余风险（未复现、未排除）：`PageProbe.rendered` 是**进程级单值**，若同一进程里
    ///   存在两个壳视图（窗口恢复 / 通知拉起的第二扇窗），自报的页与被拍的窗可能对不上。
    ///   ⇒ 探针顺带打候选窗口数，真漂了先看那个数是不是 >1。
    private static func selectPage(_ page: Page, label: String) async -> Bool {
        expecting = page
        defer { expecting = nil }
        for attempt in 1...3 {
            Page.select(page)
            let readBack = UserDefaults.standard.string(forKey: Page.storageKey) ?? "nil"
            if readBack != page.rawValue {
                log("⚠ \(label) 写完立刻读回是 \(readBack)（要 \(page.rawValue)）⇒ 写入被别的域挡住")
            }
            for _ in 0..<20 {                       // 最多等 2s
                if PageProbe.rendered == page { return true }
                try? await Task.sleep(for: .milliseconds(100))
            }
            log("⚠ \(label) 第 \(attempt) 次选页后详情列仍在 \(String(describing: PageProbe.rendered))（要 \(page.rawValue)）")
        }
        log("❌ \(label) 选页失败：视图始终没画到 \(page.rawValue) —— 这张图不可信")
        return false
    }

    // MARK: 选页漂移探针（2026-10-23 调查用）
    //
    // 现象：扫掠里 `Page.select(.dashboard)` 写完，出图却是「参数中心」，**文件名撒谎**。
    // 探针 = 每 100ms 取一次「存储里的页 / 视图自报的页」，只在**变化时**记一行。
    // 为什么轮询而不是 KVO：`UserDefaults` 的动态键拿不到类型化 `KeyPath`，
    // Swift 6 下字符串 KVO 又要 `nonisolated` 闭包往主线程跳 —— 定位"谁在什么时候改了页"
    // 用不着那个精度，100ms 的时序足够把"我们写的"和"别人写的"分开。
    /// 当前正在等的页（区分"我们自己写的"与"别人写的"）
    private static var expecting: Page?
    private static var probeStored: String?
    private static var probeDrawn: String?

    static func startPageWriteProbe() {
        Task { @MainActor in
            while true {
                let stored = UserDefaults.standard.string(forKey: Page.storageKey) ?? "nil"
                let drawn = PageProbe.rendered.map(\.rawValue) ?? "—"
                if stored != probeStored || drawn != probeDrawn {
                    let candidates = NSApp.windows.filter {
                        $0.canBecomeMain && $0.isVisible && $0.sheetParent == nil
                    }.count
                    log("page 存储=\(stored) 视图=\(drawn)｜期望 \(expecting.map(\.rawValue) ?? "—")｜候选主窗 \(candidates)")
                    probeStored = stored
                    probeDrawn = drawn
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private static func log(_ s: String) {
        NSLog("[DEBUG] [snapshot] \(s)")
    }

    private static func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue == mainWindowID }
            ?? NSApp.windows.first { $0.canBecomeMain && $0.isVisible && $0.sheetParent == nil }
    }

    private static func settingsWindow() -> NSWindow? {
        NSApp.windows.first {
            $0.sheetParent == nil && $0 !== mainWindow()
                && ($0.title.contains("设置") || $0.title.contains("Settings"))
        }
    }

    private static func openSettingsViaMenu() -> Bool {
        guard let main = NSApp.mainMenu else { return false }
        for top in main.items {
            guard let sub = top.submenu else { continue }
            if let item = sub.items.first(where: { $0.keyEquivalent == "," && $0.isEnabled }),
               let action = item.action {
                return NSApp.sendAction(action, to: item.target, from: item)
            }
        }
        return false
    }

    /// 截图前清掉全部 toast，并确保窗口是 key/active：这些是运行环境噪声，不应进视觉基线。
    // ⚠⚠ **高对比度（HC）外观没法从 App 侧强设**（2026-10-22 实测，别再试第三条路）：
    //   试过 `NSApp.appearance = NSAppearance(named: .accessibilityHighContrast*Aqua)`，
    //   出图与普通外观**逐像素比只差 0.01%（噪声）**⇒ 根本没进 HC。
    //   HC 由系统「辅助功能 → 显示 → 提高对比度」驱动，不是 App 可选外观。
    //   ⚠ 而且**别用 `appearance.name` 当证据**：HC 对象的 `name` 自报的就是
    //     `NSAppearanceNameAqua`（实测），看着像"没设上"其实它连"设上了"也报这个 —— 两次都会骗人。
    //   ⇒ 要验 HC 只能请用户临时打开系统设置那一档（属于改全局环境，需明确批准）。
    private static func snap(window: NSWindow, to dir: URL, name: String) async {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        for toast in ToastCenter.shared.visible {
            ToastCenter.shared.dismiss(toast.id)
        }
        try? await Task.sleep(for: .milliseconds(300))
        capture(window: window, to: dir, name: name)
    }

    private static func capture(window: NSWindow, to dir: URL, name: String) {
        guard let view = window.contentView?.superview ?? window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        // 固定 2x 位图：窗口瞬时失焦/不在屏上时 `bitmapImageRepForCachingDisplay`
        // 偶尔回落到 1x，导致基线尺寸不一致。显式建 2x rep 规避。
        let scale: CGFloat = 2
        let width = Int(view.bounds.width * scale)
        let height = Int(view.bounds.height * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: width, pixelsHigh: height,
                                         bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: dir.appendingPathComponent("\(name).png"))
        log("wrote \(name)")
    }
}
#endif
