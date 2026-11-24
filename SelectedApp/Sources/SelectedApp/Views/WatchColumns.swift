import SwiftUI
import SwiftTradingView
import SelectedCore

// MARK: - 自选列表可选指标列（表头可编辑）

/// 列宽固定保证表头与数据行严格对齐；涨跌类随行情红绿。
/// 可选范围参考同花顺：涨跌额/涨跌幅/换手率/振幅/量比/成交量/成交额
/// （委比、涨速无免费行情源，不提供——不造假数据）
enum WatchColumn: String, CaseIterable, Identifiable {
    case change      // 涨跌额
    case changePct   // 涨跌幅
    case turnoverRate // 换手率
    case amplitude   // 振幅
    case volumeRatio // 量比
    case volume      // 成交量
    case turnover    // 成交额

    var id: String { rawValue }

    /// 表头排序键（**唯一出口**）：nil = 这列不给排序。
    /// ⚠ 新增列必须在这里表态 —— switch 穷尽，漏了编译不过。
    var sortKey: WatchSortKey? {
        switch self {
        case .change: return .change
        case .changePct: return .changePct
        case .turnoverRate: return .turnoverRate
        case .amplitude: return .amplitude
        case .volumeRatio: return .volumeRatio
        case .volume: return .volume
        case .turnover: return .turnover
        }
    }

    /// 对齐（表头与数据行**必须**都从这里取，不许在调用点各写一份）：
    /// 指标列全是数值 ⇒ 一律右对齐，位数才对得上。
    var alignment: Alignment { .trailing }

    var title: String {
        switch self {
        case .change: return "涨跌额"
        case .changePct: return "涨跌幅"
        case .turnoverRate: return "换手率"
        case .amplitude: return "振幅"
        case .volumeRatio: return "量比"
        case .volume: return "成交量"
        case .turnover: return "成交额"
        }
    }

    /// 列宽（标题与数据行共用，右对齐）。
    /// 需要的最小宽度（文本不截断）；总宽超出可用空间时由列表统一按比例压缩
    ///（与三轮对比段同策略：fixedSize 锁定内容 + minimumScaleFactor 防换行，
    /// 绝不允许压缩到换行/错位）
    var width: CGFloat {
        switch self {
        case .change: return 72
        case .changePct: return 74
        case .turnoverRate: return 64
        case .amplitude: return 64
        case .volumeRatio: return 60
        case .volume: return 76
        case .turnover: return 78
        }
    }

    /// 从实时行情取值（无行情/无字段显示 "—"）
    func text(_ q: StockQuote?) -> String {
        guard let q else { return "—" }
        switch self {
        case .change: return StockFmt.signedPrice(q.change, code: q.code)
        case .changePct: return String(format: "%+.2f%%", q.changePercent)
        case .turnoverRate: return q.turnoverRate.map { String(format: "%.2f%%", $0) } ?? "—"
        case .amplitude: return q.amplitude.map { String(format: "%.2f%%", $0) } ?? "—"
        case .volumeRatio: return q.volumeRatio.map { String(format: "%.2f", $0) } ?? "—"
        case .volume: return StockFmt.volume(q.volume)
        case .turnover: return StockFmt.turnover(q.turnover)
        }
    }

    /// 涨跌类随行情红绿（A股红涨绿跌）；中性指标用主色
    func color(_ q: StockQuote?) -> Color {
        guard let q else { return .secondary }
        switch self {
        case .change, .changePct: return Sem.pnl(q.changePercent)
        default: return .primary
        }
    }
}

// MARK: - 选股结果页的列（数据源是 ScanPick，不是 StockQuote）

