import Foundation

/// 提示（Toast / 横幅）的**收尾口径** —— 纯函数，可被 `swift test` 覆盖。
///
/// ## 为什么放 Core
/// 与 `RoundOrder` / `NotifyPolicy` 同一条纪律：会出错的**判据**（哪一档多久、谁钉住、
/// 谁不许被挤掉、哪条才允许上横幅）必须是纯函数，否则它只能活在视图里、
/// 改错了没有任何测试会变红。
///
/// ## 三档口径
///
/// | 档 | 语义 | 收尾 |
/// |----|------|------|
/// | `success` | 通过 / 正常 | **2.0s** 自动消失 |
/// | `info` / `warning` | 中性提醒 | **3.5s** 自动消失 |
/// | `error` | 告警 / 警报 | **不自动消失**，点窗口任意处才走 |
/// | `loading` | 长任务占位 | 300s **异常兜底**（正常由同 key 的完成条原位替换） |
///
/// ⚠ `error` 钉住**有意不带 × 按钮**（项目既定：toast 不放关闭按钮）：
/// 收尾方式是"点别处即走"，而不是多一个必须瞄准的控件。
public enum ToastPolicy {

    /// 该档的自动消失秒数；`nil` = **钉住**（只能靠用户点击/新提示收尾）
    public static func autoDismissSeconds(_ style: ToastStyle) -> Double? {
        switch style {
        case .success:          return 2.0
        case .info, .warning:   return 3.5
        case .error:            return nil          // 告警类：不自动消失
        case .loading:          return 300          // 兜底，正常路径由同 key 替换
        }
    }

    /// 是否钉住（不自动消失）
    public static func isPinned(_ style: ToastStyle) -> Bool { autoDismissSeconds(style) == nil }

    /// 同屏最多几条（钉住的 error 优先保留，超出时先淘汰**非钉住**的最旧一条）
    public static let maxVisible = 3

    /// 淘汰判定：新一条进来、已到达上限时，**该淘汰哪一条的下标**。
    ///
    /// ⚠ 钉住的 error **不参与淘汰** —— 否则"不自动消失"形同虚设（下一条 toast 一来它就没了）。
    /// ⚠ 淘汰方向是**最旧的非钉住条**（列表尾部 = 旧；`lastIndex`）——
    ///   用 `firstIndex` 会先挤掉刚出现的那条（新条目在 index 0），语义相反。
    /// ⚠ 判据是 `> maxVisible` 而不是 `>=`：调用方是 `while` 循环，`>=` 会在
    ///   插入第 4 条后**连删两条**（4→3→2，过度淘汰）。
    /// - Returns: 可淘汰的下标；未超限或全是钉住条目时返回 `nil`
    ///   （全钉住时宁可临时超一条，也不静默吞掉告警）
    public static func evictionIndex(pinned: [Bool]) -> Int? {
        guard pinned.count > maxVisible else { return nil }
        return pinned.lastIndex(of: false)
    }

    // MARK: - 页顶横幅白名单

    /// **只有这两个 key 允许上页顶横幅**（其余一律走 toast）。
    ///
    /// 理由：库是唯一不可再生资产。`dbBootstrap`（建库/schema 迁移失败）与
    /// `dbIntegrity`（库损坏）是"必须持续可见、且要给出恢复线索"的故障 ——
    /// toast 飘走等于用户失去线索，所以这一条**有意保留持久横幅**。
    /// 其余写操作的失败都是**一次性事件**，持久横幅会造成"切到别的日期还挂着旧报错"的困扰。
    public static let bannerOnlyKeys: Set<String> = ["dbBootstrap", "dbIntegrity"]

    /// 该 `lastErrorKey` 是否允许渲染页顶横幅
    public static func allowsBanner(key: String?) -> Bool {
        guard let key else { return false }
        return bannerOnlyKeys.contains(key)
    }
}

/// 提示档位（App 层 `ToastCenter.Style` 的镜像；放 Core 是为了让纯函数可测）。
/// ⚠ 改名/加档必须与 `ToastCenter.Style` 同步（`toast_styled` 护栏钉着五档声明）。
public enum ToastStyle: String, CaseIterable, Sendable {
    case success, info, warning, error, loading
}
