import Foundation

// MARK: - 输入接口

/// 量能判据需要的**最小**接口（OHLC + 成交量）。
///
/// ⚠ **新开一个协议，而不是给 `OHLCBar` 加一个必选成员**：
/// `OHLCBar` 是 public 协议，加必选成员会**破坏所有既有 conformer**（编译期直接红）。
/// 而只有"量能"那几条判据需要成交量 —— 形状识别（12 个）不该被牵连。
///
/// ⚠ 单位是**手**（与 `KLineBar` / `KLineItem` 一致）。判据只用**比值**，所以单位不影响结论，
/// 但混用不同单位的序列会静默出错。
public protocol VolumeBar: OHLCBar {
    var volume: Double { get }
}

extension KLineBar: VolumeBar {}
extension KLineItem: VolumeBar {}

/// 量能 / 连续性判据 —— **第二组**（与 12 个形状正交）
///
/// ## 为什么与 12 个「形状」刻意分开
///
/// | | 12 个形状（`KLinePatterns`） | 本组（`KLineSignals`） |
/// |---|---|---|
/// | 判什么 | **形状分类**（K 线组合长什么样） | **量能 + 连续性**（量放没放、连了几根） |
/// | 互斥？ | **是**（同一组合只报一个名字，有断言钉住） | **否**（与形状正交） |
/// | 输入 | `OHLCBar`（只要 OHLC） | `VolumeBar`（OHLC + 成交量） |
///
/// 混在一起会破坏"12 个形状互斥"那条设计（`KLinePatterns` 文件头写着、`KLinePatternsTests`
/// 有互斥断言钉住）：一根光头光脚大阳线**既**可能是"天量"**也**可能不是，两者正交。
///
/// ## ⚠ 阈值来源：**本项目的出厂默认值**
/// 本组四条阈值是我们自己定的，性质与 `PatternConfig`（形态识别阈值）相同：
/// 可调、**改动等于改口径**。
///
/// ## ⚠ 只展示、不进评分
/// 方向尚未标定（本项目没有它的历史样本）。理由与 K 线形态完全一致 ——
/// 开着就是凭直觉给分，与「每个加分项都要有标定依据」的纪律冲突。
///
/// ## ⚠ 口径：**末根就是今日**
/// 与 `KLinePatterns.detect` 同约定（"按时间正序、最后一根是当日"）。
/// "前 N 日均量"= **不含末根**的前 N 根（复用 `EngineIndicators.volMult5d`，与引擎同口径）。
public enum KLineSignals {

    // MARK: - 判据类型

    public enum Kind: String, CaseIterable, Sendable {
        /// 天量：今日量远高于前 N 日均量。**方向中性** —— 天量上涨与天量下跌是两回事，
        /// 方向写在 `note` 里，不硬塞进 `direction`。
        case heavyVolume
        /// 连涨放量：连涨 + 放量（资金进场的组合特征）
        case volumeSurgeUp
        /// 下跌无量：缩量下跌。**方向中性** —— 中文技术分析里它多被读作"抛压衰竭"，
        /// 但那是一种**解读**而不是方向信号，故与十字星 / 窄幅整理同处理（不给方向）。
        case quietDecline
        /// 连续阳线（收 > 开）
        case consecutiveYang
        /// 连续阴线（收 < 开）
        case consecutiveYin

        /// 基础名（连续类会按根数换成传统名，见 `name`）
        public var baseName: String {
            switch self {
            case .heavyVolume: return "天量"
            case .volumeSurgeUp: return "连涨放量"
            case .quietDecline: return "下跌无量"
            case .consecutiveYang: return "连续阳线"
            case .consecutiveYin: return "连续阴线"
            }
        }

        public var direction: PatternDirection {
            switch self {
            case .volumeSurgeUp, .consecutiveYang: return .bullish
            case .consecutiveYin: return .bearish
            case .heavyVolume, .quietDecline: return .neutral
            }
        }

