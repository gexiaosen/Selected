import Foundation

/// 龙虎榜的**收盘后日更任务**（调度器入口）。
///
/// ## 为什么单独一个 job，而不是塞进 `PhaseReview`
///
/// 与 `FundFlowJob` 同一理由：
///   · **不给扫描轮次加失败点** —— 龙虎榜是收盘后的时点数据，独立任务 ⇒ 独立状态 ⇒
///     它挂了不会把 `review` / `iterate` 带成红色。
///   · **不进总分** —— 本文件不产出任何参与评分/判定的字段。
///
/// ## 为什么必须落库
///
/// 上榜记录与席位都是**外部时点数据**，不记下来就取不回来（对比：筹码分布可以从日K
/// 重算，所以它不落库）。故这里 `LhbStore.saveDay`。
///
/// ## ⚠ 发布时点不确定 → 用「回看补漏」兜底
///
/// 龙虎榜由交易所在收盘后发布，东财入库时点**晚于行情收盘**，具体时刻无法反推
/// （只能看到"次日已有数据"）⇒ 计划时点（17:30）是**估计值**。
///
/// 若只做"抓今天、抓不到就失败"，有两个真实的丢数据路径：
///   ① 17:30 时数据还没入库 → 重试全失败 → 当天标记 missed，
///      而这张表是**唯一的记录**，这一天就**永久没了**；
///   ② App 当天没开着（过了补跑窗口）→ 同上。
///
/// 故这里在"今天抓不到"时**回看最近几个交易日**，补上"已发布但库里没有"的那一天。
/// 代价是有界的一次性请求（回看窗口 5 天、跳过周末），收益是**不会永久丢一天**。
///
/// ⚠ 回看**只补"库里没有的"那一天**：已有的日子不再请求（省 3 次请求），
///   也**不会**用旧数据覆盖已经落好的那天。
public enum LhbJob {

    /// 回看窗口（自然日，跳过周末）。5 天足够覆盖"周五晚上没开机、周一补上"这类情形。
    public static let lookbackDays = 5

    /// 失败原因（`LocalizedError` → `Scheduler` 会取 `errorDescription` 作为重试原因文案）
    public enum Failure: LocalizedError {
        /// 今天尚未发布，且回看窗口内也没有可补的交易日（可重试）
        case notReady(date: String)
        /// 落库失败等
        case fetchFailed(String)

        public var errorDescription: String? {
            switch self {
            case .notReady(let date):
                // ⚠ 文案可自由出现「非交易日」：`Scheduler` 只认结构化 `status`，
                //   本 Job 的"跳过"走**返回值** `status=not_trading_day`（不抛错）。
                return "东财龙虎榜尚未发布 \(date) 的数据（或条数不足），稍后重试"
            case .fetchFailed(let why):
                return "龙虎榜取数失败：\(why)"
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

        // ① 交易日闸门：休市没有"今天的龙虎榜"可抓。
        //    走既有 `DataSources.isTradingDay()`（它已处理节假日与"行情未更新"），
        //    不自己判周末 —— 否则调休日会误抓。
        let (isTrading, reason) = DataSources.isTradingDay()
        guard isTrading else {
            DataSources.logDataSource("lhb", "skip_not_trading_day", "非交易日（\(reason)）→ 跳过")
            return ["status": "not_trading_day", "trading_day_reason": reason, "date": today]
        }

        // ② 取数（今天优先，抓不到则回看补漏 —— 见文件头）
        guard let picked = pickDay(today: today) else {
            throw Failure.notReady(date: today)
        }

        // ③ 落库（删日重写，幂等）—— 取消检查（审查 #12）：退出时不再写库
        if shouldStop() { return ["status": "cancelled", "date": today] }
        let saved = try LhbStore.saveDay(picked.day)

        // ④ 摘要（仅用于通知文案；不参与任何判定）
        let day = picked.day
        let instCodes = Set(day.seats.filter { $0.side == "BUY" && $0.isInstitution }
                                    .map(\.code))
        let top = day.records.max { $0.netAmount < $1.netAmount }
        let elapsed = Date().timeIntervalSince(started)
        // ⚠ 收盘后各 Job（龙虎榜/资金流/涨停池/板块热度）事件名**各自独立**，
        //   不要共用 `daily_ok` —— 它与"日K"毫无关系，诊断页按事件筛选会误导排障。
        DataSources.logDataSource("lhb", "lhb_ok",
                      "\(day.date) 落库 上榜 \(saved.records) 条 / 席位 \(saved.seats) 条"
                        + "（机构买入 \(instCodes.count) 只"
                        + (picked.backfilled ? "，回看补漏" : "")
                        + "，耗时 \(String(format: "%.1f", elapsed))s）")

        return [
            "status": "ok",
            "date": day.date,
            "backfilled": picked.backfilled,
            "records": saved.records,
            "seats": saved.seats,
            "inst_count": instCodes.count,
            "top_name": top?.name ?? "",
            "top_code": top?.code ?? "",
            "top_net": top?.netAmount ?? 0,
            "elapsed_sec": elapsed,
        ]
    }

    // MARK: - 取哪一天

    /// 今天优先；今天抓不到（尚未发布 / 条数不足）时回看窗口内补"库里还没有"的最近一天。
    ///
    /// - Returns: `nil` 表示今天与回看窗口内都没有可落库的数据（调用方抛可重试失败）。
    static func pickDay(today: String) -> (day: LhbDay, backfilled: Bool)? {
        if let day = LhbSource.fetch(today), day.date == today {
            return (day, false)
        }
        for d in recentDays(before: today, count: lookbackDays) {
            // 已经有了就跳过：既省 3 次请求，也**不会**用旧数据覆盖已落好的那天
            if LhbStore.count(date: d) > 0 { continue }
            if let day = LhbSource.fetch(d), day.date == d {
                DataSources.logDataSource("lhb", "backfill",
                              "今天（\(today)）尚未发布 → 补上 \(d)")
                return (day, true)
            }
        }
        return nil
    }

    /// `day` 之前的最近 `count` 个**非周末**自然日（新→旧）。
    ///
    /// ⚠ 实现已下沉到 `ChinaTime.recentWeekdays`（**单一实现**）：涨停池
    /// （`LimitUpPoolJob`）要用同一套口径，两处各写一份必然漂移。
    /// 本方法保留为薄壳，是为了不动既有调用方与单测。
    static func recentDays(before day: String, count: Int) -> [String] {
        ChinaTime.recentWeekdays(before: day, count: count)
    }
}
