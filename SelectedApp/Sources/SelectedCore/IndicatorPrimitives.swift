import Foundation

/// 指标共享原语 —— 移动平均 / 滚动窗口 / 价格列提取。
///
/// ## 定位
/// 上层 `TrendIndicators` / `MomentumIndicators` / `VolatilityIndicators` /
/// `VolumeIndicators` 全部由这里的原语组合而成。**口径问题只在这一个文件解决一次**，
/// 上层不再各自实现求和/平滑，避免"同一个 MA 三种写法"的漂移。
///
/// ## ⚠ 口径来源：黄金夹具，不是教科书
/// 各平滑的**种子与起点**以 `Tests/SelectedCoreTests/Fixtures/indicator_golden/`
/// 的 CSV 为准（cinar/indicator testdata；公式按公开定义 clean-room 实现）。
/// 与教科书不一致处在各函数注释写明。
/// 已知口径分裂（名字必须带平滑方式，**不许"就叫 ATR、口径靠猜"**）：
///   · ATR —— 本项目的 `TechnicalIndicators.atr` 是 **Wilder（RMA of TR）**；
///     夹具里的 `Atr` 是 **SMA of TR**（`VolatilityIndicators` 按夹具口径提供）。
///   · RSI —— `Oscillators.rsi` 是简单均值口径；夹具口径以黄金测试实测为准。
///
/// ## ⚠ 返回值约定
/// 不取整；样本不足 → `nil`，不返回 0；序列与输入**等长对齐**，预热位为 `nil`。
/// 求和一律走 `PyMath.sum`（Neumaier 补偿），朴素 `reduce(0,+)` 在长序列上会漂。
public enum IndicatorPrimitives {

    // MARK: - 价格列提取

    /// 收盘价列。
    public static func closes<B: Sequence>(_ bars: B) -> [Double] where B.Element: OHLCBar {
        bars.map(\.close)
    }

    /// 最高价列。
    public static func highs<B: Sequence>(_ bars: B) -> [Double] where B.Element: OHLCBar {
        bars.map(\.high)
    }

    /// 最低价列。
    public static func lows<B: Sequence>(_ bars: B) -> [Double] where B.Element: OHLCBar {
        bars.map(\.low)
    }

    /// 成交量列。
    public static func volumes<B: Sequence>(_ bars: B) -> [Double] where B.Element: VolumeBar {
        bars.map(\.volume)
    }

    /// 典型价 `TP = (H + L + C) / 3`（MFI / CMF / VWAP 用）。
    public static func typicalPrices<B: Sequence>(_ bars: B) -> [Double] where B.Element: OHLCBar {
        bars.map { ($0.high + $0.low + $0.close) / 3 }
    }

    /// 中价 `MedianPrice = (H + L) / 2`（AO / EMV 用）。
    public static func medianPrices<B: Sequence>(_ bars: B) -> [Double] where B.Element: OHLCBar {
        bars.map { ($0.high + $0.low) / 2 }
    }

    // MARK: - 简单移动平均 SMA

    /// SMA 序列：`out[i] = mean(values[i-n+1 … i])`，`i < n-1` 为 `nil`。
    ///
    /// ⚠ 求和走 `PyMath.sum`；窗口起点固定用切片求和（每窗独立补偿求和），
    /// 不用"滑动加减"——后者误差会沿序列累积。
    public static func smaSeries(_ values: [Double], _ period: Int) -> [Double?] {
        guard period >= 1, values.count >= period else {
            return Array(repeating: nil, count: values.count)
        }
        var out: [Double?] = Array(repeating: nil, count: values.count)
        for i in (period - 1)..<values.count {
            out[i] = PyMath.sum(values[(i - period + 1)...i]) / Double(period)
        }
        return out
    }

    /// SMA 的 nil 容忍版：窗口内出现 `nil` → 该位 `nil`（等价"等窗口填满有值段"）。
    ///
    /// 组合类指标（KST 的 ROC→SMA、StochRSI 等）上游带预热 `nil`，靠这条衔接。
    public static func smaSeries(_ values: [Double?], _ period: Int) -> [Double?] {
        guard period >= 1, values.count >= period else {
            return Array(repeating: nil, count: values.count)
        }
        var out: [Double?] = Array(repeating: nil, count: values.count)
        for i in (period - 1)..<values.count {
            var acc = 0.0
            var ok = true
            for k in (i - period + 1)...i {
                guard let v = values[k] else { ok = false; break }
                acc += v
            }
            if ok { out[i] = acc / Double(period) }
        }
        return out
    }

