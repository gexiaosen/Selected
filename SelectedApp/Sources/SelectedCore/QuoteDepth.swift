import Foundation

// MARK: - 五档盘口 / 分笔成交（腾讯）
//
// 这两块数据**本来就在既有回包里 / 同族接口里**，只是从来没解析过：
//   · 五档：`qt.gtimg.cn/q=` 的 88 字段里 f9…f28 就是买五档与卖五档
//     （2026-11-02 实测 sz000001 买一 11.70/2727 手、卖一 11.71/5245 手）
//     ⇒ 与行情**同一个接口、同一条回包**（批量取多只也还是一次请求），不引入新源。
//   · 分笔：`stock.gtimg.cn/data/index.php?appn=detail` 按页给当日逐笔
//     （实测每页恒 70 笔）。

/// 一档委托价量。
public struct QuoteLevel: Sendable, Equatable {
    public let price: Double
    /// 委托量（**手**，与 `StockQuote.volume` 同单位）
    public let volumeLots: Double

    public init(price: Double, volumeLots: Double) {
        self.price = price
        self.volumeLots = volumeLots
    }
}

/// 五档盘口。
///
/// ⚠ **空档位一律不收录**（接口对无委托的档位回 `0.00/0`，而 0 在本项目里是有意义的值）：
///   · 涨停时 `asks` 是**空数组**、跌停时 `bids` 是空数组 —— 消费方按"没有卖盘"渲染，
///     而不是渲染一个 0 价卖一。
///   · 数组顺序就是**买一 → 买五 / 卖一 → 卖五**（最优在前）。
public struct QuoteDepth: Sendable, Equatable {
    /// 带市场前缀的完整代码（`sh600519`）
    public let symbol: String
    public let bids: [QuoteLevel]
    public let asks: [QuoteLevel]
    /// 该笔快照的时间（同一回包的 `quote_time`）
    public let quoteTime: Date?

    public init(symbol: String, bids: [QuoteLevel], asks: [QuoteLevel], quoteTime: Date?) {
        self.symbol = symbol
        self.bids = bids
        self.asks = asks
        self.quoteTime = quoteTime
    }

    /// 卖一价（无卖盘 → nil）
    public var bestAsk: Double? { asks.first?.price }
    /// 买一价（无买盘 → nil）
    public var bestBid: Double? { bids.first?.price }
}

/// 分笔的成交方向（腾讯原值 `B`/`S`/`M`）。
public enum TickSide: String, Sendable, CaseIterable {
    case buy        // B：主动买
    case sell       // S：主动卖
    case neutral    // M：中性盘（含集合竞价）

    public var label: String {
        switch self {
        case .buy: return "买"
        case .sell: return "卖"
        case .neutral: return "中"
        }
    }

    init(code: String) {
        switch code.uppercased() {
        case "B": self = .buy
        case "S": self = .sell
        default: self = .neutral     // M 以及任何认不出的字母都按中性，不硬猜方向
        }
    }
}

/// 一笔分笔成交。
public struct TickTrade: Sendable, Equatable {
    /// 当日序号（接口原值，从 0 起）
    public let index: Int
    /// `HH:mm:ss`（交易所当地时间，不做时区换算 —— 与腾讯分时同口径）
    public let time: String
    public let price: Double
    /// 与**上一笔**的价差（接口第 4 字段原值，不是当日涨跌）
    public let delta: Double
    /// 成交量（**手**）
    public let volumeLots: Double
    /// 成交额（**元**）。
    ///
    /// ⚠ 腾讯的一"笔"其实是几秒窗口内的**聚合**：`price` 是窗口末价，`amount` 是窗口内
    ///   各笔金额之和 ⇒ `amount ≈ price × volumeLots × 100` 但**不严格相等**
    ///   （2026-11-02 实测 600519 偏差 0.02%~0.32%）。
    ///   单位判定不靠相等，靠量级：按"手"算比值 ≈1，按"股"算比值 ≈100。
    public let amount: Double
    public let side: TickSide

    public init(index: Int, time: String, price: Double, delta: Double,
                volumeLots: Double, amount: Double, side: TickSide) {
        self.index = index
        self.time = time
        self.price = price
        self.delta = delta
        self.volumeLots = volumeLots
        self.amount = amount
        self.side = side
    }
}

