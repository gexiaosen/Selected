import Foundation

// MARK: - 四阶段输出实体（`PhasePredict` / `PhaseVerify` / `PhaseReview` / `PhaseIterate`）
//
// 键集以夹具 `engine/tests/fixtures/phase_outputs/*.json`（真实引擎输出）为准，
// 由 `PhaseEntityTests` 做键覆盖 + 无损往返校验。
//
// ⚠ 这三个是**动态键**，刻意不建模成固定 struct，而是暴露成字典/数组：
//   · `VerifyResult.groups` —— 键是中文分组名（`最强+持续` / `脉冲信号`）
//   · `ReviewStock.tpProfits` —— 键是时刻（`09:35` / `10:00` …）
//   · `*.scores` —— 键是轮次（`1` / `2` / `3`）
//   固定 struct 装不下它们；用字典访问是**语义正确**的，不是偷懒。

// MARK: - 早盘预判（predict）

/// 早盘预判结果（`PhasePredict` 产出）
public struct PredictResult: JSONEntity {
    public let json: JSONValue
    public init(_ json: JSONValue) { self.json = json }

    public static let declaredKeys: Set<String> = [
        "is_empty_day", "market_env", "overall", "persistence_verified",
        "predict_date", "predict_time", "sel_date", "status", "stocks",
    ]
    /// 库读取路径（`SQLiteReader.predictRow`）不带 `persistence_verified`
    public static let conditionalKeys: Set<String> = ["persistence_verified"]

    public var status: String { json.str("status", "ok") }
    public var isOK: Bool { status == "ok" }
    /// 当日无入档（空仓日）→ 没有标的可预判
    public var isEmptyDay: Bool { json.flag("is_empty_day") }
    /// 轮次不足时持续性未经验证（此时**不得**按"高置信"解读）
    public var persistenceVerified: Bool { json.flag("persistence_verified") }
    /// **显式**标记为"未验证"（键缺失**不算**）——
    /// 用 `!persistenceVerified` 会把"字段缺失"也当成未验证，是行为变更。
    public var isExplicitlyUnverified: Bool { json["persistence_verified"].bool == false }
    public var predictDate: String { json.str("predict_date") }
    public var predictTime: String { json.str("predict_time") }
    public var selDate: String { json.str("sel_date") }
    /// 展示用（缺失 → "-"）
    public var predictTimeDash: String { json.strOrDash("predict_time") }
    public var selDateDash: String { json.strOrDash("sel_date") }
    /// 大盘灯（展示用，缺失 → "-"）
    ///
    /// ⚠ `market_light` 是**自选判定**（`WatchJudge`）的键，本实体**从不产出**它 ——
    /// 不要读它，取 `market_env.light`。
    public var marketLightDash: String { marketEnv.lightDash }
    /// 总体结论（可多条）
    public var overall: [String] { json.strings("overall") }
    /// 大盘环境 —— 与扫描结果/库行**共用同一个 `MarketEnv`**。
    /// 预判来源只填其中 10 个键（`light` / `light_desc` / `open_status` /
    /// `sh_open_pct` / `us_market` 这 5 个是预判独有）。
    public var marketEnv: MarketEnv { MarketEnv(json.object("market_env")) }
    public var stocks: [PredictStock] { json.objects("stocks").map(PredictStock.init) }
}

/// 一只待预判标的
public struct PredictStock: JSONEntity {
    public let json: JSONValue
    public init(_ json: JSONValue) { self.json = json }

    public static let declaredKeys: Set<String> = [
        "code", "name", "current_pct", "current_price", "open_pct",
        "position_advice", "predict_direction", "risk_level", "scores",
        "sel_price", "sell_window_end", "sell_window_start",
        "signal_type", "signal_type_name", "signal_verified",
        "stop_loss_price", "strategy_key", "target_price", "turnover", "volume_ratio",
    ]

