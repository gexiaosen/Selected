import Foundation

/// 趋势类指标 —— **EMA / MACD / HMA / KAMA**
///
/// ⚠ KST 不实现：其黄金夹具无法由当前口径复现（疑似旧版本夹具生成）；
/// 按"每个指标必须有可复现夹具"的纪律，宁缺毋滥。
///
/// ## 定位与口径纪律（与 `TechnicalIndicators` 同一哲学）
///   · 序列优先：全部返回与输入**等长对齐**的 `[Double?]`（预热位 `nil`），
///     供快照 Job 批量落库与图表画线；标量便捷包装 `lastXxx` 只取末值。
///   · 平滑种子/起点口径以 `Fixtures/indicator_golden/trend/` 黄金 CSV 为准
///     （clean-room：公式按公开定义独立实现，夹具只做数值校验，见下载脚本头注）。
///   · 不取整；样本不足 / 分母为 0 → `nil`，不返回 0。
///   · **只展示、不进评分**：方向未经本项目标定，接入选股评分体系前须走参数中心流程。
public enum TrendIndicators {

    // MARK: - 输出结构

    /// MACD 三件套（线 / 信号线 / 柱）。三条序列等长对齐，位位同生同灭。
    public struct MacdSeries: Sendable {
        public let line: [Double?]
        public let signal: [Double?]
        public let histogram: [Double?]
    }

    // MARK: - EMA

    /// EMA 序列（收盘价）。种子口径见 `IndicatorPrimitives.emaSeries`（夹具锁定 = 前 n 项 SMA）。
    public static func ema<B: Sequence>(_ bars: B, period: Int = 20) -> [Double?]
    where B.Element: OHLCBar {
        IndicatorPrimitives.emaSeries(IndicatorPrimitives.closes(bars), period)
    }

    /// 末值便捷包装。
    public static func lastEma<B: Sequence>(_ bars: B, period: Int = 20) -> Double?
    where B.Element: OHLCBar {
        IndicatorPrimitives.last(ema(bars, period: period))
    }

    // MARK: - MACD

    /// MACD —— `线 = EMA(fast) − EMA(slow)`，`信号 = EMA(线, signal)`，`柱 = 线 − 信号`。
    ///
    /// ⚠ 默认 (12, 26, 9)；夹具 `macd.csv` 按此口径核过（含 EMA 种子=SMA 的传导）。
    /// ⚠ 预热位对齐规则：fast/slow 任一 `nil` → 该位 `nil`；信号线在有值段上递推。
    public static func macd<B: Sequence>(_ bars: B, fast: Int = 12, slow: Int = 26, signal: Int = 9)
        -> MacdSeries where B.Element: OHLCBar {
        let closes = IndicatorPrimitives.closes(bars)
        let line = IndicatorPrimitives.subtract(
            IndicatorPrimitives.emaSeries(closes, fast),
            IndicatorPrimitives.emaSeries(closes, slow))
        let sig = IndicatorPrimitives.emaSeries(line, signal)
        return MacdSeries(line: line, signal: sig,
                          histogram: IndicatorPrimitives.subtract(line, sig))
    }

    // MARK: - HMA

    /// Hull MA —— `WMA( 2·WMA(round(n/2)) − WMA(n), round(√n) )`。
    ///
    /// ⚠ `n/2` 与 `√n` 都**四舍五入**（夹具口径：`hma.csv` 用 period=3，
    ///   half=round(1.5)=2；手算核对过首个有效行）。
    /// ⚠ 中间项 `2·WMA(half) − WMA(n)` 允许为负口径参与后续 WMA（价格序列上实际为正）。
    public static func hma<B: Sequence>(_ bars: B, period: Int = 20) -> [Double?]
    where B.Element: OHLCBar {
        let closes = IndicatorPrimitives.closes(bars)
        let half = max(1, Int((Double(period) / 2).rounded(.awayFromZero)))
        let root = max(1, Int(Double(period).squareRoot().rounded(.awayFromZero)))
        let wmaHalf = IndicatorPrimitives.wmaSeries(closes, half)
        let wmaFull = IndicatorPrimitives.wmaSeries(closes, period)
        var raw: [Double?] = Array(repeating: nil, count: closes.count)
        for i in 0..<closes.count {
            if let a = wmaHalf[i], let b = wmaFull[i] {
                raw[i] = 2 * a - b
            }
        }
        // 对带 nil 的序列做 WMA：只吃有值段（前段 nil 不影响，窗口滑到全有值才出数）
        return wmaSeriesSkippingNil(raw, root)
    }

    /// `WMA` 的 nil 容忍版：窗口内出现 nil → 该位 nil（等价于"等窗口填满有值段"）。
    private static func wmaSeriesSkippingNil(_ values: [Double?], _ period: Int) -> [Double?] {
        guard period >= 1, values.count >= period else {
            return Array(repeating: nil, count: values.count)
        }
        let denom = Double(period * (period + 1) / 2)
        var out: [Double?] = Array(repeating: nil, count: values.count)
        for i in (period - 1)..<values.count {
            var acc = 0.0
            var ok = true
            for k in 0..<period {
                guard let v = values[i - period + 1 + k] else { ok = false; break }
                acc += Double(k + 1) * v
            }
            if ok { out[i] = acc / denom }
        }
        return out
    }

    // MARK: - KAMA

    /// Kaufman 自适应 MA —— ER 越界波动越小、平滑越快。
    ///
    /// ```
    /// ER = |C − C[er]| / Σ|C[j] − C[j−1]|（er 窗口）
    /// sc = (ER·(2/(fast+1) − 2/(slow+1)) + 2/(slow+1))²
    /// KAMA = 前值 + sc·(C − 前值)；种子 = C[er]（索引 er 处）
    /// ```
    /// ⚠ 种子口径以 `kama.csv` 为准（首个非 0 行 = 索引 erPeriod 的收盘价）。
    public static func kama<B: Sequence>(_ bars: B, erPeriod: Int = 10,
                                         fast: Int = 2, slow: Int = 30) -> [Double?]
    where B.Element: OHLCBar {
        let closes = IndicatorPrimitives.closes(bars)
        guard erPeriod >= 1, fast >= 1, slow > fast, closes.count >= erPeriod else {
            return Array(repeating: nil, count: closes.count)
        }
        let fastCoefficient = 2.0 / Double(fast + 1)
        let slowCoefficient = 2.0 / Double(slow + 1)
        var out: [Double?] = Array(repeating: nil, count: closes.count)
        // ⚠ 种子在索引 erPeriod−1（夹具口径：kama.csv 首个有效值 = 第 er 根收盘，
        //   从 want[10] 起全段吻合）
        var prev = closes[erPeriod - 1]
        out[erPeriod - 1] = prev
        for i in erPeriod..<closes.count {
            let change = abs(closes[i] - closes[i - erPeriod])
            var volatility = 0.0
            for j in (i - erPeriod + 1)...i {
                volatility += abs(closes[j] - closes[j - 1])
            }
            let er = volatility > 0 ? change / volatility : 0
            let sc = pow(er * (fastCoefficient - slowCoefficient) + slowCoefficient, 2)
            prev = prev + sc * (closes[i] - prev)
            out[i] = prev
        }
        return out
    }

}
