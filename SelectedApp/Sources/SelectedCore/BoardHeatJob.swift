import Foundation

/// 板块热度的**收盘后日更任务**（调度器入口）
///
/// ## 为什么单独一个 job
/// 与 `FundFlowJob` / `LhbJob` / `LimitUpPoolJob` 同一理由：收盘后的**时点数据**抓取，
/// 独立任务 ⇒ 独立状态 ⇒ 它挂了不会把复盘/迭代带成红色。**不进总分**。
///
/// ## 为什么必须落库
/// 板块行情是**当日截面**，源只给"今天"。今天不记下来，以后永远取不回历史名次
/// （对比筹码分布可从日K重算，不落库）。
///
/// ## ⚠ 时点
/// 板块涨跌在 15:00 收盘时定稿，排在 **15:10**：复盘（15:05）之后、涨停统计（15:15）之前。
/// 不需要像龙虎榜那样等 17:30（那是交易所发布延迟，板块行情是行情自身状态）。
///
/// ## ⚠ 没有回看补漏
/// `clist` 板块域**不接受 date 参数**（带不带都只回最新截面）——
/// 今天没开着，这天就永久缺失。不假装能补，缺就是缺。
///
/// ## ⚠ 每次都重抓覆盖（不做"今天已有就跳过"）
/// 整日重插，**最后一次抓到的是最新状态**。若做"已有即跳过"，用户上午手动点「更新」
/// 存了盘中快照后，15:10 的调度任务会跳过 → **盘中值被永久当成收盘定稿**；
/// 重抓覆盖让 15:10 天然纠正它。
public enum BoardHeatJob {

    /// 一天板块数**下界**（实测 496 个；与 `BoardHeatSource.minBoards` 同值，
    /// 落库前再校验一次完整性，拦住半截数据）。
    public static let minRecords = BoardHeatSource.minBoards

    /// 失败原因。
    ///
    /// ⚠ 这里的文案**只许用于调度器重试路径**（`Scheduler` 取 `errorDescription`
    /// 当重试原因，25 分钟窗口内它**真会**自动重试，"稍后重试"成立）。
    /// **手动「更新」按钮不许直接复用这份文案** —— 手动点击没有任何东西会自动重试，
    /// 写"稍后重试"就是骗人。手动路径自己出文案，见 `Store.refreshBoardHeat`。
    public enum Failure: LocalizedError {
        case notReady(date: String)
        case fetchFailed(String)

        public var errorDescription: String? {
            switch self {
            case .notReady(let date):
                return "东财板块行情尚未返回 \(date) 的数据（或条数不足），调度器将在窗口内自动重试"
            case .fetchFailed(let why):
                return "板块行情取数失败：\(why)"
            }
        }
    }

    /// 收盘后跑一次：抓当日截面 → 落库（**每次都重抓覆盖**，见下）。
    ///
    /// - Returns: 结果字典。`status` 取 `ok` / `not_trading_day`
    ///   （后者由 `Scheduler.finish` 识别为"标记完成但不通知"）。
    /// - Throws: `Failure`（可重试）
    /// - Parameter shouldStop: 取消检查闭包（审查 #12）：`Scheduler.stop()` 置位取消盒后，
    ///   取数完成的一刻**不再落库**（本任务整天删重插，半路写一半比不写更糟）。
    public static func run(shouldStop: () -> Bool = { false }) throws -> [String: Any] {
        let started = Date()
        let today = ChinaTime.day()

        // ① 交易日闸门：休市没有"今天的板块行情"可抓。
        // ⚠ 这里**不能用 fail-open 的 `isTradingDay()`**（2026-10-16 审查 B5-5）：
        //   指数行情取不到时它会返回 `(true, "工作日(默认)")`，而本任务的落库是
        //   **整天删重插**（`saveDay`）且 `BoardHeatSource` 的行**没有任何日期权威**
        //   （只把 `runDate()` 盖上去）。于是"指数请求被限流 + 源返回上一交易日截面"
        //   这一组合会把**上一交易日**的 496 个板块盖章成今天、覆盖库里原有的当日行，
        //   还被标记任务完成 + 弹「板块热度已更新（496 个板块）」——
        //    phantom 日与真数据在界面上完全一样。
        //   本任务没有回看补漏，但**缺一天是可见的**（诊断页显示无记录），
        //   而**错一天是不可见的**：宁缺勿错，与资金流 `authoritativeTradeDate` 同一纪律。
        switch DataSources.tradingDayVerdict() {
        case .trading:
            break
        case .closed(let reason):
            DataSources.logDataSource("boardheat", "skip_not_trading_day", "非交易日（\(reason)）→ 跳过")
            return ["status": "not_trading_day", "trading_day_reason": reason, "date": today]
        case .unknown(let reason):
            DataSources.logDataSource("boardheat", "skip_day_unconfirmed",
                                      "交易日无从确认（\(reason)；指数行情不可得）"
                                      + "→ 本日不抓取：源无日期字段，盖章可能是上一交易日")
            return ["status": "not_trading_day", "trading_day_reason": "无从确认（\(reason)）",
                    "date": today, "day_unconfirmed": true]
        }


        // ② 取数（源只给当天截面，见类注释"没有回看补漏"）
        guard let rows = BoardHeatSource.fetchAll(), rows.count >= minRecords else {
            throw Failure.notReady(date: today)
        }

        // ③ 落库（整日重插，幂等）。盖章成 `today`：`fetchAll` 内部用 `runDate()`，
        //    回放/夹具模式下两者可能不同 → 以任务日为权威。
        let stamped = rows.map {
            BoardHeatPoint(date: today, boardCode: $0.boardCode, boardName: $0.boardName,
                           index: $0.index, changePct: $0.changePct, amount: $0.amount,
                           turnoverRate: $0.turnoverRate, totalCap: $0.totalCap,
                           mainNet: $0.mainNet, upCount: $0.upCount, downCount: $0.downCount,
                           flatCount: $0.flatCount, leaderName: $0.leaderName,
                           leaderCode: $0.leaderCode, leaderMarket: $0.leaderMarket)
        }
        // 取消检查（审查 #12）：退出时不再写库
        if shouldStop() { return ["status": "cancelled", "date": today] }
        let saved: Int
        do {
            saved = try BoardHeatStore.saveDay(date: today, rows: stamped,
                                               at: PhaseStore.nowStamp())
        } catch {
            throw Failure.fetchFailed("落库失败：\(error)")
        }

        // ④ 摘要（仅用于通知文案；不参与任何判定）
        let top = stamped.max { $0.changePct < $1.changePct }
        let inflow = stamped.filter { $0.mainNet > 0 }.count
        let elapsed = Date().timeIntervalSince(started)
        DataSources.logDataSource("boardheat", "boardheat_ok",
                      "\(today) 落库 \(saved) 个板块（领涨 "
                        + "\(top?.boardName ?? "") \(String(format: "%.2f", top?.changePct ?? 0))%，"
                        + "主力净流入 \(inflow) 个，耗时 \(String(format: "%.1f", elapsed))s）")

        return [
            "status": "ok",
            "date": today,
            "records": saved,
            "top_name": top?.boardName ?? "",
            "top_pct": top?.changePct ?? 0,
            "inflow_count": inflow,
            "elapsed_sec": elapsed,
        ]
    }
}