    public var code: String { json.str("code") }
    public var name: String { json.str("name") }
    public var nameDash: String { json.strOrDash("name") }
    public var currentPct: Double { json.num("current_pct") }
    public var currentPctOrNil: Double? { json.numOrNil("current_pct") }
    public var currentPrice: Double { json.num("current_price") }
    public var openPct: Double { json.num("open_pct") }
    public var positionAdvice: String { json.str("position_advice") }
    public var predictDirection: String { json.str("predict_direction") }
    /// `低` / `中` / `高` / `极高`
    public var riskLevel: String { json.str("risk_level") }
    public var selPrice: Double { json.num("sel_price") }
    /// 卖出窗口起止；无窗口时是 `--`
    public var sellWindowStart: String { json.str("sell_window_start") }
    public var sellWindowEnd: String { json.str("sell_window_end") }
    public var signalType: String { json.str("signal_type") }
    public var signalTypeName: String { json.str("signal_type_name") }
    public var signalVerified: Bool { json.flag("signal_verified") }
    public var stopLossPrice: Double { json.num("stop_loss_price") }
    public var strategyKey: String { json.str("strategy_key") }
    public var targetPrice: Double { json.num("target_price") }
    public var turnover: Double { json.num("turnover") }
    public var volumeRatio: Double { json.num("volume_ratio") }
    // 展示用（缺失 → "-"）
    public var riskLevelDash: String { json.strOrDash("risk_level") }
    public var positionAdviceDash: String { json.strOrDash("position_advice") }
    public var predictDirectionDash: String { json.strOrDash("predict_direction") }
    public var sellWindowStartDash: String { json.strOrDash("sell_window_start") }
    public var sellWindowEndDash: String { json.strOrDash("sell_window_end") }
    /// 开盘涨跌幅；缺失 → nil（`statCellPnl` 需要区分"无数据"与 0%）
    public var openPctOrNil: Double? { json.numOrNil("open_pct") }
    /// 各轮次得分：键是轮次号（`"1"`/`"2"`/`"3"`）→ 分数
    public var scores: [String: Double] {
        json.object("scores").dict.mapValues { $0.double ?? 0 }
    }
}

// MARK: - 盘中验证（verify）

/// 盘中验证结果（`PhaseVerify` 产出）
///
/// ⚠ **同一个实体在两条路径上看到的键集不同**：
///
/// | 路径 | 键 |
/// |------|-----|
/// | 阶段产出（`PhaseVerify`） | 11 个：`data_mode` / `groups` / `persisted` / `verify_date` … |
/// | 库读取（`SQLiteReader.verifyRow`） | 8 个：少上面 4 个，多 `is_empty_day` |
///
/// 所以 `is_empty_day` 只能算**条件键** —— 夹具来自阶段产出，里面没有它；
/// 而 `ReviewView` 读的 `store.verifyReport` 走的是**库读取**那条，**有**它。
/// 这不是"死键"，是"路径相关键"：两边都要声明，否则任一路径都会踩空。
public struct VerifyResult: JSONEntity {
    public let json: JSONValue
    public init(_ json: JSONValue) { self.json = json }

    public static let declaredKeys: Set<String> = [
        "data_mode", "detail", "deviations", "groups", "persisted",
        "sel_date", "stats", "status", "verify_date", "verify_time", "warnings",
        // 仅库读取路径有（阶段产出没有）
        "is_empty_day",
    ]
    /// 路径相关键（两条路径各缺一部分）：
    /// · 阶段产出有、库读取没有 → `data_mode` / `groups` / `persisted` / `verify_date`
    /// · 库读取有、阶段产出没有 → `is_empty_day`
    public static let conditionalKeys: Set<String> = [
        "is_empty_day", "data_mode", "groups", "persisted", "verify_date",
    ]

    public var status: String { json.str("status", "ok") }
    public var isOK: Bool { status == "ok" }
    /// 空仓日：无入档信号 → 无标的可验证。**仅库读取路径有该键**，阶段产出没有
    public var isEmptyDay: Bool { json.flag("is_empty_day") }
    /// `live` / `replay`
    public var dataMode: String { json.str("data_mode") }
    public var persisted: Bool { json.flag("persisted") }
    public var selDate: String { json.str("sel_date") }
    public var verifyDate: String { json.str("verify_date") }
    public var verifyTime: String { json.str("verify_time") }
    /// 展示用（缺失 → "-"）
    public var selDateDash: String { json.strOrDash("sel_date") }
    public var verifyTimeDash: String { json.strOrDash("verify_time") }
    public var warnings: [String] { json.strings("warnings") }
    public var detail: [VerifyDetail] { json.objects("detail").map(VerifyDetail.init) }
    public var deviations: [VerifyDeviation] { json.objects("deviations").map(VerifyDeviation.init) }
    public var stats: VerifyStats { VerifyStats(json.object("stats")) }
    /// 分组胜率：键是**中文分组名**（`最强+持续` / `脉冲信号`）→ 动态键，故用字典
    public var groups: [String: VerifyGroupStats] {
        json.object("groups").dict.mapValues(VerifyGroupStats.init)
    }
}

