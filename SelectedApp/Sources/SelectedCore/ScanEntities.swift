import Foundation

// MARK: - 扫描结果实体（`ScanRunner.runRound` 的输出）
//
// 键集与类型以黄金夹具 `engine/tests/fixtures/2026-09-14/expected_scan_result{,_wide}.json`
// 为准；`ScanEntityTests` 把 `declaredKeys` 与夹具逐键比对 ——
// **漏键、拼错键都会红**，这是"实体与生产者一致"的唯一机械保证。

/// 一轮扫描的完整结果
public struct ScanResult: JSONEntity {
    public let json: JSONValue
    public init(_ json: JSONValue) { self.json = json }

    public static let declaredKeys: Set<String> = [
        "date", "slot", "slot_label", "run_time", "screener_version", "param_version",
        "market_env", "stats", "tier1", "tier2", "tier3",
        "excluded_deep_trend", "etf_recommendations",
        "elapsed_sec", "trading_day", "trading_day_reason", "data_source",
        "quote_coverage", "quote_requested",
        "budget_limited", "budget_note", "budget_skipped_codes",
        "status", "data_error", "persist_error",
    ]
    /// 路径相关键：
    /// · `budget_note` 只在**预算真的跳过了标的**时才有
    /// · `data_error` 只在 `data_insufficient` 分支
    /// · `persist_error` 只在 `persist_failed` 分支
    public static let conditionalKeys: Set<String> = [
        "budget_note", "data_error", "persist_error",
    ]

    // MARK: 元信息
    public var date: String { json.str("date") }
    public var slot: Int { json.integer("slot") }
    public var slotLabel: String { json.str("slot_label") }
    public var runTime: String { json.str("run_time") }
    public var screenerVersion: String { json.str("screener_version") }
    public var paramVersion: String { json.str("param_version") }

    // 展示用（缺失 → "-"）
    public var slotLabelDash: String { json.strOrDash("slot_label") }
    public var runTimeDash: String { json.strOrDash("run_time") }
    public var paramVersionDash: String { json.strOrDash("param_version") }

    // MARK: 状态
    /// `ok` / `not_trading_day` / `data_insufficient` / `persist_failed` / `params_invalid`
    public var status: String { json.str("status", "ok") }
    public var isOK: Bool { status == "ok" }
    /// `data_insufficient` 的原因（展示用，缺失 → "-"）
    public var dataErrorDash: String { json.strOrDash("data_error") }
    /// `params_invalid` 的原因（画像区间非法等，展示用，缺失 → "-"）
    public var paramsErrorDash: String { json.strOrDash("params_error") }

    /// `persist_failed` 的原因（展示用，缺失 → "-"）
    public var persistErrorDash: String { json.strOrDash("persist_error") }
    public var tradingDay: Bool { json.flag("trading_day", true) }
    public var tradingDayReason: String { json.str("trading_day_reason") }
    public var dataSource: String { json.str("data_source") }
    public var elapsedSec: Double { json.num("elapsed_sec") }
    public var quoteCoverage: Double { json.num("quote_coverage") }
    public var quoteRequested: Int { json.integer("quote_requested") }

    /// 深挖耗时预算被触发（该轮**不完整**，不能当完整轮次用于复盘/迭代）
    public var budgetLimited: Bool { json.flag("budget_limited") }
    public var budgetNote: String { json.str("budget_note") }
    /// 被预算跳过、**未被评分**的代码清单（信号分类据此判为"未验证"）
    public var budgetSkippedCodes: [String] { json.strings("budget_skipped_codes") }

    // MARK: 聚合
    /// 大盘环境 —— 与预判/库行**共用同一个 `MarketEnv`**
    public var marketEnv: MarketEnv { MarketEnv(json.object("market_env")) }
    public var stats: ScanStats { ScanStats(json.object("stats")) }
    public var tier1: [ScanPick] { json.objects("tier1").map(ScanPick.init) }
    public var tier2: [ScanPick] { json.objects("tier2").map(ScanPick.init) }
    public var tier3: [ScanPick] { json.objects("tier3").map(ScanPick.init) }
    public var excludedDeepTrend: [ScanExcluded] {
        json.objects("excluded_deep_trend").map(ScanExcluded.init)
    }
    public var etfRecommendations: [ScanEtfRec] {
        json.objects("etf_recommendations").map(ScanEtfRec.init)
    }

