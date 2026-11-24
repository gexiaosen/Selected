import Foundation

/// 历史回放**编排**
///
/// 三件事：① 批量下载日K（断点续传）② 重建某历史日的全市场快照并跑一轮扫描
/// ③ 跑预判 + 复盘，把调优标签（`stock_outcomes`）一起产出，并给该日的复盘打上口径标记。
///
/// 完整论证见 `docs/specs/README.md`。
///
/// ## ⚠ 最容易搞错的一点：**两个不同的「当日」**
/// 阶段排期决定了「D 的复盘在 D+1 早上跑」（`ScheduleTimes.swift:34-50`）：
///   · `predict` 在 D+1 读 D-1 的选股 → **D 的预判，运行日是 D+1**
///   · `review`  在 D+1 复盘 D     → **D 的复盘，运行日是 D+1**
///
/// 所以回放 D 必须是**两段**，而不是一段：
///
/// | 阶段 | `runDate()` | 为什么 |
/// |------|------------|--------|
/// | 扫描（选股） | **D** | 选股价、行情快照、大盘环境都必须是 D 的 |
/// | 预判 + 复盘   | **D+1** | 复盘的「目标交易日」= `nextTradingDay(D)` = D+1，它的 open/high/close 要从 D+1 取 |
///
/// 若整段都用 D：复盘的 `historicalQuotes(targetDay: D+1)` 会去查 D+1 的 bar，而
/// `fetchDailyKline` 在回放模式下只给到 D → **全部标的查不到目标日行情** →
/// `stock_outcomes` 全是 NULL → 调优标签整批为空。而且不报错，只是"这批样本没标签"。
///
/// ## ⚠ 隔离：只写库里还没有该日数据的日期
/// 同一天已有任何 `scan_rounds` 行 → **整日跳过**（不做覆盖）。这条同时消掉了
/// 「重跑 → `picks` 覆盖 → `sel_price` 漂移 → 已算好的 `close_profit` 与新基准不再可比」
/// 这条污染链 —— live 数据永不被回放改写。
///
/// ## ⚠ 回放期间**必须独占**
/// 回放模式（`HistoryReplayMode`）是 `DataSources` 的**进程级开关**，期间任何并发取数都会
/// 拿到回放日的数据。所以：本模块拒绝嵌套；`Scheduler` / 手动扫描 / 阶段重算在回放期间一律拒绝。
public enum HistoryReplayJob {

    // MARK: - 常量

    /// 下载起始日。东财最早只给到约 2022-01-04，给个更早的日期让它自己截断。
    ///
    /// ⚠ 这是个**可以改**的值，但改小（想多要几年）会让 `bar_coverage` 全部判为"未覆盖"
    /// → 下次整批重下。这是安全方向，见 `HistoryBarStore.Coverage` 的注释。
    public static let defaultBeg = "2020-01-01"

    /// 指数符号（交易日历的唯一来源）。回放**必须**下载它，否则一天都跑不了。
    public static let indexSymbols = ["sh000001"]

    /// 回放轮的 slot：用尾盘轮次 3（隔离规则保证该日没有别的轮次）。
    ///
    /// ⚠ slot **必须是 3**：`SignalClassifier` / `PhasePredict` 按 slot 3 判"尾盘信号"。
    public static let replaySlot = 3

    /// 回放轮的展示标签 —— **不写"14:50"**：回放的价是**收盘价**，
    /// 标成 14:50 会让界面上看起来像一轮真实的尾盘选股（正是 `scan_mode` 要防的那种混淆）。
    public static let replaySlotLabel = "收盘(回放)"

    /// 复盘口径标记（写进 `reviews.scan_mode`）
    public static let scanModeReplay = "replay_close"
    /// 实盘口径标记（`reviews.scan_mode` 的 DEFAULT 值）
    public static let scanModeLive = "live"

    /// 默认并发。东财单 IP 可承受，再高收益递减且容易触发限流。
    public static let defaultConcurrency = 6

    /// 失败码最多记多少个（诊断用，不无限增长 —— 5000 只全挂时不该产出 5000 行）
    public static let maxRecordedFailures = 20

    // MARK: - 错误

    public struct ReplayError: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    // MARK: - 下载报告

