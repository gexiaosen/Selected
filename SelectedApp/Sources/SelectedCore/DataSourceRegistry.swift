import Foundation

/// 取数**数据集注册表** —— "我们到底依赖哪些源、各自有几条退路"的唯一清单。
///
/// ## 为什么要有
/// 行情池解决了"行情从哪家取"，但 App 还依赖 K线 / 分时 / 板块 / 涨停池 / 资金流 / 龙虎榜…
/// 这些散落在各个 Source 文件里，**没有一个地方能回答**：
/// "现在哪条链路是单点？哪个源刚挂过？"
/// 本注册表给每个数据集登记：**候选源 + 失败策略**，并把运行时成败记成健康度。
///
/// ## 失败策略的四种形态（都是**有意选择**，不是没做）
/// - `.pool`：多源可互换（字段口径已对齐）→ 由 `QuotePool` / `KLineService` 自动切换；
/// - `.hostFallback`：同族 host 降级（`DataSources.httpGetWithHostFallback`）；
/// - `.singleSource`：**只有一家**（字段口径独有，换源等于换语义 —— 宁可没有也不给错数）。
///   典型：龙虎榜只有东财 data-center 有；涨停池大智慧那份缺成交额/封板资金/行业，接进来会静默降质。
/// - `.inferenceFallback`：主源给权威结论，取不到时退回一条**间接判据**（交易日历：官方月历 → 行情报价日期）。
public enum DataSetID: String, CaseIterable, Sendable {
    case quotes, kline, minute, boardHeat, boardMembers, fundamental
    case limitUpPool, fundFlow, eastmoneyFundFlow, lhb, indexMembers, stockList, fundList
    case depth, ticks, tradeCalendar
}

public enum DataSetFailurePolicy: String, Sendable {
    case pool = "多源自动切换"
    case hostFallback = "同族 host 降级"
    case singleSource = "单一源"
    /// 主源给**权威结论**、取不到时退回一条**间接判据**（不是同口径的另一家源）。
    /// 与 `.pool` 的区别：兜底那条会"猜"，所以结论必须带着 reason 一起走。
    case inferenceFallback = "权威源 + 推断兜底"
}

public enum DataSourceRegistry {

    public struct Entry: Sendable {
        public let id: DataSetID
        public let title: String
        public let providers: [String]
        public let policy: DataSetFailurePolicy
    }

    public struct Health: Sendable {
        public let id: DataSetID
        public let title: String
        public let policy: DataSetFailurePolicy
        public let requests: Int
        public let failures: Int
        public let lastSuccessAt: Date?
        public let lastFailureAt: Date?
        public let lastLatencyMilliseconds: Double?
        public var successRate: Double {
            Double(requests - failures) / Double(max(1, requests))
        }
    }

