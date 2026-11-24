import Foundation

/// 「多观察窗回测」的回填器。
///
/// ## 为什么需要"回填"而不是"复盘时一起算"
///
/// 复盘在 **T+1 15:05** 执行，而 T+3 收盘要再等 2 个交易日、T+5 再等 4 个。
/// 这两列**不可能**在 T+1 那次复盘里写出来 —— 只能在**之后的复盘运行中**补。
/// 本模块就是"有界、幂等、按 code 归组"的补数器。
///
/// ## 三条纪律
///
/// 1. **只写 NULL**：已算出的值永不重算。否则历史标签会随数据源事后修正而漂移，
///    同一行两次读到的数不同 —— "多观察窗"就失去可比性（见 `PhaseStore.fillOutcomeWindows`）。
/// 2. **按 code 归组**：一次 `fetchDailyKline` 覆盖该 code 在窗口内的**所有**待补
///    (sel_date, 窗) 组合，请求数从"待补行数"降到"待补的不同标的数"。
/// 3. **窗口有界**：只扫最近 `OutcomeWindows.maxLookbackDays` 个交易日的行；
///    更早的历史行由「历史日期批量重跑」负责。
///
/// ## 与其他模块的分工
///
/// - `OutcomeWindows` 出**纯函数**（目标日推导 / 到期判定 / 单窗涨跌）
/// - `PhaseStore` 出**数据库读写**（`outcomeWindowRows` / `fillOutcomeWindows`）
/// - 本模块只做**编排**：把两边接起来，中间不掺任何新口径
public enum OutcomeWindowBackfill {

    /// 一条待补记录（一个 sel_date × code × 窗）
    public struct Pending: Equatable, Sendable {
        public let selDate: String
        public let code: String
        /// 基准价（选股日价格）—— 来自 `stock_outcomes.sel_price`
        public let selPrice: Double
        public let window: OutcomeWindow
        /// 目标交易日（已确认真实发生过）
        public let targetDay: String
    }

    /// 一次回填的结果（供日志与通知用）
    public struct Report: Sendable {
        /// SQL 取回的行数（仍缺至少一个观察窗的行）
        public var rowsScanned = 0
        /// 到期且该补的 (行 × 窗) 数
        public var pending = 0
        /// 实际取日K的标的数（= 不同 code 数）
        public var codesFetched = 0
        /// 成功写库的条数
        public var filled = 0
        /// 到期但日K里取不到目标日收盘（停牌 / 新股 / 窗口没覆盖）→ 留 NULL
        public var unavailable = 0
        /// 没有基准价（`sel_price IS NULL` 的存量行）→ 算不了，跳过
        public var rowsWithoutBase = 0
        /// 写库失败原因（非 nil 时 `filled` 不可信）
        public var error: String?

        /// 这一轮什么都没补（绝大多数日常运行的情形）
        public var isNoop: Bool { pending == 0 && rowsWithoutBase == 0 }

        /// 一行摘要（日志/通知用）
        public var summary: String {
            if let e = error { return "多观察窗回填失败：\(e)" }
            if isNoop { return "多观察窗：无可补行" }
            var s = "多观察窗：补 \(filled) 条"
            if unavailable > 0 { s += "，\(unavailable) 条取不到目标日收盘（留空）" }
            if rowsWithoutBase > 0 { s += "，\(rowsWithoutBase) 行无基准价（存量行，跳过）" }
            return s
        }
    }

    // MARK: - 窗口下界

    /// 只扫最近 `OutcomeWindows.maxLookbackDays` 个**交易日**的行。
    /// 日历为空 → `nil`（连"哪天是交易日"都不知道，谈不上回填）。
    public static func lowerBound(_ calendar: TradingCalendar) -> String? {
        guard !calendar.days.isEmpty else { return nil }
        let n = min(OutcomeWindows.maxLookbackDays, calendar.days.count)
        return calendar.days[calendar.days.count - n]
    }

    // MARK: - 规划（纯函数）

