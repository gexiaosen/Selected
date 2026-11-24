import Foundation

/// 历史日四指数快照（东财日K回填）。
///
/// 看板默认当天用腾讯实时批量；切到历史日时**不能拿实时价冒充历史**，
/// 这里用东财日K取 viewDate（或之前最近交易日）的收盘/涨跌幅，形状仍复用 `StockQuote`，
/// 让指数 tile 的渲染只有一条路径。
///
/// ⚠ 一次回填最多 4 个指数 = 4 个日K请求；只在切到历史日时发生，并按 viewDate 缓存。
public struct IndexHistorySnapshot: Sendable {
    public let quotes: [String: StockQuote]
    /// 实际取到的交易日（viewDate 为周末/节假日时会早于 viewDate）
    public let asOf: String
    public let exact: Bool

    public init(quotes: [String: StockQuote], asOf: String, exact: Bool) {
        self.quotes = quotes
        self.asOf = asOf
        self.exact = exact
    }
}

public enum IndexHistoryQuote {

    /// 取一个指数在 `date`（或之前最近交易日）的收盘快照。
    ///
    /// - Returns: `(quote, asOf)`；无数据 → nil。
    public static func fetch(symbol: String, date: String) -> (quote: StockQuote, asOf: String)? {
        guard let idx = IndexCatalog.index(for: symbol),
              let beg = ChinaTime.shiftDays(date, -30) else { return nil }
        let bars = HistoryBarsSource.fetchIndex(idx.symbol, beg: beg, end: date)
        guard let r = quote(symbol: symbol, bars: bars, date: date) else { return nil }
        return (r.quote, r.asOf)
    }

    /// 纯计算：从日K序列取 `date`（或之前最近交易日）的收盘快照。
    ///
    /// - 涨跌幅优先用"本根收盘 / 前一根收盘"算；没有前一根时回落源字段 `changePct`。
    /// - 日期是周末/节假日时取之前最近交易日，`asOf` 如实返回，不伪装成 viewDate。
    static func quote(symbol: String, bars: [HistoryBar], date: String)
        -> (quote: StockQuote, asOf: String)? {
        guard let idx = IndexCatalog.index(for: symbol),
              let at = bars.lastIndex(where: { $0.day <= date }) else { return nil }
        let bar = bars[at]
        let prev = at > 0 ? bars[at - 1] : nil
        let prevClose = prev?.close ?? 0
        let change = prevClose > 0 ? bar.close - prevClose : 0
        let pct = prevClose > 0 ? (bar.close / prevClose - 1) * 100 : bar.changePct
        let market = String(idx.symbol.prefix(2)).lowercased()
        let code = String(idx.symbol.dropFirst(2))
        let quote = StockQuote(
            market: market,
            code: code,
            name: idx.name,
            currentPrice: bar.close,
            previousClose: prevClose,
            openPrice: bar.open,
            highPrice: bar.high,
            lowPrice: bar.low,
            volume: bar.volume,
            turnover: bar.amount / 1_0000,
            change: change,
            changePercent: pct,
            turnoverRate: bar.turnover,
            peRatio: nil,
            marketCap: nil,
            circulationMarketCap: nil,
            amplitude: bar.amplitude,
            volumeRatio: nil,
            pbRatio: nil,
            limitUp: nil,
            limitDown: nil)
        return (quote, bar.day)
    }

    /// 批量回填（顺序请求，最多 4 个指数）。部分失败时保留已拿到的。
    public static func fetchAll(symbols: [String], date: String) -> IndexHistorySnapshot? {
        var quotes: [String: StockQuote] = [:]
        var asOf = ""
        for symbol in symbols {
            guard let r = fetch(symbol: symbol, date: date) else { continue }
            quotes[symbol] = r.quote
            if asOf.isEmpty { asOf = r.asOf }
        }
        guard !quotes.isEmpty, !asOf.isEmpty else { return nil }
        return IndexHistorySnapshot(quotes: quotes, asOf: asOf, exact: asOf == date)
    }
}