public struct VerifyDetail: JSONEntity {
    public let json: JSONValue
    public init(_ json: JSONValue) { self.json = json }

    public static let declaredKeys: Set<String> = [
        "code", "name", "current_pct", "current_price", "entry_return_pct",
        "intraday_pct", "outcome", "scores", "sel_price", "signal_type",
        "turnover", "volume_ratio",
    ]

    public var code: String { json.str("code") }
    public var name: String { json.str("name") }
    public var nameDash: String { json.strOrDash("name") }
    public var currentPct: Double { json.num("current_pct") }
    public var currentPctOrNil: Double? { json.numOrNil("current_pct") }
    public var currentPrice: Double { json.num("current_price") }
    /// 相对入档价（自选价）的收益
    public var entryReturnPct: Double { json.num("entry_return_pct") }
    public var intradayPct: Double { json.num("intraday_pct") }
    /// `盈利` / `亏损`
    public var outcome: String { json.str("outcome") }
    public var selPrice: Double { json.num("sel_price") }
    public var signalType: String { json.str("signal_type") }
    public var turnover: Double { json.num("turnover") }
    public var volumeRatio: Double { json.num("volume_ratio") }
    public var scores: [String: Double] {
        json.object("scores").dict.mapValues { $0.double ?? 0 }
    }
}

public struct VerifyDeviation: JSONEntity {
    public let json: JSONValue
    public init(_ json: JSONValue) { self.json = json }

    public static let declaredKeys: Set<String> = ["code", "name", "predicted", "actual_pct"]

    public var code: String { json.str("code") }
    public var name: String { json.str("name") }
    public var nameDash: String { json.strOrDash("name") }
    public var predicted: String { json.str("predicted") }
    public var actualPct: Double { json.num("actual_pct") }
}

/// 固定三段统计（`total` / `consensus` / `pulse`）
public struct VerifyStats: JSONEntity {
    public let json: JSONValue
    public init(_ json: JSONValue) { self.json = json }

    public static let declaredKeys: Set<String> = ["total", "consensus", "pulse"]

    public var total: VerifyGroupStats { VerifyGroupStats(json.object("total")) }
    public var consensus: VerifyGroupStats { VerifyGroupStats(json.object("consensus")) }
    public var pulse: VerifyGroupStats { VerifyGroupStats(json.object("pulse")) }
}

/// 一组胜率统计（`stats.*` 与 `groups.*` 元素同构）
public struct VerifyGroupStats: JSONEntity {
    public let json: JSONValue
    public init(_ json: JSONValue) { self.json = json }

    public static let declaredKeys: Set<String> = [
        "verified", "wins", "losses", "winrate", "avg_profit", "avg_loss",
    ]

    public var verified: Int { json.integer("verified") }
    public var wins: Int { json.integer("wins") }
    public var losses: Int { json.integer("losses") }
    public var winrate: Double { json.num("winrate") }
    public var avgProfit: Double { json.num("avg_profit") }
    public var avgLoss: Double { json.num("avg_loss") }
}

// MARK: - 收盘复盘（review）

/// 收盘复盘结果（`PhaseReview` 产出）
public struct ReviewResult: JSONEntity {
    public let json: JSONValue
    public init(_ json: JSONValue) { self.json = json }

    public static let declaredKeys: Set<String> = [
        "accuracy", "crash_day", "data_mode", "disciplined_target_pct",
        "four_layer_winrate", "insights", "is_empty_day", "light",
        "outcomes", "reference", "review_date", "review_time", "sel_date",
        "status", "stocks", "target_day", "target_day_estimated",
    ]
    /// 路径相关键：库读取（`SQLiteReader.reviewRow`，9 键）缺下面这些 ——
    /// 它们只在阶段产出里有
    public static let conditionalKeys: Set<String> = [
        "crash_day", "data_mode", "disciplined_target_pct", "light",
        "outcomes", "review_date", "target_day", "target_day_estimated",
    ]

