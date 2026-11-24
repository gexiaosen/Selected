import Foundation

// MARK: - 方向

/// 形态方向。负 = 卖出 / 0 = 无形态 / 正 = 买入 的语义映射。
public enum PatternDirection: String, Sendable {
    /// 买入信号（看多）
    case bullish
    /// 卖出信号（看空）
    case bearish
    /// 中性（多空平衡 / 变盘前兆）—— 不作为买入信号
    case neutral

    /// 净方向分：买 `+1` / 卖 `−1` / 中性 `0`
    public var bias: Int {
        switch self {
        case .bullish: return 1
        case .bearish: return -1
        case .neutral: return 0
        }
    }

    /// 界面上的中文标签
    public var label: String {
        switch self {
        case .bullish: return "看多"
        case .bearish: return "看空"
        case .neutral: return "中性"
        }
    }
}

// MARK: - 结果类型

/// 一个命中的形态。
///
/// ⚠ `shape` 是**形状**（同一形状在下跌后与上涨后叫不同名字），`name` 才是**带语境的名字** ——
/// 例如锤头与上吊线的 K 线形状完全相同，只有"出现在下跌后还是上涨后"这一条区别。
/// 界面与落库都应以 `name` 展示、以 `shape` 做去重与统计。
public struct PatternHit: Equatable, Sendable {
    /// 稳定主键（形状，英文）—— 12 个之一，见 `KLinePatterns.definitions`
    public let shape: String
    /// 中文名（已按语境定名，如「上吊线」而非「锤头」）
    public let name: String
    public let direction: PatternDirection
    /// 命中依据（可直接展示，如「下影 3.2× 实体」）
    public let note: String
    /// 该形态用了最近几根 K 线（1 / 2 / 3）
    public let bars: Int

    public init(shape: String, name: String, direction: PatternDirection, note: String, bars: Int) {
        self.shape = shape
        self.name = name
        self.direction = direction
        self.note = note
        self.bars = bars
    }
}

/// 识别结果。
public struct PatternResult: Equatable, Sendable {
    public let hits: [PatternHit]
    /// 计算时用的 K 线根数
    public let barsUsed: Int
    /// 趋势语境（下跌 / 上涨 / 无序）—— 界面要说明"凭什么叫锤头而不是上吊线"
    public let trend: PatternTrend

    public var shapes: [String] { hits.map(\.shape) }
    public var names: [String] { hits.map(\.name) }
    public var bullishCount: Int { hits.filter { $0.direction == .bullish }.count }
    public var bearishCount: Int { hits.filter { $0.direction == .bearish }.count }
    public var neutralCount: Int { hits.filter { $0.direction == .neutral }.count }
    /// 净方向分（买 `+1` / 卖 `−1` / 中性 `0` 求和）。**只是描述，不是评分**。
    public var bias: Int { hits.reduce(0) { $0 + $1.direction.bias } }
}

/// 前序趋势（决定"同一个形状叫什么名字"）
public enum PatternTrend: String, Sendable {
    case down, up, flat

    public var label: String {
        switch self {
        case .down: return "前序下跌"
        case .up: return "前序上涨"
        case .flat: return "前序走平"
        }
    }
}

// MARK: - 阈值