    public struct DownloadReport: Equatable, Sendable {
        /// 本次**实际发出请求**的票数（已覆盖的已剔除）
        public var requested = 0
        /// 已按该窗口请求过 → 跳过（断点续传省下的）
        public var skipped = 0
        public var succeeded = 0
        /// 请求成功但**一根 bar 都没有**（退市 / 停牌 / 代码无效 / 网络失败 —— 这两种无法区分）
        public var noData = 0
        /// 落库抛错的
        public var failed = 0
        /// 实际写入的行数
        public var bars = 0
        /// 被 `shouldStop` 提前中断（**批粒度**，见 `downloadBars`）
        public var stopped = false
        public var elapsedSec: Double = 0
        /// 前 `maxRecordedFailures` 个问题代码
        public var problems: [String] = []

        public var summary: String {
            let head = "请求 \(requested) 只（跳过已缓存 \(skipped)）→ 成功 \(succeeded)"
                + " / 无数据 \(noData) / 失败 \(failed)，写入 \(bars) 行"
            let t = String(format: "耗时 %.1fs", elapsedSec)
            // ⚠ 强调用「」不用 `**`：`summary` 在 UI 侧是 `Text(String)` → verbatim，星号会原样显示给用户。
            return stopped ? "\(head)，\(t)｜「已中断」（可重跑续传）" : "\(head)，\(t)"
        }
    }

    // MARK: - 回放报告

    /// 单日回放的结局。`status` 用下面 `Status` 的常量，**不用裸字符串**（拼错会静默变成"未分类"）。
    public struct DayResult: Equatable, Sendable {
        public let day: String
        public let status: String
        public let detail: String
        public let roundID: Int
        public let totalScanned: Int
        public let tier1: Int
        public let tier2: Int
        /// 复盘的「目标交易日」（= D 的下一交易日）
        public let targetDay: String
        /// 目标日在缓存里的 bar 数 —— 它偏小意味着 `stock_outcomes` 会静默少标签
        public let targetDayBars: Int
        public let reviewStatus: String
        public let predictStatus: String

        public var ok: Bool { status == Status.ok }
        public var oneLine: String {
            switch status {
            case Status.ok:
                return "\(day) ✅ 扫 \(totalScanned) / 一级 \(tier1) / 二级 \(tier2)"
                    + "｜T+1 \(targetDay)（\(targetDayBars) 只行情）复盘 \(reviewStatus)"
            case Status.skippedHasData:
                return "\(day) ⏭️ 跳过：\(detail)"
            default:
                return "\(day) ⚠️ \(status)：\(detail)"
            }
        }

        /// 失败结果的便捷构造。
        ///
        /// 存在的理由：成员逐一初始化器是 **internal**（键集不该被外部随便拼），
        /// 而 App 层在 `replayOne` **抛错**时（落库失败这类真错误）需要造一条失败结果
        /// 放进逐日列表 —— 否则那一天会在界面上凭空消失，看起来像"跑完了但少了几天"。
        public static func failed(day: String, detail: String) -> DayResult {
            DayResult(day: day, status: Status.failed, detail: detail,
                      roundID: 0, totalScanned: 0, tier1: 0, tier2: 0,
                      targetDay: "", targetDayBars: 0, reviewStatus: "", predictStatus: "")
        }
    }

    /// `DayResult.status` 的取值集合
    public enum Status {
        /// 扫描 + 预判 + 复盘都跑完
        public static let ok = "ok"
        /// 该日已有扫描轮次（隔离规则）→ 整日跳过，**不算失败**
        public static let skippedHasData = "skipped_has_data"
        /// 交易日历里没有该日 / 推不出确定的 T+1 / 缓存里没有 T+1 的行情 → 跳过
        public static let skippedNoCalendar = "skipped_no_calendar"
        /// 扫描自己判定"数据不足"（全市场行情不够 / 报价日期不对）→ 未落库
        public static let dataInsufficient = "data_insufficient"
        /// 抛错（落库失败等）
        public static let failed = "failed"
    }

    // MARK: - 下载