// MARK: - 解析（纯函数，网络不在这里）

public enum QuoteBook {

    /// 批量行情响应 → 完整代码 → 五档（没有盘口的标的**不出现**在结果里）。
    ///
    /// 覆盖 sh/sz/bj 个股与场内基金（同一套 88/87 字段布局）；
    /// ⚠ **指数没有盘口**（f9…f28 恒 `0.00/0`）、**港股字段布局不同**（78 字段，f9 是现价）
    ///   → 两者一律不返回，而不是返回一个"全零的五档"。
    public static func parseDepthBatch(_ text: String) -> [String: QuoteDepth] {
        var out: [String: QuoteDepth] = [:]
        for line in text.components(separatedBy: "\n") {
            guard let symbol = StockQuotes.symbolKey(of: line),
                  TencentQuoteProvider.depthMarkets.contains(QuoteSymbol.market(symbol)),
                  !QuoteSymbol.isIndex(symbol),
                  let fields = StockQuotes.quotedFields(of: line),
                  let depth = parseDepth(fields: fields, symbol: symbol) else { continue }
            out[symbol] = depth
        }
        return out
    }

    /// 一条行情响应的字段数组 → 五档。字段不足 / 全空 → nil。
    public static func parseDepth(fields: [String], symbol: String) -> QuoteDepth? {
        guard fields.count > 28 else { return nil }
        let bids = levels(fields, from: 9)
        let asks = levels(fields, from: 19)
        guard !bids.isEmpty || !asks.isEmpty else { return nil }
        return QuoteDepth(symbol: symbol, bids: bids, asks: asks,
                          quoteTime: StockQuotes.parseQuoteTime(fields.count > 30 ? fields[30] : ""))
    }

    /// 连续 5 档（`价,量` 成对）→ 去掉空档位。
    private static func levels(_ fields: [String], from start: Int) -> [QuoteLevel] {
        var out: [QuoteLevel] = []
        for i in 0..<5 {
            let p = start + i * 2
            guard p + 1 < fields.count,
                  let price = Double(fields[p]), price > 0,
                  let lots = Double(fields[p + 1]), lots > 0 else { continue }
            out.append(QuoteLevel(price: price, volumeLots: lots))
        }
        return out
    }

    /// 分笔响应 → 成交列表（**升序**，开盘在前）。
    ///
    /// 形状：`v_detail_data_sh600519=[0,"0/09:25:01/1410.00/-10.00/2207/311256090/S|1/…"]`
    /// 每笔 7 段：`序号/时间/价格/较上一笔价差/成交量(手)/成交额(元)/方向`。
    /// 非法行**跳过**（源改版时宁可少给几笔，也不整批作废）；认不出形状返回 `[]`。
    public static func parseTicks(_ text: String) -> [TickTrade] {
        guard let body = quotedSegment(text), !body.isEmpty else { return [] }
        var out: [TickTrade] = []
        for record in body.components(separatedBy: "|") {
            let f = record.components(separatedBy: "/")
            guard f.count >= 7,
                  let index = Int(f[0]), isTimeString(f[1]),
                  let price = Double(f[2]), price > 0,
                  let delta = Double(f[3]),
                  let lots = Double(f[4]),
                  let amount = Double(f[5]) else { continue }
            out.append(TickTrade(index: index, time: f[1], price: price, delta: delta,
                                 volumeLots: lots, amount: amount,
                                 side: TickSide(code: f[6])))
        }
        return out
    }

    /// 当日分笔的**行情日 + 每页时间跨度**：
    /// `v_detail_time_sh600519=[20261102,"09:25:01~09:33:25|09:33:28~09:36:55|…"]`
    ///
    /// ⚠ 这条响应就是"总页数"的**唯一出处**（`data` 响应不给总数）：
    ///   跨度按页排列，数一下就知道末页是第几页 —— 实测 2026-11-02 10:25 给了 16 段 ⇒ 末页 15。
    /// 所以取"最新一页"是**一次请求定页码**，不是靠估。
    public struct TickSession: Sendable, Equatable {
        /// `yyyyMMdd`（交易所侧的行情日）
        public let date: String
        /// 每页的时间跨度，**页码 = 下标**
        public let pageRanges: [String]

