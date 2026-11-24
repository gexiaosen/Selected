import Foundation
import SQLite3

/// 昨日涨停 · 今日表现（市场情绪指标）。
///
/// ## 一句话
/// 把**昨天涨停池**里的每只票，拿**今天的涨跌幅**做统计：平均涨幅、中位数、
/// 连板晋级率（今天又涨停的占比）、亏损面（今天下跌的占比）。
/// 这是最直接的**打板情绪**读数 —— 昨天追涨停的人今天赚钱还是亏钱。
///
/// ## 输入全是已有数据（零新数据源）
/// · 昨日涨停池：`LimitUpPoolStore.dayRecords(前一交易日)`
/// · 今日行情：`DataSources.fetchTencentQuotes(codes)`（收盘后终态）
///
/// ## ⚠ **只展示、不进评分/不进大盘灯**
/// 与 `Fundamental`（慢变量只展示）同一姿势。喂 `MarketLightLevel` 需要先做
/// Spearman 相关性检查（情绪与现有涨跌比 `ratio` 大概率 ρ>0.6，防重复计分）；
/// 这里先把数据采下来、显示出来、攒历史。
public struct ZtSentimentResult: Equatable, Sendable {

    /// 统计归属的交易日（今天）`yyyy-MM-dd`
    public let date: String
    /// 参与统计的只数（昨日涨停池里、今天拿到行情的）
    public let sample: Int
    /// 今天取不到行情的只数（停牌 / 退市 / 源缺失）—— **单独计，不污染均值**
    public let missing: Int
    /// 平均涨幅（%）
    public let avgPct: Double
    /// 涨幅中位数（%）
    public let medianPct: Double
    /// 今日再涨停（晋级）的只数
    public let promoted: Int
    /// 今日下跌（<0%）的只数（亏损面）
    public let lossCount: Int

    /// 晋级率 0–1；`sample == 0` 时 0
    public var promotionRate: Double { sample > 0 ? Double(promoted) / Double(sample) : 0 }
    /// 亏损面 0–1；`sample == 0` 时 0
    public var lossRate: Double { sample > 0 ? Double(lossCount) / Double(sample) : 0 }

    public init(date: String, sample: Int, missing: Int, avgPct: Double, medianPct: Double,
                promoted: Int, lossCount: Int) {
        self.date = date
        self.sample = sample
        self.missing = missing
        self.avgPct = avgPct
        self.medianPct = medianPct
        self.promoted = promoted
        self.lossCount = lossCount
    }
}

/// 情绪统计的**纯计算**（不触网、不碰库 → 可离线单测）。
/// 落库与读取在 `ZtSentimentStore.swift`。
public enum ZtSentiment {

    /// 一只票的"今日事实"（由调用方从行情解析后喂进来）
    public struct Sample: Equatable, Sendable {
        public let changePct: Double
        public let promoted: Bool
        public init(changePct: Double, promoted: Bool) {
            self.changePct = changePct
            self.promoted = promoted
        }
    }

    /// 晋级判定的容差（百分点）。
    ///
    /// 真实涨停收盘**精确停在板块涨停价**（四舍五入到分），涨幅 ≈ 板块上限 ±0.05；
    /// 而"涨 9.7%（主板）/19.7%（创业板）"是**没封住**的票，不该算晋级。
    /// 取 `0.2` 既容得下四舍五入误差，又能把差一口气的票挡在外面。
    public static let promoteTol = 0.2

    /// 从**昨日涨停时的涨幅**推断该票的板块涨停上限。
    ///
    /// 逻辑：能进昨日涨停池 ⇒ 昨天它封在涨停价 ⇒ 昨天涨幅 ≈ 它的板块上限。
    /// 板块上限只有四档（见 `PriceLimits` 类型注释）：ST 主板 5 / 主板 10 / 创业·科创 20 / 北交 30。
    /// ⚠ 不硬编码"代码前缀→档位"表（北交所 920 号段等规则会变）——
    ///   而是**用昨天那个真实封板涨幅反推**，规则变了也自动跟着变。
    ///
    /// ⚠ 5% 档不能省（2026-10-16 审查 B5-8）：原先 `case ..<15: return 10`
    ///   把 +5.0% 的 ST 涨停直接归到主板 10% 档，于是 `isPromoted` 要求今天 ≥9.8%，
    ///   **ST 的二连板（+5%）永远不算晋级** ⇒ 连板晋级率被系统性压低、亏损面被抬高，
    ///   而这两个数就是板块页展示给用户的"市场情绪"。
    ///   归档依据本身就是证据：能进昨日涨停池 ⇒ 昨天封在**涨停价**上，
    ///   所以它昨天的涨幅**就等于它的板块上限**（不存在"上限 10% 却封在 +5%"的票）。
    ///   原 `PriceLimits` 头注释里"ST 实际已是 ±10%"的说法据此一并纠正。
    /// - Returns: 5 / 10 / 20 / 30 之一；昨天涨幅异常低（<4.8%，连 ST 板都够不着）→ 10
    ///   （保守，最难晋级；这与既有"异常低不算晋级"的取向一致）
    public static func boardLimitPct(_ yesterdayChangePct: Double) -> Double {
        switch yesterdayChangePct {
        case ..<4.8:  return 10       // 异常低：保守归最难档
        case ..<7.5:  return 5        // ST 主板
        case ..<15:   return 10       // 主板
        case ..<25:   return 20       // 创业板 / 科创板
        default:      return 30       // 北交所
        }
    }

    /// 今日是否晋级（再涨停）：今天涨幅 ≥ 板块上限 − 容差。
    public static func isPromoted(todayChangePct: Double, yesterdayChangePct: Double) -> Bool {
        todayChangePct >= boardLimitPct(yesterdayChangePct) - promoteTol
    }

    /// 汇总（升/降序无关，内部排序取中位数）。
    ///
    /// 空样本 → 全 0（`sample == 0`），调用方据此显示"样本不足"。
    public static func compute(date: String, samples: [Sample], missing: Int) -> ZtSentimentResult {
        guard !samples.isEmpty else {
            return ZtSentimentResult(date: date, sample: 0, missing: missing,
                                     avgPct: 0, medianPct: 0, promoted: 0, lossCount: 0)
        }
        var sum = 0.0
        var promoted = 0
        var loss = 0
        var pcts: [Double] = []
        pcts.reserveCapacity(samples.count)
        for s in samples {
            sum += s.changePct
            pcts.append(s.changePct)
            if s.promoted { promoted += 1 }
            if s.changePct < 0 { loss += 1 }
        }
        pcts.sort()
        let n = pcts.count
        let median = (n % 2 == 1)
            ? pcts[n / 2]
            : (pcts[n / 2 - 1] + pcts[n / 2]) / 2
        return ZtSentimentResult(date: date, sample: n, missing: missing,
                                 avgPct: PyMath.round(sum / Double(n), 2),
                                 medianPct: PyMath.round(median, 2),
                                 promoted: promoted, lossCount: loss)
    }
}
