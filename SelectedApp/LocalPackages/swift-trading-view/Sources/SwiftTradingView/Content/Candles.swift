import Foundation
import SwiftUI

@available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
public struct Candles: Content {
    public var negativeCandleColor: Color
    public var positiveCandleColor: Color

    public init(
        negativeCandleColor: Color = Color.red,
        positiveCandleColor: Color = Color.green
    ) {
        self.negativeCandleColor = negativeCandleColor
        self.positiveCandleColor = positiveCandleColor
    }

    public func calculate(candlesInfo: CandlesInfo) -> CalculatedData {
        let (minLow, maxHigh) = candlesInfo.visibleData.reduce((Double.greatestFiniteMagnitude, Double.zero)) { result, item in
            (min(result.0, item.low), max(result.1, item.high))
        }
        return CalculatedData(
            min: minLow,
            max: maxHigh,
            values: []
        )
    }

    public func legend(candlesInfo: CandlesInfo, calculatedData: CalculatedData) -> [Text] {
        return []
    }

    public func draw(
        contextInfo: ContextInfo,
        candlesInfo: CandlesInfo,
        calculatedData: CalculatedData
    ) {
        let context = contextInfo.context
        let candleWidth = contextInfo.candleWidth

        // 按涨/跌**聚合路径**（2026-09-20，审计 P1-20）。
        //
        // 原先每根 K 线各建 2 个 `Path` 并各调一次 `stroke`/`fill`：
        // 500 根可见 = 1000 次 Path 分配 + 1000 次 draw call，**而且每帧都要重来**
        // （滚动/缩放时 `scrollOffset` 每帧变化 → Canvas 重绘）。
        // 现在只建 4 条聚合路径（涨/跌 × 影线/实体），draw call 从 O(根数) 降到 O(1)。
        //
        // 视觉等价性：影线是同一 x 上的竖直线段、实体是不重叠矩形，
        // 聚合后一次 `stroke` / 一次 `fill` 与逐根绘制结果一致（非零环绕填充规则下无差）；
        // 颜色仍按每根自己的涨跌分别进两条路径，不引入串色。
        //
        // ⚠ 未一并打开 `Canvas(rendersAsynchronously:)`：滚动时 `scrollOffset` 每帧变化，
        //   异步渲染可能落后一帧造成撕裂；本次先做零风险的聚合，异步渲染另行评估。
        var upWicks = Path(), downWicks = Path()
        var upBodies = Path(), downBodies = Path()

        for (index, item) in candlesInfo.visibleData.enumerated() {
            let x = contextInfo.xCoordinate(for: index + candlesInfo.startIndex)

            // Calculate candle positions from the top
            let candleTop = contextInfo.yCoordinate(for: item.high)
            let candleBottom = contextInfo.yCoordinate(for: item.low)
            let bodyTop = contextInfo.yCoordinate(for: max(item.open, item.close))
            let bodyBottom = contextInfo.yCoordinate(for: min(item.open, item.close))

            let body = CGRect(x: x - candleWidth / 2, y: bodyTop,
                              width: candleWidth, height: bodyBottom - bodyTop)

            if item.open > item.close {
                downWicks.move(to: CGPoint(x: x, y: candleTop))
                downWicks.addLine(to: CGPoint(x: x, y: candleBottom))
                downBodies.addRect(body)
            } else {
                upWicks.move(to: CGPoint(x: x, y: candleTop))
                upWicks.addLine(to: CGPoint(x: x, y: candleBottom))
                upBodies.addRect(body)
            }
        }

        context.stroke(downWicks, with: .color(negativeCandleColor), lineWidth: 1)
        context.stroke(upWicks, with: .color(positiveCandleColor), lineWidth: 1)
        context.fill(downBodies, with: .color(negativeCandleColor))
        context.fill(upBodies, with: .color(positiveCandleColor))
    }
}
