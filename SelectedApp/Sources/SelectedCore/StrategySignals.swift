import Foundation

/// 六条**策略选股**判据（停机坪 / 回踩年线 / 突破平台 / 海龟 / 高而窄旗形 / 低 ATR 成长）。
///
/// ## ⚠ 这一项**天然想改筛选口径** —— 但只展示
///
/// 来源是六条**独立策略**，不是"展示字段"。而本项目有一条铁律：**改既有评分 = 改变历史行为**。
/// 所以本模块走**只展示、不进评分、不进筛选**，理由有两条：
///
/// 1. 来源自己警告过：「每一条都是独立策略，需逐个回测验证，**不能直接信文档**」
///    —— 而本模块的条件与阈值**正是从那份文档抄的**。
///    在**没有任何回测标定**的情况下让它们影响选股，等于凭直觉给分。
/// 2. 落成"排除项/加分项"只能走「新参数 + 默认关」，而"默认关的旋钮"是本项目反复踩的坑。
///
/// → **条件实现完整（六条全做，不挑不删）**，但只用于**详情页展示**。
/// 要接进选股，前置条件是**用历史回放做标定**（能力已具备，见 `HistoryReplayMode`）。
///
/// ## ⚠ 三处"来源条件本身就有问题"（不擅自改，但必须写出来）
///
/// | 策略 | 问题 |
/// |------|------|
/// | **低 ATR 成长** | 名字说"**低** ATR"，条件却是「近10日高低收盘比 **> 1.1**」——比值 >1.1 是**有**波动（≥10%），与名字**方向相反**。按来源字面实现，名字的可信度另行存疑 |
/// | **突破平台** | 「前期偏离 −5%~20%」没说**相对谁**。本实现取"相对 MA60 的偏离"，这是平台型策略的通行读法，但**是一种解释** |
/// | **停机坪** | 「高开**小涨**」的"小"没给上限。本实现取 `0 < 涨幅 ≤ 5%` |
///
/// → 这三处都做成 `Config` 里的**可调阈值**，并在文档里写明"这是我们的读法"。
///
/// ## ⚠ 数据前提（决定了它只能落在**详情页**）
///
/// | 策略 | 需要的最少日K | 引擎侧（`datalen` 65） | 详情页（`KLineService` 500） |
/// |------|-------------|---------------------|--------------------------|
/// | 停机坪 / 突破平台 / 海龟 / 高而窄旗形 | 60~65 | ✅ | ✅ |
/// | **回踩年线**（MA250） / **低 ATR**（250 日） | **250** | ❌ | ✅ |
///
/// ⚠ 腾讯日K单次可给 **301 根**（请求 300），`initialCount(for: .daily) = 500`
/// → 年线在详情页**拿得到**；但引擎侧 65 根**拿不到** —— 所以本模块**不进引擎**，
/// 这不只是姿势选择，也是**数据可得性**决定的。
///
/// ## ⚠ 口径：末根 = 今日；「前 N 根」**不含末根**
/// 与 `KLinePatterns` / `KLineSignals` / `EngineIndicators.volMult5d` 同一约定。
/// ⚠ 海龟的"60 日最高收盘"必须取**末根之前**的 60 根 —— 含末根会退化成恒真式
/// （`close >= close`），那是一条**永远不会失败**的判据。
public enum StrategySignals {

    // MARK: - 阈值

    /// 阈值配置。**默认值 = 来源字面值**（给了数的地方）或**本项目的读法**（没给数的地方）。
    ///
    /// ⚠ 来源只给了「连续两天涨幅≥9.5%」「收盘/最低≥1.9」「近10日高低比>1.1」
    /// 「60日/15日/24~10日」这些**结构参数**，以及"放量"但没给倍数。
    /// 没给数的一律取本项目既有默认（放量 2.0 与 `KLineSignals.heavyVolumeMult` 一致）。
    public struct Config: Sendable {
        // ① 停机坪
        public var flatTopWindow = 15
        public var flatTopLaunchGainPct = 9.5
        public var flatTopLaunchVolMult = 2.0
        public var flatTopSmallGainMaxPct = 5.0
        public var flatTopMaxFollow = 3
        // ② 回踩年线
        public var yearLinePeriod = 250
        public var pullbackTolerance = 0.03
        public var pullbackShrinkMult = 0.7
        public var breakoutLookback = 20
        // ③ 突破平台
        public var platformMaPeriod = 60
        public var platformVolMult = 2.0
        public var platformDevMin = -0.05
        public var platformDevMax = 0.20
        // ④ 海龟
        public var turtleBreakoutDays = 60
        // ⑤ 高而窄的旗形
        public var flagMinListedDays = 60
        public var flagRiseMultiple = 1.9
        public var flagLowFrom = 24
        public var flagLowTo = 10
        public var flagPoleGainPct = 9.5
        public var flagPoleDays = 2
        // ⑥ 低 ATR 成长
        public var lowAtrMinListedDays = 250
        public var lowAtrRangeDays = 10
        public var lowAtrRangeMin = 1.1

