import Foundation

/// 资金流向的**收盘后日更任务**（调度器入口）。
///
/// ## 为什么单独一个 job，而不是塞进 `PhaseReview`
///
/// 见 `docs/specs/README.md`：
///   · **不给扫描轮次加失败点** —— 三轮扫描是实时行情任务，资金流是收盘后时点数据，
///     两者失败互不影响。独立任务 ⇒ 独立状态 ⇒ 资金流挂了不会把 `review` / `iterate`
///     带成红色。
///   · **不进总分** —— 本文件不产出任何参与评分/判定的字段。
///
/// ## 为什么必须落库
///
/// 快照接口只给**当日**全市场一屏，历史时点数据一旦不记下来就**永久取不回来**
/// （对比：筹码分布可以从日K重算，所以它不落库）。故这里 `FundFlowStore.save`。
///
/// ## 幂等与可重跑
///
/// 主键 `(trade_date, code)` + `INSERT OR REPLACE` ⇒ 同一天跑几次结果一样。
/// 且**日期取新浪给的权威交易日**（不是墙上时钟）—— 见 `FundFlowSource` 文件头。
public enum FundFlowJob {

    /// 失败原因（`LocalizedError` → `Scheduler` 会取 `errorDescription` 作为重试原因文案）
    public enum Failure: LocalizedError {
        /// 新浪还没更新到今日（可重试：稍后重跑即可）
        case notReady(latest: String, today: String)
        /// 取数失败（网络 / 解析 / 覆盖率不足）
        case fetchFailed(String)

        public var errorDescription: String? {
            switch self {
            case .notReady(let latest, let today):
                // 本 Job 的"跳过"走**返回值** `status=not_trading_day`（不抛错，见下面
                //   `guard isTrading else`），所以这条文案不受任何按文案判状态的逻辑约束。
                return "新浪资金流尚未更新到今日（最新 \(latest)，期望 \(today)），稍后重试"
            case .fetchFailed(let why):
                return "资金流取数失败：\(why)"
            }
        }
    }

    /// 收盘后跑一次：抓全市场快照 → 按 `securities` 过滤 → 落库。
    ///
    /// - Returns: 可直接交给 `JSONValue` / 通知文案的结果字典。
    ///   `status` 取 `ok` / `not_trading_day`（后者由 `Scheduler.finish` 识别为
    ///   "标记完成但不通知"，与扫描路径同一约定）。
    /// - Throws: `Failure`（可重试）
    /// - Parameter shouldStop: 取消检查闭包（审查 #12）：`Scheduler.stop()` 置位取消盒后，
    ///   取数完成的一刻**不再落库**（取数本身是单次 HTTP，同步调用中断不了）。
    public static func run(shouldStop: () -> Bool = { false }) throws -> [String: Any] {
        let started = Date()
        let today = ChinaTime.day()

        // ① 交易日闸门：休市没有"今天的资金流"可抓。
        //    走既有 `DataSources.isTradingDay()`（它已经处理了节假日与"行情未更新"），
        //    不自己判周末 —— 否则调休日会误抓、把上一交易日的数据写在今天。
        let (isTrading, reason) = DataSources.isTradingDay()
        guard isTrading else {
            DataSources.logDataSource("fundflow", "skip_not_trading_day", "非交易日（\(reason)）→ 跳过")
            return ["status": "not_trading_day", "trading_day_reason": reason, "date": today]
        }

        // ② 抓取（内部已做权威日期 / 覆盖率两道闸门）
        let codes = expectedCodes()
        guard let day = FundFlowSource.fetchDaily(expectedCodes: codes) else {
            throw Failure.fetchFailed("快照为空或覆盖率不足（应覆盖 \(codes.count) 只）")
        }

        // ③ 日期闸门：新浪的最新交易日必须**就是今天**。
        //    不是今天 = 新浪尚未刷新（收盘后几分钟内很常见）→ 可重试，
        //    绝不"用昨天的数据写今天的日期"。
        // ⚠ 这一支原先**不写日志**（①②的每条失败路径都写，唯独这里抛错前不写）
        //   ⇒ 调度状态里的文案又被通用重试文案覆盖，事后从库里完全查不出"今天为什么没落数据"。
        //   2026-11-02 排查资金流天天失败时踩实：库里 `fundflow` 这个 source 一条记录都没有。
        guard day.date == today else {
            DataSources.logDataSource("fundflow", "not_ready",
                          "锚点权威交易日 \(day.date) != 今日 \(today) → 新浪尚未发布当日行，本次不落库"
                            + "（快照已取到 \(day.points.count) 行，覆盖率闸门已过）")
            throw Failure.notReady(latest: day.date, today: today)
        }

        // ④ 落库（幂等）—— 取消检查（审查 #12）：退出时不再写库
        if shouldStop() { return ["status": "cancelled", "date": today] }
        let saved = try FundFlowStore.save(day.points)

        // ⑤ 摘要（仅用于通知文案；不参与任何判定）
        let inflow = day.points.filter { $0.mainNet > 0 }
        let top = day.points.max { $0.mainNet < $1.mainNet }
        let elapsed = Date().timeIntervalSince(started)
        DataSources.logDataSource("fundflow", "fundflow_ok",
                      "\(day.date) 落库 \(saved) 只（净流入 \(inflow.count) 只，"
                        + "耗时 \(String(format: "%.1f", elapsed))s）")

        return [
            "status": "ok",
            "date": day.date,
            "saved": saved,
            "expected": codes.count,
            "inflow_count": inflow.count,
            "top_name": top?.name ?? "",
            "top_code": top?.code ?? "",
            "top_main_net": top?.mainNet ?? 0,
            "elapsed_sec": elapsed,
        ]
    }

    /// 应被覆盖的标的集合（`securities` 全表）。
    ///
    /// ⚠ 用 `securities` 而不是"快照里出现的代码"：后者等于拿结果当基准，
    /// 覆盖率永远是 1.0，**"抓漏了"永远检测不出来**。
    /// 也顺带把北交所 / ETF / 债券挡在外面（它们不在 `securities` 里）。
    ///
    /// ⚠ 走 `FundFlowStore.securityCodes()`（它自持只读连接）——
    /// **不是** `SQLiteReader.shared`：本方法在后台任务里被调用，而那个共享连接
    /// 是主线程专用的（跨线程并发用同一连接会 SIGSEGV）。
    static func expectedCodes() -> Set<String> {
        FundFlowStore.securityCodes()
    }
}
