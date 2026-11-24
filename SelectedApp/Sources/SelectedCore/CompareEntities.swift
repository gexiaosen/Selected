import Foundation

// MARK: - 三轮对比实体（`CompareStore.runOnce` 的产出）
//
// 键集以 `engine/tests/fixtures/compare_outputs/{full,nodata,budget}.json` 为准；
// `CompareEntityTests` 做键覆盖 + 无损往返校验。
//
// ⚠ `signals` 是**动态键**（键是证券代码）→ 用字典访问，语义正确。

/// 一份三轮对比报告
public struct CompareReport: JSONEntity {
    public let json: JSONValue
    public init(_ json: JSONValue) { self.json = json }

    public static let declaredKeys: Set<String> = [
        "date", "status", "available_slots", "signals", "stability",
        "tier1_matrix", "tier2_matrix", "tier_changes", "etf_matrix",
        "excluded_table", "funnel_table", "market_env_table",
        "suggestions", "warnings",
        // 仅预算被截断的轮次才有
        "budget_limited_slots",
    ]
    /// `budget_limited_slots` 只在**有轮次被预算截断**时出现（`full`/`nodata` 夹具里没有）
    public static let conditionalKeys: Set<String> = ["budget_limited_slots"]

    public var date: String { json.str("date") }
    /// `ok` / `no_data`
    public var status: String { json.str("status") }
    public var isOK: Bool { status == "ok" }

    /// `status` 的**展示层中文名**。
    ///
    /// `status` 是引擎的机器字段（snake_case 英文），用户可见文案不许直接插英文常量；
    /// 映射收在**本属性一处**。
    ///
    /// ## ⚠ 未知取值**不吞掉、也不裸显**
    /// 映射表里没有的取值（引擎将来新增、或历史数据里没见过的值）返回「未识别状态」，
    /// UI 上不直接显示英文常量。
    public var statusLabel: String {
        switch status {
        case "ok": return "正常"
        case "no_data": return "当日出票不足"
        case "no_sel_data": return "当日无选中标的"
        case "not_trading_day": return "非交易日"
        case "data_insufficient": return "数据不足"
        case "budget_exceeded": return "超出取数预算"
        case "failed": return "生成失败"
        default: return "未识别状态"
        }
    }
    /// 有数据的轮次（升序）
    public var availableSlots: [Int] { json.object("available_slots").array.compactMap { $0.int } }
    public var warnings: [String] { json.strings("warnings") }
    /// 被深挖预算截断、该轮**不完整**的轮次号
    public var budgetLimitedSlots: [Int] {
        json.object("budget_limited_slots").array.compactMap { $0.int }
    }

    /// 逐标的信号：键是**证券代码**（动态键）→ 用字典
    public var signals: [String: CompareSignal] {
        json.object("signals").dict.mapValues(CompareSignal.init)
    }
    public var stability: CompareStability { CompareStability(json.object("stability")) }
    public var tier1Matrix: [CompareMatrixRow] { json.objects("tier1_matrix").map(CompareMatrixRow.init) }
    public var tier2Matrix: [CompareMatrixRow] { json.objects("tier2_matrix").map(CompareMatrixRow.init) }
    public var tierChanges: [CompareTierChange] { json.objects("tier_changes").map(CompareTierChange.init) }
    public var etfMatrix: [CompareEtfRow] { json.objects("etf_matrix").map(CompareEtfRow.init) }
    public var excludedTable: [CompareExcludedRow] {
        json.objects("excluded_table").map(CompareExcludedRow.init)
    }
    public var funnelTable: [CompareFunnelRow] { json.objects("funnel_table").map(CompareFunnelRow.init) }
    public var marketEnvTable: [CompareMarketEnvRow] {
        json.objects("market_env_table").map(CompareMarketEnvRow.init)
    }
    public var suggestions: [CompareSuggestion] {
        json.objects("suggestions").map(CompareSuggestion.init)
    }
}

/// 持续性判定（**决定信号能不能当"高置信"用**）
///
/// ⚠ `status == no_data` 时引擎给的是**空对象 `{}`** —— 所有字段回默认，
/// 其中 `persistence_verified` 回 `false`（未验证），这正是想要的口径。
public struct CompareStability: JSONEntity {
    public let json: JSONValue
    public init(_ json: JSONValue) { self.json = json }

    public static let declaredKeys: Set<String> = [
        "persistence_verified", "always_tier1", "consensus", "declining",
        "final_new", "pulse_only", "unverified", "missing_slots",
        "slots_available", "slots_expected",
    ]

