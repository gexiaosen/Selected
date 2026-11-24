import Foundation

/// 筹码分布（CYQ）—— 纯计算，只读日 K 的 OHLCV。
///
/// **为什么需要它**：尾盘策略问的是「次日午前能不能冲高」，而冲高的阻力来自**上方套牢盘**。
/// 引擎已有的 `dist_from_high`（距高点百分比）只回答「离最高点多远」，不回答
/// 「上方有多少筹码在等着解套」—— 一只票可以距高点 30%，但中间筹码早已在低位换手殆尽
/// （上方真空）；也可以距高点只有 3% 却层层套牢。这两个问题的答案完全不同。
///
/// ⚠ **只展示、不参与任何判定**（与 `trend_state` / `lock_confidence` / `data_quality`
/// 同一原则）。本模块**不写入** `deep_info`、**不碰** `ScanRunner`、**不改**任何评分口径。
///
/// ## 算法
///
/// 1. 取窗口内最后 `window` 根 bar，逐根按成交量加权
/// 2. 每根 bar 的成交量按**三角分布**摊到价格网格上，峰在 `(open+close+high+low)/4`
///    （标准 CYQ 用「均价 = 成交额/成交量」当峰，但 `KLineItem` 没有 `amount` 字段 →
///    用 OHLC 均值近似，误差可接受且**确定性**）
/// 3. 统计获利盘比例 / 平均成本 / 90% 成本区间 / 上方筹码占比 / 上方第一道压力位
///
/// ## 两条衰减分支（`ChipStats.decayed` 区分，UI 必须说明用的是哪条）
///
/// · **有流通股本** → 换手衰减：`turn_i = 该日成交量 / 流通股本`，历史筹码被后续换手冲掉
/// · **无流通股本** → 半衰期衰减：`w_i = 0.5^((N-1-i)/halfLifeBars)`
///
/// 两者只决定"每根 bar 的权重"，之后的分布构建与统计**共用同一条代码路径**。
///
/// ⚠ **与东方财富标准 CYQ 的口径差异**：标准实现逐日按**真实换手率**衰减，需要**每一日**的
///   流通股本（增发/解禁会变）。本实现只拿得到"今天的流通股本"，用它回溯整段窗口 → 属近似；
///   `decayed == false` 时连换手都没有，纯按时间半衰期衰减。
///   因为不参与判定，近似可接受 —— 但**不能把近似值当精确值展示**。
public enum ChipDistribution {

    // MARK: - 口径常量（改动等于改口径）

    /// 默认窗口（交易日）。详情页的日 K 首屏有 500 根，够用。
    public static let defaultWindow = 250
    /// 少于这些根就不算（与 `computeDeepInfo` 的 10 根门槛一致 —— 5 根算不出"分布"）
    public static let minBars = 10
    /// 价格网格档数。100 档在 640pt 宽的弹窗里足够平滑，且计算量恒定。
    public static let levels = 100
    /// 无流通股本时的筹码半衰期（交易日）
    public static let halfLifeBars = 60.0
    /// "上方压力位"的定义：自现价向上累计到这么多筹码即视为一道压力
    public static let pressureMass = 0.05
    /// 90% 成本区间的两端各截掉的比例
    public static let tailMass = 0.05

    // MARK: - 计算

