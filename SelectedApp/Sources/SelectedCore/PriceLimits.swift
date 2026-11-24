import Foundation

/// 涨跌停 / 异动判定 —— **纯计算**。
///
/// ## 为什么不用固定百分比阈值判涨跌停
/// 涨跌幅限制是**板块相关**的：沪深主板 ±10%、创业板/科创板 ±20%、北交所 ±30%，
/// **沪深主板 ST/*ST 仍是 ±5%**（此处旧文案曾写"ST 实际已是 ±10%、±5% 是过时常识"，
///   2026-10-16 审查 B5-8 纠正 —— 反证来自涨停池本身：能封在 +5% 说明它的上限就是 5%，
///   见 `ZtSentiment.boardLimitPct` 的 5% 档），且 ST 属主板，代码前缀推不出这一档。
/// 而且涨停价**四舍五入到分**，昨收比值不会精确等于 1.10/1.20/1.30 → 也不能反推比例。
/// ⇒ 判据只能是**数据源给的每只票自己的涨跌停价**（`StockQuote.limitUp/limitDown`），
/// 任何硬编码档位表都会随规则调整而过时。

///
/// ## ⚠ 指数行的哨兵值
/// 腾讯对**指数**返回 `limitUp = limitDown = -1`。若不先判 `> 0`，
/// `price >= -1` 恒真 → **每一条指数都会被判成"涨停"**。见 `effectiveLimit`。
///
/// ## ⚠ 这是**提示**，不进评分
/// 本模块只服务个股详情页的「异动提示」卡（只展示）。
/// ⚠ **有意不做成扫描期排除项**：`Screener.hardFilter` 已有跌幅下限
/// （`change_pct_min`），跌停票在那一步已被整批剔掉，排除层永远见不到它们 ——
/// 加在那里等于**加一个永不生效的旋钮**。
public enum PriceLimits {

    // MARK: - 异动类型

    public enum Anomaly: String, CaseIterable, Equatable, Sendable {
        /// 收于涨停价（板块感知）
        case limitUp
        /// 收于跌停价（板块感知）
        case limitDown
        /// 一字板：开 = 收 = 高 = 低，且停在某一侧的板上（无法成交）
        case oneWordBoard
        /// 放量大跌：跌幅大 + 成交额够 + 量能倍数高（次日继续跌的高概率前兆）
        case heavyVolumeDown

        /// 卡上显示的中文名（也是自检的表格驱动键）
        public var label: String {
            switch self {
            case .limitUp: return "涨停"
            case .limitDown: return "跌停"
            case .oneWordBoard: return "一字板"
            case .heavyVolumeDown: return "放量下跌"
            }
        }

        /// 严重度：越大越需要提示（卡内按此降序排列，跌停排最前）
        public var severity: Int {
            switch self {
            case .limitDown: return 4
            case .oneWordBoard: return 3
            case .heavyVolumeDown: return 2
            case .limitUp: return 1
            }
        }

        /// 是否属于"避雷"侧（卡上用警示色）
        public var isRisk: Bool {
            self == .limitDown || self == .heavyVolumeDown
        }
    }

    /// 判定结果
    public struct Verdict: Equatable, Sendable {
        /// 已按 `severity` 降序排好（卡直接按序渲染，不必再排）
        public let anomalies: [Anomaly]
        /// **有效**涨跌停价（哨兵值 -1 已被过滤掉）
        public let limitUp: Double?
        public let limitDown: Double?
        /// 量能倍数（今日量 ÷ 前 5 日均量）；`nil` = 数据不足
        public let volMult5d: Double?

        public var isEmpty: Bool { anomalies.isEmpty }

        /// 一行摘要（无命中 → 空串）
        public var summary: String {
            anomalies.map(\.label).joined(separator: " · ")
        }
    }

    // MARK: - 阈值

    /// 放量大跌的跌幅阈值（%）。口径说明见 `verdict` 的「口径边界」。
    public static let heavyVolumeDownPct = -9.5
    /// 放量大跌的最低成交额（**万元**；2 亿 = 20000 万）。与 `StockQuote.turnover` 同单位。
    public static let heavyVolumeMinAmountWan = 20000.0
    /// 放量大跌的最低量能倍数（今日量 ÷ 前 5 日均量）
    public static let heavyVolumeMinMult = 4.0

    /// 价格比较容差。腾讯的价与涨跌停价都是**2 位小数**，正常是精确相等；
    /// 留一点容差只为吸收 `Double("10.20")` 这类解析误差。
    static let priceEpsilon = 1e-6

    // MARK: - 判定

    /// 有效涨跌停价：`nil` = 数据源没给，**或给的是指数哨兵值 `-1`**。
    ///
    /// ⚠ 这个过滤**不能省**（理由见类型注释）：漏了它，
    /// `price >= -1` 恒真 → 每条指数都被判成"涨停"。
    public static func effectiveLimit(_ v: Double?) -> Double? {
        guard let v, v > 0 else { return nil }
        return v
    }

