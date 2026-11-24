import Foundation

/// K 线数据质量。
///
/// **为什么需要**：`computeDeepInfo` 的每个窗口都是 `suffix(n)` —— 对**长期停牌**的票，
/// 它的「MA20」「5 日均量」会静默地跨越大半年：数值看起来完全正常，口径却已经失真，
/// 而且三轮扫描会**恒等**地一起失真（同一份 K 线缓存），从结果上完全看不出来。
///
/// 引擎已有两道防线，但**都不覆盖「根数够、跨度异常」**这一类：
///   · K 线 < 10 根 → `computeDeepInfo` 直接返回 nil（整只票跳过，不是"标记为可疑"）
///   · 不足 6 根 → `cum_5d` 给 null（该项不参与评分）
/// 本模块补的正是中间那一档：**根数够、但日期跨度明显异常**。
///
/// ⚠ **只做诊断、不参与任何判定**（与 `trend_state` 同一原则）；
/// 也**不改** `computeDeepInfo` 的计算 —— 要让它影响判定必须另提。
public struct DataQuality: Equatable, Sendable {

    /// 实际根数
    public let bars: Int
    /// 首末 bar 的日历跨度（含两端；0 = 无法判断）
    public let spanDays: Int
    /// 相邻 bar 的最大日历间隔（0 = 无法判断）
    public let maxGapDays: Int
    /// `ok` | `sparse`
    public let level: String

    /// 单处缺口阈值。正常最长间隔是长假（春节/国庆）+ 周末 ≈ 9~10 个日历日，
    /// 取 15 留足余量 —— 长期停牌会远超这个数。
    public static let sparseMaxGapDays = 15
    /// 跨度/根数 比值阈值。正常约 1.4（5 根/周）；超过 2.0 说明中间夹着成片的非交易日。
    public static let sparseSpanRatio = 2.0

    public init(bars: Int, spanDays: Int, maxGapDays: Int, level: String) {
        self.bars = bars
        self.spanDays = spanDays
        self.maxGapDays = maxGapDays
        self.level = level
    }

    /// 评估一段 K 线（纯函数）。
    ///
    /// 判 `sparse` 的四种情形（任一命中）：
    ///   ① 根数 < 10 —— 不足以支撑深度指标（与 `computeDeepInfo` 的门槛一致）
    ///   ② 有日期**无法解析**（`day` 不是 `yyyy-MM-dd`）—— 日期都读不出来的 K 线不可信
    ///   ③ 相邻间隔 > `sparseMaxGapDays`
    ///   ④ 跨度 > 根数 × `sparseSpanRatio`
    ///
    /// ⚠ ①② 与 ③④ 必须**都判**：只判 ③④ 会让"5 根正常工作日"被判成 `ok`
    /// （跨度和间隔都正常，只是根数根本不够）。
    public static func evaluate(_ kline: [KLineBar]) -> DataQuality {
        let bars = kline.count
        let days = kline.compactMap { TradingCalendar.parse($0.day) }
        let unparsable = days.count != bars

        // 少于两根 → 跨度/间隔无从判断，如实给 0（不猜），但根数规则照常生效
        var spanDays = 0
        var maxGap = 0
        if days.count >= 2, let first = days.first, let last = days.last {
            let day = 86400.0
            spanDays = Int((last.timeIntervalSince(first) / day).rounded()) + 1
            for i in 1..<days.count {
                let gap = Int((days[i].timeIntervalSince(days[i - 1]) / day).rounded())
                if gap > maxGap { maxGap = gap }
            }
        }

        let sparse = bars < 10
            || unparsable
            || maxGap > sparseMaxGapDays
            || (bars > 0 && Double(spanDays) > Double(bars) * sparseSpanRatio)
        return DataQuality(bars: bars, spanDays: spanDays, maxGapDays: maxGap,
                           level: sparse ? "sparse" : "ok")
    }

    public var isSparse: Bool { level == "sparse" }

    /// 落库形态（写进 `deep_info.data_quality`）
    public var json: [String: Any] {
        ["bars": bars, "span_days": spanDays, "max_gap_days": maxGapDays, "level": level]
    }

    /// 一句话说明（UI 用；`ok` 返回 nil —— 正常就不该占位）
    public var warningText: String? {
        guard isSparse else { return nil }
        if bars < 10 { return "K 线仅 \(bars) 根，深度指标不可靠" }
        return "K 线跨度异常（\(bars) 根跨 \(spanDays) 天，最大间隔 \(maxGapDays) 天）→ 均线/量能口径可能失真"
    }
}
