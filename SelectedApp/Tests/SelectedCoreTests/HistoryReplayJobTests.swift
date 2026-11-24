import XCTest
import SQLite3
@testable import SelectedCore

/// 历史回放**编排** —— 隔离规则、两段「当日」、断点续传、口径标记。
///
/// 本文件**不跑真网络、不跑真扫描**：那两件事由 `SelectedApp/Tools/HistoryReplayCheck.swift`
/// 的驱动负责（那里能设 `SELECTED_DATA_DIR` 指向库的副本）。
/// 这里只测**决策**与**缓存读写**，即"能不能跑"和"跑完记什么"。
final class HistoryReplayJobTests: XCTestCase {

    // MARK: - 常量（拼错会静默变成"未分类"）

    /// `DayResult.status` 的取值集合：互不相同、且 `ok` 就是引擎里那个 `"ok"`
    func testStatusConstantsAreDistinct() {
        let all = [HistoryReplayJob.Status.ok,
                   HistoryReplayJob.Status.skippedHasData,
                   HistoryReplayJob.Status.skippedNoCalendar,
                   HistoryReplayJob.Status.dataInsufficient,
                   HistoryReplayJob.Status.failed]
        XCTAssertEqual(Set(all).count, all.count, "status 常量有重复")
        XCTAssertFalse(all.contains(""), "status 不能有空串（空串与'未分类'分不开）")
        // 扫描自己的成功码就是 "ok" —— 两边不一致会让每次成功都被判成异常
        XCTAssertEqual(HistoryReplayJob.Status.ok, "ok")
    }

    /// 回放轮的 slot **必须是 3**（`SignalClassifier` 按 slot 3 判尾盘信号）
    func testReplaySlotIsTailRound() {
        XCTAssertEqual(HistoryReplayJob.replaySlot, 3)
        XCTAssertEqual(ScanRunner.slotLabels[HistoryReplayJob.replaySlot], "14:50")
    }

    /// 回放的价是**收盘价**，标签**不能**写成 "14:50"
    /// —— 那会让界面上看起来像一轮真实的尾盘选股，正是 `scan_mode` 要防的混淆。
    func testReplaySlotLabelDoesNotMasqueradeAsLive() {
        XCTAssertNotEqual(HistoryReplayJob.replaySlotLabel, "14:50")
        XCTAssertFalse(HistoryReplayJob.replaySlotLabel.isEmpty)
    }

    /// 口径标记：两个值必须不同，且 `live` 必须与 DDL 的 DEFAULT **逐字一致**
    func testScanModeConstantsMatchTheDdlDefault() {
        XCTAssertEqual(HistoryReplayJob.scanModeLive, "live")
        XCTAssertEqual(HistoryReplayJob.scanModeReplay, "replay_close")
        XCTAssertNotEqual(HistoryReplayJob.scanModeLive, HistoryReplayJob.scanModeReplay)
        XCTAssertTrue(DBBootstrap.reviewScanModeSQL.contains("DEFAULT 'live'"),
                      "少了 DEFAULT 'live'，存量行与 Python 侧插入会是 NULL，"
                      + "而 buildPool 的 scan_mode='live' 会把 NULL 静默排除 → 历史样本全没了")
        XCTAssertTrue(DBBootstrap.reviewScanModeSQL.contains("reviews"))
        XCTAssertTrue(DBBootstrap.reviewScanModeSQL.contains("scan_mode"))
    }

    /// 问题码只记前若干个 —— 5000 只全挂时不该产出 5000 行
    func testFailureRecordingIsCapped() {
        XCTAssertGreaterThan(HistoryReplayJob.maxRecordedFailures, 0)
        XCTAssertLessThanOrEqual(HistoryReplayJob.maxRecordedFailures, 100)
    }

    // MARK: - 下载报告

