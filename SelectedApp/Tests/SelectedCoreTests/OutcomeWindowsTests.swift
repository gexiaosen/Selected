import XCTest
@testable import SelectedCore

/// `OutcomeWindows` 的契约测试。
///
/// 本模块**唯一**的自动化覆盖 —— 回填器与复盘页都不在任何测试子集里。
/// 所以"目标日怎么推、什么时候算到期、每个窗的分母是谁"这类**真会静默出错**的部分，
/// 全部钉在这里。
///
/// 日历与 K 线**全部人工构造**：目标日推导是纯算术，期望值可以手算，
/// 比"跑一遍看看对不对"可靠得多。
final class OutcomeWindowsTests: XCTestCase {

    // MARK: - 构造工具

    /// 一个连续的交易日序列（故意**不含周末**，模拟真实日历的"跳日"）
    private func calendar(_ days: [String]) -> TradingCalendar { TradingCalendar(days: days) }

    /// 2026-01-05(一) 起的 10 个交易日，跳过 01-10/01-11（周末）
    private let week: [String] = [
        "2026-01-05", "2026-01-06", "2026-01-07", "2026-01-08", "2026-01-09",
        "2026-01-12", "2026-01-13", "2026-01-14", "2026-01-15", "2026-01-16",
    ]

    private func bar(_ day: String, _ close: Double) -> KLineBar {
        KLineBar(day: day, open: close, high: close, low: close, close: close, volume: 1000)
    }

    // MARK: - 窗口自身的契约

    /// 只有 T+3 / T+5 两个窗，**没有 T+1** —— T+1 收盘涨跌已经存在，
    /// 就是 `stock_outcomes.close_profit`。这条断言是防"有人后来顺手补一个 t1"。
    func testThereIsNoT1Window() {
        XCTAssertEqual(OutcomeWindow.allCases.count, 2)
        XCTAssertEqual(OutcomeWindow.allCases.map(\.rawValue), ["t3", "t5"])
        XCTAssertEqual(OutcomeWindow.allCases.map(\.offset), [3, 5])
        for w in OutcomeWindow.allCases {
            XCTAssertFalse(w.column.hasPrefix("t1"), "不该有 t1 列：\(w.column)")
            XCTAssertNotEqual(w.column, "close_profit", "T+1 一律复用 close_profit，不新开列")
            XCTAssertTrue(w.column.hasPrefix("t"), "列名要以 t 开头：\(w.column)")
        }
    }

    func testColumnNamesMatchMigration() {
        XCTAssertEqual(OutcomeWindow.t3.column, "t3_close_pct")
        XCTAssertEqual(OutcomeWindow.t5.column, "t5_close_pct")
        XCTAssertEqual(OutcomeWindow.t3.label, "持有 3 日")
        XCTAssertEqual(OutcomeWindow.t5.label, "持有 5 日")
    }

    // MARK: - 目标日推导

    func testTargetDayCountsTradingDays() {
        let cal = calendar(week)
        // selDate = 01-05(一)，T+3 = 01-08(四)，T+5 = 01-12(一) —— 跨过周末
        XCTAssertEqual(OutcomeWindows.targetDay(selDate: "2026-01-05", offset: 3, calendar: cal),
                       "2026-01-08")
        XCTAssertEqual(OutcomeWindows.targetDay(selDate: "2026-01-05", offset: 5, calendar: cal),
                       "2026-01-12")
    }

    /// 关键：目标日必须是**日历里真实发生过的交易日**，不是"往后数 3 个工作日"。
    /// 若用 `shiftTradingDay` 的工作日回落，跨周末/节假日会算错一天。
    func testTargetDayIsExactTradingDayNotWeekdayFallback() {
        let cal = calendar(week)
        // 01-09(五) + 3 个交易日 = 01-14(三)，而不是 01-12(一) + 2 = 01-14 的巧合；
        // 用 01-08(四) 更清楚：+3 = 01-13(二)，中间跳过整个周末（工作日推算会给出 01-13 吗？
        // 01-08 四 → 五(09) → 一(12) → 二(13)，恰好也对；故用 01-09 验证跨周）
        XCTAssertEqual(OutcomeWindows.targetDay(selDate: "2026-01-09", offset: 3, calendar: cal),
                       "2026-01-14")
        XCTAssertEqual(OutcomeWindows.targetDay(selDate: "2026-01-09", offset: 5, calendar: cal),
                       "2026-01-16")
    }

