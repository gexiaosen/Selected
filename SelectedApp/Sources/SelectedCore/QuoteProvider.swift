import Foundation

/// 行情多源抽象 —— **接口池的协议层**。
///
/// ## 为什么要有这一层
/// 2026-10-30 实测：东财 `push2` / `push2delay` 对同一出口**间歇性空回包**，
/// 而 `push2delay2`、腾讯、新浪稳定 —— 谁挂取决于当天/当刻，写死任何一家都会在
/// 它挂的时候整页没价。这里把"从哪家取"变成运行时可换的决策，而不是编译期常量。
///
/// ## 不变量
/// 1. **同一份 `StockQuote`**：各源的单位/字段布局差异全部在适配器里消化掉
///    （手 vs 股、万元 vs 元、亿 vs 元），池和 UI 只认模型。
/// 2. **能力声明**：源没有的字段（如新浪没有涨跌停价）必须在 `capabilities` 里如实声明，
///    池据此做"硬过滤 + 软偏好"——不允许用 0 冒充缺失值。
/// 3. **可离线测**：解析函数是纯函数（`parse*`），网络只在 `fetchQuotes` 里发生。
public struct QuoteCapabilities: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// 沪深京 A 股 / 场内基金（6 位代码）
    public static let aShare = QuoteCapabilities(rawValue: 1 << 0)
    /// 港股（5 位代码）
    public static let hk = QuoteCapabilities(rawValue: 1 << 1)
    /// 指数（`indexes()` 入口专用）
    public static let index = QuoteCapabilities(rawValue: 1 << 2)
    /// PE / PB / 总市值 / 流通市值 / 量比 / 换手率
    public static let valuation = QuoteCapabilities(rawValue: 1 << 3)
    /// 涨停价 / 跌停价（详情页「涨跌停异动」判定要用）
    public static let limitPrices = QuoteCapabilities(rawValue: 1 << 4)

    /// 描述成日志/诊断页可读的形式
    public var labels: [String] {
        var out: [String] = []
        if contains(.aShare) { out.append("A股") }
        if contains(.hk) { out.append("港股") }
        if contains(.index) { out.append("指数") }
        if contains(.valuation) { out.append("估值") }
        if contains(.limitPrices) { out.append("涨跌停价") }
        return out
    }
}

public enum QuoteProviderError: Error, CustomStringConvertible, Sendable {
    case unsupported(String)
    case empty
    case malformed(String)
    case http(String)

    public var description: String {
        switch self {
        case .unsupported(let s): return "不支持：\(s)"
        case .empty: return "空响应"
        case .malformed(let s): return "解析失败：\(s)"
        case .http(let s): return "HTTP：\(s)"
        }
    }
}

/// 一个行情源。实现必须是 `Sendable`（池内并发调用）。
public protocol QuoteProvider: Sendable {
    /// 稳定标识（日志/诊断页/粘性记忆的键）
    var id: String { get }
    /// 如实声明能力；池用它做硬过滤与软偏好
    var capabilities: QuoteCapabilities { get }
    /// 批量拉取。`symbols` 是**带市场前缀的完整代码**（sh600519 / hk00700 / sh000001）。
    /// 返回值以同一个完整代码为键；拿不到的标的**不出现**（不要用 0 占位）。
    func fetchQuotes(_ symbols: [String]) async throws -> [String: StockQuote]
}

/// 代码口径的统一入口（池与各适配器共用）。
public enum QuoteSymbol {

    /// 输入 `600519` / `sh600519` / `SH600519` → 带前缀的完整代码；形状非法返回 nil。
    public static func full(_ code: String) -> String? {
        let lowered = code.lowercased()
        for p in ["sh", "sz", "bj", "hk"] where lowered.hasPrefix(p) && lowered.count > 2 {
            let digits = String(lowered.dropFirst(2))
            guard DataSourceEndpoints.isQuoteCode(digits) else { return nil }
            return lowered
        }
        let d = StockQuotes.digits(code)
        guard DataSourceEndpoints.isQuoteCode(d) else { return nil }
        return StockQuotes.inferMarket(code: d) + d
    }

    /// 完整代码 → 市场前缀（sh/sz/bj/hk）
    public static func market(_ full: String) -> String {
        String(full.prefix(2)).lowercased()
    }

    /// 是否指数（`sh000xxx` / `sz399xxx` / `bj899xxx`）。
    ///
    /// ⚠ **不能只看数字**：`sz000001` 是平安银行、`sh000001` 是上证指数 ——
    /// 同数字不同市场，所以前缀必须一起判。
    public static func isIndex(_ full: String) -> Bool {
        let m = market(full)
        let d = StockQuotes.digits(full)
        switch m {
        case "sh": return d.hasPrefix("000")
        case "sz": return d.hasPrefix("399")
        case "bj": return d.hasPrefix("899")
        default: return false
        }
    }

    /// 完整代码 → 东财 `secid`（`1.600519` / `0.000001` / `116.00700`）。
    /// 实测：沪市 1、深市与北交所都是 0、港股 116（2026-10-30 逐只核对）。
    public static func eastmoneySecid(_ full: String) -> String? {
        let d = StockQuotes.digits(full)
        guard !d.isEmpty, d.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        switch market(full) {
        case "sh": return "1." + d
        case "sz", "bj": return "0." + d
        case "hk": return "116." + d
        default: return nil
        }
    }

    /// 一批完整代码所需的市场能力（用于池的硬过滤）
    public static func capabilities(for symbols: [String]) -> QuoteCapabilities {
        var out: QuoteCapabilities = []
        for s in symbols {
            switch market(s) {
            case "hk": out.insert(.hk)
            default: out.insert(.aShare)
            }
        }
        return out
    }
}
