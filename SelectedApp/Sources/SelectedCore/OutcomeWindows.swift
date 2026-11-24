import Foundation

// MARK: - 观察窗

/// 「多观察窗回测」的窗口。
///
/// ⚠ **没有 T+1**：T+1 收盘涨跌**已经存在**，就是 `stock_outcomes.close_profit`。
/// 再补一列 `t1_close_pct` 等于同一值存两遍 —— 两个字段迟早分叉，且分叉时界面上
/// 两个数看着都正常。T+1 一律复用 `close_profit`。
public enum OutcomeWindow: String, CaseIterable, Sendable {
    case t3
    case t5

    /// 相对选股日的**交易日**偏移
    public var offset: Int {
        switch self {
        case .t3: return 3
        case .t5: return 5
        }
    }

    /// 库列名（Swift-only 列，见 `DBBootstrap.ensureSwiftOnlyMigrations`）
    public var column: String {
        switch self {
        case .t3: return "t3_close_pct"
        case .t5: return "t5_close_pct"
        }
    }

    /// 界面标签
    public var label: String {
        switch self {
        case .t3: return "持有 3 日"
        case .t5: return "持有 5 日"
        }
    }
}

// MARK: - 单窗统计

/// 一个窗口在一批行上的胜率/平均收益。
///
/// ⚠ **每个窗的 `total` 必须各算各的**：`close_profit` 在 T+1 就有值，
/// `t5_close_pct` 要等 5 个交易日 → 同一批标的下各窗的**有效样本数必然不同**。
/// 用同一个分母算胜率 = 把"还没到期的"当成"没涨" —— 凭空压低长窗胜率，且不会报错。
public struct WindowStats: Equatable, Sendable {
    /// 该窗的**有效样本数**（这一列非 null 的行数）
    public let total: Int
    /// 收益 > 0 的条数
    public let wins: Int
    /// 平均收益（`PyMath.round(_, 2)`）
    public let avgProfit: Double
    /// 胜率（百分数，`PyMath.round(_, 1)`）
    public let winrate: Double

    public init(total: Int, wins: Int, avgProfit: Double, winrate: Double) {
        self.total = total; self.wins = wins
        self.avgProfit = avgProfit; self.winrate = winrate
    }
}

// MARK: - 跨日汇总

/// 跨日「多观察窗」汇总 —— 回答：
///
/// > 「这个策略的票，**次日午前卖是对的，还是拿三天更对**？」
///
/// 四个口径并列：`l3`（次日午前，纪律口径，可执行主口径）/ `t1`（次日收盘，既有的
/// `close_profit`）/ `t3` / `t5`。
///
/// ⚠ **每个窗的样本数必须各算各的**（`WindowStats.total`）：`disc_profit` 在 T+1 就有值，
/// `t5_close_pct` 要等 5 个交易日 → 长窗样本天然比短窗少。
/// 用一个共同分母会把"还没到期的"当成"没涨" —— 凭空压低长窗胜率，**而且不会报错**。
/// 界面上因此**必须同时显示样本数**，否则读不出"T+5 胜率低"到底是策略问题还是样本问题。
public struct MultiWindowSummary: Equatable, Sendable {
    /// 参与汇总的**选股日**数（不是行数）
    public let days: Int
    /// 纪律口径（次日午前窗口内首次触及目标价）—— 可执行主口径
    public let l3: WindowStats?
    /// 次日收盘（既有 `close_profit`，**不是**新列）
    public let t1: WindowStats?
    public let t3: WindowStats?
    public let t5: WindowStats?

    /// 从 `stock_outcomes` 原始行汇总。
    ///
    /// ⚠ 传进来的必须是**原始行**而不是 SQL 聚合结果 —— 浮点求和要走 `PyMath.sum`
    ///   （SQLite 的 `SUM`/`AVG` 是朴素加法，`[1e16, 1, -1e16]` 会丢掉那个 1）。
    /// ⚠ `skipped = 1` 的行必须由调用方（SQL）先滤掉，这里不再判。
    public static func make(rows: [[String: Any]]) -> MultiWindowSummary {
        MultiWindowSummary(
            days: Set(rows.compactMap { $0["sel_date"] as? String }).count,
            l3: OutcomeWindows.stats(rows: rows, column: "disc_profit"),
            t1: OutcomeWindows.stats(rows: rows, column: "close_profit"),
            t3: OutcomeWindows.stats(rows: rows, column: OutcomeWindow.t3.column),
            t5: OutcomeWindows.stats(rows: rows, column: OutcomeWindow.t5.column))
    }