    /// 日历里没有那么多天 = 还没到期 → nil（**不是**猜一个未来日）
    func testTargetDayReturnsNilWhenNotHappened() {
        let cal = calendar(week)
        XCTAssertEqual(OutcomeWindows.targetDay(selDate: "2026-01-15", offset: 3, calendar: cal),
                       nil, "01-15 + 3 个交易日已超出日历 → 未到期")
        XCTAssertEqual(OutcomeWindows.targetDay(selDate: "2026-01-16", offset: 5, calendar: cal),
                       nil)
        // 边界：恰好最后一天算得出来
        XCTAssertEqual(OutcomeWindows.targetDay(selDate: "2026-01-12", offset: 3, calendar: cal),
                       "2026-01-15")
    }

    /// 选股日**不在日历里**（异常数据）也要能推：第一个 > selDate 的交易日就是 T+1
    func testTargetDayWorksWhenSelDateNotInCalendar() {
        let cal = calendar(week)
        // 01-10(六) 不在日历里 → T+1 = 01-12(一)，T+3 = 01-14(三)
        XCTAssertEqual(OutcomeWindows.targetDay(selDate: "2026-01-10", offset: 3, calendar: cal),
                       "2026-01-14")
    }

    func testTargetDayRejectsBadInput() {
        let cal = calendar(week)
        XCTAssertNil(OutcomeWindows.targetDay(selDate: "", offset: 3, calendar: cal))
        XCTAssertNil(OutcomeWindows.targetDay(selDate: "2026-01-05", offset: 0, calendar: cal))
        XCTAssertNil(OutcomeWindows.targetDay(selDate: "2026-01-05", offset: -1, calendar: cal))
        XCTAssertNil(OutcomeWindows.targetDay(selDate: "2026-01-05", offset: 3,
                                              calendar: calendar([])))
    }

    // MARK: - 到期判定

    /// 窗口**逐个**到期：T+3 先到、T+5 后到 —— 这是"回填器每轮只补该补的"的依据
    func testDueWindowsGrowsAsDaysPass() {
        let cal = calendar(week)
        // 站在 01-08（= T+3 当天）：T+3 到期，T+5 还没
        XCTAssertEqual(OutcomeWindows.dueWindows(selDate: "2026-01-05", calendar: cal),
                       [.t3, .t5], "用满 10 天的日历，两个窗都已到期")
        // 用短日历模拟"站在 T+3 当天"
        let short = calendar(Array(week.prefix(4)))       // 到 01-08 为止
        XCTAssertEqual(OutcomeWindows.dueWindows(selDate: "2026-01-05", calendar: short), [.t3])
        let shorter = calendar(Array(week.prefix(3)))     // 到 01-07 为止
        XCTAssertEqual(OutcomeWindows.dueWindows(selDate: "2026-01-05", calendar: shorter), [])
    }

    func testDueWindowsIsEmptyWhenSelDateIsLatest() {
        let cal = calendar(week)
        XCTAssertEqual(OutcomeWindows.dueWindows(selDate: "2026-01-16", calendar: cal), [])
    }

    // MARK: - 单窗涨跌

    func testClosePctMatchesReviewFormula() {
        let bars = [bar("2026-01-08", 11.0), bar("2026-01-12", 12.5)]
        // (11 − 10) / 10 × 100 = 10
        XCTAssertEqual(OutcomeWindows.closePct(selPrice: 10, targetDay: "2026-01-08", bars: bars),
                       10.0)
        // (12.5 − 10) / 10 × 100 = 25
        XCTAssertEqual(OutcomeWindows.closePct(selPrice: 10, targetDay: "2026-01-12", bars: bars),
                       25.0)
        // 亏损：收 9.2 → −8
        XCTAssertEqual(OutcomeWindows.closePct(selPrice: 10, targetDay: "2026-01-12",
                                               bars: [bar("2026-01-12", 9.2)]),
                       -8.0)
    }

