import Foundation

// MARK: - 调优实体（`PhaseTune.tune` 的产出）
//
// 键集以夹具 `engine/tests/fixtures/tune_outputs/{global,nodata}.json`（真实引擎产出）为准。
//
// ⚠ **两种形态**：正常形态 / 空池（`status=no_data`）只 2 键（`status` + `error`）。
//
// ⚠ 动态键（用字典访问，语义正确）：
// · `dims` 是数组（21 个参数路径）✓ 不是字典
// · `diff` 的键是**参数点路径**（如 `scoring.tiers.tier2_min`）→ 字典
// · `metrics.by_metric` 的键是**口径名**（`l1`/`l3`/`window`/`close`/`ceiling`）→ 字典
// · `label_sources` 的键是**标签来源名**（`outcomes`/`reviews`）→ 字典

/// 一次调优的结果
public struct TuneResult: JSONEntity {
    public let json: JSONValue
    public init(_ json: JSONValue) { self.json = json }

    public static let declaredKeys: Set<String> = [
        "status", "baseline", "candidates", "dims", "elapsed_s", "label_sources",
        "metric", "metric_label", "policy_labeled", "policy_mismatch",
        "pool_dates", "pool_days", "pool_size", "pool_window",
        "scope", "scope_note", "warning",
        // 加分项同源相关性诊断（扩展字段）
        "correlation",
        // 样本门槛（扩展字段）
        "sample_gate",
        // 反事实覆盖诊断（扩展字段）
        "counterfactual",
        // 参数时代诊断（扩展字段）
        "param_eras", "param_era_warning",
        // 本次样本池的**口径**标记（扩展字段）
        "include_replay",
        // 空池早退时才有
        "error",
    ]
    /// 形态相关键：
    /// · `error` 只在 `status == no_data`（空池）时出现
    /// · `correlation` / `sample_gate` / `counterfactual` / `include_replay` 是**扩展诊断键**：
    ///   黄金夹具里没有、只在非空池路径出现 —— 必须算条件键
    /// · `param_eras` 非空池路径总有；`param_era_warning` 只在跨多个版本时出现
    /// · 其余只在**非空池**时出现 —— 空池早退时只输出 `status` + `error` 两个键
    public static let conditionalKeys: Set<String> = [
        "error", "correlation", "sample_gate", "counterfactual",
        "param_eras", "param_era_warning", "include_replay",
        "baseline", "candidates", "dims", "elapsed_s", "label_sources",
        "metric", "metric_label", "policy_labeled", "policy_mismatch",
        "pool_dates", "pool_days", "pool_size", "pool_window",
        "scope", "scope_note", "warning",
    ]

    /// `ok` / `no_data`
    public var status: String { json.str("status") }
    public var isOK: Bool { status == "ok" }
    /// 空池原因（**空池是有效结论**，不是错误 —— 样本不足就该直说）
    public var error: String { json.str("error") }
    public var errorDash: String { json.strOrDash("error") }
    public var metric: String { json.str("metric") }
    public var metricLabel: String { json.str("metric_label") }
    public var elapsedSec: Double { json.num("elapsed_s") }

    /// 评估池标的数（去重后）
    public var poolSize: Int { json.integer("pool_size") }
    /// 评估池跨了多少个交易日
    public var poolDates: Int { json.integer("pool_dates") }
    /// 池窗口（如 `2026-09-10 ~ 2026-09-11`）
    public var poolWindow: String { json.str("pool_window") }
    /// 池窗口；缺失 → nil（视图要区分"没有"与"空串"）
    public var poolWindowOrNil: String? { json["pool_window"].string }
    /// 本次样本池是否纳入了**历史回放样本**（扩展键）。
    ///
    /// 缺失（空池早退 / 老结果）→ `false`：与出厂默认「只用 live」一致，
    /// 且是**保守方向**（把"不知道"读成"只用 live"，不会把回放样本算成实盘口径）。
    public var includeReplay: Bool { json["include_replay"].bool ?? false }
    /// 调优维度（参数点路径，21 项）
    public var dims: [String] { json.strings("dims") }
    /// 样本量提示（如"样本仅 7 只，结果不具统计意义"）
    public var warning: String { json.str("warning") }