        public var pageCount: Int { pageRanges.count }
        /// 末页页码；空表 → nil（没有分笔数据）
        public var lastPage: Int? { pageRanges.isEmpty ? nil : pageRanges.count - 1 }
    }

    public static func parseSession(_ text: String) -> TickSession? {
        guard let start = text.firstIndex(of: "["), let end = text.lastIndex(of: "]") else { return nil }
        let inner = String(text[text.index(after: start)..<end])
        guard let comma = inner.firstIndex(of: ",") else { return nil }
        let date = String(inner[..<comma]).trimmingCharacters(in: CharacterSet(charactersIn: " \""))
        guard date.count == 8, date.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        guard let body = quotedSegment(inner), !body.isEmpty else { return nil }
        let ranges = body.components(separatedBy: "|")
        // 每一段都必须是 `时间~时间`：少一段就等于少数一页，末页会退到**旧的一页**，
        // 表现为"分笔停在几十分钟前"却毫不报错 ⇒ 宁可不给。
        for r in ranges where !isRange(r) { return nil }
        return TickSession(date: date, pageRanges: ranges)
    }

    static func isRange(_ s: String) -> Bool {
        let p = s.components(separatedBy: "~")
        return p.count == 2 && isTimeString(p[0]) && isTimeString(p[1])
    }

    /// 取引号内的那一段（第一段是页码/日期数字）
    static func quotedSegment(_ text: String) -> String? {
        guard let open = text.firstIndex(of: "\"") else { return nil }
        let rest = text[text.index(after: open)...]
        guard let close = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<close])
    }

    static func seconds(_ hhmmss: String) -> Int? {
        let p = hhmmss.components(separatedBy: ":")
        guard p.count == 3,
              p.allSatisfy({ $0.count == 2 && $0.allSatisfy { c in c.isASCII && c.isNumber } }),
              let h = Int(p[0]), let m = Int(p[1]), let s = Int(p[2]),
              (0...23).contains(h), (0...59).contains(m), (0...59).contains(s) else { return nil }
        return h * 3600 + m * 60 + s
    }

    static func isTimeString(_ s: String) -> Bool { seconds(s) != nil }
}

/// 分笔成交拉取结果：区分“有成交 / 市场不支持 / 确认暂无成交 / 瞬时网络或解析失败”。
public enum TicksOutcome: Sendable, Equatable {
    case loaded([TickTrade])
    case empty
    case unsupported
    case failed
}

// MARK: - 取数（盘口 / 分笔）

/// 盘口与分笔的取数入口。**界面侧唯一门面仍是 `QuoteAPI`**（护栏 `quote_pool` 要求 UI 不直连源）。
///
/// ## 分笔为什么要先问"页数"
/// 接口按页给当日逐笔（`p=0` 是**开盘**那 70 笔），页码越界只给空 body，而 `data` 响应里
/// 不带总数。唯一给总数的是 `action=last`（323 字节，按页给出每页的时间跨度）
/// ⇒ **一次请求定末页**，然后只取末页（要更多笔再往前取 1~3 页）。
/// ⚠ 这条链路**不进 1 秒轮询**：它是详情页展开时取一次的数据（TTL 30s）。
///   真要让分笔常驻刷新，改成"记住上次末页、只增量取新页"，别按现在的写法每秒重取。
public enum QuoteBookSource {

    /// 腾讯分笔每页笔数（实测恒 70）
    public static let pageSize = 70
    /// 单次最多取几页
    static let maxPagesPerCall = 4
    /// 分笔结果缓存（秒）
    public static let ticksTTL: TimeInterval = 30
    /// 单次最多返回笔数
    public static let maxTicks = 280

    // MARK: 五档

    /// 单只五档（沪深个股 / 场内基金 / 北交所；指数与港股返回 nil）。
    public static func depth(_ fullCode: String) async -> QuoteDepth? {
        await depths([fullCode])[fullCode]
    }