        public init() {}
    }

    // MARK: - 判据类型

    /// 六条策略。**互不排斥** —— 同一天可以同时命中多条。
    public enum Kind: String, CaseIterable, Sendable {
        case flatTop
        case yearLinePullback
        case platformBreakout
        case turtleBreakout
        case highTightFlag
        case lowAtrGrowth

        /// 展示名。
        public var title: String {
            switch self {
            case .flatTop: return "停机坪"
            case .yearLinePullback: return "回踩年线"
            case .platformBreakout: return "突破平台"
            case .turtleBreakout: return "海龟交易法则"
            case .highTightFlag: return "高而窄的旗形"
            case .lowAtrGrowth: return "低 ATR 成长"
            }
        }
    }

    /// 命中一条。
    public struct Hit: Sendable {
        public let kind: Kind
        /// 命中的**依据**（写进界面，让用户能核对，而不是只给一个名字）。
        public let note: String
    }

    /// 评估结果。
    ///
    /// ⚠ **`skipped` 不是"没命中"，是"没评估"** —— 日K根数不够 / 缺上市日期时，
    /// 该条判据**根本没跑**。把它混进"未命中"会让界面显示成"这只票不符合海龟法则"，
    /// 而真相是"我们没能力判断"。跳过数必须如实报出（本项目通用纪律）。
    public struct Outcome: Sendable {
        public let hits: [Hit]
        public let skipped: [Kind: String]

        public var hitKinds: [Kind] { hits.map(\.kind) }
    }

    // MARK: - 入口

    /// 评估六条策略。
    ///
    /// - Parameters:
    ///   - bars: 日K，**时间正序、末根是今日**。
    ///   - listedDays: **上市交易日数**（⚠ **不是自然日**）。为 `nil` 时回落成 `bars.count`。
    ///
    ///     ⚠ 口径统一成"交易日"是有意的：来源写"上市 ≥250 日"，而这是**日K策略** ——
    ///     最自然的实现就是"数据长度 ≥ 250 根"。若改用**自然日**，同一个 250 会差出
    ///     **4 个月**（250 自然日 ≈ 8 个月 vs 250 交易日 ≈ 1 年），
    ///     而两套口径混用是典型的静默错误（同一阈值、两条数据路径给出不同答案）。
    ///     → 谁传进来的都必须按**交易日**算。
    ///
    ///     ⚠ 与 `bars.count` 仍有细微差别：少取了几根 bar 时 `bars.count` 会偏小。
    ///     所以 `skipped` 的文案里会**标明这个数是从哪来的**，不静默等同。
    ///   - config: 阈值。
    public static func evaluate<B: Sequence>(_ bars: B,
                                             listedDays: Int? = nil,
                                             config: Config = .init()) -> Outcome
    where B.Element: VolumeBar {
        let b = Array(bars)
        var hits: [Hit] = []
        var skipped: [Kind: String] = [:]

        // ⚠ 直接分发（见 `collect` 注释）：不传函数引用，避免 Swift 6 的
        //   `capture of non-Sendable type 'B.Element.Type'`（`#SendableMetatypes` 警告）。
        collect(.flatTop, need: 3, b, config, &hits, &skipped)
        collect(.yearLinePullback, need: config.yearLinePeriod + 1, b, config, &hits, &skipped)
        collect(.platformBreakout, need: config.platformMaPeriod + 1, b, config, &hits, &skipped)
        collect(.turtleBreakout, need: config.turtleBreakoutDays + 1, b, config, &hits, &skipped)

        // ⑤⑥ 额外依赖「上市交易日数」——没给就按 bar 根数兜底，但把**来源**写进 note
        let age = listedDays ?? b.count
        let ageNote = listedDays == nil ? "按日K根数推断" : "由调用方给出"
        for (kind, need) in [(Kind.highTightFlag, config.flagMinListedDays),
                             (Kind.lowAtrGrowth, config.lowAtrMinListedDays)] {
            let barsNeed = kind == .highTightFlag
                ? max(config.flagLowFrom + 1, config.flagPoleDays + 1)
                : config.lowAtrRangeDays
            guard b.count >= barsNeed else {
                skipped[kind] = "日K不足（有 \(b.count) 根，需要 \(barsNeed) 根）"
                continue
            }
            guard age >= need else {
                skipped[kind] = "上市不满 \(need) 个交易日（实得 \(age) 个，\(ageNote)）"
                continue
            }
            let h = kind == .highTightFlag
                ? highTightFlag(b, config)
                : lowAtrGrowth(b, config)
            if let h { hits.append(h) }
        }
        return Outcome(hits: hits, skipped: skipped)
    }

