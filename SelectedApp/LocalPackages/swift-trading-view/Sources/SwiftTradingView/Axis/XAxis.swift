import Foundation
import SwiftUI

public struct XAxis: Axis {
    public var lineColor: Color
    public var labelFont: Font
    public var labelColor: Color
    public var labelInterval: Int
    /// 标签格式化：`(时间, 本屏上一个已画刻度的时间)`。
    ///
    /// ⚠ 为什么要带"上一个刻度"（2026-10-29）：调用方要判断"这里跨年了吗"，
    ///   只看当前时间做不到 —— 间隔是**按根数**取的（自适应 = 可视根数 / 6），
    ///   年份边界经常正好落在两个刻度之间，按"本刻度是否是一年的开头"会整个漏掉。
    ///   本屏第一个刻度的 `previousTime` 是 `nil`（调用方可据此把年份锚出来）。
    public var labelFormatter: (_ time: Double, _ previousTime: Double?) -> String
    /// 固定标签（2026-09-17 分时改造）：非空时优先于 labelInterval 等分模式。
    /// 分时图的时间刻度不是均匀倍数（午休跳变），用固定 (槽位, 文本) 集合最直接：
    /// [(0,"09:30"),(30,"10:00"),…,(120,"11:30/13:00"),…,(239,"15:00")]
    public var fixedLabels: [(index: Int, text: String)]

    /// Initializes a new instance of `XAxis` with customizable appearance and behavior.
    ///
    /// - Parameters:
    ///   - lineColor: The color of the vertical grid lines. Default is gray.
    ///   - labelFont: The font used for x-axis labels. Default is system font with size 10.
    ///   - labelColor: The color of the x-axis label text. Default is black.
    ///   - labelInterval: The interval at which to display labels on the x-axis. Default is every 10 candles.
    ///   - labelFormatter: Formats each label from (time, previousLabeledTime);
    ///     the first label on screen gets `nil`. Default renders "HH:mm".
    ///   - fixedLabels: Fixed (index, text) label list; takes precedence over labelInterval when non-empty.
    public init(
        lineColor: Color = Color.gray,
        labelFont: Font = Font.system(size: 10),
        labelColor: Color = Color.black,
        labelInterval: Int = 10,
        labelFormatter: @escaping (_ time: Double, _ previousTime: Double?) -> String = { time, _ in
            let date = Date(timeIntervalSince1970: time)
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "HH:mm"
            return dateFormatter.string(from: date)
        },
        fixedLabels: [(index: Int, text: String)] = []
    ) {
        self.lineColor = lineColor
        self.labelFont = labelFont
        self.labelColor = labelColor
        self.labelInterval = labelInterval
        self.labelFormatter = labelFormatter
        self.fixedLabels = fixedLabels
    }

    public func draw(
        contextInfo: ContextInfo,
        candlesInfo: CandlesInfo
    ) {

        let context = contextInfo.context
        let contextSize = contextInfo.contextSize

        if !fixedLabels.isEmpty {
            // 固定标签模式：每项 (槽位, 文本)；槽位取数据索引（含 startIndex 偏移）。
            // 首尾标签贴**可视窗口**边缘钳制（2026-09-20 修：原实现钳到整条画布边缘，
            // 画布 = 全部 K 线总宽，窗口边缘的标签仍会被裁掉一半）
            for label in fixedLabels {
                let dataIndex = label.index
                guard dataIndex >= candlesInfo.startIndex,
                      dataIndex <= candlesInfo.endIndex else { continue }
                let text = Text(label.text)
                    .font(labelFont)
                    .foregroundColor(labelColor)
                let resolvedText = context.resolve(text)
                let textSize = resolvedText.measure(in: contextSize)
                guard let x = visibleClampedX(contextInfo.xCoordinate(for: dataIndex),
                                              textWidth: textSize.width,
                                              window: contextInfo.visibleBounds) else { continue }
                let y = contextSize.height - textSize.height / 2
                context.draw(text, at: CGPoint(x: x, y: y), anchor: .center)
            }
            return
        }

        // 本屏**上一个已画刻度**的时间；每帧从 nil 重新开始（滚动/缩放后第一个刻度必带锚点年份）
        var previousTime: Double?
        for (index, item) in candlesInfo.visibleData.enumerated() {
            // labelInterval > 0 = 固定间隔（调用方指定）；<= 0 = 自适应（2026-09-18）：
            // 按**可视根数**取 1/6，这样加载了 500 根日K 后仍然每屏都有刻度，
            // 不会出现"一屏看不到一个日期"（原实现用总根数 /8，根数一多标签全挤在屏外）。
            let interval = labelInterval > 0
                ? labelInterval
                : max(1, candlesInfo.visibleData.count / 6)
            if (index + candlesInfo.startIndex).isMultiple(of: interval) {
                let x = contextInfo.xCoordinate(for: index + candlesInfo.startIndex)
                drawLabel(contextInfo: contextInfo,
                          text: labelFormatter(item.time, previousTime), x: x, showGrid: true)
                previousTime = item.time
            }
        }
    }

    /// 可视窗口内的标签 x 钳制。
    ///
    /// 2026-09-20 修：原实现钳到 `contextSize.width`（**整条画布**），而画布宽 = 全部
    /// K 线总宽（如 500 根 ≈ 5000pt）—— 可视窗口左右边缘的标签中心落在窗口外，
    /// 画出来被裁掉一半（用户截图里的左端日期 / 右端日期都是这个原因）。
    /// 返回 nil = 标签不在窗口内（整条省略，避免多个标签堆在边缘）。
    private func visibleClampedX(_ x: CGFloat, textWidth: CGFloat, window: CGRect) -> CGFloat? {
        let half = textWidth / 2
        guard x >= window.minX - half, x <= window.maxX + half else { return nil }
        let lo = window.minX + half + 2
        let hi = window.maxX - half - 2
        guard hi > lo else { return nil }   // 窗口比标签还窄（极端缩放下）：不画
        return min(max(x, lo), hi)
    }

    private func drawLabel(
        contextInfo: ContextInfo,
        text: String,
        x: CGFloat,
        showGrid: Bool
    ) {
        let context = contextInfo.context
        let contextSize = contextInfo.contextSize
        let label = Text(text)
            .font(labelFont)
            .foregroundColor(labelColor)
        let resolvedText = context.resolve(label)
        let textSize = resolvedText.measure(in: contextSize)
        let y = contextSize.height - textSize.height / 2
        guard let clampedX = visibleClampedX(x, textWidth: textSize.width,
                                             window: contextInfo.visibleBounds) else { return }
        context.draw(label, at: CGPoint(x: clampedX, y: y), anchor: .center)

        if showGrid {
            let linePath = Path { path in
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: contextSize.height - textSize.height))
            }
            context.stroke(linePath, with: .color(lineColor), lineWidth: 1)
        }
    }
}