    func testDownloadReportSummaryCarriesTheNumbers() {
        var r = HistoryReplayJob.DownloadReport()
        r.requested = 5000
        r.skipped = 1200
        r.succeeded = 3700
        r.noData = 100
        r.bars = 4_200_000
        r.elapsedSec = 61.5
        let s = r.summary
        for token in ["5000", "1200", "3700", "100", "4200000"] {
            XCTAssertTrue(s.contains(token), "摘要缺 \(token)：\(s)")
        }
        XCTAssertFalse(s.contains("中断"))
        r.stopped = true
        XCTAssertTrue(r.summary.contains("中断"), "被中断必须显式说出来（否则会被当成跑完了）")
    }

    // MARK: - 逐日结果

    func testDayResultOneLineDistinguishesOkFromSkipped() {
        let ok = HistoryReplayJob.DayResult(
            day: "2026-08-12", status: HistoryReplayJob.Status.ok, detail: "",
            roundID: 7, totalScanned: 5200, tier1: 3, tier2: 5,
            targetDay: "2026-08-13", targetDayBars: 5100,
            reviewStatus: "ok", predictStatus: "ok")
        XCTAssertTrue(ok.ok)
        XCTAssertTrue(ok.oneLine.contains("2026-08-12"))
        XCTAssertTrue(ok.oneLine.contains("2026-08-13"), "T+1 必须显示出来（标签的来源日）")

        let skipped = HistoryReplayJob.DayResult(
            day: "2026-08-12", status: HistoryReplayJob.Status.skippedHasData,
            detail: "该日已有扫描轮次（隔离规则：不做覆盖）",
            roundID: 0, totalScanned: 0, tier1: 0, tier2: 0,
            targetDay: "", targetDayBars: 0, reviewStatus: "", predictStatus: "")
        XCTAssertFalse(skipped.ok)
        XCTAssertTrue(skipped.oneLine.contains("跳过"))
        XCTAssertTrue(skipped.oneLine.contains("隔离规则"), "跳过原因必须可见")
    }

    /// `DayResult.failed` 是 App 层在 `replayOne` 抛错时唯一能用的构造。
    ///
    /// 它存在的理由是**可见性**：抛错的那天若造不出结果，它会在逐日列表里凭空消失，
    /// 看起来像"跑完了但少了一天"。
    func testDayResultFailedFactoryIsVisibleAndNotOK() {
        let f = HistoryReplayJob.DayResult.failed(day: "2026-08-12", detail: "落库失败：disk I/O")
        XCTAssertEqual(f.day, "2026-08-12")
        XCTAssertEqual(f.status, HistoryReplayJob.Status.failed)
        XCTAssertFalse(f.ok)
        XCTAssertEqual(f.roundID, 0)
        XCTAssertTrue(f.oneLine.contains("2026-08-12"))
        XCTAssertTrue(f.oneLine.contains("落库失败"), "错误详情必须显示出来：\(f.oneLine)")
    }

    // MARK: - 可回放日期筛选（纯决策）

    private let calDays = ["2026-08-10", "2026-08-11", "2026-08-12", "2026-08-13", "2026-08-14"]

    func testSelectableDaysExcludesDaysThatAlreadyHaveData() {
        let got = HistoryReplayJob.selectableDays(
            candidates: ["2026-08-10", "2026-08-11", "2026-08-12"],
            calendarDays: calDays,
            existing: ["2026-08-11"])
        XCTAssertEqual(got, ["2026-08-10", "2026-08-12"])
    }

    func testSelectableDaysExcludesNonTradingDays() {
        // 2026-08-08 是周六、08-09 是周日，且不在日历里
        let got = HistoryReplayJob.selectableDays(
            candidates: ["2026-08-08", "2026-08-09", "2026-08-10"],
            calendarDays: calDays, existing: [])
        XCTAssertEqual(got, ["2026-08-10"])
    }

    /// 日历的**最后一天**推不出确定的 T+1 → 必须排除。
    /// 若放行，`nextTradingDay` 会回落"下一个工作日"（`uncertain`），把**错误日**的收益
    /// 写进 `stock_outcomes` —— 而调优标签正是吃那张表。
    func testSelectableDaysExcludesTheLastCalendarDay() {
        let got = HistoryReplayJob.selectableDays(
            candidates: ["2026-08-14"], calendarDays: calDays, existing: [])
        XCTAssertEqual(got, [], "最后一天没有确定的 T+1，不能回放")
    }

