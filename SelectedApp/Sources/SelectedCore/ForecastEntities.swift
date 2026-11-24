import Foundation

// MARK: - 预报实体（`ForecastEngine.forecast` 的产出）
//
// 键集以 `engine/tests/fixtures/forecast_outputs/{normal,warned,early}.json` 为准：
// `normal` 正常 / `warned` 带涨跌停提示 / `early` 日K不足早退。

/// 一次预报的完整结果
///
/// ⚠ **三种键集形态**：
/// | 形态 | 键数 | 说明 |
/// |------|------|------|
/// | 正常 | 16 | 全字段 |
/// | 正常 + 涨跌停提示 | 17 | 多 `warnings` |
/// | 早退（日K不足） | 7 | 只有 `code`/`name`/`adjusted`/`params`/`caveats`/`status`/`data_error` |
public struct ForecastResult: JSONEntity {
    public let json: JSONValue
    public init(_ json: JSONValue) { self.json = json }

    public static let declaredKeys: Set<String> = [
        "code", "name", "adjusted", "params", "caveats", "status",
        "as_of", "base_close", "high_central", "high_optimistic",
        "low_central", "low_optimistic", "expected_range_pct",
        "baseline", "recent", "backtest",
        // 日K不足早退时才有
        "data_error",
        // 涨跌停提示（极端日之后区间参考意义下降）时才有
        "warnings",
    ]
    /// 形态相关键：
    /// · `data_error` 只在**早退**分支
    /// · `warnings` 只在有涨跌停提示时
    /// · 下面 10 个只在**非早退**分支（早退时没有基线与区间）
    public static let conditionalKeys: Set<String> = [
        "data_error", "warnings",
        "as_of", "base_close", "high_central", "high_optimistic",
        "low_central", "low_optimistic", "expected_range_pct",
        "baseline", "recent", "backtest",
    ]

    public var code: String { json.str("code") }
    public var name: String { json.str("name") }
    public var nameDash: String { json.strOrDash("name") }
    /// `ok` / `insufficient_data`
    public var status: String { json.str("status") }
    public var isOK: Bool { status == "ok" }
    /// 是否用了前复权数据（`false` = 除权日会有跳空，区间参考意义下降）
    public var adjusted: Bool { json.flag("adjusted", true) }
    /// 早退原因（日K不足 / 有效样本不足）
    public var dataError: String { json.str("data_error") }
    public var asOf: String { json.str("as_of") }
    /// 展示用（缺失 → "-"）
    public var asOfDash: String { json.strOrDash("as_of") }
    public var baseClose: Double { json.num("base_close") }
    public var highCentral: Double { json.num("high_central") }
    public var highOptimistic: Double { json.num("high_optimistic") }
    public var lowCentral: Double { json.num("low_central") }
    public var lowOptimistic: Double { json.num("low_optimistic") }
    public var expectedRangePct: Double { json.num("expected_range_pct") }

    // 展示用可选形态：缺失 → nil（视图里显示 "—" 而不是 0）
    public var baseCloseOrNil: Double? { json.numOrNil("base_close") }
    public var highCentralOrNil: Double? { json.numOrNil("high_central") }
    public var highOptimisticOrNil: Double? { json.numOrNil("high_optimistic") }
    public var lowCentralOrNil: Double? { json.numOrNil("low_central") }
    public var lowOptimisticOrNil: Double? { json.numOrNil("low_optimistic") }
    public var expectedRangePctOrNil: Double? { json.numOrNil("expected_range_pct") }
    /// 免责/口径说明（**不是**错误信息）
    public var caveats: [String] { json.strings("caveats") }
    public var warnings: [String] { json.strings("warnings") }

    public var params: ForecastParams { ForecastParams(json.object("params")) }
    /// 早退时没有基线（`nil`）
    public var baseline: ForecastBaseline? {
        json["baseline"].isNull ? nil : ForecastBaseline(json.object("baseline"))
    }
    public var recent: ForecastRecent? {
        json["recent"].isNull ? nil : ForecastRecent(json.object("recent"))
    }
    public var backtest: ForecastBacktest? {
        json["backtest"].isNull ? nil : ForecastBacktest(json.object("backtest"))
    }
}

public struct ForecastParams: JSONEntity {
    public let json: JSONValue
    public init(_ json: JSONValue) { self.json = json }

    public static let declaredKeys: Set<String> = ["base_days", "recent_days", "test_days"]

    public var baseDays: Int { json.integer("base_days") }
    public var recentDays: Int { json.integer("recent_days") }
    public var testDays: Int { json.integer("test_days") }
}

