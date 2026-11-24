import Foundation

/// 大盘环境（`market_env`）—— **一个类型，三种来源**
///
/// | 来源 | 键数 | 谁产出 | 独有键 |
/// |------|------|--------|--------|
/// | 扫描结果（`ScanResult.market_env`） | 19 | `Screener.buildMarketEnv` | `sh_price` / 涨跌家数 / `ratio` / `sh_amplitude` / `sh_d1` / `sh_d2` / `sh_decline_*` / `regime` / `ma_period_used` |
/// | 库 `scan_rounds.market_env_json` | **12–19** | `ScanStore.persistRound` **原样存**扫描的那份 | ——（是扫描的历史子集，见下） |
/// | 预判（`PredictResult.market_env`） | 12 | `PhasePredict` | `light` / `light_desc` / `open_status` / `sh_open_pct` / `us_market` / `regime` / `ma_period_used` |
///
/// ⚠ **库是 append-only 的**：旧行保留其写入时的键集形状（12–19 键多种历史形态），
/// 消费方必须容忍历史键集，不能按"当前引擎产出"声明键。
///
/// 由此定的形状：
///
/// * `alwaysPresentKeys`（5 个）：三种来源、所有历史形状里**都存在**
/// * `conditionalKeys`（19 个）：**来源相关** —— 读它们必须用 `OrNil` 变体，
///   否则"这个来源没报这个字段"会被静默当成 `0` / `false`
///
/// ⚠ `regime` / `ma_period_used` 是 Swift 侧扩展键：扫描与预判都产出，但历史库行里没有。
public struct MarketEnv: JSONEntity {
    public let json: JSONValue
    public init(_ json: JSONValue) { self.json = json }

    public static let declaredKeys: Set<String> = [
        // ── 三种来源都有（5）
        "sh_change_pct", "sh_consecutive_decline", "sh_ok",
        "sh_3d_decline_count", "sh_3d_trend",
        // ── 扫描结果 / 库（12）
        "sh_price", "sh_amplitude", "up_count", "down_count", "flat_count",
        "ratio", "ratio_ok", "sh_d1", "sh_d2",
        "sh_decline_streak", "sh_decline_lookback", "sh_decline_days_cfg",
        // ── 预判独有（5）
        "light", "light_desc", "open_status", "sh_open_pct", "us_market",
        // ── 市场状态机：扫描与预判两侧都产出，但历史行里没有
        "regime", "ma_period_used",
    ]

    /// 三种来源、所有历史形状里**都**存在的键（其余 19 个都是来源相关）
    public static let alwaysPresentKeys: Set<String> = [
        "sh_change_pct", "sh_consecutive_decline", "sh_ok",
        "sh_3d_decline_count", "sh_3d_trend",
    ]

    public static let conditionalKeys: Set<String> =
        declaredKeys.subtracting(alwaysPresentKeys)

    /// 该键在**本次来源**里是否存在 —— 用来区分"这个来源没报"与"值是 0 / false"
    public func has(_ key: String) -> Bool { !json[key].isNull }

    /// 该来源**完全没有**环境数据（`{}`）—— 回退链的判定用它，
    /// 不要用 `shPrice == 0` 这类"值等于默认值"的间接判据
    public var isEmpty: Bool { json.dict.isEmpty }

    // MARK: - 三种来源都有的（5）

    public var shChangePct: Double { json.num("sh_change_pct") }
    /// 涨跌幅；缺失 → nil（通知里"只在真有数时才附上"，避免凭空播报 +0.00%）
    public var shChangePctOrNil: Double? { json.numOrNil("sh_change_pct") }
    public var shConsecutiveDecline: Bool { json.flag("sh_consecutive_decline") }
    public var shOK: Bool { json.flag("sh_ok") }
    public var sh3dDeclineCount: Int { json.integer("sh_3d_decline_count") }
    public var sh3dTrend: String { json.str("sh_3d_trend") }
    /// 展示用（缺失 → "-"）
    public var sh3dTrendDash: String { json.strOrDash("sh_3d_trend") }

    // MARK: - 扫描结果 / 库（12）—— 预判来源里都没有

