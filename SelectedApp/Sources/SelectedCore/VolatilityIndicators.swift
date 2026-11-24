import Foundation

/// 波动率类指标 —— **Bollinger 系 / Donchian / Keltner / SuperTrend / Ulcer / ATR(SMA)**
///
/// ## ⚠ ATR 口径分裂（必须知道再调用）
/// 本文件的 `atrSmaSeries` 是 **SMA of TR**（黄金夹具 `atr.csv` 口径，
/// Keltner / SuperTrend 也建立在这条上）；项目既有的 `TechnicalIndicators.atr`
/// 是 **Wilder（RMA of TR）**。两者在跳空/波动变化时数值不同，
/// 交叉测试（`VolatilityIndicatorsCrossTests`）把差异显式钉住，防止有人"顺手统一"。
///
/// ## 通用约定
/// 序列优先、等长对齐、预热 `nil`；不取整；分母为 0 → `nil`（"算不出"不伪装成 0）。
public enum VolatilityIndicators {

    // MARK: - 输出结构

    /// 布林带全家（中线 / 上轨 / 下轨 / 带宽 / %B），五条序列等长对齐。
    public struct BollingerSeries: Sendable {
        public let middle: [Double?]
        public let upper: [Double?]
        public let lower: [Double?]
        /// `(上 − 下) / 中 × 100`（百分数口径；夹具 `bollinger_band_width.csv` 是
        /// 0–1 比例，测试侧 ×100 比对）。
        public let bandwidth: [Double?]
        /// `(收 − 下) / (上 − 下)`；带宽为 0 → `nil`。
        public let percentB: [Double?]
    }

    /// 唐奇安通道。
    public struct DonchianSeries: Sendable {
        public let upper: [Double?]
        public let middle: [Double?]
        public let lower: [Double?]
    }

    /// 肯特纳通道：中线 EMA，上下轨 = 中线 ± 2×ATR(SMA)。
    public struct KeltnerSeries: Sendable {
        public let middle: [Double?]
        public let upper: [Double?]
        public let lower: [Double?]
    }

    /// 超级趋势：趋势线 + 方向（`trendUp[i] == true` 表示该位处于上升趋势）。
    public struct SuperTrendSeries: Sendable {
        public let line: [Double?]
        public let trendUp: [Bool?]
    }

    // MARK: - ATR（SMA of TR，夹具口径）

    /// `ATR_SMA(n) = SMA(TR, n)` —— 夹具 `atr.csv` 口径（非 Wilder）。
    public static func atrSmaSeries<B: Sequence>(_ bars: B, period: Int = 14) -> [Double?]
    where B.Element: OHLCBar {
        IndicatorPrimitives.smaSeries(IndicatorPrimitives.trueRanges(bars), period)
    }

    // MARK: - Bollinger

    /// 布林带 —— `中 = SMA(n)`，`上/下 = 中 ± k·σ(总体)`，并顺带产出带宽与 %B。
    ///
    /// ⚠ σ 为**总体**标准差（除以 n）—— 由 `bollinger_bands.csv` 反推核过
    ///   （见 `IndicatorPrimitives.stddevSeries`）。
    /// ⚠ 带宽除数用中线；中线为 0（脏数据）→ 该位 `nil`。
    public static func bollingerBands<B: Sequence>(_ bars: B, period: Int = 20,
                                                   multiplier: Double = 2) -> BollingerSeries
    where B.Element: OHLCBar {
        let closes = IndicatorPrimitives.closes(bars)
        let middle = IndicatorPrimitives.smaSeries(closes, period)
        let sigma = IndicatorPrimitives.stddevSeries(closes, period)
        var upper: [Double?] = Array(repeating: nil, count: closes.count)
        var lower: [Double?] = Array(repeating: nil, count: closes.count)
        for i in 0..<closes.count {
            guard let m = middle[i], let s = sigma[i] else { continue }
            upper[i] = m + multiplier * s
            lower[i] = m - multiplier * s
        }
        var bandwidth: [Double?] = Array(repeating: nil, count: closes.count)
        var percentB: [Double?] = Array(repeating: nil, count: closes.count)
        for i in 0..<closes.count {
            if let u = upper[i], let l = lower[i], let m = middle[i], m != 0 {
                bandwidth[i] = (u - l) / m * 100
            }
            if let u = upper[i], let l = lower[i], u != l {
                percentB[i] = (closes[i] - l) / (u - l)
            }
        }
        return BollingerSeries(middle: middle, upper: upper, lower: lower,
                               bandwidth: bandwidth, percentB: percentB)
    }