    /// 判定一只票的异动。
    ///
    /// - Parameters:
    ///   - price / open / high / low: 当日快照（**不是分时**，见下方口径边界）
    ///   - changePct: 当日涨跌幅（%）
    ///   - amountWan: 当日成交额（**万元**，与 `StockQuote.turnover` 同单位）
    ///   - limitUp / limitDown: 腾讯给的涨跌停价（可为 `nil` / 哨兵值）
    ///   - volMult5d: 量能倍数（今日量 ÷ 前 5 日均量）；`nil` = 数据不足 → 不判放量
    ///
    /// ## 口径边界（有意，不是遗漏）
    /// - **只看日K/快照，不看分时**：分时不可回溯，
    ///   所以"盘中是否开板"这类需要逐笔的判定本项目做不了
    /// - ⚠ **量能倍数不做"盘中折算到全日"**（引擎侧 `volMultNormalize` 会折算）：
    ///   折算会让倍数**变大**，也就是**更容易**报"放量下跌"。这里选**保守方向**
    ///   （宁可少报警，不要盘中一惊一乍），且尾盘窗口（14:50）折算系数仅 240/230≈1.04，
    ///   实际差异可忽略
    /// - ⚠ **放量大跌的 `-9.5%` 阈值对 20%/30% 板块偏低**：创业板 -19% 不会命中。
    ///   这是既有口径（"-9.5% 是主板跌停的位置"），**有意保留**：
    ///   换成"该板块跌停幅度的一半"会让同一张卡在不同板块表达不同的意思
    public static func verdict(price: Double, open: Double, high: Double, low: Double,
                               changePct: Double, amountWan: Double,
                               limitUp: Double?, limitDown: Double?,
                               volMult5d: Double?) -> Verdict {
        let up = effectiveLimit(limitUp)
        let dn = effectiveLimit(limitDown)
        var hits: [Anomaly] = []

        // 价格无效 → 不判定（停牌 / 数据源异常）
        if price > 0 {
            let atUp = up.map { price >= $0 - priceEpsilon } ?? false
            let atDown = dn.map { price <= $0 + priceEpsilon } ?? false
            if atUp { hits.append(.limitUp) }
            if atDown { hits.append(.limitDown) }
            // 一字板：开 = 收 = 高 = 低，**且**停在某一侧的板上。
            // ⚠ 必须带上"在板上"这个条件：否则全天停牌（四个值都为 0 或都相等）会被误判成一字板。
            let flat = open > 0 && approx(open, high) && approx(high, low) && approx(low, price)
            if flat && (atUp || atDown) { hits.append(.oneWordBoard) }
        }

        // 放量大跌：跌幅 + 成交额 + 量能倍数**三者齐备**才判
        // （量能倍数缺失 → 不判，而不是当成 0 或当成满足）
        if changePct <= heavyVolumeDownPct,
           amountWan >= heavyVolumeMinAmountWan,
           let vm = volMult5d, vm >= heavyVolumeMinMult {
            hits.append(.heavyVolumeDown)
        }

        return Verdict(anomalies: hits.sorted { $0.severity > $1.severity },
                       limitUp: up, limitDown: dn, volMult5d: volMult5d)
    }

    /// `StockQuote` 便捷入口：从行情里取价/涨跌/额，涨跌停价自动过滤哨兵值。
    ///
    /// ⚠ 港股没有涨跌停（`limitUp/limitDown` 恒 `nil`）→ 只会命中"放量大跌"那一条。
    public static func verdict(_ q: StockQuote, volMult5d: Double?) -> Verdict {
        verdict(price: q.currentPrice, open: q.openPrice, high: q.highPrice, low: q.lowPrice,
                changePct: q.changePercent, amountWan: q.turnover,
                limitUp: q.limitUp, limitDown: q.limitDown, volMult5d: volMult5d)
    }

    /// 量能倍数：今日量 ÷ 前 `days` 日均量，**复用引擎同款公式**（`EngineIndicators.volMult5d`）。
    ///
    /// ⚠ **必须复用引擎那个公式**：自己写一遍会得到第二个口径，
    /// 而"量能倍数"在引擎里是参与加分/扣分的量（`scoring.bonus.vol_mult_*`），两个口径迟早分叉。
    ///
    /// ## ⚠ 为什么要传日期，而不是让调用方声明"来源含不含当日"
    /// 本项目两个日K源对"**含不含当日 bar**"的答案**正好相反**，
    /// 且新浪的行为还**随时刻变**（收盘后当日 bar 才出现）——
    /// "声明来源"不可靠，直接**看最后一根的日期是不是今天**，把判断交给数据本身。
    ///
    /// 判错方向的后果：量能倍数整体错位一个交易日（分子分母都挪一位），
    /// **不报错**，只是"放量"判成了"缩量"。
    ///
    /// - Parameter klineDays: 日K的日期（**升序**，与 `klineVolumes` 一一对应）
    /// - Returns: `nil` = 样本不足 / 今日量为 0（停牌）/ 均量为 0（长期停牌）
    public static func volumeMultiple(klineDays: [String], klineVolumes: [Double],
                                      today: String, todayVolume: Double,
                                      days: Int = 5) -> Double? {
        guard klineDays.count == klineVolumes.count,
              klineVolumes.count >= days,
              !today.isEmpty else { return nil }
        let series: [Double]
        if klineDays.last == today {
            // 末根已是今日（腾讯 / 收盘后的新浪）→ 直接用，**不要再接一次**
            series = klineVolumes
        } else {
            guard todayVolume > 0 else { return nil }
            series = klineVolumes + [todayVolume]
        }
        guard series.count >= days + 1 else { return nil }
        let vm = EngineIndicators.volMult5d(series, days)
        // `volMult5d` 在均量为 0（长期停牌）或样本不足时返回 0；
        // "0 倍量"与"算不出来"在卡上是两件事，折成 nil。
        return vm > 0 ? vm : nil
    }

    private static func approx(_ a: Double, _ b: Double) -> Bool {
        abs(a - b) <= priceEpsilon
    }
}
