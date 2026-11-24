import SwiftUI
import SelectedCore

// MARK: - 主窗口侧边栏、调度任务 Popover 与外观切换

extension AppShellView {

    var sidebar: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Page.allCases) { p in
                    SidebarTab(title: p.title, icon: p.icon,
                               isSelected: p == currentPage) {
                        pageRaw = p.rawValue
                    }
                }
            }
            // 首行 pill 绝对顶 = 40：safe area（标题栏带 ~30）+ 10。让开红绿灯，
            // 且图标左缘落在 18pt 对齐线上（列左 10 + pill 内缩 8）。
            .padding(.top, 10)
            .padding(.leading, 6)
            .padding(.trailing, 2)
            Spacer(minLength: 12)
            sidebarFooter
                .padding(.horizontal, 18)
                .padding(.top, 10)
                .padding(.bottom, 18)
        }
    }

    private var sidebarFooter: some View {
        // ⚠ 圆点条与外观控件**同轴居中**（VStack 用 .center）。
        VStack(spacing: 8) {
            Divider()
            scheduleStatusButton
            // 自动调度开关仅在设置页保留（主页面不再暴露）
            // 外观三档 + 设置齿轮同排。
            // ⚠ `Spacer` 撑开：分段控件贴左缘、齿轮贴右缘（外层已有 12pt 水平 padding）。
            //   齿轮补 `frame(width:26, height:22)`（≈ 分段控件 regular 高度与单段宽度）对齐左侧；
            //   hover 淡底由 `IconHoverFeedback` 的 background 跟着 frame 走，
            //   命中区按 `btnIcon` 的既有约定由 `.frame` + `.contentShape` 决定。
            HStack(spacing: 0) {
                appearanceIcons
                Spacer(minLength: 8)
                // ⚠ `SettingsLink`（macOS 14+）是打开 `Settings` scene 的官方入口 ——
                //   与菜单栏「设置…」/ Cmd+, 同一个动作，不是第二套逻辑。
                SettingsLink {
                    Image(systemName: "gearshape")
                        .font(AppFont.glyph(16))
                        .frame(width: 26, height: 22)
                        // 静默检查发现新版 → 齿轮右上角红点（与「关于」页的「发现新版本」同一份状态）。
                        // ⚠ 读 `availableVersion` 即注册 Observation 依赖，红点会随静默检查自动亮起。
                        .overlay(alignment: .topTrailing) {
                            if UpdateCenter.shared.availableVersion != nil {
                                Circle()
                                    .fill(Sem.up)
                                    .frame(width: 6, height: 6)
                                    .offset(x: -1, y: 1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .iconHoverFeedback()
                .help(UpdateCenter.shared.availableVersion.map { "设置（发现新版本 v\($0)）" } ?? "设置")
            }
        }
    }

    // MARK: 调度任务列表

    /// 侧栏底部的调度入口：一行摘要，点开是完整任务列表（时间 / 状态 / 失败原因）。
    /// 原来的 14 颗 7pt 圆点只有颜色和悬停文字，改成列表后状态有文字通道。
    private var scheduleStatusButton: some View {
        let summary = scheduleSummary
        return Button {
            showScheduleList.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: summary.icon)
                    .font(.caption)
                Text(summary.text)
                    .font(AppFont.detail)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(AppFont.micro)
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(summary.color)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("查看全部调度任务（时间 / 状态 / 失败原因）")
        .popover(isPresented: $showScheduleList, arrowEdge: .trailing) {
            scheduleTaskList
        }
    }

    private var scheduleTaskList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("调度任务").font(.headline)
                Spacer()
                Text("今日").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(scheduler.tasks.indices, id: \.self) { i in
                        scheduleTaskRow(scheduler.tasks[i])
                        if i < scheduler.tasks.count - 1 {
                            Divider()
                        }
                    }
                }
            }
            // 14 行 × 31（上下内缩 8 + 12pt 行高 15）+ 表头 37 + 分隔线 13 = **484pt** 是常态高度，
            // 每多一条失败详情 +31（行距 3 + 11pt 两行 28）⇒ 一条 515、两条 546。
            // 上限取 520：全绿的一天不用滚，出现一条失败原因也不滚（旧值 420 连 14 行都装不下）。
            .frame(maxHeight: 520)
        }
        .frame(width: scheduleMetrics.width)
    }

    /// 宽度不写死：三列各自取实测内容宽，名称列跟着 `ScheduleCatalog` 最长的名字走
    ///   （十几个字符串取个最长，成本可忽略）。
    private var scheduleMetrics: SchedulePopoverMetrics {
        SchedulePopoverMetrics(labels: scheduler.tasks.map(\.label))
    }

    /// 三列定宽 + 状态右贴边；**行首不再有状态符号**（符号与后面的状态文字重复）。
    ///
    /// ⚠ 详情行占**整块内容宽**（190pt，不缩进到名称列）：缩进后只剩 142pt，
    ///   最长那条失败原因（实测 344.4pt = 原因 288.5 + 「（第 1/3 次）」）会折到 2.4 行，
    ///   尾巴被 `lineLimit(2)` 削掉。
    private func scheduleTaskRow(_ task: Scheduler.Task) -> some View {
        let m = scheduleMetrics
        let state = scheduleTaskState(task)
        let hhmm = String(format: "%02d:%02d", task.hour, task.minute)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: m.columnGap) {
                Text(hhmm)
                    .font(AppFont.bodySmall)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: m.timeWidth, alignment: .leading)
                Text(task.label)
                    .font(AppFont.bodySmall)
                    .lineLimit(1)
                    .frame(width: m.nameWidth, alignment: .leading)
                Text(state.text)
                    .font(AppFont.detail.weight(.medium))
                    .foregroundStyle(state.color)
                    .lineLimit(1)
                    .frame(width: m.statusWidth, alignment: .trailing)
            }
            if let detail = state.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: m.contentWidth, alignment: .leading)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, m.padding)
        .padding(.vertical, 8)
    }

    /// 详情行**只放原因**：状态列已经写了「未执行 / 失败（已放弃）/ 失败 · 重试中」，
    /// 原先尾部再补的「可手动补跑」「已停止自动重试」是把同一件事说第二遍
    /// （且「可手动补跑」只有轮次成立，其余任务没有手动入口，属于误导）。
    private func scheduleTaskState(_ task: Scheduler.Task) -> (text: String, color: Color, detail: String?) {
        let running = scheduler.runningTaskId == task.id
        let done = scheduler.completedToday.contains(task.id)
        let failCount = scheduler.failedCounts[task.id]
        let missed = scheduler.missedToday[task.id]
        let failed = failCount != nil && !running
        let gaveUp = failed && (done || missed != nil)
        let retrying = failed && !gaveUp
        if running { return ("执行中", Sem.info, nil) }
        if let missed {
            // 「当日未执行」是 `missedToday` 没有原因时的回落值，与状态列同义 ⇒ 不再占一行
            return ("未执行", Sem.up, missed == "当日未执行" ? nil : missed)
        }
        if gaveUp {
            return ("失败（已放弃）", Sem.up, scheduler.failureMessages[task.id])
        }
        if retrying, let n = failCount {
            let nth = "第 \(n)/\(Scheduler.policy.maxAttempts) 次"
            guard let why = scheduler.failureMessages[task.id], !why.isEmpty else {
                return ("失败 · 重试中", Sem.warn, "\(nth)失败，将自动重试")
            }
            return ("失败 · 重试中", Sem.warn, "\(why)（\(nth)）")
        }
        if done { return ("完成", Sem.down, nil) }
        return ("待运行", .secondary, nil)
    }

    private var scheduleSummary: (text: String, color: Color, icon: String) {
        let tasks = scheduler.tasks
        let running = tasks.filter { scheduler.runningTaskId == $0.id }.count
        let terminal = tasks.filter {
            scheduler.missedToday[$0.id] != nil
                || (scheduler.failedCounts[$0.id] != nil && scheduler.completedToday.contains($0.id))
        }.count
        let retrying = tasks.filter {
            scheduler.failedCounts[$0.id] != nil
                && scheduler.missedToday[$0.id] == nil
                && !scheduler.completedToday.contains($0.id)
                && scheduler.runningTaskId != $0.id
        }.count
        let done = tasks.filter { scheduler.completedToday.contains($0.id) }.count
        if running > 0 { return ("执行中 \(running)", Sem.info, "arrow.triangle.2.circlepath") }
        if terminal > 0 { return ("失败 \(terminal)", Sem.up, "exclamationmark.triangle.fill") }
        if retrying > 0 { return ("重试 \(retrying)", Sem.warn, "arrow.clockwise.circle") }
        return ("完成 \(done)/\(tasks.count)", .secondary,
                done == tasks.count ? "checkmark.circle.fill" : "clock")
    }

    /// 外观三档：**三个图标并排，点哪个是哪个**，当前档带底。
    ///
    /// ## 为什么是三个并排而不是一个循环按钮
    /// 一眼看得到有哪三档、也看得到当前在哪档，且**一步到位**（循环按钮最多要点两下、还得记顺序）。
    ///
    /// ## 约定
    /// - **原生 segmented Picker**（选中态由系统提供）；点选即切并落盘（`AppearanceStore.set` 唯一入口不变）
    /// - 每段带悬浮提示（把"自动 = 跟随系统设置"说清）
    private var appearanceIcons: some View {
        HStack(spacing: 0) {
            ForEach(AppearanceStore.Mode.allCases, id: \.self) { m in
                Button {
                    appearance = m
                    AppearanceStore.shared.set(m)
                } label: {
                    Image(systemName: m.icon)
                        .font(AppFont.glyph(12))
                        .frame(width: 22, height: 20)
                        .foregroundStyle(appearance == m ? Tok.label : Tok.labelSecondary)
                        .background(appearance == m ? Tok.pillFill : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(m.helpText)
            }
        }
        .padding(2)
        .background(Tok.chip, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .help("外观：自动 / 白天 / 黑夜")
    }
}

/// 菜单栏「调度任务」popover 的列宽（1px = 1pt，全部取**实测内容宽度**）。
///
/// 旧实现是 `.frame(width: 340)` 写死：行内容实测最长只有 146.8pt ⇒ 右侧 169pt 纯空白。
/// 现在宽度由下面四个数相加得出，**不留富余**。
struct SchedulePopoverMetrics {
    /// 「09:30」12pt 实测 33.8pt
    let timeWidth: CGFloat = 40
    /// 「失败（已放弃）」11pt Medium 实测 69.1pt（六个状态里最长的一条）
    let statusWidth: CGFloat = 70
    let columnGap: CGFloat = 10
    let padding: CGFloat = 12
    /// 名称列：**按任务表里最长的名字现算**，不写死。
    /// 中文方块字在 12pt 下字宽 ≈ 1em（实测「第一轮选股」5 字 = 59.6pt ≤ 5×12），
    /// 所以注册表将来加一个六个字的任务，这里会自己变宽，不会出现"名字被省略号吃掉"。
    let nameWidth: CGFloat

    init(labels: [String]) {
        nameWidth = CGFloat(max(1, labels.map(\.count).max() ?? 1)) * 12
    }

    var contentWidth: CGFloat { timeWidth + columnGap + nameWidth + columnGap + statusWidth }
    var width: CGFloat { contentWidth + padding * 2 }
}
