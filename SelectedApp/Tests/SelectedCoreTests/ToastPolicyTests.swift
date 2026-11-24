import Testing
@testable import SelectedCore

/// 提示收尾口径 —— 时长 / 钉住 / 淘汰 / 横幅白名单。
///
/// 这些判据是纯函数（在 Core），改错了会有测试变红；这里钉死。
@Suite("ToastPolicy 三档收尾口径")
struct ToastPolicyTests {

    @Test("三档时长：success 2.0 / info+warning 3.5 / error 钉住 / loading 兜底")
    func lifetimes() {
        #expect(ToastPolicy.autoDismissSeconds(.success) == 2.0)
        #expect(ToastPolicy.autoDismissSeconds(.info) == 3.5)
        #expect(ToastPolicy.autoDismissSeconds(.warning) == 3.5)
        #expect(ToastPolicy.autoDismissSeconds(.error) == nil, "告警类不自动消失")
        #expect(ToastPolicy.autoDismissSeconds(.loading) == 300)
    }

    @Test("isPinned 只有 error 为真")
    func pinned() {
        #expect(!ToastPolicy.isPinned(.success))
        #expect(!ToastPolicy.isPinned(.info))
        #expect(!ToastPolicy.isPinned(.warning), "warning 是中性提醒，仍自动消失")
        #expect(ToastPolicy.isPinned(.error))
        #expect(!ToastPolicy.isPinned(.loading))
    }

    @Test("未超过上限不淘汰（=3 也不动，>3 才挤）")
    func noEvictionAtOrBelowCap() {
        #expect(ToastPolicy.evictionIndex(pinned: []) == nil)
        #expect(ToastPolicy.evictionIndex(pinned: [false]) == nil)
        #expect(ToastPolicy.evictionIndex(pinned: [false, false, false]) == nil,
                "刚好 3 条 = 没超限 → 不淘汰（`>=` 会让 while 循环连删两条）")
    }

    /// 淘汰方向必须"挤最旧"：列表 index 0 是**最新**一条，
    /// 若误用 firstIndex 会把刚出现的 toast 挤掉、留下三条旧的。
    @Test("超限挤最旧的非钉住条，不挤最新")
    func evictsOldestNotNewest() {
        // [新, 中, 旧, 更旧] 全非钉住 → 淘汰 index 3（最旧）
        #expect(ToastPolicy.evictionIndex(pinned: [false, false, false, false]) == 3)
        // 最新一条是钉住的 error → 仍淘汰最旧（index 3），不碰钉住的
        #expect(ToastPolicy.evictionIndex(pinned: [true, false, false, false]) == 3)
        // 钉住的排在最旧位 → 跳过它，淘汰 index 2
        #expect(ToastPolicy.evictionIndex(pinned: [false, false, false, true]) == 2)
    }

    /// 全是钉住条目时返回 nil（宁可临时超一条）——
    /// 否则"不自动消失"形同虚设：下一条 toast 一来告警就被挤没了。
    @Test("全钉住时不淘汰（允许临时超限）")
    func allPinnedReturnsNil() {
        #expect(ToastPolicy.evictionIndex(pinned: [true, true, true]) == nil)
        #expect(ToastPolicy.evictionIndex(pinned: [true, true, true, true]) == nil)
    }

    @Test("横幅白名单：只有库级故障能上横幅")
    func bannerWhitelist() {
        #expect(ToastPolicy.allowsBanner(key: "dbBootstrap"))
        #expect(ToastPolicy.allowsBanner(key: "dbIntegrity"))
        // 其余全部不许上横幅（含用户截图那条 boardheat，与所有写操作 key）
        #expect(!ToastPolicy.allowsBanner(key: "boardheat"))
        #expect(!ToastPolicy.allowsBanner(key: "round"))
        #expect(!ToastPolicy.allowsBanner(key: "param"))
        #expect(!ToastPolicy.allowsBanner(key: "tune"))
        #expect(!ToastPolicy.allowsBanner(key: "scheduler"))
        #expect(!ToastPolicy.allowsBanner(key: nil), "没写 key 也不许上横幅")
        #expect(!ToastPolicy.allowsBanner(key: ""), "空串不是合法 key")
    }

    @Test("白名单只有两条（加档要过老板）")
    func whitelistSize() {
        #expect(ToastPolicy.bannerOnlyKeys == ["dbBootstrap", "dbIntegrity"])
    }
}