    public var status: String { json.str("status", "ok") }
    public var isOK: Bool { status == "ok" }
    public var dataMode: String { json.str("data_mode") }
    /// 暴跌日：策略不操作，复盘口径随之调整
    public var crashDay: Bool { json.flag("crash_day") }
    public var isEmptyDay: Bool { json.flag("is_empty_day") }
    public var light: String { json.str("light") }
    public var disciplinedTargetPct: Double { json.num("disciplined_target_pct") }
    public var reviewDate: String { json.str("review_date") }
    public var reviewTime: String { json.str("review_time") }
    public var selDate: String { json.str("sel_date") }
    /// 展示用（缺失 → "-"）
    public var reviewTimeDash: String { json.strOrDash("review_time") }
    public var selDateDash: String { json.strOrDash("sel_date") }
    public var targetDay: String { json.str("target_day") }
    /// 目标交易日是**推算**出来的（非交易日顺延）
    public var targetDayEstimated: Bool { json.flag("target_day_estimated") }
    public var insights: [String] { json.strings("insights") }
    public var accuracy: ReviewAccuracy { ReviewAccuracy(json.object("accuracy")) }
    public var fourLayerWinrate: ReviewFourLayer { ReviewFourLayer(json.object("four_layer_winrate")) }
    public var outcomes: ReviewOutcomes { ReviewOutcomes(json.object("outcomes")) }
    public var stocks: [ReviewStock] { json.objects("stocks").map(ReviewStock.init) }
    /// 参考胜率；引擎在无参考时给 `null`
    ///
    /// ⚠ 类型是字典（生产者 `PhaseReview` 写 `{close_winrate, ceiling_winrate}`），不是字符串。
    /// 夹具里该字段恒为 `null`，键覆盖 / 往返测试证明不了它的类型 —— 改动时必须读生产者交叉确认。
    public var reference: ReviewReference? {
        json["reference"].isNull ? nil : ReviewReference(json.object("reference"))
    }
}

/// 参考胜率（历史对照）
public struct ReviewReference: JSONEntity {
    public let json: JSONValue
    public init(_ json: JSONValue) { self.json = json }

    public static let declaredKeys: Set<String> = ["close_winrate", "ceiling_winrate"]

    public var closeWinrate: Double { json.num("close_winrate") }
    /// 键缺失 → nil（消费者 `ReviewView` 用它决定"要不要显示参考卡片"）
    public var closeWinrateOrNil: Double? { json.numOrNil("close_winrate") }
    public var ceilingWinrate: Double { json.num("ceiling_winrate") }
}

public struct ReviewAccuracy: JSONEntity {
    public let json: JSONValue
    public init(_ json: JSONValue) { self.json = json }

    public static let declaredKeys: Set<String> = [
        "avg_score", "avg_target_diff", "market_hit", "window_hit_rate",
    ]

    public var avgScore: Double { json.num("avg_score") }
    public var avgTargetDiff: Double { json.num("avg_target_diff") }
    public var marketHit: Bool { json.flag("market_hit") }
    public var windowHitRate: Double { json.num("window_hit_rate") }
}

/// 四层胜率 + 两个诊断口径（`disciplined` / `ceiling`）
public struct ReviewFourLayer: JSONEntity {
    public let json: JSONValue
    public init(_ json: JSONValue) { self.json = json }

    public static let declaredKeys: Set<String> = [
        "disciplined", "gap", "window", "close", "snapshot", "ceiling",
    ]

    /// 纪律口径（窗口内首次触及目标价）
    public var disciplined: WinRate { WinRate(json.object("disciplined")) }
    /// 跳空口径（次日开盘为正）
    public var gap: WinRate { WinRate(json.object("gap")) }
    /// 窗口最高价口径（**不可实现**，仅诊断）
    public var window: WinRate { WinRate(json.object("window")) }
    public var close: WinRate { WinRate(json.object("close")) }
    public var snapshot: WinRate { WinRate(json.object("snapshot")) }
    /// 策略上限口径（事后视角，仅诊断）
    public var ceiling: WinRate { WinRate(json.object("ceiling")) }
}

/// 一处胜率（`total` / `wins` / `winrate` / `avg_profit`）
public struct WinRate: JSONEntity {
    public let json: JSONValue
    public init(_ json: JSONValue) { self.json = json }

