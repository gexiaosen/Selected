import Foundation

/// 指标筛选规则表。
///
/// ## 这是什么 / 不是什么
/// 每个指标卡片对应**一条**"符合这个指标的股票"判据。
/// **可调阈值**（4 个）走 B 域 `indicator_params` 表（键 `screen.*`，见
/// `IndicatorParamSpec`）：筛选页「设置」可调、留变更流水，但**不进选股参数版本、
/// 不进调优空间**；运行时缺键/脏值 → 回落 `Rule.defaultThreshold`。
/// 其余数值（ppo>0、ao>0、%B>1……）是**定义性判据**（零轴/上轨），不参数化。
///
/// ## 规则三型
///   · `filter`：当日快照列的谓词（如 RSI<阈值）；
///   · `cross` ：今日 vs 前一快照日的穿越（金叉）—— 库里没有前一日时**返回空**
///     （"没有可比的前日"不是"没有命中"，不硬造金叉）；
///   · `sort` ：无阈值，按某列强弱排序（高波动 / 深回撤）。
///
/// ## ⚠ 展示口径
/// `valueSQL` 出的数是**排序键**，界面上必须带 `valueLabel` 说明是什么量
/// （乖离%、柱、%B……），不许裸数字让人猜。判据全部基于**收盘定稿快照**，
/// 与评分体系无关（这些方向未经本项目标定，只作筛选展示，不进总分）。
/// 历史 `viewDate` 用**当前激活**阈值（展示型透镜，不做按日回放口径）。
public enum IndicatorScreener {

    /// whereSQL / title 模板里的阈值占位 token（专用串，避免与 `String(format:)` 的 % 混淆）。
    public static let thresholdToken = "{{th}}"

    /// 一条筛选规则（纯数据 + SQL 模板常量；阈值经 token 注入为**绑定参数**）。
    public struct Rule: Sendable {
        /// 关联的注册表指标 id（一 id 一规则）
        public let indicatorId: String
        /// 判据一句话模板（含 `{{th}}` 的用 `title(thresholds:)` 渲染）
        public let title: String
        /// 排序键的列头名（说明这个数是什么）
        public let valueLabel: String
        /// 排序键 SQL 表达式（只引用 `t.` / `p.` 白名单列）
        public let valueSQL: String
        /// 谓词 SQL（只引用 `t.` / `p.` 白名单列 + 可选一个 `{{th}}` token）
        public let whereSQL: String
        /// 排序方向（超卖类升序=最超卖在前；突破类降序）
        public let ascending: Bool
        /// 需要前一快照日（cross 型）
        public let needsPreviousDay: Bool
        /// 参数中心的阈值键（nil = 本规则无可调阈值）
        public let thresholdKey: String?
        /// 缺省阈值（回落与补键迁移共用的单一来源）
        public let defaultThreshold: Double

        init(indicatorId: String, title: String, valueLabel: String,
             valueSQL: String, whereSQL: String, ascending: Bool = false,
             needsPreviousDay: Bool = false, thresholdKey: String? = nil,
             defaultThreshold: Double = 0) {
            self.indicatorId = indicatorId
            self.title = title
            self.valueLabel = valueLabel
            self.valueSQL = valueSQL
            self.whereSQL = whereSQL
            self.ascending = ascending
            self.needsPreviousDay = needsPreviousDay
            self.thresholdKey = thresholdKey
            self.defaultThreshold = defaultThreshold
        }

        /// 用当前阈值渲染判据文案（`%g`：30→"30"、0.1→"0.1"）。
        public func title(thresholds: [String: Double]) -> String {
            guard let key = thresholdKey else { return title }
            let v = thresholds[key] ?? defaultThreshold
            return title.replacingOccurrences(of: Self.token(), with: IndicatorScreener.g(v))
        }

        static func token() -> String { IndicatorScreener.thresholdToken }
    }

    /// `%g` 数字格式化（C printf：去尾零，30.0→"30"、0.10→"0.1"）。
    static func g(_ v: Double) -> String { String(format: "%g", v) }