    // MARK: - Donchian

    /// 唐奇安通道 —— `上 = max(H,n)`，`下 = min(L,n)`，`中 = (上+下)/2`。
    public static func donchianChannel<B: Sequence>(_ bars: B, period: Int = 20) -> DonchianSeries
    where B.Element: OHLCBar {
        let bars = Array(bars)
        let upper = IndicatorPrimitives.rollingMax(IndicatorPrimitives.highs(bars), period)
        let lower = IndicatorPrimitives.rollingMin(IndicatorPrimitives.lows(bars), period)
        var middle: [Double?] = Array(repeating: nil, count: bars.count)
        for i in 0..<bars.count {
            if let u = upper[i], let l = lower[i] { middle[i] = (u + l) / 2 }
        }
        return DonchianSeries(upper: upper, middle: middle, lower: lower)
    }

    // MARK: - Keltner

    /// 肯特纳通道 —— `中 = EMA(n)`，`上/下 = 中 ± 2×ATR_SMA(n)`。
    ///
    /// ⚠ 夹具口径：ATR 周期与通道周期**同为 n**（KC(20) → Atr(20)），且 ATR 是
    ///   SMA 口径（见文件头）。Keltner 挤压（带宽 < 布林带宽）是常用判据，
    ///   但**方向未标定**，接筛选规则前走参数中心流程。
    public static func keltnerChannel<B: Sequence>(_ bars: B, period: Int = 20,
                                                   multiplier: Double = 2) -> KeltnerSeries
    where B.Element: OHLCBar {
        let middle = IndicatorPrimitives.emaSeries(IndicatorPrimitives.closes(bars), period)
        let atr = atrSmaSeries(bars, period: period)
        var upper: [Double?] = Array(repeating: nil, count: middle.count)
        var lower: [Double?] = Array(repeating: nil, count: middle.count)
        for i in 0..<middle.count {
            guard let m = middle[i], let a = atr[i] else { continue }
            upper[i] = m + multiplier * a
            lower[i] = m - multiplier * a
        }
        return KeltnerSeries(middle: middle, upper: upper, lower: lower)
    }

    // MARK: - SuperTrend

    /// 超级趋势 —— 基准线 **HL2 中价**，带宽 `± multiplier × HMA(TR, period)`，
    /// 带"最终带只朝趋势方向收紧"的锁定递推。
    ///
    /// ⚠ 口径由夹具锁定（`super_trend.csv` 逐点吻合）：
    ///   · 名字里的 `HMA(14)` 指 **TR 的平滑是 HMA**（不是 SMA/EMA），基准线是 `(H+L)/2`；
    ///   · 首位输出 = HMA(TR) 首个有效位（索引 `2×period−2` 附近），初始方向按
    ///     "收盘 ≥ 最终下轨 → 下轨作线" 的下降分支起步（首个线值 = finalLower）；
    ///   · 递推：`上带 = min(原始上带, 前最终上带)`（除非昨收突破它）、
    ///     `下带 = max(原始下带, 前最终下带)`（除非昨收跌破它），
    ///     持涨中收盘 ≥ 最终上轨则翻跌、持跌中收盘 ≥ 最终下轨则持下轨。
    ///   这与通达信 SuperTrend 的常见写法（EMA 基准）不同 —— 接 UI 时以本注释为准。
    /// ```
    /// 上升持有时：line = finalLower；收盘 < finalLower → 转下降取 finalUpper
    /// 下降持有时：line = finalUpper；收盘 > finalUpper → 转上升取 finalLower
    /// ```
    public static func superTrend<B: Sequence>(_ bars: B, period: Int = 14,
                                               multiplier: Double = 2.5) -> SuperTrendSeries
    where B.Element: OHLCBar {
        let bars = Array(bars)
        let n = bars.count
        let basis = IndicatorPrimitives.medianPrices(bars)
        let atr = hmaSeries(IndicatorPrimitives.trueRanges(bars), period: period)
        var line: [Double?] = Array(repeating: nil, count: n)
        var trendUp: [Bool?] = Array(repeating: nil, count: n)
        var finalUpper: Double?
        var finalLower: Double?
        var upTrend = false
        var first = true
        var prevClose: Double?
        for i in 0..<n {
            guard let a = atr[i] else { continue }
            let rawUpper = basis[i] + multiplier * a
            let rawLower = basis[i] - multiplier * a
            let close = bars[i].close
            let out: Double
            if first {
                first = false
                finalUpper = rawUpper
                finalLower = rawLower
                out = rawLower // 夹具口径：首位输出下轨（初始按下降分支）
            } else {
                let prev = prevClose ?? close
                if rawUpper < finalUpper! || prev > finalUpper! { finalUpper = rawUpper }
                if rawLower > finalLower! || prev < finalLower! { finalLower = rawLower }
                if upTrend {
                    if close <= finalUpper! {
                        out = finalUpper!
                    } else {
                        out = finalLower!
                        upTrend = false
                    }
                } else {
                    if close >= finalLower! {
                        out = finalLower!
                    } else {
                        out = finalUpper!
                        upTrend = true
                    }
                }
            }
            line[i] = out
            // trendUp 语义：线在价格下方 = 上升趋势支撑线
            trendUp[i] = out <= close
            prevClose = close
        }
        return SuperTrendSeries(line: line, trendUp: trendUp)
    }