    public static let declaredKeys: Set<String> = ["total", "wins", "winrate", "avg_profit"]

    public var total: Int { json.integer("total") }
    public var wins: Int { json.integer("wins") }
    public var winrate: Double { json.num("winrate") }
    public var avgProfit: Double { json.num("avg_profit") }
}

public struct ReviewOutcomes: JSONEntity {
    public let json: JSONValue
    public init(_ json: JSONValue) { self.json = json }

    public static let declaredKeys: Set<String> = ["count", "target_pct", "window"]

    public var count: Int { json.integer("count") }
    public var targetPct: Double { json.num("target_pct") }
    /// 卖出窗口（`["09:30", "10:30"]`）
    public var window: [String] { json.strings("window") }
}

/// 复盘一行（33 个字段：六套口径的盈亏与胜负 + 三个价位）
public struct ReviewStock: JSONEntity {
    public let json: JSONValue
    public init(_ json: JSONValue) { self.json = json }

    public static let declaredKeys: Set<String> = [
        "code", "name", "signal_type", "risk_level", "skipped",
        "accuracy_score", "sel_price", "target_price", "stop_loss_price",
        "open_pct", "intraday_high", "intraday_low", "sell_window",
        "disc_target_pct", "disc_profit", "disc_win", "disc_hit", "disc_hit_time",
        "gap_profit", "gap_win",
        "window_profit", "window_win", "window_high",
        "close_pct", "close_price", "close_profit", "close_win",
        "snapshot_profit", "snapshot_win",
        "high_profit", "high_win", "high_time", "tp_profits",
    ]

    public var code: String { json.str("code") }
    public var name: String { json.str("name") }
    public var nameDash: String { json.strOrDash("name") }
    public var signalType: String { json.str("signal_type") }
    public var riskLevel: String { json.str("risk_level") }
    /// 被跳过（策略在该环境下不操作）—— 这些样本**不计入**胜率
    public var skipped: Bool { json.flag("skipped") }
    public var accuracyScore: Int { json.integer("accuracy_score") }
    public var selPrice: Double { json.num("sel_price") }
    public var targetPrice: Double { json.num("target_price") }
    public var stopLossPrice: Double { json.num("stop_loss_price") }
    public var openPct: Double { json.num("open_pct") }
    public var intradayHigh: Double { json.num("intraday_high") }
    public var intradayLow: Double { json.num("intraday_low") }
    public var sellWindow: String { json.str("sell_window") }

    // 纪律口径
    public var discTargetPct: Double { json.num("disc_target_pct") }
    public var discProfit: Double { json.num("disc_profit") }
    public var discWin: Int { json.integer("disc_win") }
    public var discHit: Bool { json.flag("disc_hit") }
    /// 首次触及目标价的时刻；未触及 → nil（**不是** `--`，是真的没有）
    public var discHitTime: String? { json["disc_hit_time"].string }

    // 跳空口径
    public var gapProfit: Double { json.num("gap_profit") }
    public var gapWin: Int { json.integer("gap_win") }

    // 窗口口径
    public var windowProfit: Double { json.num("window_profit") }
    /// 窗口盈亏；缺失 → nil（视图用 `PnlText(value:)` 显示"无数据"而不是 0%）
    public var windowProfitOrNil: Double? { json.numOrNil("window_profit") }
    public var windowWin: Int { json.integer("window_win") }
    public var windowHigh: Double { json.num("window_high") }

    // 收盘口径
    public var closePct: Double { json.num("close_pct") }
    public var closePrice: Double { json.num("close_price") }
    public var closeProfit: Double { json.num("close_profit") }
    /// 收盘盈亏；缺失 → nil
    public var closeProfitOrNil: Double? { json.numOrNil("close_profit") }
    public var closeWin: Int { json.integer("close_win") }

    // 快照 / 上限
    public var snapshotProfit: Double { json.num("snapshot_profit") }
    public var snapshotWin: Int { json.integer("snapshot_win") }
    public var highProfit: Double { json.num("high_profit") }
    public var highWin: Int { json.integer("high_win") }
    public var highTime: String { json.str("high_time") }
    /// 展示用（缺失 → "-"）
    public var highTimeDash: String { json.strOrDash("high_time") }

