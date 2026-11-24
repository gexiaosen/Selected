import Foundation
import UserNotifications
import AppKit
import SelectedCore   // `NotifyPolicy`（通知三态裁决）

/// 通知深链在**页面之内**的定位标记（`userInfo["section"]` 的取值域）。
///
/// 为什么需要：三轮对比并入选股结果之后「跳到哪一页」不再等于「看到哪一格」——
/// 结果页是一条时间线（三轮 + 三轮对比），只跳页会把人停在某一轮那格，而正文说的是对比结论。
/// ⚠ 两端都走这个枚举（`Scheduler.notifyTarget` 写、`didReceive` 读），
///   字符串只在系统归档的边界上出现一次；新增段落加 case，编译器负责找出没接上的地方。
enum NotifySection: String {
    /// 选股结果页时间线的第四格「三轮对比」（`ResultsView.Leg.compare`）
    case compare
}

/// macOS 通知中心（F10）
@MainActor
final public class Notifier: NSObject, UNUserNotificationCenterDelegate {
    public static let shared = Notifier()

    /// 授权状态：`nil` = **还没裁决**（系统回调还没回来）；`true`/`false` = 已裁决。
    ///
    /// ⚠ 必须是三态而不是一个 `Bool`：把"还没裁决"与"已拒绝"混成一件事，
    ///   **启动瞬间**（回调回来之前）发出的通知就会被当成"已拒绝"静默丢掉、没有任何痕迹。
    private var authState: Bool?

    /// 前台激活观察者令牌（见 `refreshAuthFromSystem`）。
    /// ⚠ 闭包式观察者会被 NotificationCenter 永久持有，注册处必须能看到令牌放在哪
    ///   （与 `AppDelegate.engineTaskObserver` 同一条纪律；`Notifier.shared` 与 App 同生命周期、无拆除时机）。
    private var activationObserver: NSObjectProtocol?

    /// 授权裁决**之前**暂存的通知（裁决一到就补发）。
    /// ⚠ **有界**（见 `pendingLimit`）：异常情况下不能无限增长。
    private var pending: [(title: String, body: String, identifier: String,
                           userInfo: [String: String])] = []

    private static let pendingLimit = 8

    /// 因"已拒绝授权"被拦下的通知**条数**（供设置页提示）
    private(set) var suppressedCount = 0
    /// 最近一条因未授权被拦下的通知标题（保留给可能的 UI 提示）
    private(set) var lastSuppressed: String?

    // MARK: 因缺行情被跳过的判定

    /// 最近一轮里「**配了提醒但没行情**」而**未判定**的票数。
    ///
    /// ## 为什么与 `suppressedCount` 分开记
    /// 两者都是"提醒没响"，但**根因与处置完全不同**：
    /// · `suppressedCount` = 系统**没授权** ⇒ 处置是去系统设置里开通知；
    /// · `skippedNoQuote`  = **没取到行情**（断网 / 限流 / 该票当天无数据）⇒ 处置是看网络或数据源状态。
    /// 混用一个计数器会让用户按错误提示去改系统设置、白折腾。
    ///
    /// ## 语义
    /// **是"最近一轮"的值，不是累计** —— 每一轮 tick 都会被覆盖（用户关心的是「此刻还有没有在漏」）。
    private var _skippedNoQuote = 0
    var skippedNoQuote: Int { _skippedNoQuote }

    /// 记「本轮因缺行情未判定的票数」。由 `AlertMonitor.tick` 每轮调用。
    /// - Parameter n: 本轮 `rulesByCode` 里没拿到行情的代码数（0 = 本轮全部判定到了）。
    func recordSkippedNoQuote(_ n: Int) {
        _skippedNoQuote = max(0, n)
    }

