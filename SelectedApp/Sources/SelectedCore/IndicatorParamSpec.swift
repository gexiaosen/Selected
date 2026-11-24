import Foundation

/// 指标筛选参数清单（B 域）。
///
/// ## 域纪律
///   · **A 选股参数**（打分/过滤链/档位）→ `param_versions` 版本线，可调优、可回滚；
///   · **B 指标筛选参数**（本文件）→ `indicator_params` 独立表，**不进选股版本列表、
///     不进调优空间** —— 只影响筛选页的查询透镜与快照周期，不改任何打分结论；
///   · **C 保持代码**：定义性判据（ppo>0、%B>1）、形态阈值（未标定）、强度权重、
///     覆盖率闸门 —— 改了是"改系统"，不是"调参"，不给按钮。
///
/// ## 单一来源
/// 键、中文名、默认值、区间、步进全在这里 —— 编辑 sheet 渲染、写入校验、
/// 契约测试（默认值 ↔ `IndicatorRegistry.defaultPeriods` / `Rule.defaultThreshold` /
/// `Oscillators.Config` 出厂值）都读这一份。加参数只改这里 + 消费点。
///
/// ## 键命名
///   · `screen.<id>` —— 判据阈值；
///   · `period.<指标id>.<参数>` —— 指标周期/参数（改了要重算快照，Job 按此取数）；
///   · `osc.<指标>.<参数>` —— Oscillators 超买超卖线（只影响详情页 Zone 判读展示）。
/// **缺键 = 回落默认**（读侧语义，见 `IndicatorParamStore`）。
public enum IndicatorParamSpec {

    public enum Group: String, CaseIterable, Sendable {
        case screen = "判据阈值"
        case period = "指标周期"
        case osc = "超买超卖线"
    }

    public struct Entry: Sendable {
        public let key: String
        public let group: Group
        /// 指标/分类显示名（编辑 sheet 分组行用）
        public let owner: String
        public let label: String
        public let defaultValue: Double
        public let min: Double
        public let max: Double
        public let step: Double
        /// true = 整数语义（UI 步进 1、写回取整）
        public let isInt: Bool

        init(key: String, group: Group, owner: String, label: String,
             defaultValue: Double, min: Double, max: Double, step: Double, isInt: Bool = true) {
            self.key = key
            self.group = group
            self.owner = owner
            self.label = label
            self.defaultValue = defaultValue
            self.min = min
            self.max = max
            self.step = step
            self.isInt = isInt
        }
    }

    /// 全表（顺序 = 编辑 sheet 展示顺序）。
    public static let all: [Entry] = screenEntries + periodEntries + oscEntries

    // MARK: - screen（判据阈值，4 项；默认值必须 == Rule.defaultThreshold）

    public static let screenEntries: [Entry] = [
        Entry(key: "screen.rsi_oversold", group: .screen, owner: "RSI",
              label: "超卖线", defaultValue: 30, min: 0, max: 100, step: 1),
        Entry(key: "screen.stochrsi_oversold", group: .screen, owner: "StochRSI",
              label: "超卖线", defaultValue: 20, min: 0, max: 100, step: 1),
        Entry(key: "screen.cmf_inflow", group: .screen, owner: "CMF",
              label: "流入线", defaultValue: 0.1, min: -1, max: 1, step: 0.05, isInt: false),
        Entry(key: "screen.mfm_strong", group: .screen, owner: "MFM",
              label: "贴线日高占比", defaultValue: 0.5, min: 0, max: 1, step: 0.05, isInt: false),
    ]

    // MARK: - period（指标周期/参数；.period 项默认值必须 == 注册表 defaultPeriods 首位）

