import Foundation

// MARK: - 自选判定实体（`WatchJudge.judge` 的产出）
//
// 键集以夹具 `engine/tests/fixtures/watch_outputs/{base,red,noround,not_in_watchlist}.json`
// （真实引擎产出）为准。
//
// ⚠ **两种形态**：
// · 正常（`judged > 0`）→ 9 键，含 `market_trend` / `results` / `buys` / `sells`
// · 代码不在自选中（`judged == 0`）→ **只 5 键**：`date` / `judged` / `market_light` / `status` / `summary`

/// 一次自选判定（全部自选 或 指定单只）
public struct WatchJudgeResult: JSONEntity {
    public let json: JSONValue
    public init(_ json: JSONValue) { self.json = json }

    public static let declaredKeys: Set<String> = [
        "status", "date", "judged", "market_light", "market_trend",
        "results", "buys", "sells", "summary",
    ]
    /// `judged == 0`（代码不在自选中）时只输出 5 键，下面 4 个缺席
    public static let conditionalKeys: Set<String> = ["market_trend", "results", "buys", "sells"]

    public var status: String { json.str("status", "ok") }
    public var isOK: Bool { status == "ok" }
    public var date: String { json.str("date") }
    /// 实际判定的只数（0 = 该代码不在自选中）
    public var judged: Int { json.integer("judged") }
    /// 大盘灯级（`绿灯` / `黄灯` / `红灯`）
    public var marketLight: String { json.str("market_light") }
    public var marketLightDash: String { json.strOrDash("market_light") }
    public var marketTrend: String { json.str("market_trend") }
    public var marketTrendDash: String { json.strOrDash("market_trend") }
    /// 摘要（`买入 N · 卖出 M · 大盘X灯` 或 `NNNNNN 不在自选中`）
    public var summary: String { json.str("summary") }
    public var results: [WatchVerdict] { json.objects("results").map(WatchVerdict.init) }
    /// 买入标的**名称**列表（只有名称，没有代码 —— 与 `results` 里的 `code` 对应）
    public var buys: [String] { json.strings("buys") }
    /// 卖出列表：每项是 `[原因, 名称]` 二元组（如 `["止盈卖出", "盐田港"]`）
    public var sells: [[String]] { json.objects("sells").map { $0.strings() } }
}

/// 单只自选标的的判定结果
///
/// ⚠ **两种形态**（见 `watch_outputs/base.json` 的 `results[7]`）：
/// | 形态 | 键数 | 说明 |
/// |------|------|------|
/// | 正常 | 18 | 全字段 |
/// | **数据缺失**（行情取不到） | 13 | 缺 `change_pct` / `price` / `cost_price` / `shares` / `is_holding`；<br>且 `action = "数据缺失"`、`score_details = ["行情获取失败"]`、其余价位字段为 `null` |
public struct WatchVerdict: JSONEntity {
    public let json: JSONValue
    public init(_ json: JSONValue) { self.json = json }

    public static let declaredKeys: Set<String> = [
        "code", "name", "action", "price", "change_pct", "score",
        "risk_level", "position_advice", "market_light", "is_holding",
        "cost_price", "shares", "baseline_price", "target_price", "stop_loss_price",
        "sell_window", "score_details", "penalty_details",
    ]
    /// 行情取不到时（`action == "数据缺失"`）这 5 个键**不输出**
    public static let conditionalKeys: Set<String> = [
        "price", "change_pct", "cost_price", "shares", "is_holding",
    ]

    public var code: String { json.str("code") }
    public var name: String { json.str("name") }
    public var nameDash: String { json.strOrDash("name") }
    /// 操作建议：`买入` / `持有` / `卖出` / `观望` / **`数据缺失`** …
    public var action: String { json.str("action") }
    /// 行情取不到（该行只有 `code`/`name`/`action` 有意义）
    public var isDataMissing: Bool { action == "数据缺失" }
    public var price: Double { json.num("price") }
    public var priceOrNil: Double? { json.numOrNil("price") }
    public var changePct: Double { json.num("change_pct") }
    public var changePctOrNil: Double? { json.numOrNil("change_pct") }
    public var score: Int { json.integer("score") }
    /// 评分；**数据缺失时为 `null`**（不是 0 分）
    public var scoreOrNil: Int? { json.intOrNil("score") }
    /// `低` / `中` / `高` / `极高`；数据缺失时为 `null`
    public var riskLevel: String { json.str("risk_level") }
    public var riskLevelDash: String { json.strOrDash("risk_level") }
    public var positionAdvice: String { json.str("position_advice") }
    public var positionAdviceDash: String { json.strOrDash("position_advice") }
    public var marketLight: String { json.str("market_light") }
    /// 是否持仓（持仓才谈成本价与份额）
    public var isHolding: Bool { json.flag("is_holding") }
    /// 成本价；**未持仓时为 `null`**（不是 0）
    public var costPrice: Double? { json.numOrNil("cost_price") }
    /// 份额；**未持仓时为 `null`**
    public var shares: Double? { json.numOrNil("shares") }
    public var baselinePrice: Double { json.num("baseline_price") }
    public var baselinePriceOrNil: Double? { json.numOrNil("baseline_price") }
    public var targetPrice: Double { json.num("target_price") }
    public var targetPriceOrNil: Double? { json.numOrNil("target_price") }
    public var stopLossPrice: Double { json.num("stop_loss_price") }
    public var stopLossPriceOrNil: Double? { json.numOrNil("stop_loss_price") }
    /// 卖出窗口（如 `09:30~10:00`）；数据缺失时为 `null`
    public var sellWindow: String { json.str("sell_window") }
    public var sellWindowDash: String { json.strOrDash("sell_window") }
    public var scoreDetails: [String] { json.strings("score_details") }
    public var penaltyDetails: [String] { json.strings("penalty_details") }
}

private extension JSONValue {
    /// 把数组元素按字符串读（`sells` 的每个元素是 `[原因, 名称]`）
    func strings() -> [String] { array.compactMap { $0.string } }
}
