import SwiftUI
import AppKit
import SelectedCore

// MARK: - 点击空白取消输入框聚焦（macOS 全局事件方案）

/// 监听鼠标按下事件：若点击目标不在文本编辑器内，统一结束当前编辑（释放第一响应者）。
/// SwiftUI TextField 聚焦后，SwiftUI 自身不提供"点外面失焦"，需在 AppKit 层处理。
final class FocusDismissMonitor: @unchecked Sendable {
    static let shared = FocusDismissMonitor()
    private var localMonitor: Any?

    func start() {
        guard localMonitor == nil else { return }
        // 本应用窗口内的鼠标按下（关键：local monitor 能在事件分发前拦截）
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    func stop() {
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
    }

    private func handle(_ event: NSEvent) {
        // 只在主线程处理（事件监听已在主线程）
        guard let window = event.window ?? NSApplication.shared.keyWindow else { return }
        guard let fr = window.firstResponder else { return }

        // SwiftUI TextField 聚焦时，firstResponder 是 field editor（NSTextView）
        guard fr is NSTextView else { return }

        // ⚠ `contentView` 的存在性检查是有意的早退语义，别当无用检查删掉
        let location = event.locationInWindow
        guard window.contentView != nil else { return }

        // SwiftUI 的 hitTest 返回 NSHostingView（SwiftUI 层不暴露内部结构）
        // 策略：点击位置若与当前 field editor 的 frame 相交 → 保持聚焦；否则结束
        if let editor = fr as? NSView {
            let editorFrameInWindow = editor.convert(editor.bounds, to: nil)
            let clickedInEditor = editorFrameInWindow.contains(location)
            if clickedInEditor { return }  // 点在输入框内，正常编辑
        }
        // 点击空白：强制把第一响应者转移出文本编辑
        window.makeFirstResponder(nil)
    }
}

extension View {
    /// SwiftUI 层兜底：点击视图空白区取消输入框焦点（与全局监听双保险）
    func dismissKeyboardOnOutsideTap() -> some View {
        onTapGesture {
            if let window = NSApplication.shared.keyWindow,
               let fr = window.firstResponder,
               fr is NSTextInputClient {
                window.makeFirstResponder(nil)
            }
        }
    }
}