    // MARK: - 加权移动平均 WMA

    /// WMA 序列：权重 `1…n`（越近权重越大），`i < n-1` 为 `nil`。
    ///
    /// `WMA = Σ(w_k · x_k) / Σ(w_k)`，`Σw = n(n+1)/2`。HMA 的组合项用它。
    public static func wmaSeries(_ values: [Double], _ period: Int) -> [Double?] {
        guard period >= 1, values.count >= period else {
            return Array(repeating: nil, count: values.count)
        }
        let denom = Double(period * (period + 1) / 2)
        var out: [Double?] = Array(repeating: nil, count: values.count)
        for i in (period - 1)..<values.count {
            var acc = 0.0
            for k in 0..<period {
                acc += Double(k + 1) * values[i - period + 1 + k]
            }
            out[i] = acc / denom
        }
        return out
    }

    // MARK: - 指数移动平均 EMA

    /// EMA 序列，**种子 = 前 n 个有值项的 SMA**（教科书口径），`α = 2/(n+1)`。
    ///
    /// ⚠ 口径由夹具锁定：`envelope_ema.csv` 的 Middle 首个非 0 行 = 前 20 根收盘的
    /// SMA，**不是**"种子=首值"的流派。
    /// ⚠ 输入允许带 `nil`（如 MACD 线本身有预热段）：只在**有值项**上递推，
    /// 种子吃前 n 个有值项，输出与输入**按原索引对齐**、预热位为 `nil`。
    public static func emaSeries(_ values: [Double?], _ period: Int) -> [Double?] {
        guard period >= 1 else { return values }
        var out: [Double?] = Array(repeating: nil, count: values.count)
        let alpha = 2.0 / Double(period + 1)
        var seed: [Double] = []
        seed.reserveCapacity(period)
        var prev: Double?
        for i in 0..<values.count {
            guard let v = values[i] else { continue }
            if let p = prev {
                let next = v * alpha + p * (1 - alpha)
                out[i] = next
                prev = next
            } else {
                seed.append(v)
                if seed.count == period {
                    let value = PyMath.sum(seed) / Double(period)
                    out[i] = value
                    prev = value
                }
            }
        }
        return out
    }

    /// 无预热输入的便捷重载。
    public static func emaSeries(_ values: [Double], _ period: Int) -> [Double?] {
        emaSeries(values.map { Optional($0) }, period)
    }

    // MARK: - Wilder 平滑 RMA

    /// RMA（Wilder 平滑）序列：种子 = 前 n 项 SMA，之后 `x_t = (x_{t-1}(n-1) + v_t)/n`。
    ///
    /// `i < n-1` 为 `nil`。ATR(Wilder)、RSI(Wilder 口径) 都建立在这条上。
    /// ⚠ 与 `TechnicalIndicators.atr` 的种子/递推完全同款。
    public static func rmaSeries(_ values: [Double], _ period: Int) -> [Double?] {
        guard period >= 1, values.count >= period else {
            return Array(repeating: nil, count: values.count)
        }
        var out: [Double?] = Array(repeating: nil, count: values.count)
        var value = PyMath.sum(values[0..<period]) / Double(period)
        out[period - 1] = value
        for i in period..<values.count {
            value = (value * Double(period - 1) + values[i]) / Double(period)
            out[i] = value
        }
        return out
    }

    // MARK: - 滚动极值

    /// 滚动最大值：`out[i] = max(values[i-n+1 … i])`，`i < n-1` 为 `nil`。
    public static func rollingMax(_ values: [Double], _ period: Int) -> [Double?] {
        rollingWindow(values, period) { window in window.max() ?? 0 }
    }

    /// 滚动最小值。
    public static func rollingMin(_ values: [Double], _ period: Int) -> [Double?] {
        rollingWindow(values, period) { window in window.min() ?? 0 }
    }

