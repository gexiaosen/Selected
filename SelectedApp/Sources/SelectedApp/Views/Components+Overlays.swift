import SwiftUI
import AppKit   // NSEvent（钉住 toast 的"点别处即走"本地监视器）
import SelectedCore

// MARK: - 全局提示 Toast（三档收尾；可堆叠）
//
// ⚠ **收尾口径的唯一实现在 `SelectedCore.ToastPolicy`**（纯函数、可被 `swift test` 覆盖）：
//   · `success` 2.0s 自动消失（通过 / 正常）
//   · `info` / `warning` 3.5s 自动消失（中性提醒）
//   · `error` **不自动消失**（告警 / 警报）—— 点窗口任意处才走
//   · `loading` 300s 兜底（正常由同 key 的完成条原位替换）
// 这里只负责"怎么渲染、怎么收事件"，**不再自己写时长数字**（两处口径必然分叉）。

/// 提示中心：新的在上、最多同时 3 条（超出挤掉最旧一条，避免批量操作刷满窗口）。
/// ⚠ **没有关闭按钮**：toast 由定时器或"点别处"收尾，不加 ×（占宽且暗示"要手动关"）。
/// 堆叠是"多条真实反馈不互相顶掉"的需要。
@Observable @MainActor
final class ToastCenter {
    static let shared = ToastCenter()

    enum Style { case success, info, warning, error, loading }
    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let message: String
        let style: Style
        /// 去重键：**同一个 key 的下一条会原位替换上一条** ——
        /// 长任务的「刷新中… → 已刷新」走同一个 key，**不新增第二条**（见 `show`）。
        let key: String?
    }

    /// 最多同时可见条数
    private static var maxVisible: Int { ToastPolicy.maxVisible }

    /// 该档的自动消失秒数（`nil` = 钉住）。**委托 Core 的 `ToastPolicy`**。
    private static func lifetime(_ style: Style) -> Double? {
        ToastPolicy.autoDismissSeconds(style.policyStyle)
    }

    private(set) var visible: [Toast] = []
    private var dismissTasks: [UUID: Task<Void, Never>] = [:]
    /// 钉住条目的"点别处即走"监视器（有钉住条目时才存在，清空即摘除）
    @ObservationIgnored private var clickMonitor: Any?

    func show(_ message: String, style: Style = .success, key: String? = nil) {
        // 同 key 的旧条**原位去掉**、由新条接替 —— 长任务「刷新中 → 已完成」不新增第二条，
        // 同一件事只留 1 处反馈。
        if let key, let idx = visible.firstIndex(where: { $0.key == key }) {
            let old = visible[idx]
            dismissTasks[old.id]?.cancel()
            dismissTasks[old.id] = nil
            visible.remove(at: idx)
        }
        let toast = Toast(message: message, style: style, key: key)
        visible.insert(toast, at: 0)
        // ⚠ 淘汰**必须问 `ToastPolicy`**：钉住的 error 不参与淘汰（否则"不自动消失"
        //   形同虚设 —— 下一条 toast 一来它就没了）。全是钉住条目时宁可临时多占一条，
        //   也不静默吞掉告警。
        while let drop = ToastPolicy.evictionIndex(pinned: visible.map { Self.isPinned($0.style) }) {
            let dropped = visible.remove(at: drop)
            dismissTasks[dropped.id]?.cancel()
            dismissTasks[dropped.id] = nil
        }
        if let seconds = Self.lifetime(style) {
            dismissTasks[toast.id] = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { return }
                self?.dismiss(toast.id)
            }
        }
        syncClickMonitor()
    }

    func dismiss(_ id: UUID) {
        dismissTasks[id]?.cancel()
        dismissTasks[id] = nil
        visible.removeAll { $0.id == id }
        syncClickMonitor()
    }

    /// 清掉全部**钉住**的条目（"点了别处"= 用户已读到告警）。非钉住的按各自定时器自然收尾。
    func dismissPinned() {
        for t in visible where Self.isPinned(t.style) { dismiss(t.id) }
    }

    private static func isPinned(_ style: Style) -> Bool {
        ToastPolicy.isPinned(style.policyStyle)
    }

    /// 有钉住条目 → 装一个 App 内鼠标按下监视器；没有 → 摘掉（别白留全局钩子）。
    ///
    /// ⚠ 用 `addLocalMonitorForEvents`（**只监听本 App**，且**不吞事件** —— 返回值原样传回，
    ///   被点的那个控件照常收到点击）。全局监视器（`addGlobalMonitorForEvents`）要辅助功能
    ///   授权、且收不到本 App 事件，都不适合这里。
    /// ⚠ 监视器里**不能同步改 @Observable 状态**（它在 AppKit 事件回调里），
    ///   故 hop 回主线程再 `dismissPinned()`。
    private func syncClickMonitor() {
        let hasPinned = visible.contains { Self.isPinned($0.style) }
        if hasPinned, clickMonitor == nil {
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
                if event.type == .keyDown && event.keyCode != 53 {
                    return event
                }
                Task { @MainActor in self?.dismissPinned() }
                return event          // 事件继续派发，不拦截用户真正想点的控件或 Esc 键
            }
        } else if !hasPinned, let m = clickMonitor {
            NSEvent.removeMonitor(m)
            clickMonitor = nil
        }
    }
}

