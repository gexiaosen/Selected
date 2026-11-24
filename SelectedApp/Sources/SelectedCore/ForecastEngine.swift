import Foundation

/// Selected 引擎 — 次日高低点区间估计（基线 + 近期波动状态 + 自带回测）
///
/// ⚠ 定位与边界：这是**统计区间估计**，不是确定性预测，更不构成买卖建议。
/// 单日最高/最低主要由大盘走势与突发消息决定；个股自身的历史波动分布只能回答
/// 「它平时一天大概波动多大」。因此输出一律是**区间 + 历史命中率 + 误差量级**。
///
/// 方法（三步，全部只用历史数据，无未来函数）：
///   1) 基线：每日「高/低相对**前收**的偏离」做成分布取分位数（用前收做锚，
///      因为开盘价本身也是待预测量）
///   2) 近期状态：近期平均振幅 ÷ 基线平均振幅 = 波动倍数 k，钳在 [0.6, 2.0]
///   3) 次日区间 = 前收 × (1 + 基线分位数 × k)
///   4) 自带逐日滚动回测（walk-forward）：预测第 t 日只用 `bars[0..<t]`，统计命中率
public enum ForecastEngine {

    public static let kMin = 0.6, kMax = 2.0

    public static let caveats = [
        "区间来自该股自身历史波动分布，属统计估计，不是确定性预测，也不构成买卖建议",
        "大盘剧烈波动、突发消息、涨跌停一字板时区间会失效",
        "回测为逐日滚动、无未来函数；但模型参数是在同一段历史上选定的，且只覆盖最近样本 → 命中率仍偏乐观（见 backtest.n）",
    ]

    /// 线性插值分位数（q 取 0~1）
    public static func quantile(_ values: [Double], _ q: Double) -> Double? {
        if values.isEmpty { return nil }
        let xs = values.sorted()
        if xs.count == 1 { return xs[0] }
        let pos = q * Double(xs.count - 1)
        let lo = Int(pos)                          // 向零截断
        let hi = min(lo + 1, xs.count - 1)
        let frac = pos - Double(lo)
        return xs[lo] + (xs[hi] - xs[lo]) * frac
    }

    /// 每个交易日「高/低相对前收」的偏离（%）样本：(highPct, lowPct, rangePct, chgPct)
    public static func deviationSamples(_ bars: [KLineBar]) -> [(Double, Double, Double, Double)] {
        var out: [(Double, Double, Double, Double)] = []
        if bars.count < 2 { return out }
        for i in 1..<bars.count {
            let prev = bars[i - 1].close
            if prev <= 0 { continue }
            let h = bars[i].high, l = bars[i].low, c = bars[i].close
            out.append(((h - prev) / prev * 100, (l - prev) / prev * 100,
                        (h - l) / prev * 100, (c - prev) / prev * 100))
        }
        return out
    }

    public struct Baseline {
        public var days = 0
        public var avgRangePct = 0.0
        public var highPct: (p25: Double, p50: Double, p75: Double) = (0, 0, 0)
        public var lowPct: (p25: Double, p50: Double, p75: Double) = (0, 0, 0)
        public var closeUpRatio = 0.0
        public var maxRangePct = 0.0

        public var json: [String: Any] {
            ["days": days, "avg_range_pct": avgRangePct, "atr_pct": avgRangePct,
             "high_pct": ["p25": highPct.p25, "p50": highPct.p50, "p75": highPct.p75],
             "low_pct": ["p25": lowPct.p25, "p50": lowPct.p50, "p75": lowPct.p75],
             "close_up_ratio": closeUpRatio, "max_range_pct": maxRangePct]
        }
    }

    /// 基线波动结构（用 bars 的**最后 baseDays 个交易日**）
    public static func baseline(_ bars: [KLineBar], baseDays: Int = 30) -> Baseline? {
        if bars.count < baseDays + 1 { return nil }
        let window = Array(bars.suffix(baseDays + 1))
        let dev = deviationSamples(window)
        if dev.count < max(5, baseDays / 3) { return nil }
        let highs = dev.map { $0.0 }
        let lows = dev.map { $0.1 }
        let ranges = dev.map { $0.2 }
        let ups = dev.filter { $0.3 > 0 }.count

        func q(_ vals: [Double], _ p: Double) -> Double { PyMath.round(quantile(vals, p) ?? 0, 2) }
        var b = Baseline()
        b.days = dev.count
        b.avgRangePct = PyMath.round(PyMath.sum(ranges) / Double(ranges.count), 2)
        b.highPct = (q(highs, 0.25), q(highs, 0.50), q(highs, 0.75))
        b.lowPct = (q(lows, 0.25), q(lows, 0.50), q(lows, 0.75))
        b.closeUpRatio = PyMath.round(Double(ups) / Double(dev.count), 3)
        b.maxRangePct = PyMath.round(ranges.max() ?? 0, 2)
        return b
    }

