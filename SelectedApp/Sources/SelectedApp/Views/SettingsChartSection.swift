import SwiftUI
import SelectedCore

/// 设置 › 显示 › 图表：详情页 K 线 / 分时下方的副图显示成交量还是成交额。
struct ChartSettingsCard: View {

    @AppStorage(ChartSubPlot.defaultsKey) private var subPlotRaw = ChartSubPlot.volume.rawValue

    var body: some View {
        Card("图表", subtitle: "详情页 K 线 / 分时下方的副图") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("副图指标")
                        .font(.callout.bold())
                    Picker("", selection: $subPlotRaw) {
                        ForEach(ChartSubPlot.allCases) { p in
                            Text(p.title).tag(p.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                    Spacer(minLength: 0)
                }
                Text("成交量按「手」，成交额按「元」（显示为万 / 亿）。只改副图的画法，不动行情与判定。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