    /// 全表：注册表 22 个指标一一对应（`IndicatorScreenerTests` 钉死覆盖与列名白名单）。
    public static let rules: [Rule] = [
        // MARK: 趋势
        Rule(indicatorId: "ema", title: "收盘上穿 EMA20（乖离降序）",
             valueLabel: "乖离%",
             valueSQL: "(t.close_value / t.ema_value - 1) * 100",
             whereSQL: "t.close_value > t.ema_value AND t.ema_value IS NOT NULL"),
        Rule(indicatorId: "macd", title: "MACD 金叉（线昨弱今强）",
             valueLabel: "柱",
             valueSQL: "t.macd_hist",
             whereSQL: "t.macd_line > t.macd_signal AND p.macd_line <= p.macd_signal"
                 + " AND t.macd_line IS NOT NULL AND t.macd_signal IS NOT NULL",
             needsPreviousDay: true),
        Rule(indicatorId: "hma", title: "收盘上穿 HMA20（乖离降序）",
             valueLabel: "乖离%",
             valueSQL: "(t.close_value / t.hma_value - 1) * 100",
             whereSQL: "t.close_value > t.hma_value AND t.hma_value IS NOT NULL"),
        Rule(indicatorId: "kama", title: "收盘上穿 KAMA（乖离降序）",
             valueLabel: "乖离%",
             valueSQL: "(t.close_value / t.kama_value - 1) * 100",
             whereSQL: "t.close_value > t.kama_value AND t.kama_value IS NOT NULL"),

        // MARK: 动量
        Rule(indicatorId: "rsiWilder", title: "RSI 超卖（<{{th}}，最低在前）",
             valueLabel: "RSI",
             valueSQL: "t.rsi_wilder_value",
             whereSQL: "t.rsi_wilder_value < \(thresholdToken)",
             ascending: true,
             thresholdKey: "screen.rsi_oversold", defaultThreshold: 30),
        Rule(indicatorId: "stochastic", title: "Stochastic K 上穿 D",
             valueLabel: "%K",
             valueSQL: "t.stochastic_k",
             whereSQL: "t.stochastic_k > t.stochastic_d AND p.stochastic_k <= p.stochastic_d",
             needsPreviousDay: true),
        Rule(indicatorId: "stochasticRsi", title: "StochRSI 超卖（<{{th}}，最低在前）",
             valueLabel: "StochRSI",
             valueSQL: "t.stochastic_rsi_value",
             whereSQL: "t.stochastic_rsi_value < \(thresholdToken)",
             ascending: true,
             thresholdKey: "screen.stochrsi_oversold", defaultThreshold: 20),
        Rule(indicatorId: "ppo", title: "PPO 多头（线>信号 且 >0）",
             valueLabel: "柱",
             valueSQL: "t.ppo_hist",
             whereSQL: "t.ppo_line > t.ppo_signal AND t.ppo_line > 0"),
        Rule(indicatorId: "awesomeOscillator", title: "AO 零轴上方（动能为正）",
             valueLabel: "AO",
             valueSQL: "t.awesome_oscillator_value",
             whereSQL: "t.awesome_oscillator_value > 0"),
        Rule(indicatorId: "ultimateOscillator", title: "UO 超卖（<30，最低在前）",
             valueLabel: "UO",
             valueSQL: "t.ultimate_oscillator_value",
             whereSQL: "t.ultimate_oscillator_value < 30",
             ascending: true),

        // MARK: 波动率
        Rule(indicatorId: "atrSma", title: "高波动（ATR 占价降序）",
             valueLabel: "ATR%",
             valueSQL: "t.atr_sma_percent",
             whereSQL: "t.atr_sma_percent IS NOT NULL"),
        Rule(indicatorId: "bollingerBands", title: "突破布林上轨（%B>1）",
             valueLabel: "%B",
             valueSQL: "t.bollinger_bands_percent_b",
             whereSQL: "t.bollinger_bands_percent_b > 1"),
        Rule(indicatorId: "donchianChannel", title: "创 20 日新高（收盘>昨上轨）",
             valueLabel: "超轨%",
             // ⚠ 必须比**前一日**上轨：当日上轨 = 含当日 high 的 20 日最大值，
             //   `close > 当日上轨` 数学上不可能成立（最多相等）—— 2026-10-26 实测
             //   旧规则在 5217 只里恒命中 0。与前一快照日比才是"创 20 日新高"。
             valueSQL: "(t.close_value / p.donchian_channel_upper - 1) * 100",
             whereSQL: "t.close_value > p.donchian_channel_upper"
                 + " AND p.donchian_channel_upper IS NOT NULL",
             needsPreviousDay: true),
        Rule(indicatorId: "keltnerChannel", title: "突破肯特纳上轨",
             valueLabel: "超轨%",
             valueSQL: "(t.close_value / t.keltner_channel_upper - 1) * 100",
             whereSQL: "t.close_value > t.keltner_channel_upper"),
        Rule(indicatorId: "superTrend", title: "SuperTrend 上升趋势（乖离降序）",
             valueLabel: "乖离%",
             valueSQL: "(t.close_value / t.super_trend_value - 1) * 100",
             whereSQL: "t.super_trend_up = 1 AND t.super_trend_value IS NOT NULL"),
        Rule(indicatorId: "ulcerIndex", title: "深度回撤中（UI 降序）",
             valueLabel: "UI",
             valueSQL: "t.ulcer_index_value",
             whereSQL: "t.ulcer_index_value > 0"),

        // MARK: 成交量
        Rule(indicatorId: "vwap", title: "收盘高于 14 日 VWAP",
             valueLabel: "乖离%",
             valueSQL: "(t.close_value / t.vwap_value - 1) * 100",
             whereSQL: "t.close_value > t.vwap_value AND t.vwap_value IS NOT NULL"),
        Rule(indicatorId: "cmf", title: "蔡金资金流入（CMF>{{th}}）",
             valueLabel: "CMF",
             valueSQL: "t.cmf_value",
             whereSQL: "t.cmf_value > \(thresholdToken)",
             thresholdKey: "screen.cmf_inflow", defaultThreshold: 0.1),
        Rule(indicatorId: "emv", title: "EMV 正值（上行省力）",
             valueLabel: "EMV",
             valueSQL: "t.emv_value",
             whereSQL: "t.emv_value > 0"),
        Rule(indicatorId: "forceIndex", title: "强力指数为正（放量上涨）",
             valueLabel: "FI",
             valueSQL: "t.force_index_value",
             whereSQL: "t.force_index_value > 0"),
        Rule(indicatorId: "moneyFlowMultiplier", title: "收盘贴近日高（MFM>{{th}}）",
             valueLabel: "MFM",
             valueSQL: "t.money_flow_multiplier_value",
             whereSQL: "t.money_flow_multiplier_value > \(thresholdToken)",
             thresholdKey: "screen.mfm_strong", defaultThreshold: 0.5),
        Rule(indicatorId: "moneyFlowVolume", title: "资金流体积为正",
             valueLabel: "MFV",
             valueSQL: "t.money_flow_volume_value",
             whereSQL: "t.money_flow_volume_value > 0"),
    ]