    public var shPrice: Double { json.num("sh_price") }
    public var shPriceOrNil: Double? { json.numOrNil("sh_price") }
    public var shAmplitude: Double { json.num("sh_amplitude") }
    public var shAmplitudeOrNil: Double? { json.numOrNil("sh_amplitude") }
    public var upCount: Int { json.integer("up_count") }
    public var upCountOrNil: Int? { json.intOrNil("up_count") }
    public var downCount: Int { json.integer("down_count") }
    public var downCountOrNil: Int? { json.intOrNil("down_count") }
    public var flatCount: Int { json.integer("flat_count") }
    public var flatCountOrNil: Int? { json.intOrNil("flat_count") }
    /// 涨跌比。⚠ 引擎侧**可能是 int 也可能是 float**，故按 Double 读
    public var ratio: Double { json.num("ratio") }
    public var ratioOrNil: Double? { json.numOrNil("ratio") }
    public var ratioOK: Bool { json.flag("ratio_ok") }
    public var shD1: Double { json.num("sh_d1") }
    public var shD1OrNil: Double? { json.numOrNil("sh_d1") }
    public var shD2: Double { json.num("sh_d2") }
    public var shD2OrNil: Double? { json.numOrNil("sh_d2") }
    public var shDeclineStreak: Int { json.integer("sh_decline_streak") }
    public var shDeclineStreakOrNil: Int? { json.intOrNil("sh_decline_streak") }
    public var shDeclineLookback: Int { json.integer("sh_decline_lookback") }
    public var shDeclineLookbackOrNil: Int? { json.intOrNil("sh_decline_lookback") }
    public var shDeclineDaysCfg: Int { json.integer("sh_decline_days_cfg") }
    public var shDeclineDaysCfgOrNil: Int? { json.intOrNil("sh_decline_days_cfg") }

    // MARK: - 预判独有（5）—— 扫描结果 / 库里都没有

    /// `绿灯` / `黄灯` / `红灯`
    public var light: String { json.str("light") }
    /// 展示用（缺失 → "-"）
    public var lightDash: String { json.strOrDash("light") }
    public var lightDesc: String { json.str("light_desc") }
    public var openStatus: String { json.str("open_status") }
    public var openStatusDash: String { json.strOrDash("open_status") }
    public var shOpenPct: Double { json.num("sh_open_pct") }
    public var shOpenPctOrNil: Double? { json.numOrNil("sh_open_pct") }
    public var usMarket: String { json.str("us_market") }
    public var usMarketDash: String { json.strOrDash("us_market") }

    // MARK: - 市场状态机

    /// 五态之一（`BULL_TREND` / `BULL_CORRECTION` / `BEAR_TREND` / `PANIC` / `RECOVERY`）；
    /// 历史不足或**早期落的库行** → `UNKNOWN`
    public var regime: String { json.str("regime") }
    public var regimeDash: String { json.strOrDash("regime") }
    /// 实际用到的 MA 周期（60 / 20 / 10）；缺失 → 0
    public var maPeriodUsed: Int { json.integer("ma_period_used") }
    /// 缺失 → nil（区别于"真的用了 0"）
    public var maPeriodUsedOrNil: Int? { json.intOrNil("ma_period_used") }

    // MARK: - 大盘灯

    /// 大盘灯。
    ///
    /// ⚠ 规则顺序**必须**是"连续下跌 → 红；`sh_ok` 非真 → 黄；否则绿"：
    /// `sh_ok` 在预判来源里可能与扫描不一致，若先看 `sh_ok`，
    /// 同一份行情会因"数据来自哪个来源"而变色。
    ///
    /// 只读 `alwaysPresentKeys` 里的键 → 三种来源都算得出来。
    public var lightLevel: MarketLightLevel {
        if shConsecutiveDecline { return .red }
        if !shOK { return .yellow }
        return .green
    }
}

/// 大盘灯档位（判定在 `SelectedCore`，文案与配色留给 UI 层）
///
/// ⚠ **rawValue 是线上格式的中文原值**（`红灯` / `黄灯` / `绿灯`）：
/// 这三个串落进 `scan_rounds.market_env_json` / `predictions.market_env_json` /
/// `watch_judgments.market_light` 并被逐字段比对，改一个字节即破坏兼容，
/// 故不得改成英文代号。
///
/// `init?(rawValue:)` 是唯一解析器：空串与未识别值 → nil，
/// 各调用点保留自己原有的回落（灰 / 未知 / 非 crash / 实时默认绿灯），**不引入新默认值**。
public enum MarketLightLevel: String, Sendable, CaseIterable {
    case red = "红灯"
    case yellow = "黄灯"
    case green = "绿灯"

    /// 从 JSON/字典字段解析（缺失 / 非字符串 / 未识别 → nil）。
    /// 落库值是中文串，所以不能用 `as? MarketLightLevel` 直接取。
    public init?(json: Any?) {
        guard let s = json as? String, let v = MarketLightLevel(rawValue: s) else { return nil }
        self = v
    }
}