    /// 加分项同源相关性诊断（扩展键）。
    /// 空池早退 / 老结果 → nil（**不要回落成空对象**：那会让"没诊断过"看起来像"查过没发现"）。
    public var correlationOrNil: JSONValue? {
        json["correlation"].isNull ? nil : json["correlation"]
    }
    /// 高相关配对（已按 |ρ| 降序）；无诊断 → 空数组
    public var correlationPairs: [JSONValue] { json["correlation"]["pairs"].array }
    /// 诊断口径与局限说明（含"量的是特征不是得分"这句）
    public var correlationNote: String { json["correlation"].str("note") }
    /// 诊断用的成对样本数
    public var correlationSamples: Int { json["correlation"].integer("samples") }
    public var warningDash: String { json.strOrDash("warning") }

    /// 样本门槛（扩展键）。空池早退 / 老结果 → nil
    /// （**不回落成 `sufficient=true`**：那会把"没判过"当成"样本够"）
    public var sampleGateOrNil: JSONValue? {
        json["sample_gate"].isNull ? nil : json["sample_gate"]
    }
    /// 结论是否可信；**没有判据时按"不足"处理** —— 宁可不给结论，也不给一个没有依据的结论
    public var sampleSufficient: Bool { json["sample_gate"].flag("sufficient") }
    /// 参与结论的样本数（缺失 → 0）
    public var sampleCount: Int { json["sample_gate"].integer("samples") }
    public var sampleThreshold: Int { json["sample_gate"].integer("threshold") }
    /// 面向用户的说明（样本充足 → 空串）
    public var sampleGateMessage: String {
        guard sampleGateOrNil != nil else { return "" }
        return SampleGate.message(samples: sampleCount, threshold: sampleThreshold)
    }

    /// 反事实覆盖诊断（扩展键）。空池早退 / 老结果 → nil
    public var counterfactualOrNil: JSONValue? {
        json["counterfactual"].isNull ? nil : json["counterfactual"]
    }
    /// 同一评估窗口内被淘汰（未并入池）的样本条数
    public var counterfactualExcluded: Int { json["counterfactual"].integer("excluded_in_window") }
    /// 其中带齐特征、可重新评分的条数（当前恒 0 —— `excluded_stocks` 没有那些列）
    public var counterfactualRescoreable: Int { json["counterfactual"].integer("excluded_rescoreable") }
    /// 缺口说明（供 UI 原样展示，措辞由 Core 统一给）
    public var counterfactualNote: String { json["counterfactual"].str("note") }

    /// 参数时代分布（扩展键）：键是**版本名**（`(未记录)` = 该日期查不到生效版本），
    /// 值是样本数。空池早退 / 老结果 → 空字典
    public var paramEras: [String: Int] {
        json.object("param_eras").dict.mapValues { $0.int ?? 0 }
    }
    /// 跨了几个参数版本（≤1 表示结论不混时代）
    public var paramEraCount: Int { paramEras.count }
    /// 混合时代告警（单一版本时为空串）
    public var paramEraWarning: String { json.str("param_era_warning") }
    /// 标签来源计数：键是来源名（`outcomes` / `reviews`）
    public var labelSources: [String: Int] {
        json.object("label_sources").dict.mapValues { $0.int ?? 0 }
    }
    /// 标签政策口径计数（标注来源与实际不符的条数）
    public var policyLabeled: Int { json.integer("policy_labeled") }
    public var policyMismatch: Int { json.integer("policy_mismatch") }

    public var baseline: TuneBaseline { TuneBaseline(json.object("baseline")) }
    public var candidates: [TuneCandidate] { json.objects("candidates").map(TuneCandidate.init) }
}

