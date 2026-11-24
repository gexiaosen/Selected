import SwiftUI
import SelectedCore

/// 设置窗口的**分类**（左分类列表 + 右内容，参照 macOS 系统设置的通行形态）。
///
/// ⚠ 分类只决定**哪几张卡同时出现**，卡片内容一行不动
///   （`Settings{Replay,Alert,Classify,Diag}Section.swift` 各文件）。
///
/// ## 顺带收益（不是动机，但真实）
/// `Card` 的 content 闭包是**饿求值**（`Components.swift` 的 `init`：`self.content = content()`）
/// —— 分页后一次只构造 1~4 张，不必为全部卡片的构造开销买单。
/// ⚠ **`.params` / `.tune` 分类已删除** —— 选股参数的编辑与调优都在主窗口侧栏的
///   「参数中心」（`ParamsCenterView`），单一入口纪律：两处入口必然漂移。默认分类为 `.dashboard`。
///
/// ## 2026-10-27 重排：6 类 → 5 类（按"我来这儿要做什么"分，不按子系统分）
/// · `.dashboard` 显示（原「看板」）· `.schedule` 自动化（原「调度」，任务时刻已从前台撤掉）
/// · `.alerts` 提醒 · `.sources` **数据**（吞掉原「回放」类：自检 / 诊断 / 个股档案 / 历史回放
///   都是"取数与样本"这一件事）· `.about` 关于（只剩身份与求助入口）
/// ⚠ case 名与 rawValue **刻意不改**（`dashboard`/`schedule`/`sources`）—— 存的是 rawValue，
///   改名会让"记住上次分类"失效。只有 `title` 变了。
/// ⚠ 老用户存过的 `"replay"` 是坏值 ⇒ 自动回落第一个分类（与当年删 `.params`/`.tune` 同一处置）。
enum SettingsCategory: String, CaseIterable, Identifiable {
    case dashboard, schedule, alerts, sources, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return "显示"
        case .schedule:  return "自动化"
        case .alerts:    return "提醒"
        case .sources:   return "数据"
        case .about:     return "关于"
        }
    }

    /// ⚠ 一律**单色 SF Symbol**：本项目里**颜色是数据语义**（涨跌红绿 / 灯级 / 信号 / 风险，
    ///   见 `Tokens.swift` 与 `Components.swift` 的按钮角色说明）—— 分类图标不是数据，
    ///   不给它上色，否则"红色"会同时意味着"上涨"和"某个分类"（本项目一直在消除的歧义）。
    ///
    /// ⚠ **名字必须真实存在**：写错时 SwiftUI **什么都不画**（不报错、不占位，肉眼看不出来）——
    ///   由自检 `symbol_names` 逐个实测。
    var icon: String {
        switch self {
        // 折线 = 看板上那几个指数
        case .dashboard: return "chart.line.uptrend.xyaxis"
        // 「日历 + 时钟」＝每天几点的定时任务；⚠ 别改回 `clock.badge.gearshape`（不存在）
        case .schedule:  return "calendar.badge.clock"
        case .alerts:    return "bell.badge"
        // 天线 = 取数链路（回放也在这类里）
        case .sources:   return "antenna.radiowaves.left.and.right"
        case .about:     return "info.circle"
        }
    }
}

// MARK: - 分类壳（左列表 + 右内容）

extension SettingsView {

    /// 分类列表（与主窗口共用 `SidebarTab`、144 定宽、18pt 图标对齐线）。
    var settingsCategoryList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(SettingsCategory.allCases) { c in
                SidebarTab(title: c.title, icon: c.icon, isSelected: c == category) {
                    categoryRaw = c.rawValue
                }
            }
            Spacer(minLength: 0)
        }
        // 首行 pill 绝对顶 = 40：safe area（标题栏带 ~30）+ 10。与主窗口同一套几何。
        .padding(.top, 10)
        .padding(.leading, 6)
        .padding(.trailing, 2)
        .padding(.bottom, 18)
    }

    /// 当前分类的卡片（每页 1~4 张）。
    ///
    /// ⚠ **末尾那张卡拉伸吞掉留白**（`.frame(maxHeight:.infinity, alignment:.top)`）——
    ///   沿用原设置页「底卡拉伸」的做法：铺满模式下未消费的高度吸进卡片，页面底部不露白。
    ///   ⚠ 试过改成自然高度：Settings scene 打开时布局不收敛（`openSettings` 卡住），
    ///     已回退。卡片的 hairline 会框住拉伸后的空白，这是已知取舍。
    @ViewBuilder
    func settingsPage(_ c: SettingsCategory) -> some View {
        switch c {
        case .dashboard:
            dashboardSettingsCard
            ChartSettingsCard().frame(maxHeight: .infinity, alignment: .top)
        case .schedule:
            ScheduleSettingsPage().frame(maxHeight: .infinity, alignment: .top)
        case .alerts:
            alertsCard.frame(maxHeight: .infinity, alignment: .top)
        case .sources:
            // 「数据」：自检 / 诊断 / 个股档案 / 历史回放四张卡上下直接列出。
            selftestCard
            diagnosticsCard
            profileCard
            replayCard.frame(maxHeight: .infinity, alignment: .top)
        case .about:
            aboutCard
        }
    }
}

// ⚠ 分类切换**刻意不做淡入动效**（与主窗口切页不同）：这一列在 `FitScrollView` 里，
//   而它靠"量内容自然高度"决定"铺满还是滚动" —— 叠一层 transition 会让测量多一个中间态
//   （可能闪一下高度）。分类切换本身就是"换一页"，直切最利落，不值得为此引动效。