    /// 四个窗一个样本都没有（界面整卡不显示）
    public var isEmpty: Bool { l3 == nil && t1 == nil && t3 == nil && t5 == nil }

    /// 最长窗（T+5）是否已有样本 —— 界面据此提示"还在累积"
    public var longestWindowReady: Bool { t5 != nil }
}

// MARK: - 纯计算

/// 多观察窗的**纯函数**层：目标日推导 / 到期判定 / 单窗涨跌 / 单窗统计。
///
/// 与网络、数据库完全解耦 —— 回填器（`OutcomeWindowBackfill`）与界面聚合都调这里，
/// 保证"引擎算的"与"界面显示的"是同一套口径。
public enum OutcomeWindows {

    /// 回填只扫最近这么多个**交易日**的行。
    ///
    /// 更早的历史行由「历史日期批量重跑」负责 —— 混进来会让
    /// 请求量随库龄线性增长，两件事互相拖累。
    public static let maxLookbackDays = 12

    // MARK: 目标日

    /// 目标交易日 = `selDate` 之后的第 `offset` 个**已发生**交易日。
    ///
    /// ⚠ **必须走日历索引，不能用 `shiftTradingDay`**：后者的未来日会回落"下一个工作日"
    /// 并标 `uncertain`，而本函数要的恰恰是"**真的发生了没有**" —— 返回 `nil`
    /// 就是"还没到期，别去算"。
    ///
    /// ⚠ 不用先判断 `selDate` 本身是不是交易日：`days.firstIndex(where: { $0 > selDate })`
    /// 无论选股日在不在日历里，取到的都是 **T+1**，语义统一。
    public static func targetDay(selDate: String, offset: Int, calendar: TradingCalendar) -> String? {
        guard offset >= 1, !selDate.isEmpty else { return nil }
        guard let firstAfter = calendar.days.firstIndex(where: { $0 > selDate }) else { return nil }
        let idx = firstAfter + (offset - 1)
        guard idx < calendar.days.count else { return nil }   // 还没发生 → 未到期
        return calendar.days[idx]
    }

    /// 该选股日上**当前已到期**的窗口（可能 0 / 1 / 2 个）。
    ///
    /// 到期 = 目标交易日已经真实发生过。停牌不算"没到期" —— 那种情况
    /// 目标日是有的，只是日K里取不到收盘 → 交给 `closePct` 返 `nil`（宁缺勿错）。
    public static func dueWindows(selDate: String, calendar: TradingCalendar) -> [OutcomeWindow] {
        OutcomeWindow.allCases.filter { targetDay(selDate: selDate, offset: $0.offset,
                                                   calendar: calendar) != nil }
    }

    // MARK: 单窗涨跌

    /// 目标日收盘相对 `selPrice` 的涨跌%（round 2）。取不到 → `nil`。
    ///
    /// ⚠ 收盘价为 **0 视为"没有值"** → `nil`（判据是 `px != 0`，不是 `px > 0`）。
    /// ⚠ `round` 必须走 `PyMath.round`（半偶 + 基于 double 精确值），不能用 `Swift.round`。
    public static func closePct(selPrice: Double, targetDay: String, bars: [KLineBar]) -> Double? {
        guard selPrice > 0, !targetDay.isEmpty else { return nil }
        guard let bar = bars.first(where: { $0.day == targetDay }) else { return nil }
        let px = bar.close
        guard px != 0 else { return nil }
        return PyMath.round((px - selPrice) / selPrice * 100, 2)
    }

    // MARK: 单窗统计

    /// 一批行在某一列上的胜率/平均收益。该列全为 null → `nil`（**不是** 0 胜率）。
    ///
    /// ⚠ 浮点求和走 `PyMath.sum`（Neumaier 补偿）：朴素 `reduce(0.0){+}` 会在末位累积误差，
    /// 除以条数再 round 后可能差 0.01。
    public static func stats(rows: [[String: Any]], column: String) -> WindowStats? {
        var profits: [Double] = []
        profits.reserveCapacity(rows.count)
        for r in rows {
            // ⚠ `PredictRules.num` 对 NSNull 与缺失键都返 nil（NSNull 不是 NSNumber）
            guard let v = PredictRules.num(r[column]) else { continue }
            profits.append(v)
        }
        guard !profits.isEmpty else { return nil }
        let wins = profits.reduce(0) { $0 + ($1 > 0 ? 1 : 0) }
        let avg = PyMath.sum(profits) / Double(profits.count)
        return WindowStats(total: profits.count, wins: wins,
                           avgProfit: PyMath.round(avg, 2),
                           winrate: PyMath.round(Double(wins) / Double(profits.count) * 100, 1))
    }
}