    /// 滚动窗口通用骨架（极值/自定义归约共用，避免三份手写循环漂移）。
    private static func rollingWindow(_ values: [Double], _ period: Int,
                                      _ reduce: (ArraySlice<Double>) -> Double) -> [Double?] {
        guard period >= 1, values.count >= period else {
            return Array(repeating: nil, count: values.count)
        }
        var out: [Double?] = Array(repeating: nil, count: values.count)
        for i in (period - 1)..<values.count {
            out[i] = reduce(values[(i - period + 1)...i])
        }
        return out
    }

    // MARK: - 标准差

    /// 滚动**总体**标准差（除以 n，不是 n-1）。
    ///
    /// ⚠ 总体 vs 样本以夹具为准（`bollinger_bands.csv` 的上轨 = SMA + 2σ）；
    /// 若换样本口径，布林带宽会在短序列上系统性偏宽。
    public static func stddevSeries(_ values: [Double], _ period: Int) -> [Double?] {
        guard period >= 1, values.count >= period else {
            return Array(repeating: nil, count: values.count)
        }
        let sma = smaSeries(values, period)
        var out: [Double?] = Array(repeating: nil, count: values.count)
        for i in (period - 1)..<values.count {
            guard let mean = sma[i] else { continue }
            var acc = 0.0
            for k in (i - period + 1)...i {
                let d = values[k] - mean
                acc += d * d
            }
            out[i] = (acc / Double(period)).squareRoot()
        }
        return out
    }

    // MARK: - 真实波幅 TR

    /// 真实波幅序列：`TR = max(H-L, |H-昨收|, |L-昨收|)`，首根取 `H-L`。
    ///
    /// ⚠ 与 `TechnicalIndicators.trueRanges` 同口径（首根处理一致）；
    /// 这里收一份 `[Double]` 进 `[Double]` 出，方便 ATR 两种平滑复用。
    public static func trueRanges<B: Sequence>(_ bars: B) -> [Double] where B.Element: OHLCBar {
        let bars = Array(bars)
        guard !bars.isEmpty else { return [] }
        var out: [Double] = [max(0, bars[0].high - bars[0].low)]
        out.reserveCapacity(bars.count)
        for i in 1..<bars.count {
            let prevClose = bars[i - 1].close
            let h = bars[i].high, l = bars[i].low
            out.append(max(h - l, max(abs(h - prevClose), abs(l - prevClose))))
        }
        return out
    }

    // MARK: - 变化率

    /// 变化率 ROC（百分数）：`out[i] = (v[i]/v[i-n] - 1) × 100`，`i < n` 为 `nil`。
    ///
    /// ⚠ 分母为 0 → 该位 `nil`（外部数据里 0 价是脏数据，不制造 `inf`）。
    public static func rocSeries(_ values: [Double], _ period: Int) -> [Double?] {
        guard period >= 1, values.count > period else {
            return Array(repeating: nil, count: values.count)
        }
        var out: [Double?] = Array(repeating: nil, count: values.count)
        for i in period..<values.count {
            let prev = values[i - period]
            guard prev != 0 else { continue }
            out[i] = (values[i] / prev - 1) * 100
        }
        return out
    }

    // MARK: - 序列算术

    /// 逐点相加（任一为 nil → nil；长度不齐按交集对齐到较短者、其余 nil）。
    public static func add(_ a: [Double?], _ b: [Double?]) -> [Double?] {
        combine(a, b, +)
    }

    /// 逐点相减（任一为 nil → nil；长度不齐按交集对齐到较短者、其余 nil）。
    public static func subtract(_ a: [Double?], _ b: [Double?]) -> [Double?] {
        combine(a, b, -)
    }

    private static func combine(_ a: [Double?], _ b: [Double?],
                                _ op: (Double, Double) -> Double) -> [Double?] {
        let head = zip(a, b).map { x, y -> Double? in
            guard let x, let y else { return nil }
            return op(x, y)
        }
        let tailCount = max(a.count, b.count) - head.count
        guard tailCount > 0 else { return head }
        return head + Array(repeating: nil, count: tailCount)
    }

    /// 取序列末值（便捷包装统一用它：空输入 / 末位 nil → nil）。
    public static func last(_ series: [Double?]) -> Double? { series.last ?? nil }
}