/// 形态识别阈值。全部有默认值 —— 出厂参数缺失时按这些值回落。
///
/// ⚠ **`dojiBodyRatio` 是四个判据共用的边界**：它既是十字星族的**入口**
/// （`bodyRatio ≤ dojiBodyRatio` 才算十字），又是锤头 / 倒锤头 / 纺锤的**守卫**
/// （`bodyRatio > dojiBodyRatio` 才归它们）。所以调这个值**不会**让两个形态同时命中，
/// 只会**把同一个形状改名**（放宽到 0.2 → 「纺锤」变「十字星」）。
/// 这是有意的设计（保证 12 个形状互斥），但**改它时必须意识到是在改分类边界，不是改灵敏度**。
public struct PatternConfig: Equatable, Sendable {
    /// 趋势回看根数（决定"锤头 vs 上吊线"）
    public var trendLookback: Int = 5
    /// 长影线 / 实体 的最小倍数
    public var shadowRatio: Double = 2.0
    /// 「另一侧影线很短」的判据：影线 ≤ 实体 × 该值
    public var shortShadowRatio: Double = 0.5
    /// 小实体上限（实体 ÷ 全幅）
    public var smallBodyRatio: Double = 0.3
    /// 十字星实体上限（实体 ÷ 全幅）
    public var dojiBodyRatio: Double = 0.1
    /// 光头光脚：影线 ÷ 全幅 的上限
    public var marubozuShadowRatio: Double = 0.05
    /// 大实体下限（实体 ÷ 全幅）
    public var longBodyRatio: Double = 0.6
    /// 曙光初现 / 乌云盖顶：深入前一根实体的比例下限
    public var penetrationRatio: Double = 0.5
    /// 窄幅整理：当日全幅 ÷ 近 N 日平均全幅 的上限
    public var narrowRangeRatio: Double = 0.5
    /// 窄幅整理的均值回看根数
    public var narrowLookback: Int = 5
    /// 三个白兵：每根实体的下限（实体 ÷ 全幅）
    public var soldiersBodyRatio: Double = 0.5

    public init() {}
}

// MARK: - 输入接口

/// 形态识别需要的**最小** K 线接口（只要有 OHLC）。
///
/// ⚠ 刻意用**协议**而不是两个 `detect(_:)` 重载 —— 重载会让 `detect([])` **歧义**
/// （空数组字面量推断不出元素类型），那是调用方每天都会踩的坑。
/// 协议还顺带保证：引擎侧的 `KLineBar` 与详情页的 `KLineItem` 走**同一条计算路径**，
/// 显示口径与打分口径**不可能分叉**。
public protocol OHLCBar {
    var open: Double { get }
    var high: Double { get }
    var low: Double { get }
    var close: Double { get }
}

extension KLineBar: OHLCBar {}
extension KLineItem: OHLCBar {}

// MARK: - 打分

/// 形态**打分**配置（`scoring.patterns`）。
///
/// ⚠ 与 `PatternConfig`（识别阈值）**刻意分开**：识别阈值变了只是"判据松紧"，
/// 打分配置变了才是"给不给分"。两者的后果完全不同，混在一个 struct 里会让
/// "调了个阈值"与"开了个开关"看起来是同一类改动。
///
/// ⚠ `enabled` **出厂默认关闭**，而且这一条是硬要求不是保守：形态维度的方向
/// **尚未标定**（本项目没有它的历史样本）。开着就是凭直觉给分，与
/// 「每个加分项都要有标定依据」的既有纪律冲突。开启前先按「次日高开 / 次日午前冲高」
/// 口径做一次标定（可复用 `stock_outcomes`）。
///
/// ⚠ **刻意不声明为 schema 项**（同 `iterate.tune_pool_days`）—— `validate` 对
/// "非可选参数**键缺失**"会报错，新增 schema 项会让所有存量参数版本立即非法。
/// 本参数只影响打分、关掉时逐字复现旧行为 → 走「工厂参数 + 读取处回落默认值」。
/// 将来标定通过要暴露到参数中心时，按 `regime_thresholds` 那条路（升格 schema 项
/// + Swift-only 补种迁移）。
public struct PatternScoreConfig: Equatable, Sendable {
    /// ⚠⚠ 出厂默认关闭
    public var enabled: Bool = false
    public var bullishScore: Int = 6
    public var bearishScore: Int = -6
    /// 中性形态（十字星 / 纺锤 / 窄幅整理 / 身怀六甲）默认**不给分** ——
    /// 它们是"变盘前兆 / 多空平衡"，方向本身就不是信号。
    public var neutralScore: Int = 0
    /// 单只票形态加分的**绝对值上限** —— 防"一天命中 5 个形态"把分数顶飞
    public var cap: Int = 12

    public init() {}

