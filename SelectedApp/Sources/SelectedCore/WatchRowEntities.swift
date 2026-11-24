import Foundation

// MARK: - 自选**库行**实体（`SQLiteReader` 的读取结果）
//
// ⚠ 与 `WatchEntities.swift`（**判定产出**）是两回事，别看错：
//   · 本文件 = 从 `watch_groups` / `watchlist` / `watch_judgments` 三张表读出来的**行**
//   · `WatchEntities` = `WatchJudge.judge` 算出来的**判定结果**
// 同一个概念在两边形态不同（例：`is_holding` 在库行里是 **Int 0/1**，在判定产出里是 **Bool**），
// 这正是"不能按名字猜形状"的典型。
//
// 键集以夹具 `engine/tests/fixtures/watch_row_outputs/*.json`（真实捕获）为准。

/// 自选分组行（≡ `SQLiteReader.watchGroups()` 元素）
public struct WatchGroupRow: JSONEntity {
    public let json: JSONValue
    public init(_ json: JSONValue) { self.json = json }

    public static let declaredKeys: Set<String> = ["id", "name", "stock_count", "holding_count"]

    public var id: Int { json.integer("id") }
    public var name: String { json.str("name") }
    public var nameDash: String { json.strOrDash("name") }
    public var stockCount: Int { json.integer("stock_count") }
    /// 组内标记为持仓的只数
    public var holdingCount: Int { json.integer("holding_count") }
}

/// 自选列表行（≡ `SQLiteReader.watchlist()` 元素）
///
/// 由 `watchlist LEFT JOIN watch_judgments` 得到：后 4 个字段（`action`/`score`/
/// `target_price`/`stop_loss_price`）来自**最近一次判定**，没有判定时是空串 / 0。
public struct WatchItemRow: JSONEntity {
    public let json: JSONValue
    public init(_ json: JSONValue) { self.json = json }

    public static let declaredKeys: Set<String> = [
        "code", "name", "added_at", "group_id", "is_holding",
        "cost_price", "shares", "action", "score", "target_price", "stop_loss_price",
    ]

    public var code: String { json.str("code") }
    public var name: String { json.str("name") }
    /// 展示名：名称为空时回落代码（视图里的既有口径）
    public var displayName: String { name.isEmpty ? code : name }
    public var addedAt: String { json.str("added_at") }
    public var groupId: Int { json.integer("group_id", 1) }
    /// ⚠ 库行里是 **Int 0/1**（判定产出里是 `Bool`）—— SQL 里就是这么存的
    public var isHoldingRaw: Int { json.integer("is_holding") }
    public var isHolding: Bool { isHoldingRaw == 1 }
    /// 成本价；未填时库里是 `NULL` → 读取层折成 **0**（不是 nil）
    public var costPrice: Double { json.num("cost_price") }
    public var shares: Double { json.num("shares") }
    /// 最近一次判定的动作（无判定时为空串）
    public var action: String { json.str("action") }
    public var hasAction: Bool { !action.isEmpty }
    public var score: Int { json.integer("score") }
    public var targetPrice: Double { json.num("target_price") }
    public var stopLossPrice: Double { json.num("stop_loss_price") }
}

/// 某日全量判定行（≡ `SQLiteReader.watchJudgments(date:)` 元素）
public struct WatchJudgmentRow: JSONEntity {
    public let json: JSONValue
    public init(_ json: JSONValue) { self.json = json }

    public static let declaredKeys: Set<String> = [
        "code", "name", "action", "score", "details", "target_price", "stop_loss_price",
        "baseline_price", "sell_window", "position_advice", "risk_level", "market_light",
    ]

    public var code: String { json.str("code") }
    public var name: String { json.str("name") }
    public var nameDash: String { json.strOrDash("name") }
    public var action: String { json.str("action") }
    public var hasAction: Bool { !action.isEmpty }
    public var score: Int { json.integer("score") }
    /// 明细（`score_details` / `penalty_details`）
    public var details: JSONValue { json.object("details") }
    public var scoreDetails: [String] { details.strings("score_details") }
    public var penaltyDetails: [String] { details.strings("penalty_details") }
    public var targetPrice: Double { json.num("target_price") }
    public var targetPriceOrNil: Double? { json.numOrNil("target_price") }
    public var stopLossPrice: Double { json.num("stop_loss_price") }
    public var stopLossPriceOrNil: Double? { json.numOrNil("stop_loss_price") }
    public var baselinePrice: Double { json.num("baseline_price") }
    public var baselinePriceOrNil: Double? { json.numOrNil("baseline_price") }
    public var sellWindow: String { json.str("sell_window") }
    public var sellWindowDash: String { json.strOrDash("sell_window") }
    public var positionAdvice: String { json.str("position_advice") }
    public var positionAdviceDash: String { json.strOrDash("position_advice") }
    public var riskLevel: String { json.str("risk_level") }
    public var riskLevelDash: String { json.strOrDash("risk_level") }
    public var marketLight: String { json.str("market_light") }
}