    func testClosePctReturnsNilWhenTargetDayMissing() {
        let bars = [bar("2026-01-08", 11.0)]
        // 目标日不在日K里（停牌 / 过早 / 窗口没覆盖）→ nil，**不猜**
        XCTAssertNil(OutcomeWindows.closePct(selPrice: 10, targetDay: "2026-01-12", bars: bars))
        XCTAssertNil(OutcomeWindows.closePct(selPrice: 10, targetDay: "2026-01-12", bars: []))
        XCTAssertNil(OutcomeWindows.closePct(selPrice: 10, targetDay: "", bars: bars))
    }

    /// **收盘价 0 也算"没有"**（真值判断，不是 `px > 0`）—— 口径是定死的契约，
    /// 别"顺手改成判正数"，那会在边界上与存量数据分叉。
    func testClosePctTreatsZeroCloseAsMissing() {
        XCTAssertNil(OutcomeWindows.closePct(selPrice: 10, targetDay: "2026-01-08",
                                             bars: [bar("2026-01-08", 0)]))
    }

    func testClosePctReturnsNilOnNonPositiveSelPrice() {
        let bars = [bar("2026-01-08", 11.0)]
        XCTAssertNil(OutcomeWindows.closePct(selPrice: 0, targetDay: "2026-01-08", bars: bars))
        XCTAssertNil(OutcomeWindows.closePct(selPrice: -1, targetDay: "2026-01-08", bars: bars))
    }

    /// 目标日有多根 bar（数据源重复）时取**第一根**
    func testClosePctTakesFirstMatchingBar() {
        let bars = [bar("2026-01-08", 11.0), bar("2026-01-08", 99.0)]
        XCTAssertEqual(OutcomeWindows.closePct(selPrice: 10, targetDay: "2026-01-08", bars: bars),
                       10.0)
    }

    /// 舍入必须走 `PyMath.round`（半偶），不是 Swift 的 `(x*100).rounded()/100`（半远离零）
    func testClosePctUsesPyMathRoundNotSwiftRounding() {
        // 先钉住两个舍入器的差别本身（2.125 在二进制里精确可表示）
        XCTAssertEqual(PyMath.round(2.125, 2), 2.12, "PyMath.round 是半偶（printf %.2f）")
        XCTAssertEqual((2.125 * 100).rounded() / 100, 2.13, "Swift 默认是半远离零 —— 两者不同")
        // 再确认 closePct 走的是前者：800 → 817 恰好是 2.125（已实测二进制上精确）
        let bars = [bar("2026-01-08", 817.0)]
        let got = OutcomeWindows.closePct(selPrice: 800, targetDay: "2026-01-08", bars: bars)
        XCTAssertEqual(got, 2.12, "走 PyMath.round；若误用 Swift 舍入会得 2.13")
        XCTAssertNotEqual(got, 2.13)
    }

    // MARK: - 单窗统计

    /// 本模块最重要的一条：**每个窗的分母必须各算各的**。
    /// 同一批标的里 `close_profit` 全有值、`t5_close_pct` 只有一条 ——
    /// 用一个共同分母会把"还没到期的"当成"没涨"，凭空压低长窗胜率且不报错。
    func testStatsUsesPerWindowDenominator() {
        let rows: [[String: Any]] = [
            ["close_profit": 2.0, "t5_close_pct": 5.0],
            ["close_profit": -1.0],                     // T+5 还没到期
            ["close_profit": 3.0],                      // 同上
        ]
        let t1 = OutcomeWindows.stats(rows: rows, column: "close_profit")
        let t5 = OutcomeWindows.stats(rows: rows, column: "t5_close_pct")
        XCTAssertEqual(t1?.total, 3)
        XCTAssertEqual(t1?.wins, 2)
        XCTAssertEqual(t5?.total, 1, "t5 的有效样本只有 1 条，不是 3 条")
        XCTAssertEqual(t5?.wins, 1)
        XCTAssertEqual(t5?.winrate, 100.0, "若用共同分母会算成 33.3 —— 那就是这条要防的错")
    }

