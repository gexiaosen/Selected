import XCTest
@testable import SelectedCore

/// **接口池选路**的离线单测。
///
/// ## 为什么这些必须离线可测
/// 池的价值恰恰在"某家挂了的那天"才体现 —— 而那天没法现测（真挂了才有现象）。
/// 这里用可控的桩 provider 把三条核心行为钉死：
/// ① 首选失败 → 自动换下一家，且失败被记进健康度；
/// ② 连续失败进冷却 → 后续轮次不再先打它（省掉每轮一个超时）；
/// ③ 粘性 —— 分差在抖动带内不来回切，但差距拉大时必须切。
final class QuotePoolTests: XCTestCase {

    // MARK: - 桩

    private final class StubProvider: QuoteProvider, @unchecked Sendable {
        let id: String
        let capabilities: QuoteCapabilities
        private let lock = NSLock()
        private var calls = 0
        private var failing: Bool

        init(id: String, capabilities: QuoteCapabilities = [.aShare], failing: Bool = false) {
            self.id = id
            self.capabilities = capabilities
            self.failing = failing
        }

        var callCount: Int { lock.withLock { calls } }

        func setFailing(_ v: Bool) { lock.withLock { failing = v } }

        func fetchQuotes(_ symbols: [String]) async throws -> [String: StockQuote] {
            let shouldFail = lock.withLock {
                calls += 1
                return failing
            }
            if shouldFail { throw QuoteProviderError.empty }
            return Dictionary(uniqueKeysWithValues: symbols.map { ($0, Self.sample($0)) })
        }

        static func sample(_ full: String, lag: TimeInterval = 0) -> StockQuote {
            StockQuote(market: QuoteSymbol.market(full),
                       code: StockQuotes.digits(full), name: "测试",
                       currentPrice: 10, previousClose: 9.9, openPrice: 9.95,
                       highPrice: 10.1, lowPrice: 9.9, volume: 100, turnover: 100,
                       change: 0.1, changePercent: 1,
                       turnoverRate: nil, peRatio: nil, marketCap: nil,
                       circulationMarketCap: nil, amplitude: nil, volumeRatio: nil,
                       pbRatio: nil, limitUp: nil, limitDown: nil,
                       quoteTime: Date().addingTimeInterval(-lag))
        }
    }

    private func healthy(_ id: String, successes: Int, latency: Double, lag: TimeInterval) -> ProviderHealth {
        var h = ProviderHealth()
        for _ in 0..<successes {
            h.recordSuccess(latency: latency, lag: lag, now: Date())
        }
        return h
    }

    // MARK: - 切换

    func testFailsOverToNextProviderAndRecordsFailure() async {
        let a = StubProvider(id: "a", failing: true)
        let b = StubProvider(id: "b")
        let pool = QuotePool(providers: [a, b])

        let out = await pool.quotes(["sh600519"])
        XCTAssertEqual(out.provider, "b")
        XCTAssertEqual(out.quotes.count, 1)
        XCTAssertNotNil(out.failures["a"])
        let ha = await pool.healthSnapshot(for: "a")
        XCTAssertEqual(ha?.failures, 1)
        XCTAssertEqual(a.callCount, 1)
        XCTAssertEqual(b.callCount, 1)
    }

    func testAllProvidersFailingReturnsEmptyNotCrash() async {
        let a = StubProvider(id: "a", failing: true)
        let b = StubProvider(id: "b", failing: true)
        let pool = QuotePool(providers: [a, b])

        let out = await pool.quotes(["sh600519"])
        XCTAssertTrue(out.isEmpty)
        XCTAssertNil(out.provider)
        XCTAssertEqual(out.failures.count, 2)
    }

    // MARK: - 熔断

    func testCoolingProviderIsSkipped() async {
        let a = StubProvider(id: "a")
        let b = StubProvider(id: "b")
        let pool = QuotePool(providers: [a, b])

        var ha = ProviderHealth()
        for _ in 0..<ProviderHealth.failureLimit {
            ha.recordFailure("挂了", now: Date())
        }
        XCTAssertNotNil(ha.cooldownUntil)
        await pool.setHealth(ha, for: "a")

        let out = await pool.quotes(["sh600519"])
        XCTAssertEqual(out.provider, "b")
        XCTAssertEqual(a.callCount, 0, "冷却中的源不该再被打")
    }

    func testAllCoolingStillTriesTheBestOne() async {
        let a = StubProvider(id: "a")
        let b = StubProvider(id: "b")
        let pool = QuotePool(providers: [a, b])

        var ha = ProviderHealth()
        for _ in 0..<ProviderHealth.failureLimit { ha.recordFailure("挂了", now: Date()) }
        var hb = ProviderHealth()
        for _ in 0..<ProviderHealth.failureLimit { hb.recordFailure("挂了", now: Date()) }
        await pool.setHealth(ha, for: "a")
        await pool.setHealth(hb, for: "b")

        let out = await pool.quotes(["sh600519"])
        XCTAssertFalse(out.isEmpty, "全部冷却时宁可选最不坏的，也不能整页没数")
    }

