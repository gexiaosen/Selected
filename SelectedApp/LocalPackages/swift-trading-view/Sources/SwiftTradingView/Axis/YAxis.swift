import Foundation
import SwiftUI

/// 独立 Y 轴列（2026-09-17 方案 B 重构，通达信/同花顺范式）。
///
/// **为什么独立成列**：原先 Y 轴画在滚动 Canvas 内部、锚在内容末端（`visibleBounds.maxX`），
/// 内容一窄（分时数据少 / 缩小）刻度就跟着往左挪，悬在图表中间；缩放时还会与蜡烛、
/// 副图图例重叠。独立列后刻度永远贴图表区右缘，与缩放 / 平移 / 数据量完全解耦。
///
/// 职责划分：
/// - **本类型**：在右侧固定列内绘制主图价格刻度、副图刻度、最新价胶囊（底色 + 白字）
/// - **TradingView.renderChart**：水平网格线（需要与本类型相同的刻度值，经 `labelValues` 共享）
/// - **Content.yAxisLabels**：副图（成交量等）的刻度文本
///
/// 注：不再遵循 `Axis` 协议（该协议服务于“画在滚动内容内”的旧架构，仅 XAxis 继续使用）。
public struct YAxis {
    public var labelFont: Font
    public var labelColor: Color
    public var labelFormatter: (Double) -> String
    public var negativeCandleColor: Color
    public var positiveCandleColor: Color
    public var lineColor: Color
    public var labelsCount: Int
    public var labelTrailingPadding: CGFloat
    /// 最新价胶囊的文字色（深色外观下涨跌色偏亮，白字对比不足 → 由调用方配深字）
    public var latestLabelColor: Color

    /// Initializes a new instance of `YAxis` with customizable appearance and behavior.
    ///
    /// - Parameters:
    ///   - negativeCandleColor: The color used for the latest-price tag when the last candle is bearish. Default is red.
    ///   - positiveCandleColor: The color used for the latest-price tag when the last candle is bullish. Default is green.
    ///   - lineColor: The color of the horizontal grid lines. Default is a faint gray (18% opacity).
    ///     ⚠ 该值此前**声明了却从未被消费** —— 水平网格线在 `TradingView` 里写死了
    ///     `Color.gray.opacity(0.18)`，于是调用方传进来的颜色（如 App 的 `Tok.hairline`）
    ///     对水平网格线无效，深色外观下这条线只剩约 9% 灰、几乎看不见。
    ///     现在由 `TradingView` 真正使用本值；默认值同步改成与原先硬编码一致的 18% 灰，
    ///     保证不传该参数的调用方视觉零变化。
    ///   - labelFont: The font used for y-axis labels. Default is system font with size 10.
    ///   - labelColor: The color of the y-axis label text. Default is black.
    ///   - labelsCount: The number of labels (and grid lines) to display on the y-axis. Default is 4.
    ///   - labelFormatter: A closure that formats the y-axis label values. Default formats to two decimal places.
    ///   - labelTrailingPadding: Right inset of label text inside the column. Default is 6.
    ///   - latestLabelColor: Text color of the latest-price tag. Default is white.
    public init(
        negativeCandleColor: Color = Color.red,
        positiveCandleColor: Color = Color.green,
        lineColor: Color = Color.gray.opacity(0.18),
        labelFont: Font = Font.system(size: 10),
        labelColor: Color = Color.black,
        labelsCount: Int = 4,
        labelFormatter: @escaping (Double) -> String = { String(format: "%.2f", $0) },
        labelTrailingPadding: CGFloat = 6,
        latestLabelColor: Color = .white
    ) {
        self.labelFont = labelFont
        self.labelColor = labelColor
        self.negativeCandleColor = negativeCandleColor
        self.positiveCandleColor = positiveCandleColor
        self.lineColor = lineColor
        self.labelsCount = labelsCount
        self.labelFormatter = labelFormatter
        self.labelTrailingPadding = labelTrailingPadding
        self.latestLabelColor = latestLabelColor
    }

    // MARK: - 刻度值计算（与网格线共享）

