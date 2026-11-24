import Foundation

/// 涨停池的**收盘后日更任务**（调度器入口）。
///
/// ## 为什么单独一个 job，而不是塞进 `PhaseReview`
///
/// 与 `LhbJob` / `FundFlowJob` 同一理由：
///   · **不给扫描轮次加失败点** —— 涨停池是收盘后的时点数据，独立任务 ⇒ 独立状态 ⇒
///     它挂了不会把 `review` / `iterate` 带成红色。
///   · **不进总分** —— 本文件不产出任何参与评分/判定的字段。
///
/// ## 为什么必须落库
///
/// ⚠ 源**只覆盖最近约 10 余个交易日**（实测更早的日期返回 `tc=0`）。
/// 也就是说：**今天不记下来，以后永远取不回**。
/// 对比筹码分布（能从日K重算，所以不落库）—— 这是两类东西。
/// → 落库，而且**不补历史**（补不了）。
///
/// ## ⚠ 时点
///
/// 涨停在 15:00 收盘时定稿（14:57 后的集合竞价仍可能炸板），所以排在 **15:15**：
/// 在复盘（15:05）之后、资金流（15:20）之前。**不需要**像龙虎榜那样等 17:30
/// —— 那个是交易所发布延迟，涨停池是行情自身的状态。
///
/// ## ⚠ 回看补漏
///
/// 与 `LhbJob` 同一套：App 当天没开着 / 抓取失败时，回看最近几个交易日，
/// 补上"**库里还没有**"的那一天。因为源只覆盖 10 余天，丢一天就少一天。
public enum LimitUpPoolJob {

    /// 回看窗口（自然日，跳过周末）。5 天足够覆盖"周五晚上没开机、周一补上"这类情形。
    public static let lookbackDays = 5

    /// 一天的涨停家数**下界**。
    ///
    /// A股几乎每个交易日都有涨停股（哪怕大跌日也有个位数），所以"只拿到 1~2 只"
    /// 几乎一定是抓取异常（半截响应）而不是真的只有这么多。
    /// ⚠ 这个下界**不是**用来判断"今天行情好不好"，只用来判断"这次抓取像不像完整的"。
    public static let minRecords = 3

    /// 失败原因（`LocalizedError` → `Scheduler` 取 `errorDescription` 作为重试原因文案）
    public enum Failure: LocalizedError {
        /// 今天拿不到，且回看窗口内也没有可补的交易日（可重试）
        case notReady(date: String)
        /// 落库失败等
        case fetchFailed(String)

        public var errorDescription: String? {
            switch self {
            case .notReady(let date):
                // ⚠ 文案可自由出现「非交易日」：`Scheduler` 只认结构化 `status`，
                //   本 Job 的"跳过"走**返回值** `status=not_trading_day`（不抛错）。
                return "东财涨停池尚未返回 \(date) 的数据（或条数不足），稍后重试"
            case .fetchFailed(let why):
                return "涨停池取数失败：\(why)"
            }
        }
    }

    /// 收盘后跑一次：抓当日（必要时回看补漏）→ 落库。
    ///
    /// - Returns: 可直接交给 `JSONValue` / 通知文案的结果字典。
    ///   `status` 取 `ok` / `not_trading_day`（后者由 `Scheduler.finish` 识别为
    ///   "标记完成但不通知"，与扫描路径同一约定）。
    /// - Throws: `Failure`（可重试）
    /// - Parameter shouldStop: 取消检查闭包（审查 #12）：`Scheduler.stop()` 置位取消盒后，
    ///   取数完成的一刻**不再落库**。
    public static func run(shouldStop: () -> Bool = { false }) throws -> [String: Any] {
        let started = Date()
        let today = ChinaTime.day()

        // ① 交易日闸门：休市没有"今天的涨停池"可抓。
        //    走既有 `DataSources.isTradingDay()`（已处理节假日与"行情未更新"），
        //    不自己判周末 —— 否则调休日会误抓。
        let (isTrading, reason) = DataSources.isTradingDay()
        guard isTrading else {
            DataSources.logDataSource("limitup", "skip_not_trading_day", "非交易日（\(reason)）→ 跳过")
            return ["status": "not_trading_day", "trading_day_reason": reason, "date": today]
        }

        // ② 取数（今天优先，抓不到则回看补漏 —— 见文件头）
        guard let picked = pickDay(today: today) else {
            throw Failure.notReady(date: today)
        }

        // ③ 落库（整日重插，幂等）—— 取消检查（审查 #12）：退出时不再写库
        if shouldStop() { return ["status": "cancelled", "date": today] }
        let saved: Int
        do {
            saved = try LimitUpPoolStore.saveDay(date: picked.day, records: picked.records,
                                                 at: PhaseStore.nowStamp())
        } catch {
            throw Failure.fetchFailed("落库失败：\(error)")
        }

        // ④ 摘要（仅用于通知文案；不参与任何判定）
        let maxBoards = picked.records.map(\.boards).max() ?? 0
        let top = picked.records.max { $0.boards < $1.boards }
        let broken = picked.records.filter { $0.brokenCount > 0 }.count
        let elapsed = Date().timeIntervalSince(started)
        // ⚠ 收盘后各 Job（龙虎榜/资金流/涨停池/板块热度）事件名**各自独立**，
        //   不要共用 `daily_ok` —— 它与"日K"毫无关系，诊断页按事件筛选会误导排障。
        DataSources.logDataSource("limitup", "limitup_ok",
                      "\(picked.day) 落库 \(saved) 条（最高 \(maxBoards) 连板，"
                        + "炸板过 \(broken) 只"
                        + (picked.backfilled ? "，回看补漏" : "")
                        + "，耗时 \(String(format: "%.1f", elapsed))s）")

        return [
            "status": "ok",
            "date": picked.day,
            "backfilled": picked.backfilled,
            "records": saved,
            "max_boards": maxBoards,
            "broken_count": broken,
            "top_name": top?.name ?? "",
            "top_code": top?.code ?? "",
            "elapsed_sec": elapsed,
        ]
    }

    // MARK: - 取哪一天

    /// 今天优先；今天抓不到时回看窗口内补"库里还没有"的最近一天。
    ///
    /// - Returns: `nil` 表示今天与回看窗口内都没有可落库的数据（调用方抛可重试失败）。
    static func pickDay(today: String) -> (day: String, records: [LimitUpRecord],
                                          backfilled: Bool)? {
        if let r = LimitUpPoolSource.fetchDay(today), r.count >= minRecords {
            return (today, r, false)
        }
        for d in ChinaTime.recentWeekdays(before: today, count: lookbackDays) {
            // 已经有了就跳过：既省请求，也**不会**用旧数据覆盖已落好的那天
            if LimitUpPoolStore.hasDay(d) { continue }
            if let r = LimitUpPoolSource.fetchDay(d), r.count >= minRecords {
                DataSources.logDataSource("limitup", "backfill",
                                          "今天（\(today)）尚未返回 → 补上 \(d)")
                return (d, r, true)
            }
        }
        return nil
    }
}