    /// 从参数读；**任何一项缺失都按上面的默认值回落**。
    ///
    /// ⚠ 回落值必须与属性默认值**逐字一致** —— 否则"参数没配"与"配了默认值"
    /// 会给出不同结果（这正是「工厂参数 + 读取处回落」那条约束的要求）。
    public static func from(_ params: [String: Any]?) -> PatternScoreConfig {
        var cfg = PatternScoreConfig()
        guard let d = (params?["scoring"] as? [String: Any])?["patterns"] as? [String: Any]
        else { return cfg }
        if let v = d["enabled"] as? Bool { cfg.enabled = v }
        if let v = d["bullish_score"] as? Int { cfg.bullishScore = v }
        if let v = d["bearish_score"] as? Int { cfg.bearishScore = v }
        if let v = d["neutral_score"] as? Int { cfg.neutralScore = v }
        if let v = d["cap"] as? Int { cfg.cap = v }
        return cfg
    }

    /// 一次识别结果 → 加分（已按 `cap` 截断）与**实际计分**的形态名。
    ///
    /// `names` 只含"分数非 0 的形态"—— 与 `scoring.intraday` 的既有约定一致
    /// （加分为 0 的维度只保留特征、不写明细，避免"尾盘放量1.8倍 +0"这种噪声）。
    public func score(_ r: PatternResult) -> (delta: Int, names: [String]) {
        var raw = 0
        var names: [String] = []
        for h in r.hits {
            let add: Int
            switch h.direction {
            case .bullish: add = bullishScore
            case .bearish: add = bearishScore
            case .neutral: add = neutralScore
            }
            if add != 0 { raw += add; names.append(h.name) }
        }
        let capped = cap > 0 ? max(-cap, min(cap, raw)) : raw
        return (capped, names)
    }
}

// MARK: - 识别

/// K 线形态识别（12 个短周期形态）—— 纯计算，只读日 K 的 OHLC。
///
/// ## 为什么只挑 12 个
///
/// 只取**当日 / 两日 / 三日**的短周期形态 —— 它们与"尾盘选股 + 次日午前"的时间尺度
/// 直接相关；长周期与罕见组合形态不在本模块。
///
/// ## ⚠ 为什么不能放在第 7 层（`formCheck`）
///
/// 引擎的第 7 层「K 线形态」过滤**只拿得到当日 OHLC**（`ScanRunner.swift` 传的是
/// `q.open / q.price / q.high / q.low`），**没有 K 线历史** —— 而这里 12 个形态里有 7 个
/// 是两日或三日组合，在第 7 层**根本算不出来**。
/// 65 根日 K 只在**深挖阶段**才有 → 形态只能在深挖阶段（或详情页用图上已加载的 K 线）算。
///
/// ## 命名规则：形状 ≠ 名字
///
/// 同一形状在不同趋势语境下**是两个名字**（这是形态学本身的定义，不是本项目的简化）：
///
/// | 形状 | 前序下跌 → | 前序上涨 → |
/// |------|-----------|-----------|
/// | 长下影小实体 | **锤头**（买） | **上吊线**（卖） |
/// | 长上影小实体 | **倒锤头**（买） | **射击之星**（卖） |
/// | 三根反转 | **早晨之星**（买） | **黄昏之星**（卖） |
/// | 两日贯穿 | **曙光初现**（买） | **乌云盖顶**（卖） |
/// | 长影十字 | **蜻蜓十字**（买） | **墓碑十字**（卖） |
///
/// 趋势走平时这些"语境形态"**不出**（`PatternTrend.flat`）—— 硬按一个方向命名等于编造信号。
/// 但 `engulfing` / `harami` / `three_soldiers` / `doji` / `marubozu` / `spinning_top` /
/// `narrow_range` 这 7 个**自带方向或本就是中性**，不依赖语境。
///
/// ## 12 个形状是互斥的（有意为之）
///
/// 每条判据都加了**互斥条件**，避免同一个 K 线组合被报成三个形态：
/// · 锤头要求 `bodyRatio > dojiBodyRatio` → 与十字星族（`≤ dojiBodyRatio`）互斥
/// · 蜻蜓 / 墓碑十字要求"另一侧无影"，十字星要求"两侧都有影" → 互斥
/// · 锤头要求"另一侧影线短"，纺锤要求"两侧影线都长" → 互斥
/// · 光头光脚要求 `bodyRatio ≥ longBodyRatio`，与十字星 / 纺锤互斥
/// · 孕线要求"实体包含"，吞没要求"实体被包含" → 互斥
/// → 由 `KLinePatternsTests` 的互斥断言钉住（放宽任一条件都会让某对同时命中）。
public enum KLinePatterns {

