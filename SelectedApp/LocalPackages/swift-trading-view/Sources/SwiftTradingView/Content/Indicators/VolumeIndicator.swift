import Foundation
import SwiftUI
import SwiftTA

@available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
public struct VolumeIndicator: Content {
    public var positiveCandleColor: Color
    public var negativeCandleColor: Color
    public var volumeColor: Color
    public var ma5Color: Color
    public var ma10Color: Color
    public var labelFont: Font
    public var lineWidth: CGFloat
    public var valueFormatter: (Double) -> String
    public var yAxisLabelColor: Color
    /// `true` = 副图画 `CandleData.amount`（成交额，元）；`false` = `volume`（成交量，手）。
    public var usesAmount: Bool

    public init(
        positiveCandleColor: Color = .green,
        negativeCandleColor: Color = .red,
        volumeColor: Color = .gray,
        ma5Color: Color = .blue,
        ma10Color: Color = .red,
        labelFont: Font = Font.system(size: 10),
        lineWidth: CGFloat = 1.0,
        valueFormatter: @escaping (Double) -> String = { String(format: "%.2f", $0) },
        yAxisLabelColor: Color = .black,
        usesAmount: Bool = false
    ) {
        self.positiveCandleColor = positiveCandleColor
        self.negativeCandleColor = negativeCandleColor
        self.volumeColor = volumeColor
        self.ma5Color = ma5Color
        self.ma10Color = ma10Color
        self.labelFont = labelFont
        self.lineWidth = lineWidth
        self.valueFormatter = valueFormatter
        self.yAxisLabelColor = yAxisLabelColor
        self.usesAmount = usesAmount
    }

    private func value(of candle: CandleData) -> Double {
        usesAmount ? candle.amount : candle.volume
    }

    public func calculate(candlesInfo: CandlesInfo) -> CalculatedData {
        let values = candlesInfo.data.map { value(of: $0) }

        do {
            let (ma5BeginIndex, ma5Values) = try TALib.MA(inReal: values, timePeriod: 5, maType: .sma)
            let (ma10BeginIndex, ma10Values) = try TALib.MA(inReal: values, timePeriod: 10, maType: .sma)

            let visibleValues = Array(values[candlesInfo.startIndex..<candlesInfo.endIndex])
            let visibleMA5 = Array(ma5Values[max(0, candlesInfo.startIndex - ma5BeginIndex)..<min(ma5Values.count, candlesInfo.endIndex - ma5BeginIndex)])
            let visibleMA10 = Array(ma10Values[max(0, candlesInfo.startIndex - ma10BeginIndex)..<min(ma10Values.count, candlesInfo.endIndex - ma10BeginIndex)])

            let allValues = visibleValues + visibleMA5 + visibleMA10
            // ⚠ 柱状分栏的下界**必须是 0**，不是可见数据的最小值。
            //   取 min 会让 `yScale = pane高/(max−min)` 放大，`yCoordinate(0)` 落到
            //   **pane 底以下** (max/(max−min) − 1) 个 pane 高处 —— 柱子直接穿过分栏、
            //   盖进底部的日期带（实测：可见区间 min≈2760万 / max≈4550万 ⇒ 基线在 pane 底
            //   以下 1.54 个 pane 高，日期被整根柱子埋掉）。
            //   取 0 之后 `yCoordinate(0) == visibleBounds.maxY`，柱高 = volume/max × pane高，
            //   既是正确的比例（原来按 `v/(max−min)` 画，等于把差异放大 2.5 倍），
            //   也不会再越出分栏。
            let minValue = 0.0
            let maxValue = allValues.max() ?? 0

            let yAxisLabels = calculateYAxisLabels(min: minValue, max: maxValue)

            return CalculatedData(
                min: minValue,
                max: maxValue,
                values: (
                    ma5: (beginIndex: ma5BeginIndex, values: ma5Values),
                    ma10: (beginIndex: ma10BeginIndex, values: ma10Values),
                    yAxisLabels: yAxisLabels
                )
            )
        } catch {
            print("Error calculating Volume MAs: \(error)")
            return CalculatedData(min: 0, max: 0, values: (ma5: (beginIndex: 0, values: []), ma10: (beginIndex: 0, values: []), yAxisLabels: []))
        }
    }

    public func legend(candlesInfo: CandlesInfo, calculatedData: CalculatedData) -> [Text] {
        guard let (ma5, ma10, _) = calculatedData.values as? ((beginIndex: Int, values: [Double]), (beginIndex: Int, values: [Double]), [Double]) else {
            return []
        }

        // 图例取最后一个**有效**槽（分时是固定 240 槽数组，尾部空槽 close=0，
        // 直接取 last 会显示 Vol:0 / MA:-0）（2026-09-17 修）
        let lastVisibleIndex = (candlesInfo.startIndex..<candlesInfo.endIndex)
            .reversed().first { $0 < candlesInfo.data.count && value(of: candlesInfo.data[$0]) > 0 }
            ?? (candlesInfo.endIndex - 1)
        let seriesValue = value(of: candlesInfo.data[lastVisibleIndex])
        let ma5Value = ma5.values[safe: lastVisibleIndex - ma5.beginIndex] ?? 0
        let ma10Value = ma10.values[safe: lastVisibleIndex - ma10.beginIndex] ?? 0

        return [
            Text("\(usesAmount ? "额" : "Vol"): \(valueFormatter(seriesValue))")
                .font(labelFont).foregroundColor(volumeColor),
            Text("MA(5): \(valueFormatter(ma5Value))").font(labelFont).foregroundColor(ma5Color),
            Text("MA(10): \(valueFormatter(ma10Value))").font(labelFont).foregroundColor(ma10Color)
        ]
    }

