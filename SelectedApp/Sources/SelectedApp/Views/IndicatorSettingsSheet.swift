import SwiftUI
import SelectedCore

// MARK: - 指标筛选设置（B 域参数编辑）

/// 筛选页齿轮入口的全量设置面板：三段（判据阈值 / 指标周期 / 超买超卖线）。
///
/// ## 为什么在这里而不是参数中心
/// 这些参数**不进打分**（域纪律见 `IndicatorParamSpec` 头注）：改它们不产生选股
/// 参数版本、不进调优空间。放在筛选页里"就地改、就地看效果"，与选股参数彻底解耦。
///
/// ## 交互
///   · 每行 = 中文名 + 数值控件（spec 的 min/max/step）+ 「默认」灰字标注 + 恢复默认；
///   · **改即落库**（`IndicatorParamStore.set`，留变更流水），无"保存"按钮 ——
///     阈值类即时生效；**周期类改动在关闭面板时触发一次快照重算**（全市场分钟级，
///     不做每改一下重算一次）；
///   · 底部展示最近变更流水（可回看"什么时候把什么改成了什么"）。
struct IndicatorSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    private let store = Store.shared

    /// 当前生效值（`.task` 载入；body 不查库）
    @State private var values: [String: Double] = [:]
    /// 本次会话里是否改过周期（关闭时决定是否触发重算）
    @State private var periodChanged = false
    /// 超买超卖线（只影响个股详情页）默认折叠，避免和本页筛选参数混在一起
    @State private var showOsc = false
    @State private var history: [IndicatorParamStore.Change] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("指标筛选设置").font(.title3.weight(.medium))
                Text("判据阈值即时生效 · 周期改动需重算快照 · 不进选股参数版本")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("完成") { close() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    section(.screen)
                    section(.period)
                    section(.osc)
                    historySection
                }
                .padding(16)
            }
        }
        .frame(width: SheetMetrics.indicatorSettings.width,
               height: SheetMetrics.indicatorSettings.height)
        .task { reload() }
    }

    private func reload() {
        var v: [String: Double] = [:]
        for e in IndicatorParamSpec.all {
            v[e.key] = IndicatorParamStore.effective(key: e.key) ?? e.defaultValue
        }
        values = v
        history = IndicatorParamStore.history(limit: 10)
    }

    private func close() {
        if periodChanged {
            if store.isHistorical {
                // 历史快照不重算（今日 bar 只能由当日收盘行情合成）——不弹"不可重算"的报错，
                // 直接把生效时机说清楚
                ToastCenter.shared.show("周期已保存；历史快照不重算，回到最新交易日后生效",
                                        style: .warning)
            } else {
                store.refreshIndicatorSnapshot()
            }
        }
        dismiss()
    }

    // MARK: 分组

    @ViewBuilder
    private func section(_ group: IndicatorParamSpec.Group) -> some View {
        Card(group.rawValue) {
            VStack(alignment: .leading, spacing: 10) {
                if group == .period {
                    Text(store.isHistorical
                         ? "历史日不重算快照：周期改动回到最新交易日后才生效"
                         : "周期改动会在关闭本面板后重算全市场快照（约 1 分钟）")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if group == .osc {
                    DisclosureGroup(isExpanded: $showOsc) {
                        VStack(alignment: .leading, spacing: 10) {
                            ownerBlocks(group)
                        }
                        .padding(.top, 8)
                    } label: {
                        Text("\(IndicatorParamSpec.entries(group: .osc).count) 项 · 仅影响个股详情页的 Zone 判读，不影响本页筛选")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    ownerBlocks(group)
                }
            }
            .padding(.top, 4)
        }
    }

    private func ownerBlocks(_ group: IndicatorParamSpec.Group) -> some View {
        ForEach(ownedRows(group), id: \.owner) { block in
            VStack(alignment: .leading, spacing: 6) {
                Text(block.owner).font(.caption.weight(.medium))
                ForEach(block.entries, id: \.key) { entryRow($0) }
            }
        }
    }

    /// 组内按 owner（指标名）聚块，保持 spec 声明顺序
    private func ownedRows(_ group: IndicatorParamSpec.Group) -> [(owner: String, entries: [IndicatorParamSpec.Entry])] {
        var order: [String] = []
        var map: [String: [IndicatorParamSpec.Entry]] = [:]
        for e in IndicatorParamSpec.entries(group: group) {
            if map[e.owner] == nil { order.append(e.owner) }
            map[e.owner, default: []].append(e)
        }
        return order.map { (owner: $0, entries: map[$0] ?? []) }
    }

    // MARK: 单行

    private func entryRow(_ e: IndicatorParamSpec.Entry) -> some View {
        let current = values[e.key] ?? e.defaultValue
        let isDefault = abs(current - e.defaultValue) < 1e-9
        return HStack(spacing: 8) {
            Text(e.label)
                .font(.caption).frame(width: 132, alignment: .leading)
            if !isDefault {
                Circle().fill(Sem.brand).frame(width: 6, height: 6)
                    .help("已改（默认 \(fmt(e.defaultValue, e))）")
            }
            Stepper(value: Binding(
                get: { current },
                set: { newValue in update(e, newValue) }
            ), in: e.min...e.max, step: e.step) {
                Text(fmt(current, e))
                    .font(AppFont.numeric(.caption))
                    .frame(width: 64, alignment: .trailing)
            }
            .fixedSize()
            Text("默认 \(fmt(e.defaultValue, e))")
                .font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if !isDefault {
                Button("恢复") { resetEntry(e) }
                    .buttonStyle(.plain)
                    .font(AppFont.detail).foregroundStyle(Sem.brand)
            }
        }
    }

    private func fmt(_ v: Double, _ e: IndicatorParamSpec.Entry) -> String {
        e.isInt ? String(format: "%.0f", v) : String(format: "%g", v)
    }

    private func update(_ e: IndicatorParamSpec.Entry, _ newValue: Double) {
        values[e.key] = newValue
        do {
            try IndicatorParamStore.set(key: e.key, value: newValue, source: "ui")
            if e.key.hasPrefix("period.") { periodChanged = true }
            history = IndicatorParamStore.history(limit: 10)
        } catch {
            ToastCenter.shared.show("参数保存失败：\(e.label)（\((error as? LocalizedError)?.errorDescription ?? "?")）",
                                    style: .error)
            reload()
        }
    }

    private func resetEntry(_ e: IndicatorParamSpec.Entry) {
        do {
            try IndicatorParamStore.reset(key: e.key, source: "ui")
            if e.key.hasPrefix("period.") { periodChanged = true }
            reload()
        } catch {
            ToastCenter.shared.show("恢复默认失败：\(e.label)", style: .error)
        }
    }

    // MARK: 流水

    private var historySection: some View {
        Card("最近变更") {
            VStack(alignment: .leading, spacing: 4) {
                if history.isEmpty {
                    Text("还没有改过任何参数").font(.caption).foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else {
                    ForEach(Array(history.enumerated()), id: \.offset) { _, ch in
                        HStack(spacing: 6) {
                            Text(ch.ts.suffix(14))
                                .font(AppFont.numeric(.caption)).foregroundStyle(.secondary)
                            Text(IndicatorParamSpec.entry(key: ch.key)?.label ?? ch.key)
                                .font(AppFont.detail)
                            Text("\(ch.oldValue.map { String(format: "%g", $0) } ?? "默认") → \(String(format: "%g", ch.newValue))")
                                .font(AppFont.numeric(AppFont.detail)).foregroundStyle(.secondary)
                            Spacer()
                        }
                    }
                }
            }
            .padding(.top, 4)
        }
    }
}

#Preview("指标筛选设置（真实库 · 禁网络）") {
    Store.shared.previewMode = true
    return IndicatorSettingsSheet()
}