extension WatchColumn {
    /// 选股结果页能用的列 —— **只含 `ScanPick` 真有的字段**。
    ///
    /// ⚠⚠ **命名撞车，映射时必须逐个核对**（本扩展最容易出错的地方）：
    ///   · `WatchColumn.turnover` = **成交额**（万元）→ 对应 `ScanPick.amount`
    ///   · `ScanPick.turnover`    = **换手率**（%）  → 对应 `WatchColumn.turnoverRate`
    ///   —— 两个类型里 `turnover` 含义**相反**，绝不能按名字直连。
    ///
    /// ⚠ **不在本列表里的两个是有意排除，不是遗漏**：
    ///   · `.change`（涨跌额）：`picks` 表没存，且**不许自算** —— 项目契约是
    ///     "涨跌额来源缺失必须回落 0，不许用「现价−昨收」反推"（反推在除权日会给出错误数字）
    ///   · `.volume`（成交量）：`picks` 表只存 `amount`（成交额），没存股数
    static let scanResultColumns: [WatchColumn] = [
        .changePct, .turnoverRate, .amplitude, .volumeRatio, .turnover,
    ]

    /// 从**选股结果**取值（格式与 `text(_ q: StockQuote?)` 对齐，两页视觉一致）
    func text(pick: ScanPick) -> String {
        switch self {
        case .changePct:    return String(format: "%+.2f%%", pick.changePct)
        // ⚠ ScanPick.turnover 是**换手率**（见上方命名撞车说明）
        case .turnoverRate: return String(format: "%.2f%%", pick.turnover)
        case .amplitude:    return String(format: "%.2f%%", pick.amplitude)
        case .volumeRatio:  return String(format: "%.2f", pick.volumeRatio)
        // ⚠ ScanPick.amount 才是**成交额**
        case .turnover:     return StockFmt.turnover(pick.amount)
        case .change, .volume:
            // 不支持的列（见 scanResultColumns 的说明）—— 显示占位，不编一个数出来
            return "—"
        }
    }

    /// 涨跌类随行情红绿（A股红涨绿跌）；其余中性
    func color(pick: ScanPick) -> Color {
        switch self {
        case .changePct: return Sem.pnl(pick.changePct)
        default:         return .primary
        }
    }
}

// MARK: - 持仓页可选指标列（自选指标 + 持仓专属）

/// 持仓页列 = 自选 7 指标列 + 持仓 6 专属列，共 13 个可选项。
/// 自选列复用 WatchColumn 的 text/color；持仓列独立实现。
enum HoldingColumn: String, CaseIterable, Identifiable {
    // 自选指标列（与 WatchColumn.allCases 同序）
    case change, changePct, turnoverRate, amplitude, volumeRatio, volume, turnover
    // 持仓专属列
    case costPrice    // 成本价
    case shares       // 持仓量
    case marketValue  // 市值
    case pnl          // 盈亏
    case pnlPct       // 盈亏率
    case recovery     // 回本%

    var id: String { rawValue }

    /// 表头排序键（唯一出口，理由同 `WatchColumn.sortKey`）
    var sortKey: WatchSortKey? {
        switch self {
        case .change: return .change
        case .changePct: return .changePct
        case .turnoverRate: return .turnoverRate
        case .amplitude: return .amplitude
        case .volumeRatio: return .volumeRatio
        case .volume: return .volume
        case .turnover: return .turnover
        case .costPrice: return .costPrice
        case .shares: return .shares
        case .marketValue: return .marketValue
        case .pnl: return .pnl
        case .pnlPct: return .pnlPct
        case .recovery: return .recovery
        }
    }

    /// 对齐：同 `WatchColumn.alignment`，指标列一律右对齐
    var alignment: Alignment { .trailing }

    var title: String {
        switch self {
        case .change: return "涨跌额"
        case .changePct: return "涨跌幅"
        case .turnoverRate: return "换手率"
        case .amplitude: return "振幅"
        case .volumeRatio: return "量比"
        case .volume: return "成交量"
        case .turnover: return "成交额"
        case .costPrice: return "成本价"
        case .shares: return "持仓量"
        case .marketValue: return "市值"
        case .pnl: return "盈亏"
        case .pnlPct: return "盈亏率"
        case .recovery: return "回本%"
        }
    }