        /// 卡内排序（越大越靠前）：连阴最该先看到（风险），天量最次
        public var severity: Int {
            switch self {
            case .consecutiveYin: return 5
            case .quietDecline: return 4
            case .heavyVolume: return 3
            case .volumeSurgeUp: return 2
            case .consecutiveYang: return 1
            }
        }
    }

    /// 一条命中的判据
    public struct Signal: Equatable, Sendable {
        public let kind: Kind
        /// 展示名（连续类会带传统名，如「四串阳」）
        public let name: String
        public let direction: PatternDirection
        /// 命中依据（可直接展示）
        public let note: String
    }

    // MARK: - 阈值

    /// 阈值。全部有默认值 —— 出厂参数缺失时按这些回落。
    ///
    /// ⚠ 与 `KLinePatterns.PatternConfig` 同一性质：**改动等于改口径**，不是"调灵敏度"。
    public struct SignalConfig: Equatable, Sendable {
        /// 均量回看根数（不含今日）
        public var volAvgDays: Int = 5
        /// 天量：今日量 ÷ 前 N 日均量 的下限
        public var heavyVolumeMult: Double = 3.0
        /// 连涨放量：连涨天数下限
        public var surgeUpMinDays: Int = 2
        /// 连涨放量：量能倍数下限
        public var surgeUpMult: Double = 2.0
        /// 下跌无量：量能倍数**上限**
        public var quietDeclineMult: Double = 0.7
        /// 连续阳线 / 阴线的根数下限。
        ///
        /// ⚠ 默认 **4**：传统名（四串阳 / 八仙过海(八连阳) / 九阳神功(九连阳) / 七仙女下凡(七连阴)）
        /// 都是 4 根起；设成 1 或 2 会让"两连阳"这种极常见形态天天命中（噪声）。
        public var consecutiveMin: Int = 4

        public init() {}
    }

    // MARK: - 入口

    /// 识别末根 K 线上的量能 / 连续性判据。
    ///
    /// - Parameter bars: **按时间正序**（最后一根是当日）。样本不足（< `volAvgDays + 1`）→ `[]`。
    /// - Returns: 已按 `severity` 降序排好（卡直接按序渲染）
    public static func detect<B: Sequence>(_ bars: B,
                                           config: SignalConfig = SignalConfig()) -> [Signal]
    where B.Element: VolumeBar {
        let arr = Array(bars)
        let n = arr.count
        guard n >= config.volAvgDays + 1, config.volAvgDays >= 1 else { return [] }

        let volumes = arr.map(\.volume)
        let closes = arr.map(\.close)
        let cur = arr[n - 1]
        let prev = arr[n - 2]
        // 量能倍数 = 今日量 ÷ 前 N 日均量。⚠ 复用引擎公式（`volumes.last` 当今日、
        // 前 N 根当基准），不另写一遍 —— 否则会得到第二个"量能倍数"口径。
        // 均量为 0（长期停牌）时返回 0 → 下面各条都不命中（`vm > 0` 是下跌无量的前置）。
        let vm = EngineIndicators.volMult5d(volumes, config.volAvgDays)
        let chgPct = prev.close > 0 ? PyMath.round((cur.close - prev.close) / prev.close * 100, 2) : 0

        var out: [Signal] = []

        if vm >= config.heavyVolumeMult {
            out.append(Signal(kind: .heavyVolume, name: Kind.heavyVolume.baseName,
                              direction: Kind.heavyVolume.direction,
                              note: "今日量 \(fmt(vm)) 倍于前 \(config.volAvgDays) 日均量"
                                  + "（今日 \(signed(chgPct))%）"))
        }

        let upDays = EngineIndicators.consecutiveUpDays(closes)
        if upDays >= config.surgeUpMinDays, vm >= config.surgeUpMult {
            out.append(Signal(kind: .volumeSurgeUp, name: Kind.volumeSurgeUp.baseName,
                              direction: Kind.volumeSurgeUp.direction,
                              note: "连涨 \(upDays) 天且今日量 \(fmt(vm)) 倍均量"))
        }

        // ⚠ `vm > 0` 不能省：均量为 0 时 `volMult5d` 返回 0，而 0 ≤ 0.7 会让
        //   "算不出来"被当成"极度缩量"→ 长期停牌的票被报成"下跌无量"。
        if chgPct < 0, vm > 0, vm <= config.quietDeclineMult {
            out.append(Signal(kind: .quietDecline, name: Kind.quietDecline.baseName,
                              direction: Kind.quietDecline.direction,
                              note: "今日 \(signed(chgPct))% 但量只有均量的 \(fmt(vm)) 倍"))
        }

        let (yang, yin) = consecutiveBodyStreak(arr)
        if yang >= config.consecutiveMin {
            out.append(Signal(kind: .consecutiveYang, name: yangName(yang),
                              direction: Kind.consecutiveYang.direction,
                              note: "连续 \(yang) 根阳线（收 > 开）"))
        }
        if yin >= config.consecutiveMin {
            out.append(Signal(kind: .consecutiveYin, name: yinName(yin),
                              direction: Kind.consecutiveYin.direction,
                              note: "连续 \(yin) 根阴线（收 < 开）"))
        }

        return out.sorted { $0.kind.severity > $1.kind.severity }
    }