public struct TuneBaseline: JSONEntity {
    public let json: JSONValue
    public init(_ json: JSONValue) { self.json = json }

    public static let declaredKeys: Set<String> = ["metrics"]
    public var metrics: TuneMetrics { TuneMetrics(json.object("metrics")) }
}

/// 一个候选参数组合（`diff` = 相对基线的改动）
public struct TuneCandidate: JSONEntity {
    public let json: JSONValue
    public init(_ json: JSONValue) { self.json = json }

    public static let declaredKeys: Set<String> = ["backtest", "diff", "metrics"]

    public var metrics: TuneMetrics { TuneMetrics(json.object("metrics")) }
    public var backtest: TuneBacktest { TuneBacktest(json.object("backtest")) }
    /// 相对基线的参数改动：键是**参数点路径**（如 `scoring.tiers.tier2_min`）→ 新值
    public var diff: [String: JSONValue] { json.object("diff").dict }
    /// 改了几项参数
    public var diffCount: Int { diff.count }
    /// diff 的原样字典形态（保存到个股覆盖时要用）
    public var diffAny: [String: Any] { diff.mapValues { $0.raw } }
    /// 该候选是否有回测
    public var hasBacktest: Bool { !json["backtest"].isNull }
}

/// 一组评估指标（`metrics`）
public struct TuneMetrics: JSONEntity {
    public let json: JSONValue
    public init(_ json: JSONValue) { self.json = json }

    public static let declaredKeys: Set<String> = [
        "metric", "metric_label", "metric_fallback",
        "total", "tier1", "tier2",
        "pool_size", "valid_size", "coverage_pct", "score_errors",
        "by_metric", "per_stock",
    ]

    /// 实际使用的口径名
    public var metric: String { json.str("metric") }
    public var metricLabel: String { json.str("metric_label") }
    /// ⚠ **有回退的样本数**：标签口径回退过说明结果口径与标注不符，必须能看见
    public var metricFallback: Double { json.num("metric_fallback") }
    /// 综合分
    public var total: Double { json.num("total") }
    public var poolSize: Int { json.integer("pool_size") }
    /// **有效样本数**（`pool_size` 里真正能算的）
    public var validSize: Int { json.integer("valid_size") }
    public var coveragePct: Double { json.num("coverage_pct") }
    /// 评分失败被丢弃的样本数
    public var scoreErrors: Int { json.integer("score_errors") }
    public var tier1: TuneTierStats { TuneTierStats(json.object("tier1")) }
    public var tier2: TuneTierStats { TuneTierStats(json.object("tier2")) }
    /// 逐口径统计：键是**口径名**（`l1`/`l3`/`window`/`close`/`ceiling`）
    public var byMetric: [String: TuneMetricStat] {
        json.object("by_metric").dict.mapValues(TuneMetricStat.init)
    }
    public var perStock: [TunePerStockRow] {
        json.objects("per_stock").map(TunePerStockRow.init)
    }
}

/// 档位统计（`tier1` / `tier2`）
public struct TuneTierStats: JSONEntity {
    public let json: JSONValue
    public init(_ json: JSONValue) { self.json = json }

    public static let declaredKeys: Set<String> = [
        "n", "wins", "winrate", "avg_profit", "labeled", "labeled_fallback",
    ]

    public var n: Int { json.integer("n") }
    public var wins: Int { json.integer("wins") }
    public var winrate: Double { json.num("winrate") }
    public var avgProfit: Double { json.num("avg_profit") }
    /// 有标签的样本数
    public var labeled: Int { json.integer("labeled") }
    /// 其中**标签口径回退过**的样本数
    public var labeledFallback: Int { json.integer("labeled_fallback") }
}

/// 单个口径的统计（`by_metric` 元素）
public struct TuneMetricStat: JSONEntity {
    public let json: JSONValue
    public init(_ json: JSONValue) { self.json = json }

    public static let declaredKeys: Set<String> = [
        "label", "winrate", "avg_profit", "labeled", "fallback", "tier1_n",
    ]

