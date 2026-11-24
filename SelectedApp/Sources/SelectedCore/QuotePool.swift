import Foundation

/// 行情接口池 —— **运行时选源**。
///
/// ## 解决的问题
/// 2026-10-30 实测：东财 `push2`/`push2delay` 对同一出口间歇性空回包，`push2delay2` 稳定；
/// 三家源的"谁最快最稳"会随出口、时段、源侧限流变化 —— 写死任何一家都会在它挂时整页没价。
///
/// ## 选路规则（顺序即优先级）
/// 1. **硬过滤**：不满足市场能力（A股/港股/指数）的源直接出局；
/// 2. **冷却**：连续 3 败的源冷却 120s（除非全部候选都在冷却 —— 那时宁可选最不坏的）；
/// 3. **排序**：`ProviderHealth.score`（成功率 50% + 速度 25% + 新鲜度 25%）
///    + **软偏好加成**（能提供调用方想要的字段 +0.15）；
/// 4. **粘性**：当前源只要分数不低于最优的 85% 就不换 —— 防止两家分差在抖动带里来回切；
/// 5. **失败切换**：当前源抛错/空响应 → 立刻试下一家，并写 `data_source_logs`。
///
/// ## 探测
/// 交易时段每 5 分钟用 `sh000001` 探一次**所有**源，更新健康分。
/// 探针活在后台任务里，不进前台请求路径 —— 用户点开时选的已经是"上次测出来的最好那家"。
public actor QuotePool {

    public static let shared = QuotePool()

    /// 默认源顺序只是**冷启动先验**，之后完全由健康分决定
    public static var defaultProviders: [any QuoteProvider] {
        [TencentQuoteProvider(), EastmoneyQuoteProvider(), SinaQuoteProvider()]
    }

    public struct Outcome: Sendable {
        public let quotes: [String: StockQuote]
        public let provider: String?
        public let failures: [String: String]
        public var isEmpty: Bool { quotes.isEmpty }
    }

    public struct ProviderStatus: Sendable {
        public let id: String
        public let capabilities: [String]
        public let score: Double
        public let successRate: Double
        public let latencyMilliseconds: Double
        public let lagSeconds: Double?
        public let coolingDown: Bool
        public let lastFailure: String?
    }

    private let providers: [any QuoteProvider]
    private var health: [String: ProviderHealth]
    /// 每个"能力组合"当前选中的源（粘性记忆）
    private var preferred: [String: String] = [:]
    private var lastProbeAt: Date?
    private var probing = false

    /// 探针间隔：5 分钟（三家 × 1 只票 = 3 次请求，成本可忽略）
    public static let probeInterval: TimeInterval = 300
    /// 软偏好加成：有能力给字段但并非必需时，压过一点速度差
    static let softBonus: Double = 0.15
    /// 粘性阈值：当前源分数 ≥ 最优 × 0.85 就不换
    static let stickiness: Double = 0.85

    public init(providers: [any QuoteProvider] = QuotePool.defaultProviders) {
        self.providers = providers
        var h: [String: ProviderHealth] = [:]
        for p in providers { h[p.id] = ProviderHealth() }
        self.health = h
    }

    // MARK: - 取数

    public func quotes(_ symbols: [String],
                       requiring hard: QuoteCapabilities = [],
                       preferring soft: QuoteCapabilities = []) async -> Outcome {
        guard !symbols.isEmpty else { return Outcome(quotes: [:], provider: nil, failures: [:]) }
        let need = QuoteSymbol.capabilities(for: symbols).union(hard)
        let candidates = providers.filter { $0.capabilities.isSuperset(of: need) }
        guard !candidates.isEmpty else {
            DataSources.logDataSource("quote_pool", "no_provider",
                                      "没有源满足能力 [\(need.labels.joined(separator: ","))]")
            return Outcome(quotes: [:], provider: nil,
                           failures: ["*": "没有源满足能力 \(need.labels)"])
        }

        let now = Date()
        let key = "\(need.rawValue)"
        let ordered = order(candidates, key: key, soft: soft, now: now)
        let allCooling = ordered.allSatisfy { health[$0.id]?.isCoolingDown(now) ?? false }

        var failures: [String: String] = [:]
        for p in ordered {
            if !allCooling, health[p.id]?.isCoolingDown(now) == true {
                failures[p.id] = "冷却中"
                continue
            }
            let started = Date()
            do {
                let q = try await p.fetchQuotes(symbols)
                guard !q.isEmpty else { throw QuoteProviderError.empty }
                let latency = Date().timeIntervalSince(started)
                health[p.id]?.recordSuccess(latency: latency, lag: medianLag(q), now: Date())
                let previous = preferred[key]
                preferred[key] = p.id
                if let previous = previous, previous != p.id {
                    DataSources.logDataSource(
                        "quote_pool", "switched",
                        "\(symbols.count) 只：\(previous) → \(p.id)（\(p.id) "
                        + String(format: "%.0fms", latency * 1000)
                        + "，此前失败：\(failures.map { "\($0.key)=\($0.value)" }.joined(separator: "；"))）")
                }
                return Outcome(quotes: q, provider: p.id, failures: failures)
            } catch {
                let reason = String(describing: error)
                health[p.id]?.recordFailure(reason, now: Date())
                failures[p.id] = reason
                DataSources.logDataSource(
                    "quote_pool", "provider_failed",
                    "\(p.id) \(symbols.count) 只失败：\(reason)")
            }
        }

        preferred[key] = nil
        DataSources.logDataSource("quote_pool", "all_failed",
                                  "\(symbols.count) 只全部源失败："
                                  + failures.map { "\($0.key)=\($0.value)" }.joined(separator: "；"))
        return Outcome(quotes: [:], provider: nil, failures: failures)
    }

    /// 按健康分排序 + 粘性。`internal` 供单测直接调用。
    func order(_ candidates: [any QuoteProvider], key: String,
               soft: QuoteCapabilities, now: Date) -> [any QuoteProvider] {
        func score(_ p: any QuoteProvider) -> Double {
            (health[p.id]?.score(now: now) ?? 0)
                + (p.capabilities.isSuperset(of: soft) ? Self.softBonus : 0)
        }
        var sorted = candidates.sorted { score($0) > score($1) }
        guard let current = preferred[key],
              let idx = sorted.firstIndex(where: { $0.id == current }), idx > 0 else {
            return sorted
        }
        let best = score(sorted[0])
        if score(sorted[idx]) >= best * Self.stickiness {
            let item = sorted.remove(at: idx)
            sorted.insert(item, at: 0)
        }
        return sorted
    }

    /// 一批行情里"行情时间戳落后现在"的中位数（秒）。`nil` = 全部没有时间戳。
    ///
    /// 为什么取中位数而不是最大值：自选里可能有停牌股，它们的快照停在停牌前 ——
    /// 用最大值会把"源很新"误判成"源很旧"。中位数对少数离群值不敏感。
    func medianLag(_ quotes: [String: StockQuote], now: Date = Date()) -> TimeInterval? {
        let lags = quotes.values.compactMap { q -> TimeInterval? in
            guard let t = q.quoteTime else { return nil }
            return max(0, now.timeIntervalSince(t))
        }.sorted()
        guard !lags.isEmpty else { return nil }
        return lags[lags.count / 2]
    }

    // MARK: - 探针

    /// 交易时段每 `probeInterval` 秒探一次所有源。调用方负责"是否在时段内"的门控。
    public func probeIfNeeded(force: Bool = false) async {
        if !force, let last = lastProbeAt, Date().timeIntervalSince(last) < Self.probeInterval {
            return
        }
        guard !probing else { return }
        probing = true
        lastProbeAt = Date()
        defer { probing = false }

        for p in providers {
            let started = Date()
            do {
                let q = try await p.fetchQuotes(["sh000001"])
                guard !q.isEmpty else { throw QuoteProviderError.empty }
                health[p.id]?.recordSuccess(latency: Date().timeIntervalSince(started),
                                            lag: medianLag(q), now: Date())
            } catch {
                health[p.id]?.recordFailure(String(describing: error), now: Date())
            }
        }
    }

    // MARK: - 诊断

    public func status() -> [ProviderStatus] {
        let now = Date()
        return providers.map { p in
            let h = health[p.id] ?? ProviderHealth()
            return ProviderStatus(
                id: p.id,
                capabilities: p.capabilities.labels,
                score: h.score(now: now),
                successRate: h.successRate,
                latencyMilliseconds: h.ewmaLatency * 1000,
                lagSeconds: h.lastLag,
                coolingDown: h.isCoolingDown(now),
                lastFailure: h.lastFailureReason
            )
        }.sorted { $0.score > $1.score }
    }

    /// 当前每个能力组合选中的源（诊断页显示"现在实际在用哪家"）
    public func currentProviders() -> [String: String] { preferred }

    /// 单测用：直接改健康度（生产代码不要调）
    func setHealth(_ h: ProviderHealth, for id: String) { health[id] = h }

    func healthSnapshot(for id: String) -> ProviderHealth? { health[id] }
}