    /// 该列全为 null → `nil`（**不是** 0 胜率）。界面据此显示"—"而不是"0%"
    func testStatsReturnsNilWhenAllNull() {
        let rows: [[String: Any]] = [["close_profit": 1.0], ["close_profit": NSNull()]]
        XCTAssertNil(OutcomeWindows.stats(rows: rows, column: "t5_close_pct"))
        XCTAssertNil(OutcomeWindows.stats(rows: [], column: "t5_close_pct"))
        // 全是 NSNull
        XCTAssertNil(OutcomeWindows.stats(rows: [["t5_close_pct": NSNull()]],
                                          column: "t5_close_pct"))
    }

    func testStatsSkipsNSNullAndMissingKeys() {
        let rows: [[String: Any]] = [
            ["t3_close_pct": 4.0],
            ["t3_close_pct": NSNull()],
            [:],
            ["t3_close_pct": "6.5"],                    // 字符串数字也算（PredictRules.num 口径）
            ["t3_close_pct": -2.0],
        ]
        let s = OutcomeWindows.stats(rows: rows, column: "t3_close_pct")
        XCTAssertEqual(s?.total, 3)
        XCTAssertEqual(s?.wins, 2)
        XCTAssertEqual(s?.avgProfit, PyMath.round((4.0 + 6.5 - 2.0) / 3, 2))
        XCTAssertEqual(s?.winrate, PyMath.round(2.0 / 3 * 100, 1))
    }

    /// 收益恰为 0 不算赢（与 `disc_win = 1 if profit > 0` 同口径）
    func testStatsTreatsZeroProfitAsNotWin() {
        let rows: [[String: Any]] = [["t3_close_pct": 0.0], ["t3_close_pct": 1.0]]
        let s = OutcomeWindows.stats(rows: rows, column: "t3_close_pct")
        XCTAssertEqual(s?.wins, 1)
        XCTAssertEqual(s?.winrate, 50.0)
    }

    /// 聚合必须走 `PyMath.sum`（Neumaier 补偿），不能用朴素累加 ——
    /// 也不能下推成 SQL 的 `AVG()`（SQLite 的累加是朴素加法，同样会丢这个 1）。
    /// `[1e16, 1, -1e16]`：朴素累加得 0，补偿求和得 1。
    func testStatsUsesPyMathSumNotNaiveAccumulation() {
        let vals = [1e16, 1.0, -1e16]
        XCTAssertEqual(PyMath.sum(vals), 1.0, "补偿求和保住被吞掉的 1")
        XCTAssertEqual(vals.reduce(0.0) { $0 + $1 }, 0.0, "朴素累加把它吞掉了 —— 这就是差异")

        let rows: [[String: Any]] = vals.map { ["t5_close_pct": $0] as [String: Any] }
        let s = OutcomeWindows.stats(rows: rows, column: "t5_close_pct")
        XCTAssertEqual(s?.total, 3)
        XCTAssertEqual(s?.wins, 2)                       // 1e16 与 1 为正，−1e16 不是
        XCTAssertEqual(s?.avgProfit, PyMath.round(1.0 / 3, 2), "0.33；朴素累加会给出 0.0")
        XCTAssertNotEqual(s?.avgProfit, 0.0)
    }
}

/// `MultiWindowSummary` 的契约测试 —— 界面上那张「多观察窗」卡的唯一自动化覆盖。
final class MultiWindowSummaryTests: XCTestCase {

    private func rows(_ selDate: String, _ items: [(String, Double?)]) -> [[String: Any]] {
        items.map { ["sel_date": selDate, "code": $0.0, "disc_profit": $0.1 ?? NSNull(),
                     "close_profit": $0.1 ?? NSNull(), "t3_close_pct": NSNull(),
                     "t5_close_pct": NSNull()] }
    }

    func testEmptyRowsProduceEmptySummary() {
        let m = MultiWindowSummary.make(rows: [])
        XCTAssertTrue(m.isEmpty)
        XCTAssertEqual(m.days, 0)
        XCTAssertNil(m.l3); XCTAssertNil(m.t1); XCTAssertNil(m.t3); XCTAssertNil(m.t5)
        XCTAssertFalse(m.longestWindowReady)
    }