    public func yAxisLabels(candlesInfo: CandlesInfo, calculatedData: CalculatedData) -> [(value: Double, text: String)] {
        // 刻度已改由独立 Y 轴列渲染（方案 B）：返回 (数值, 格式化文本)，
        // 位置由 Y 轴列按副图 yBounds 真实映射（避免等分倒置）
        guard let (_, _, yAxisLabels) = calculatedData.values as? ((beginIndex: Int, values: [Double]), (beginIndex: Int, values: [Double]), [Double]) else {
            return []
        }
        return yAxisLabels.map { ($0, valueFormatter($0)) }
    }

    public func draw(
        contextInfo: ContextInfo,
        candlesInfo: CandlesInfo,
        calculatedData: CalculatedData
    ) {
        guard let (ma5, ma10, _) = calculatedData.values as? ((beginIndex: Int, values: [Double]), (beginIndex: Int, values: [Double]), [Double]) else {
            return
        }

        let context = contextInfo.context

        // Y 轴刻度绘制已移至独立 Y 轴列（2026-09-17 方案 B）：
        // 原实现在此画刻度会跟随滚动内容漂移，且与 MA 图例重叠。

        // ⚠ 柱子与 MA 线共用 `contextInfo.yCoordinate`，而它的映射来自本分栏的
        //   `yBounds`（下界已是 0，见 `calculate`）⇒ 两者永远落在 pane 内。
        //   这里**不要**再各自另算一套基线。

        // Draw volume bars
        drawVolumeBars(context: context, contextInfo: contextInfo, candlesInfo: candlesInfo)

        // Draw MA lines（空槽断开，防止 MA 画进空白区）
        drawMALine(context: context, contextInfo: contextInfo, beginIndex: ma5.beginIndex, values: ma5.values, color: ma5Color, candlesInfo: candlesInfo)
        drawMALine(context: context, contextInfo: contextInfo, beginIndex: ma10.beginIndex, values: ma10.values, color: ma10Color, candlesInfo: candlesInfo)
    }

    private func drawVolumeBars(context: GraphicsContext, contextInfo: ContextInfo, candlesInfo: CandlesInfo) {
        let barWidth = contextInfo.candleWidth

        for (index, item) in candlesInfo.visibleData.enumerated() {
            let x = contextInfo.xCoordinate(for: index + candlesInfo.startIndex)
            let y = contextInfo.yCoordinate(for: value(of: item))
            let zeroY = contextInfo.yCoordinate(for: 0)

            let barRect = CGRect(
                x: x - barWidth / 2,
                y: y,
                width: barWidth,
                height: zeroY - y
            )
            let color = item.open > item.close ? negativeCandleColor : positiveCandleColor
            context.fill(Path(barRect), with: .color(color))
        }
    }

    private func drawMALine(context: GraphicsContext, contextInfo: ContextInfo, beginIndex: Int, values: [Double], color: Color, candlesInfo: CandlesInfo) {
        // 跳过空槽（值<=0，分时停牌/未到时间）：否则 MA 会画进空白区（下垂线）（2026-09-17 修）
        let linePath = Path { path in
            var firstPoint = true
            for (index, value) in values.enumerated() {
                let dataIndex = index + beginIndex
                guard dataIndex >= 0, dataIndex < candlesInfo.data.count,
                      self.value(of: candlesInfo.data[dataIndex]) > 0 else {
                    firstPoint = true   // 断开，下个有效点重新 move
                    continue
                }
                let x = contextInfo.xCoordinate(for: dataIndex)
                let y = contextInfo.yCoordinate(for: value)

                if firstPoint {
                    path.move(to: CGPoint(x: x, y: y))
                    firstPoint = false
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
        }

        context.stroke(linePath, with: .color(color), lineWidth: lineWidth)
    }

    private func calculateYAxisLabels(min: Double, max: Double) -> [Double] {
        let range = max - min
        if range <= 1000 {
            // If the range is small, just return one label in the middle
            return [(min + max) / 2].map { $0.rounded() }
        } else {
            // Otherwise, return two labels
            let lowerLabel = (min + range * 0.25).rounded()
            let upperLabel = (max - range * 0.25).rounded()
            return [lowerLabel, upperLabel]
        }
    }
}

extension Collection {
    subscript(safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