extension ToastCenter.Style {
    /// 与 Core `ToastStyle` 的映射（时长/钉住判据的唯一来源在 Core）
    var policyStyle: ToastStyle {
        switch self {
        case .success: return .success
        case .info: return .info
        case .warning: return .warning
        case .error: return .error
        case .loading: return .loading
        }
    }
}

struct ToastBanner: View {
    let toast: ToastCenter.Toast

    /// 图标（`loading` 档**不用符号**：走 `ProgressView` 转圈 —— 静态符号会被读成"某一步已完成"）
    private var icon: String? {
        switch toast.style {
        case .success: return "checkmark.circle.fill"
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        case .loading: return nil
        }
    }

    private var color: Color {
        switch toast.style {
        case .success: return Sem.down
        case .info: return Sem.info
        case .warning: return Sem.warn
        case .error: return Sem.up
        case .loading: return Sem.info   // 进行中＝中性蓝（与 info 同色，靠转圈区分）
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            if let icon {
                Image(systemName: icon)
                    .font(.callout)
                    .foregroundStyle(color)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(color)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(toast.message)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if toast.style == .error {
                    Text("点击任意处或按 Esc 关闭")
                        .font(AppFont.detail)
                        .foregroundStyle(.secondary)
                }
            }
            // ⚠ **不放 × 按钮**：全部由 `ToastCenter` 的定时器 / "点别处 / Esc"收尾，`ToastBanner` 不再有交互。
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        // ⚠ **底色与描边都带语义色**：成功 / 失败 / 警告 / 信息必须一眼可辨。
        //   ⚠ 色值一律走 `Tok.tint` —— `theme_tint` 护栏禁止视图里裸写 `opacity(0.0x)`；
        //   ⚠ 描边用 0.45（> 0.2，不在该护栏管辖的"语义色底"那一族里），
        //     0.18 的底色太淡，做描边看不见。
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Tok.tint(color, .strong))
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(color.opacity(0.45), lineWidth: 1)
        }
        // 落地感双阴影
        .shadow(color: Tok.shadow, radius: 18, y: 6)
        .shadow(color: Tok.shadow.opacity(0.55), radius: 4, y: 1)
    }
}

// MARK: - 全局 toast 浮层（**每个窗口各挂一份**）

/// 顶部**水平居中**（常规短提示）与**右上避让**（钉住 `.error`）的 toast 浮层（最多同屏 3 条，新的在上）。
///
/// ⚠ 位置：常规 `.success` / `.info` / `.warning` / `.loading` 顶部居中（top 56 / 宽度上限 380）；
///   一旦出现钉住的 `.error`（不自动消失，靠鼠标点击或 `Esc` 收起），整体右移至右上角（`.topTrailing`），
///   避免长时间遮挡自选搜索框与对比/复盘顶部六环节链路条。
/// ⚠ 为什么必须**每个窗口都挂一份**：设置页是独立窗口，只挂主窗口时
///   在设置窗口里点刷新完全看不到任何提示（刷新恰恰几乎全在设置页触发）。
/// ⚠ 但**只许 key window 画**：两窗口共用 `ToastCenter.shared.visible` 同一份数据，
///   都挂 overlay 就会**各显示一条**。用 `controlActiveState` 门控：只有当前
///   **前台且有键盘焦点**的那个窗口（`.key`）才渲染 —— 用户在哪个窗口操作，
///   提示就只出现在哪个窗口。`controlActiveState` 是环境值，key window 切换时
///   SwiftUI 自动重算 ⇒ 无需手动跟随。
///   ⚠ 用 `.key` 而非"是否前台"：应用整体进后台时两窗口都是 `.inactive` → 都不画，
///     这正是我们要的（toast 是**就地反馈**，后台失败走系统通知）。
struct ToastOverlay: View {
    @Environment(\.controlActiveState) private var activeState