    // MARK: - 粘性

    func testStickyKeepsCurrentWhenScoreGapIsSmall() async {
        let a = StubProvider(id: "a", failing: true)
        let b = StubProvider(id: "b")
        let pool = QuotePool(providers: [a, b])

        // 第一轮：a 挂 → b 胜出，成为"当前源"
        _ = await pool.quotes(["sh600519"])
        XCTAssertEqual(b.callCount, 1)

        // a 恢复且略强于 b，但差距在 15% 粘性带内 → 不应切
        a.setFailing(false)
        await pool.setHealth(healthy("a", successes: 3, latency: 0.1, lag: 60), for: "a")
        await pool.setHealth(healthy("b", successes: 3, latency: 0.3, lag: 60), for: "b")

        let out = await pool.quotes(["sh600519"])
        XCTAssertEqual(out.provider, "b", "分差在粘性带内应保持当前源，避免来回切")
        XCTAssertEqual(a.callCount, 1, "粘性命中时不该先去打被换下的源")
    }

    func testSwitchesWhenGapExceedsThreshold() async {
        let a = StubProvider(id: "a", failing: true)
        let b = StubProvider(id: "b")
        let pool = QuotePool(providers: [a, b])

        _ = await pool.quotes(["sh600519"])     // b 成为当前源

        a.setFailing(false)
        await pool.setHealth(healthy("a", successes: 200, latency: 0.02, lag: 0), for: "a")
        await pool.setHealth(healthy("b", successes: 1, latency: 0.5, lag: 120), for: "b")

        let out = await pool.quotes(["sh600519"])
        XCTAssertEqual(out.provider, "a", "差距拉大时必须切到更优的源")
    }

    // MARK: - 能力过滤

    func testCapabilityFilterExcludesProviders() async {
        let a = StubProvider(id: "a", capabilities: [.aShare])
        let pool = QuotePool(providers: [a])

        let out = await pool.quotes(["sh000001"], requiring: .index)
        XCTAssertTrue(out.isEmpty)
        XCTAssertEqual(a.callCount, 0, "没有指数能力的源不该被调用")
    }

    func testSoftPreferenceRanksFieldCapableProviderFirst() async {
        let plain = StubProvider(id: "plain", capabilities: [.aShare])
        let rich = StubProvider(id: "rich", capabilities: [.aShare, .limitPrices])
        let pool = QuotePool(providers: [plain, rich])

        let ordered = await pool.order([plain, rich], key: "x", soft: .limitPrices, now: Date())
        XCTAssertEqual(ordered.first?.id, "rich", "能提供涨跌停价的源应在软偏好下排前")
    }

    // MARK: - 新鲜度

    func testMedianLagIgnoresSuspendedOutlier() async {
        let pool = QuotePool(providers: [])
        let quotes = [
            "sh600519": StubProvider.sample("sh600519", lag: 1),
            "sz000001": StubProvider.sample("sz000001", lag: 3),
            "sh600000": StubProvider.sample("sh600000", lag: 5000),   // 停牌股
        ]
        let lag = await pool.medianLag(quotes)
        XCTAssertNotNil(lag)
        XCTAssertLessThan(lag ?? .infinity, 10, "停牌股的旧时间戳不该把整批判成很旧")
    }

    func testFreshnessPenaltyIgnoredOnWeekendAndNonTradingDay() throws {
        let fmt = ChinaTime.formatter("yyyy-MM-dd HH:mm:ss")
        // 2026-10-10 是周六，10:00 虽在时段内但非交易日
        let saturdayMorning = try XCTUnwrap(fmt.date(from: "2026-10-10 10:00:00"))
        // 2026-10-12 是周一，10:00 为交易时段
        let mondayMorning = try XCTUnwrap(fmt.date(from: "2026-10-12 10:00:00"))

        var stale = ProviderHealth()
        stale.recordSuccess(latency: 0.1, lag: 7200, now: saturdayMorning)
        var noTimestamp = ProviderHealth()
        noTimestamp.recordSuccess(latency: 0.1, lag: nil, now: saturdayMorning)

        XCTAssertEqual(stale.score(now: saturdayMorning),
                       noTimestamp.score(now: saturdayMorning),
                       accuracy: 1e-9,
                       "周末即使在 09:30-15:00 窗口内也不得计算新鲜度扣分")
        XCTAssertEqual(stale.score(now: mondayMorning, isTradingDay: false),
                       noTimestamp.score(now: mondayMorning, isTradingDay: false),
                       accuracy: 1e-9,
                       "明确非交易日（如法定节假日）也不得计算新鲜度扣分")
        XCTAssertLessThan(stale.score(now: mondayMorning, isTradingDay: true),
                          noTimestamp.score(now: mondayMorning, isTradingDay: true),
                          "交易日盘中时段应正常惩罚过期快照")
    }
}
