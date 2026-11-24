import Foundation

/// 腾讯行情源（`qt.gtimg.cn`）。
///
/// ## 为什么它是默认首选
/// 字段最全（**唯一带涨跌停价** f47/f48，详情页的「涨跌停异动」判定依赖它），
/// 且 2026-10-30 实测 78ms / 稳定。
///
/// ## 口径
/// 解析完全复用 `StockQuotes.parseBatchFullKeys`（纯函数、已有单测覆盖），
/// 这里只负责"分批 + 发请求 + 解码"。
public struct TencentQuoteProvider: QuoteProvider {

    public init() {}

    public let id = "tencent"

    public var capabilities: QuoteCapabilities {
        [.aShare, .hk, .index, .valuation, .limitPrices]
    }

    /// 腾讯单批上限：服务端 1000 只触发 HTTP 414，取 500 留余量（沿用既有口径）
    public static let batchLimit = 500

    /// 腾讯全家族共用的 UA（`qt.gtimg.cn` / `stock.gtimg.cn` 都只认浏览器 UA）
    public static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"

    /// 五档可用的市场：88/87 字段布局里 f9…f28 就是买卖五档。
    /// ⚠ 港股是 78 字段且 f9 = 现价（实测 hk00700），布局不同 ⇒ 排除。
    public static let depthMarkets: Set<String> = ["sh", "sz", "bj"]
    /// 分笔可用的市场（实测 2026-11-02：bj/hk/指数 在 `appn=detail` 上**一律空 body**）
    public static let tickMarkets: Set<String> = ["sh", "sz"]

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

    /// 同一批 `q=` 请求的**原始响应文本**。
    ///
    /// 五档、以及将来任何"这份回包里还没用过的字段"都从这里解析 ——
    /// 免得为每个新字段各发一次请求（腾讯的 88 字段本来就在同一条 `v_sh600519="…"` 里）。
    public static func fetchRawText(_ symbols: [String]) async throws -> String {
        guard let url = URL(string: DataSourceEndpoints.tencentQuotes
                            + symbols.joined(separator: ",")) else {
            throw QuoteProviderError.malformed("腾讯行情 URL 非法")
        }
        var req = URLRequest(url: url, timeoutInterval: 6)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        var lastError: Error = QuoteProviderError.empty
        // 一次重试：腾讯偶发"立即重试即成功"，而换源的成本比多打一次高
        for _ in 0..<2 {
            do {
                let data = try await HTTPFetch.get(req)
                guard let text = String(data: data, encoding: DataSources.gb18030) else {
                    throw QuoteProviderError.malformed("腾讯行情 GBK 解码失败")
                }
                return text
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    static func fetchChunk(_ symbols: [String]) async throws -> [String: StockQuote] {
        let text = try await fetchRawText(symbols)
        let parsed = StockQuotes.parseBatchFullKeys(text)
        guard !parsed.isEmpty else { throw QuoteProviderError.empty }
        return parsed
    }
}
