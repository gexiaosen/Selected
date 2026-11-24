import Foundation

/// 指标注册表 —— 已实现指标的**元数据单一来源**。
///
/// 快照 Job 按 `all` 遍历落库、筛选页按 `category` 分区渲染卡片。
/// 契约测试（`IndicatorRegistryTests`）钉死
/// "每个已实现序列指标必有 meta、id 唯一、分类合法" —— 新增指标漏登记会红。
///
/// ## ⚠ 这里是"目录"，不是"判据"
/// 只登记 数学上已实现 的指标与其默认参数；**筛选规则/阈值不在本表**
/// （那要走参数中心版本化流程，见 `ParamStore`）。`caliber` 一句话写明
/// 口径分裂点（Wilder/SMA、0–100 等），消费方不许靠 id 猜口径。
public enum IndicatorRegistry {

    /// 指标分类（与筛选页四分区一一对应）。
    public enum Category: String, CaseIterable, Sendable {
        case trend = "趋势"
        case momentum = "动量"
        case volatility = "波动率"
        case volume = "成交量"
    }

    /// 单个指标的元数据。纯值类型，无闭包 —— 可整体序列化进快照表。
    public struct Meta: Sendable, Equatable {
        /// 稳定 id（落库/界面路由用；**只增不改不删**，改名要走迁移）
        public let id: String
        public let category: Category
        /// 界面显示名（中文，本项目唯一界面语言）
        public let displayName: String
        /// 默认周期参数（无参数指标为空数组）
        public let defaultPeriods: [Int]
        /// 口径一句话（分裂点必须写明，如 "Wilder RSI，非 Oscillators 的简单均值口径"）
        public let caliber: String
        /// 输出序列键（快照宽表列名的单一来源：`<snake(id)>_<series>`，
        /// 单输出用 `"value"`；多输出如 MACD 用 `["line","signal","hist"]`）
        public let outputs: [String]

        public init(id: String, category: Category, displayName: String,
                    defaultPeriods: [Int], caliber: String, outputs: [String] = ["value"]) {
            self.id = id
            self.category = category
            self.displayName = displayName
            self.defaultPeriods = defaultPeriods
            self.caliber = caliber
            self.outputs = outputs
        }

        /// 快照宽表里本指标某序列的列名。
        public func column(series: String) -> String {
            Self.snake(id) + "_" + series
        }

        /// 快照宽表里本指标的全部列名（按 `outputs` 顺序）。
        public var columns: [String] { outputs.map { column(series: $0) } }

        /// camelCase → snake_case（列名风格与既有表一致，如 `change_pct`）。
        static func snake(_ s: String) -> String {
            var out = ""
            for ch in s {
                if ch.isUppercase {
                    if !out.isEmpty { out.append("_") }
                    out.append(Character(ch.lowercased()))
                } else {
                    out.append(ch)
                }
            }
            return out
        }
    }