    private var hasPinnedError: Bool {
        ToastCenter.shared.visible.contains { $0.style == .error }
    }

    var body: some View {
        Group {
            if activeState == .key {
                VStack(alignment: hasPinnedError ? .trailing : .center, spacing: 8) {
                    ForEach(ToastCenter.shared.visible) { t in
                        ToastBanner(toast: t)
                            .frame(maxWidth: 380, alignment: hasPinnedError ? .trailing : .center)
                            .motionAwareTransition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .frame(maxWidth: .infinity, alignment: hasPinnedError ? .trailing : .center)
                // 页栏本体的高度 ≈ 18 + 28 + 10；56 让第一条 toast 落在按钮下沿之下
                .padding(.top, 56)
                .padding(.horizontal, 16)
                .motionAware(Mot.toast, value: ToastCenter.shared.visible)
            }
        }
        // ⚠ **整层不参与命中测试**：toast 顶部居中，而 `error` 档**钉住不自动消失** ——
        //   一条长文案的失败 toast 会盖住页顶 `PageActionBar` 那排按钮，形成双重死锁：
        //   点不到按钮，也"点别处"点不到按钮底下的窗口内容去关掉 toast。
        //   ⇒ toast 是**纯展示**（没有任何交互控件），整层 `allowsHitTesting(false)` 零损失；
        //     "点别处即走"由 `NSEvent` 本地监视器在 AppKit 层收事件，与 SwiftUI 命中测试无关。
        .allowsHitTesting(false)
    }
}

extension View {
    /// 挂上全局 toast 浮层（顶部居中）。⚠ 主窗口与设置窗口**都要挂** —— 理由见 `ToastOverlay`。
    func toastOverlay() -> some View {
        overlay(alignment: .top) { ToastOverlay() }
    }
}

// MARK: - 空仓日统一说明卡（三轮均无入档信号 → 复盘/验证/预判均无标的）

/// 空仓日说明：图标 + 主说明 + 风控脚注，文案不再各页散写
struct EmptyDayCard: View {
    var detail: String
    var footer: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(detail).font(.callout)
            } icon: {
                // ⚠ 中性灰，不是 `Sem.warn`（2026-10-22 P5 / 设计文档 M4）：
                //   同一个橙在这里是"今天没数据"，在别处是"黄灯 / 中风险 / 脉冲信号 / 失败重试中"
                //   —— 一色多义，且把空态画成了危险。托盘这个符号自己就说清了"空"。
                Image(systemName: "tray").foregroundStyle(Tok.dim)
            }
            if let footer {
                Text(footer).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - 操作建议样式（看板与结果页对比段共用，单一实现避免分叉）

/// 引擎建议类型（high_confidence/late_enhance/weakening/empty/etf_hedge）的图标与颜色
enum SuggestionStyle {
    static func icon(_ type: String) -> String {
        switch type {
        case "high_confidence": return "star.fill"
        case "late_enhance": return "arrow.up.right.circle.fill"
        case "weakening": return "arrow.down.right.circle"
        case "empty": return "minus.circle"
        case "etf_hedge": return "shield.lefthalf.filled"
        default: return "info.circle"
        }
    }

    static func color(_ type: String) -> Color {
        switch type {
        case "high_confidence": return Sem.accent
        case "late_enhance": return Sem.info
        case "weakening": return Sem.warn
        default: return .secondary
        }
    }
}

// MARK: - 个股详情点击（全局弹窗入口，任何页面个股行复用）

extension View {
    /// 点击标的名称弹出个股详情（实时行情 + K 线）。挂载于标的名称 Text
    func stockDetailTap(code: String, name: String) -> some View {
        self.onTapGesture {
            Store.shared.showStockDetail(code: code, name: name)
        }
        .clickableRow()
        // ⚠ 键盘可达 —— 与 WatchlistHoldingSection 行同款。macOS 下 `.focusable()`
        //   默认不进 Tab 循环（需系统「全键盘控制」），那是系统行为，别当缺陷修。
        .focusable()
        // ⚠ `.focusEffectDisabled()` 只**关掉焦点环视觉**（`.focusable()` 让鼠标点击也会
        //   把键盘焦点移过来，系统给点过的行画一圈常驻蓝环），`.onKeyPress(.return)` 照常
        //   工作 —— 即"保留键盘可达、去掉焦点环"。
        .focusEffectDisabled()
        .onKeyPress(.return) {
            Store.shared.showStockDetail(code: code, name: name)
            return .handled
        }
        .help("点击查看 \(name) 实时行情与 K 线")
    }
}
