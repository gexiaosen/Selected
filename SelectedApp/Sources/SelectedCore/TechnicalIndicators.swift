import Foundation

/// 技术指标四件套 —— **ATR / OBV / MFI / BIAS**。
///
/// ## 为什么只有这四个
/// 上游参考实现有 32 个指标，但**明确不建议全量移植**：
/// ① `SelectedCore` 只许 `Foundation` / `SQLite3`（talib 是 C 库 + pandas 封装，`CoreLayeringTests` 钉死）；
/// ② 口径风险 —— 上游自己承认"调整个别公式确保与同花顺/通达信一致"，
///    也就是**它的口径是特调的**，混进来会让"哪一层算错了"难以定位；
/// ③ 32 个里对"**次日午前**"这个尺度有解释力的只有少数几个。
///
/// ## ⚠ 这四个与既有量的关系（**都核过公式，不是"名字像"**）
///
/// | 指标 | 既有近似物 | 差在哪 |
/// |------|-----------|--------|
/// | **ATR** | `ForecastEngine` 的"近期平均**振幅**" | 振幅 = `(H-L)/昨收`；ATR 的 TR = `max(H-L, \|H-昨收\|, \|L-昨收\|)` → **差在跳空日**（跳空时 TR 明显大于振幅，与次日区间估计天然互补） |
/// | **BIAS** | `DeepInfo.ma_deviation` | 那个是 `abs(MA5-MA10)/MA10`（**均线之间**的乖离）；BIAS 是 `(close-MA_n)/MA_n`（**收盘对均线**的乖离）。名字都带"乖离"，**不是同一个量** |
/// | OBV / MFI | 无 | 真缺口 |
///
/// ## ⚠ 只展示、不进评分
/// 与 K 线形态 / 量能判据同一理由：**方向尚未标定**（本项目没有它们的历史样本）。
/// ⚠ 尤其 **MFI 的传统 80/20 区间**：上游明确**否决**过"固定阈值买卖信号"
/// （"这类固定阈值信号与 Selected 的评分体系是两套哲学"）→ 界面只给数值，
/// 80/20 只作**灰字参考线**并注明"传统口径，不是本项目的判据"。
///
/// ## ⚠ 返回值一律**不取整**
/// 取整是展示层的事（`StockFmt.num`）。这里保留原始精度，免得"先取整再算比值"引入误差。
/// **样本不足 / 算不出来 → `nil`**，不返回 0 —— "算不出来"与"值是 0"在界面上是两件事。
public enum TechnicalIndicators {

    // MARK: - ATR（真实波幅均值）