    /// 计算筹码分布。
    ///
    /// - Parameters:
    ///   - bars: 日 K，**必须按时间升序**（`KLineService.fetchKLine` 的返回序）
    ///   - currentPrice: 现价。网格范围会扩展到包含它（否则"上方"无从谈起）
    ///   - floatShares: 流通股本（**股**）。`nil` / ≤0 → 走半衰期衰减。
    ///     ⚠ 单位约定：`KLineItem.volume` 是**手**（腾讯 `newfqkline` 口径），
    ///     故内部按 `volume × 100` 折成股再与 `floatShares` 相除。
    ///   - window: 只用最后这么多根 bar
    /// - Returns: 数据不足（< `minBars` 根有效 bar）或全零成交量时返回 `nil`
    public static func compute(_ bars: [KLineItem],
                               currentPrice: Double,
                               floatShares: Double? = nil,
                               window: Int = defaultWindow) -> ChipStats? {
        guard currentPrice > 0, window >= minBars else { return nil }

        // 剔除停牌 / 脏数据 bar：没有成交量就不产生筹码，价格区间反过来还会污染网格
        let used = bars.suffix(window).filter {
            $0.volume > 0 && $0.low > 0 && $0.high >= $0.low
        }
        let n = used.count
        guard n >= minBars else { return nil }

        // ---- 1. 权重（两条衰减分支的唯一差别）----
        var weights = [Double](repeating: 0, count: n)
        var decayed = false
        if let fs = floatShares, fs > 0 {
            decayed = true
            // 经典写法是自旧向新逐日 `chips *= (1 - turn_i)`。等价地，第 i 根 bar
            // 对**今天**筹码的贡献 = `v_i × Π_{j>i}(1 - turn_j)` —— 一次反向遍历即可，
            // 不必真的维护整张筹码表逐日做乘法。
            var remain = 1.0
            for i in stride(from: n - 1, through: 0, by: -1) {
                let shares = used[i].volume * 100                       // 手 → 股
                let turn = min(1.0, shares / fs)                        // 单日换手率，上限 100%
                weights[i] = shares * remain
                remain *= (1 - turn)
            }
        } else {
            for i in 0..<n {
                weights[i] = used[i].volume * pow(0.5, Double(n - 1 - i) / halfLifeBars)
            }
        }
        let wsum = weights.reduce(0, +)
        guard wsum > 0 else { return nil }
        let w = weights.map { $0 / wsum }

        // ---- 2. 价格网格（必须含现价，否则"上方/下方"无意义）----
        var lo = min(used.map(\.low).min() ?? currentPrice, currentPrice)
        let hi = max(used.map(\.high).max() ?? currentPrice, currentPrice)
        // 全程同价（一字板连板）→ 给一个非零 bin，避免除零。
        // ⚠ 只能**向下**扩：退化时 `hi == currentPrice`，向下扩之后所有档位都 ≤ 现价，
        //   「上方无筹码」这个结论才成立。若对称扩，档位会跨到现价之上，
        //   凭空造出一批"上方套牢盘"。
        if hi - lo < max(1e-9, lo * 1e-9) { lo -= max(0.01, lo * 0.001) }
        let bin = (hi - lo) / Double(levels)
        let centers: [Double] = (0..<levels).map { lo + (Double($0) + 0.5) * bin }

        // ---- 3. 三角分布摊筹码 ----
        var chips = [Double](repeating: 0, count: levels)
        for i in 0..<n {
            let b = used[i]
            let span = b.high - b.low
            let peak = min(max((b.open + b.close + b.high + b.low) / 4, b.low), b.high)
            var dens = [Double](repeating: 0, count: levels)
            var dsum = 0.0
            for k in 0..<levels {
                let p = centers[k]
                guard p >= b.low, p <= b.high else { continue }
                let d: Double
                if span < 1e-9 {
                    d = 1
                } else if p <= peak {
                    d = (peak - b.low) < 1e-9 ? 0
                        : 2 * (p - b.low) / (span * (peak - b.low))
                } else {
                    d = (b.high - peak) < 1e-9 ? 0
                        : 2 * (b.high - p) / (span * (b.high - peak))
                }
                if d > 0 { dens[k] = d; dsum += d }
            }
            if dsum <= 0 {
                // bar 区间比一格还窄，或峰落在端点上把两侧都压成 0 → 全量落到离峰最近的一格。
                // ⚠ 必须兜这一手：否则这根 bar 的筹码会**静默消失**，权重总和与 chips 总和不再相等。
                let k = min(levels - 1, max(0, Int(((peak - lo) / bin).rounded(.down))))
                chips[k] += w[i]
            } else {
                for k in 0..<levels where dens[k] > 0 { chips[k] += w[i] * dens[k] / dsum }
            }
        }
        let total = chips.reduce(0, +)
        guard total > 0 else { return nil }

        // ---- 4. 统计 ----
        var profit = 0.0, above = 0.0, weighted = 0.0
        for k in 0..<levels {
            weighted += centers[k] * chips[k]
            if centers[k] <= currentPrice { profit += chips[k] } else { above += chips[k] }
        }

        /// 自低位向上累计到 `target` 筹码处的价格（`chips` 非负 → 单调）
        func priceAtCumulative(_ target: Double) -> Double {
            var acc = 0.0
            for k in 0..<levels {
                acc += chips[k]
                if acc >= target { return centers[k] }
            }
            return centers[levels - 1]
        }

        var pressurePrice: Double?
        var acc = 0.0
        let need = total * pressureMass
        for k in 0..<levels where centers[k] > currentPrice {
            acc += chips[k]
            if acc >= need { pressurePrice = centers[k]; break }
        }

        return ChipStats(
            window: n,
            decayed: decayed,
            profitRatio: profit / total,
            avgCost: weighted / total,
            cost90Low: priceAtCumulative(total * tailMass),
            cost90High: priceAtCumulative(total * (1 - tailMass)),
            aboveMass: above / total,
            pressurePrice: pressurePrice,
            pressureGapPct: pressurePrice.map { ($0 / currentPrice - 1) * 100 })
    }

