import AppKit
import Observation
import Sparkle

// 自动更新中枢：Sparkle 2 + 静默红点策略（与 MiscKit 同一套交互）。
//
// 分工：
//   · 每日静默检查（Sparkle 默认 24h 调度）→ 发现新版不弹窗，只点亮侧栏设置的「关于」红点；
//   · 手动检查（应用菜单 /「关于」页按钮）→ 弹 Sparkle 标准更新窗（release notes、安装按钮）。
//
// 为什么 Apple Development / ad-hoc 分发也敢用 Sparkle：Sparkle 2 的更新校验是
// 「EdDSA 有效 *或* 新旧包 Apple 签名一致」二选一（SUUpdateValidator 源码），
// 官方报错文案明确写着 "adhoc signing can be used at minimum"。ad-hoc 包的 DR=cdhash
// 每包都变，苹果签名通道必败，但 DMG 用 EdDSA 私钥签名后走 EdDSA 通道即可正常安装。
// 私钥只进 GitHub Secrets，CI 出包不依赖 Apple Developer ID。

/// 安装前校验的分流：手动弹标准窗，静默只标红点。
///
/// ⚠ 静默路径必须 reply `.dismiss` 而不是 `.skip`：`.skip` 会把该版本记进
/// SPUSkippedUpdate，而这条记录**只作用于后台静默渠道**（SUAppcastDriver 仅在
/// background 检查时过滤被跳过的版本）——一旦静默发现也回 skip，红点从此
/// 看不到这个版本。`.dismiss` 只结束本次会话，什么都不记，下轮静默仍能发现。
@MainActor
final class QuietUserDriver: SPUStandardUserDriver {
    override func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        if state.userInitiated {
            super.showUpdateFound(with: appcastItem, state: state, reply: reply)
        } else {
            UpdateCenter.shared.noteAvailable(appcastItem.displayVersionString)
            reply(.dismiss)
        }
    }
}

/// 跳过 Sparkle 首次启动的"允许自动检查更新吗"授权弹窗：
/// 静默每日检查是本项目既定行为，不再打扰用户；系统档案默认不发送（不实现
/// feedParametersForUpdater 即为空）。留 delegate 便于以后按需覆写。
@MainActor
private final class UpdateDelegate: NSObject, SPUUpdaterDelegate {
    static let shared = UpdateDelegate()

    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool {
        false
    }
}

@MainActor
@Observable
final class UpdateCenter {
    static let shared = UpdateCenter()

    /// 静默检查发现的新版本号；nil = 无红点。侧栏齿轮与「关于」页共用。
    private(set) var availableVersion: String?

    let updater: SPUUpdater

    private init() {
        updater = SPUUpdater(
            hostBundle: .main,
            applicationBundle: .main,
            userDriver: QuietUserDriver(hostBundle: .main, delegate: nil),
            delegate: UpdateDelegate.shared
        )
    }

    /// AppDelegate 在 `applicationDidFinishLaunching` 里调用；
    /// Sparkle 约定 updater 不能在启动完成前 start（菜单/绑定尚未就绪）。
    func start() {
        do {
            try updater.start()
        } catch {
            // 更新能力失效不影响主功能：记日志即可，绝不让启动路径因更新挂掉。
            NSLog("[ERROR] [Selected] update.startFailed: \(String(describing: error))")
        }
    }

    /// 手动检查（应用菜单 /「关于」页按钮）：红点先清，结果交给 Sparkle 标准窗口。
    func checkForUpdates() {
        availableVersion = nil
        updater.checkForUpdates()
    }

    func noteAvailable(_ version: String) {
        availableVersion = version
        NSLog("[NOTICE] [Selected] update.available: \(version)")
    }
}
