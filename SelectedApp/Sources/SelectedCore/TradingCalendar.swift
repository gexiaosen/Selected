import Foundation

/// Selected 引擎 — 交易日历（唯一事实来源：指数日K本身）
///
/// **为什么不用节假日表**：A 股节假日需要每年维护，还包含调休、临时休市，漏一次就会
/// 在错误的日期推进 T+1，进而把错误日的数据写进 `stock_outcomes` 污染调优标签。
/// 指数日K就是"真实发生过的交易记录"，直接用它推导，天然覆盖所有节假日与调休。
///
/// **能力边界（不猜）**：
///   · 已发生的交易日 —— 精确（来自日K）
///   · 未来的交易日 —— 日K里没有，回落"下一个工作日"并标记 `uncertain`
///
/// 数据来源：调用方注入交易日列表（App 已有指数日K 的直连能力），本类不自己抓取、
/// 不维护缓存。
public struct TradingCalendar {

    /// 升序的**已发生**交易日（YYYY-MM-DD）
    public let days: [String]
    private let daySet: Set<String>

    public init(days: [String]) {
        self.days = days.sorted()
        self.daySet = Set(self.days)
    }

    /// 从指数日K构造（去重取日期，升序）
    public init(indexBars: [KLineBar]) {
        self.init(days: Array(Set(indexBars.map(\.day).filter { !$0.isEmpty })))
    }

    // MARK: 查询

    public func isTradingDay(_ day: String) -> Bool { daySet.contains(day) }

    /// day **之前**最近的一个已发生交易日；没有则回落上一个工作日
    public func prevTradingDay(_ day: String) -> String {
        guard let d = Self.parse(day) else { return "" }
        let past = days.filter { $0 < day }
        if let last = past.last { return last }
        var n = Self.addDays(d, -1)
        while Self.pythonWeekday(n) >= 5 { n = Self.addDays(n, -1) }
        return Self.format(n)
    }

    /// day **之后**最近的一个交易日。
    ///
    /// 顺序：① 日K里已有的未来交易日 → 取最近的（历史回放走这条）
    ///      ② 日K里没有 且 调用方确认「本机当日就是交易日」→ today 才是真实 T+1
    ///      ③ 都不满足 → 回落下一个工作日，并置 `uncertain = true`
    ///
    /// ⚠ 只在 ② 明确成立时才取 today：否则（回放某个历史选股日）会把 T+1 错认成今天。
    public func nextTradingDay(_ day: String, uncertain: inout Bool,
                        today: String? = nil, todayIsTrading: Bool = false) -> String {
        guard let d = Self.parse(day) else { return "" }
        if let next = days.first(where: { $0 > day }) { return next }
        if let t = today, todayIsTrading, t > day { return t }
        uncertain = true
        var n = Self.addDays(d, 1)
        while Self.pythonWeekday(n) >= 5 { n = Self.addDays(n, 1) }
        return Self.format(n)
    }

    /// 按交易日偏移（offset 可正可负）。为负/超出已知范围时回落工作日推算。
    public func shiftTradingDay(_ day: String, _ offset: Int) -> String {
        var cur = day
        if offset == 0 { return cur }
        let step = offset > 0 ? 1 : -1
        for _ in 0..<abs(offset) {
            var unc = false
            cur = step > 0 ? nextTradingDay(cur, uncertain: &unc)
                           : prevTradingDay(cur)
            if cur.isEmpty { break }
        }
        return cur
    }

    // MARK: 日期工具（纯日期运算，不涉时区）

    private static let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return c
    }()

    /// "yyyy-MM-dd" → DateComponents 派生的 Date；失败返回 nil
    public static func parse(_ s: String) -> Date? {
        let parts = s.split(separator: "-")
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d
        return cal.date(from: c)
    }

    public static func format(_ d: Date) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public static func addDays(_ d: Date, _ delta: Int) -> Date {
        cal.date(byAdding: .day, value: delta, to: d) ?? d
    }

    /// Python 的 `date.weekday()`：周一=0 … 周日=6（Calendar 的 weekday 是 周日=1…周六=7）
    public static func pythonWeekday(_ d: Date) -> Int {
        let w = cal.component(.weekday, from: d)     // 1=周日 … 7=周六
        return (w + 5) % 7
    }
}