    // MARK: - ① 停机坪

    /// 「15 日内放量涨 >9.5% → 次日高开小涨 → 后 2~3 日高开小涨」
    ///
    /// 读法：在最近 `flatTopWindow` 根里找**启动日**（涨幅 > 9.5% + 放量），
    /// 要求启动日**之后**的每一根（1~`flatTopMaxFollow` 根）都是「高开 + 小涨」。
    /// 找**最近**的那个启动日（从末根往前扫）。
    static func flatTop<B: VolumeBar>(_ b: [B], _ c: Config) -> Hit? {
        let last = b.count - 1
        guard last >= 1 else { return nil }
        let from = max(1, b.count - c.flatTopWindow)
        guard last - 1 >= from else { return nil }
        for i in stride(from: last - 1, through: from, by: -1) {
            let follow = last - i
            guard follow >= 1, follow <= c.flatTopMaxFollow else { continue }
            let prev = b[i - 1].close
            guard prev > 0 else { continue }
            guard pct(prev, b[i].close) > c.flatTopLaunchGainPct else { continue }
            guard let av = avgVolume(b, before: i, n: 5), av > 0,
                  b[i].volume >= av * c.flatTopLaunchVolMult else { continue }
            var ok = true
            for j in (i + 1)...last {
                guard b[j].open > b[j - 1].close else { ok = false; break }   // 高开
                let g = b[j].open > 0 ? (b[j].close - b[j].open) / b[j].open * 100 : -1
                guard g > 0, g <= c.flatTopSmallGainMaxPct else { ok = false; break }  // 小涨
            }
            guard ok else { continue }
            return Hit(kind: .flatTop,
                       note: "启动日在 \(follow) 根前（涨 \(fmt(pct(prev, b[i].close)))% + 放量），"
                           + "其后 \(follow) 根均高开小涨")
        }
        return nil
    }

    // MARK: - ② 回踩年线

    /// 「突破年线后回踩缩量」
    ///
    /// 三步：① 最近 `breakoutLookback` 根内**发生过**向上突破年线（收盘由下穿上）；
    /// ② 今日收盘**回到年线附近**（±`pullbackTolerance`）；③ 今日**缩量**。
    static func yearLinePullback<B: VolumeBar>(_ b: [B], _ c: Config) -> Hit? {
        let n = c.yearLinePeriod
        let last = b.count - 1
        guard b.count >= n + 1, last >= n else { return nil }
        // ① 突破：在 [last-lookback, last] 里找 close[j-1] <= MA(j-1) < close[j]
        let lo = max(n, last - c.breakoutLookback)
        guard lo <= last else { return nil }
        var brokeAt: Int?
        for j in stride(from: last, through: lo, by: -1) {
            guard let maNow = ma(b, endingAt: j, period: n),
                  let maPrev = ma(b, endingAt: j - 1, period: n) else { continue }
            if b[j - 1].close <= maPrev, b[j].close > maNow { brokeAt = j; break }
        }
        guard let bt = brokeAt else { return nil }
        // ② 回踩到位
        guard let maToday = ma(b, endingAt: last, period: n), maToday > 0 else { return nil }
        let dev = (b[last].close - maToday) / maToday
        guard abs(dev) <= c.pullbackTolerance else { return nil }
        // ③ 缩量
        guard let av = avgVolume(b, before: last, n: 5), av > 0,
              b[last].volume < av * c.pullbackShrinkMult else { return nil }
        return Hit(kind: .yearLinePullback,
                   note: "\(last - bt) 根前突破年线（MA\(n)=\(fmt(maToday))），"
                       + "今日回踩至 \(fmt(dev * 100))% 且缩量")
    }