    /// 批量下载个股日K（**可断点续传**）。
    ///
    /// 续传判据：`bar_coverage[code].covers(beg:end:)` —— 已按同一窗口请求过的票直接跳过。
    ///
    /// ⚠ **返回 0 根的票不记 `bar_coverage`**（下次会重试）。这是**有意选的方向**：
    /// `HistoryBarsSource.fetch` 无法区分"网络失败"与"这只票真的没数据"（两者都是 `[]`）。
    /// 若一律记账，一次网络抖动就会把一批票**永久**排除在缓存外 → 回放的全市场快照
    /// 悄悄缺一大片，而界面上只看到"缓存已完整"。宁可下次多请求几百次。
    ///
    /// ⚠ `shouldStop` 只在**批**粒度生效（`concurrentPerform` 无法中断已开始的迭代）——
    /// 所以中断后仍可能有几十只在途。它们的进度是**已落库**的，重跑会跳过。
    ///
    /// - Parameter onProgress: `(已完成, 总数)`。**可能从多个线程并发调用**，回调里别碰本模块。
    @discardableResult
    public static func downloadBars(codes: [String], beg: String, end: String,
                                    concurrency: Int = defaultConcurrency,
                                    shouldStop: (@Sendable () -> Bool)? = nil,
                                    onProgress: (@Sendable (Int, Int) -> Void)? = nil) -> DownloadReport {
        let t0 = Date().timeIntervalSince1970

        // 去重 + 剔除已覆盖（**在发请求之前**做，续传省下的请求数要能被看见）
        let cov = HistoryBarStore.coverage()
        var seen = Set<String>()
        var picked: [String] = []
        var skipped = 0
        for c in codes where !c.isEmpty {
            guard seen.insert(c).inserted else { continue }
            if let k = cov[c], k.covers(beg: beg, end: end) {
                skipped += 1
                continue
            }
            picked.append(c)
        }
        // ⚠ 必须是 `let`：下面要跨线程读它。可变捕获会在并发闭包里被拒绝（Swift 6）。
        let todo = picked
        let total = todo.count
        guard total > 0 else {
            var r = DownloadReport()
            r.skipped = skipped
            r.elapsedSec = Date().timeIntervalSince1970 - t0
            return r
        }

        let stamp = PhaseStore.nowStamp()
        // 批数 = min(并发, 票数)；每批大小向上取整 → 批数可能略小于并发，不会空转
        let batchCount = max(1, min(max(1, concurrency), total))
        let per = (total + batchCount - 1) / batchCount
        // 累加器是 `final class + 自持 NSLock`（项目既有手法）：Swift 6 不允许在并发闭包里
        // 改捕获的 `var`，而"所有改动都在锁内"这件事编译器看不出来 → 用类型把意图写死。
        let acc = DownloadAccumulator()
        acc.seed(skipped: skipped, requested: total)

        DispatchQueue.concurrentPerform(iterations: batchCount) { bi in
            let lo = bi * per
            let hi = min(total, lo + per)
            guard lo < hi else { return }
            for i in lo..<hi {
                if shouldStop?() == true {
                    acc.markStopped()
                    return
                }
                let code = todo[i]
                let bars = HistoryBarsSource.fetch(code, beg: beg, end: end)
                var saved = 0
                var problem: String?
                do {
                    saved = try HistoryBarStore.save(bars)
                    if saved > 0 {
                        // ⚠ 记的是**请求窗口**，不是 bars 的首尾日期 —— 见 Coverage 的注释
                        try HistoryBarStore.markCoverage(code: code, reqBeg: beg, reqEnd: end,
                                                         bars: saved, at: stamp)
                    }
                } catch {
                    problem = "\(code): \(error)"
                }
                let d = acc.record(code: code, saved: saved, problem: problem)
                onProgress?(d, total)
                // ⚠ 连续空转熔断已触发 ⇒ 收工（同 `shouldStop` 那条路径，标记 stopped）
                if acc.trippedEmpty {
                    acc.markStopped()
                    return
                }

            }
        }

        var report = acc.snapshot
        report.elapsedSec = Date().timeIntervalSince1970 - t0
        return report
    }

    /// 下载指数日K（**串行**，只有一两个符号）。
    ///
    /// ⚠ 不下载指数就一天都回放不了：交易日历唯一来源就是它（`TradingCalendar`）。
    @discardableResult
    public static func downloadIndex(symbols: [String] = indexSymbols,
                                     beg: String, end: String) -> DownloadReport {
        let t0 = Date().timeIntervalSince1970
        var report = DownloadReport()
        let cov = HistoryBarStore.coverage()
        let stamp = PhaseStore.nowStamp()
        for sym in symbols where !sym.isEmpty {
            if let k = cov[sym], k.covers(beg: beg, end: end) {
                report.skipped += 1
                continue
            }
            report.requested += 1
            let bars = HistoryBarsSource.fetchIndex(sym, beg: beg, end: end)
            do {
                let saved = try HistoryBarStore.saveIndex(bars)
                if saved > 0 {
                    try HistoryBarStore.markCoverage(code: sym, reqBeg: beg, reqEnd: end,
                                                     bars: saved, at: stamp)
                    report.succeeded += 1
                    report.bars += saved
                } else {
                    report.noData += 1
                    record(&report, sym)
                }
            } catch {
                report.failed += 1
                record(&report, "\(sym): \(error)")
            }
        }
        report.elapsedSec = Date().timeIntervalSince1970 - t0
        return report
    }