    /// 按指标 id 取规则（找不到 → nil；界面渲染卡片时用它拿判据一句话）。
    public static func rule(for indicatorId: String) -> Rule? {
        rules.first { $0.indicatorId == indicatorId }
    }

    /// 按分类取规则（保持注册表内顺序，筛选页分区渲染用）。
    public static func rules(category: IndicatorRegistry.Category) -> [Rule] {
        rules.filter { IndicatorRegistry.meta(id: $0.indicatorId)?.category == category }
    }

    /// 全部可调阈值的缺省表（键 = schema 键）。**单一来源**：规则表本身
    /// （补键迁移 `DBBootstrap.backfillScreenThresholds` 与运行时回落都读这里）。
    public static var defaultThresholds: [String: Double] {
        var out: [String: Double] = [:]
        for r in rules { if let k = r.thresholdKey { out[k] = r.defaultThreshold } }
        return out
    }

    /// 当前生效阈值表：默认值打底，B 域 `indicator_params` 的 `screen.*` 覆盖。
    ///
    /// ⚠ 回落纪律（同 `PatternScoreConfig.from`）：缺键 / 非数值 / 非有限值 /
    ///   超出 spec 区间 → 用默认值，**不报错不崩**（阈值是展示透镜，
    ///   脏参数不该让整页打不开）。区间与默认的唯一来源是 `IndicatorParamSpec`。
    public static func activeThresholds() -> [String: Double] {
        var out = defaultThresholds
        for r in rules {
            guard let key = r.thresholdKey, let v = IndicatorParamStore.effective(key: key) else { continue }
            out[key] = v
        }
        return out
    }

    /// 执行筛选（阈值在此解析，Store 只做绑定查询）。
    public static func screen(indicatorId: String, date: String,
                              limit: Int = 300) -> [IndicatorSnapshotStore.RankEntry] {
        guard let r = rule(for: indicatorId) else { return [] }
        let thresholds = activeThresholds()
        let value = r.thresholdKey.flatMap { thresholds[$0] } ?? r.defaultThreshold
        return IndicatorSnapshotStore.screen(rule: r, date: date, limit: limit, threshold: value)
    }

    // MARK: - 多条件（AND）

    /// 界面一次最多勾选的条件数：结果表每条件一列（约 84pt），再多读不动；
    /// 同时也是"组合塌缩成 0"的高发区。放在 Core 是为了界面/测试/文档同一个数。
    public static let maxConditions = 6

    /// 多条件 AND 筛选（排序键缺省 = 第一个条件；方向取该规则自身）。
    ///
    /// ⚠ 任一 id 不在规则表里 → 整体返回空（**不静默丢条件**：少一个条件等于筛出另一批股票）。
    public static func screen(indicatorIds: [String], date: String,
                              limit: Int = 300, sortBy: String? = nil)
        -> [IndicatorSnapshotStore.ScreenRow] {
        let rs = resolveRules(indicatorIds)
        guard !rs.isEmpty else { return [] }
        return IndicatorSnapshotStore.screen(rules: rs, date: date, limit: limit,
                                             sortBy: sortBy, thresholds: activeThresholds())
    }

    /// 多条件 AND 的命中数（`nil` = 不可算，或缺前一日）。
    public static func count(indicatorIds: [String], date: String) -> Int? {
        let rs = resolveRules(indicatorIds)
        guard !rs.isEmpty else { return nil }
        return IndicatorSnapshotStore.count(rules: rs, date: date,
                                            thresholds: activeThresholds())
    }

    /// 22 条规则各自的单日命中数（勾选面板右侧的数）。
    public static func singleCounts(date: String) -> [String: Int] {
        IndicatorSnapshotStore.singleCounts(date: date, thresholds: activeThresholds())
    }

    /// ids → 规则（去重保序；遇到未知 id 整体放弃）。
    static func resolveRules(_ ids: [String]) -> [Rule] {
        var seen = Set<String>()
        var out: [Rule] = []
        for id in ids where seen.insert(id).inserted {
            guard let r = rule(for: id) else { return [] }
            out.append(r)
        }
        return out
    }
}