    /// 该轮落库用的**精简版**：只留统计与环境，明细走 picks 表
    public var slimJSON: JSONValue {
        JSONValue([
            "date": json.raw(at: "date"),
            "slot": json.raw(at: "slot"),
            "slot_label": json.raw(at: "slot_label"),
            "screener_version": json.raw(at: "screener_version"),
            "param_version": json.raw(at: "param_version"),
            "status": json.raw(at: "status") ?? "ok",
            "elapsed_sec": json.raw(at: "elapsed_sec"),
            "data_source": json.raw(at: "data_source"),
            "stats": json.raw(at: "stats") ?? [String: Any](),
            "market_env": json.raw(at: "market_env") ?? [String: Any](),
            "budget_limited": json.raw(at: "budget_limited") ?? false,
            "budget_note": json.raw(at: "budget_note") ?? "",
            "budget_skipped_codes": json.raw(at: "budget_skipped_codes") ?? [String](),
        ])
    }
}

/// 扫描漏斗统计（`stats`）
public struct ScanStats: JSONEntity {
    public let json: JSONValue
    public init(_ json: JSONValue) { self.json = json }

    public static let declaredKeys: Set<String> = [
        "total_scanned", "after_hard_filter", "candidates_zero_field",
        "after_profile_filter", "after_form_filter", "excluded_count",
        "final_count", "tier1_count", "tier2_count",
        "deep_processed", "deep_skipped_budget",
    ]

    public var totalScanned: Int { json.integer("total_scanned") }
    public var afterHardFilter: Int { json.integer("after_hard_filter") }
    public var candidatesZeroField: Int { json.integer("candidates_zero_field") }
    public var afterProfileFilter: Int { json.integer("after_profile_filter") }
    public var afterFormFilter: Int { json.integer("after_form_filter") }
    public var excludedCount: Int { json.integer("excluded_count") }
    public var finalCount: Int { json.integer("final_count") }
    public var tier1Count: Int { json.integer("tier1_count") }
    public var tier2Count: Int { json.integer("tier2_count") }
    public var deepProcessed: Int { json.integer("deep_processed") }
    public var deepSkippedBudget: Int { json.integer("deep_skipped_budget") }
}

/// 一只入选标的（`tier1`/`tier2`/`tier3` 元素）
public struct ScanPick: JSONEntity {
    public let json: JSONValue
    public init(_ json: JSONValue) { self.json = json }

    public static let declaredKeys: Set<String> = [
        "code", "name", "price", "change_pct", "volume_ratio", "turnover", "amplitude",
        "amount", "avg_price", "score", "score_raw",
        "ma_qualified", "tier_lock_applied", "market_weak",
        "deep_info", "score_details", "penalty_details",
    ]

    public var code: String { json.str("code") }
    public var name: String { json.str("name") }
    /// 展示用（缺失 → "-"）
    public var nameDash: String { json.strOrDash("name") }
    public var price: Double { json.num("price") }
    public var changePct: Double { json.num("change_pct") }
    /// 涨跌幅；缺失/非数值 → nil（视图里用 `PnlText(value:)` 显示"无数据"而不是 0%）
    public var changePctOrNil: Double? { json.numOrNil("change_pct") }
    public var volumeRatio: Double { json.num("volume_ratio") }
    public var turnover: Double { json.num("turnover") }
    public var amplitude: Double { json.num("amplitude") }
    /// 成交额（万元）
    public var amount: Double { json.num("amount") }
    public var avgPrice: Double { json.num("avg_price") }
    public var score: Int { json.integer("score") }
    /// 原始分（未加惩罚前）。键缺失时**回落 `score`** —— 与落库口径
    /// `p["score_raw"] ?? score` 一致（`ScanStore.persistRound`）
    public var scoreRaw: Int { json["score_raw"].int ?? score }
    /// 原始分（Double 口径，供展示）
    public var scoreRawValue: Double { json["score_raw"].double ?? json["score"].double ?? 0 }
    /// 压制后的分（Double 口径，供展示）
    public var scoreValue: Double { json["score"].double ?? 0 }
    /// ⚠ 缺省是 **true** —— 与 `ScanStore.persistRound` 的 `Self.bool(p["ma_qualified"], true)`
    /// 同口径；要改这个缺省请单独提（落库与读取两侧必须一致）。
    public var maQualified: Bool { json.flag("ma_qualified", true) }
    public var tierLockApplied: Bool { json.flag("tier_lock_applied") }
    public var marketWeak: Bool { json.flag("market_weak") }