    public static let periodEntries: [Entry] = [
        // 趋势
        Entry(key: "period.ema.period", group: .period, owner: "EMA", label: "周期", defaultValue: 20, min: 2, max: 250, step: 1),
        Entry(key: "period.macd.fast", group: .period, owner: "MACD", label: "快线 EMA", defaultValue: 12, min: 2, max: 120, step: 1),
        Entry(key: "period.macd.slow", group: .period, owner: "MACD", label: "慢线 EMA", defaultValue: 26, min: 3, max: 250, step: 1),
        Entry(key: "period.macd.signal", group: .period, owner: "MACD", label: "信号 EMA", defaultValue: 9, min: 2, max: 90, step: 1),
        Entry(key: "period.hma.period", group: .period, owner: "HMA", label: "周期", defaultValue: 20, min: 2, max: 250, step: 1),
        Entry(key: "period.kama.er", group: .period, owner: "KAMA", label: "ER 效率比周期", defaultValue: 10, min: 2, max: 90, step: 1),
        Entry(key: "period.kama.fast", group: .period, owner: "KAMA", label: "快 SC", defaultValue: 2, min: 1, max: 20, step: 1),
        Entry(key: "period.kama.slow", group: .period, owner: "KAMA", label: "慢 SC", defaultValue: 30, min: 2, max: 90, step: 1),
        // 动量
        Entry(key: "period.rsiWilder.period", group: .period, owner: "RSI(Wilder)", label: "周期", defaultValue: 14, min: 2, max: 90, step: 1),
        Entry(key: "period.stochastic.period", group: .period, owner: "Stochastic", label: "高低周期", defaultValue: 14, min: 2, max: 90, step: 1),
        Entry(key: "period.stochastic.smooth", group: .period, owner: "Stochastic", label: "%D 平滑", defaultValue: 3, min: 1, max: 30, step: 1),
        Entry(key: "period.stochasticRsi.period", group: .period, owner: "StochRSI", label: "周期", defaultValue: 14, min: 2, max: 90, step: 1),
        Entry(key: "period.ppo.fast", group: .period, owner: "PPO", label: "快线 EMA", defaultValue: 12, min: 2, max: 120, step: 1),
        Entry(key: "period.ppo.slow", group: .period, owner: "PPO", label: "慢线 EMA", defaultValue: 26, min: 3, max: 250, step: 1),
        Entry(key: "period.ppo.signal", group: .period, owner: "PPO", label: "信号 EMA", defaultValue: 9, min: 2, max: 90, step: 1),
        Entry(key: "period.awesomeOscillator.short", group: .period, owner: "AO", label: "短 SMA", defaultValue: 5, min: 2, max: 60, step: 1),
        Entry(key: "period.awesomeOscillator.long", group: .period, owner: "AO", label: "长 SMA", defaultValue: 34, min: 3, max: 250, step: 1),
        Entry(key: "period.ultimateOscillator.short", group: .period, owner: "UO", label: "短周期", defaultValue: 7, min: 2, max: 60, step: 1),
        Entry(key: "period.ultimateOscillator.medium", group: .period, owner: "UO", label: "中周期", defaultValue: 14, min: 3, max: 120, step: 1),
        Entry(key: "period.ultimateOscillator.long", group: .period, owner: "UO", label: "长周期", defaultValue: 28, min: 4, max: 250, step: 1),
        // 波动率
        Entry(key: "period.atrSma.period", group: .period, owner: "ATR(SMA)", label: "周期", defaultValue: 14, min: 2, max: 90, step: 1),
        Entry(key: "period.bollingerBands.period", group: .period, owner: "布林带", label: "周期", defaultValue: 20, min: 2, max: 250, step: 1),
        Entry(key: "period.bollingerBands.multiplier", group: .period, owner: "布林带", label: "σ 倍数", defaultValue: 2, min: 0.5, max: 5, step: 0.1, isInt: false),
        Entry(key: "period.donchianChannel.period", group: .period, owner: "唐奇安", label: "周期", defaultValue: 20, min: 2, max: 250, step: 1),
        Entry(key: "period.keltnerChannel.period", group: .period, owner: "肯特纳", label: "周期", defaultValue: 20, min: 2, max: 250, step: 1),
        Entry(key: "period.keltnerChannel.multiplier", group: .period, owner: "肯特纳", label: "ATR 倍数", defaultValue: 2, min: 0.5, max: 5, step: 0.1, isInt: false),
        Entry(key: "period.superTrend.period", group: .period, owner: "SuperTrend", label: "周期", defaultValue: 14, min: 2, max: 90, step: 1),
        Entry(key: "period.superTrend.multiplier", group: .period, owner: "SuperTrend", label: "ATR 倍数", defaultValue: 2.5, min: 0.5, max: 10, step: 0.1, isInt: false),
        Entry(key: "period.ulcerIndex.period", group: .period, owner: "溃疡指数", label: "周期", defaultValue: 14, min: 2, max: 90, step: 1),
        // 成交量
        Entry(key: "period.vwap.period", group: .period, owner: "VWAP", label: "滚动窗口", defaultValue: 14, min: 2, max: 90, step: 1),
        Entry(key: "period.cmf.period", group: .period, owner: "CMF", label: "周期", defaultValue: 20, min: 2, max: 250, step: 1),
        Entry(key: "period.emv.period", group: .period, owner: "EMV", label: "周期", defaultValue: 14, min: 2, max: 90, step: 1),
        Entry(key: "period.forceIndex.period", group: .period, owner: "FI", label: "EMA 周期", defaultValue: 13, min: 2, max: 90, step: 1),
    ]

    // MARK: - osc（Oscillators 六指标阈值；默认值必须 == Config 出厂值）

