import Foundation

/// 「无大幅回撤」风险判据 —— **纯计算**。
///
/// ## 口径
/// 「无大幅回撤」= `60 日涨幅 < 60%` + `无单日跌超 7%`。
///
/// ⚠ **来源把涨幅写成小数**（"量比 ≥ 2" 就是 2 倍），所以 `0.6` = 60%。
/// 若读作 0.6% 则几乎没有票满足 —— 与"稳健型选股"的意图不符。
/// 因为这是个**读数**而不是既定事实，所以阈值做成**可调参数**，并写在卡上。
///
/// ## ⚠ 与 Selected 既有三层风险结构的关系
///
/// | 既有 | 口径 | 关系 |
/// |------|------|------|
/// | 第 3 层硬过滤 | `change_pct_min = -7.0`（**当日**跌幅剔除） | **不同**：这里看**历史**单日跌幅 |
/// | 第 6 层强制避雷 | `volume_ratio_hard_max` / `turnover_hard_max` | **不同**：量能口径 |
/// | 第 8 层深度趋势排除 | `distFromHigh60d = (现价 − 60 日最高收盘)/最高收盘` | **互补**：那个量**下跌侧**（防接刀），本项量**上涨侧**（防追高） |
/// | `scoring.bonus.cum_5d` | 5 日累计涨幅（越大加分越少） | **同向、不同周期**：那个 5 日，本项 60 日 |
///
/// → `EngineIndicators` 里**没有**"60 日累计涨幅"（只有 5 日）、
///   **没有**"区间最大单日跌幅"（任何周期都没有）⇒ **两条都是新维度**。
///
/// ## ⚠ 为什么**只展示、不做成排除项**
/// 1. 做成排除会改 `excluded_stocks` 输出 → 改变历史行为 → 只能"新参数 + **默认关**"
/// 2. 而"**默认关的排除项**"正是本项目反复踩的坑：永不生效的参数最终都成了死参数
/// 3. 且**方向尚未标定**：没有样本能回答"剔掉'暴涨过的票'"是提升还是削弱胜率 ——
///    而 Selected 的核心是**动量型**（当日放量上涨 + 均线多头），"防追高"与它**有张力**
///    （`cum_5d` 的加分递减已体现这种张力，但那是**加分**不是**排除**）
///
/// → 先展示。完整论证见 `docs/specs/README.md`。
public enum DeepDrawdown {

    /// 计算窗口（**交易日**）。默认 60 —— 口径就是 60 日。
    public static let defaultDays = 60
    /// 单日跌幅上限（%）
    public static let defaultMaxDropLimit = 7.0
    /// 区间累计涨幅上限（%，来源写成 `0.6`，读作 60%）
    public static let defaultCumGainLimit = 60.0

    /// 判定结果
    public struct Stats: Equatable, Sendable {
        /// 计算窗口（交易日）
        public let days: Int
        /// 实际参与计算的 bar 数
        public let bars: Int
        /// 区间内**最大单日跌幅**（%，正值表示跌了多少）
        public let maxDrop1d: Double?
        /// 那次最大跌幅发生在**多少个交易日前**（0 = 就是最后一根）。
        /// ⚠ 用"多少根之前"而不是日期：输入协议 `OHLCBar` **只有 OHLC、没有日期**
        /// （加日期字段会破坏所有既有 conformer）。
        public let maxDropAgoBars: Int
        /// 区间**累计涨幅**（%）
        public let cumGain: Double?
        /// 是否满足"无大幅回撤"。
        /// ⚠ 任一项算不出来 → **`false`**（不声称一个我们验证不了的"安全"）
        public let clean: Bool
    }

    /// 算区间回撤结构。
    ///
    /// - Parameter bars: 按时间**正序**（最后一根是当日）。
    /// - Returns: 样本不足（`< days + 1` 根）→ `nil`。
    ///
    /// ⚠ **为什么需要 `days + 1` 根**：`days` 个交易日的涨幅需要 `days + 1` 个收盘价
    /// （与 `cumGain5d` 用 6 个收盘算 5 日涨幅同一口径）。同理"单日跌幅"的区间是
    /// 窗口内的 `days` 个**相邻间隔**。
    /// ⚠ 全程**收盘对收盘** —— 与 `cum_5d` / `consec_up` / `prev_1d` 一致。
    /// 用 `(high − low)` 或 `(前收 − 最低)` 会让同一张卡上两个"跌幅"含义不同。
    public static func stats<B: Sequence>(_ bars: B, days: Int = defaultDays,
                                          maxDropLimit: Double = defaultMaxDropLimit,
                                          cumGainLimit: Double = defaultCumGainLimit) -> Stats?
    where B.Element: OHLCBar {
        let arr = Array(bars)
        guard days >= 1, arr.count >= days + 1 else { return nil }
        let window = Array(arr.suffix(days + 1))
        guard let first = window.first, let last = window.last else { return nil }

        // ---- 累计涨幅：末收 ÷ 首收 − 1 ----
        let cumGain: Double? = first.close > 0
            ? PyMath.round((last.close - first.close) / first.close * 100, 2) : nil

        // ---- 最大单日跌幅：窗口内相邻两两比，取跌幅最大的一次 ----
        var maxDrop: Double?
        var maxDropAgo = 0
        for i in 1..<window.count {
            let prev = window[i - 1].close
            let cur = window[i].close
            guard prev > 0 else { continue }          // 前收非正 → 这一格算不出（不猜）
            let drop = (prev - cur) / prev * 100      // 涨为负、跌为正
            if maxDrop == nil || drop > maxDrop! {
                maxDrop = drop
                maxDropAgo = window.count - 1 - i     // 0 = 最后一根
            }
        }
        let maxDropRounded = maxDrop.map { PyMath.round($0, 2) }

        // ---- 判定 ----
        // ⚠ 任一项算不出来 → 不算"干净"（不声称一个验证不了的结论）
        let clean: Bool
        if let d = maxDropRounded, let g = cumGain {
            clean = d <= maxDropLimit && g <= cumGainLimit
        } else {
            clean = false
        }

        return Stats(days: days, bars: window.count,
                     maxDrop1d: maxDropRounded, maxDropAgoBars: maxDropAgo,
                     cumGain: cumGain, clean: clean)
    }
}