    public var label: String { json.str("label") }
    public var winrate: Double { json.num("winrate") }
    public var avgProfit: Double { json.num("avg_profit") }
    public var labeled: Int { json.integer("labeled") }
    /// 该口径下**标签回退过**的样本数
    public var fallback: Int { json.integer("fallback") }
    public var tier1N: Int { json.integer("tier1_n") }
}

/// 池内一条样本（`per_stock` 元素）
public struct TunePerStockRow: JSONEntity {
    public let json: JSONValue
    public init(_ json: JSONValue) { self.json = json }

    public static let declaredKeys: Set<String> = ["code", "name", "date", "tier", "score", "profit", "win"]

    public var code: String { json.str("code") }
    public var name: String { json.str("name") }
    public var nameDash: String { json.strOrDash("name") }
    public var date: String { json.str("date") }
    public var tier: Int { json.integer("tier") }
    public var score: Int { json.integer("score") }
    public var profit: Double { json.num("profit") }
    public var win: Bool { json.flag("win") }
}

/// 候选参数的样本内回测
public struct TuneBacktest: JSONEntity {
    public let json: JSONValue
    public init(_ json: JSONValue) { self.json = json }

    public static let declaredKeys: Set<String> = ["rows", "summary"]

    public var rows: [TuneBacktestRow] { json.objects("rows").map(TuneBacktestRow.init) }
    public var summary: TuneBacktestSummary { TuneBacktestSummary(json.object("summary")) }
}

/// 回测汇总（新老参数对比）
public struct TuneBacktestSummary: JSONEntity {
    public let json: JSONValue
    public init(_ json: JSONValue) { self.json = json }

    public static let declaredKeys: Set<String> = [
        "old", "new", "total_delta", "winrate_delta", "avg_profit_delta",
        "good_changes", "bad_changes",
    ]

    public var old: TuneSideStats { TuneSideStats(json.object("old")) }
    public var new: TuneSideStats { TuneSideStats(json.object("new")) }
    /// 综合分变化（新 − 老）
    public var totalDelta: Double { json.num("total_delta") }
    /// 胜率变化（百分点）
    public var winrateDelta: Double { json.num("winrate_delta") }
    public var avgProfitDelta: Double { json.num("avg_profit_delta") }
    /// 变好的标的数 / 变坏的标的数
    public var goodChanges: Int { json.integer("good_changes") }
    public var badChanges: Int { json.integer("bad_changes") }
}

/// 回测里的一侧（老参数 / 新参数）
public struct TuneSideStats: JSONEntity {
    public let json: JSONValue
    public init(_ json: JSONValue) { self.json = json }

    public static let declaredKeys: Set<String> = ["total", "coverage_pct", "tier1"]

    public var total: Double { json.num("total") }
    public var coveragePct: Double { json.num("coverage_pct") }
    public var tier1: TuneTierStats { TuneTierStats(json.object("tier1")) }
}

/// 回测里的一行（逐标的）
public struct TuneBacktestRow: JSONEntity {
    public let json: JSONValue
    public init(_ json: JSONValue) { self.json = json }

    public static let declaredKeys: Set<String> = [
        "code", "name", "change", "old_score", "new_score", "old_tier", "new_tier", "profit", "win",
    ]

    public var code: String { json.str("code") }
    public var name: String { json.str("name") }
    public var nameDash: String { json.strOrDash("name") }
    /// `up` / `down` / `same`
    public var change: String { json.str("change") }
    public var oldScore: Int { json.integer("old_score") }
    public var newScore: Int { json.integer("new_score") }
    public var oldTier: Int { json.integer("old_tier") }
    public var newTier: Int { json.integer("new_tier") }
    public var profit: Double { json.num("profit") }
    /// 次日实盘收益；缺失 → nil（视图显示 "-" 而不是 0%）
    public var profitOrNil: Double? { json.numOrNil("profit") }
    public var win: Bool { json.flag("win") }
}