    /// `days` 数的是**选股日**，不是行数（一行 = 一只标的）
    func testDaysCountsDistinctSelDates() {
        let r = rows("2026-01-01", [("600001", 1.0), ("600002", -1.0), ("600003", 2.0)])
            + rows("2026-01-02", [("600001", 1.0)])
        XCTAssertEqual(MultiWindowSummary.make(rows: r).days, 2)
    }

    /// 本文件最重要的一条：四个口径的**分母各算各的**。
    /// `disc_profit` 全有值、`t5_close_pct` 只有一条 —— 用共同分母会把
    /// "还没到期的"当成"没涨"，凭空压低长窗胜率，**而且不会报错**。
    func testEachWindowKeepsItsOwnDenominator() {
        let r: [[String: Any]] = [
            ["sel_date": "2026-01-01", "disc_profit": 2.0, "close_profit": 1.0,
             "t3_close_pct": 3.0, "t5_close_pct": -1.0],
            ["sel_date": "2026-01-01", "disc_profit": -1.0, "close_profit": -0.5,
             "t3_close_pct": NSNull(), "t5_close_pct": NSNull()],
            ["sel_date": "2026-01-02", "disc_profit": 1.0, "close_profit": 0.2,
             "t3_close_pct": NSNull(), "t5_close_pct": NSNull()],
        ]
        let m = MultiWindowSummary.make(rows: r)
        XCTAssertEqual(m.l3?.total, 3)
        XCTAssertEqual(m.t1?.total, 3)
        XCTAssertEqual(m.t3?.total, 1, "T+3 只有 1 条到期")
        XCTAssertEqual(m.t5?.total, 1, "T+5 只有 1 条到期")
        XCTAssertEqual(m.t3?.winrate, 100.0, "若用共同分母会算成 33.3 —— 那就是这条要防的错")
        XCTAssertEqual(m.t5?.winrate, 0.0, "唯一的 T+5 样本是亏的")
        XCTAssertEqual(m.t5?.avgProfit, -1.0)
        XCTAssertTrue(m.longestWindowReady)
    }

    /// 护栏：`t1` 必须来自**既有的** `close_profit`，不是新开的列。
    /// 若哪天有人加了 `t1_close_pct`，这条会红 —— 那是"同一列存两遍"的复发。
    func testT1ComesFromExistingCloseProfit() {
        let r: [[String: Any]] = [
            ["sel_date": "2026-01-01", "disc_profit": 1.0, "close_profit": 2.5],
        ]
        let m = MultiWindowSummary.make(rows: r)
        XCTAssertEqual(m.t1?.avgProfit, 2.5, "t1 读的是 close_profit")
        XCTAssertEqual(m.t1?.total, 1)
        XCTAssertEqual(OutcomeWindow.allCases.map(\.column), ["t3_close_pct", "t5_close_pct"],
                       "库里只该有这两个观察窗列（+ 基准价 sel_price，它不是窗）")
    }

    /// 部分窗没样本时，`isEmpty` 仍为 false（有 l3 就值得展示）
    func testSummaryIsNotEmptyWhenOnlyShortWindowHasData() {
        let m = MultiWindowSummary.make(rows: rows("2026-01-01", [("600001", 1.0)]))
        XCTAssertFalse(m.isEmpty)
        XCTAssertNotNil(m.l3)
        XCTAssertNil(m.t3)
        XCTAssertFalse(m.longestWindowReady, "T+5 还没样本 → 界面要提示「还在累积」")
    }
}

/// `OutcomeWindowBackfill` 的契约测试。
///
/// 「只写 NULL」那条不变量写在 SQL 里（`AND <col> IS NULL`），单测覆盖不到 ——
/// 它由真实库自检负责（库副本 + 一次性驱动）。
/// 这里覆盖的是**编排**：谁该补、按什么顺序取、取不到怎么办。
final class OutcomeWindowBackfillTests: XCTestCase {

    // MARK: - 构造工具