    public struct RecentState {
        /// 输出形态 —— 与 `recentState` 的**两条 return 分支**一一对应。
        ///
        /// ⚠ 为什么要显式建模：两条分支**键集不同**（早退分支只 3 键、正常分支不带 `note`）。
        ///   若不分形状、恒输出全部键（未设置的写 `null`），按键集消费的下游
        ///   会把"键在、值 null"误当"有值"。
        public enum Shape: Sendable {
            /// 正常：7 键（`days` / `avg_range_pct` / `k_raw` / `k` / `k_clamped` / `streak` / `vol_mult`）
            case normal
            /// 近期无样本：**只 3 键**（`days` / `k` / `note`）
            case noSamples
        }

        public var shape: Shape = .normal
        public var days = 0
        public var k = 1.0
        public var note: String?
        public var avgRangePct: Double?
        public var kRaw: Double?
        public var kClamped: Bool?
        public var streak: Int?
        public var volMult: Double?

        /// `recentState` 两条分支的输出形态 —— **键集必须逐键一致**
        public var json: [String: Any] {
            var d: [String: Any] = ["days": days, "k": k]
            switch shape {
            case .noSamples:
                // 早退分支：只 3 键（`days` / `k` / `note`）
                if let note { d["note"] = note }
            case .normal:
                // 正常分支：下面 4 个恒有
                if let avgRangePct { d["avg_range_pct"] = avgRangePct }
                if let kRaw { d["k_raw"] = kRaw }
                if let kClamped { d["k_clamped"] = kClamped }
                if let streak { d["streak"] = streak }
                // ⚠ `vol_mult` 在正常分支里**总是设**（`base_vol` 为 0 时是 `null`）
                //   → 必须显式给 `null`，不能省略键
                d["vol_mult"] = volMult.map { $0 as Any } ?? NSNull()
            }
            return d
        }
    }

    /// 近期状态：波动倍数 k、趋势、量能
    public static func recentState(_ bars: [KLineBar], _ base: Baseline, recentDays: Int = 3) -> RecentState {
        let dev = deviationSamples(Array(bars.suffix(recentDays + 1)))
        if dev.isEmpty {
            var s = RecentState()
            s.shape = .noSamples
            s.note = "近期无样本，按基线原样输出"
            return s
        }
        let recentAvg = PyMath.sum(dev.map { $0.2 }) / Double(dev.count)
        let baseAvg = base.avgRangePct != 0 ? base.avgRangePct : 1e-9
        let rawK = recentAvg / baseAvg
        let k = min(kMax, max(kMin, rawK))

        let closes = Array(bars.suffix(recentDays + 1)).map(\.close)
        var streak = 0
        if closes.count >= 2 {
            for i in stride(from: closes.count - 1, through: 1, by: -1) {
                let up = closes[i] > closes[i - 1]
                if i == closes.count - 1 {
                    streak = up ? 1 : -1
                } else if (up && streak > 0) || (!up && streak < 0) {
                    streak += streak > 0 ? 1 : -1
                } else {
                    break
                }
            }
        }

        let vols = bars.map(\.volume)
        let recentSlice = Array(vols.suffix(recentDays))
        let recentVol = PyMath.sum(recentSlice) / Double(max(1, recentSlice.count))
        // ⚠ 基准窗必须**整段排除近期窗**（2026-10-16 审查 B5-15）：
        //   原先写作 `vols.suffix(base.days + 1).dropLast()` ⇒ 基准只往回挪一根，
        //   与 `recentSlice`（含末根）仍重叠 `recentDays - 1` 根 ——
        //   "近 3 日均量 ÷ 基准均量"里两边共用两根，比值被拉向 1.0，
        //   放量/缩量信号随之变钝。与项目里既有的"去今日"口径
        //   （`EngineIndicators.volMult5d`）也不再一致。
        let baseSlice = Array(vols.dropLast(recentSlice.count).suffix(base.days))
        let baseVol = PyMath.sum(baseSlice) / Double(max(1, baseSlice.count))


        var s = RecentState()
        s.days = dev.count
        s.avgRangePct = PyMath.round(recentAvg, 2)
        s.kRaw = PyMath.round(rawK, 2)
        s.k = PyMath.round(k, 2)
        s.kClamped = abs(rawK - k) > 1e-9
        s.streak = streak
        s.volMult = baseVol > 0 ? PyMath.round(recentVol / baseVol, 2) : nil
        return s
    }