    /// 评分明细（如 `"均线多头 +20"`）—— 展示用
    public var scoreDetails: [String] { json.strings("score_details") }
    public var penaltyDetails: [String] { json.strings("penalty_details") }

    public var deepInfo: ScanDeepInfo { ScanDeepInfo(json.object("deep_info")) }
}

/// 深度指标（`deep_info`）
public struct ScanDeepInfo: JSONEntity {
    public let json: JSONValue
    public init(_ json: JSONValue) { self.json = json }

    public static let declaredKeys: Set<String> = [
        "ma5", "ma10", "ma20", "ma_pass", "vol_mult_5d", "consec_up", "cum_5d",
        "prev_1d", "dist_from_low", "dist_from_high", "ma20_slope_up", "ma_deviation",
        "gain_ratio", "shadow_body_ratio", "intraday",
        "trend_state", "lock_confidence", "data_quality",
    ]

    /// `trend_state` / `lock_confidence` / `data_quality` 是**纯诊断**字段，黄金夹具里没有这些键。
    /// 声明为**条件键**，否则键覆盖测试会报「实体声明了引擎输出里不存在的键」。
    public static let conditionalKeys: Set<String> = ["trend_state", "lock_confidence", "data_quality"]

    public var ma5: Double { json.num("ma5") }
    public var ma10: Double { json.num("ma10") }
    public var ma20: Double { json.num("ma20") }
    public var maPass: Bool { json.flag("ma_pass") }
    /// ⚠ **可能显式为 null**（该值异常时调优侧计入 `score_errors`）
    public var volMult5d: Double? { json.numOrNil("vol_mult_5d") }
    public var consecUp: Int { json.integer("consec_up") }
    /// ⚠ **可能显式为 null**（唯一显式判空的指标）
    public var cum5d: Double? { json.numOrNil("cum_5d") }
    public var prev1d: Double { json.num("prev_1d") }
    public var distFromLow: Double { json.num("dist_from_low") }
    public var distFromHigh: Double { json.num("dist_from_high") }
    public var ma20SlopeUp: Bool { json.flag("ma20_slope_up") }
    public var maDeviation: Double { json.num("ma_deviation") }
    /// ⚠ **可能显式为 null**
    public var gainRatio: Double? { json.numOrNil("gain_ratio") }
    /// ⚠ **可能显式为 null**
    public var shadowBodyRatio: Double? { json.numOrNil("shadow_body_ratio") }
    public var intraday: ScanIntraday { ScanIntraday(json.object("intraday")) }

    /// 趋势状态：`BULL_ALIGNED` / `BULL_WEAKENING` / `MA_PULLBACK` /
    /// `BEAR_TREND` / `INSUFFICIENT`。
    ///
    /// ⚠ 返回**可选**而不是给默认值：老行**根本没有这个键** ——
    /// 那代表"这一轮没算过"，与 `INSUFFICIENT`（"算了但 K 线不够"）是两件事，
    /// 混成一个默认值就是「null 当 0 用」。
    public var trendStateOrNil: String? { json["trend_state"].string }

    /// 锁档信心：`high` / `likely_blunt` / `unknown` / `none`。
    /// 同上，老行没有此键 → nil（不要与 `none`「未被锁」混为一谈）。
    public var lockConfidenceOrNil: String? { json["lock_confidence"].string }

    /// K 线数据质量。老行没有此键 → nil（不是 `ok`）。
    public var dataQualityOrNil: ScanDataQuality? {
        json["data_quality"].isNull ? nil : ScanDataQuality(json.object("data_quality"))
    }
}

