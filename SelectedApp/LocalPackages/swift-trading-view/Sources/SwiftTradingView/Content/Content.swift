import Foundation
import SwiftUI

/// Defines the core functionality for technical analysis indicators.
///
/// This protocol outlines the methods required to calculate, display, and draw
/// technical indicators on a financial chart. Types conforming to this protocol
/// can be used as primary content in chart visualizations.
@available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
public protocol Content {
    /// Calculates the indicator values based on the provided candle data.
    ///
    /// This method should perform the necessary calculations to derive the
    /// indicator values from the given candle data.
    ///
    /// - Parameter candlesInfo: Information about the candles, including the full dataset and visible range.
    /// - Returns: A `CalculatedData` instance containing the results of the calculation.
    func calculate(candlesInfo: CandlesInfo) -> CalculatedData

    /// Generates legend items for the indicator.
    ///
    /// This method should create text elements to be displayed in the chart legend,
    /// typically showing current values or other relevant information about the indicator.
    ///
    /// - Parameters:
    ///   - candlesInfo: Information about the candles, including the full dataset and visible range.
    ///   - calculatedData: The data calculated by the `calculate` method.
    /// - Returns: An array of `Text` views to be displayed in the legend.
    func legend(candlesInfo: CandlesInfo, calculatedData: CalculatedData) -> [Text]

    /// Draws the indicator on the provided graphics context.
    ///
    /// This method is responsible for rendering the visual representation of the indicator
    /// on the chart. It should use the provided context information to properly scale and
    /// position the indicator elements.
    ///
    /// - Parameters:
    ///   - contextInfo: Information about the graphics context and chart dimensions.
    ///   - candlesInfo: Information about the candles, including the full dataset and visible range.
    ///   - calculatedData: The data calculated by the `calculate` method.
    func draw(
        contextInfo: ContextInfo,
        candlesInfo: CandlesInfo,
        calculatedData: CalculatedData
    )

    /// Y 轴刻度（供独立 Y 轴列渲染，2026-09-17 方案 B）。
    ///
    /// 返回 (数值, 格式化文本)；位置由 Y 轴列按 yBounds 真实映射，保证上下顺序正确。
    /// 不需要刻度的指标返回空数组（默认实现）。刻度绘制已从指标自身 draw 中移出
    /// ——在指标内绘制会跟随滚动内容跑，缩放时漂移到图表中间。
    ///
    /// - Parameters:
    ///   - candlesInfo: Information about the candles, including the full dataset and visible range.
    ///   - calculatedData: The data calculated by the `calculate` method.
    /// - Returns: An array of (value, formatted label) pairs for the y-axis column.
    func yAxisLabels(candlesInfo: CandlesInfo, calculatedData: CalculatedData) -> [(value: Double, text: String)]
}

@available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
extension Content {
    /// 默认无刻度：仅成交量等需要量纲标注的指标实现此方法
    public func yAxisLabels(candlesInfo: CandlesInfo, calculatedData: CalculatedData) -> [(value: Double, text: String)] { [] }
}
