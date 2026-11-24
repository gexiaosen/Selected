import SwiftUI
import SelectedCore

// MARK: - 个股档案

/// 「个股档案」卡片：两份**低频刷新的公开数据** —— 指数成份 + 基本面。
///
/// ## 为什么合成一张卡
/// 两者性质相同（都是"某只票的静态属性"、都只服务详情页、都只展示不进筛选、
/// 都是**季度级**变化 → 都用手动刷新），合成一张更好找。
///
/// ⚠ 但**刷新按钮分开**：成本差一个数量级（指数 **9 个请求** / 基本面 **56**）——
/// 合成一个按钮会让"只想刷新指数"的用户被迫等几十个请求。
///
/// ⚠ 基本面与板块热度虽然**共用同一条接口**（东财 `clist`，只是 `fs=` 不同），但**有意各自独立刷新**：
/// 两个数据集要能独立演进。见 `docs/specs/README.md` 决策 3。
///
/// ## ⚠ 概念**不做**
/// 成本高 1~2 个数量级（504 个概念板块 / 5000 个按票请求），且**概念成份每周都在变**
/// → 用当前清单回放历史 = **前视偏差**。完整论证见 `docs/specs/README.md`。
///
/// ## 版式
/// 两列各自成块（标题 → 覆盖 → 最近刷新 →（弹性）→ 按钮），说明文字收进 ⓘ 图标按需展开，
/// 刷新进度/结果统一走 Toast（卡片内不再重复显示报告）。
/// 覆盖信息之后、`Spacer` 之前由弹性空间吃掉高度差异 ⇒ 两列底部的按钮永远横向对齐。
extension SettingsView {

    var profileCard: some View {
        Card("个股档案", subtitle: "指数成份 / 基本面 —— 只做详情页展示，不进筛选") {
            // `spacing: 0` + 每块自带左右内边距：竖分隔线正好落在两块中间
            HStack(alignment: .top, spacing: 0) {
                datasetRegion(title: "指数成份",
                              value: store.indexMemberCounts.isEmpty
                                  ? "尚未抓取" : store.indexMemberCountsText,
                              note: store.indexMembersLastFetched.map { shortStamp($0) },
                              info: Self.indexMembersInfo,
                              busy: store.indexMembersRefreshing
                                  || store.busy.contains("indexMembers"),
                              first: true) { store.refreshIndexMembers() }
                datasetRegion(title: "基本面",
                              value: store.fundamentalCoverageText,
                              note: store.fundamentalLastFetched.map { shortStamp($0) },
                              info: Self.fundamentalInfo,
                              busy: store.fundamentalRefreshing
                                  || store.busy.contains("fundamental"),
                              first: false) { store.refreshFundamentals() }
            }
        }
    }

    // MARK: 版式零件

    /// 两块里的**一块**：标题 + ⓘ → 覆盖数字 → 最近刷新 →（弹性）→ 按钮
    ///
    /// ⚠ `.frame(maxHeight: .infinity)` 让两块**等高**：内容更高的那块决定整体高度，
    ///   另一块把多出来的空间吃掉 ⇒ 两块底部的按钮自然横向对齐。
    private func datasetRegion(title: String, value: String, note: String?, info: String,
                               busy: Bool, first: Bool,
                               action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text(title).font(.callout.bold())
                InfoTip(text: info, title: title)
            }
            Text(value)
                .font(.caption.monospacedDigit())
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            if let note {
                Text(note).font(.caption).foregroundStyle(.secondary).padding(.top, 2)
            }
            // ⚠ **卡上不显示"刷新报告"** —— 同一件事不说两遍（卡上一行小字 + 一条 toast），
            //   而卡上那行**不会自己消失**（只在"下一次刷新开始"时才清），
            //   两个数据集同时失败还会显示两行一模一样的文案。
            //   ⇒ 摘要只由 toast 说；卡上留**最近刷新时间**当参考（失败时它停在"上次成功"的时刻，
            //     所以"时间没往前走"本身就是"这次没刷上"的信号）。
            Spacer(minLength: 10)
            // 按钮**在块内左对齐**、固定宽度（转圈图标出现/消失都不推动它）
            //
            // ⚠ 这一块里**所有内容都是左对齐的**（标题 / ⓘ / 覆盖数字 / 时间），
            //   按钮也左对齐才与上面文字成**一整列**；三个按钮等宽（minWidth 112）⇒ 左边缘全齐。
            Button(action: action) {
                HStack(spacing: 6) {
                    if busy { ProgressView().controlSize(.mini) }
                    Text(refreshLabel(title)).lineLimit(1)
                }
                .frame(minWidth: 112)
            }
            .btnPrimary()
            .disabled(busy)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, first ? 0 : 14)
        .padding(.trailing, first ? 14 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // 竖分隔线：画在自己这一块的**左缘**（第一块不画）
        .overlay(alignment: .leading) {
            if !first {
                Rectangle().fill(.quaternary).frame(width: 0.5)
            }
        }
    }

    /// `2026-09-24 09:48:48` → `09-24 09:48`（三列并排时完整时间戳太长；"最近刷新"不需要年份与秒）
    ///
    /// ⚠ 纯字符串切：`PhaseStore.nowStamp()` 的格式是固定的 `yyyy-MM-dd HH:mm:ss`
    ///   （`en_US_POSIX`，不是本地化格式）⇒ 切 `[5..<16]` 就得到 `MM-dd HH:mm`。
    ///   长度不够就原样返回（宁可显示得难看，也不要显示成错的时间）。
    private func shortStamp(_ s: String) -> String {
        guard s.count >= 16 else { return s }
        let a = s.index(s.startIndex, offsetBy: 5)
        let b = s.index(s.startIndex, offsetBy: 16)
        return String(s[a..<b])
    }

    /// 两块的按钮文案（与标题同源 —— 标题改了这里必须跟着改，所以收成一个 switch）
    private func refreshLabel(_ title: String) -> String {
        switch title {
        case "指数成份": return "刷新指数成份"
        default:        return "刷新基本面"
        }
    }

    // MARK: 两段说明（在 ⓘ 图标里展示）

    /// ⚠ 这些是给用户看的**普通字符串**，不是 Markdown —— **不要写 `**`**
    /// （护栏 `md_literal` 盯的就是这一类：星号会原样显示给用户）。
    static let indexMembersInfo = """
    来自新浪指数与板块成份接口，
    沪深300 / 中证500 / 上证50 三个指数共 9 个请求（约几秒）。
    ⚠ 某个指数抓不到、或返回空数组时，那个指数会被拦下并保留旧数据 ——
    部分失败是正常的，不会用一份残缺的表覆盖。
    """

    static let fundamentalInfo = """
    来自东方财富财务接口。
    全市场约 5600 只，刷新一次约 56 个请求（几十秒）。
    ⚠ 「慢变量」—— 与「次日午前」的时间尺度不匹配，所以只展示、不进评分、不进筛选。
    ⚠ 仅展示可校验的五组指标：第六组「股本股东」的源字段校验不稳定，暂未纳入。
    ⚠ 数据源以「-」表示「没有」，界面显示成「—」而不是 0
    （「资产负债率 0%」是「无负债」，与「没数据」是完全不同的结论）。
    ⚠ 「刷新了 N 只」与「其中 N 只有数据」是两件事 —— 退市 / 停牌票会返回空值。
    """
}