    /// 2026-01-01 起连续 n 天（`TradingCalendar` 只排序字符串，不校验星期几）
    private func manyDays(_ n: Int) -> [String] {
        var out: [String] = []
        for i in 0..<n { out.append(String(format: "2026-01-%02d", i + 1)) }
        return out
    }

    private func row(_ selDate: String, _ code: String = "600000",
                     price: Double? = 10, t3: Double? = nil, t5: Double? = nil)
        -> PhaseStore.OutcomeWindowRow {
        PhaseStore.OutcomeWindowRow(selDate: selDate, code: code,
                                    selPrice: price, t3: t3, t5: t5)
    }

    private func bar(_ day: String, _ close: Double) -> KLineBar {
        KLineBar(day: day, open: close, high: close, low: close, close: close, volume: 1000)
    }

    // MARK: - 窗口下界

    func testLowerBoundTakesLastLookbackDays() {
        let cal = TradingCalendar(days: manyDays(30))
        // maxLookbackDays = 12 → 最近 12 天里最早的那天 = 第 19 天（1-based）→ 01-19
        XCTAssertEqual(OutcomeWindowBackfill.lowerBound(cal), "2026-01-19")
    }

    func testLowerBoundClampsToAvailableDays() {
        let cal = TradingCalendar(days: manyDays(5))
        XCTAssertEqual(OutcomeWindowBackfill.lowerBound(cal), "2026-01-01",
                       "日历比回填窗口短时取下界 = 最早那天，不是崩/越界")
    }

    func testLowerBoundNilOnEmptyCalendar() {
        XCTAssertNil(OutcomeWindowBackfill.lowerBound(TradingCalendar(days: [])))
    }

    // MARK: - 规划

    /// 两道闸门之一：**已有值永不重算**
    func testPlanSkipsWindowsThatAlreadyHaveValues() {
        let cal = TradingCalendar(days: manyDays(10))
        // t3 已有值、t5 没有 → 只补 t5
        let p = OutcomeWindowBackfill.plan(rows: [row("2026-01-01", t3: 3.0)], calendar: cal)
        XCTAssertEqual(p.pending.map(\.window), [.t5])
        XCTAssertEqual(p.rowsWithoutBase, 0)
    }

    /// 两道闸门之二：**未到期不补**（日历里还没有那个交易日）
    func testPlanSkipsWindowsNotYetDue() {
        let cal = TradingCalendar(days: manyDays(3))       // 01-01..01-03
        let p = OutcomeWindowBackfill.plan(rows: [row("2026-01-01")], calendar: cal)
        XCTAssertTrue(p.pending.isEmpty, "01-01 之后只有 2 天，T+3/T+5 都还没到期")
    }

    func testPlanEmitsBothWindowsWhenBothDue() {
        let cal = TradingCalendar(days: manyDays(10))
        let p = OutcomeWindowBackfill.plan(rows: [row("2026-01-01")], calendar: cal)
        XCTAssertEqual(p.pending.map(\.window), [.t3, .t5], "同一行的窗按 allCases 顺序")
        XCTAssertEqual(p.pending.map(\.targetDay), ["2026-01-04", "2026-01-06"])
    }

    /// 没有基准价的存量行**整行跳过**并单独计数（不猜）
    func testPlanSkipsRowsWithoutBase() {
        let cal = TradingCalendar(days: manyDays(10))
        let p = OutcomeWindowBackfill.plan(
            rows: [row("2026-01-01", price: nil), row("2026-01-01", "600001", price: 0)],
            calendar: cal)
        XCTAssertTrue(p.pending.isEmpty)
        XCTAssertEqual(p.rowsWithoutBase, 2, "nil 与 0 都不算基准价")
    }

    /// 规划不改变输入顺序（行序 → 窗序）—— 出错时"补了哪几只"要能一眼对上
    func testPlanPreservesRowOrder() {
        let cal = TradingCalendar(days: manyDays(10))
        let p = OutcomeWindowBackfill.plan(
            rows: [row("2026-01-01", "600001"), row("2026-01-02", "600002")],
            calendar: cal)
        XCTAssertEqual(p.pending.map { "\($0.code)@\($0.selDate)" },
                       ["600001@2026-01-01", "600001@2026-01-01",
                        "600002@2026-01-02", "600002@2026-01-02"])
    }

