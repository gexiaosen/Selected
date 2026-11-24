import Foundation

// MARK: - 看板 / 复盘**库行**实体（`SQLiteReader` 的读取结果）
//
// 夹具 `engine/tests/fixtures/dashboard_row_outputs/*.json` 是**真实捕获**的库行。
//
// ⚠ `signals` / `winrateTrend` 的捕获库不同：本机测试库里 `signal_classes` 与 `reviews`
// 常常是空的 —— 分别取自 compare 测试库（19 条 signal_classes）与 phase review 库。
// **夹具里没有的行，测试证明不了它**（这一点在 spec 里已写明）。

/// 当日轮次摘要行（≡ `SQLiteReader.todayRounds(_:)` 元素）
///
/// ⚠ 只保留 1/2/3 三个轮次里**存在**的那些（`[1,2,3].compactMap`）——
/// 所以"今天扫了几轮" = `roundSummaries.count`，而不是数组下标。
/// ⚠ 轮次集合的唯一来源是 `RoundPlan.slots`（审查 B8-1）；本行提及的 1/2/3 只是它的当前取值。
public struct RoundSummaryRow: JSONEntity {
    public let json: JSONValue
    public init(_ json: JSONValue) { self.json = json }

    public static let declaredKeys: Set<String> = [
        "round_id", "slot", "slot_label", "run_time",
        "tier1_count", "tier2_count", "param_version", "market_env",
    ]

    public var roundId: Int { json.integer("round_id") }
    /// 轮次号（1/2/3）
    public var slot: Int { json.integer("slot") }
    public var slotLabel: String { json.str("slot_label") }
    public var runTime: String { json.str("run_time") }
    public var tier1Count: Int { json.integer("tier1_count") }
    public var tier2Count: Int { json.integer("tier2_count") }
    public var paramVersion: String { json.str("param_version") }
    /// 落库的大盘环境 —— 与扫描结果/预判**共用同一个 `MarketEnv`**（决策 #2「统一」）。
    ///
    /// ⚠ 库里的键数是**历史形状**（12 / 13 / 15 / 16 / 17 键不等），
    /// 不是"落库漏了几个键" —— 详见 `MarketEnvEntities.swift` 的说明。
    /// `MarketEnv` 的 `declaredKeys` 取的是**并集**，所以任何历史形状都读得动；
    /// 读"这个来源可能没有"的键请用 `OrNil` 变体。
    public var marketEnv: MarketEnv { MarketEnv(json.object("market_env")) }
}

/// 信号分类行（≡ `SQLiteReader.signals(date:)` 元素）
public struct SignalClassRow: JSONEntity {
    public let json: JSONValue
    public init(_ json: JSONValue) { self.json = json }

    public static let declaredKeys: Set<String> = ["code", "name", "signal_type", "trend", "scores"]

    public var code: String { json.str("code") }
    public var name: String { json.str("name") }
    public var nameDash: String { json.strOrDash("name") }
    /// `strongest` / `consensus` / `pulse` / 其他（未识别归 `other`，由视图分组）
    public var signalType: String { json.str("signal_type") }
    /// 趋势描述（如 `评分递增`）
    public var trend: String { json.str("trend") }
    public var trendDash: String { json.strOrDash("trend") }
    /// 各轮得分（**键是轮次号**，不是数组）
    public var scores: [Int: Double] { json.bySlot("scores") { $0.double } }
}

/// 四层胜率跨日走势的一点（≡ `SQLiteReader.recentReviewWinrates(limit:)` 元素）
///
/// ⚠ 只含**有样本**的选股日（`window.total == 0` 的"无样本日"在读取层就被滤掉了），
/// 且返回时**已按日期升序**（读取层 `DESC` 查询后 `reversed()`）。
public struct WinrateTrendRow: JSONEntity {
    public let json: JSONValue
    public init(_ json: JSONValue) { self.json = json }

    public static let declaredKeys: Set<String> = ["date", "snapshot", "close", "window", "ceiling"]

    public var date: String { json.str("date") }
    public var dateDash: String { json.strOrDash("date") }
    public var snapshot: Double { json.num("snapshot") }
    public var close: Double { json.num("close") }
    public var window: Double { json.num("window") }
    public var ceiling: Double { json.num("ceiling") }

    /// 按**口径名**取胜率（`snapshot` / `close` / `window` / `ceiling`）。
    ///
    /// 视图要**遍历四个口径**画折线（`trendLayers` 是 `(key, name, color)` 列表），
    /// 所以需要一个按名字取值的入口。键名集中在这里，视图不再出现字符串键；
    /// 未知口径返回 `nil`。
    public func winrate(for layer: String) -> Double? {
        switch layer {
        case "snapshot": return json.numOrNil("snapshot")
        case "close": return json.numOrNil("close")
        case "window": return json.numOrNil("window")
        case "ceiling": return json.numOrNil("ceiling")
        default: return nil
        }
    }
}
