import Foundation

/// 通知投递的**三态裁决**（从 App 层 `Notifier` 抽出，纯计算进 Core 以便被单测钉住）。
///
/// 裁决只依赖 `Bool?` 与计数，**无 UI / 系统依赖** → 放 Core 合法
/// （`CoreLayeringTests` 只禁 import UI 框架，纯函数不受限）。
///
/// ⚠ 标 `public`：App 层按普通依赖 import Core，`internal` 符号不可见（非测试目标）。
public enum NotifyPolicy {

    /// 裁决结果（**无副作用**的描述）
    public enum Decision: Equatable {
        /// 授权未裁决 → 排队；`trimmed` = 队列已到上限、本次会挤掉最早一条
        case enqueue(trimmed: Bool)
        /// 已拒绝授权 → 记抑制（不投递，供设置页提示"有提醒未送达"）
        case suppress
        /// 已授权 → 直接投递
        case deliver
    }

    /// 三态授权 → 动作。
    ///
    /// ⚠ 三态语义：`nil` = **还没裁决** —— 必须排队等裁决，
    /// 把它当成"已拒绝"会导致启动瞬间通知静默丢失。
    public static func decide(authorized: Bool?, pendingCount: Int, limit: Int) -> Decision {
        switch authorized {
        case .none:
            return .enqueue(trimmed: pendingCount >= limit)
        case .some(false):
            return .suppress
        case .some(true):
            return .deliver
        }
    }

    /// 排队后裁剪到上限（`limit` 条；丢弃最早入队的）。
    /// `count <= limit` 原样返回 —— 纯函数，队列长度的唯一口径。
    public static func trimmed(count: Int, limit: Int) -> Int {
        min(count, limit)
    }

    /// 系统授权状态 → 三态裁决（**接口是 `UNAuthorizationStatus.rawValue`**）。
    ///
    /// 用途：回前台时复查系统设置 —— 用户中途改权限后 `Notifier.authState` 会陈旧：
    /// "先拒后开"⇒ 通知一直被拦；"先开后关"⇒ 投递被系统静默吞。
    ///
    /// ⚠ 收 `Int` 而非 `UNAuthorizationStatus`：`SelectedCore` 不许 import
    ///   `UserNotifications`（`CoreLayeringTests` 钉死）⇒ rawValue 是唯一能过界的形态。
    ///
    /// 映射（与 `UNAuthorizationStatus` 的 raw 值一一对应）：
    /// · `notDetermined`(0) → `nil` —— **仍未裁决**，保持三态语义（继续排队等裁决）；
    /// · `denied`(1) → `false`；
    /// · `authorized`(2) / `provisional`(3) / `ephemeral`(4) → `true`
    ///   （provisional = 静默投递，对"能否投递"而言等同已授权）；
    /// · **未知值 → `nil`**（未来系统新增枚举）—— 不猜，宁可保持原状。
    public static func grantedFromStatusRaw(_ raw: Int) -> Bool? {
        switch raw {
        case 1: return false
        case 2, 3, 4: return true
        default: return nil
        }
    }
}
