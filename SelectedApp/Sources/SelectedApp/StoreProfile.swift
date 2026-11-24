import Foundation
import SwiftUI
import Observation
import SelectedCore

/// 指数成份（沪深300 / 中证500 / 上证50）的界面状态与动作。
///
/// ## ⚠ 为什么是**手动刷新**而不是启动时自动抓
/// 一次刷新是 **9 个请求**（300+500+50，每页上限 100）。指数成份是**季度级**变化的公开数据，
/// 挂在启动路径上等于每天多打 9 次请求去取一份几乎不变的表。
/// 「证券主列表」不同：那个**每天**都可能变（新股上市），所以有 TTL + 自动刷新。
///
/// ## 口径
/// 只用于**详情页的身份徽章**，不进筛选、不进评分。
/// ⚠ 「只做权重股」开关**不做**：那要进 `hard_filter` 或画像，属"改筛选口径"，需先有回测依据。
extension Store {

    /// 各指数的成份数（`index_code → 只数`）
    var indexMemberCountsText: String {
        IndexMembers.indices.map { idx in
            "\(idx.name) \(indexMemberCounts[idx.code] ?? 0) 只"
        }.joined(separator: " · ")
    }

    /// 最近一次刷新时间（取三者里最新的；都没刷过 → nil）
    var indexMembersLastFetched: String? {
        indexMembersFetchedAt.values.max()
    }

    /// 重新抓取三个指数的成份并整表替换。
    ///
    /// ⚠ **部分失败是正常的、也是安全的**：数量低于下界（`Index.minCount`）的指数
    /// **不写库、保留旧数据** —— 因为 `IndexMembersSource.fetch` 对"抓取失败"与
    /// "这个指数没有成份"都返回 `[]`（它分不清），而节点名写错时新浪就是返回空数组。
    /// 拿 `[]` 覆盖会让徽章**静默消失**，比不刷新更糟。
    ///
    /// ## ⚠ 失败**不写全局错误横幅**
    /// 两项档案数据（指数成份 / 基本面）都**只在设置页由用户手动点按钮**触发；
    /// 手动、就地的动作**只留浮层提示（toast）**，全局横幅留给**后台 / 调度 / 数据库**
    /// 这类用户看不到来源的失败（横幅是全局的，会跟着用户切到别的页面）。
    /// 同理**不要顺手清空** `lastError` —— 那会把一条无关的严重错误（如数据库初始化失败）静默抹掉。
    ///
    /// ## ⚠ 结果摘要**只留 toast 一处**，卡上显示"最近刷新时间"
    /// ⚠ "失败原因"只活在 toast 的几秒里 —— 但**卡上的时间会停在"上次成功"那一刻**，
    ///   所以"时间没往前走"本身就是"这次没刷上"的信号（这是这个取舍成立的前提）。
    func refreshIndexMembers() {
        let key = "indexMembers"
        guard !busy.contains(key) else { return }
        busy.insert(key)
        indexMembersRefreshing = true
        // ⚠ 长任务用 `loading` 档占位，完成时以**同一 key** 替换（不新增第二条）——
        //   卡上的小转圈只在设置页可见；切到别的页面后，全局 toast 是唯一的"还在跑"信号。
        ToastCenter.shared.show("指数成份刷新中…", style: .loading, key: "profile.indexMembers")
        Task.detached(priority: .utility) { [weak self] in
            let report = IndexMembersStore.refresh()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.busy.remove(key)
                self.indexMembersRefreshing = false
                self.loadIndexMemberStats()
                // ⚠ 文案不带括号，数字用 `·` 分隔；"已保留旧数据"是默认行为，不写
                if report.rejected.isEmpty {
                    ToastCenter.shared.show("指数成份已刷新 · \(report.refreshed.count) 个指数",
                                            key: "profile.indexMembers")
                } else {
                    ToastCenter.shared.show("指数成份部分未刷新", style: .warning,
                                            key: "profile.indexMembers")
                }
            }
        }
    }

    /// 读库里的统计（⚠ **只许主线程调** —— 走 `SQLiteReader.shared`）
    func loadIndexMemberStats() {
        indexMemberCounts = IndexMembersStore.counts()
        indexMembersFetchedAt = IndexMembersStore.lastFetched()
    }
}


// MARK: - 基本面

/// 个股基本面（东财 `clist` 的估值 / 每股 / 盈利 / 成长 / 负债五组字段）。
///
/// ## ⚠ 为什么与指数成份分开成两个动作
/// 两者都是"低频刷新的公开分类数据"，但**成本差一个数量级**：
/// 指数成份 **9 个请求**，基本面 **56 个请求**（`pz` 上限 100 是服务端强制的）。
/// 合成一个按钮会让"只想刷新指数"的用户被迫等 56 个请求。
///
/// ## ⚠ 概念**不做**
/// 成本高 1~2 个数量级（504 个概念板块 / 5000 个按票请求），
/// 且**概念成份每周都在变** → 用当前清单回放历史 = **前视偏差**。
/// 完整论证见 `docs/specs/README.md`。
extension Store {

    // MARK: - 基本面

    /// 基本面表的覆盖文案。
    ///
    /// ⚠ **两个数都要显示** —— "5000 只"与"其中 3000 只有数据"是两件事
    /// （源对退市/停牌票返回全 `-`，那些行落库了但没有数据）。
    /// 只显示前者会让用户以为基本面覆盖很全。
    var fundamentalCoverageText: String {
        guard fundamentalStockCount > 0 else { return "尚未抓取" }
        return "\(fundamentalStockCount) 只（\(fundamentalWithData) 只有数据）"
    }

    /// 重新抓全市场基本面并整表替换（**56 个请求**）。
    ///
    /// ⚠ 与指数同一套护栏：抓到不足 `Fundamental.minStocks` 只 → **不写库、保留旧数据**，
    /// 并如实报告（`FundamentalSource.fetchAll` 对"抓取失败"与"真的一只都没有"都返回 nil，分不清）。
    ///
    /// ⚠ 与板块热度**各自独立刷新**（有意）—— 虽然两者在同一个 `clist` 请求族里，
    /// 但两个数据集要能独立演进。
    func refreshFundamentals() {
        let key = "fundamental"
        guard !busy.contains(key) else { return }
        busy.insert(key)
        fundamentalRefreshing = true
        ToastCenter.shared.show("基本面刷新中…", style: .loading, key: "profile.fundamental")
        Task.detached(priority: .utility) { [weak self] in
            let report = FundamentalStore.refresh()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.busy.remove(key)
                self.fundamentalRefreshing = false
                self.loadFundamentalStats()
                if report.rejected == nil {
                    ToastCenter.shared.show("基本面已刷新 · \(report.withData) 只有数据",
                                            key: "profile.fundamental")
                } else {
                    // 疑似限流时给可行动提示（`clist` 族按出口 IP 限流，同一处置）
                    let hint = DataSources.throttleHint(report.rejected).map { " · \($0)" } ?? ""
                    ToastCenter.shared.show("基本面未刷新\(hint)", style: .error,
                                            key: "profile.fundamental")
                }
            }
        }
    }

    /// 读库里的统计（⚠ **只许主线程调** —— 走 `SQLiteReader.shared`）
    func loadFundamentalStats() {
        fundamentalStockCount = FundamentalStore.total()
        fundamentalWithData = FundamentalStore.withDataCount()
        fundamentalLastFetched = FundamentalStore.lastFetched()
    }
}