    /// 下载报告的记账（只留前若干个问题码）
    private static func record(_ report: inout DownloadReport, _ item: String) {
        if report.problems.count < maxRecordedFailures { report.problems.append(item) }
    }

    /// `downloadBars` 的跨线程累加器。
    ///
    /// **为什么需要这个类型**：Swift 6 不允许在并发闭包里改捕获的 `var`
    /// （"mutation of captured var in concurrently-executing code"）。而这里的改动
    /// **全部在锁内**，编译器看不出来 —— 于是用 `final class + @unchecked Sendable +
    /// 自持 NSLock` 把"这是安全的"写进类型里
    /// （与 `DataSources.KLineCache` / `HistoryReplayMode.Box` 同一手法）。
    private final class DownloadAccumulator: @unchecked Sendable {
        private let lock = NSLock()
        private var report = DownloadReport()
        private var done = 0

        func seed(skipped: Int, requested: Int) {
            lock.lock(); defer { lock.unlock() }
            report.skipped = skipped
            report.requested = requested
        }

        func markStopped() {
            lock.lock(); defer { lock.unlock() }
            report.stopped = true
        }

        /// 记一条结果，返回**累计完成数**（进度用）
        func record(code: String, saved: Int, problem: String?) -> Int {
            lock.lock(); defer { lock.unlock() }
            if let p = problem {
                report.failed += 1
                append(p)
            } else if saved == 0 {
                report.noData += 1
                append(code)
            } else {
                report.succeeded += 1
                report.bars += saved
            }
            // ⚠ 连续空转熔断（2026-10-16 审查 B4）：取不到 bar 既不算失败也不算成功，
            //   原先**没有任何停手条件** —— 于是一次源侧故障（或被限流）会一路打到
            //   5000 个请求全部空转为止。README:151 与 `docs/specs` 记的正是这个事故
            //   （"1904 个 URL 全失败，此后同族的行业/基本面刷新几乎全被拒"）。
            //   判据用"连续多少只都为空"而不是"累计失败数"：退市/长期停牌的票是**零散**的空，
            //   而限流是**成片**的空 —— 连续计数才分得开这两者。
            if saved == 0 {
                consecutiveEmpty += 1
                if consecutiveEmpty >= Self.emptyStreakLimit {
                    trippedEmpty = true
                    append("连续 \(Self.emptyStreakLimit) 只都取不到任何 bar ⇒ 判定数据源整体不可用，"
                           + "提前收工（继续打下去会把出口 IP 打进限流名单）")
                }
            } else {
                consecutiveEmpty = 0
            }
            done += 1
            return done
        }

        /// 连续取空的上限（熔断阈值）
        static let emptyStreakLimit = 60
        private var consecutiveEmpty = 0
        private(set) var trippedEmpty = false


        private func append(_ item: String) {
            if report.problems.count < maxRecordedFailures { report.problems.append(item) }
        }

        var snapshot: DownloadReport {
            lock.lock(); defer { lock.unlock() }
            return report
        }
    }

    // MARK: - 回放

    /// 回放若干天（**串行**，一天一天跑）。
    ///
    /// - Parameters:
    ///   - days: 要回放的**选股日**（升序）。已有数据的日期会被整日跳过，所以传一整段很安全。
    ///   - params / paramVersion: 由调用方给（与 `ScanRunner` 同约定：本文件不读库取参数）。
    ///   - onDay: 每天开始时回调（界面进度用）
    /// - Returns: 与 `days` **等长同序**的逐日结果 —— 跳过的也在里面，不是被悄悄吞掉。
    public static func replay(days: [String],
                              params: [String: Any], paramVersion: String,
                              onDay: ((String) -> Void)? = nil) throws -> [DayResult] {
        guard !HistoryReplayMode.isActive else {
            throw ReplayError(message: "回放模式已在激活状态 —— 不允许嵌套或并发回放"
                + "（它是进程级开关，嵌套会让内外两层互相串数据）")
        }
        // ⚠ 整段会话必须占住：`replayOne` 每天会 `begin`/`end` 两次，
        // **天与天之间 `activeDay` 是空的** —— 调度器正好可能在那一刻触发一轮实时扫描，
        // 把实盘行情写进库，而回放正跑到一半（事后无法区分）。见 `HistoryReplayMode.isRunning`。
        guard HistoryReplayMode.beginSession() else {
            throw ReplayError(message: "已有回放会话在进行中 —— 不允许并发回放")
        }
        defer { HistoryReplayMode.endSession() }

        var out: [DayResult] = []
        out.reserveCapacity(days.count)
        for day in days.sorted() {
            onDay?(day)
            out.append(try replayOne(day: day, params: params, paramVersion: paramVersion))
        }
        return out
    }

