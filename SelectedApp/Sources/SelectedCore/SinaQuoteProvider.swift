import Foundation

/// 新浪行情源（`hq.sinajs.cn`）。
///
/// ## 定位
/// 第三源 / 兜底。优点是覆盖面（沪深京、ETF、指数、港股全都有）与协议极简；
/// 缺点是**字段少**：没有 PE/PB/市值/量比/涨跌停价 —— 这些必须在 `capabilities` 里
/// 如实声明，池只会在"不要这些字段"的场景选它。
///
/// ## 两条实测约束
/// 1. **必须带 Referer**：不带直接 403（9 字节拒绝页，2026-10-30 实测）。
/// 2. **单位不统一**：A 股成交量是**股**（腾讯是手，要 /100），
///    但指数成交量三条源给的是同一个数（不能再除）；港股成交量本来就是股。
public struct SinaQuoteProvider: QuoteProvider {

    public init() {}

    public let id = "sina"

    public var capabilities: QuoteCapabilities {
        [.aShare, .hk, .index]
    }

    static let batchLimit = 300
    static let timeFormatter = ChinaTime.formatter("yyyy-MM-dd HH:mm:ss")

    public func fetchQuotes(_ symbols: [String]) async throws -> [String: StockQuote] {
        guard !symbols.isEmpty else { return [:] }
        var out: [String: StockQuote] = [:]
        var index = 0
        while index < symbols.count {
            let chunk = Array(symbols[index..<min(index + Self.batchLimit, symbols.count)])
            index += Self.batchLimit
            out.merge(try await Self.fetchChunk(chunk)) { _, new in new }
        }
        return out
    }

    static func fetchChunk(_ symbols: [String]) async throws -> [String: StockQuote] {
        guard let url = URL(string: DataSourceEndpoints.sinaHQ + symbols.joined(separator: ","))
        else { throw QuoteProviderError.malformed("新浪行情 URL 非法") }
        var req = URLRequest(url: url, timeoutInterval: 6)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
                     forHTTPHeaderField: "User-Agent")
        req.setValue(DataSourceEndpoints.sinaHQReferer, forHTTPHeaderField: "Referer")

        let data = try await HTTPFetch.get(req)
        guard let text = String(data: data, encoding: DataSources.gb18030) else {
            throw QuoteProviderError.malformed("新浪行情 GBK 解码失败")
        }
        let parsed = parse(text)
        guard !parsed.isEmpty else { throw QuoteProviderError.empty }
        return parsed
    }

    // MARK: - 纯解析（可离线单测）

    /// `var hq_str_sh600519="…";` 多行 → 全代码 → StockQuote。
    public static func parse(_ text: String) -> [String: StockQuote] {
        var out: [String: StockQuote] = [:]
        for rawLine in text.components(separatedBy: ";") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let range = line.range(of: "hq_str_") else { continue }
            let rest = line[range.upperBound...]
            guard let eq = rest.firstIndex(of: "=") else { continue }
            let full = String(rest[..<eq]).lowercased()
            let body = rest[rest.index(after: eq)...]
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            guard !body.isEmpty else { continue }
            let f = body.components(separatedBy: ",")
            let quote: StockQuote?
            switch QuoteSymbol.market(full) {
            case "hk": quote = parseHK(full: full, f: f)
            default:   quote = parseA(full: full, f: f)
            }
            if let q = quote { out[full] = q }
        }
        return out
    }

    private static func num(_ f: [String], _ i: Int) -> Double? {
        guard i < f.count else { return nil }
        return Num.doubleOrNil(f[i])
    }

    private static func parseA(full: String, f: [String]) -> StockQuote? {
        // 0 名称 1 今开 2 昨收 3 现价 4 最高 5 最低 6 买一 7 卖一 8 成交量 9 成交额
        // 30 日期 31 时间
        guard f.count >= 32,
              let price = num(f, 3), price > 0,
              let preClose = num(f, 2), preClose > 0 else { return nil }
        let isIndex = QuoteSymbol.isIndex(full)
        let rawVolume = num(f, 8) ?? 0
        let amount = num(f, 9) ?? 0
        let high = num(f, 4) ?? 0
        let low = num(f, 5) ?? 0
        let change = price - preClose

        return StockQuote(
            market: QuoteSymbol.market(full),
            code: StockQuotes.digits(full),
            name: DataSources.cleanName(f[0]),
            currentPrice: price,
            previousClose: preClose,
            openPrice: num(f, 1) ?? 0,
            highPrice: high,
            lowPrice: low,
            // ⚠ A 股成交量是**股**（腾讯是手）；指数三条源给的是同一个数，不能再除
            volume: isIndex ? rawVolume : rawVolume / 100,
            turnover: amount / 1_0000,                   // 元 → 万元
            change: change,
            changePercent: preClose > 0 ? change / preClose * 100 : 0,
            turnoverRate: nil,
            peRatio: nil,
            marketCap: nil,
            circulationMarketCap: nil,
            amplitude: preClose > 0 ? (high - low) / preClose * 100 : nil,
            volumeRatio: nil,
            pbRatio: nil,
            limitUp: nil,
            limitDown: nil,
            quoteTime: parseTime(date: f.count > 30 ? f[30] : "",
                                 time: f.count > 31 ? f[31] : "")
        )
    }

    private static func parseHK(full: String, f: [String]) -> StockQuote? {
        // 0 英文名 1 中文名 2 今开 3 昨收 4 最高 5 最低 6 现价 7 涨跌额 8 涨跌幅
        // 9 买一 10 卖一 **11 成交额(元) 12 成交量(股)** 15 52周高 16 52周低
        // 17 日期 18 时间
        // ⚠ 11/12 的顺序与 A 股相反（A 股是 量在前、额在后），2026-10-30 逐字段核对过。
        guard f.count >= 19,
              let price = num(f, 6), price > 0,
              let preClose = num(f, 3), preClose > 0 else { return nil }
        let high = num(f, 4) ?? 0
        let low = num(f, 5) ?? 0
        return StockQuote(
            market: "hk",
            code: StockQuotes.digits(full),
            name: DataSources.cleanName(f.count > 1 && !f[1].isEmpty ? f[1] : f[0]),
            currentPrice: price,
            previousClose: preClose,
            openPrice: num(f, 2) ?? 0,
            highPrice: high,
            lowPrice: low,
            volume: num(f, 12) ?? 0,                     // 股（与腾讯同口径）
            turnover: (num(f, 11) ?? 0) / 1_0000,        // 元 → 万元
            change: num(f, 7) ?? (price - preClose),
            changePercent: num(f, 8) ?? 0,
            turnoverRate: nil,
            peRatio: nil,
            marketCap: nil,
            circulationMarketCap: nil,
            amplitude: preClose > 0 ? (high - low) / preClose * 100 : nil,
            volumeRatio: nil,
            pbRatio: nil,
            limitUp: nil,
            limitDown: nil,
            quoteTime: parseTime(date: f.count > 17 ? f[17] : "",
                                 time: f.count > 18 ? f[18] : "")
        )
    }

    static func parseTime(date: String, time: String) -> Date? {
        let d = date.trimmingCharacters(in: .whitespaces)
        let t = time.trimmingCharacters(in: .whitespaces)
        guard !d.isEmpty, !t.isEmpty else { return nil }
        return timeFormatter.date(from: "\(d) \(t)")
    }
}