    // MARK: - 连续性（纯函数）

    /// 从末根往前数连续阳线 / 阴线根数。
    ///
    /// ⚠ **口径与 `consec_up` 不同**（这是本模块存在的理由之一）：
    /// · 这里按**阳线/阴线**：`收 > 开` / `收 < 开`
    /// · `EngineIndicators.consecutiveUpDays` 按**涨幅**：`(close[i]-close[i-1])/close[i-1] > 0`
    ///
    /// 两者会给出**不同答案**：跳空高开但收阴的票（涨幅 > 0、收 < 开）计入**连涨**、不计入**连阳**。
    /// → 不是重复口径，是两件不同的事。
    ///
    /// ⚠ **十字（收 == 开）会同时打断两条连续** —— 它既不是阳线也不是阴线。
    /// 用严格不等号（`>` / `<`）而不是 `>=` / `<=` 就是为了这个。
    public static func consecutiveBodyStreak<B: Sequence>(_ bars: B) -> (yang: Int, yin: Int)
    where B.Element: OHLCBar {
        let arr = Array(bars)
        guard !arr.isEmpty else { return (0, 0) }
        let last = arr[arr.count - 1]
        let isYang = last.close > last.open
        let isYin = last.close < last.open
        guard isYang || isYin else { return (0, 0) }     // 末根是十字 → 两条都不成立
        var count = 0
        for b in arr.reversed() {
            if isYang, b.close > b.open { count += 1 }
            else if isYin, b.close < b.open { count += 1 }
            else { break }
        }
        return isYang ? (count, 0) : (0, count)
    }

    // MARK: - 命名（传统名）

    /// 连续阳线的展示名。4 / 8 / 9 根各有传统叫法，其余按 `N连阳`。
    ///
    /// ⚠ 1 / 2 根的「一根大阳线 / 两根大阳线」**不在这里** —— 那两条还要求"实体够大"，
    /// 而"大阳线 / 大阴线"已由 `KLinePatterns` 的 `marubozu`（光头光脚）覆盖。
    public static func yangName(_ n: Int) -> String {
        switch n {
        case 4: return "四串阳"
        case 8: return "八仙过海"
        case 9: return "九阳神功"
        default: return "\(n)连阳"
        }
    }

    /// 连续阴线的展示名（传统名「七仙女下凡」）
    public static func yinName(_ n: Int) -> String {
        n == 7 ? "七仙女下凡" : "\(n)连阴"
    }

    // MARK: - 文案工具

    private static func fmt(_ v: Double) -> String {
        String(format: "%.2f", PyMath.round(v, 2))
    }

    private static func signed(_ v: Double) -> String {
        String(format: "%+.2f", v)
    }
}