/// 基线（历史波动分布）
public struct ForecastBaseline: JSONEntity {
    public let json: JSONValue
    public init(_ json: JSONValue) { self.json = json }

    public static let declaredKeys: Set<String> = [
        "days", "avg_range_pct", "atr_pct", "high_pct", "low_pct",
        "close_up_ratio", "max_range_pct",
    ]

    public var days: Int { json.integer("days") }
    public var avgRangePct: Double { json.num("avg_range_pct") }
    /// 与 `avg_range_pct` **同一口径的别名**（为便于理解保留）
    public var atrPct: Double { json.num("atr_pct") }
    /// 收盘上涨天数占比
    public var closeUpRatio: Double { json.num("close_up_ratio") }
    public var maxRangePct: Double { json.num("max_range_pct") }
    public var highPct: ForecastBand { ForecastBand(json.object("high_pct")) }
    public var lowPct: ForecastBand { ForecastBand(json.object("low_pct")) }
}

/// 分位带（`p25` / `p50` / `p75`）
public struct ForecastBand: JSONEntity {
    public let json: JSONValue
    public init(_ json: JSONValue) { self.json = json }

    public static let declaredKeys: Set<String> = ["p25", "p50", "p75"]

    public var p25: Double { json.num("p25") }
    public var p50: Double { json.num("p50") }
    public var p75: Double { json.num("p75") }
}

/// 近期状态（波动倍数 k、趋势、量能）
///
/// ⚠ **两种形态**：
/// · 正常 → 7 键：`days` / `avg_range_pct` / `k_raw` / `k` / `k_clamped` / `streak` / `vol_mult`
/// · 近期无样本 → **只 3 键**：`days` / `k` / `note`
public struct ForecastRecent: JSONEntity {
    public let json: JSONValue
    public init(_ json: JSONValue) { self.json = json }

    public static let declaredKeys: Set<String> = [
        "days", "k", "note", "avg_range_pct", "k_raw", "k_clamped", "streak", "vol_mult",
    ]
    /// 正常分支**不带** `note`；早退分支只带 `note` + `days` + `k`
    public static let conditionalKeys: Set<String> = [
        "note", "avg_range_pct", "k_raw", "k_clamped", "streak", "vol_mult",
    ]

    public var days: Int { json.integer("days") }
    /// 波动倍数（已按上下限夹紧）
    public var k: Double { json.num("k") }
    public var note: String { json.str("note") }
    public var noteDash: String { json.strOrDash("note") }
    public var avgRangePct: Double { json.num("avg_range_pct") }
    /// 夹紧前的原始 k
    public var kRaw: Double { json.num("k_raw") }
    /// k 是否被上下限夹紧过（夹紧说明近期波动超出历史范围）
    public var kClamped: Bool { json.flag("k_clamped") }
    /// 连涨/连跌天数（正=连涨，负=连跌）
    public var streak: Int { json.integer("streak") }
    /// 近期量能倍数；`base_vol` 为 0 时是 `null`
    public var volMult: Double? { json.numOrNil("vol_mult") }
}

/// 逐日滚动回测（walk-forward）
///
/// ⚠ **两种形态**：
/// · 正常 → 8 键：`n` + 7 个统计量
/// · 历史长度不足 → **只 2 键**：`n` / `note`
public struct ForecastBacktest: JSONEntity {
    public let json: JSONValue
    public init(_ json: JSONValue) { self.json = json }

    public static let declaredKeys: Set<String> = [
        "n", "note", "high_within_upper", "low_above_lower", "both_covered",
        "high_in_band", "low_in_band", "high_median_err_pct", "low_median_err_pct",
    ]
    /// 正常分支**不带** `note`；早退分支只带 `note`
    public static let conditionalKeys: Set<String> = [
        "note", "high_within_upper", "low_above_lower", "both_covered",
        "high_in_band", "low_in_band", "high_median_err_pct", "low_median_err_pct",
    ]

    public var n: Int { json.integer("n") }
    public var note: String { json.str("note") }
    public var noteDash: String { json.strOrDash("note") }
    /// 实际高点 ≤ 上限的比例（越高越保守）
    public var highWithinUpper: Double { json.num("high_within_upper") }
    /// 实际低点 ≥ 下限的比例
    public var lowAboveLower: Double { json.num("low_above_lower") }
    /// 上下限同时覆盖的比例
    public var bothCovered: Double { json.num("both_covered") }
    /// 高点落在「中枢~乐观」区间内
    public var highInBand: Double { json.num("high_in_band") }
    public var lowInBand: Double { json.num("low_in_band") }
    public var highMedianErrPct: Double { json.num("high_median_err_pct") }
    public var lowMedianErrPct: Double { json.num("low_median_err_pct") }
}