    /// 全部已实现指标（按分类分组排列）。
    public static let all: [Meta] = [
        // MARK: 趋势
        Meta(id: "ema", category: .trend, displayName: "指数移动平均 EMA",
             defaultPeriods: [20],
             caliber: "种子=前n项SMA（夹具口径，非首值种子）"),
        Meta(id: "macd", category: .trend, displayName: "MACD 指数平滑异同",
             defaultPeriods: [12, 26, 9],
             caliber: "线=EMA12−EMA26，信号=EMA(线,9)，柱=线−信号",
             outputs: ["line", "signal", "hist"]),
        Meta(id: "hma", category: .trend, displayName: "赫尔移动平均 HMA",
             defaultPeriods: [20],
             caliber: "half/√n 四舍五入（夹具口径）"),
        Meta(id: "kama", category: .trend, displayName: "考夫曼自适应均线 KAMA",
             defaultPeriods: [10, 2, 30],
             caliber: "种子=索引er−1收盘价（夹具口径）"),

        // MARK: 动量
        Meta(id: "rsiWilder", category: .momentum, displayName: "相对强弱指标 RSI",
             defaultPeriods: [14],
             caliber: "Wilder 平滑；⚠ 与 Oscillators.rsi（简单均值）是两种口径"),
        Meta(id: "stochastic", category: .momentum, displayName: "随机指标 Stochastic",
             defaultPeriods: [14, 3],
             caliber: "%K 未平滑（=rawK），3 只作用于 %D；一字板取中性 50",
             outputs: ["k", "d"]),
        Meta(id: "stochasticRsi", category: .momentum, displayName: "随机指标 StochRSI",
             defaultPeriods: [14],
             caliber: "基于 Wilder RSI；对外 0–100（夹具是 0–1）"),
        Meta(id: "ppo", category: .momentum, displayName: "百分比价格振荡 PPO",
             defaultPeriods: [12, 26, 9],
             caliber: "MACD 骨架，除以慢线 EMA 并 ×100",
             outputs: ["line", "signal", "hist"]),
        Meta(id: "awesomeOscillator", category: .momentum, displayName: "动量振荡 AO",
             defaultPeriods: [5, 34],
             caliber: "SMA(HL2,5)−SMA(HL2,34)，不吃收盘价"),
        Meta(id: "ultimateOscillator", category: .momentum, displayName: "终极振荡 UO",
             defaultPeriods: [7, 14, 28],
             caliber: "窗口内 ΣBP/ΣTR（含昨收），先求和再相除"),

        // MARK: 波动率
        Meta(id: "atrSma", category: .volatility, displayName: "平均真实波幅 ATR(SMA)",
             defaultPeriods: [14],
             caliber: "SMA of TR；⚠ 与 TechnicalIndicators.atr（Wilder）是两种口径"),
        Meta(id: "bollingerBands", category: .volatility, displayName: "布林带",
             defaultPeriods: [20],
             caliber: "σ=总体口径；带宽×100，%B 带宽为0时 nil",
             outputs: ["mid", "upper", "lower", "bandwidth", "percent_b"]),
        Meta(id: "donchianChannel", category: .volatility, displayName: "唐奇安通道",
             defaultPeriods: [20],
             caliber: "上=max(H,n)，下=min(L,n)，中=均值",
             outputs: ["upper", "mid", "lower"]),
        Meta(id: "keltnerChannel", category: .volatility, displayName: "肯特纳通道",
             defaultPeriods: [20],
             caliber: "中=EMA(n)，轨=中±2×ATR_SMA(n)",
             outputs: ["mid", "upper", "lower"]),
        Meta(id: "superTrend", category: .volatility, displayName: "超级趋势 SuperTrend",
             defaultPeriods: [14],
             caliber: "基准=HL2，带宽=2.5×HMA(TR)（夹具口径，非 EMA 版）",
             outputs: ["value", "up"]),
        Meta(id: "ulcerIndex", category: .volatility, displayName: "溃疡指数 UI",
             defaultPeriods: [14],
             caliber: "√(SMA(回撤%²,n))，只量痛苦程度无方向"),

        // MARK: 成交量
        Meta(id: "vwap", category: .volume, displayName: "成交量加权均价 VWAP",
             defaultPeriods: [14],
             caliber: "n 根滚动窗口、TP=收盘；非分时累计口径"),
        Meta(id: "cmf", category: .volume, displayName: "蔡金资金流 CMF",
             defaultPeriods: [20],
             caliber: "ΣMFV/ΣV；整窗 ΣV=0 → nil"),
        Meta(id: "emv", category: .volume, displayName: "简易波动指标 EMV",
             defaultPeriods: [14],
             caliber: "×1e8 缩放口径（阈值标定按此量纲）"),
        Meta(id: "forceIndex", category: .volume, displayName: "强力指数 FI",
             defaultPeriods: [13],
             caliber: "raw=V×ΔC，平滑=EMA"),
        Meta(id: "moneyFlowMultiplier", category: .volume, displayName: "资金流乘数 MFM",
             defaultPeriods: [],
             caliber: "收盘版 (2C−H−L)/(H−L)（夹具口径，非 TP 版）；一字板=0"),
        Meta(id: "moneyFlowVolume", category: .volume, displayName: "资金流体积 MFV",
             defaultPeriods: [],
             caliber: "MFM×Volume"),
    ]

    /// 按 id 查 meta（消费方加载快照行时用；找不到 → nil，不硬造默认）。
    public static func meta(id: String) -> Meta? {
        all.first { $0.id == id }
    }

    /// 按分类取全部 meta（筛选页分区渲染用，保持 `all` 内的登记顺序）。
    public static func metas(category: Category) -> [Meta] {
        all.filter { $0.category == category }
    }
}