    /// 主图价格刻度值（含端点，等分 labelsCount 档）。水平网格线与列内刻度共用此结果，
    /// 保证“线与数字永远对齐”。
    public func labelValues(for yBounds: (min: Double, max: Double)) -> [Double] {
        guard labelsCount > 1, yBounds.max > yBounds.min else { return [] }
        let step = (yBounds.max - yBounds.min) / Double(labelsCount - 1)
        return stride(from: yBounds.min, through: yBounds.max, by: step).map { $0 }
    }

    // MARK: - 独立列渲染

    /// 一段可绘制区域（主图或某个副图在列内的垂直区间）
    public struct Segment {
        /// 区域矩形（列自身坐标系；width 即列宽）
        public let rect: CGRect
        /// 该区域数值范围
        public let yBounds: (min: Double, max: Double)
        /// 副图刻度（数值 + 格式化文本；主图传 nil，主图刻度由 labelsCount/labelFormatter 生成）
        public let secondaryLabels: [(value: Double, text: String)]?

        public init(rect: CGRect, yBounds: (min: Double, max: Double),
                    secondaryLabels: [(value: Double, text: String)]? = nil) {
            self.rect = rect
            self.yBounds = yBounds
            self.secondaryLabels = secondaryLabels
        }

        func yCoordinate(for value: Double) -> CGFloat {
            let scale = rect.height / CGFloat(max(yBounds.max - yBounds.min, .ulpOfOne))
            return CGFloat(yBounds.max - value) * scale + rect.minY
        }
    }

    /// 在独立列 Canvas 内绘制全部刻度。
    ///
    /// - Parameters:
    ///   - context: 列 Canvas 的绘图上下文
    ///   - size: 列尺寸
    ///   - primary: 主图区域（nil 则跳过主图刻度）
    ///   - secondarySegments: 副图区域列表（成交量等）
    ///   - lastPrice: 最新价（值 + 涨跌色），画胶囊标签；nil 不画
    public func drawColumn(
        context: GraphicsContext,
        size: CGSize,
        primary: Segment?,
        secondarySegments: [Segment],
        lastPrice: (value: Double, isPositive: Bool)?
    ) {
        guard size.width > 0, size.height > 0 else { return }

        // 胶囊尺寸按真实文字量：定位、边界钳制和引导线都依赖它，不能写死。
        let lastLabelText = lastPrice.map { labelFormatter($0.value) }
        let lastLabelSize: CGSize? = lastLabelText.map {
            context.resolve(Text($0).font(labelFont)).measure(in: size)
        }
        // 胶囊背景高 = 文字高 + 上下各 padding，再 -2；与刻度文字各占一半高度，外加 2pt 间隙
        let capsuleHalfHeight = (lastLabelSize?.height ?? 0) / 2 + Self.capsulePadding - 1
        let tickClearance = capsuleHalfHeight + (lastLabelSize?.height ?? 0) / 2 + 2

        // 最新价**真实**价位（超出主图范围时钳到边缘）。标签可以让位，引导线始终指回这里。
        let lastPriceY: CGFloat? = {
            guard let last = lastPrice, let primary else { return nil }
            let raw = primary.yCoordinate(for: last.value)
            return min(max(raw, primary.rect.minY + capsuleHalfHeight),
                       primary.rect.maxY - capsuleHalfHeight)
        }()

        // 胶囊落点：刻度标签全部保留（2026-10-21 实机反馈后选“标签让位”）——
        // 冲突时把胶囊挪到最近空位，而不是像旧实现那样跳过刻度数字。
        let lastPriceTagY: CGFloat? = {
            guard let primary, let lastPriceY else { return nil }
            let tickYs = labelValues(for: primary.yBounds).map { primary.yCoordinate(for: $0) }
            return tagSlot(near: lastPriceY, avoiding: tickYs,
                           clearance: tickClearance,
                           minY: primary.rect.minY + capsuleHalfHeight,
                           maxY: primary.rect.maxY - capsuleHalfHeight)
        }()

        // 主图价格刻度：右对齐排在列内（全部绘制，不再因胶囊跳过）
        if let primary {
            for value in labelValues(for: primary.yBounds) {
                drawRightAligned(
                    context: context, size: size,
                    text: labelFormatter(value),
                    at: primary.yCoordinate(for: value), color: labelColor,
                    background: nil
                )
            }
        }

        // 副图刻度（成交量量纲等，指标自行格式化）：按数值真实映射到副图区域，
        // 避免等分倒置（低值在上高值在下）（2026-09-17 修）
        for segment in secondarySegments {
            guard let labels = segment.secondaryLabels, !labels.isEmpty else { continue }
            for label in labels {
                let y = min(max(segment.yCoordinate(for: label.value),
                               segment.rect.minY + 5),
                           segment.rect.maxY - 5)
                drawRightAligned(
                    context: context, size: size,
                    text: label.text,
                    at: y, color: labelColor,
                    background: nil
                )
            }
        }

        // 让位时先画引导线（轴列左缘的真实价位 → 胶囊所在高度），再画胶囊盖住线头
        if let last = lastPrice, let lastPriceY, let lastPriceTagY, let lastLabelSize,
           abs(lastPriceTagY - lastPriceY) > 0.5 {
            drawLatestPriceLeader(
                context: context, size: size,
                trueY: lastPriceY, tagY: lastPriceTagY,
                tagTextWidth: lastLabelSize.width,
                color: last.isPositive ? positiveCandleColor : negativeCandleColor
            )
        }

        // 最新价胶囊：底色涨跌色 + 白字，钉在让位后的 y。
        // 取最后一个**有效**数据点（分时固定槽数组尾部可能是空槽，close=0 会画出 0.00 错位胶囊）
        if let last = lastPrice, let lastPriceTagY, let lastLabelText {
            drawRightAligned(
                context: context, size: size,
                text: lastLabelText,
                at: lastPriceTagY,
                color: latestLabelColor,
                background: last.isPositive ? positiveCandleColor : negativeCandleColor
            )
        }
    }