    /// 持续性是否已验证。**未验证时不得按"高置信"解读**（缺失轮次会伪造出一致性）
    public var persistenceVerified: Bool { json.flag("persistence_verified") }
    /// 显式标记未验证（键缺失**不算**）
    public var isExplicitlyUnverified: Bool { json["persistence_verified"].bool == false }
    /// 三轮均为一档
    public var alwaysTier1: [String] { json.strings("always_tier1") }
    /// 持续信号（≥2 轮出现）
    public var consensus: [String] { json.strings("consensus") }
    /// 逐轮走弱
    public var declining: [String] { json.strings("declining") }
    /// 末轮新进
    public var finalNew: [String] { json.strings("final_new") }
    /// 只出现一次的脉冲
    public var pulseOnly: [String] { json.strings("pulse_only") }
    /// 无法验证（所属轮次被预算截断）
    public var unverified: [String] { json.strings("unverified") }
    /// 缺失的轮次号
    public var missingSlots: [Int] { json.object("missing_slots").array.compactMap { $0.int } }
    public var slotsAvailable: [Int] {
        json.object("slots_available").array.compactMap { $0.int }
    }
    public var slotsExpected: [Int] {
        json.object("slots_expected").array.compactMap { $0.int }
    }
}

/// 一只标的的跨轮信号
public struct CompareSignal: JSONEntity {
    public let json: JSONValue
    public init(_ json: JSONValue) { self.json = json }

    public static let declaredKeys: Set<String> = [
        "name", "trend", "tiers", "scores", "signal_type", "signal_type_name",
        "signal_verified", "budget_limited", "slots_available", "slots_expected",
    ]

    public var name: String { json.str("name") }
    public var nameDash: String { json.strOrDash("name") }
    /// 趋势型：`评分递增` / `稳定` / `下降` / `波动` …
    public var trend: String { json.str("trend") }
    /// 展示用（缺失 → "-"）
    public var trendDash: String { json.strOrDash("trend") }
    /// 各轮档位（**键是轮次号**，不是数组）：`{1: 1, 2: 1, 3: 1}`
    public var tiers: [Int: Int] { json.bySlot("tiers") { $0.int } }
    /// 各轮得分（**键是轮次号**）
    public var scores: [Int: Double] { json.bySlot("scores") { $0.double } }
    public var signalType: String { json.str("signal_type") }
    public var signalTypeName: String { json.str("signal_type_name") }
    /// 信号是否**经过验证**（轮次不足时为 false，不得按"持续"解读）
    public var signalVerified: Bool { json.flag("signal_verified") }
    /// 所属轮次被预算截断 → 该标的**未被完整评分**
    public var budgetLimited: Bool { json.flag("budget_limited") }
    public var slotsAvailable: [Int] {
        json.object("slots_available").array.compactMap { $0.int }
    }
    public var slotsExpected: [Int] {
        json.object("slots_expected").array.compactMap { $0.int }
    }
}

/// 逐轮矩阵的一行（`tier1_matrix` / `tier2_matrix` 元素）
public struct CompareMatrixRow: JSONEntity {
    public let json: JSONValue
    public init(_ json: JSONValue) { self.json = json }

    public static let declaredKeys: Set<String> = [
        "code", "name", "tiers", "prices", "scores", "changes",
        "trend", "signal_type", "signal_type_name",
    ]

    public var code: String { json.str("code") }
    public var name: String { json.str("name") }
    public var nameDash: String { json.strOrDash("name") }
    /// 各轮档位（**键是轮次号**，不是数组）
    public var tiers: [Int: Int] { json.bySlot("tiers") { $0.int } }
    /// 各轮价格（**键是轮次号**）
    public var prices: [Int: Double] { json.bySlot("prices") { $0.double } }
    /// 各轮得分（**键是轮次号**）
    public var scores: [Int: Double] { json.bySlot("scores") { $0.double } }
    /// 逐轮得分变化（**键是轮次号**）
    public var changes: [Int: Double] { json.bySlot("changes") { $0.double } }
    public var trend: String { json.str("trend") }
    public var signalType: String { json.str("signal_type") }
    public var signalTypeName: String { json.str("signal_type_name") }
}

/// 档位变化（升/降档）
public struct CompareTierChange: JSONEntity {
    public let json: JSONValue
    public init(_ json: JSONValue) { self.json = json }

    public static let declaredKeys: Set<String> = ["code", "name", "change"]

    public var code: String { json.str("code") }
    public var name: String { json.str("name") }
    public var nameDash: String { json.strOrDash("name") }
    /// 变化描述（如 `三档→一档`）
    public var change: String { json.str("change") }
}

