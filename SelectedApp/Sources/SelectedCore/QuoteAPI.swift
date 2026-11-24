import Foundation

/// **行情统一出口** —— 界面层只认识这一个门面，不直连任何 provider。
///
/// ## 契约（与改造前的 `StockQuotes.fetchBatch/fetch/fetchIndexBatch` 保持一致）
/// - `batch` 的键是**纯数字代码**（自选列表口径），值已归一到 `StockQuote`；
/// - `indexes` 的键是**完整代码**（`sh000001`），因为指数存在同数字不同市场；
/// - 失败返回空字典 —— 调用方保留上一轮价格（不要清空界面）。
///
/// ## 为什么 UI 不直连 provider
/// 直连等于把"选哪家"写死在调用点；三家源的健康状态只有池知道。
/// 护栏（`quote_pool`）扫的就是"Core 之外不许出现 `*QuoteProvider(`"。
public enum QuoteAPI {

    /// 自选/看板批量行情（键 = 纯数字代码）
    public static func batch(_ codes: [String],
                             preferring soft: QuoteCapabilities = []) async -> [String: StockQuote] {
        var seen = Set<String>()
        var fulls: [String] = []
        var dropped = 0
        for code in codes {
            guard let full = QuoteSymbol.full(code) else { dropped += 1; continue }
            if seen.insert(full).inserted { fulls.append(full) }
        }
        if dropped > 0 {
            DataSources.logDataSource("quote_api", "bad_code", "丢弃 \(dropped) 个形状非法的代码")
        }
        guard !fulls.isEmpty else { return [:] }
        let outcome = await QuotePool.shared.quotes(fulls, preferring: soft)
        var out: [String: StockQuote] = [:]
        for (full, quote) in outcome.quotes {
            out[StockQuotes.digits(full)] = quote
        }
        return out
    }

    /// 单只行情（详情页）。软偏好涨跌停价 —— 腾讯有、别家没有时优先腾讯，
    /// 但腾讯挂了仍然返回价格（`limitUp/limitDown` 为 nil），不整页没数。
    public static func single(_ code: String) async -> StockQuote? {
        guard let full = QuoteSymbol.full(code) else { return nil }
        let outcome = await QuotePool.shared.quotes([full], preferring: .limitPrices)
        return outcome.quotes[full]
    }

    /// 指数批量（键 = 完整代码）
    public static func indexes(_ symbols: [String]) async -> [String: StockQuote] {
        let fulls = symbols.compactMap { QuoteSymbol.full($0) }
        guard !fulls.isEmpty else { return [:] }
        return await QuotePool.shared.quotes(fulls, requiring: .index).quotes
    }

    /// 后台探针（调用方先判交易时段；这里再判一次，避免非交易时段白打请求）
    public static func probeIfNeeded() async {
        guard AlertWindow.inSession(minuteOfDay: ChinaTime.minutesOfDay()) else { return }
        await QuotePool.shared.probeIfNeeded()
    }

    // MARK: - 盘口 / 分笔

    /// 单只五档（键 = 纯数字代码以外的口径：返回体自带 `symbol`）。
    ///
    /// 只有腾讯给得出（东财 `ulist` 没有五档字段、新浪简版没有），所以**不经行情池**；
    /// 走的是 `q=` 同一条请求，池里那三家挂哪家都不影响这条的可用性判定。
    /// 指数 / 港股返回 `nil`（接口对指数回全零、港股字段布局不同 —— 不硬凑）。
    public static func depth(_ code: String) async -> QuoteDepth? {
        guard let full = QuoteSymbol.full(code) else { return nil }
        return await QuoteBookSource.depth(full)
    }

    /// 批量五档（一次请求；键 = **纯数字代码**，与 `batch` 同口径）。
    public static func depths(_ codes: [String]) async -> [String: QuoteDepth] {
        let fulls = codes.compactMap { QuoteSymbol.full($0) }
        guard !fulls.isEmpty else { return [:] }
        let byFull = await QuoteBookSource.depths(fulls)
        var out: [String: QuoteDepth] = [:]
        for (full, depth) in byFull { out[StockQuotes.digits(full)] = depth }
        return out
    }

    /// 最近 `limit` 笔分笔（升序，末笔在最后），带「不支持 / 无成交 / 获取失败」语义区分。
    ///
    /// ⚠ 别挂到 1 秒轮询上（成本与限制见 `QuoteBookSource`）。
    public static func ticksOutcome(_ code: String, limit: Int = 100) async -> TicksOutcome {
        guard let full = QuoteSymbol.full(code) else { return .unsupported }
        return await QuoteBookSource.latestTicksOutcome(full, limit: limit)
    }

    /// 最近 `limit` 笔分笔（升序，末笔在最后）。取不到返回 `[]`。
    ///
    /// ⚠ 别挂到 1 秒轮询上（成本与限制见 `QuoteBookSource`）。
    public static func ticks(_ code: String, limit: Int = 100) async -> [TickTrade] {
        guard let full = QuoteSymbol.full(code) else { return [] }
        return await QuoteBookSource.latestTicks(full, limit: limit)
    }

    /// 诊断页：各源健康度（按分数降序）
    public static func status() async -> [QuotePool.ProviderStatus] {
        await QuotePool.shared.status()
    }
}
