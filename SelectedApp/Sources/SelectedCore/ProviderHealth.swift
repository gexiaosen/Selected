import Foundation

/// 单个行情源的健康度 —— 池的"选谁"依据。
///
/// ## 三项分怎么来
/// - **成功率**：拉普拉斯平滑（`(s+1)/(s+f+2)`），避免"刚启动 1 次成功 = 100%"的假象；
/// - **速度**：EWMA 延迟（0.7 旧 + 0.3 新）——单次抖动不该把首选打下去；
/// - **新鲜度**：源给的最后行情时间与本地时钟之差，按 60 秒一档衰减。
///   这项是"及时"的直接度量：两家都快，但一家回的是 3 分钟前的快照，就该输。
///
/// ## 熔断
/// 连续 `failureLimit` 次失败 → 冷却 `cooldown` 秒。冷却期内除非**所有**候选都在冷却，
/// 否则不选它 —— 否则一个已挂的源会把每一轮都拖满超时才换下一个。
public struct ProviderHealth: Sendable, Equatable {

    public var successes = 0
    public var failures = 0
    public var consecutiveFailures = 0
    /// 指数滑动平均延迟（秒）
    public var ewmaLatency: Double = 0.35
    public var lastLatency: Double = 0.35
    public var lastSuccessAt: Date?
    public var lastFailureAt: Date?
    public var lastFailureReason: String?
    /// 最近一次成功时，行情时间戳落后本地时钟的秒数（`nil` = 该源不给时间戳）
    public var lastLag: TimeInterval?
    public var cooldownUntil: Date?

    public static let failureLimit = 3
    public static let cooldown: TimeInterval = 120

    public init() {}

    /// 成功率（拉普拉斯平滑）
    public var successRate: Double {
        Double(successes + 1) / Double(successes + failures + 2)
    }

    /// 速度分：0.1s → 0.91，1s → 0.5
    public var speedScore: Double { 1 / (1 + max(0, ewmaLatency)) }

    /// 新鲜度分：行情时间戳落后 0s → 1.0，落后 60s → 0.5
    public var freshnessScore: Double {
        guard let lag = lastLag else { return 0.5 }      // 不给时间戳的源按中性算
        return 1 / (1 + max(0, lag) / 60)
    }

    /// 综合分（0..1）。权重固定：成功率优先，其次速度与新鲜度。
    ///
    /// ⚠ **非交易日（含周末与官方日历休市）及非交易时段新鲜度不参与打分**：
    ///   收盘后/周末所有源的快照都停在上一交易日 15:00，照算滞后会把新鲜度打到接近 0，
    ///   让不给时间戳的源靠 0.5 中性分虚高胜出。新鲜度只在交易日盘中时段（`inSession`）生效。
    /// - Parameters:
    ///   - now: 评估时刻（默认当前时间）。
    ///   - isTradingDay: 可选交易日覆写；未传时按「非北京时间周末 且 未在官方日历缓存中判休市」判定（零网络阻塞）。
    public func score(now: Date = Date(), isTradingDay: Bool? = nil) -> Double {
        let tradingDay = isTradingDay
            ?? (!ChinaTime.isWeekend(now) && (TradingCalendarSource.cachedIsTradingDay(now) ?? true))
        let inSession = tradingDay && AlertWindow.inSession(minuteOfDay: ChinaTime.minutesOfDay(now))
        let fresh = inSession ? freshnessScore : 0.5
        return 0.5 * successRate + 0.25 * speedScore + 0.25 * fresh
    }

    public func isCoolingDown(_ now: Date) -> Bool {
        guard let until = cooldownUntil else { return false }
        return until > now
    }

    public mutating func recordSuccess(latency: TimeInterval, lag: TimeInterval?, now: Date) {
        successes += 1
        consecutiveFailures = 0
        lastLatency = latency
        ewmaLatency = ewmaLatency * 0.7 + max(0, latency) * 0.3
        lastSuccessAt = now
        if let lag = lag { lastLag = lag }
        cooldownUntil = nil
    }

    public mutating func recordFailure(_ reason: String, now: Date) {
        failures += 1
        consecutiveFailures += 1
        lastFailureAt = now
        lastFailureReason = reason
        if consecutiveFailures >= Self.failureLimit {
            cooldownUntil = now.addingTimeInterval(Self.cooldown)
        }
    }
}