/// ETF 逐轮变化
public struct CompareEtfRow: JSONEntity {
    public let json: JSONValue
    public init(_ json: JSONValue) { self.json = json }

    public static let declaredKeys: Set<String> = ["code", "name", "changes"]

    public var code: String { json.str("code") }
    public var name: String { json.str("name") }
    public var nameDash: String { json.strOrDash("name") }
    /// 逐轮变化（**键是轮次号**，不是数组）
    public var changes: [Int: Double] { json.bySlot("changes") { $0.double } }
}

/// 深度排除项（附所属轮次）
public struct CompareExcludedRow: JSONEntity {
    public let json: JSONValue
    public init(_ json: JSONValue) { self.json = json }

    public static let declaredKeys: Set<String> = ["code", "name", "reasons", "slots"]

    public var code: String { json.str("code") }
    public var name: String { json.str("name") }
    public var nameDash: String { json.strOrDash("name") }
    /// 各轮排除原因（**键是轮次号**）
    public var reasons: [Int: String] { json.bySlot("reasons") { $0.string } }
    /// 出现过的轮次（**这是数组**，与 `reasons` 的形态不同）
    public var slots: [Int] { json.object("slots").array.compactMap { $0.int } }
}

/// 逐轮漏斗
public struct CompareFunnelRow: JSONEntity {
    public let json: JSONValue
    public init(_ json: JSONValue) { self.json = json }

    public static let declaredKeys: Set<String> = [
        "slot", "total_scanned", "after_hard_filter", "after_profile_filter",
        "after_form_filter", "excluded_count", "final_count", "tier1_count", "tier2_count",
    ]

    public var slot: Int { json.integer("slot") }
    public var totalScanned: Int { json.integer("total_scanned") }
    public var afterHardFilter: Int { json.integer("after_hard_filter") }
    public var afterProfileFilter: Int { json.integer("after_profile_filter") }
    public var afterFormFilter: Int { json.integer("after_form_filter") }
    public var excludedCount: Int { json.integer("excluded_count") }
    public var finalCount: Int { json.integer("final_count") }
    public var tier1Count: Int { json.integer("tier1_count") }
    public var tier2Count: Int { json.integer("tier2_count") }
}

/// 逐轮大盘环境（**与扫描的 `market_env` 键集不同**：这里多了 `slot` / `label`）
///
/// ⚠ 这是**派生形态**，不是引擎产出的 `market_env` 本身：由 `Signals.swift`
/// 从各轮 `market_env` 拍平成表格行、附上 `slot` / `label` 得到。
/// 环境字段是 `MarketEnv` 的**子集**（少 `sh_amplitude` / `ratio` / `sh_d1` / `sh_d2` /
/// `sh_decline_*`），所以这里保留独立的 `declaredKeys`；
/// 扫描结果 / 库行 / 预判三种来源已统一到 `MarketEnv`。
public struct CompareMarketEnvRow: JSONEntity {
    public let json: JSONValue
    public init(_ json: JSONValue) { self.json = json }

    public static let declaredKeys: Set<String> = [
        "slot", "label", "sh_price", "sh_change_pct", "up_count", "down_count",
        "flat_count", "ratio_ok", "sh_consecutive_decline", "sh_3d_trend", "sh_ok",
    ]

    public var slot: Int { json.integer("slot") }
    /// 档位标签（如 `红灯`）
    public var label: String { json.str("label") }
    public var labelDash: String { json.strOrDash("label") }
    public var shPrice: Double { json.num("sh_price") }
    public var shChangePct: Double { json.num("sh_change_pct") }
    public var shChangePctOrNil: Double? { json.numOrNil("sh_change_pct") }
    public var upCount: Int { json.integer("up_count") }
    public var downCount: Int { json.integer("down_count") }
    public var flatCount: Int { json.integer("flat_count") }
    public var ratioOK: Bool { json.flag("ratio_ok") }
    public var shConsecutiveDecline: Bool { json.flag("sh_consecutive_decline") }
    public var sh3dTrend: String { json.str("sh_3d_trend") }
    public var sh3dTrendDash: String { json.strOrDash("sh_3d_trend") }
    public var shOK: Bool { json.flag("sh_ok") }
}

/// 操作建议
public struct CompareSuggestion: JSONEntity {
    public let json: JSONValue
    public init(_ json: JSONValue) { self.json = json }

    public static let declaredKeys: Set<String> = ["text", "type"]

    public var text: String { json.str("text") }
    /// `info` / `warn` / `danger` …
    public var type: String { json.str("type") }
}
