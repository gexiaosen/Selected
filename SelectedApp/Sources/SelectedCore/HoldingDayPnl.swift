import Foundation

/// 一只持仓的输入（成本/股数 + 可选实时价与昨收）。
///
/// ⚠ 价格用 `Double?` 而不是 0：缺行情与"真的 0 元"必须区分，
///   否则停牌/缺价的票会被当成跌停计入当日盈亏。
public struct HoldingPositionInput: Equatable, Sendable {
    public let code: String
    public let name: String
    public let costPrice: Double
    public let shares: Double
    public let price: Double?
    public let previousClose: Double?

    public init(code: String, name: String, costPrice: Double, shares: Double,
                price: Double?, previousClose: Double?) {
        self.code = code
        self.name = name
        self.costPrice = costPrice
        self.shares = shares
        self.price = price
        self.previousClose = previousClose
    }
}

/// 持仓当日盈亏汇总（纯计算，不碰库/网络）。
///
/// 口径：
/// · 当日盈亏 = `(现价 − 昨收) × 股数`（券商"当日浮动盈亏"，**不含已实现盈亏/分红**）
/// · 当日盈亏率 = 当日盈亏 ÷ **昨收市值**（= Σ 昨收 × 股数，仅计有昨收的票）
///   券商"当日收益率"口径：基数是**昨收盘时的持仓价值**，不是成本 —— 成本是"买入时"的价值，
///   拿它当分母等于把持仓以来的全部涨跌摊进"今天"，日内涨跌幅会被严重稀释。
/// · 总盈亏 = `(现价 − 成本) × 股数`
/// · 缺行情 → 计入 `missingCount`，不参与任何金额；缺昨收 → 当日盈亏为 nil，但总盈亏照算
public struct HoldingDayPnl: Equatable, Sendable {

    public struct Line: Identifiable, Equatable, Sendable {
        public let code: String
        public let name: String
        public let shares: Double
        public let costPrice: Double
        public let price: Double
        public let previousClose: Double?
        public let marketValue: Double
        public let totalPnl: Double
        public let totalPnlPct: Double
        /// `nil` = 昨收缺失/为 0，无法算当日盈亏
        public let dayPnl: Double?
        public let dayPct: Double?

        public var id: String { code }

        public init(code: String, name: String, shares: Double, costPrice: Double,
                    price: Double, previousClose: Double?, marketValue: Double,
                    totalPnl: Double, totalPnlPct: Double,
                    dayPnl: Double?, dayPct: Double?) {
            self.code = code
            self.name = name
            self.shares = shares
            self.costPrice = costPrice
            self.price = price
            self.previousClose = previousClose
            self.marketValue = marketValue
            self.totalPnl = totalPnl
            self.totalPnlPct = totalPnlPct
            self.dayPnl = dayPnl
            self.dayPct = dayPct
        }
    }

    /// 有行情的持仓，按当日盈亏**降序**（nil 排最后；UI 的贡献榜用 `topMovers`）
    public let lines: [Line]
    /// 没有行情的持仓只数（停牌/源缺失/未轮询到）
    public let missingCount: Int
    /// 有行情但昨收缺失的只数（当日盈亏无法计入，总盈亏仍计）
    public let missingPrevCloseCount: Int

    public let totalCost: Double
    public let totalValue: Double
    public let totalPnl: Double
    public let totalPnlPct: Double
    public let dayPnl: Double
    public let dayPnlPct: Double
    /// 当日盈亏的"昨收市值"分母（= Σ 昨收 × 股数，仅计有昨收的票）
    public let dayBaseValue: Double

    public let winners: Int
    public let losers: Int
    public let flats: Int

    public var quotedCount: Int { lines.count }
    public var hasAnyQuote: Bool { !lines.isEmpty }
    public var hasAnyDayPnl: Bool { winners + losers + flats > 0 }

    /// 贡献榜：按 |当日盈亏| 降序（大涨/大跌都值得先看）
    public var topMovers: [Line] {
        lines.filter { $0.dayPnl != nil }
            .sorted { a, b in
                let aa = abs(a.dayPnl ?? 0), bb = abs(b.dayPnl ?? 0)
                if aa != bb { return aa > bb }
                let av = a.dayPnl ?? 0, bv = b.dayPnl ?? 0
                if av != bv { return av > bv }
                return a.code < b.code
            }
    }

    public static func compute(_ inputs: [HoldingPositionInput]) -> HoldingDayPnl {
        var lines: [Line] = []
        lines.reserveCapacity(inputs.count)
        var missing = 0
        var missingPrev = 0
        var totalCost = 0.0
        var totalValue = 0.0
        var totalPnl = 0.0
        var dayPnl = 0.0
        var dayBase = 0.0
        var winners = 0
        var losers = 0
        var flats = 0

        for item in inputs {
            guard item.shares > 0 else { continue }
            guard let price = item.price, price > 0 else {
                missing += 1
                continue
            }
            let cost = item.costPrice > 0 ? item.costPrice : 0
            let marketValue = price * item.shares
            let pnl = (price - cost) * item.shares
            let pnlPct = cost > 0 ? (price - cost) / cost * 100 : 0

            var day: Double?
            var dayPct: Double?
            if let prev = item.previousClose, prev > 0 {
                let v = (price - prev) * item.shares
                day = v
                dayPct = (price - prev) / prev * 100
                dayPnl += v
                dayBase += prev * item.shares
                if v > 0 { winners += 1 }
                else if v < 0 { losers += 1 }
                else { flats += 1 }
            } else {
                missingPrev += 1
            }

            totalCost += cost * item.shares
            totalValue += marketValue
            totalPnl += pnl
            lines.append(Line(code: item.code, name: item.name, shares: item.shares,
                              costPrice: cost, price: price,
                              previousClose: item.previousClose, marketValue: marketValue,
                              totalPnl: pnl, totalPnlPct: pnlPct,
                              dayPnl: day, dayPct: dayPct))
        }

        lines.sort { a, b in
            let av = a.dayPnl
            let bv = b.dayPnl
            if av == nil, bv == nil { return a.code < b.code }
            if av == nil { return false }
            if bv == nil { return true }
            if av == bv { return a.code < b.code }
            return (av ?? 0) > (bv ?? 0)
        }

        return HoldingDayPnl(
            lines: lines,
            missingCount: missing,
            missingPrevCloseCount: missingPrev,
            totalCost: totalCost,
            totalValue: totalValue,
            totalPnl: totalPnl,
            totalPnlPct: totalCost > 0 ? totalPnl / totalCost * 100 : 0,
            dayPnl: dayPnl,
            dayPnlPct: dayBase > 0 ? dayPnl / dayBase * 100 : 0,
            dayBaseValue: dayBase,
            winners: winners,
            losers: losers,
            flats: flats)
    }
}
