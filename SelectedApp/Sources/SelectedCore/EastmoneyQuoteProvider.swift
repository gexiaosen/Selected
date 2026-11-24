import Foundation

/// 东财行情源（`push2` 家族）。
///
/// ## 为什么主用 `push2delay2`
/// 2026-10-30 实测：`push2` / `push2delay` 对本机出口**间歇性空回包**（curl 52），
/// 而 `push2delay2` 稳定 200（27ms、100 只 32ms）。"delay" 只是子域名，
/// 数据与 `push2` 是同一套实时快照（逐字段比对过 600519/000001/00700）。
///
/// ## 能力边界（**必须如实声明**）
/// - 有：价格/涨跌/量额/换手/量比/PE/PB/总市值/流通市值
/// - **没有**：涨停价、跌停价（`ulist` 的 f51/f52 是资金流字段，不是涨跌停；
///   只有 `stock/get` 的 f51/f52 才是，但那是一票一请求 —— 不划算）
///
/// ## 单位（与腾讯口径逐项对齐，切换源不能改变界面数字）
/// f5 手、f6 元→万元、f20/f21 元→亿、f124 Unix 秒。
public struct EastmoneyQuoteProvider: QuoteProvider {

    public init() {}

    public let id = "eastmoney"

    public var capabilities: QuoteCapabilities {
        [.aShare, .hk, .index, .valuation]
    }

    /// 单批只数：实测 100 只 32ms；留 100 是为了单次 URL 长度可控
    public static let batchLimit = 100

    /// host 降级链：**首选实测最稳的 delay2**，其余同族兜底
    public static let hosts: [String] = [
        DataSourceEndpoints.eastmoneyPush2Delay2,
        DataSourceEndpoints.eastmoneyPush2,
        DataSourceEndpoints.eastmoneyPush2Delay,
    ] + DataSourceEndpoints.eastmoneyPush2Numbered

    static let fields = "f2,f3,f4,f5,f6,f8,f9,f10,f12,f13,f14,f15,f16,f17,f18,f20,f21,f23,f124"

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
        // secid → 完整代码：响应只带 f13/f12，要靠这张表还原 sz/bj 与美股等差异
        var mapping: [String: String] = [:]
        for s in symbols {
            guard let secid = QuoteSymbol.eastmoneySecid(s) else { continue }
            mapping[secid] = s
        }
        guard !mapping.isEmpty else { throw QuoteProviderError.malformed("东财 secid 全为空") }

        let secids = mapping.keys.joined(separator: ",")
        var lastError: Error = QuoteProviderError.empty

        for host in hosts {
            let path = host + "/api/qt/ulist.np/get?fltt=2&invt=2"
                + "&ut=" + DataSourceEndpoints.eastmoneyUT
                + "&fields=" + fields
                + "&secids=" + secids
            guard let url = URL(string: path) else {
                lastError = QuoteProviderError.malformed("东财行情 URL 非法")
                continue
            }
            var req = URLRequest(url: url, timeoutInterval: 6)
            req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
                         forHTTPHeaderField: "User-Agent")
            req.setValue(DataSourceEndpoints.eastmoneyReferer, forHTTPHeaderField: "Referer")
            do {
                let data: Data
                do {
                    data = try await HTTPFetch.get(req)
                } catch {
                    await DataSources.throttleAfterNetworkAsync()
                    throw error
                }
                // ⚠ 东财对批量端点按出口 IP 限流：async 路径走异步全局限速器，不阻塞协作线程池
                await DataSources.throttleAfterNetworkAsync()
                let obj = try JSONSerialization.jsonObject(with: data)
                let parsed = parse(obj, mapping: mapping)
                guard !parsed.isEmpty else { throw QuoteProviderError.empty }
                return parsed
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    // MARK: - 纯解析（可离线单测）

    /// 东财 `ulist.np/get` 响应 → 全代码 → StockQuote。
    ///
    /// - Parameter mapping: `secid → 完整代码`（请求时建的）
    public static func parse(_ json: Any, mapping: [String: String]) -> [String: StockQuote] {
        guard let root = json as? [String: Any],
              let data = root["data"] as? [String: Any] else { return [:] }
        let rows: [[String: Any]]
        if let arr = data["diff"] as? [[String: Any]] {
            rows = arr
        } else if let dict = data["diff"] as? [String: Any] {
            rows = dict.values.compactMap { $0 as? [String: Any] }
        } else {
            return [:]
        }

        var out: [String: StockQuote] = [:]
        for row in rows {
            func num(_ key: String) -> Double? { Num.doubleOrNil(row[key]) }
            func str(_ key: String) -> String {
                if let s = row[key] as? String { return s }
                if let n = row[key] as? NSNumber { return n.stringValue }
                return ""
            }
            guard let price = num("f2"), price > 0,
                  let preClose = num("f18") else { continue }

            let code = str("f12")
            let marketID = str("f13")
            let secid = marketID.isEmpty ? "" : "\(marketID).\(code)"
            // 优先用请求表还原（能区分 sz/bj）；表里没有（源多给了票）时按代码推断，
            // 推断不出就跳过 —— 绝不拿"1.600519"这种 secid 前缀当市场前缀用
            let full: String
            if let m = mapping[secid] {
                full = m
            } else if let f = QuoteSymbol.full(code) {
                full = f
            } else {
                continue
            }
            let market = QuoteSymbol.market(full)
            let high = num("f15") ?? 0
            let low = num("f16") ?? 0
            let amplitude = preClose > 0 ? (high - low) / preClose * 100 : nil
            let ts = num("f124")

            out[full] = StockQuote(
                market: market,
                code: code,
                name: DataSources.cleanName(str("f14")),
                currentPrice: price,
                previousClose: preClose,
                openPrice: num("f17") ?? 0,
                highPrice: high,
                lowPrice: low,
                volume: num("f5") ?? 0,                       // 手（指数/港股与腾讯同口径）
                turnover: (num("f6") ?? 0) / 1_0000,          // 元 → 万元
                change: num("f4") ?? 0,
                changePercent: num("f3") ?? 0,
                turnoverRate: num("f8"),
                peRatio: num("f9"),
                marketCap: num("f20").map { $0 / 1_0000_0000 },   // 元 → 亿
                circulationMarketCap: num("f21").map { $0 / 1_0000_0000 },
                amplitude: amplitude,
                volumeRatio: num("f10"),
                pbRatio: num("f23"),
                limitUp: nil,                                   // 见类型注释：ulist 不给涨跌停价
                limitDown: nil,
                quoteTime: ts.map { Date(timeIntervalSince1970: $0) }
            )
        }
        return out
    }
}