    public static let entries: [Entry] = [
        Entry(id: .quotes, title: "实时行情（自选/看板/详情）",
              providers: ["腾讯", "东财", "新浪"], policy: .pool),
        Entry(id: .kline, title: "K 线（日/周/月）",
              providers: ["腾讯（前复权）", "同花顺（前复权，仅日K）", "新浪（不复权兜底）"], policy: .pool),
        Entry(id: .minute, title: "分时",
              providers: ["腾讯", "东财"], policy: .pool),
        Entry(id: .depth, title: "五档盘口",
              providers: ["腾讯 qt 回包 f9…f28（与行情同一条回包）"], policy: .singleSource),
        Entry(id: .ticks, title: "分笔成交",
              providers: ["腾讯 stock.gtimg.cn 分页"], policy: .singleSource),
        Entry(id: .tradeCalendar, title: "交易日历（开休市判定）",
              providers: ["深交所 monthList", "上证行情报价日期（推断兜底）"], policy: .inferenceFallback),
        Entry(id: .boardHeat, title: "板块热度",
              providers: ["东财 push2"], policy: .hostFallback),
        Entry(id: .boardMembers, title: "板块成分",
              providers: ["东财 push2"], policy: .hostFallback),
        Entry(id: .fundamental, title: "基本面快照",
              providers: ["东财 push2"], policy: .hostFallback),
        Entry(id: .limitUpPool, title: "涨停池",
              providers: ["东财 push2ex"], policy: .singleSource),
        Entry(id: .fundFlow, title: "资金流",
              providers: ["新浪 MoneyFlow"], policy: .singleSource),
        // ⚠ **不与 `.fundFlow` 合并成"双源"**：2026-11-02 同日同票逐字段核对，
        //   新浪 `r0_net` 与东财"主力净流入"在 6 个交易日里**差到反号**
        //   （600000 于 10-30：新浪 -17,866,501 vs 东财 +7,525,885）。
        //   两家的"大单/特大单"划分与主动买卖认定规则不同 ⇒ 换源等于换语义，
        //   写进同一列就是静默污染（本文件文件头对 `.singleSource` 的定义）。
        //   所以东财这条**单独立册**，只作为东财口径的独立序列。
        Entry(id: .eastmoneyFundFlow, title: "资金流（东财口径）",
              providers: ["东财 push2his fflow/daykline"], policy: .singleSource),
        Entry(id: .lhb, title: "龙虎榜",
              providers: ["东财 data-center"], policy: .singleSource),
        Entry(id: .indexMembers, title: "指数成分",
              providers: ["新浪"], policy: .singleSource),
        Entry(id: .stockList, title: "证券主列表",
              providers: ["新浪 Market_Center"], policy: .singleSource),
        Entry(id: .fundList, title: "场内基金列表",
              providers: ["新浪"], policy: .singleSource),
    ]

    public static func entry(_ id: DataSetID) -> Entry? {
        entries.first { $0.id == id }
    }

    // MARK: - 运行时健康度

    private struct Counter {
        var requests = 0
        var failures = 0
        var lastSuccessAt: Date?
        var lastFailureAt: Date?
        var lastLatencyMS: Double?
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var counters: [DataSetID: Counter] = [:]

    /// 记录一次取数结果。`latencyMS` 传整段耗时（含重试），没有就留 nil。
    public static func report(_ id: DataSetID, ok: Bool,
                              latencyMS: Double? = nil, detail: String? = nil) {
        let now = Date()
        lock.lock()
        var c = counters[id] ?? Counter()
        c.requests += 1
        if ok {
            c.lastSuccessAt = now
            c.lastLatencyMS = latencyMS
        } else {
            c.failures += 1
            c.lastFailureAt = now
        }
        counters[id] = c
        lock.unlock()

        if let detail = detail {
            DataSources.logDataSource("registry", ok ? "ok" : "failed",
                                      "\(id.rawValue)：\(detail)")
        }
    }

    /// 同步取数入口的计时包装：`nil` = 失败。返回值原样透传。
    @discardableResult
    public static func timed<T>(_ id: DataSetID, _ body: () -> T?) -> T? {
        let started = Date()
        let result = body()
        report(id, ok: result != nil,
               latencyMS: Date().timeIntervalSince(started) * 1000)
        return result
    }

    /// 异步版本（K线/分时）
    public static func timedAsync<T>(_ id: DataSetID, _ body: () async -> T?) async -> T? {
        let started = Date()
        let result = await body()
        report(id, ok: result != nil,
               latencyMS: Date().timeIntervalSince(started) * 1000)
        return result
    }

    public static func health() -> [Health] {        lock.lock()
        let snapshot = counters
        lock.unlock()
        return entries.map { e in
            let c = snapshot[e.id] ?? Counter()
            return Health(id: e.id, title: e.title, policy: e.policy,
                          requests: c.requests, failures: c.failures,
                          lastSuccessAt: c.lastSuccessAt,
                          lastFailureAt: c.lastFailureAt,
                          lastLatencyMilliseconds: c.lastLatencyMS)
        }
    }

    /// 单源数据集清单（诊断/评审用）：这些是**已知单点**。
    public static var singleSourceDataSets: [DataSetID] {
        entries.filter { $0.policy == .singleSource }.map(\.id)
    }
}