    /// 在刻度文字之间找离真实价位最近的空位；上下都可让，取位移最小者。
    private func tagSlot(near y: CGFloat, avoiding tickYs: [CGFloat],
                         clearance: CGFloat, minY: CGFloat, maxY: CGFloat) -> CGFloat {
        guard minY <= maxY else { return y }
        let target = min(max(y, minY), maxY)
        func collides(_ candidate: CGFloat) -> Bool {
            tickYs.contains { abs($0 - candidate) < clearance }
        }
        guard collides(target) else { return target }

        var candidates = [minY, maxY]
        for tickY in tickYs {
            candidates.append(tickY - clearance)
            candidates.append(tickY + clearance)
        }
        let free = candidates
            .map { min(max($0, minY), maxY) }
            .filter { !collides($0) }
        return free.min { abs($0 - target) < abs($1 - target) } ?? target
    }

    /// 标签让位时的引导线：从轴列左缘的真实价位折到胶囊左缘；线走刻度文字左侧的空隙。
    private func drawLatestPriceLeader(
        context: GraphicsContext, size: CGSize,
        trueY: CGFloat, tagY: CGFloat, tagTextWidth: CGFloat, color: Color
    ) {
        let x = size.width - labelTrailingPadding
        let capsuleLeft = x - tagTextWidth - Self.capsulePadding
        let leaderX: CGFloat = 2
        var path = Path()
        path.move(to: CGPoint(x: 0, y: trueY))
        path.addLine(to: CGPoint(x: leaderX, y: trueY))
        path.addLine(to: CGPoint(x: leaderX, y: tagY))
        path.addLine(to: CGPoint(x: max(capsuleLeft - 2, leaderX), y: tagY))
        context.stroke(path, with: .color(color.opacity(0.55)), lineWidth: 1)
    }

    /// 右对齐绘制一行文本；background 非空时先画底色圆角胶囊（最新价标签）
    private func drawRightAligned(
        context: GraphicsContext,
        size: CGSize,
        text: String,
        at y: CGFloat,
        color: Color,
        background: Color?
    ) {
        let label = Text(text)
            .font(labelFont)
            .foregroundColor(color)
        let resolved = context.resolve(label)
        let textSize = resolved.measure(in: size)
        let x = size.width - labelTrailingPadding

        if let bg = background {
            let pad = Self.capsulePadding
            let rect = CGRect(
                x: x - textSize.width - pad,
                y: y - textSize.height / 2 - pad + 1,
                width: textSize.width + pad * 2,
                height: textSize.height + pad * 2 - 2
            )
            context.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(bg))
        }
        context.draw(label, at: CGPoint(x: x - textSize.width / 2, y: y), anchor: .center)
    }

    /// 最新价胶囊的内边距（绘制与避让共用，改一处即可）
    private static let capsulePadding: CGFloat = 3
}