    /// 单日回放。抛错只发生在"落库失败"这类**真错误**上；可预期的不可跑情况返回带 `status` 的结果。
    public static func replayOne(day: String, params: [String: Any],
                                 paramVersion: String) throws -> DayResult {
        guard !HistoryReplayMode.isActive else {
            throw ReplayError(message: "回放模式已在激活状态（不允许嵌套）")
        }

        // ---- ① 隔离：该日已有任何轮次 → 整日跳过 ----
        // 这是「live 数据永不被回放改写」的唯一保证。放在最前面：先判能不能写，再去取数。
        if !CompareStore.shared.loadRounds(date: day).isEmpty {
            return DayResult(day: day, status: Status.skippedHasData,
                             detail: "该日已有扫描轮次（隔离规则：不做覆盖）",
                             roundID: 0, totalScanned: 0, tier1: 0, tier2: 0,
                             targetDay: "", targetDayBars: 0,
                             reviewStatus: "", predictStatus: "")
        }

        // ---- ② 交易日历：用**指数**缓存，且必须能推出确定的 T+1 ----
        let cal = TradingCalendar(days: HistoryBarStore.indexDays(symbol: indexSymbols[0]))
        guard cal.isTradingDay(day) else {
            return DayResult(day: day, status: Status.skippedNoCalendar,
                             detail: "指数缓存里没有 \(day)（未下载？或该日非交易日）",
                             roundID: 0, totalScanned: 0, tier1: 0, tier2: 0,
                             targetDay: "", targetDayBars: 0,
                             reviewStatus: "", predictStatus: "")
        }
        var uncertain = false
        // `today: nil, todayIsTrading: false` → 只用"日K里已有的未来交易日"这一条分支；
        // 取不到就置 uncertain（回落"下一个工作日"）。**不能接受猜出来的 T+1**：
        // 它会把错误日的收益写进 stock_outcomes，而调优标签正是吃那张表。
        let next = cal.nextTradingDay(day, uncertain: &uncertain, today: nil, todayIsTrading: false)
        guard !uncertain, !next.isEmpty, cal.isTradingDay(next) else {
            return DayResult(day: day, status: Status.skippedNoCalendar,
                             detail: "推不出 \(day) 的下一交易日（缓存里没有更晚的指数 bar）",
                             roundID: 0, totalScanned: 0, tier1: 0, tier2: 0,
                             targetDay: next, targetDayBars: 0,
                             reviewStatus: "", predictStatus: "")
        }
        // T+1 的行情是复盘的原料。缺它 → 复盘照跑但 stock_outcomes 全 NULL，
        // 表现为"这批样本没标签"而不是报错。宁可跳过并说明。
        let targetBars = HistoryBarStore.bars(on: next).count
        guard targetBars > 0 else {
            return DayResult(day: day, status: Status.skippedNoCalendar,
                             detail: "缓存里没有 \(next)（T+1）的个股行情 —— 复盘会产出空标签",
                             roundID: 0, totalScanned: 0, tier1: 0, tier2: 0,
                             targetDay: next, targetDayBars: 0,
                             reviewStatus: "", predictStatus: "")
        }

        // ---- ③ 扫描：整段在「当日 = day」下跑 ----
        var scanResult: [String: Any] = [:]
        HistoryReplayMode.withDay(day) {
            scanResult = ScanRunner.runScan(params: params, paramVersion: paramVersion,
                                            slot: replaySlot, slotLabel: replaySlotLabel,
                                            persist: true)
        }
        let scanStatus = (scanResult["status"] as? String) ?? ""
        if scanStatus != "ok" {
            // `not_trading_day` / `data_insufficient` / `persist_failed` 都是"没落库"
            let detail = (scanResult["data_error"] as? String) ?? scanStatus
            return DayResult(day: day, status: Status.dataInsufficient, detail: detail,
                             roundID: 0,
                             totalScanned: (scanResult["stats"] as? [String: Any])?["total_scanned"] as? Int ?? 0,
                             tier1: 0, tier2: 0,
                             targetDay: next, targetDayBars: targetBars,
                             reviewStatus: "", predictStatus: "")
        }
        let stats = (scanResult["stats"] as? [String: Any]) ?? [:]
        let roundID = (scanResult["round_id"] as? NSNumber)?.intValue
            ?? (scanResult["round_id"] as? Int) ?? 0

        // ---- ④ 预判 + 复盘：整段在「当日 = T+1」下跑（见文件头的两段表）----
        var predictStatus = ""
        var reviewStatus = ""
        var phaseError: String?
        HistoryReplayMode.withDay(next) {
            do {
                let p = try PhasePredict.predict(targetDate: day, persist: true, params: params)
                predictStatus = (p["status"] as? String) ?? ""
            } catch {
                phaseError = "预判失败：\(error)"
            }
            if phaseError == nil {
                do {
                    let r = try PhaseReview.review(persist: true, selDate: day, params: params)
                    reviewStatus = (r["status"] as? String) ?? ""
                } catch {
                    phaseError = "复盘失败：\(error)"
                }
            }
        }
        if let e = phaseError {
            // 扫描已经落库了 —— 不能假装整天失败。返回 failed 但把已发生的部分如实报出来。
            return DayResult(day: day, status: Status.failed, detail: e,
                             roundID: roundID,
                             totalScanned: stats["total_scanned"] as? Int ?? 0,
                             tier1: stats["tier1_count"] as? Int ?? 0,
                             tier2: stats["tier2_count"] as? Int ?? 0,
                             targetDay: next, targetDayBars: targetBars,
                             reviewStatus: reviewStatus, predictStatus: predictStatus)
        }

        // ---- ⑤ 标记口径 ----
        // `reviews.scan_mode` 的 DEFAULT 是 'live'，而回放的复盘是**同一个 INSERT 语句**写的
        // （不往 INSERT 里加列 —— 这条 SQL 与 live 路径共用，加列会让两条路径分叉）。
        // 所以标记是**插入之后的 UPDATE** —— 语义上"这条复盘的选股轮次是收盘价口径"。
        try PhaseStore.shared.markReviewScanMode(selDate: day, mode: scanModeReplay)

        return DayResult(day: day, status: Status.ok,
                         detail: "",
                         roundID: roundID,
                         totalScanned: stats["total_scanned"] as? Int ?? 0,
                         tier1: stats["tier1_count"] as? Int ?? 0,
                         tier2: stats["tier2_count"] as? Int ?? 0,
                         targetDay: next, targetDayBars: targetBars,
                         reviewStatus: reviewStatus, predictStatus: predictStatus)
    }