    // MARK: - 口径常量（改动等于改口径）

    /// 最少需要的 K 线根数：三根形态 + 至少 1 根前置用于判趋势
    public static let minBars = 4
    /// 十字星族的"另一侧无影"判据：影线 ÷ 全幅
    public static let dojiFlatShadow = 0.1
    /// 蜻蜓 / 墓碑十字的"长影"判据：影线 ÷ 全幅
    public static let dojiLongShadow = 0.6
    /// 纺锤的"两侧影线都不短"判据：影线 ÷ 全幅
    public static let spinningShadow = 0.25
    /// 十字星的"两侧都要有影"判据：影线 ÷ 全幅
    public static let dojiBothShadow = 0.1

    /// 12 个形状的**权威清单**（`shape` → 主名）。
    ///
    /// ⚠ 这是**覆盖性护栏**的基准：`KLinePatternsTests` 断言每个 `shape` 都能被真实构造的
    /// K 线序列命中一次。往这里加一项而不加对应实现，测试立刻红。
    public static let definitions: [(shape: String, name: String)] = [
        ("hammer", "锤头/上吊线"),
        ("inverted_hammer", "倒锤头/射击之星"),
        ("star", "早晨之星/黄昏之星"),
        ("piercing", "曙光初现/乌云盖顶"),
        ("engulfing", "穿头破脚"),
        ("harami", "身怀六甲"),
        ("three_soldiers", "三个白兵"),
        ("doji", "十字星"),
        ("dragonfly", "蜻蜓十字/墓碑十字"),
        ("marubozu", "光头光脚"),
        ("spinning_top", "纺锤"),
        ("narrow_range", "窄幅整理"),
    ]

    /// 不依赖趋势语境的 7 个形状（前序走平时照常出）
    public static let contextFreeShapes: Set<String> = [
        "engulfing", "harami", "three_soldiers", "doji",
        "dragonfly", "marubozu", "spinning_top", "narrow_range",
    ]

    // MARK: - 入口

    /// 识别最近若干根 K 线上的形态。
    ///
    /// - Parameter bars: **按时间正序**（最后一根是当日）。倒序传入不会报错，但结论无意义。
    ///   接受任何 `OHLCBar` 序列 —— 引擎的 `KLineBar`（深挖阶段）与详情页的 `KLineItem`
    ///   （图表已加载）都行，且**共用同一条计算路径**。
    /// - Returns: K 线不足 `minBars` 时返回 `nil`（与 `computeDeepInfo` 的 10 根门槛同一风格）
    public static func detect<B: Sequence>(_ bars: B,
                                           config: PatternConfig = PatternConfig()) -> PatternResult?
    where B.Element: OHLCBar {
        detect(bars.map { Metrics($0) }, config: config)
    }