    /// 批量五档（一次 `q=` 请求拿多只；键 = 完整代码）。
    public static func depths(_ fullCodes: [String]) async -> [String: QuoteDepth] {
        await DataSourceRegistry.timedAsync(.depth) { () -> [String: QuoteDepth]? in
            guard !fullCodes.isEmpty else { return [:] }
            guard let text = try? await TencentQuoteProvider.fetchRawText(fullCodes) else { return nil }
            return QuoteBook.parseDepthBatch(text)
        } ?? [:]
    }

    // MARK: 分笔

    /// 最近 `limit` 笔分笔（**升序**，末笔在最后）。区分不支持 / 空响应 / 网络失败。
    public static func latestTicksOutcome(_ fullCode: String, limit: Int = 100) async -> TicksOutcome {
        let want = min(max(1, limit), maxTicks)
        let key = "ticks|\(fullCode)|\(want)"
        if let hit: [TickTrade] = DataSources.cacheGet(key, ttl: ticksTTL) { return .loaded(hit) }
        // 代码形状不合法（含不支持的市场）→ 直接 unsupported，不发请求
        guard tickURL(fullCode, page: 0) != nil else { return .unsupported }
        // ⚠ 拿不到页数信息绝不退回"取第 0 页"：
        //   第 0 页是**开盘那 70 笔**，把它当"最新成交"返回，界面上与真数据完全一样
        //   （时间、价格都真实），只是停在半小时前 —— 这类错没人能看出来。
        //   （探针 2026-11-02 10:25 就是这么抓到的：末笔显示 09:33:25。）
        let page: Int
        switch await fetchSessionOutcome(fullCode) {
        case .loaded(let session):
            guard let lastPage = session.lastPage else {
                DataSourceRegistry.report(.ticks, ok: false)
                return .empty
            }
            page = lastPage
        case .empty:
            DataSourceRegistry.report(.ticks, ok: false)
            return .empty
        case .malformed:
            DataSources.logDataSource("tencent", "ticks_no_page_index",
                                      "\(fullCode) 拿不到分笔页数（action=last 形状变了）→ 宁可不给")
            DataSourceRegistry.report(.ticks, ok: false)
            return .failed
        case .networkError:
            DataSourceRegistry.report(.ticks, ok: false)
            return .failed
        }

        var pages: [[TickTrade]] = []
        var cursor = page
        var firstPageFailed = false
        let wantPages = min(maxPagesPerCall, (want + pageSize - 1) / pageSize)
        pageLoop: while pages.count < wantPages {
            switch await tickPageOutcome(fullCode, page: cursor) {
            case .loaded(let rows):
                pages.append(rows)
            case .empty:
                break pageLoop
            case .networkError:
                if pages.isEmpty { firstPageFailed = true }
                break pageLoop
            }
            if cursor == 0 { break }
            cursor -= 1
        }
        if firstPageFailed {
            DataSourceRegistry.report(.ticks, ok: false)
            return .failed
        }
        let result = Array(pages.reversed().flatMap { $0 }.suffix(want))
        DataSourceRegistry.report(.ticks, ok: !result.isEmpty)
        if result.isEmpty { return .empty }
        DataSources.cachePut(key, result)
        return .loaded(result)
    }

    /// 最近 `limit` 笔分笔（**升序**，末笔在最后）。取不到返回 `[]`。
    public static func latestTicks(_ fullCode: String, limit: Int = 100) async -> [TickTrade] {
        if case .loaded(let rows) = await latestTicksOutcome(fullCode, limit: limit) {
            return rows
        }
        return []
    }

    private enum PageOutcome {
        case loaded([TickTrade])
        case empty
        case networkError
    }

    private enum SessionOutcome {
        case loaded(QuoteBook.TickSession)
        case empty
        case malformed
        case networkError
    }

    private enum TextFetchResult {
        case text(String)
        case emptyBody
        case networkError
    }

    /// 某一页的分笔；页码越界 / 解析不出 → nil。
    static func tickPage(_ fullCode: String, page: Int) async -> [TickTrade]? {
        if case .loaded(let rows) = await tickPageOutcome(fullCode, page: page) { return rows }
        return nil
    }

