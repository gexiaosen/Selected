import Foundation
import SwiftUI
import Observation
import SelectedCore

/// 回放 / 下载的**取消标志**。
///
/// **为什么必须是独立对象、不能用 Store 上的 `@Observable` 属性**：
/// 取消标志由**后台线程**轮询（`HistoryReplayJob.downloadBars` 的 `shouldStop` 在
/// `concurrentPerform` 的每个 worker 里被调用），而 `Store` 是 `@MainActor` ——
/// 从后台线程读它的属性是数据竞争（Swift 6 会直接拒绝编译）。
/// 所以用一个自持 `NSLock` 的 `@unchecked Sendable` 盒子
/// （与 `HistoryReplayMode.Box` / `DataSources.KLineCache` 同一手法）。
///
/// ⚠ `nonisolated`：`Selected` target **默认 MainActor 隔离**（`Package.swift` 的 `defaultIsolation`），
///   而本类的**全部意义就是给后台线程用** —— 不标 `nonisolated` 会被默认隔离成 MainActor，
///   `Task.detached` 里读它直接编译失败。
nonisolated final class ReplayCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return flag
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        flag = true
    }

    /// 开始新任务前复位。⚠ 不复位的话，上一次点过"取消"会让新任务**立刻自行中断**
    /// （表现为"点了开始但什么都没发生"）。
    func reset() {
        lock.lock(); defer { lock.unlock() }
        flag = false
    }
}

/// 进度中转：**后台线程 → 主 actor**。
///
/// **为什么需要它**：`HistoryReplayJob.downloadBars` 的 `onProgress` 是 `@Sendable`，
/// 而目标状态在 `@MainActor` 的 `Store` 上。直接在里面写
/// `Task { @MainActor [weak self] in … }` 会被 Swift 6 拒绝
/// （内层闭包重新捕获了外层那个 `weak var self`）。
/// 用一个自持锁的盒子把"目标是个 `@MainActor` 闭包"这件事写进类型里，两层都干净。
///
/// ⚠ `nonisolated`：同 `ReplayCancelFlag` —— 本类供**后台线程调用**（`onProgress` 是 `@Sendable`），
///   必须显式 `nonisolated` 才不被默认隔离成 MainActor。
///   ⚠ 内部那个 `Task { @MainActor in h(…) }` 是跨回主 actor 的**唯一**通道，别删。
nonisolated final class ReplayProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@MainActor (Int, Int) -> Void)?

    func set(_ h: @escaping @MainActor (Int, Int) -> Void) {
        lock.lock(); defer { lock.unlock() }
        handler = h
    }

    func report(_ done: Int, _ total: Int) {
        lock.lock()
        let h = handler
        lock.unlock()
        guard let h else { return }
        Task { @MainActor in h(done, total) }
    }
}

// MARK: - 历史回放

/// 界面侧的编排：下载缓存 → 逐日回放 → 展示结果。
///
/// ## ⚠ 口径必须先说清楚
/// 回放只能做到**收盘价口径**：live 的选股价是 14:00/14:30/14:50 的**盘中价**，
/// 而分时数据不可回溯（新浪 5 分钟线只覆盖最近约 5 个交易日）。所以
/// 选股价 = 收盘价、量比 = 全日口径、尾盘分时结构整块跳过。
/// **回放样本与实盘样本口径不同**，调优器默认不混用（`reviews.scan_mode`）。
/// 完整论证见 `docs/specs/README.md`。
extension Store {

    /// 缓存概况是否正在读取（`>0` = 有读取在飞）
    var replayCacheLoading: Bool { replayCacheLoadsInFlight > 0 }