/// K 线数据质量（`deep_info.data_quality`，诊断字段）
public struct ScanDataQuality: JSONEntity {
    public let json: JSONValue
    public init(_ json: JSONValue) { self.json = json }

    public static let declaredKeys: Set<String> = ["bars", "span_days", "max_gap_days", "level"]

    public var bars: Int { json.integer("bars") }
    public var spanDays: Int { json.integer("span_days") }
    public var maxGapDays: Int { json.integer("max_gap_days") }
    /// `ok` | `sparse`
    public var level: String { json.str("level") }
    public var isSparse: Bool { level == "sparse" }
}

/// 尾盘分时结构（`deep_info.intraday`）
public struct ScanIntraday: JSONEntity {
    public let json: JSONValue
    public init(_ json: JSONValue) { self.json = json }

    public static let declaredKeys: Set<String> = [
        "bars_today", "last_bar_time", "elapsed_minutes",
        "tail_window_min", "tail_start", "tail_vol_ratio", "tail_vol_share",
        "tail_gain_pct", "tail_new_high", "close_position",
        "high_bucket", "day_high_time", "high_age_ratio",
    ]

    public var barsToday: Int { json.integer("bars_today") }
    public var lastBarTime: String { json.str("last_bar_time") }
    public var elapsedMinutes: Int { json.integer("elapsed_minutes") }
    public var tailWindowMin: Int { json.integer("tail_window_min") }
    public var tailStart: String { json.str("tail_start") }
    public var tailVolRatio: Double { json.num("tail_vol_ratio") }
    public var tailVolShare: Double { json.num("tail_vol_share") }
    public var tailGainPct: Double { json.num("tail_gain_pct") }
    public var tailNewHigh: Bool { json.flag("tail_new_high") }
    public var closePosition: Double { json.num("close_position") }
    /// `tail` / `open` / `mid` …
    public var highBucket: String { json.str("high_bucket") }
    public var dayHighTime: String { json.str("day_high_time") }
    /// 日内高点时刻；缺失 → nil（视图里"没有就不显示这一项"）
    public var dayHighTimeOrNil: String? { json["day_high_time"].string }
    public var highAgeRatio: Double { json.num("high_age_ratio") }
}

/// ETF 推荐（`etf_recommendations` 元素）
public struct ScanEtfRec: JSONEntity {
    public let json: JSONValue
    public init(_ json: JSONValue) { self.json = json }

    public static let declaredKeys: Set<String> = [
        "code", "name", "price", "change_pct", "volume_ratio", "turnover", "amount",
    ]

    public var code: String { json.str("code") }
    public var name: String { json.str("name") }
    /// 展示用（缺失 → "-"）
    public var nameDash: String { json.strOrDash("name") }
    public var price: Double { json.num("price") }
    public var changePct: Double { json.num("change_pct") }
    /// 涨跌幅；缺失/非数值 → nil（视图里用 `PnlText(value:)` 显示"无数据"而不是 0%）
    public var changePctOrNil: Double? { json.numOrNil("change_pct") }
    public var volumeRatio: Double { json.num("volume_ratio") }
    public var turnover: Double { json.num("turnover") }
    public var amount: Double { json.num("amount") }
}

/// 深度趋势排除项（`excluded_deep_trend` 元素）
public struct ScanExcluded: JSONEntity {
    public let json: JSONValue
    public init(_ json: JSONValue) { self.json = json }

    public static let declaredKeys: Set<String> = ["code", "name", "reason"]

    public var code: String { json.str("code") }
    public var name: String { json.str("name") }
    public var reason: String { json.str("reason") }
    /// 展示用（缺失 → "-"）
    public var nameDash: String { json.strOrDash("name") }
    public var reasonDash: String { json.strOrDash("reason") }
}

extension JSONValue {
    /// 取原始值（缺键 → nil），供需要"原样透传"的场景（如 `slimJSON`）
    func raw(at key: String) -> Any? {
        guard let d = raw as? [String: Any], let v = d[key] else { return nil }
        return v
    }
}