    private static func tickPageOutcome(_ fullCode: String, page: Int) async -> PageOutcome {
        switch await fetchTextResult(tickURL(fullCode, page: page)) {
        case .text(let text):
            let rows = QuoteBook.parseTicks(text)
            return rows.isEmpty ? .empty : .loaded(rows)
        case .emptyBody:
            return .empty
        case .networkError:
            return .networkError
        }
    }

    /// 页数信息（一次请求，结果按 `行情日` 缓存 —— 换日自动重取）。
    static func fetchSession(_ fullCode: String) async -> QuoteBook.TickSession? {
        if case .loaded(let s) = await fetchSessionOutcome(fullCode) { return s }
        return nil
    }

    private static func fetchSessionOutcome(_ fullCode: String) async -> SessionOutcome {
        let cacheKey = "ticks_session|\(fullCode)"
        if let hit: QuoteBook.TickSession = DataSources.cacheGet(cacheKey, ttl: ticksTTL) { return .loaded(hit) }
        guard let url = sessionURL(fullCode) else { return .malformed }
        switch await fetchTextResult(url) {
        case .networkError:
            return .networkError
        case .emptyBody:
            return .empty
        case .text(let text):
            if let session = QuoteBook.parseSession(text) {
                DataSources.cachePut(cacheKey, session)
                return .loaded(session)
            }
            if isExplicitEmptySession(text) {
                return .empty
            }
            return .malformed
        }
    }

    /// 如 `v_detail_time_sh600519=[20261102,""]`：接口明确回应“今日暂无页数”，与格式损坏区分。
    private static func isExplicitEmptySession(_ text: String) -> Bool {
        guard let start = text.firstIndex(of: "["), let end = text.lastIndex(of: "]") else { return false }
        let inner = String(text[text.index(after: start)..<end])
        guard let comma = inner.firstIndex(of: ",") else { return false }
        let date = String(inner[..<comma]).trimmingCharacters(in: CharacterSet(charactersIn: " \""))
        guard date.count == 8, date.allSatisfy({ $0.isASCII && $0.isNumber }) else { return false }
        return QuoteBook.quotedSegment(inner) == ""
    }

    /// 页数信息的 URL（与 `data` 只差一个 `action`，同 host 同族）。
    static func sessionURL(_ fullCode: String) -> String? {
        guard let base = tickURL(fullCode, page: 0) else { return nil }
        return base.replacingOccurrences(of: "action=data", with: "action=last")
    }

    /// 腾讯的 `detail` 域是 GBK 家族（与 `qt.gtimg.cn` 同），优先按 GB18030 解。
    private static func fetchTextResult(_ url: String?) async -> TextFetchResult {
        guard let url, let target = URL(string: url) else { return .networkError }
        var req = URLRequest(url: target, timeoutInterval: 8)
        req.setValue(TencentQuoteProvider.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("https://gu.qq.com/", forHTTPHeaderField: "Referer")
        do {
            let data = try await HTTPFetch.get(req)
            if data.isEmpty { return .emptyBody }
            guard let text = String(data: data, encoding: DataSources.gb18030)
                    ?? String(data: data, encoding: .utf8) else {
                return .networkError
            }
            return .text(text)
        } catch {
            return .networkError
        }
    }

    /// 分笔 URL。市场限制见 `TencentQuoteProvider.tickMarkets`
    /// （实测北交所 / 港股 / 指数在该接口一律空 body）；指数在这里就挡掉，不白打请求。
    /// ⚠ 只认 **6 位**代码：`isQuoteCode` 允许 5 位（那是港股口径），
    ///   放 `sh60051` 这种畸形串进 URL 只会换来一次没有意义的空响应。
    static func tickURL(_ fullCode: String, page: Int) -> String? {
        let lower = fullCode.lowercased()
        let digits = StockQuotes.digits(lower)
        let market = QuoteSymbol.market(lower)
        guard DataSourceEndpoints.isSixDigitCode(digits),
              TencentQuoteProvider.tickMarkets.contains(market),
              !QuoteSymbol.isIndex(lower), page >= 0 else { return nil }
        return DataSourceEndpoints.tencentDetail
            + "?appn=detail&action=data&c=\(market)\(digits)&p=\(page)"
    }
}