    public struct Prediction {
        public var baseClose = 0.0
        public var highCentral = 0.0
        public var highOptimistic = 0.0
        public var lowCentral = 0.0
        public var lowOptimistic = 0.0
        public var expectedRangePct = 0.0
        public var baseline: Baseline
        public var recent: RecentState

        public var json: [String: Any] {
            ["base_close": baseClose, "high_central": highCentral,
             "high_optimistic": highOptimistic, "low_central": lowCentral,
             "low_optimistic": lowOptimistic, "expected_range_pct": expectedRangePct,
             "baseline": baseline.json, "recent": recent.json]
        }
    }

    /// **只用 barsHist**（严格不含未来）给出次日区间。锚点 = 末根收盘。
    public static func predictFrom(_ barsHist: [KLineBar], baseDays: Int = 30,
                            recentDays: Int = 3) -> Prediction? {
        guard let base = baseline(barsHist, baseDays: baseDays) else { return nil }
        let st = recentState(barsHist, base, recentDays: recentDays)
        let c = barsHist[barsHist.count - 1].close
        guard c.isFinite, c > 0 else { return nil }
        let k = st.k
        func px(_ pct: Double) -> Double { PyMath.round(c * (1 + pct * k / 100), 2) }

        var p = Prediction(baseline: base, recent: st)
        p.baseClose = PyMath.round(c, 2)
        p.highCentral = px(base.highPct.p50)
        p.highOptimistic = px(base.highPct.p75)
        p.lowCentral = px(base.lowPct.p50)
        p.lowOptimistic = px(base.lowPct.p25)
        p.expectedRangePct = PyMath.round((p.highCentral - p.lowCentral) / c * 100, 2)
        return p
    }

    public struct BacktestResult {
        public var n = 0
        public var note: String?
        public var highWithinUpper: Double?
        public var lowAboveLower: Double?
        public var bothCovered: Double?
        public var highInBand: Double?
        public var lowInBand: Double?
        public var highMedianErrPct: Double?
        public var lowMedianErrPct: Double?

        /// 两条 return 分支的**键集必须逐键一致**：
        /// · 正常 → 8 键（`n` + 7 个统计量，**不带** `note`）
        /// · 历史长度不足 → 只 2 键（`n` + `note`）
        public var json: [String: Any] {
            var d: [String: Any] = ["n": n]
            if let note { d["note"] = note }
            if let highWithinUpper { d["high_within_upper"] = highWithinUpper }
            if let lowAboveLower { d["low_above_lower"] = lowAboveLower }
            if let bothCovered { d["both_covered"] = bothCovered }
            if let highInBand { d["high_in_band"] = highInBand }
            if let lowInBand { d["low_in_band"] = lowInBand }
            if let highMedianErrPct { d["high_median_err_pct"] = highMedianErrPct }
            if let lowMedianErrPct { d["low_median_err_pct"] = lowMedianErrPct }
            return d
        }
    }

