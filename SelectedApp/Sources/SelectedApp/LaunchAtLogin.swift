import Foundation
import ServiceManagement

/// 开机自启（`SMAppService` 主应用登录项）。
///
/// ## ⚠ 为什么这件事在本 App 里不是"锦上添花"
/// 本 App 的全部自动化都跑在**进程内定时器**上（`Scheduler` 的单次定时器 +
/// `NSWorkspace.didWakeNotification` 补偿），而窗口策略又是"关窗不退出"
/// （`applicationShouldTerminateAfterLastWindowClosed → false`）。
/// 于是**重启/换机后它不会自己回来**：
/// · 09:30 预判、14:00/14:30/14:50 三轮、15:05 复盘…… 整天一个都不跑；
/// · 而且因为进程压根没运行，**连"超窗未执行"的记录与通知都不会产生**
///   （那是活着的调度器才会写的 `missed` 状态）—— 用户第二天看到的只是
///   "昨天怎么什么都没有"，没有任何一处说明"因为 App 没在跑"。
/// · `LimitUpPoolJob` / `LhbJob` 的注释里已经按"周五晚上没开机、周一补上"
///   设计了回看逻辑，说明登录即启动本就是产品预期。
///
/// ## 状态语义
/// `SMAppService.mainApp.status` 才是真相（用户可以在「系统设置 › 通用 › 登录项」
/// 里改），所以 `isEnabled` 每次现读、不缓存 —— 与 `Notifier` 查
/// `notificationSettings()` 而不是读自己上次记的 flag 是同一条纪律。
public enum LaunchAtLogin {

    /// 是否可用。从 `swift build` 的裸可执行文件（非 `.app` 包）跑时会不支持，
    /// 这时界面上必须说"不可用"，而不是让开关点了没反应。
    public static var isAvailable: Bool {
        // 只有被 LaunchServices 正常登记的 bundle 才有登录项可言
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")
    }

    /// 当前是否已登记为登录项（现读系统真相）。
    public static var isEnabled: Bool {
        guard isAvailable else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    /// 开/关登录项。返回 `nil` = 成功；非 `nil` = 给用户的可读原因。
    ///
    /// ⚠ 不抛错而返回文案：这是一次"改了就该立刻看见结果"的开关，
    ///   调用方（设置页）要把原因直接摊在行旁边，而不是弹一个只有"失败"的框。
    public static func setEnabled(_ on: Bool) -> String? {
        guard isAvailable else {
            return "当前不是以 .app 方式运行，登录项无法登记（请用打包后的 Selected.app）"
        }
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch let e as NSError {
            // 带上 domain/code：这类失败只有系统知道原因（未签名、Bundle 被移动过等）
            return "登录项设置失败（\(e.domain) \(e.code)）：\(e.localizedDescription)"
        }
    }
}
