import Foundation

/// 动量类指标 —— **RSI 序列 / Stochastic / StochRSI / PPO / AO / UO**
///
/// ## ⚠ 与 `Oscillators` 的口径关系（两份 RSI 并存，各有用途）
/// `Oscillators.rsi` 是**简单均值**口径（国内通达信习惯，服务既有评分链路，**不动它**）；
/// 本文件的 `rsiSeries` 是 **Wilder 平滑**口径（与黄金夹具 `rsi.csv` 一致），
/// 且 StochRSI 的定义就建立在 Wilder RSI 序列上。两者由各自的测试锁死，
/// 消费方（快照 Job）用哪个**必须写进指标注册表的口径字段**，不许靠名字猜。
///
/// ## 通用约定（同 `TrendIndicators`）
/// 序列优先、等长对齐、预热 `nil`；一字板 / 全平区间等**无位置信息**的场景取
/// 中性 50（与 `Oscillators.kdj` 同哲学）；不取整。
public enum MomentumIndicators {

    // MARK: - 输出结构

    /// Stochastic 两件套（%K 平滑线 / %D）。
    public struct StochasticSeries: Sendable {
        public let k: [Double?]
        public let d: [Double?]
    }

    /// PPO 三件套（线 / 信号线 / 柱），口径同 MACD 但用百分比。
    public struct PpoSeries: Sendable {
        public let line: [Double?]
        public let signal: [Double?]
        public let histogram: [Double?]
    }

    // MARK: - RSI（Wilder 平滑序列）

    /// Wilder RSI 序列：种子 = 前 n 根涨跌的简单均值，之后 RMA 递推。
    ///
    /// `i < n` 为 `nil`（第 n 根才有种子值）。`Σ涨+Σ跌 == 0` → 中性 50
    /// （与 `Oscillators.rsi` 同一处理：全平区间没有方向信息，不硬造 0/100）。
    public static func rsiSeries<B: Sequence>(_ bars: B, period: Int = 14) -> [Double?]
    where B.Element: OHLCBar {
        let closes = IndicatorPrimitives.closes(bars)
        guard period >= 1, closes.count > period else {
            return Array(repeating: nil, count: closes.count)
        }
        let changes = zip(closes.dropFirst(), closes).map { $0 - $1 }
        // 种子是**均值**：递推项 (avg·(n−1)+ch)/n 作用在均值上，用和会整体偏移
        var gain = 0.0, loss = 0.0
        for ch in changes[0..<period] {
            if ch > 0 { gain += ch } else if ch < 0 { loss -= ch }
        }
        gain /= Double(period)
        loss /= Double(period)
        var out: [Double?] = Array(repeating: nil, count: closes.count)
        func value(_ g: Double, _ l: Double) -> Double {
            g + l > 0 ? 100 * g / (g + l) : 50
        }
        out[period] = value(gain, loss)
        for i in period..<changes.count {
            let ch = changes[i]
            gain = (gain * Double(period - 1) + max(0, ch)) / Double(period)
            loss = (loss * Double(period - 1) + max(0, -ch)) / Double(period)
            out[i + 1] = value(gain, loss)
        }
        return out
    }

    // MARK: - Stochastic（随机指标）

    /// Stochastic —— `rawK = (C − LL_n)/(HH_n − LL_n) × 100`，`%D = SMA(rawK, smooth)`。
    ///
    /// ⚠ 夹具口径：`STOCHOSC(14,3)` 的 **3 只作用于 %D**，`%K` 就是未平滑的 rawK。
    ///   通达信"K=D 的 SMA"式慢随机与本口径不同，接 UI 展示时以本注释为准。
    /// ⚠ `HH == LL`（一字板）→ rawK 取中性 50（同 `Oscillators.kdj` 的 RSV 处理）。
    public static func stochastic<B: Sequence>(_ bars: B, period: Int = 14, smooth: Int = 3)
        -> StochasticSeries where B.Element: OHLCBar {
        let bars = Array(bars)
        let closes = IndicatorPrimitives.closes(bars)
        let highs = IndicatorPrimitives.highs(bars)
        let lows = IndicatorPrimitives.lows(bars)
        guard period >= 1, bars.count >= period else {
            return StochasticSeries(k: Array(repeating: nil, count: bars.count),
                                    d: Array(repeating: nil, count: bars.count))
        }
        var rawK: [Double?] = Array(repeating: nil, count: bars.count)
        for i in (period - 1)..<bars.count {
            let hh = highs[(i - period + 1)...i].max() ?? 0
            let ll = lows[(i - period + 1)...i].min() ?? 0
            rawK[i] = hh > ll ? (closes[i] - ll) / (hh - ll) * 100 : 50
        }
        // %K = rawK（不平滑）；%D = SMA(rawK, smooth)
        let d = IndicatorPrimitives.smaSeries(rawK, smooth)
        return StochasticSeries(k: rawK, d: d)
    }

    // MARK: - StochRSI