    // MARK: - ③ 突破平台

    /// 「60 日收盘 ≥ 60 日均线 > 开盘 + 放量 + 前期偏离 −5%~20%」
    ///
    /// 读法：`MA60` 落在今日开盘与收盘**之间**（盘中由下穿上 = 突破），且今日放量；
    /// 再加一条**平台约束** —— 前 60 根相对**各自 MA60** 的偏离都落在 `[devMin, devMax]`。
    /// ⚠ 这一条是**我们的解释**（来源没说是相对谁），见文件头。
    static func platformBreakout<B: VolumeBar>(_ b: [B], _ c: Config) -> Hit? {
        let n = c.platformMaPeriod
        let last = b.count - 1
        guard let maToday = ma(b, endingAt: last, period: n), maToday > 0 else { return nil }
        let bar = b[last]
        guard bar.close >= maToday, maToday > bar.open else { return nil }
        guard let av = avgVolume(b, before: last, n: 5), av > 0,
              bar.volume >= av * c.platformVolMult else { return nil }
        // 平台约束：前 n 根相对各自 MA60 的偏离
        for j in (last - n)..<last {
            guard j >= n, let m = ma(b, endingAt: j, period: n), m > 0 else { continue }
            let dev = (b[j].close - m) / m
            guard dev >= c.platformDevMin, dev <= c.platformDevMax else { return nil }
        }
        return Hit(kind: .platformBreakout,
                   note: "MA\(n)=\(fmt(maToday)) 落在开盘/收盘之间（\(fmt(bar.open))→\(fmt(bar.close))），"
                       + "放量 \(fmt(bar.volume / av))× 前 5 日均量")
    }

    // MARK: - ④ 海龟交易法则

    /// 「收盘 ≥ 最近 60 日最高收盘」
    ///
    /// ⚠ 必须是**末根之前**的 60 根：含末根会退化成 `close >= close`（恒真）。
    /// ⚠ 与既有 `EngineIndicators.distFromHigh60d` **同源**（都取 60 日最高收盘）：
    /// 那条算"距最高点还差多少"（**下跌侧**、防接刀），本项问"**是否创了新高**"。
    /// 两者可互推（`distFromHigh >= 0`），但**不是同一层**：前者进第 8 层深度排除，
    /// 后者只在详情页展示。
    static func turtleBreakout<B: VolumeBar>(_ b: [B], _ c: Config) -> Hit? {
        let last = b.count - 1
        let lo = last - c.turtleBreakoutDays
        guard lo >= 0 else { return nil }
        let prior = b[lo..<last].map(\.close)
        guard let hi = prior.max(), hi > 0 else { return nil }
        guard b[last].close >= hi else { return nil }
        return Hit(kind: .turtleBreakout,
                   note: "收盘 \(fmt(b[last].close)) ≥ 前 \(c.turtleBreakoutDays) 日最高收盘 \(fmt(hi))")
    }

    // MARK: - ⑤ 高而窄的旗形

    /// 「上市 ≥60 日 + 收盘 / 前 24~10 日最低 ≥ 1.9 + 连续两天涨幅 ≥9.5%」
    ///
    /// 「前 24~10 日最低」取 `[last-24, last-10]` 这段区间的**最低价**（`low`，不是 `close`）。
    static func highTightFlag<B: VolumeBar>(_ b: [B], _ c: Config) -> Hit? {
        let last = b.count - 1
        // 旗杆：最近 flagPoleDays 根，每根涨幅 ≥ 9.5%
        for k in 0..<c.flagPoleDays {
            let i = last - k
            guard i >= 1, b[i - 1].close > 0 else { return nil }
            guard pct(b[i - 1].close, b[i].close) >= c.flagPoleGainPct else { return nil }
        }
        // 高度：收盘 / 前 24~10 日最低
        let loIdx = last - c.flagLowFrom
        let hiIdx = last - c.flagLowTo
        guard loIdx >= 0, hiIdx >= loIdx else { return nil }
        guard let lowest = b[loIdx...hiIdx].map(\.low).min(), lowest > 0 else { return nil }
        let mult = b[last].close / lowest
        guard mult >= c.flagRiseMultiple else { return nil }
        return Hit(kind: .highTightFlag,
                   note: "收盘 / 前 \(c.flagLowFrom)~\(c.flagLowTo) 日最低 = \(fmt(mult))×（≥\(fmt(c.flagRiseMultiple))），"
                       + "且连续 \(c.flagPoleDays) 天涨幅 ≥\(fmt(c.flagPoleGainPct))%")
    }