    /// HMA 的裸序列入口（任意数值数组版，供 SuperTrend 对 TR 做 HMA 平滑复用；
    /// 口径同 `TrendIndicators.hma`：half/√ 都四舍五入）。
    private static func hmaSeries(_ values: [Double], period: Int) -> [Double?] {
        let half = max(1, Int((Double(period) / 2).rounded(.awayFromZero)))
        let root = max(1, Int(Double(period).squareRoot().rounded(.awayFromZero)))
        let wmaHalf = IndicatorPrimitives.wmaSeries(values, half)
        let wmaFull = IndicatorPrimitives.wmaSeries(values, period)
        var raw: [Double?] = Array(repeating: nil, count: values.count)
        for i in 0..<values.count {
            if let a = wmaHalf[i], let b = wmaFull[i] { raw[i] = 2 * a - b }
        }
        guard root >= 1, raw.count >= root else { return Array(repeating: nil, count: values.count) }
        let denom = Double(root * (root + 1) / 2)
        var out: [Double?] = Array(repeating: nil, count: values.count)
        for i in (root - 1)..<values.count {
            var acc = 0.0
            var ok = true
            for k in 0..<root {
                guard let v = raw[i - root + 1 + k] else { ok = false; break }
                acc += Double(k + 1) * v
            }
            if ok { out[i] = acc / denom }
        }
        return out
    }

    // MARK: - Ulcer Index

    /// 溃疡指数 —— 回撤的"痛苦程度"：`UI = √(SMA(pct², n))`。
    ///
    /// ```
    /// maxN = max(C, n 窗口)；rel = C − maxN；pct = 100 × rel / maxN
    /// ```
    /// ⚠ `maxN == 0`（脏数据）→ 该位 `nil`。UI ≥ 0，无超买超卖方向，只量"磨人程度"。
    public static func ulcerIndex<B: Sequence>(_ bars: B, period: Int = 14) -> [Double?]
    where B.Element: OHLCBar {
        let closes = IndicatorPrimitives.closes(bars)
        guard period >= 1, closes.count >= period else {
            return Array(repeating: nil, count: closes.count)
        }
        let rollingMax = IndicatorPrimitives.rollingMax(closes, period)
        var pctSq: [Double?] = Array(repeating: nil, count: closes.count)
        for i in 0..<closes.count {
            guard let mx = rollingMax[i], mx != 0 else { continue }
            let rel = closes[i] - mx
            let pct = 100 * rel / mx
            pctSq[i] = pct * pct
        }
        let mean = IndicatorPrimitives.smaSeries(pctSq, period)
        return mean.map { v in v.flatMap { $0 >= 0 ? $0.squareRoot() : nil } }
    }
}
