import SwiftUI
import SelectedCore

// MARK: - 调度设置（设置窗口的「调度」分类页）
//
// ⚠ 这是**分类页不是弹窗**（同一动作不留两条入口，旧的 `ScheduleSheet` 弹窗已删）。
//
//   **2026-10-27 第二次收：时刻清单从前台撤掉（连只读版也不留）。**
//     依据不是"用不到改"，而是**同一份信息不留两处** —— 主窗口左下角那一栏的
//     「调度任务」popover（`AppShellView.scheduleTaskList`）已经列出
//     **时刻 + 今日状态 + 失败原因**，设置页这份只有时刻，是它的弱化副本。
//     于是这一页只剩"要不要让它自己跑"这一件事 —— 分类名随之改成「自动化」。
//   ⚠ 要改时刻：改 `SelectedCore.ScheduleCatalog` 的出厂表 —— 每个时点为什么选在那里
//     （15:15 涨停统计等收盘定稿、17:30 龙虎榜等交易所发布延迟…）注释就写在那一行旁边。
//   ⚠ 存量自定义仍然生效：`ScheduleTimes.load()` 按 `key` 合并 UserDefaults，
//     撤掉写入入口不等于重置任何人已改过的时刻（本机现存 `compare` 14:53，出厂 15:02）。
//     要连"能被覆盖"这件事一起删，得再删 `ScheduleTimes.update/reset` 与其持久化 —— 未做，待拍。

struct ScheduleSettingsPage: View {
    private let scheduler = Scheduler.shared

    /// 登录项开关的**本地镜像**（初值取系统真相；写入后再回读，见 `launchToggle`）
    @State private var launchEnabled: Bool = LaunchAtLogin.isEnabled
    /// 登录项设置失败的原因；`nil` = 无错误
    @State private var launchError: String?

    var body: some View {
        Card("自动化", subtitle: "开关即时生效 · 任务时刻看主窗口左下角「调度」栏") {
            VStack(alignment: .leading, spacing: 16) {
                toggles
                HStack(spacing: 6) {
                    Text("运行口径")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    InfoTip(text: footnoteText, title: "调度口径")
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: 两个开关（上下两条排开，紧凑清晰）

    /// 「自动调度」与「开机自启」是同一类决策（**这套调度存不存在**），上下两条排开。
    ///
    /// ⚠ 开机自启为什么留在这一页而不是「通用」：它不是应用偏好，而是这一页所有时刻
    ///   能不能发生的 precondition —— 调度全部跑在进程内定时器上，App 没回来，
    ///   列在这里的 14 个时点一个都不会执行。
    private var toggles: some View {
        VStack(alignment: .leading, spacing: 12) {
            toggleRow(title: "自动调度",
                      note: "三轮扫描 + 四阶段（预判/验证/复盘/迭代）+ 收盘后资金流向 / 龙虎榜",
                      isOn: Binding(get: { scheduler.schedulerEnabled },
                                    set: { scheduler.schedulerEnabled = $0 }),
                      disabled: false,
                      help: "关掉后所有任务只保留手动入口，调度器不再按时唤醒")
            Divider()
            toggleRow(title: "开机 / 登录后自动启动",
                      note: launchError ?? "App 没运行，这一页列的时刻都不会发生",
                      isOn: Binding(
                        get: { launchEnabled },
                        set: { on in
                            launchEnabled = on
                            launchError = LaunchAtLogin.setEnabled(on)
                            // 失败或系统侧被改回 → 用真相覆盖乐观值，别让开关显示一个不存在状态
                            if launchError != nil { launchEnabled = LaunchAtLogin.isEnabled }
                        }),
                      disabled: !LaunchAtLogin.isAvailable,
                      help: "调度全部跑在进程内定时器上：重启后需要它自己回来")
        }
    }

    private func toggleRow(title: String, note: String, isOn: Binding<Bool>,
                           disabled: Bool, help: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(disabled)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(note)
                    .font(.caption)
                    .foregroundStyle(launchError != nil && title.contains("开机") ? Sem.warn : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(help)
    }

    // MARK: 边界与补跑（收进 ⓘ；这页只回答"要不要让它自己跑"）

    private var footnoteText: String {
        var lines = [
            "轮次归属边界：\(ScheduleTimes.shared.roundBoundaries.joined(separator: " / "))（按三轮时间自动推导）",
            "补跑窗口：到点后 \(Scheduler.policy.catchUpMinutes) 分钟内仍会执行；超过则记为「未执行」并通知，不会静默跳过",
        ]
        if Scheduler.shared.schedulerEnabled, let next = Scheduler.shared.nextRunAt {
            lines.append("下次唤醒：\(ChinaTime.hhmm(next))（系统唤醒后自动补偿）")
        }
        return lines.joined(separator: "\n")
    }
}