    // MARK: - ⑥ 低 ATR 成长

    /// 「上市 ≥250 日 + 近 10 日高低收盘比 > 1.1」
    ///
    /// ⚠ **名字与条件方向相反**（"低 ATR" vs 比值 > 1.1 即 ≥10% 波动）——
    /// 按来源字面实现，见文件头。`lowAtrRangeMin` 可调，改它等于改口径。
    static func lowAtrGrowth<B: VolumeBar>(_ b: [B], _ c: Config) -> Hit? {
        let last = b.count - 1
        let lo = last - c.lowAtrRangeDays + 1
        guard lo >= 0 else { return nil }
        let closes = b[lo...last].map(\.close)
        guard let hi = closes.max(), let mn = closes.min(), mn > 0 else { return nil }
        let ratio = hi / mn
        guard ratio > c.lowAtrRangeMin else { return nil }
        return Hit(kind: .lowAtrGrowth,
                   note: "近 \(c.lowAtrRangeDays) 日最高收盘 / 最低收盘 = \(fmt(ratio))×（>\(fmt(c.lowAtrRangeMin))）")
    }

    // MARK: - 工具

    /// 跑一条判据并归档结果：**要么进 `hits`，要么进 `skipped`**（"没评估"绝不静默）。
    ///
    /// ⚠ 在 `switch kind` 里**直接分发**策略函数，而不是把函数引用当闭包参数传入：
    ///   Swift 6 下把泛型函数引用传给闭包参数会在孤立闭包里捕获非 Sendable 的
    ///   `B.Element.Type`（`#SendableMetatypes` 警告）。`default` 分支不可达
    ///   （kind 其余 case 由 `evaluate` 的⑤⑥循环处理，不会走到这里）。
    private static func collect<B: VolumeBar>(_ kind: Kind, need: Int, _ b: [B], _ c: Config,
                                              _ hits: inout [Hit],
                                              _ skipped: inout [Kind: String]) {
        guard b.count >= need else {
            skipped[kind] = "日K不足（有 \(b.count) 根，需要 \(need) 根）"
            return
        }
        let h: Hit? = switch kind {
        case .flatTop: flatTop(b, c)
        case .yearLinePullback: yearLinePullback(b, c)
        case .platformBreakout: platformBreakout(b, c)
        case .turtleBreakout: turtleBreakout(b, c)
        default: nil  // 不可达（见上）
        }
        if let h { hits.append(h) }
    }

    /// 收盘价均线（`endingAt` 含在内）。
    static func ma<B: OHLCBar>(_ b: [B], endingAt i: Int, period: Int) -> Double? {
        guard period > 0, i - period + 1 >= 0 else { return nil }
        let s = b[(i - period + 1)...i].reduce(0.0) { $0 + $1.close }
        return s / Double(period)
    }

    /// **不含 `i`** 的前 `n` 根平均成交量（与 `EngineIndicators.volMult5d` 同口径）。
    static func avgVolume<B: VolumeBar>(_ b: [B], before i: Int, n: Int) -> Double? {
        guard n > 0, i - n >= 0 else { return nil }
        let s = b[(i - n)..<i].reduce(0.0) { $0 + $1.volume }
        return s / Double(n)
    }

    static func pct(_ from: Double, _ to: Double) -> Double {
        guard from > 0 else { return .nan }
        return (to - from) / from * 100
    }

    /// 只用于 `note` 的可读格式化（两位小数，与引擎 `round2` 口径一致）。
    static func fmt(_ v: Double) -> String {
        String(format: "%.2f", v)
    }
}