    /// 从参数里读识别阈值（`scoring.patterns`）。
    ///
    /// ⚠ **引擎（`ScanRunner`）与详情页（`StockDetailSheet`）都调这一个函数** ——
    /// 两处各写一份必然漂移，而漂移的表现是"界面上显示的形态与引擎打分的形态不一致"，
    /// 且**不会报错**（两处各自都自洽）。
    ///
    /// ⚠ 回落值必须与 `PatternConfig` 的属性默认值**逐字一致**。
    public static func config(from params: [String: Any]?) -> PatternConfig {
        var cfg = PatternConfig()
        guard let d = (params?["scoring"] as? [String: Any])?["patterns"] as? [String: Any]
        else { return cfg }
        if let v = d["trend_lookback"] as? Int, v > 0 { cfg.trendLookback = v }
        if let v = d["shadow_ratio"] as? Double, v > 0 { cfg.shadowRatio = v }
        if let v = d["short_shadow_ratio"] as? Double, v >= 0 { cfg.shortShadowRatio = v }
        if let v = d["small_body_ratio"] as? Double, v > 0 { cfg.smallBodyRatio = v }
        if let v = d["doji_body_ratio"] as? Double, v > 0 { cfg.dojiBodyRatio = v }
        if let v = d["marubozu_shadow_ratio"] as? Double, v >= 0 { cfg.marubozuShadowRatio = v }
        if let v = d["long_body_ratio"] as? Double, v > 0 { cfg.longBodyRatio = v }
        if let v = d["penetration_ratio"] as? Double, v > 0 { cfg.penetrationRatio = v }
        if let v = d["narrow_range_ratio"] as? Double, v > 0 { cfg.narrowRangeRatio = v }
        if let v = d["narrow_lookback"] as? Int, v > 0 { cfg.narrowLookback = v }
        if let v = d["soldiers_body_ratio"] as? Double, v > 0 { cfg.soldiersBodyRatio = v }
        return cfg
    }

    /// 剔除**尾部**尚未形成的 bar。
    ///
    /// 盘中早段行情接口会给出 `high / low` 全为 0 的"当日占位 bar"（实测腾讯 `newfqkline`
    /// 在开盘前就会带上当日日期）。把它当成"当前根"会让 12 个形态全部落在一条假 K 线上 ——
    /// 且**不会报错**（全零 bar 的 `range == 0`，各形态静默不出）。
    ///
    /// ⚠ 只在**尾部**剔除：中间的零值 bar（停牌 / 长期无成交）是**历史事实**，
    /// 剔掉会让两日 / 三日形态**跨越停牌期拼接** —— 那在形态学上不成立。
    public static func dropUnformedTail<B: Sequence>(_ bars: B) -> [B.Element]
    where B.Element: OHLCBar {
        var out = Array(bars)
        while let last = out.last, last.high <= 0 || last.low <= 0 || last.high < last.low {
            out.removeLast()
        }
        return out
    }

