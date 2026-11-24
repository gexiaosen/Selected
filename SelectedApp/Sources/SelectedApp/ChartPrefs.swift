import Foundation

/// 详情页副图显示什么：成交量（手）/ 成交额（元）。
///
/// ⚠ 键名只在这里定义一次 —— 设置页与图表读同一个常量，写成两个字面量会漂。
enum ChartSubPlot: String, CaseIterable, Identifiable {
    case volume
    case amount

    var id: String { rawValue }

    var title: String {
        switch self {
        case .volume: return "成交量"
        case .amount: return "成交额"
        }
    }

    static let defaultsKey = "chart.subplot"
}
