import SwiftUI
import SelectedCore

/// 设置 › 显示 › 看板指数：与主页一致的 4 槽位横向排列。
///
/// 规则：
/// · 已选顺序 = 主页展示顺序；拖动卡片直接调整顺序；
/// · 右上角「×」移除后，右侧后续指数自动左移补位；最少保留 1 个；
/// · 空白处保留一个「添加」按钮，从当前未选指数中选一项追加到末尾；
/// · 不足 4 个时，其余空槽由目录顺序自动补位（与 `DashboardIndexSelection.displayed` 同源）。
extension SettingsView {

    private static let tileHeight: CGFloat = 54
    private static let slotSpacing: CGFloat = 8

    var dashboardSettingsCard: some View {
        let prefs = DashboardPrefs.shared
        return Card("看板指数", subtitle: "拖动卡片调整顺序 · 点右上角 × 移除") {
            VStack(alignment: .leading, spacing: 10) {
                horizontalSlotStrip(prefs)
                HStack(spacing: 8) {
                    Text("已选 \(prefs.selected.count)/\(IndexCatalog.visibleCount) · 最少保留 1 个；"
                         + "不足 \(IndexCatalog.visibleCount) 个时按目录顺序自动补位")
                        .font(AppFont.detail)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("恢复默认") { prefs.reset() }
                        .btnSecondary()
                        .controlSize(.small)
                        .disabled(prefs.selected == IndexCatalog.defaultSelected)
                }
                Text("看板进入时默认展示当天；手动选日期后不覆盖。周末回落到最近有数据日。")
                    .font(AppFont.detail)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 横向四槽位

    private func horizontalSlotStrip(_ prefs: DashboardPrefs) -> some View {
        let selected = prefs.selectedIndices
        let autoFilled = prefs.autoFilled
        return HStack(alignment: .top, spacing: Self.slotSpacing) {
            ForEach(selected) { idx in
                selectedTile(prefs, idx, canRemove: selected.count > 1)
            }
            if selected.count < IndexCatalog.visibleCount {
                addSlotTile(prefs, autoFill: autoFilled.first)
                ForEach(Array(autoFilled.dropFirst()), id: \.symbol) { fill in
                    autoFillPlaceholderTile(fill)
                }
            }
        }
        .coordinateSpace(name: "indexStrip")
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { w in
            if w > 0 { indexStripWidth = w }
        }
    }

    private func selectedTile(_ prefs: DashboardPrefs, _ idx: MarketIndex, canRemove: Bool) -> some View {
        let isDragging = draggingIndexSymbol == idx.symbol
        return ZStack(alignment: .topTrailing) {
            VStack(alignment: .center, spacing: 2) {
                Text(idx.name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text(idx.symbol)
                    .font(AppFont.numeric(AppFont.detail))
                    .foregroundStyle(Tok.labelSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: Self.tileHeight, maxHeight: Self.tileHeight)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isDragging ? Tok.tint(Sem.brand, .chip) : Tok.row)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isDragging ? Sem.brand : Tok.stroke, lineWidth: isDragging ? 1 : 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .gesture(
                DragGesture(minimumDistance: 6, coordinateSpace: .named("indexStrip"))
                    .onChanged { value in
                        handleDragChanged(prefs: prefs, symbol: idx.symbol, value: value)
                    }
                    .onEnded { _ in
                        endDrag()
                    }
            )

            Button {
                remove(prefs, idx)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .btnIcon(Tok.labelSecondary)
            .padding(3)
            .disabled(!canRemove)
            .opacity(canRemove ? 1 : 0.35)
            .help(canRemove ? "移除 \(idx.name)" : "至少保留 1 个指数")
        }
        .frame(maxWidth: .infinity, minHeight: Self.tileHeight, maxHeight: Self.tileHeight)
        .offset(x: isDragging ? draggingIndexOffsetX : 0)
        .scaleEffect(isDragging ? 1.03 : 1.0)
        .shadow(color: isDragging ? Tok.shadow : .clear, radius: isDragging ? 8 : 0, y: isDragging ? 4 : 0)
        .zIndex(isDragging ? 10 : 0)
        // 被拖卡片本身紧跟指针、不做位移延迟；其余卡片在排序变化时平滑补位
        .motionAware(Mot.swap, value: isDragging ? [] : prefs.selected)
        .motionAware(Mot.hover, value: isDragging)
        .help("拖动调整展示顺序")
    }

    private func handleDragChanged(prefs: DashboardPrefs, symbol: String, value: DragGesture.Value) {
        let count = prefs.selected.count
        guard count > 1 else { return }

        let totalGap = Self.slotSpacing * CGFloat(IndexCatalog.visibleCount - 1)
        let slotW = max(60, (indexStripWidth - totalGap) / CGFloat(IndexCatalog.visibleCount))
        let step = slotW + Self.slotSpacing
        func centerX(_ slot: Int) -> CGFloat {
            (CGFloat(slot) + 0.5) * slotW + CGFloat(slot) * Self.slotSpacing
        }

        if draggingIndexSymbol == nil {
            guard let start = prefs.selected.firstIndex(of: symbol) else { return }
            draggingIndexSymbol = symbol
            dragStartSlot = start
            dragStartLocationX = value.startLocation.x
        }
        guard draggingIndexSymbol == symbol,
              var curSlot = prefs.selected.firstIndex(of: symbol) else { return }

        let grabDelta = dragStartLocationX - centerX(dragStartSlot)
        let minCenter = centerX(0) - 6
        let maxCenter = centerX(count - 1) + 6
        let desiredCenter = min(max(value.location.x - grabDelta, minCenter), maxCenter)

        let threshold = step * 0.52
        if curSlot + 1 < count, desiredCenter > centerX(curSlot) + threshold {
            let targetSymbol = prefs.selected[curSlot + 1]
            prefs.move(symbol, to: targetSymbol)
            curSlot += 1
        } else if curSlot - 1 >= 0, desiredCenter < centerX(curSlot) - threshold {
            let targetSymbol = prefs.selected[curSlot - 1]
            prefs.move(symbol, to: targetSymbol)
            curSlot -= 1
        }

        draggingIndexOffsetX = desiredCenter - centerX(curSlot)
    }

    private func endDrag() {
        draggingIndexSymbol = nil
        draggingIndexOffsetX = 0
    }

    private func addSlotTile(_ prefs: DashboardPrefs, autoFill: MarketIndex?) -> some View {
        Menu {
            ForEach(prefs.optionalIndices) { idx in
                Button("\(idx.name)  \(idx.symbol)") { add(prefs, idx) }
            }
        } label: {
            VStack(spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: "plus.circle")
                        .font(.caption)
                        .foregroundStyle(Sem.brand)
                    Text("添加指数")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Tok.label)
                }
                if let autoFill {
                    Text("默认补位: \(autoFill.shortName)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, minHeight: Self.tileHeight, maxHeight: Self.tileHeight)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .disabled(prefs.optionalIndices.isEmpty)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Tok.sunken))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Tok.stroke, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
        .help("选择一个未选中的指数添加到看板")
    }

    private func autoFillPlaceholderTile(_ idx: MarketIndex) -> some View {
        VStack(spacing: 2) {
            Text(idx.name)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Text("自动补位")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, minHeight: Self.tileHeight, maxHeight: Self.tileHeight)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Tok.sunken))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Tok.stroke, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
        .help("不足 \(IndexCatalog.visibleCount) 个时将由 \(idx.name) 自动补位")
    }

    // MARK: - 动作

    private func add(_ prefs: DashboardPrefs, _ idx: MarketIndex) {
        if let error = prefs.toggle(idx.symbol) {
            ToastCenter.shared.show(error, style: .warning)
        }
    }

    private func remove(_ prefs: DashboardPrefs, _ idx: MarketIndex) {
        if let error = prefs.toggle(idx.symbol) {
            ToastCenter.shared.show(error, style: .warning)
        }
    }
}
