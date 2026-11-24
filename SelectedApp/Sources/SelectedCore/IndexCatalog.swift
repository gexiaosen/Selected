import Foundation

/// 看板可配置的指数。
///
/// `symbol` 用引擎/行情层既有写法（`sh000001`），与 `StockQuotes` 的前缀规则同源；
/// `name` 是展示名，`shortName` 只给空间很窄的图例/胶囊用。
public struct MarketIndex: Identifiable, Equatable, Sendable {
    public let symbol: String
    public let name: String
    public let shortName: String

    public var id: String { symbol }

    public init(symbol: String, name: String, shortName: String) {
        self.symbol = symbol
        self.name = name
        self.shortName = shortName
    }
}

/// 看板指数目录 + 展示选择规则（纯数据/纯函数，可单测）。
///
/// 规则（产品口径）：
/// · 看板恒展示 **4** 个指数；
/// · 用户选中的指数按选择顺序排在前面；
/// · 不足 4 个时，未选中的指数按**目录顺序**自动补位；
/// · 最多选 4 个，第 5 个由 UI 拒绝。
public enum IndexCatalog {
    /// 看板固定展示槽位
    public static let visibleCount = 4

    /// 目录顺序 = 自动补位顺序。
    ///
    /// ⚠ 前 4 个是出厂默认；改这里等于改所有新用户的首屏，
    ///   存量用户已存的 `selected` 不受影响（见 `DashboardIndexSelection.displayed`）。
    public static let all: [MarketIndex] = [
        MarketIndex(symbol: "sh000001", name: "上证指数", shortName: "上证"),
        MarketIndex(symbol: "sz399001", name: "深证成指", shortName: "深证"),
        MarketIndex(symbol: "sh000688", name: "科创50", shortName: "科创50"),
        MarketIndex(symbol: "sh000510", name: "中证A500", shortName: "中证A500"),
        MarketIndex(symbol: "sh000300", name: "沪深300", shortName: "沪深300"),
        MarketIndex(symbol: "sh000905", name: "中证500", shortName: "中证500"),
        MarketIndex(symbol: "sh000852", name: "中证1000", shortName: "中证1000"),
        MarketIndex(symbol: "sz399006", name: "创业板指", shortName: "创业板"),
        MarketIndex(symbol: "sh000680", name: "科创综指", shortName: "科创综"),
    ]

    public static let defaultSelected: [String] = Array(all.prefix(visibleCount)).map(\.symbol)

    /// 按 symbol 查目录项；未知 symbol → nil（存量脏数据用）。
    public static func index(for symbol: String) -> MarketIndex? {
        let key = symbol.lowercased()
        return all.first { $0.symbol.lowercased() == key }
    }
}

/// 选择/排序/补位的**纯函数**。
///
/// 与 UI 解耦：设置页只负责把用户动作翻译成 `[String]`，补位规则在这里唯一实现。
public enum DashboardIndexSelection {

    /// 过滤未知 symbol、去重、保持顺序、截断到 `visibleCount`。
    public static func normalize(_ symbols: [String], max: Int = IndexCatalog.visibleCount) -> [String] {
        guard max > 0 else { return [] }
        var seen = Set<String>()
        var out: [String] = []
        for raw in symbols {
            guard let idx = IndexCatalog.index(for: raw) else { continue }
            let key = idx.symbol.lowercased()
            guard seen.insert(key).inserted else { continue }
            out.append(idx.symbol)
            if out.count == max { break }
        }
        return out
    }

    /// 最终展示的 4 个：已选顺序 + 目录顺序自动补位。
    ///
    /// - Parameter selected: 用户选择（允许乱序/含未知项/少于或多于 4 个）
    /// - Returns: 恰好 `visibleCount` 个；目录本身不足时按实际数量返回。
    public static func displayed(_ selected: [String],
                                 max: Int = IndexCatalog.visibleCount) -> [MarketIndex] {
        guard max > 0 else { return [] }
        let chosen = normalize(selected, max: max)
        let chosenKeys = Set(chosen.map { $0.lowercased() })
        var out = chosen.compactMap { IndexCatalog.index(for: $0) }
        guard out.count < max else { return Array(out.prefix(max)) }
        for idx in IndexCatalog.all where !chosenKeys.contains(idx.symbol.lowercased()) {
            out.append(idx)
            if out.count == max { break }
        }
        return out
    }

    /// 切换一个指数；返回 `nil` = 已应用，非 nil = 被拒绝的原因。
    ///
    /// - 已选 → 取消（至少保留 1 个）
    /// - 未选 → 追加（最多 4 个）
    public static func toggle(_ symbol: String, in selected: [String]) -> (selection: [String], error: String?) {
        let current = normalize(selected)
        guard let idx = IndexCatalog.index(for: symbol) else {
            return (current, "未知指数：\(symbol)")
        }
        if let at = current.firstIndex(where: { $0.caseInsensitiveCompare(idx.symbol) == .orderedSame }) {
            guard current.count > 1 else {
                return (current, "至少保留 1 个指数")
            }
            var next = current
            next.remove(at: at)
            return (next, nil)
        }
        guard current.count < IndexCatalog.visibleCount else {
            return (current, "最多展示 \(IndexCatalog.visibleCount) 个指数，先取消一个再添加")
        }
        return (current + [idx.symbol], nil)
    }

    /// 在已选列表内上移/下移（`offset` = -1 / +1）。越界不做任何事。
    public static func move(_ symbol: String, offset: Int, in selected: [String]) -> [String] {
        var current = normalize(selected)
        guard let at = current.firstIndex(where: { $0.caseInsensitiveCompare(symbol) == .orderedSame })
        else { return current }
        let target = at + offset
        guard target >= 0, target < current.count, offset != 0 else { return current }
        current.swapAt(at, target)
        return current
    }

    /// 拖动重排：将 `symbol` 移动到当前占据 `targetSymbol` 的位置，中间项顺次平移。
    public static func move(_ symbol: String, to targetSymbol: String, in selected: [String]) -> [String] {
        var current = normalize(selected)
        guard let from = current.firstIndex(where: { $0.caseInsensitiveCompare(symbol) == .orderedSame }),
              let to = current.firstIndex(where: { $0.caseInsensitiveCompare(targetSymbol) == .orderedSame }),
              from != to
        else { return current }
        let item = current.remove(at: from)
        current.insert(item, at: to)
        return current
    }

    /// 自动补位的指数（已选之外的目录前几项）—— 设置页预览用。
    public static func autoFilled(_ selected: [String],
                                  max: Int = IndexCatalog.visibleCount) -> [MarketIndex] {
        let chosen = normalize(selected, max: max)
        guard chosen.count < max else { return [] }
        return Array(displayed(chosen, max: max).dropFirst(chosen.count))
    }
}