    public static let oscEntries: [Entry] = [
        Entry(key: "osc.kdj.period", group: .osc, owner: "KDJ", label: "周期", defaultValue: 9, min: 2, max: 90, step: 1),
        Entry(key: "osc.kdj.obK", group: .osc, owner: "KDJ", label: "超买 K 线", defaultValue: 80, min: 50, max: 100, step: 1),
        Entry(key: "osc.kdj.obD", group: .osc, owner: "KDJ", label: "超买 D 线", defaultValue: 70, min: 50, max: 100, step: 1),
        Entry(key: "osc.kdj.obJ", group: .osc, owner: "KDJ", label: "超买 J 线", defaultValue: 90, min: 50, max: 150, step: 1),
        Entry(key: "osc.kdj.osK", group: .osc, owner: "KDJ", label: "超卖 K 线", defaultValue: 20, min: 0, max: 50, step: 1),
        Entry(key: "osc.kdj.osD", group: .osc, owner: "KDJ", label: "超卖 D 线", defaultValue: 30, min: 0, max: 50, step: 1),
        Entry(key: "osc.rsi.period", group: .osc, owner: "RSI(简单均值)", label: "周期", defaultValue: 6, min: 2, max: 90, step: 1),
        Entry(key: "osc.rsi.ob", group: .osc, owner: "RSI(简单均值)", label: "超买线", defaultValue: 80, min: 50, max: 100, step: 1),
        Entry(key: "osc.rsi.severeOb", group: .osc, owner: "RSI(简单均值)", label: "严重超买线", defaultValue: 90, min: 50, max: 100, step: 1),
        Entry(key: "osc.rsi.os", group: .osc, owner: "RSI(简单均值)", label: "超卖线", defaultValue: 20, min: 0, max: 50, step: 1),
        Entry(key: "osc.rsi.severeOs", group: .osc, owner: "RSI(简单均值)", label: "严重超卖线", defaultValue: 10, min: 0, max: 50, step: 1),
        Entry(key: "osc.cci.period", group: .osc, owner: "CCI", label: "周期", defaultValue: 14, min: 2, max: 90, step: 1),
        Entry(key: "osc.cci.ob", group: .osc, owner: "CCI", label: "超买线", defaultValue: 100, min: 0, max: 500, step: 10),
        Entry(key: "osc.cci.os", group: .osc, owner: "CCI", label: "超卖线", defaultValue: -100, min: -500, max: 0, step: 10),
        Entry(key: "osc.cr.period", group: .osc, owner: "CR", label: "周期", defaultValue: 26, min: 2, max: 120, step: 1),
        Entry(key: "osc.cr.sell", group: .osc, owner: "CR", label: "卖出线", defaultValue: 160, min: 50, max: 500, step: 10),
        Entry(key: "osc.cr.buy", group: .osc, owner: "CR", label: "买入线", defaultValue: 40, min: 0, max: 100, step: 5),
        Entry(key: "osc.wr.period", group: .osc, owner: "WR", label: "周期", defaultValue: 14, min: 2, max: 90, step: 1),
        Entry(key: "osc.wr.ob", group: .osc, owner: "WR", label: "超买线", defaultValue: 20, min: 0, max: 100, step: 5),
        Entry(key: "osc.wr.os", group: .osc, owner: "WR", label: "超卖线", defaultValue: 80, min: 0, max: 100, step: 5),
        Entry(key: "osc.vr.period", group: .osc, owner: "VR", label: "周期", defaultValue: 26, min: 2, max: 120, step: 1),
        Entry(key: "osc.vr.sellLow", group: .osc, owner: "VR", label: "卖出区下沿", defaultValue: 160, min: 0, max: 1000, step: 10),
        Entry(key: "osc.vr.sellHigh", group: .osc, owner: "VR", label: "卖出区上沿", defaultValue: 450, min: 0, max: 1000, step: 10),
        Entry(key: "osc.vr.buyLow", group: .osc, owner: "VR", label: "买入区下沿", defaultValue: 40, min: 0, max: 500, step: 10),
        Entry(key: "osc.vr.buyHigh", group: .osc, owner: "VR", label: "买入区上沿", defaultValue: 70, min: 0, max: 500, step: 10),
    ]

    // MARK: 查询

    public static func entry(key: String) -> Entry? { all.first { $0.key == key } }

    public static func entries(group: Group) -> [Entry] { all.filter { $0.group == group } }

    /// 校验：键唯一 + 区间合法（min<max、默认在区间内）
    public static func validate() -> [String] {
        var errors: [String] = []
        let keys = all.map(\.key)
        if Set(keys).count != keys.count { errors.append("存在重复 key") }
        for e in all {
            if e.min >= e.max { errors.append("\(e.key)：min ≥ max") }
            if e.defaultValue < e.min || e.defaultValue > e.max { errors.append("\(e.key)：默认值越界") }
            if e.step <= 0 { errors.append("\(e.key)：step ≤ 0") }
        }
        return errors
    }
}