    // MARK: - 纯决策（可单测，不碰网络/库）

    /// 在给定候选日期里，挑出**该回放**的那些（升序）。
    ///
    /// 判据只有两条，都是"能不能跑"而不是"值不值得跑"：
    ///   · 交易日历里有这一天，且能推出**确定**的下一交易日
    ///   · 该日**没有**任何已有轮次（隔离规则）
    ///
    /// ⚠ `existing` 传的是"库里已有数据的日期集合"。**空集合不等于"什么都没写"** ——
    /// 调用方若传错（比如传了 `nil` 变成空集），隔离规则就形同虚设、live 数据会被覆盖。
    /// 所以这个函数只做判断，**取集合的动作留在 `replayOne` 里**（那里读的是真库）。
    public static func selectableDays(candidates: [String], calendarDays: [String],
                                      existing: Set<String>) -> [String] {
        let cal = TradingCalendar(days: calendarDays)
        var out: [String] = []
        for d in candidates.sorted() where !d.isEmpty {
            guard !existing.contains(d), cal.isTradingDay(d) else { continue }
            var unc = false
            let n = cal.nextTradingDay(d, uncertain: &unc, today: nil, todayIsTrading: false)
            guard !unc, !n.isEmpty, cal.isTradingDay(n) else { continue }
            out.append(d)
        }
        return out
    }
}