    /// 哪些 (行 × 窗) 该补。
    ///
    /// 两道闸门，缺一不可：
    /// - **该窗还没有值**（`r.value(for:) == nil`）→ 已有值永不重算
    /// - **该窗已到期**（`OutcomeWindows.targetDay` 非 nil）→ 目标日真实发生过
    ///
    /// ⚠ 没有基准价（`sel_price IS NULL`）的行**整行跳过**并单独计数，不猜；
    ///   这些行的 T+3/T+5 永远补不上（有意接受）。
    public static func plan(rows: [PhaseStore.OutcomeWindowRow], calendar: TradingCalendar)
        -> (pending: [Pending], rowsWithoutBase: Int) {
        var pending: [Pending] = []
        var noBase = 0
        for r in rows {
            guard let price = r.selPrice, price > 0 else { noBase += 1; continue }
            for w in OutcomeWindow.allCases {
                guard r.value(for: w) == nil else { continue }          // 已有值 → 不重算
                guard let target = OutcomeWindows.targetDay(selDate: r.selDate, offset: w.offset,
                                                            calendar: calendar) else { continue }  // 未到期
                pending.append(Pending(selDate: r.selDate, code: r.code, selPrice: price,
                                       window: w, targetDay: target))
            }
        }
        return (pending, noBase)
    }

    // MARK: - 计算（纯函数，取K线可注入）

    /// 按 code 归组取一次日K，算出每个待补项。
    ///
    /// ⚠ **请求顺序按 code 字典序**：不是为了好看，是为了**可复现** ——
    /// 出错时"补了哪几只"必须能一眼对上（`Dictionary` 的遍历顺序不保证稳定）。
    /// ⚠ 取不到目标日收盘的项进 `unavailable`，**留 NULL 而不是写 0**
    ///   （0 会被下游当成"平盘"，与"没数据"完全不同）。
    public static func compute(_ pendings: [Pending], fetchBars: (String) -> [KLineBar])
        -> (fills: [(Pending, Double)], unavailable: [Pending], codesFetched: Int) {
        var byCode: [String: [Pending]] = [:]
        for p in pendings { byCode[p.code, default: []].append(p) }

        var fills: [(Pending, Double)] = []
        var unavailable: [Pending] = []
        var fetched = 0
        for (code, items) in byCode.sorted(by: { $0.key < $1.key }) {
            let bars = fetchBars(code)
            fetched += 1
            for p in items {
                if let pct = OutcomeWindows.closePct(selPrice: p.selPrice,
                                                     targetDay: p.targetDay, bars: bars) {
                    fills.append((p, pct))
                } else {
                    unavailable.append(p)
                }
            }
        }
        return (fills, unavailable, fetched)
    }

    // MARK: - 生产入口

    /// 回填一轮。**幂等**：没有该补的行时是一次纯读。
    ///
    /// - `store` 默认 `PhaseStore.shared`（自带 `query_only` 只读连接 + 串行队列，
    ///   可在后台线程调用 —— 复盘正跑在 `Task.detached` 里）。
    /// - `fetchBars` 默认走 `DataSources.fetchDailyKline`（进程内按 code+日期缓存，
    ///   同一轮内重复取同 code 免费）。
    public static func run(calendar: TradingCalendar,
                           store: PhaseStore = .shared,
                           fetchBars: (String) -> [KLineBar] = { DataSources.fetchDailyKline($0) }
    ) -> Report {
        var rep = Report()
        guard let since = lowerBound(calendar) else { return rep }

        let rows = store.outcomeWindowRows(since: since)
        rep.rowsScanned = rows.count

        let p = plan(rows: rows, calendar: calendar)
        rep.pending = p.pending.count
        rep.rowsWithoutBase = p.rowsWithoutBase
        guard !p.pending.isEmpty else { return rep }

        let c = compute(p.pending, fetchBars: fetchBars)
        rep.codesFetched = c.codesFetched
        rep.unavailable = c.unavailable.count
        do {
            try store.fillOutcomeWindows(c.fills.map {
                (selDate: $0.0.selDate, code: $0.0.code, window: $0.0.window, pct: $0.1)
            })
            rep.filled = c.fills.count
        } catch {
            rep.error = "\(error)"
        }
        return rep
    }

    /// 回填一轮 + 打日志。给复盘流程调用。
    ///
    /// ⚠ 日志只在**真补了东西**或**出错**时打：每天打一条"无可补行"会把
    ///   `data_source_logs` 变成噪声，真出事时反而看不见。
    /// ⚠ 异常**不向上抛**：多观察窗是观察型功能，它补不上不该让整个复盘判定失败。
    @discardableResult
    public static func runAndLog(calendar: TradingCalendar,
                                 store: PhaseStore = .shared,
                                 fetchBars: (String) -> [KLineBar] = { DataSources.fetchDailyKline($0) }
    ) -> Report {
        let rep = run(calendar: calendar, store: store, fetchBars: fetchBars)
        if rep.error != nil || rep.filled > 0 || rep.rowsWithoutBase > 0 {
            DataSources.logDataSource("review", "outcome_windows", rep.summary)
        }
        return rep
    }
}