    /// 唯一的实现（两种输入都汇到这里）
    private static func detect(_ m: [Metrics],
                               config: PatternConfig) -> PatternResult? {
        let n = m.count
        guard n >= minBars else { return nil }

        let cur = m[n - 1]
        let p1 = m[n - 2]
        let p2 = m[n - 3]

        // ---- 趋势语境：用"当前根之前"的收盘与均线比 ----
        let priorCloses = m[0..<(n - 1)].map(\.c)
        let look = max(1, min(config.trendLookback, priorCloses.count))
        let window = priorCloses.suffix(look)
        let ma = window.reduce(0, +) / Double(window.count)
        let ref = priorCloses[priorCloses.count - 1]
        let trend: PatternTrend
        if ref < ma { trend = .down } else if ref > ma { trend = .up } else { trend = .flat }

        var hits: [PatternHit] = []

        // ---- 1 / 2：长影线小实体（语境形态）----
        if cur.bodyRatio > config.dojiBodyRatio, cur.bodyRatio <= config.smallBodyRatio {
            if cur.lower >= cur.body * config.shadowRatio,
               cur.upper <= cur.body * config.shortShadowRatio {
                if trend == .down {
                    hits.append(.init(shape: "hammer", name: "锤头", direction: .bullish,
                                      note: "下影 \(fx(cur.lower / cur.body))× 实体，上影很短 · 前序下跌",
                                      bars: 1))
                } else if trend == .up {
                    hits.append(.init(shape: "hammer", name: "上吊线", direction: .bearish,
                                      note: "下影 \(fx(cur.lower / cur.body))× 实体，上影很短 · 前序上涨",
                                      bars: 1))
                }
            }
            if cur.upper >= cur.body * config.shadowRatio,
               cur.lower <= cur.body * config.shortShadowRatio {
                if trend == .down {
                    hits.append(.init(shape: "inverted_hammer", name: "倒锤头", direction: .bullish,
                                      note: "上影 \(fx(cur.upper / cur.body))× 实体，下影很短 · 前序下跌",
                                      bars: 1))
                } else if trend == .up {
                    hits.append(.init(shape: "inverted_hammer", name: "射击之星", direction: .bearish,
                                      note: "上影 \(fx(cur.upper / cur.body))× 实体，下影很短 · 前序上涨",
                                      bars: 1))
                }
            }
        }

        // ---- 3：三根反转（早晨之星 / 黄昏之星）----
        if p2.bodyRatio >= config.longBodyRatio, p1.bodyRatio <= config.smallBodyRatio {
            if !p2.isBull, p1.c < p2.c, cur.isBull, cur.c > p2.mid, cur.c > p1.c {
                hits.append(.init(shape: "star", name: "早晨之星", direction: .bullish,
                                  note: "大阴 + 小实体（收更低）+ 阳线收回前阴实体上半", bars: 3))
            }
            if p2.isBull, p1.c > p2.c, !cur.isBull, cur.c < p2.mid, cur.c < p1.c {
                hits.append(.init(shape: "star", name: "黄昏之星", direction: .bearish,
                                  note: "大阳 + 小实体（收更高）+ 阴线跌回前阳实体下半", bars: 3))
            }
        }

        // ---- 4：两日贯穿（曙光初现 / 乌云盖顶）----
        if !p1.isBull, cur.isBull, cur.o < p1.c, cur.c > p1.mid, cur.c < p1.o {
            hits.append(.init(shape: "piercing", name: "曙光初现", direction: .bullish,
                              note: "低开阳线深入前阴实体 \(fx((cur.c - p1.c) / max(p1.body, 1e-9)))× ，未吞没", bars: 2))
        }
        if p1.isBull, !cur.isBull, cur.o > p1.c, cur.c < p1.mid, cur.c > p1.o {
            hits.append(.init(shape: "piercing", name: "乌云盖顶", direction: .bearish,
                              note: "高开阴线跌破前阳实体 \(fx((p1.c - cur.c) / max(p1.body, 1e-9)))× ，未吞没", bars: 2))
        }

        // ---- 5：穿头破脚（吞没）----
        if !p1.isBull, cur.isBull, cur.o <= p1.c, cur.c >= p1.o {
            hits.append(.init(shape: "engulfing", name: "穿头破脚（阳包阴）", direction: .bullish,
                              note: "阳线实体完全包住前一根阴线实体", bars: 2))
        }
        if p1.isBull, !cur.isBull, cur.o >= p1.c, cur.c <= p1.o {
            hits.append(.init(shape: "engulfing", name: "穿头破脚（阴包阳）", direction: .bearish,
                              note: "阴线实体完全包住前一根阳线实体", bars: 2))
        }

        // ---- 6：身怀六甲（孕线）----
        if p1.bodyRatio >= config.longBodyRatio, cur.body < p1.body * 0.5,
           max(cur.o, cur.c) <= max(p1.o, p1.c), min(cur.o, cur.c) >= min(p1.o, p1.c) {
            hits.append(.init(shape: "harami", name: "身怀六甲", direction: .neutral,
                              note: "小实体完全孕于前一根大实体之内（变盘前兆）", bars: 2))
        }

        // ---- 7：三个白兵 ----
        if p2.isBull, p1.isBull, cur.isBull,
           p2.bodyRatio >= config.soldiersBodyRatio,
           p1.bodyRatio >= config.soldiersBodyRatio,
           cur.bodyRatio >= config.soldiersBodyRatio,
           p1.c > p2.c, cur.c > p1.c,
           p1.o > p2.o, p1.o < p2.c, cur.o > p1.o, cur.o < p1.c {
            hits.append(.init(shape: "three_soldiers", name: "三个白兵", direction: .bullish,
                              note: "三连阳，实体均 ≥ \(pct(config.soldiersBodyRatio)) 全幅，逐根抬高", bars: 3))
        }

        // ---- 8 / 9：十字星族 ----
        if cur.bodyRatio <= config.dojiBodyRatio, cur.range > 0 {
            let flatUp = cur.upper <= cur.range * dojiFlatShadow
            let flatDown = cur.lower <= cur.range * dojiFlatShadow
            let longDown = cur.lower >= cur.range * dojiLongShadow
            let longUp = cur.upper >= cur.range * dojiLongShadow
            if flatUp, longDown {
                hits.append(.init(shape: "dragonfly", name: "蜻蜓十字", direction: .bullish,
                                  note: "开收在最高附近 + 长下影 \(pct(cur.lower / cur.range)) 全幅（下方承接）", bars: 1))
            } else if flatDown, longUp {
                hits.append(.init(shape: "dragonfly", name: "墓碑十字", direction: .bearish,
                                  note: "开收在最低附近 + 长上影 \(pct(cur.upper / cur.range)) 全幅（上方抛压）", bars: 1))
            } else if cur.upper >= cur.range * dojiBothShadow, cur.lower >= cur.range * dojiBothShadow {
                hits.append(.init(shape: "doji", name: "十字星", direction: .neutral,
                                  note: "实体仅 \(pct(cur.bodyRatio)) 全幅，上下都有影（多空平衡）", bars: 1))
            }
        }

        // ---- 10：光头光脚 ----
        if cur.range > 0,
           cur.bodyRatio >= config.longBodyRatio,
           cur.upper <= cur.range * config.marubozuShadowRatio,
           cur.lower <= cur.range * config.marubozuShadowRatio {
            hits.append(.init(shape: "marubozu",
                              name: cur.isBull ? "光头光脚阳线" : "光头光脚阴线",
                              direction: cur.isBull ? .bullish : .bearish,
                              note: "实体 \(pct(cur.bodyRatio)) 全幅，两端几乎无影", bars: 1))
        }

        // ---- 11：纺锤 ----
        if cur.range > 0,
           cur.bodyRatio > config.dojiBodyRatio, cur.bodyRatio <= config.smallBodyRatio,
           cur.upper >= cur.range * spinningShadow, cur.lower >= cur.range * spinningShadow {
            hits.append(.init(shape: "spinning_top", name: "纺锤", direction: .neutral,
                              note: "小实体 \(pct(cur.bodyRatio)) 全幅 + 上下影都长（波动收敛）", bars: 1))
        }

        // ---- 12：窄幅整理 ----
        if cur.range > 0 {
            let back = min(config.narrowLookback, n - 1)
            if back >= 2 {
                let priorRanges = m[(n - 1 - back)..<(n - 1)].map(\.range)
                let avg = priorRanges.reduce(0, +) / Double(priorRanges.count)
                if avg > 0, cur.range <= avg * config.narrowRangeRatio {
                    hits.append(.init(shape: "narrow_range", name: "窄幅整理", direction: .neutral,
                                      note: "全幅仅为近 \(back) 日均值 \(pct(cur.range / avg))（变盘前兆）", bars: 1))
                }
            }
        }

        return PatternResult(hits: hits, barsUsed: n, trend: trend)
    }

    // MARK: - 内部

    /// 单根 K 线的派生量。`range` 恒 ≥ 0；全幅为 0（一字板 / 停牌）时所有比值按 0 处理。
    private struct Metrics {
        let o: Double, h: Double, l: Double, c: Double

        init<B: OHLCBar>(_ b: B) { o = b.open; h = b.high; l = b.low; c = b.close }

        var range: Double { max(h - l, 0) }
        var body: Double { abs(c - o) }
        var upper: Double { max(0, h - max(o, c)) }
        var lower: Double { max(0, min(o, c) - l) }
        var isBull: Bool { c >= o }
        var bodyRatio: Double { range > 0 ? body / range : 0 }
        var mid: Double { (o + c) / 2 }
    }

    /// 倍数格式化（`3.2`）
    private static func fx(_ v: Double) -> String {
        String(format: "%.1f", v)
    }

    /// 比例格式化（`32%`）
    private static func pct(_ v: Double) -> String {
        String(format: "%.0f%%", v * 100)
    }
}