    func testSelectableDaysSortsAndIgnoresEmpty() {
        let got = HistoryReplayJob.selectableDays(
            candidates: ["2026-08-12", "", "2026-08-10"],
            calendarDays: calDays, existing: [])
        XCTAssertEqual(got, ["2026-08-10", "2026-08-12"])
    }

    /// 空日历 → 一个都不能选。**不能**退化成"那就全选吧"
    func testSelectableDaysWithEmptyCalendarSelectsNothing() {
        XCTAssertEqual(HistoryReplayJob.selectableDays(
            candidates: ["2026-08-10"], calendarDays: [], existing: []), [])
    }

    // MARK: - 编排：拒绝嵌套 / 拒绝不可跑的日期

    /// 回放模式是**进程级开关**，嵌套会让内外两层互相串数据 → 必须拒绝，而不是"后者覆盖前者"
    func testReplayOneRefusesToNest() throws {
        HistoryReplayMode.end()
        defer { HistoryReplayMode.end() }
        XCTAssertTrue(HistoryReplayMode.begin("2026-08-12"))
        XCTAssertThrowsError(try HistoryReplayJob.replayOne(
            day: "2026-08-12", params: [:], paramVersion: "test")) { err in
            XCTAssertTrue("\(err)".contains("回放模式"), "错误信息要说明是嵌套：\(err)")
        }
    }

    func testReplayRefusesToNest() {
        HistoryReplayMode.end()
        defer { HistoryReplayMode.end() }
        XCTAssertTrue(HistoryReplayMode.begin("2026-08-12"))
        XCTAssertThrowsError(try HistoryReplayJob.replay(
            days: ["2026-08-12"], params: [:], paramVersion: "test"))
    }