    /// 逐时点触及目标价的情况：键是时刻（`09:35` / `10:00` …）→ 是否触及
    public var tpProfits: [String: JSONValue] { json.object("tp_profits").dict }
}

// MARK: - 三天迭代（iterate）

/// 三天迭代结果（`PhaseIterate` 产出）
public struct IterateResult: JSONEntity {
    public let json: JSONValue
    public init(_ json: JSONValue) { self.json = json }

    public static let declaredKeys: Set<String> = [
        "counter", "data_mode", "empty_trend", "four_layer_avg",
        "group_analysis", "insights", "is_empty_day_report",
        "status", "trigger_date", "trigger_time",
    ]
    /// 路径相关键：库读取（`SQLiteReader.iterateRow`，6 键）缺下面这些
    public static let conditionalKeys: Set<String> = [
        "data_mode", "group_analysis", "status", "trigger_time",
    ]

    public var status: String { json.str("status", "ok") }
    public var isOK: Bool { status == "ok" }
    /// 展示用（缺失 → "-"）
    public var statusDash: String { json.strOrDash("status") }
    public var dataMode: String { json.str("data_mode") }
    /// 迭代计数器（回放模式下**不得推进**）
    public var counter: Int { json.integer("counter") }
    public var isEmptyDayReport: Bool { json.flag("is_empty_day_report") }
    public var triggerDate: String { json.str("trigger_date") }
    /// 展示用（缺失 → "-"）
    public var triggerDateDash: String { json.strOrDash("trigger_date") }
    public var triggerTime: String { json.str("trigger_time") }
    public var insights: [String] { json.strings("insights") }
    public var emptyTrend: IterateEmptyTrend { IterateEmptyTrend(json.object("empty_trend")) }
    public var fourLayerAvg: IterateFourLayerAvg { IterateFourLayerAvg(json.object("four_layer_avg")) }
    /// 分组表现：键是分组名（`consensus` / `pulse`）→ 动态键，故用字典
    public var groupAnalysis: [String: IterateGroup] {
        json.object("group_analysis").dict.mapValues(IterateGroup.init)
    }
}

public struct IterateEmptyTrend: JSONEntity {
    public let json: JSONValue
    public init(_ json: JSONValue) { self.json = json }

    public static let declaredKeys: Set<String> = [
        "daily", "empty_days", "empty_ratio", "no_participation_days", "total_days",
    ]

    public var daily: [IterateEmptyDay] { json.objects("daily").map(IterateEmptyDay.init) }
    public var emptyDays: Int { json.integer("empty_days") }
    public var emptyRatio: Double { json.num("empty_ratio") }
    public var noParticipationDays: Int { json.integer("no_participation_days") }
    public var totalDays: Int { json.integer("total_days") }
}

public struct IterateEmptyDay: JSONEntity {
    public let json: JSONValue
    public init(_ json: JSONValue) { self.json = json }

    public static let declaredKeys: Set<String> = [
        "date", "is_empty", "is_no_participation", "participating", "stocks",
    ]

    public var date: String { json.str("date") }
    public var isEmpty: Bool { json.flag("is_empty") }
    public var isNoParticipation: Bool { json.flag("is_no_participation") }
    public var participating: Int { json.integer("participating") }
    public var stocks: Int { json.integer("stocks") }
}

/// 各口径的平均收益（`four_layer_avg`）
///
/// ⚠ **只有 4 个键**（`PhaseIterate` 只写 snapshot/close/window/ceiling）——
/// 与 `ReviewFourLayer` 的 6 个键**不是同一组**，别按 review 的形状多声明。
public struct IterateFourLayerAvg: JSONEntity {
    public let json: JSONValue
    public init(_ json: JSONValue) { self.json = json }

    public static let declaredKeys: Set<String> = ["snapshot", "close", "window", "ceiling"]

    public var snapshot: Double { json.num("snapshot") }
    public var close: Double { json.num("close") }
    public var window: Double { json.num("window") }
    public var ceiling: Double { json.num("ceiling") }
}

public struct IterateGroup: JSONEntity {
    public let json: JSONValue
    public init(_ json: JSONValue) { self.json = json }

    public static let declaredKeys: Set<String> = ["count", "winrate"]

    public var count: Int { json.integer("count") }
    public var winrate: Double { json.num("winrate") }
}
