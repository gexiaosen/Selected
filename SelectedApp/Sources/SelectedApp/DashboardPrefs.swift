import Foundation
import Observation
import SelectedCore

/// 看板指数偏好（UserDefaults，跨窗口共享）。
///
/// 存的是**已选 symbol 的有序数组**（最多 4 个）；看板展示不足 4 个时
/// 由 `DashboardIndexSelection.displayed` 按目录顺序自动补位。
@Observable
@MainActor
final class DashboardPrefs {
    static let shared = DashboardPrefs()
    static let defaultsKey = "dashboard.indices"

    /// 已选指数（有序；不含自动补位）
    private(set) var selected: [String]

    private init() {
        let saved = UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? []
        let normalized = DashboardIndexSelection.normalize(saved)
        selected = normalized.isEmpty ? IndexCatalog.defaultSelected : normalized
        // 存量脏数据（未知 symbol / 重复 / 超过 4 个）顺手归一，避免每次启动都重新算
        if normalized != saved, !saved.isEmpty {
            UserDefaults.standard.set(selected, forKey: Self.defaultsKey)
        }
    }

    /// 已选顺序 + 自动补位后的最终展示（恒 4 个）
    var displayed: [MarketIndex] { DashboardIndexSelection.displayed(selected) }
    var displayedSymbols: [String] { displayed.map(\.symbol) }
    var selectedIndices: [MarketIndex] { selected.compactMap { IndexCatalog.index(for: $0) } }

    /// 还没被选中的目录项（设置页“可选指数”列表）
    var optionalIndices: [MarketIndex] {
        let keys = Set(selected.map { $0.lowercased() })
        return IndexCatalog.all.filter { !keys.contains($0.symbol.lowercased()) }
    }

    /// 自动补位的项（不足 4 个时才有）
    var autoFilled: [MarketIndex] { DashboardIndexSelection.autoFilled(selected) }

    /// - Returns: `nil` = 已应用；非 nil = 拒绝原因（UI 直接弹 toast）
    @discardableResult
    func toggle(_ symbol: String) -> String? {
        let result = DashboardIndexSelection.toggle(symbol, in: selected)
        guard let error = result.error else {
            apply(result.selection)
            return nil
        }
        return error
    }

    func move(_ symbol: String, offset: Int) {
        apply(DashboardIndexSelection.move(symbol, offset: offset, in: selected))
    }

    func move(_ symbol: String, to targetSymbol: String) {
        apply(DashboardIndexSelection.move(symbol, to: targetSymbol, in: selected))
    }

    func reset() {
        apply(IndexCatalog.defaultSelected)
    }

    private func apply(_ next: [String]) {
        let normalized = DashboardIndexSelection.normalize(next)
        let final = normalized.isEmpty ? IndexCatalog.defaultSelected : normalized
        guard final != selected else { return }
        selected = final
        UserDefaults.standard.set(final, forKey: Self.defaultsKey)
    }
}