    /// 整段会话必须**盖住天与天之间的空隙** —— 那正是 `isBusy` 存在的理由。
    /// 若只在单日内占位，调度器可能在两天的间隙里跑一轮实时扫描，把实盘行情写进库。
    func testReplayHoldsSessionAcrossTheWholeRun() throws {
        HistoryReplayMode.end(); HistoryReplayMode.endSession()
        var sawRunningInside = false
        var sawDayInside: String?
        let out = try HistoryReplayJob.replay(days: ["1990-01-02"], params: [:],
                                              paramVersion: "test") { day in
            sawRunningInside = HistoryReplayMode.isRunning
            sawDayInside = HistoryReplayMode.activeDay
        }
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].status, HistoryReplayJob.Status.skippedNoCalendar)
        XCTAssertTrue(sawRunningInside, "onDay 回调时整段会话必须已经在位")
        XCTAssertNil(sawDayInside, "onDay 回调发生在单日 begin 之前（此刻不该有回放日）")
        XCTAssertFalse(HistoryReplayMode.isBusy, "跑完必须把会话关掉（否则后续一切写操作被永久拒绝）")
    }

    /// 已有会话在跑 → 拒绝并发回放（而不是"两个回放轮流写同一个开关"）
    func testReplayRefusesWhenASessionIsAlreadyRunning() {
        HistoryReplayMode.end(); HistoryReplayMode.endSession()
        defer { HistoryReplayMode.endSession() }
        XCTAssertTrue(HistoryReplayMode.beginSession())
        XCTAssertThrowsError(try HistoryReplayJob.replay(
            days: ["1990-01-02"], params: [:], paramVersion: "test")) { err in
            XCTAssertTrue("\(err)".contains("会话"), "错误信息要说明是会话冲突：\(err)")
        }
        XCTAssertTrue(HistoryReplayMode.isRunning, "被拒绝的那次不该把已有会话关掉")
    }

    /// 缓存里没有这一天 → 跳过并说明，**不抛错**（这是可预期的"跑不了"，不是故障）
    func testReplayOneSkipsDayMissingFromIndexCache() throws {
        HistoryReplayMode.end()
        let r = try HistoryReplayJob.replayOne(day: "1990-01-02", params: [:],
                                               paramVersion: "test")
        XCTAssertEqual(r.status, HistoryReplayJob.Status.skippedNoCalendar)
        XCTAssertTrue(r.detail.contains("1990-01-02"))
        XCTAssertEqual(r.roundID, 0)
        XCTAssertFalse(r.ok)
    }

    // MARK: - 缓存读写（临时数据目录，不碰真实库）

    func testDownloadBarsWithNoCodesDoesNothing() {
        XCTAssertEqual(HistoryReplayJob.downloadBars(codes: [], beg: "2020-01-01",
                                                     end: "2026-09-22").requested, 0)
        XCTAssertEqual(HistoryReplayJob.downloadBars(codes: ["", ""], beg: "2020-01-01",
                                                     end: "2026-09-22").requested, 0)
    }

    /// 断点续传：已按同一窗口请求过的票**不发请求**（`requested == 0`）
    func testDownloadBarsSkipsAlreadyCoveredCodes() throws {
        try withTempDataDir {
            let beg = "2020-01-01", end = "2026-09-22"
            try HistoryBarStore.markCoverage(code: "600519", reqBeg: beg, reqEnd: end,
                                             bars: 1145, at: "2026-09-22 08:00:00")
            let r = HistoryReplayJob.downloadBars(codes: ["600519"], beg: beg, end: end)
            XCTAssertEqual(r.requested, 0, "已覆盖 → 不该发请求")
            XCTAssertEqual(r.skipped, 1)
            XCTAssertEqual(r.bars, 0)
        }
    }

    /// 请求窗口**更宽**时必须重下：缓存里只有 2024 起的数据，要 2020 起就得补
    func testDownloadBarsRedownloadsWhenWindowWidens() throws {
        try withTempDataDir {
            try HistoryBarStore.markCoverage(code: "600519", reqBeg: "2024-01-01",
                                             reqEnd: "2026-09-22", bars: 600,
                                             at: "2026-09-22 08:00:00")
            // 窗口一样 → 跳过
            XCTAssertEqual(HistoryReplayJob.downloadBars(
                codes: ["600519"], beg: "2024-01-01", end: "2026-09-22").skipped, 1)
            // 窗口变宽 → 判为未覆盖（**安全方向**：重下的代价是时间，漏下的代价是静默缺数据）
            let cov = HistoryBarStore.coverage()["600519"]
            XCTAssertEqual(cov?.covers(beg: "2020-01-01", end: "2026-09-22"), false)
        }
    }

    /// 覆盖区间要能原样读回来（`req_beg`/`req_end` 的读写与列名一致）
    func testCoverageRoundTripsThroughTheCache() throws {
        try withTempDataDir {
            XCTAssertTrue(HistoryBarStore.coverage().isEmpty)
            try HistoryBarStore.markCoverage(code: "600519", reqBeg: "2020-01-01",
                                             reqEnd: "2026-09-22", bars: 1145,
                                             at: "2026-09-22 08:00:00")
            let c = HistoryBarStore.coverage()["600519"]
            XCTAssertEqual(c?.reqBeg, "2020-01-01")
            XCTAssertEqual(c?.reqEnd, "2026-09-22")
            XCTAssertEqual(c?.bars, 1145)
            XCTAssertEqual(c?.covers(beg: "2020-01-01", end: "2026-09-22"), true)
        }
    }

    /// 指数键的**约定**：`fetchIndex` 存的是**引擎符号**（`sh000001`），
    /// 而读取侧 `indexBars(symbol:)` / `indexDays(symbol:)` 也用它。
    /// 两边不一致时读侧只会**安静地返回空**（表现为"回放日没有指数数据"，看不出是键错）。
    func testIndexBarsAreKeyedByEngineSymbol() throws {
        try withTempDataDir {
            let bars = [hbar("sh000001", "2026-08-11", close: 3400),
                        hbar("sh000001", "2026-08-12", close: 3410),
                        hbar("sh000001", "2026-08-13", close: 3390)]
            XCTAssertEqual(try HistoryBarStore.saveIndex(bars), 3)

            XCTAssertEqual(HistoryBarStore.indexBars(symbol: "sh000001", upTo: "2026-08-13").count, 3)
            XCTAssertEqual(HistoryBarStore.indexDays(symbol: "sh000001"),
                           ["2026-08-11", "2026-08-12", "2026-08-13"])
            // 用裸代码查 → 空（这正是"键写错会静默返回空"的那条）
            XCTAssertTrue(HistoryBarStore.indexBars(symbol: "000001", upTo: "2026-08-13").isEmpty)
            // 指数**不**进个股表：混进去会被当成一只票参与硬过滤
            XCTAssertTrue(HistoryBarStore.bars(on: "2026-08-12").isEmpty)
            XCTAssertEqual(HistoryBarStore.stats().indexBars, 3)
            XCTAssertEqual(HistoryBarStore.stats().bars, 0)
        }
    }

    /// 个股与指数的交易日**不可互换**：个股停牌日在自己那行没有 bar
    func testStockTradingDaysDifferFromIndexTradingDays() throws {
        try withTempDataDir {
            _ = try HistoryBarStore.save([hbar("600519", "2026-08-11", close: 10)])
            _ = try HistoryBarStore.saveIndex([hbar("sh000001", "2026-08-11", close: 3400),
                                               hbar("sh000001", "2026-08-12", close: 3410)])
            XCTAssertEqual(HistoryBarStore.tradingDays(), ["2026-08-11"])
            XCTAssertEqual(HistoryBarStore.indexDays(symbol: "sh000001"),
                           ["2026-08-11", "2026-08-12"])
        }
    }

    /// 缓存自愈：旧形状的 `bar_coverage`（`first_day`/`last_day`）要被重建，
    /// 否则 `coverage()` 的 `SELECT req_beg …` 报 `no such column`，而读路径**静默吞错返回空**
    /// → 表现为"断点续传失灵、每次都重下全市场"。
    func testStaleCoverageShapeIsHealed() throws {
        let dir = try makeTempDataDir()
        defer { cleanUpTempDataDir(dir) }
        // 手工造一个旧形状的库
        let path = dir + "/history.sqlite3"
        var h: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &h), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(h, "CREATE TABLE bar_coverage("
            + "code TEXT PRIMARY KEY, first_day TEXT, last_day TEXT,"
            + " bars INTEGER, fetched_at TEXT)", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(h, "INSERT INTO bar_coverage VALUES"
            + "('600519','2022-01-04','2026-09-22',1145,'x')", nil, nil, nil), SQLITE_OK)
        sqlite3_close(h)

        useDataDir(dir)
        // 旧行被丢掉（续传簿记可安全丢弃 → 只会重下，不会缺数据）
        XCTAssertTrue(HistoryBarStore.coverage().isEmpty)
        // 新形状可用
        try HistoryBarStore.markCoverage(code: "600519", reqBeg: "2020-01-01",
                                         reqEnd: "2026-09-22", bars: 1, at: "now")
        XCTAssertEqual(HistoryBarStore.coverage()["600519"]?.reqBeg, "2020-01-01")
    }

    // MARK: - 临时数据目录

    /// 指向临时目录 —— 顺带把 `HistoryBarStore` 缓存的句柄失效，否则会**悄悄写到真实数据目录**
    private func useDataDir(_ dir: String) {
        setenv("SELECTED_DATA_DIR", dir, 1)
        HistoryBarStore.invalidateConnection()
    }

    private func makeTempDataDir() throws -> String {
        let dir = NSTemporaryDirectory() + "/selected-history-job-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanUpTempDataDir(_ dir: String) {
        HistoryBarStore.invalidateConnection()
        unsetenv("SELECTED_DATA_DIR")
        try? FileManager.default.removeItem(atPath: dir)
    }

    private func withTempDataDir(_ body: () throws -> Void) throws {
        let dir = try makeTempDataDir()
        useDataDir(dir)
        defer { cleanUpTempDataDir(dir) }
        try body()
    }

    private func hbar(_ code: String, _ day: String, close: Double) -> HistoryBar {
        HistoryBar(code: code, day: day, open: close, close: close, high: close,
                   low: close, volume: 1000, amount: 1_000_000, amplitude: 1,
                   changePct: 0, turnover: 1)
    }
}
