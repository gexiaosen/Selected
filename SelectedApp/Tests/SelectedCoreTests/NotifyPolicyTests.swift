import Testing
@testable import SelectedCore

/// 通知三态裁决：`Notifier` 裁决逻辑（在 Core）的单测。
/// 防的回归：`nil`（未裁决）被当成"已拒绝"→ 启动瞬间通知静默丢失。
struct NotifyPolicyTests {

    @Test("未裁决 → 排队（未超限不裁剪）")
    func undecidedEnqueues() {
        #expect(NotifyPolicy.decide(authorized: nil, pendingCount: 0, limit: 8)
            == .enqueue(trimmed: false))
    }

    @Test("未裁决且队列已满 → 排队并裁剪（丢最早一条）")
    func undecidedTrimsAtLimit() {
        #expect(NotifyPolicy.decide(authorized: nil, pendingCount: 8, limit: 8)
            == .enqueue(trimmed: true))
        #expect(NotifyPolicy.decide(authorized: nil, pendingCount: 9, limit: 8)
            == .enqueue(trimmed: true))
    }

    @Test("已拒绝 → 抑制（不投递、不排队）")
    func rejectedSuppresses() {
        #expect(NotifyPolicy.decide(authorized: false, pendingCount: 3, limit: 8)
            == .suppress)
    }

    @Test("已授权 → 直接投递")
    func grantedDelivers() {
        #expect(NotifyPolicy.decide(authorized: true, pendingCount: 3, limit: 8)
            == .deliver)
    }

    @Test("队列裁剪：超过上限截断，未超过原样")
    func trimmedClamps() {
        #expect(NotifyPolicy.trimmed(count: 10, limit: 8) == 8)
        #expect(NotifyPolicy.trimmed(count: 3, limit: 8) == 3)
        #expect(NotifyPolicy.trimmed(count: 8, limit: 8) == 8)
    }

    /// 回前台复查系统授权状态（`Notifier.refreshAuthFromSystem`）用的映射。
    /// 防的回归：用户在系统设置里"先拒后开"后，App 仍把通知当"已拒绝"拦下（直到重启）。
    @Test("系统授权状态 rawValue → 三态裁决",
          arguments: [(0, Bool?.none), (1, Bool?.some(false)), (2, Bool?.some(true)),
                      (3, Bool?.some(true)), (4, Bool?.some(true)),
                      (9, Bool?.none), (-1, Bool?.none)])
    func grantedFromStatusRaw(raw: Int, expected: Bool?) {
        #expect(NotifyPolicy.grantedFromStatusRaw(raw) == expected)
    }
}