    var width: CGFloat {
        switch self {
        case .change: return 72
        case .changePct: return 74
        case .turnoverRate: return 64
        case .amplitude: return 64
        case .volumeRatio: return 60
        case .volume: return 76
        case .turnover: return 78
        case .costPrice: return 70
        case .shares: return 72
        case .marketValue: return 78
        case .pnl: return 74
        case .pnlPct: return 76
        case .recovery: return 64
        }
    }

    /// 对应的 WatchColumn（自选列复用其 text/color）
    private var watchColumn: WatchColumn? { WatchColumn(rawValue: rawValue) }

    func text(item: WatchItemRow, live: StockQuote?) -> String {
        if let wc = watchColumn { return wc.text(live) }
        let cost = item.costPrice
        let sh = item.shares
        // 成本价/持仓量无需行情
        // ⚠ 成本价**必须 3 位小数**：摊薄成本与 ETF 净值本来就是 3 位
        //   （实测持仓 `159338 = 1.249`、`600276 = 55.879`）。用 `%.2f` 显示的是错的值。
        switch self {
        case .costPrice: return StockFmt.costPrice(cost)
        case .shares: return sh > 0 ? Self.fmtShares(sh) : "—"
        default: break
        }
        guard let live else { return "—" }
        // ⚠ 派生量一律走 `HoldingMetrics`（Core）—— 表头排序读的是同一份算式，
        //   在这里再写一遍就会与排序值漂（显示 3.21% / 按 3.2% 排）。
        let m = HoldingMetrics(cost: cost, shares: sh, price: live.currentPrice)
        let (value, p, pPct, rec) = (m.marketValue, m.pnl, m.pnlPct, m.recovery)
        // ⚠ 市值/盈亏走 `StockFmt.money`（≤3 位小数、去尾随零、**不取整**）——
        //   必须与"3 位小数的成本价 × 数量"对得上，取整到元/百元精度都会对不上。
        switch self {
        case .marketValue: return StockFmt.money(value)
        case .pnl: return StockFmt.signedMoney(p)
        case .pnlPct: return String(format: "%+.2f%%", pPct)
        case .recovery: return rec.map { String(format: "+%.1f%%", $0) } ?? "—"
        default: return "—"
        }
    }

    func color(item: WatchItemRow, live: StockQuote?) -> Color {
        if let wc = watchColumn { return wc.color(live) }
        guard let live else { return .secondary }
        let p = HoldingMetrics(cost: item.costPrice, shares: item.shares,
                               price: live.currentPrice).pnl
        switch self {
        case .pnl, .pnlPct: return Sem.pnl(p)
        case .recovery: return p < 0 ? Sem.warn : Sem.pnl(p)
        default: return .primary
        }
    }

    private static func fmtShares(_ v: Double) -> String {
        if v >= 10000 { return String(format: "%.2f万", v / 10000) }
        return String(format: "%.0f", v)
    }
}

// MARK: - 表头排序（三态逻辑在 Core 的 `WatchSortState.next`，这里只画格子）

/// 表头一格：宽度与对齐**必须**和数据行同源（都取自 `WatchColumnLayout` / `*.alignment`）。
/// 给了 `sortKey` 就是排序按钮，箭头只在该列生效时出现。
struct WatchHeaderCell: View {
    let title: String
    let width: CGFloat
    let alignment: Alignment
    var sortKey: WatchSortKey? = nil
    var active: WatchSortState? = nil
    var onSort: (WatchSortKey) -> Void = { _ in }

    var body: some View {
        let label = HStack(spacing: 2) {
            Text(title)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let sortKey, active?.key == sortKey {
                Image(systemName: active!.ascending ? "chevron.up" : "chevron.down")
                    .font(AppFont.glyph(8).weight(.semibold))
                    .foregroundStyle(Sem.brand)
            }
        }
        // 定宽 + 对齐：与数据行同一枚 frame，错位就一眼看得出来
        .frame(width: width, alignment: alignment)
        .contentShape(Rectangle())
        if let sortKey {
            Button { onSort(sortKey) } label: { label }
                .buttonStyle(.plain)
                .help("按「\(title)」排序：升序 → 降序 → 取消")
        } else {
            label
        }
    }
}
