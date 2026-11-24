import Foundation

/// 昨日涨停表现的**计算任务**。
///
/// ## 为什么**不单独占一个调度项**
/// 输入是「昨日涨停池（已落库）+ 今日收盘行情」——与 `LimitUpPoolJob` 同时点、同数据面。
/// 拆成独立任务只会多一个失败点、多一格调度设置；并入 15:15 的涨停统计任务，
/// **尽力而为**（best-effort）：情绪算失败**不影响**涨停池本身的落库结果与任务状态。
///
/// ## 口径
/// · 「昨日」= 交易日历上的**前一交易日**（`TradingCalendar.prevTradingDay`，与复盘同源），
///   不是自然日昨天 —— 周一的情绪对应的是上周五的池子。
/// · 「今日涨跌幅」= 收盘后腾讯行情终态（`fetchTencentQuotes`，15:15 抓到的是收盘价）。
/// · 停牌/取不到行情 → 计入 `missing`，**不参与均值**（否则停牌 0% 会把情绪拉平）。
public enum ZtSentimentJob {

    /// 失败原因（供日志文案；本 Job **不抛给调度器**——见类型注释"尽力而为"）
    public enum Skip: Equatable {
        /// 前一交易日的涨停池不在库里（超源覆盖窗口 / 当时 App 没开着）
        case noPool(prevDay: String)
        /// 交易日历拿不到（指数日K失败）→ 无法确定"昨日"是哪天
        case noCalendar
        /// 行情整批为空（腾讯挂了）
        case noQuotes
        case saveFailed(String)

        var text: String {
            switch self {
            case .noPool(let d): return "前一交易日（\(d)）的涨停池不在库里 → 跳过"
            case .noCalendar: return "交易日历不可用 → 跳过"
            case .noQuotes: return "今日行情为空 → 跳过"
            case .saveFailed(let w): return "落库失败：\(w)"
            }
        }
    }

    /// 计算并落库；**任何失败只留痕，不打断调用方**（涨停池任务）。
    ///
    /// - Returns: `(结果, 跳过原因)` —— 二者恰有一个非 nil。
    @discardableResult
    public static func runQuietly(today: String) -> (ZtSentimentResult?, Skip?) {
        let outcome = compute(today: today)
        switch outcome {
        case .computed(let r):
            do {
                try ZtSentimentStore.save(r, at: PhaseStore.nowStamp())
                DataSources.logDataSource("zt_sentiment", "ok",
                    "\(today) 昨涨停 \(r.sample) 只（缺 \(r.missing)）："
                    + "均涨 \(String(format: "%+.2f", r.avgPct))%｜晋级 \(r.promoted)"
                    + "｜亏损面 \(r.lossCount)")
                return (r, nil)
            } catch {
                let s = Skip.saveFailed("\(error)")
                DataSources.logDataSource("zt_sentiment", "save_failed", "\(today) \(s.text)")
                return (nil, s)
            }
        case .skipped(let s):
            DataSources.logDataSource("zt_sentiment", "skip", "\(today) \(s.text)")
            return (nil, s)
        }
    }

    public enum Outcome {
        case computed(ZtSentimentResult)
        case skipped(Skip)
    }

    /// 纯取数 + 计算（不落库；自检可单独调）。
    public static func compute(today: String) -> Outcome {
        // ① 前一交易日：与复盘同源（指数日K构造日历）。日历为空 → 不猜"昨天"。
        let bars = DataSources.fetchIndexDailyKline(symbol: "sh000001", datalen: 260)
        guard !bars.isEmpty else { return .skipped(.noCalendar) }
        let prevDay = TradingCalendar(indexBars: bars).prevTradingDay(today)
        guard !prevDay.isEmpty else { return .skipped(.noCalendar) }

        // ② 昨日涨停池（库里没有 → 跳过，不报错：源只覆盖 10 余天，缺就是缺）
        let pool = LimitUpPoolStore.dayRecords(prevDay)
        guard !pool.isEmpty else { return .skipped(.noPool(prevDay: prevDay)) }

        // ③ 今日收盘行情（按池内代码取，一次批量 ≤ 池子大小）
        let codes = pool.map(\.code)
        let quotes = DataSources.fetchTencentQuotes(codes)
        guard !quotes.isEmpty else { return .skipped(.noQuotes) }

        // ④ 逐只配对：行情缺失 → missing（不进样本）；晋级按该票自己的板块上限判
        var samples: [ZtSentiment.Sample] = []
        samples.reserveCapacity(pool.count)
        var missing = 0
        for rec in pool {
            guard let q = quotes[rec.code],
                  let pct = Num.doubleOrNil(q["change_pct"]) else {
                missing += 1
                continue
            }
            samples.append(.init(changePct: pct,
                                 promoted: ZtSentiment.isPromoted(todayChangePct: pct,
                                                                  yesterdayChangePct: rec.changePct)))
        }
        return .computed(ZtSentiment.compute(date: today, samples: samples, missing: missing))
    }
}