    /// Stochastic RSI —— 把 Stochastic 公式套在 **Wilder RSI 序列**上：
    /// `(RSI − min(RSI,n)) / (max(RSI,n) − min(RSI,n)) × 100`，窗口 n = period。
    ///
    /// ⚠ 本项目对外统一 **0–100** 口径；夹具 `stochastic_rsi.csv` 是 0–1 比例
    ///   （测试侧 ×100 后比对，容差相应放大）。
    ///
    /// ⚠ 分母为 0（RSI 窗口内全平）→ 中性 50。
    /// ⚠ RSI 预热段（前 period 根）无值 → 窗口凑不齐 → `nil`，
    ///   首个有效位自然落在 `2×period` 附近。
    public static func stochasticRsi<B: Sequence>(_ bars: B, period: Int = 14) -> [Double?]
    where B.Element: OHLCBar {
        let rsi = rsiSeries(bars, period: period)
        let n = rsi.count
        guard period >= 1 else { return Array(repeating: nil, count: n) }
        var out: [Double?] = Array(repeating: nil, count: n)
        for i in 0..<n {
            guard i >= period - 1 else { continue }
            let win = rsi[(i - period + 1)...i]
            guard win.allSatisfy({ $0 != nil }), let cur = rsi[i] else { continue }
            let vals = win.compactMap { $0 }
            let lo = vals.min() ?? 0, hi = vals.max() ?? 0
            out[i] = hi > lo ? (cur - lo) / (hi - lo) * 100 : 50
        }
        return out
    }

    // MARK: - PPO

    /// PPO —— `(EMA(fast) − EMA(slow)) / EMA(slow) × 100`；信号线 = EMA(line, signal)。
    ///
    /// ⚠ 与 MACD 同骨架，差别只在除以慢线并乘 100（跨价格水平可比）。
    public static func ppo<B: Sequence>(_ bars: B, fast: Int = 12, slow: Int = 26, signal: Int = 9)
        -> PpoSeries where B.Element: OHLCBar {
        let closes = IndicatorPrimitives.closes(bars)
        let emaFast = IndicatorPrimitives.emaSeries(closes, fast)
        let emaSlow = IndicatorPrimitives.emaSeries(closes, slow)
        var line: [Double?] = Array(repeating: nil, count: closes.count)
        for i in 0..<closes.count {
            if let f = emaFast[i], let s = emaSlow[i], s != 0 {
                line[i] = (f - s) / s * 100
            }
        }
        let sig = IndicatorPrimitives.emaSeries(line, signal)
        return PpoSeries(line: line, signal: sig,
                         histogram: IndicatorPrimitives.subtract(line, sig))
    }

    // MARK: - Awesome Oscillator

    /// AO —— `SMA(中价, 5) − SMA(中价, 34)`，中价 = (H+L)/2。
    ///
    /// ⚠ 只用 H/L（不吃收盘）。
    public static func awesomeOscillator<B: Sequence>(_ bars: B, short: Int = 5, long: Int = 34)
        -> [Double?] where B.Element: OHLCBar {
        let median = IndicatorPrimitives.medianPrices(bars)
        return IndicatorPrimitives.subtract(
            IndicatorPrimitives.smaSeries(median, short),
            IndicatorPrimitives.smaSeries(median, long))
    }

    // MARK: - Ultimate Oscillator

    /// UO —— 三周期加权：`100 × (4·R7 + 2·R14 + R28) / 7`，
    /// 其中 `R_p = Σ BP / Σ TR`（窗口 p 内**先求和再相除**，不是逐根比值平均）。
    ///
    /// ```
    /// BP_k = C_k − min(L_k, C_{k−1})
    /// TR_k = max(H_k, C_{k−1}) − min(L_k, C_{k−1})   （教科书"含昨收"口径）
    /// ```
    /// ⚠ 首根无昨收：退化为当日 L/H（与 `trueRanges` 首根同处理）。
    /// ⚠ `ΣTR == 0`（全平窗口）→ 该周期项记 0（无信息不硬造结论）。
    public static func ultimateOscillator<B: Sequence>(_ bars: B, short: Int = 7,
                                                       medium: Int = 14, long: Int = 28)
        -> [Double?] where B.Element: OHLCBar {
        let bars = Array(bars)
        let n = bars.count
        guard short >= 1, medium >= short, long >= medium, n > long else {
            return Array(repeating: nil, count: n)
        }
        // 预计算逐根 BP/TR（k≥1 含昨收；k=0 退化为当日区间）
        var bp = [Double](repeating: 0, count: n)
        var tr = [Double](repeating: 0, count: n)
        for k in 0..<n {
            let prevClose = k > 0 ? bars[k - 1].close : bars[k].close
            let lo = Swift.min(bars[k].low, prevClose)
            let hi = Swift.max(bars[k].high, prevClose)
            bp[k] = bars[k].close - lo
            tr[k] = hi - lo
        }
        var out: [Double?] = Array(repeating: nil, count: n)
        for i in long..<n {
            var total = 0.0
            for (period, weight) in [(short, 4.0), (medium, 2.0), (long, 1.0)] {
                let start = i - period + 1
                let sumBp = PyMath.sum(bp[start...i])
                let sumTr = PyMath.sum(tr[start...i])
                if sumTr > 0 { total += weight * sumBp / sumTr }
            }
            out[i] = total / 7 * 100
        }
        return out
    }
}