    /// 刷新缓存概况（设置页打开时调一次；下载/回放结束后再调）
    ///
    /// ⚠ **必须放后台**：`HistoryBarStore.stats()` 是 `daily_bars` 的**全表扫**
    /// （`COUNT(DISTINCT code)` + `COUNT(*)`），缓存灌满一年后单次以秒计、且随缓存增长线性变大
    /// —— 放主线程就是每次打开设置页硬卡一下。
    ///
    /// `HistoryBarStore` 自持连接 + 串行队列，三个读都可以从任意线程调，所以这里只把结果搬回主 actor。
    ///
    /// 副作用：界面会先显示"读取中…"再变成真实数字 —— 比卡顿好，
    /// 也比"先显示缓存为空"好（那是**错的**状态，不是空状态）。
    func refreshReplayCache() {
        replayCacheLoadsInFlight += 1
        Task.detached(priority: .utility) {
            let stats = HistoryBarStore.stats()
            let covered = HistoryBarStore.coverage().count
            let days = HistoryBarStore.indexDays(symbol: HistoryReplayJob.indexSymbols[0]).count
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.replayCache = stats
                self.replayCoveredCodes = covered
                self.replayIndexDayCount = days
                self.replayCacheLoadsInFlight -= 1
            }
        }
    }

    /// 取消正在跑的下载 / 回放（后台任务在下一个检查点收手）
    func cancelReplay() {
        replayCancel.cancel()
        ToastCenter.shared.show("已请求取消，正在收尾（已下载/已回放的部分会保留）", style: .info)
    }

    /// 释放回放的**逐日结果**（离开设置页时调）。
    ///
    /// ⚠ `replayResults` 挂在 `Store.shared`（**进程级**），不主动释放就一直驻留
    ///   （整份逐日结果：每天一条 `DayResult`，含明细）。
    /// ⚠ 回放**正在跑**时不能清（会丢掉进行中的结果）⇒ 由调用方判 `replayRunningDay == nil`；
    ///   本函数自己也再挡一层。
    func clearReplayResults() {
        guard replayRunningDay == nil else { return }
        replayResults = []
        replaySummary = nil
    }

    /// 清空日K缓存（缓存可随时删掉重下；清空后回放会报"交易日历缺失"）
    ///
    /// ⚠ 必须在**后台**删（2026-10-16 审查 B3）：`deleteAll` 是 `DELETE FROM daily_bars`
    ///   + 指数表 + coverage 表三句，生产库实测 143MB / 上百万行，
    ///   而 `HistoryBarStore.deleteAll()` 内部是串行队列的**同步** `write` ——
    ///   原先直接在 `@MainActor` 里调用，等于**把主线程按住直到删完**（数秒起），
    ///   期间调度 tick、自选 5 秒轮询、菜单栏一起卡住。
    func clearReplayCache() {
        let key = "replayClear"
        guard !busy.contains(key), !HistoryReplayMode.isBusy else { return }
        busy.insert(key)
        // 先给界面"正在清"的反馈，再做重活
        ToastCenter.shared.show("正在清空日K缓存…", style: .info)
        Task.detached(priority: .utility) {
            let failure: String?
            do {
                try HistoryBarStore.deleteAll()
                failure = nil
            } catch {
                failure = String(describing: error)
            }
            await MainActor.run {
                self.busy.remove(key)
                if let failure {
                    self.lastError = "清空缓存失败：\(failure)"
                    self.lastErrorKey = key
                    ToastCenter.shared.show("清空缓存失败", style: .error)
                } else {
                    self.refreshReplayCache()
                    self.replayResults = []
                    self.replaySummary = nil
                    ToastCenter.shared.show("日K缓存已清空")
                }
            }

        }
    }

    /// 下载日K缓存（**可取消、可续传**）。
    ///
    /// 先下指数（交易日历的唯一来源 —— 没有它一天都回放不了），再下全市场个股。
    /// 已按同一窗口请求过的票一次请求都不发（`bar_coverage`）。
    ///
    /// ⚠ 首次全市场约 **5000 请求 / 10–20 分钟**，必须能中断再续。
    func downloadReplayCache(beg: String, end: String) {
        let key = "replayDownload"
        guard !busy.contains(key) else { return }
        guard !HistoryReplayMode.isBusy else {
            lastError = "历史回放进行中，暂不可下载缓存"
            lastErrorKey = key
            ToastCenter.shared.show(lastError ?? "下载未开始", style: .error)
            return
        }
        guard beg <= end else {
            lastError = "起始日（\(beg)）不能晚于结束日（\(end)）"
            lastErrorKey = key
            ToastCenter.shared.show("日期区间不合法", style: .warning)
            return
        }
        busy.insert(key)
        replayCancel.reset()
        replayDownloadDone = 0
        replayDownloadTotal = 0
        lastError = nil
        lastErrorKey = nil
        let cancel = replayCancel
        let relay = replayProgressRelay
        relay.set { [weak self] done, total in
            self?.replayDownloadDone = done
            self?.replayDownloadTotal = total
        }

        Task.detached(priority: .utility) { [weak self] in
            let idx = HistoryReplayJob.downloadIndex(beg: beg, end: end)
            let codes = DataSources.fetchStockList().compactMap { $0["code"] as? String }
            let bars = HistoryReplayJob.downloadBars(
                codes: codes, beg: beg, end: end,
                shouldStop: { cancel.isCancelled },
                onProgress: { done, total in relay.report(done, total) })
            let summary = "指数 \(idx.summary)\n个股 \(bars.summary)"
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.busy.remove(key)
                self.replayDownloadDone = 0
                self.replayDownloadTotal = 0
                self.refreshReplayCache()
                self.lastError = nil
                self.lastErrorKey = nil
                if bars.stopped {
                    ToastCenter.shared.show("下载已取消（可再次点击继续，已下载的不会重下）",
                                            style: .info)
                } else if bars.failed > 0 || bars.noData > 0 {
                    // ⚠ 如实报出来，不吞：noData 的票**不会**记 bar_coverage，
                    //   所以下次会重试（这是有意的 —— 见 HistoryReplayJob.downloadBars 注释）
                    ToastCenter.shared.show("下载完成，但有 \(bars.failed) 只失败 / "
                                            + "\(bars.noData) 只无数据（下次会重试）", style: .warning)
                } else {
                    ToastCenter.shared.show("日K缓存下载完成")
                }
                self.replaySummary = summary
            }
        }
    }

    /// 回放 `[beg, end]` 区间内的**可回放**交易日（收盘价口径）。
    ///
    /// 已有实盘数据的日期会被整日跳过（隔离规则：不覆盖 live 数据），
    /// 跳过的天数会写进摘要 —— **不静默省略**。
    func runReplay(beg: String, end: String) {
        let key = "replay"
        guard !busy.contains(key) else { return }
        guard !HistoryReplayMode.isBusy else {
            lastError = "已有回放正在进行"
            lastErrorKey = key
            ToastCenter.shared.show(lastError ?? "回放未开始", style: .error)
            return
        }
        guard let params = ParamStore.shared.activeParams() else {
            lastError = "激活参数不可读（数据库与随包文件都读不到），回放未执行"
            lastErrorKey = key
            ToastCenter.shared.show("回放未执行：激活参数不可读", style: .error)
            return
        }
        let version = ParamStore.shared.activeName()
        busy.insert(key)
        replayCancel.reset()
        replayResults = []
        replaySummary = nil
        replayProgressIndex = 0
        replayProgressTotal = 0
        replayRunningDay = nil
        lastError = nil
        lastErrorKey = nil
        let cancel = replayCancel

        Task.detached(priority: .utility) { [weak self] in
            let calDays = HistoryBarStore.indexDays(symbol: HistoryReplayJob.indexSymbols[0])
            // 已有轮次的日期 → 预筛掉。**但要数出来告诉用户**，
            // 否则"我明明选了 30 天，怎么只回放了 3 天"无从解释。
            let existing = Set(PhaseStore.shared.query("SELECT DISTINCT date FROM scan_rounds")
                .compactMap { $0["date"] as? String })
            let inRange = calDays.filter { $0 >= beg && $0 <= end }
            let days = HistoryReplayJob.selectableDays(candidates: inRange,
                                                       calendarDays: calDays,
                                                       existing: existing)
            let skippedExisting = inRange.filter { existing.contains($0) }.count

            var results: [HistoryReplayJob.DayResult] = []
            var cancelled = false
            for (i, day) in days.enumerated() {
                if cancel.isCancelled { cancelled = true; break }
                let idx = i + 1
                await MainActor.run { [weak self] in
                    self?.replayRunningDay = day
                    self?.replayProgressIndex = idx
                    self?.replayProgressTotal = days.count
                }
                let r: HistoryReplayJob.DayResult
                do {
                    r = try HistoryReplayJob.replayOne(day: day, params: params,
                                                       paramVersion: version)
                } catch {
                    r = HistoryReplayJob.DayResult.failed(day: day, detail: "\(error)")
                }
                results.append(r)
            }

            let okCount = results.filter(\.ok).count
            let insuff = results.filter { $0.status == HistoryReplayJob.Status.dataInsufficient }.count
            let failed = results.filter { $0.status == HistoryReplayJob.Status.failed }.count
            let summary = "区间 \(beg) ~ \(end)：候选 \(inRange.count) 天，"
                + "其中 \(skippedExisting) 天已有实盘数据（跳过）、"
                + "\(days.count - results.count) 天未跑完\n"
                + "回放 \(results.count) 天 → 成功 \(okCount) / 数据不足 \(insuff) / 失败 \(failed)"
                + (cancelled ? "\n（已被取消，已完成的保留在库里）" : "")

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.busy.remove(key)
                self.replayRunningDay = nil
                self.replayProgressTotal = 0
                self.replayResults = results
                self.replaySummary = summary
                if failed > 0 {
                    self.lastError = "回放有 \(failed) 天失败（见下方逐日结果）"
                    self.lastErrorKey = key
                }
                ToastCenter.shared.show("回放结束：成功 \(okCount) / \(results.count) 天")
                // 回放会往库里写轮次/复盘，刷新全局视图
                self.refresh()
            }
        }
    }

    /// 当前「调优池是否纳入回放样本」的**引擎侧默认值**（工厂参数 `iterate.include_replay`）。
    /// 设置页的开关（`@AppStorage("tuneIncludeReplay")`）会覆盖它 ——
    /// 与 `phases` 同一模式：工厂参数是默认，实际生效值由设置页单独管。
    var tuneIncludeReplayFactoryDefault: Bool {
        guard let iterate = ParamStore.shared.activeParams()?["iterate"] as? [String: Any] else {
            return false
        }
        return PredictRules.bool(iterate["include_replay"]) ?? false
    }
}