    /// 真实波幅（TR）序列。
    ///
    /// `TR = max(H-L, |H-昨收|, |L-昨收|)`
    ///
    /// ⚠ **首根的 TR 取 `H-L`** —— 它没有前收可比较。这是通行做法；
    /// 若强行用"第二根起"会让 ATR 的样本窗口少一根（而 ATR 的种子正好吃前 n 根）。
    /// ⚠ 与"振幅"的区别就在后两项：**跳空日** `|H-昨收|` / `|L-昨收|` 会大于 `H-L`，
    /// 而振幅只看当日区间 → 跳空越多，两个数差越大。
    public static func trueRanges<B: Sequence>(_ bars: B) -> [Double]
    where B.Element: OHLCBar {
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

    /// ATR —— **Wilder 平滑**（教科书口径）。
    ///
    /// ```
    /// 种子：ATR_n = mean(TR_1 … TR_n)
    /// 之后：ATR_t = (ATR_{t-1} × (n-1) + TR_t) / n
    /// ```
    ///
    /// ⚠ **不是 TR 的简单均值**：两者数值不同，而"ATR"这个名字默认指 Wilder 口径。
    /// ⚠ 递归依赖**全序列**（种子在开头）→ 传进来的 `bars` 要足够长（见 `atrPercent` 的调用方）。
    public static func atr<B: Sequence>(_ bars: B, period: Int = 14) -> Double?
    where B.Element: OHLCBar {
        let tr = trueRanges(bars)
        guard period >= 1, tr.count >= period else { return nil }
        var value = PyMath.sum(tr[0..<period]) / Double(period)
        if tr.count > period {
            for i in period..<tr.count {
                value = (value * Double(period - 1) + tr[i]) / Double(period)
            }
        }
        return value
    }

    /// ATR ÷ 收盘价 × 100（%）—— **跨股票可比的那个数**。
    ///
    /// 茅台 ATR 十几元、银行股几毛钱，绝对值没法横向比；百分比才说明"这只票一天动多少"。
    public static func atrPercent<B: Sequence>(_ bars: B, period: Int = 14) -> Double?
    where B.Element: OHLCBar {
        let bars = Array(bars)
        guard let a = atr(bars, period: period) else { return nil }
        let close = bars[bars.count - 1].close
        guard close > 0 else { return nil }
        return a / close * 100
    }

    // MARK: - OBV（能量潮）

    /// OBV 累计序列（首根为 0）。
    ///
    /// `收 > 昨收 → +量`；`收 < 昨收 → -量`；`收 == 昨收 → 不变`。
    ///
    /// ⚠ **OBV 的绝对值没有意义** —— 它取决于从哪一天开始累计。
    /// 界面**不要**显示这个数，用 `obvChange(_:window:)`（变化量）或它的方向。
    /// ⚠ `volume` 为 0 的日子**照常累计**（等价于不变）：跳过它们会改变"累计"的语义，
    /// 而停牌日的 0 本身就是事实。
    public static func obvSeries<B: Sequence>(_ bars: B) -> [Double]
    where B.Element: VolumeBar {
        let bars = Array(bars)
        guard !bars.isEmpty else { return [] }
        var out: [Double] = [0]
        out.reserveCapacity(bars.count)
        for i in 1..<bars.count {
            let d = bars[i].close - bars[i - 1].close
            let prev = out[i - 1]
            if d > 0 { out.append(prev + bars[i].volume) }
            else if d < 0 { out.append(prev - bars[i].volume) }
            else { out.append(prev) }
        }
        return out
    }

    /// OBV 的 **N 日变化量**（末根 − 前 N 根）—— 这才是可展示的量。
    ///
    /// 单位是**手**（与 `volume` 同单位）；它的**符号**说明"这段时间资金在进还是在出"。
    public static func obvChange<B: Sequence>(_ bars: B, window: Int = 20) -> Double?
    where B.Element: VolumeBar {
        let s = obvSeries(bars)
        guard window >= 1, s.count >= window + 1 else { return nil }
        return s[s.count - 1] - s[s.count - 1 - window]
    }

    // MARK: - MFI（资金流量指标，带量的 RSI）

    /// MFI。
    ///
    /// ```
    /// TP  = (H + L + C) / 3
    /// RMF = TP × volume
    /// TP 高于前一根 → 计入正资金流 PMF；低于 → 计入负资金流 NMF
    /// MFI = 100 − 100 / (1 + PMF / NMF)
    /// ```
    ///
    /// ⚠ **三个除零/退化边界都要显式处理**（否则会产出 `nan` / `inf` 混进界面）：
    /// - `NMF == 0`（期间只有正流）→ **100**
    /// - `PMF == 0`（期间只有负流）→ **0**
    /// - **两者都为 0**（连续无成交 / `TP` 完全不变）→ **`nil`**（"算不出来"，不是 0 也不是 100）
    public static func mfi<B: Sequence>(_ bars: B, period: Int = 14) -> Double?
    where B.Element: VolumeBar {
        let bars = Array(bars)
        guard period >= 1, bars.count >= period + 1 else { return nil }
        var pmf = 0.0
        var nmf = 0.0
        for i in (bars.count - period)..<bars.count {
            let tp = typicalPrice(bars[i])
            let prevTp = typicalPrice(bars[i - 1])
            let rmf = tp * bars[i].volume
            if tp > prevTp { pmf += rmf } else if tp < prevTp { nmf += rmf }
        }
        if pmf == 0 && nmf == 0 { return nil }
        if nmf == 0 { return 100 }
        if pmf == 0 { return 0 }
        return 100 - 100 / (1 + pmf / nmf)
    }

    /// 典型价 `(H + L + C) / 3`（MFI 用）
    public static func typicalPrice(_ bar: some OHLCBar) -> Double {
        (bar.high + bar.low + bar.close) / 3
    }

    // MARK: - BIAS（乖离率）

    /// 乖离率 `(收盘 − MA_n) / MA_n × 100`（%）。
    ///
    /// ⚠ 与 `EngineIndicators.maDeviation`（`abs(MA5−MA10)/MA10`）**不是同一个量** ——
    /// 那个量的是"两条均线之间"，这个量的是"收盘对均线"。见文件头。
    /// ⚠ `MA_n <= 0` → `nil`（不产出 `inf`）。均线用 `EngineIndicators.sma`（与引擎同口径）。
    public static func bias<B: Sequence>(_ bars: B, period: Int = 6) -> Double?
    where B.Element: OHLCBar {
        let bars = Array(bars)
        guard period >= 1, bars.count >= period else { return nil }
        let closes = bars.map(\.close)
        guard let ma = EngineIndicators.sma(closes, period), ma > 0 else { return nil }
        let close = bars[bars.count - 1].close
        return (close - ma) / ma * 100
    }

    /// 三个常用周期的 BIAS（通达信默认组 6 / 12 / 24）。缺失的周期折成 `nil`。
    public static func biasSet<B: Sequence>(_ bars: B,
                                            periods: [Int] = [6, 12, 24]) -> [Int: Double]
    where B.Element: OHLCBar {
        var out: [Int: Double] = [:]
        for p in periods {
            if let v = bias(bars, period: p) { out[p] = v }
        }
        return out
    }

    // MARK: - 打包（界面一次取齐）

    /// 四个指标的展示值。**任何一项算不出来都是 `nil`**（不回落成 0）。
    public struct Snapshot: Equatable, Sendable {
        public let atr: Double?
        public let atrPercent: Double?
        public let obvChange: Double?
        public let mfi: Double?
        /// `period → BIAS%`（默认 6 / 12 / 24）
        public let bias: [Int: Double]
        /// 计算用的 K 线根数
        public let barsUsed: Int
    }

    /// 一次算齐（界面用）。`atrPeriod` / `mfiPeriod` / `obvWindow` / `biasPeriods` 可调。
    public static func snapshot<B: Sequence>(_ bars: B, atrPeriod: Int = 14, obvWindow: Int = 20,
                                             mfiPeriod: Int = 14,
                                             biasPeriods: [Int] = [6, 12, 24]) -> Snapshot
    where B.Element: VolumeBar {
        let bars = Array(bars)
        return Snapshot(atr: atr(bars, period: atrPeriod),
                 atrPercent: atrPercent(bars, period: atrPeriod),
                 obvChange: obvChange(bars, window: obvWindow),
                 mfi: mfi(bars, period: mfiPeriod),
                 bias: biasSet(bars, periods: biasPeriods),
                 barsUsed: bars.count)
    }
}
