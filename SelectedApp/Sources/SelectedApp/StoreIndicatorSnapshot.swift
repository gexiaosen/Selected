import Foundation
import Observation
import SelectedCore

/// 指标快照的**加载与手动触发**。
///
/// ## 为什么单独一个 extension
/// 与 `StoreBoardHeat` 同一思路：一次查完 → 收进存储属性 → View 只读不查。
/// 这里只收**库级新鲜度**（最新日 / 覆盖数 / 更新时刻）—— 具体某指标的排行
/// 由页面按需调 `IndicatorSnapshotStore.ranking`（全市场排行不进全局状态，
/// 否则每次 refresh 都拖一条 36 列里的一列 ORDER BY，白花时间）。
///
/// ## 手动「重算」的语义（与板块热度同纪律）
/// 每次都整日重插覆盖：盘中点 = 盘中快照，15:25 调度 = 收盘定稿。
/// 历史口径不重算（今日 bar 只能由**今天**的收盘行情合成，历史日重算=拿今天数据冒充历史）；
/// 回放进行中不重算（历史库正被写入，窗口读到半截）。
extension Store {

    /// 加载快照库新鲜度（由 `refresh()` 调用）
    func loadIndicatorSnapshot() {
        indicatorSnapshotLatestDay = IndicatorSnapshotStore.latestDay()
        if let day = indicatorSnapshotLatestDay {
            indicatorSnapshotCoveredCount = IndicatorSnapshotStore.count(on: day)
        } else {
            indicatorSnapshotCoveredCount = 0
        }
        indicatorSnapshotFetchedAt = IndicatorSnapshotStore.lastFetchedAt()
        // 跨日缓存失效：换了 viewDate 才重查
        indicatorSnapshotPrevDayFor = nil
        indicatorSnapshotPrevDayCache = nil
        // 每次刷新都推进版本号：重算前后覆盖数可能一模一样，靠它通知页面重载
        indicatorSnapshotRevision &+= 1
    }

    /// viewDate 的**前一**有快照日（判"无前日 ⇒ 金叉类规则算不出"）。
    ///
    /// ⚠ 带按日缓存（2026-10-16 审查 B3）：`IndicatorSnapshotStore.previousDay(of:)`
    ///   内部是 `days()` = `SELECT DISTINCT trade_date … ORDER BY …`，
    ///   快照每天约 5000 行、积累数月后是几十万行的扫描；
    ///   而调用点在 `IndicatorScreenerView` 的**结果卡 body** 里（每次重渲染都读），
    ///   违反同文件既有的「视图 body 不查库」纪律。
    func indicatorSnapshotPreviousDay(of day: String) -> String? {
        if indicatorSnapshotPrevDayFor == day { return indicatorSnapshotPrevDayCache }
        let v = IndicatorSnapshotStore.previousDay(of: day)
        indicatorSnapshotPrevDayFor = day
        indicatorSnapshotPrevDayCache = v
        return v
    }


    /// 手动重算今日指标快照（与调度任务同一份 `IndicatorSnapshotJob.run()`）。
    func refreshIndicatorSnapshot() {
        guard !blockedByScheduler("重算指标快照") else { return }
        guard !isHistorical else {
            ToastCenter.shared.show("历史模式下不可重算指标快照（今日 bar 只能由当日收盘行情合成），请先回到最新交易日",
                                    style: .warning)
            return
        }
        if HistoryReplayMode.isBusy {
            ToastCenter.shared.show("历史回放进行中，暂不可重算指标快照", style: .warning)
            return
        }
        let key = "indsnap"
        guard !busy.contains(key) else { return }
        busy.insert(key)
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome: (JSONValue?, String?) = {
                do { return (JSONValue(try IndicatorSnapshotJob.run()), nil) }
                catch { return (nil, (error as? LocalizedError)?.errorDescription
                                ?? String(describing: error)) }
            }()
            await MainActor.run {
                guard let self else { return }
                self.busy.remove(key)
                guard let json = outcome.0 else {
                    // ⚠ 手动失败走**钉住的 error toast**、不写 lastError（横幅只留库级故障）。
                    // ⚠ 文案**自己出、不复用 Job.Failure 的**：Job 那份是调度路径写的
                    //   （补跑窗口会自动重试）；手动点击没有任何东西替你重试，照抄会误导。
                    ToastCenter.shared.show("指标快照重算失败：\(outcome.1 ?? "未知")", style: .error)
                    return
                }
                if json["status"].string == "not_trading_day" {
                    let why = json["trading_day_reason"].string ?? "休市"
                    ToastCenter.shared.show("今日非交易日（\(why)），无收盘行情可算", style: .warning)
                    return
                }
                ToastCenter.shared.show("指标快照已重算（\(json["saved"].int ?? 0) 只）")
                self.refresh()
            }
        }
    }
}
