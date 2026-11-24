import Foundation

/// 中国市场时间（Asia/Shanghai）—— 全项目日期/时刻的**唯一出口**。
///
/// 存在的理由：`DateFormatter()` 与 `Calendar.current` 跟随**系统时区**，而 A 股的开盘时段、
/// 交易日归属、以及引擎写入 SQLite 的 `date` 都按北京时间定义。
/// 设备时区一旦不是 Asia/Shanghai（出国、虚拟机、误设），就会出现：
///   · 按**本地**时刻触发扫描，而北京早已收盘 → 扫的是另一天的数据；
///   · `dateKey` 与引擎的交易日错位一天 → 看板把非今日当今日 → 用错日数据决策；
///   · 周末/交易日判定按本地日期误判。
/// 统一走本枚举后，上述判定与设备时区解耦。
public enum ChinaTime {
    public static let zone = TimeZone(identifier: "Asia/Shanghai") ?? TimeZone.current

    public static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        return c
    }()

    /// 构造一个已固定 `Asia/Shanghai` + `en_US_POSIX` 的格式化器。
    ///
    /// ⚠ `en_US_POSIX` 把**日历**钉死为公历：设备设为佛历/和历等非公历时，
    ///   `yyyy-MM-dd` 会被解析成整体错年（K 线时间轴全错），格式化也会输出错年。
    ///   只设 `timeZone` 而漏 `locale` 解决不了这个问题。
    ///   需要日期格式时一律走这里，不要再裸建 `DateFormatter()`。
    public static func formatter(_ fmt: String) -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = fmt
        f.timeZone = zone
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }

    // 两个高频格式化器缓存为常量：`day()`/`hhmm()` 被 Store.today / Scheduler.dateKey /
    // DateChip / LiveQuotes 的 body 高频调用，每次裸建 DateFormatter 分配开销大。
    // DateFormatter 的格式化/解析调用本身线程安全，可共享实例；输出与 locale/时区不变。
    private static let dayFmt = formatter("yyyy-MM-dd")
    private static let hhmmFmt = formatter("HH:mm")
    private static let stampFmt = formatter("yyyy-MM-dd HH:mm:ss")

    /// yyyy-MM-dd 格式化器（北京时间）。替代散落各处的 `DateFormatter()` 裸建，
    /// 它默认跟随系统时区 → 换时区后日期会整体错位。
    public static var dayFormatter: DateFormatter { dayFmt }

    /// yyyy-MM-dd HH:mm:ss（北京时间）—— 落库时间戳的统一格式
    public static func stamp(_ date: Date = Date()) -> String { stampFmt.string(from: date) }

    /// yyyy-MM-dd（北京时间）
    public static func day(_ date: Date = Date()) -> String {
        dayFmt.string(from: date)
    }

    /// HH:mm（北京时间）
    public static func hhmm(_ date: Date = Date()) -> String {
        hhmmFmt.string(from: date)
    }

    public static func parseDay(_ day: String) -> Date? {
        dayFmt.date(from: day)
    }

    /// 北京时间当日已过分钟数（0..1439）
    public static func minutesOfDay(_ date: Date = Date()) -> Int {
        calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
    }

    /// 星期（1=周日 … 7=周六，与 Calendar 一致）
    public static func weekday(_ date: Date = Date()) -> Int {
        calendar.component(.weekday, from: date)
    }

    public static func isWeekend(_ date: Date = Date()) -> Bool {
        weekday(date) == 1 || weekday(date) == 7
    }

    public static func shiftDays(_ day: String, _ delta: Int) -> String? {
        guard let d = parseDay(day),
              let n = calendar.date(byAdding: .day, value: delta, to: d) else { return nil }
        return self.day(n)
    }

    /// `day` 之前的最近 `count` 个**非周末**自然日（新→旧）。
    ///
    /// ⚠ 语义是"往前数够 `count` 个**工作日**"，不是"往前取 `count` 个自然日再剔周末" ——
    /// 后者在跨周末时会悄悄少给几天（周二往前 5 个自然日只剩 3 天），
    /// 而调用方要的是"窗口够宽"。
    ///
    /// ⚠ **只跳周末、不跳节假日**：节假日要靠调用方自己的取数返回空来发现
    /// （那会多花几次请求，但窗口只有几天，代价有界且每天只发生一次）。
    /// 不在这里猜节假日 —— 本项目的节假日判定已经集中在 `DataSources.isTradingDay()`，
    /// 再写一份必然漂移。
    ///
    /// **单一实现**：龙虎榜与涨停池的回看窗口都走这里。
    public static func recentWeekdays(before day: String, count: Int) -> [String] {
        guard count > 0, let base = dayFormatter.date(from: day) else { return [] }
        var out: [String] = []
        // 迭代上限：最坏情况连着一整个周末，count*2+3 个自然日内一定能凑够 count 个工作日
        for i in 1...(count * 2 + 3) {
            if out.count >= count { break }
            guard let d = calendar.date(byAdding: .day, value: -i, to: base) else { continue }
            let weekday = calendar.component(.weekday, from: d)   // 1=周日 7=周六
            if weekday == 1 || weekday == 7 { continue }
            out.append(self.day(d))
        }
        return out
    }
}
