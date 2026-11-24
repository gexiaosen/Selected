import Foundation
import SwiftUI

/// 分时折线（2026-09-17 分时形态改造）：价格线 + 均价线（VWAP 黄线）。
///
/// 与蜡烛（`Candles`）的差异：
/// - 数据是**固定时间槽**（全天 240 格，由 App 侧生成）：位置由时间决定、与数据量无关，
///   开盘时只占左侧对应比例、收盘填满——替代旧"分钟点转蜡烛再均分"的错误形态
/// - 空槽（`close<=0`，停牌/未到时间）跳过不画；折线在空槽处断开，
///   下一个有效点重新起线（停牌时段留白，不连线误导）
/// - 均价线读 `CandleData.avgPrice`（App 侧算好 VWAP），nil 则不画
@available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
public struct MinuteLines: Content {
    /// 价格线颜色（主走势线）
    public var priceColor: Color
    /// 均价线颜色（VWAP，A股惯例黄色）
    public var avgColor: Color
    public var lineWidth: CGFloat
    /// 图例文案颜色（价格线用同色）
    public var legendFont: Font

    public init(
        priceColor: Color = .blue,
        avgColor: Color = Color(red: 0.95, green: 0.72, blue: 0.16),
        lineWidth: CGFloat = 1.5,
        legendFont: Font = Font.system(size: 10)
    ) {
        self.priceColor = priceColor
        self.avgColor = avgColor
        self.lineWidth = lineWidth
        self.legendFont = legendFont
    }

    public func calculate(candlesInfo: CandlesInfo) -> CalculatedData {
        // min/max 仅统计有效槽（价格/均价都要参与，Y 轴范围才盖得住两条线）
        var minV = Double.greatestFiniteMagnitude
        var maxV = -Double.greatestFiniteMagnitude
        for item in candlesInfo.visibleData {
            if item.close > 0 {
                minV = min(minV, item.low)
                maxV = max(maxV, item.high)
            }
            if let a = item.avgPrice, a > 0 {
                minV = min(minV, a)
                maxV = max(maxV, a)
            }
        }
        guard minV <= maxV else { return CalculatedData(min: 0, max: 0, values: ()) }
        return CalculatedData(min: minV, max: maxV, values: ())
    }

    public func legend(candlesInfo: CandlesInfo, calculatedData: CalculatedData) -> [Text] {
        // 取最后一个有效点做图例（价格 + 均价）
        let last = candlesInfo.visibleData.last { $0.close > 0 }
        let avg = candlesInfo.visibleData.last { $0.avgPrice != nil }
        var texts: [Text] = []
        if let l = last {
            texts.append(Text(String(format: "价格 %.2f", l.close))
                .font(legendFont).foregroundColor(priceColor))
        }
        if let a = avg?.avgPrice {
            texts.append(Text(String(format: "均价 %.2f", a))
                .font(legendFont).foregroundColor(avgColor))
        }
        return texts
    }

    public func draw(
        contextInfo: ContextInfo,
        candlesInfo: CandlesInfo,
        calculatedData: CalculatedData
    ) {
        let context = contextInfo.context

        // 价格折线：空槽断线重起（停牌/未开盘留白，不误导连线）
        strokePolyline(context: context, contextInfo: contextInfo, candlesInfo: candlesInfo,
                       value: { $0.close > 0 ? $0.close : nil }, color: priceColor)
        // 均价折线
        strokePolyline(context: context, contextInfo: contextInfo, candlesInfo: candlesInfo,
                       value: { $0.avgPrice }, color: avgColor)
    }

    private func strokePolyline(
        context: GraphicsContext,
        contextInfo: ContextInfo,
        candlesInfo: CandlesInfo,
        value: (CandleData) -> Double?,
        color: Color
    ) {
        var path = Path()
        var drawing = false
        for (i, item) in candlesInfo.visibleData.enumerated() {
            guard let v = value(item), v > 0 else {
                drawing = false   // 空槽：断线，下个有效点重新 move
                continue
            }
            let x = contextInfo.xCoordinate(for: i + candlesInfo.startIndex)
            let y = contextInfo.yCoordinate(for: v)
            if drawing {
                path.addLine(to: CGPoint(x: x, y: y))
            } else {
                path.move(to: CGPoint(x: x, y: y))
                drawing = true
            }
        }
        if !path.isEmpty {
            context.stroke(path, with: .color(color), lineWidth: lineWidth)
        }
    }
}
