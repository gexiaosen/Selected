import Foundation

/// 昨涨停表现的**盘中快照**（只进内存，不落库）。
///
/// 收盘定稿仍由 `ZtSentimentJob` 在 15:15 落 `zt_sentiment`；
/// 盘中每 60 秒算一次的是同一套口径，只是价格换成实时价。
public struct ZtSentimentLiveSnapshot: Equatable, Sendable {
    public let result: ZtSentimentResult
    /// 前一交易日（周一的情绪对应上周五）
    public let prevTradingDay: String
    /// 本次计算时刻（北京时间）
    public let updatedAt: Date
    /// 参与统计的昨日涨停池条数（含缺价）
    public let poolCount: Int
    /// 昨日涨停池是否由本次从源补回（库里原先没有）
    public let backfilledPool: Bool

    public init(result: ZtSentimentResult, prevTradingDay: String, updatedAt: Date,
                poolCount: Int, backfilledPool: Bool) {
        self.result = result
        self.prevTradingDay = prevTradingDay
        self.updatedAt = updatedAt
        self.poolCount = poolCount
        self.backfilledPool = backfilledPool
    }
}

/// 昨涨停表现的盘中计算 + 昨日涨停池补漏。
public enum ZtSentimentLive {

    /// 用实时行情算一次（纯计算，不触网）。
    ///
    /// ⚠ 与 `ZtSentimentJob.compute` 同一判据（`ZtSentiment.isPromoted`），
    ///   区别只是行情来源：盘中走 `StockQuotes.fetchBatch`，收盘走 `DataSources.fetchTencentQuotes`。
    public static func compute(date: String, pool: [LimitUpRecord],
                               quotes: [String: StockQuote]) -> ZtSentimentResult {
        var samples: [ZtSentiment.Sample] = []
        samples.reserveCapacity(pool.count)
        var missing = 0
        for rec in pool {
            guard let q = quotes[rec.code] else {
                missing += 1
                continue
            }
            samples.append(.init(changePct: q.changePercent,
                                 promoted: ZtSentiment.isPromoted(
                                    todayChangePct: q.changePercent,
                                    yesterdayChangePct: rec.changePct)))
        }
        return ZtSentiment.compute(date: date, samples: samples, missing: missing)
    }

    /// 确保前一交易日的涨停池在内存/库里有数据。
    ///
    /// 源只覆盖最近约 10 个交易日 —— "昨天 App 没开"时库里没有昨日池，
    /// 不加这一步的话开盘后情绪会一直空到收盘（而收盘任务也补不出更早的池）。
    ///
    /// - Parameter allowWrite: 调度器/回放/历史视图占用时传 false：
    ///   只把从源取到的池用于本次内存计算，不写库。
    /// - Returns: `(池, 是否由本次补回)`；源也拿不到 → 空数组。
    public static func ensurePreviousPool(prevDay: String, allowWrite: Bool,
                                          fetchIfMissing: Bool = true)
        -> (pool: [LimitUpRecord], backfilled: Bool) {
        guard !prevDay.isEmpty else { return ([], false) }
        let existing = LimitUpPoolStore.dayRecords(prevDay)
        if !existing.isEmpty { return (existing, false) }
        // 已知源也拿不到时，调用方按退避间隔传 false：只读库、不再反复打源/反复留痕
        guard fetchIfMissing else { return ([], false) }

        guard let fetched = LimitUpPoolSource.fetchDay(prevDay),
              fetched.count >= LimitUpPoolJob.minRecords else {
            // 60 秒一次，不写 data_source_logs（失败保留上一笔/空态提示即可）
            NSLog("[NOTICE] 盘中情绪：%@ 涨停池不在库且源未返回", prevDay)
            return ([], false)
        }
        if allowWrite {
            do {
                try LimitUpPoolStore.saveDay(date: prevDay, records: fetched,
                                             at: PhaseStore.nowStamp())
                DataSources.logDataSource("limitup", "live_backfill",
                                          "盘中补回 \(prevDay) 涨停池 \(fetched.count) 条")
            } catch {
                DataSources.logDataSource("limitup", "live_backfill_failed",
                                          "盘中补 \(prevDay) 涨停池失败：\(error)")
            }
        }
        return (fetched, true)
    }

    /// 前一交易日（交易日历来自上证日K，与复盘/收盘任务同源）。
    public static func previousTradingDay(today: String) -> String? {
        let bars = DataSources.fetchIndexDailyKline(symbol: "sh000001", datalen: 260)
        guard !bars.isEmpty else { return nil }
        let day = TradingCalendar(indexBars: bars).prevTradingDay(today)
        return day.isEmpty ? nil : day
    }
}
