import SwiftUI
import SelectedCore

/// 新手引导的 UserDefaults 键（唯一来源）。
/// ⚠ 键名只出现一次：读写各写一份字面量，改名/拼错漂移不会让任何测试变红
///   （与 `AlertPause.defaultsKey` 同款）。
enum OnboardingFlag {
    static let defaultsKey = "onboardingCompleted"
}

// MARK: - 首次启动新手引导
// 触发：AppShellView 首次出现且 UserDefaults 无 onboardingCompleted 标记；
// 重看：设置页「关于」卡片入口。内容与 README/引擎口径一致，改口径时同步。

struct OnboardingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0

    /// 共 4 步（TabView 索引 0~3）
    private static let pageCount = 4

    var body: some View {
        VStack(spacing: 0) {
            // 内容区：手动翻页（switch 而非 TabView —— macOS 下 TabView 对无标签页的布局行为不可控）；
            // 每页内容由 onboardingPage 内部 ScrollView 包裹，内容再多也只在页内滚动，
            // 绝不把底部圆点/按钮挤出窗口
            ZStack {
                switch page {
                case 0: welcomePage
                case 1: schedulePage
                case 2: signalPage
                default: startPage
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // 底部：小圆点居中 + 按钮右侧（ZStack 叠放，圆点不受按钮有无影响真正居中）
            ZStack {
                HStack(spacing: 6) {
                    ForEach(0..<Self.pageCount, id: \.self) { i in
                        Circle()
                            .fill(i == page ? Sem.brand : Tok.stroke)
                            .frame(width: 7, height: 7)
                    }
                }
                HStack(spacing: 10) {
                    // ⚠ 「跳过」+ Escape（2026-10-16 审查 B6）：原先引导 4 页**只能一路点到底**，
                    //   连 `.cancelAction` 都没有 ⇒ 按 Escape 毫无反应。老手第一次打开就被锁在
                    //   一个必须点 4 次才能关掉的模态里，而它可能正开在 14:00 的盘中共。
                    if page < Self.pageCount - 1 {
                        Button("跳过引导") {
                            UserDefaults.standard.set(true, forKey: OnboardingFlag.defaultsKey)
                            dismiss()
                        }
                        .keyboardShortcut(.cancelAction)
                        .btnSecondary()
                    }
                    if page > 0 {
                        Button("上一步") { page -= 1 }
                            .btnSecondary()
                    }
                    Button(page == Self.pageCount - 1 ? "开始使用" : "下一步") {
                        if page == Self.pageCount - 1 {
                            UserDefaults.standard.set(true, forKey: OnboardingFlag.defaultsKey)
                            dismiss()
                        } else {
                            page += 1
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .btnPrimary()
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 600, height: 520)
    }

    // MARK: 第 1 页 · 欢迎

    private var welcomePage: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(AppFont.glyph(52))
                .foregroundStyle(Sem.brand)
            VStack(spacing: 8) {
                Text("Selected · A股尾盘量化选股").font(.title2.bold())
                Text("全自动跑完「选股 → 验证 → 复盘」闭环，你只做决策")
                    .font(.callout).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 12) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("尾盘买入 · 次日午前卖出").font(.callout.bold())
                        Text("系统只找「尾盘走强、次日大概率高开」的标的，纪律口径目标 +1.5%~2%")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "clock.badge.checkmark").foregroundStyle(Sem.brand).frame(width: 24)
                }
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("本地运行 · 数据不出机器").font(.callout.bold())
                        Text("行情直连腾讯/新浪，选股库存在本机，无云端依赖")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "lock.shield").foregroundStyle(Sem.brand).frame(width: 24)
                }
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("菜单栏常驻 · 不值守").font(.callout.bold())
                        Text("到点自动执行全流程，完成弹通知；关窗口不影响调度")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "menubar.rectangle").foregroundStyle(Sem.brand).frame(width: 24)
                }
            }
            .padding(.horizontal, 36)
            Spacer()
        }
        .padding(.top, 24)
    }

    // MARK: 第 2 页 · 每日节奏

    private var schedulePage: some View {
        onboardingPage("每天自动做什么", subtitle: "全部由调度器到点执行，时间可在设置中调整") {
            VStack(alignment: .leading, spacing: 10) {
               ForEach(Array(Self.timeline.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 12) {
                        Text(ScheduleTimes.shared.clock(item.key))
                            .font(.callout.bold().monospacedDigit())
                            .foregroundStyle(Sem.brand)
                            .frame(width: 52, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.callout.bold())
                            Text(item.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 2)
                }
            }
            .padding(.horizontal, 8)
        }
    }

    /// 轮次行**按 `RoundPlan` 派生**（措辞按**位置**取：首轮 / 中间轮 / 末轮）。
    /// ⚠ 写死三行的话，加第 4 轮后引导页永远只教三轮 —— 而引导页是用户建立心智模型的地方，
    ///   "教少了"不会报错，只会让用户以为系统就这个节奏。
    private static var roundRows: [(key: String, title: String, detail: String)] {
        RoundPlan.slots.enumerated().map { i, num in
            (RoundPlan.roundKey(num), "\(RoundPlan.ordinal(num))扫描",
             i == 0 ? "全市场 ~5000 只筛选 + 打分"
             : i == RoundPlan.count - 1 ? "末轮扫描，随行情逐轮趋紧"
             : "同口径复扫，观察信号持续性")
        }
    }

    /// ⚠ 时刻不写死：只存任务 key + 文案，时刻在渲染时从 `ScheduleTimes.shared.clock(key)` 取 ——
    ///   用户改了调度设置后引导页必须跟着变，否则引导教的是错的时刻（比没有引导更糟）。
    /// ⚠ **末轮扫描**与自选判定拆成两行：默认值相同，但用户可以把它们改成不同时刻，
    ///   合成一行就只能显示其中一个。
    private static let timeline: [(key: String, title: String, detail: String)] = [
        ("predict", "早盘预判", "对昨日选股给出红黄绿灯与逐标的卖出策略"),
        ("verify", "盘中验证", "盘中快照统计昨日信号的真实胜率"),
    ] + roundRows + [
        ("watch", "全量判定", "对自选股执行三层判定并推送触碰提醒"),
        ("compare", "三轮对比", "汇总三轮，分类最强/持续/脉冲信号"),
        ("review", "收盘复盘", "四层胜率 + 预判准确度评分"),
        ("iterate", "三天迭代", "每 3 个有效交易日输出偏差模式洞察"),
    ]

    // MARK: 第 3 页 · 信号纪律

    private var signalPage: some View {
        onboardingPage("怎么读信号", subtitle: "只操作经三轮确认的持续信号，是本系统的核心纪律") {
            VStack(alignment: .leading, spacing: 12) {
                // 信号类型
                HStack(spacing: 8) {
                    SignalTag(type: .strongest)
                    SignalTag(type: .consensus)
                    SignalTag(type: .pulse)
                    SignalTag(type: .unverified)
                }
                Text("最强 = 三轮均一档（优先操作）｜持续 = 三轮均入档｜脉冲 = 非全轮入选（谨慎）｜未验证 = 轮次不足（按脉冲对待）")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                // 打分体系
                VStack(alignment: .leading, spacing: 6) {
                    Text("打分体系（0-100+ 加权分）").font(.callout.bold())
                    HStack(spacing: 12) {
                        // ⚠ 档位与**当前默认版本**（backtest_v1_3_0：tier1_min=85 / tier2_min=60 /
                        //   tier_lock=49）一致；换默认参数版本时需同步这里（教学页不动态取数）。
                        scoreChip("≥85 买入", Sem.up)
                        scoreChip("60-84 观察", Sem.warn)
                        scoreChip("<60 回避", Sem.down)
                    }
                    Text("均线未多头排列的高分票会被纪律锁进三档（显示原始分），档位代表资格而非仅分数")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                // 大盘灯
                VStack(alignment: .leading, spacing: 6) {
                    Text("大盘灯（一票否决）").font(.callout.bold())
                    HStack(spacing: 12) {
                        LightBadge(level: .green)
                        LightBadge(level: .yellow)
                        LightBadge(level: .red)
                    }
                    Text("红灯 = 大盘连跌 ≥2 日，全部标的空仓观望，不给买入点")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
        }
    }

    private func scoreChip(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption.bold())
            .foregroundStyle(color)
            .padding(.horizontal, 10).padding(.vertical, 3)
            .background(Tok.tint(color), in: Capsule())
    }

    // MARK: 第 4 页 · 开始使用

    private var startPage: some View {
        onboardingPage("开始之前", subtitle: "两件小事让体验完整") {
            VStack(alignment: .leading, spacing: 14) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("允许通知").font(.callout.bold())
                        Text("扫描完成、买入/卖出信号、自选止盈止损提醒都走系统通知；若刚才弹出的授权窗口点了拒绝，可到 系统设置 → 通知 中重新开启")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "bell.badge").foregroundStyle(Sem.brand).frame(width: 24)
                }
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("添加几只自选股").font(.callout.bold())
                        Text("自选页支持分组与手动持仓（成本/数量），每天 \(ScheduleTimes.shared.clock("watch")) 自动判定买卖点并推送触碰提醒")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "star.circle").foregroundStyle(Sem.brand).frame(width: 24)
                }
                Divider()
                Text("看板页每张卡片与右上角按钮都有悬停说明；侧栏「参数中心」管理选股参数版本，调优与回放在「设置」。遇到问题先看「设置 → 数据源自检」。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 8)
        }
    }

    // MARK: 页面骨架

    private func onboardingPage<Content: View>(_ title: String, subtitle: String,
                                               @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title3.bold())
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 12)
            // 页内滚动：内容超出高度时在页内滚动，底部控件永远在窗口内
            ScrollView {
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
            }
        }
    }
}