    /// 估算流通股本（**股**）。
    ///
    /// 两个来源，按可靠性排序：
    /// 1. `换手率` + `成交量`：`流通股本(股) = 成交量(手) × 100 / (换手率% / 100)`
    ///    —— 换手率是数据源直接给的，与成交量同源，故优先
    /// 2. `流通市值` + `现价`：`流通股本 = 流通市值(亿) × 1e8 / 现价` —— 市值口径固定，作为兜底
    ///
    /// 两者都拿不到（停牌 / 数据源缺字段）→ 返回 `nil`，调用方退化为半衰期衰减。
    ///
    /// 验算：流通股本 1 亿股，今日成交 100 手（1 万股）→ 换手率 0.01%。
    /// `100 × 100 / 0.0001 = 1e8` ✓（⚠ 别漏「手→股」那一步，漏了结果小 100 倍）
    public static func estimateFloatShares(turnoverRate: Double?,
                                           volumeInLots: Double?,
                                           circulationMarketCapYi: Double?,
                                           price: Double) -> Double? {
        if let tr = turnoverRate, tr > 0, let v = volumeInLots, v > 0 {
            return v * 100 / (tr / 100)
        }
        if let cap = circulationMarketCapYi, cap > 0, price > 0 {
            return cap * 1e8 / price
        }
        return nil
    }
}

/// 筹码分布的统计结果（`ChipDistribution.compute` 的返回值）
public struct ChipStats: Equatable, Sendable {

    /// 实际参与计算的 bar 数（已剔除零成交量的停牌 bar）
    public let window: Int
    /// `true` = 换手衰减（拿到了流通股本）；`false` = 半衰期衰减
    public let decayed: Bool
    /// 获利盘比例（成本 ≤ 现价的筹码占比），0–1
    public let profitRatio: Double
    /// 成交量加权的平均成本
    public let avgCost: Double
    /// 90% 成本区间下沿（从低位累计到 5% 筹码处的价格）
    public let cost90Low: Double
    /// 90% 成本区间上沿（从低位累计到 95% 筹码处的价格）
    public let cost90High: Double
    /// 上方筹码占比（成本 > 现价的筹码占比），0–1。**越低 = 上方越真空 = 冲高阻力越小**
    public let aboveMass: Double
    /// 上方第一道压力位（自现价向上累计到 `ChipDistribution.pressureMass` 筹码处的价格）；
    /// `nil` = 上方筹码不足，即真空
    public let pressurePrice: Double?
    /// 现价到 `pressurePrice` 的距离（%）；`nil` 同 `pressurePrice`
    public let pressureGapPct: Double?

    public init(window: Int, decayed: Bool, profitRatio: Double, avgCost: Double,
                cost90Low: Double, cost90High: Double, aboveMass: Double,
                pressurePrice: Double?, pressureGapPct: Double?) {
        self.window = window
        self.decayed = decayed
        self.profitRatio = profitRatio
        self.avgCost = avgCost
        self.cost90Low = cost90Low
        self.cost90High = cost90High
        self.aboveMass = aboveMass
        self.pressurePrice = pressurePrice
        self.pressureGapPct = pressureGapPct
    }

    /// 上方真空（没有够分量的压力位）
    public var isAboveVacuum: Bool { pressurePrice == nil }
}