    private override init() {
        super.init()
        // 注册 delegate：前台时通知也展示（默认前台被系统吞掉），并确保图标/样式走标准链路
        UNUserNotificationCenter.current().delegate = self
        // ⚠ **不在这里 `requestAuth()`**：唯一入口在启动流程那一处（显式、可 grep；两处都写等于没人知道哪处是权威）。
        // ⚠ 用户在系统设置里**中途**改通知权限后 `authState` 会陈旧（「先拒后开」通知一直被拦、
        //   「先开后关」投递被系统静默吞掉）⇒ 回到前台时复查一次（不做轮询）。
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshAuthFromSystem() }
        }
    }

    /// 前台运行时也弹出横幅（app 在最前面时默认不展示，必须走 willPresent 回调）
    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// 点击横幅 / 通知中心里的条目 → 把 App 带到前台并**跳到该通知所属页面**。
    ///
    /// ⚠ 为什么必须实现（2026-10-16 审查 B6）：此前全项目只有 `willPresent`，
    ///   `didReceive response:` 一处都没有 ⇒ 点通知只等于"把 App 叫到前台"，
    ///   停在用户上次看的那页；正文写着「第三轮完成」，他还得自己点侧栏去找结果页。
    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let raw = response.notification.request.content.userInfo["page"]
        // `userInfo` 经系统归档后字符串可能是 NSString，两种都要认
        let page = (raw as? String) ?? ((raw as? NSString) as String?)
        let rawSection = response.notification.request.content.userInfo["section"]
        let section = (rawSection as? String) ?? ((rawSection as? NSString) as String?)
        let rawDate = response.notification.request.content.userInfo["date"]
        let date = (rawDate as? String) ?? ((rawDate as? NSString) as String?)
        Task { @MainActor in
            if let page, let target = Page(rawValue: page) { Page.select(target) }
            // 报告所属选股日：预判/验证/复盘挂在**选股日**下（T+1 产出），
            // 不带日期落地会停在「今天」的空态上（通知说就绪、页面说没生成）。
            if let date { Store.shared.jump(toDate: date) }
            // 页内那一格：必须在**选页之后**发请求 —— 跨页进来时结果页是新建的，
            // 它的 `leg` 初值就读这个标志（同页时由 `onChange` 接），早一步置位也只是没人看。
            switch NotifySection(rawValue: section ?? "") {
            case .compare: Store.shared.requestCompareLeg()
            case nil:      break
            }
            // 主窗口在的常态下就是"揭开并置前"；不在（用户从没开过）时退化成激活 App，
            // 由用户自己从菜单栏开 —— 通知不该擅自开新窗口（单窗口策略）
            if !focusExistingMainWindow() { NSApp.activate(ignoringOtherApps: true) }
        }

        completionHandler()
    }

    /// 请求通知授权。**唯一调用点是 `SelectedApp.applicationDidFinishLaunching`。**
    public func requestAuth() {

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] ok, _ in
            Task { @MainActor in self?.resolveAuth(granted: ok) }
        }
    }

    /// 授权裁决落地：记状态 + 处理裁决前排队的通知。
    ///
    /// ⚠ **裁决前的通知不能丢** —— 授权成功就**补发**，被拒就**记下条数**
    ///   （供设置页说"有 N 条提醒未送达"，而不是让用户以为"没发生"）。
    private func resolveAuth(granted: Bool) {
        authState = granted
        let queued = pending
        pending = []
        if granted {
            for q in queued {
                deliver(title: q.title, body: q.body, identifier: q.identifier, userInfo: q.userInfo)
            }
        } else {

            suppressedCount += queued.count
            lastSuppressed = queued.last?.title ?? lastSuppressed
        }
    }

    /// 回到前台时**复查**系统授权状态。
    ///
    /// 为什么需要：用户可以在系统设置里中途改动授权 ——「先拒后开」会让后续通知一直被当
    /// "已拒绝"拦下（只计数不投递）；「先开后关」会让投递被系统静默吞掉（没有任何痕迹）。
    /// ⚠ 只在 `didBecomeActive` 查（不在任何 tick 里轮询）：系统设置的变更只可能发生在用户离开本 App 期间。
    /// ⚠ 状态映射走 `NotifyPolicy.grantedFromStatusRaw`（Core 纯函数，有单测）——
    ///   `SelectedCore` 不许 import `UserNotifications`，故以 rawValue 为接口。
    private func refreshAuthFromSystem() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let granted = NotifyPolicy.grantedFromStatusRaw(settings.authorizationStatus.rawValue)
            Task { @MainActor in
                guard let self, let granted else { return }     // nil = 仍未裁决，保持三态
                guard self.authState != granted else { return } // 无变化不动作（避免重复补发）
                self.resolveAuth(granted: granted)
            }
        }
    }

    /// 是否已获授权。⚠ 语义：**只有明确 `true` 才算已授权**（未裁决 = `false`）。
    /// ⚠ 设置页**不读它** —— 那边每次向系统查 `notificationSettings()`（唯一"当前真相"）；
    ///   这里只服务于"要不要排队/补发"，回前台时会随系统设置复查刷新（`refreshAuthFromSystem`）。
    public var isAuthorized: Bool { authState == true }

    /// 发送通知。
    ///
    /// - Parameter identifier: 稳定的去重键（默认用标题）——**同一 identifier 的请求会被系统替换**，
    ///   即"同一任务只留最新一条"（用随机 id 会让反复提醒在通知中心堆成一串）。
    ///
    /// ⚠ 三种授权状态下的行为**不同**：
    ///   · **未裁决** → **排队等裁决**（裁决一到就补发，不能当成"已拒绝"丢）
    ///   · **已拒绝** → 记 `suppressedCount` / `lastSuppressed`（不静默，设置页可提示）
    ///   · **已授权** → 直接投递
    ///
    /// - Parameter page: 点击这条通知后要跳去的页面（`Page.rawValue`）。
    ///   带上它，通知才是**入口**而不只是"有一条新消息"（审查 B6：
    ///   原先正文写着「第三轮完成」，点下去只把 App 叫到前台、停在用户上次看的那页）。
    /// - Parameter section: 页内段落标记（`NotifySection.rawValue`）—— 页面合并后"跳到哪页"
    ///   不再等于"看到哪一段"，落点要一路指到段（见 `NotifySection`）。
    /// - Parameter date: 报告所属日期（yyyy-MM-dd）—— 落地时定位到该日，
    ///   否则预判/复盘这类 T+1 产出的通知会落在「今天」的空态上。
    public func send(title: String, body: String, identifier: String? = nil,
                     page: String? = nil, section: String? = nil, date: String? = nil) {
        let id = identifier ?? "selected.\(title)"
        var info: [String: String] = [:]
        if let page { info["page"] = page }
        if let section { info["section"] = section }
        if let date { info["date"] = date }
        // ⚠ 裁决逻辑收敛到 `NotifyPolicy`（Core 纯函数，可单测）；本处只执行裁决出来的副作用。
        switch NotifyPolicy.decide(authorized: authState,
                                   pendingCount: pending.count,
                                   limit: Self.pendingLimit) {
        case .enqueue:
            pending.append((title, body, id, info))

            pending = Array(pending.suffix(Self.pendingLimit))   // 超限丢最早
        case .suppress:
            suppressedCount += 1
            lastSuppressed = title
        case .deliver:
            deliver(title: title, body: body, identifier: id, userInfo: info)

        }
    }

    /// 真正投递给系统（**只应由 `send` / `resolveAuth` 调**）
    private func deliver(title: String, body: String, identifier: String,
                         userInfo: [String: String] = [:]) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // 点击跳页的路由信息。⚠ 值只能是 plist 可编码类型（`userInfo` 要走系统归档），
        // 所以这里统一用字符串，不放 Int/枚举。
        if !userInfo.isEmpty { content.userInfo = userInfo }


        // 左侧应用图标由系统按 LaunchServices 注册自动显示（build_app.sh --install 已注册），不需要手动加附件。

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