    /// 逐日滚动回测（walk-forward）：逐日用**当时可见**的历史预测当日区间，与实际高低点比对。
    /// 严格无未来函数：预测第 t 天时只用 `bars[0..<t]`。
    ///
    /// ⚠ **术语澄清**：本函数**不是**"样本内回测" —— 它逐日滚动、
    ///   每天都只用之前的数据，命中率本身没有未来函数。真正让它偏乐观的是另外两件事：
    ///   ① **模型形式与参数**（`baseDays` / 分位数档位 / k 钳位区间）是在同一段历史上
    ///      人工选定的（选择偏差）；
    ///   ② 测试窗口只有最后 `testDays` 天，市场状态单一。
    ///   所以 `caveats` 文案说"命中率仍偏乐观"，不说"样本内"。
    public static func backtest(_ bars: [KLineBar], baseDays: Int = 30, recentDays: Int = 3,
                         testDays: Int = 30) -> BacktestResult {
        var r = BacktestResult()
        var hiCapped = 0, loFloored = 0, both = 0, strictHi = 0, strictLo = 0
        var hiErr: [Double] = [], loErr: [Double] = []
        let start = max(baseDays + 1, bars.count - testDays)
        if start < bars.count {
            for t in start..<bars.count {
                guard let pred = predictFrom(Array(bars[0..<t]), baseDays: baseDays,
                                             recentDays: recentDays) else { continue }
                let h = bars[t].high, l = bars[t].low
                r.n += 1
                if h <= pred.highOptimistic { hiCapped += 1 }
                if l >= pred.lowOptimistic { loFloored += 1 }
                if pred.highCentral <= h && h <= pred.highOptimistic { strictHi += 1 }
                if pred.lowOptimistic <= l && l <= pred.lowCentral { strictLo += 1 }
                if h <= pred.highOptimistic && l >= pred.lowOptimistic { both += 1 }
                if pred.baseClose > 0 {
                    hiErr.append(abs(h - pred.highCentral) / pred.baseClose * 100)
                    loErr.append(abs(l - pred.lowCentral) / pred.baseClose * 100)
                }
            }
        }
        if r.n == 0 {
            r.note = "历史长度不足，无法回测"
            return r
        }
        let n = Double(r.n)
        r.highWithinUpper = PyMath.round(Double(hiCapped) / n, 3)
        r.lowAboveLower = PyMath.round(Double(loFloored) / n, 3)
        r.bothCovered = PyMath.round(Double(both) / n, 3)
        r.highInBand = PyMath.round(Double(strictHi) / n, 3)
        r.lowInBand = PyMath.round(Double(strictLo) / n, 3)
        // ⚠ 中位数统一走 `medianOf`（2026-10-16 审查 B5-15）：原先是 `sorted()[n/2]`，
        //   偶数样本时取的是**上侧那一个**而不是中间两值平均 —— 与同项目
        //   `ZtSentiment` 的中位数定义不同，于是"一个 App 两手中位数"。
        //   （偶数样本本函数里是常态：回测天数按窗口滑动，偶偶数都有。）
        r.highMedianErrPct = PyMath.round(medianOf(hiErr), 2)
        r.lowMedianErrPct = PyMath.round(medianOf(loErr), 2)
        return r
    }

    /// 中位数：奇数取正中，偶数取中间两值平均（与 `ZtSentiment` 同一口径）。
    static func medianOf(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        let mid = s.count / 2
        if s.count % 2 == 1 { return s[mid] }
        return (s[mid - 1] + s[mid]) / 2
    }


    /// 对外主入口：基线 + 近期状态 + 次日区间 + 回测
    public static func forecast(code: String, name: String = "", bars: [KLineBar],
                         baseDays: Int = 30, recentDays: Int = 3, testDays: Int = 30,
                         adjusted: Bool = true) -> [String: Any] {
        var result: [String: Any] = [
            "code": code, "name": name, "adjusted": adjusted,
            "params": ["base_days": baseDays, "recent_days": recentDays, "test_days": testDays],
            "caveats": caveats,
        ]
        if bars.count < baseDays + 2 {
            result["status"] = "insufficient_data"
            result["data_error"] = "日K不足：仅 \(bars.count) 根，至少需要 \(baseDays + 2) 根"
                + "（基线 \(baseDays) + 2）"
            return result
        }
        guard let pred = predictFrom(bars, baseDays: baseDays, recentDays: recentDays) else {
            result["status"] = "insufficient_data"
            result["data_error"] = "有效样本不足，无法建立基线"
            return result
        }
        result["status"] = "ok"
        result["as_of"] = bars[bars.count - 1].day
        for (k, v) in pred.json { result[k] = v }
        result["backtest"] = backtest(bars, baseDays: baseDays, recentDays: recentDays,
                                      testDays: testDays).json

        // 涨跌停提示：极端日之后区间参考意义下降
        let hist = deviationSamples(bars)
        if let last = hist.last {
            if last.3 >= 9.7 {
                result["warnings"] = ["最近一个交易日接近涨停：次日若一字板，区间不适用"]
            } else if last.3 <= -9.7 {
                result["warnings"] = ["最近一个交易日接近跌停：次日若一字板，区间不适用"]
            }
        }
        return result
    }
}