    // MARK: - 计算

    /// 按 code 归组：3 个待补项横跨 2 只标的 → **只取 2 次日K**
    func testComputeGroupsByCodeAndFetchesOncePerCode() {
        let cal = TradingCalendar(days: manyDays(10))
        var calls: [String] = []
        let p = OutcomeWindowBackfill.plan(
            rows: [row("2026-01-01", "600001"), row("2026-01-01", "600002")], calendar: cal)
        XCTAssertEqual(p.pending.count, 4)                 // 2 行 × 2 窗

        let c = OutcomeWindowBackfill.compute(p.pending) { code in
            calls.append(code)
            return [bar("2026-01-04", 11.0), bar("2026-01-06", 12.0)]
        }
        XCTAssertEqual(c.codesFetched, 2)
        XCTAssertEqual(calls, ["600001", "600002"], "按 code 字典序取（可复现）")
        XCTAssertEqual(c.fills.count, 4)
        XCTAssertTrue(c.unavailable.isEmpty)
    }

    /// 取不到目标日收盘 → `unavailable`，**绝不写 0**（0 会被当成平盘）
    func testComputeMarksUnavailableWhenTargetDayMissing() {
        let cal = TradingCalendar(days: manyDays(10))
        let p = OutcomeWindowBackfill.plan(rows: [row("2026-01-01")], calendar: cal)
        let c = OutcomeWindowBackfill.compute(p.pending) { _ in
            [bar("2026-01-02", 11.0)]                       // 只有 T+1，没有 T+3/T+5
        }
        XCTAssertTrue(c.fills.isEmpty, "取不到就留空，不写 0")
        XCTAssertEqual(c.unavailable.count, 2)
        XCTAssertEqual(c.codesFetched, 1)
    }

    func testComputeFillsCarryTheRightWindowAndValue() {
        let cal = TradingCalendar(days: manyDays(10))
        let p = OutcomeWindowBackfill.plan(rows: [row("2026-01-01")], calendar: cal)
        let c = OutcomeWindowBackfill.compute(p.pending) { _ in
            [bar("2026-01-04", 11.0), bar("2026-01-06", 9.5)]
        }
        let byWindow = Dictionary(uniqueKeysWithValues: c.fills.map { ($0.0.window, $0.1) })
        XCTAssertEqual(byWindow[.t3], 10.0)                // (11 − 10) / 10 × 100
        XCTAssertEqual(byWindow[.t5], -5.0)                // (9.5 − 10) / 10 × 100
    }

    func testComputeIsEmptyForEmptyInput() {
        let c = OutcomeWindowBackfill.compute([]) { _ in XCTFail("不该取日K"); return [] }
        XCTAssertTrue(c.fills.isEmpty)
        XCTAssertEqual(c.codesFetched, 0)
    }

    // MARK: - 报告文案

    func testReportSummaryWording() {
        var r = OutcomeWindowBackfill.Report()
        XCTAssertTrue(r.isNoop)
        XCTAssertEqual(r.summary, "多观察窗：无可补行")

        r.pending = 5; r.filled = 5
        XCTAssertEqual(r.summary, "多观察窗：补 5 条")

        r.unavailable = 2; r.rowsWithoutBase = 3
        XCTAssertEqual(r.summary, "多观察窗：补 5 条，2 条取不到目标日收盘（留空），3 行无基准价（存量行，跳过）")

        r.error = "disk full"
        XCTAssertTrue(r.summary.hasPrefix("多观察窗回填失败："))
        XCTAssertTrue(r.summary.contains("disk full"))
    }

    /// 只有"无基准价的行"时不算 noop —— 那是个需要被看见的状态（存量行永远补不上）
    func testReportWithOnlyLegacyRowsIsNotNoop() {
        var r = OutcomeWindowBackfill.Report()
        r.rowsWithoutBase = 4
        XCTAssertFalse(r.isNoop)
        XCTAssertEqual(r.summary, "多观察窗：补 0 条，4 行无基准价（存量行，跳过）")
    }
}
