import Foundation

// MARK: - 自选 / 持仓列表的表头排序（纯函数，`Tools/watch_sort_test.sh` 单测）
//
// 三态循环：**升序 → 降序 → 取消**（取消 = 回到库里的加入顺序，也就是没排过的原样）。
//
// ⚠ 三条口径是这套排序的全部难点，改之前先读完：
//   ① **nil 恒沉底，且不随方向翻转**。换手率 / 振幅 / 量比 / 回本% 是可选值，
//      行情没抓到时是 nil。若按 `?? 0` 参与排序，"没数据"会伪装成"最小值"——
//      升序时整排空值挤在最上面，比不排序更糟。
//   ② **排序值与显示值必须同一个算式**。持仓的市值/盈亏/盈亏率/回本以前只存在于
//      视图侧的字符串格式化里；排序若自己再写一遍算式，两处迟早漂（换了排序值却和
//      屏幕上对不上）。⇒ 算式收口成 `HoldingMetrics`，视图与排序都读它。
//   ③ **判定列有意不可排**。动作词（买入 / 止盈卖出 / 止损卖出 / 清仓卖出 / 持有 /
//      空仓观望 / 观察 / 回避）是分类量不是有序量：`Sem.actionColor` 把"买入"与
//      "止盈卖出"归成同一支红，说明这套词里没有一条自洽的强弱轴。硬造 ordinal
//      就是让读者猜"为什么卖出排在买入后面"⇒ 不给排序键。

/// 持仓派生指标（**唯一算式**：视图显示与表头排序都读它）
public struct HoldingMetrics: Sendable {
    public let marketValue: Double
    /// 相对成本的总盈亏（不是当日盈亏 —— 当日盈亏只在汇总栏按昨收算，两回事）
    public let pnl: Double
    /// 盈亏率（%）；成本额 ≤0 时 0（与显示口径一致）
    public let pnlPct: Double
    /// 回本%：只在"确实亏着"时有值，否则 nil（显示为「—」）
    public let recovery: Double?

    public init(cost: Double, shares: Double, price: Double?) {
        guard let price, shares > 0 else {
            marketValue = 0; pnl = 0; pnlPct = 0; recovery = nil
            return
        }
        let value = price * shares
        let costTotal = cost * shares
        let p = value - costTotal
        marketValue = value
        pnl = p
        pnlPct = costTotal > 0 ? p / costTotal * 100 : 0
        recovery = (p < 0 && price > 0) ? (cost / price - 1) * 100 : nil
    }
}

public enum WatchSortKey: String, CaseIterable, Hashable, Sendable {
    case price, score
    // 行情指标（与视图侧 `WatchColumn` 一一对应）
    case change, changePct, turnoverRate, amplitude, volumeRatio, volume, turnover
    // 持仓专有（与视图侧 `HoldingColumn` 一一对应）
    case costPrice, shares, marketValue, pnl, pnlPct, recovery
}

/// 当前生效的排序（`nil` = 没排，行序 = 库里的加入顺序）
public struct WatchSortState: Equatable {
    public let key: WatchSortKey
    public let ascending: Bool
    public init(key: WatchSortKey, ascending: Bool) {
        self.key = key
        self.ascending = ascending
    }

    /// 点同一列：升 → 降 → 取消；点别的列：直接从那列的升序开始。
    /// ⚠ 口径是老板 2026-10-23 原话「点击表头进行升序，再点倒叙，再点取消」——
    ///   第一下**一律升序**，不给"数值列默认降序"这种自作聪明的例外。
    public static func next(_ current: WatchSortState?, _ tapped: WatchSortKey) -> WatchSortState? {
        guard let c = current, c.key == tapped else { return WatchSortState(key: tapped, ascending: true) }
        return c.ascending ? WatchSortState(key: tapped, ascending: false) : nil
    }
}

public enum WatchSort {
    /// 取排序键的值；nil = 该行该列没有值（沉底，不参与正反序）
    public static func value(row: WatchItemRow, live: StockQuote?, key: WatchSortKey) -> Double? {
        switch key {
        case .price:        return live?.currentPrice
        case .score:        // 库里"没判过"与"判了 0 分"同形（score 缺省 0）⇒ 用 hasAction 区分，
                            // 没判过的沉底，别混进"最低分"
            return row.hasAction ? Double(row.score) : nil
        case .change:       return live?.change
        case .changePct:    return live?.changePercent
        case .turnoverRate: return live?.turnoverRate
        case .amplitude:    return live?.amplitude
        case .volumeRatio:  return live?.volumeRatio
        case .volume:       return live?.volume
        case .turnover:     return live?.turnover
        case .costPrice:    return row.costPrice > 0 ? row.costPrice : nil
        case .shares:       return row.shares > 0 ? row.shares : nil
        case .marketValue, .pnl, .pnlPct, .recovery:
            // 无行情时持仓派生量全都没有（`marketValue` 显示「—」），不能按 0 参与排序
            guard let live else { return nil }
            let m = HoldingMetrics(cost: row.costPrice, shares: row.shares, price: live.currentPrice)
            switch key {
            case .marketValue: return row.shares > 0 ? m.marketValue : nil
            case .pnl:         return row.shares > 0 ? m.pnl : nil
            case .pnlPct:      return row.costPrice > 0 && row.shares > 0 ? m.pnlPct : nil
            case .recovery:    return m.recovery
            default:           return nil
            }
        }
    }

    /// 稳定排序：有值的按方向排，nil 恒沉底。
    /// ⚠ 必须稳定 —— 同分的行要保持原顺序，否则每 5s 轮询刷新时行会自己跳位
    ///   （Swift 的 `sorted` **不保证**稳定，所以显式带上下标做同值裁决）。
    public static func sorted<T>(_ items: [T], by key: WatchSortKey, ascending: Bool,
                                 input: (T) -> (WatchItemRow, StockQuote?)) -> [T] {
        let decorated = items.enumerated().map {
            (order: $0.offset, element: $0.element,
             value: value(row: input($0.element).0, live: input($0.element).1, key: key))
        }
        let withValue = decorated.filter { $0.value != nil }
        let without = decorated.filter { $0.value == nil }
        let ordered = withValue.sorted { a, b in
            let (x, y) = (a.value!, b.value!)
            if x == y { return a.order < b.order }        // 同值 → 原顺序
            return ascending ? x < y : x > y
        }
        return (ordered + without).map(\.element)
    }
}
