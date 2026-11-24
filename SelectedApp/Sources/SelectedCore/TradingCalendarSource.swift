import Foundation

/// 交易所**官方**交易日历（深交所 `monthList`）—— "某一天到底开不开盘"的权威判据。
///
/// ## 为什么要换掉"猜"
/// 改造前 `DataSources.tradingDayVerdict` 在工作日靠**上证指数行情的报价日期**反推今天是否
/// 交易日：指数取不到 → `.unknown`（`isTradingDay` 折叠成"开盘"）；报价日期落后 → 判休市。
/// 也就是说"今天开不开盘"的判据其实是"行情有没有在更新"这条**间接证据**，
/// 而节假日恰好是唯一会让它误判的场景（上一交易日的行情照样能取到）。
/// 官方接口一次 1.3KB 的 GET 直接把整月（含未来日、调休）给全。
///
/// ## 口径（2026-11-02 实测）
/// · `data[].jyrq` = 日期、`jybz` = `"1"` 交易日 / `"0"` 休市；**无需 Referer / cookie**。
/// · **发布窗口 = 当月 + 次月**：`month=2026-12` 给满 31 条，`month=2027-01` 给
///   `{"data":[],"nowdate":"2026-11-02"}` —— **空数组是"没发布"，不是"整月休市"**。
///   ⇒ 覆盖不到的日期一律返回 `nil`（未知），绝不返回 `false`。
/// · 只有深市这一家。沪深法定节假日历年一致；**深市单边休市（台风等）未逐日核实**，
///   若发生会把沪市开盘日误判成休市 —— 这条边界写在这里，不掩盖。
/// · fixture / 回放模式**一个请求都不发**（返回 nil）：离线快照是唯一事实来源，
///   "同快照必同结果"不能取决于日历接口通不通。
public enum TradingCalendarSource {

    /// 一个月的官方日历。
    public struct MonthCalendar: Sendable, Equatable {
        /// `"yyyy-MM"`
        public let month: String
        /// 该月**条目数**（正常 = 该月自然日数；明显偏少说明响应被截断）
        public let entryCount: Int
        /// `jybz == "1"` 的日期
        public let tradingDays: Set<String>
        /// `jybz` 明确为 `"0"` 的日期（与 `tradingDays` 一起构成"本表覆盖到的日子"）
        public let closedDays: Set<String>

        /// 某一天的官方结论；**不在本表覆盖范围 → nil**（未知，调用方不许当成休市）。
        public func verdict(_ day: String) -> Bool? {
            if tradingDays.contains(day) { return true }
            if closedDays.contains(day) { return false }
            return nil
        }
    }

    /// 按月缓存的有效期（秒）：日历几乎不变，但**临时休市公告**需要能被看到；
    /// 6 小时 = 全天最多 8 次抓取（每次 1.3KB）。
    public static let cacheTTL: TimeInterval = 6 * 3600

    // MARK: - 解析（纯函数，单测入口）

    /// 响应文本 → 该月日历。非法 JSON / 缺 `data` / 一条都没有 → `nil`。
    public static func parse(_ text: String, month: String) -> MonthCalendar? {
        guard let data = text.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rows = root["data"] as? [[String: Any]], !rows.isEmpty else { return nil }
        var trading: Set<String> = []
        var closed: Set<String> = []
        for row in rows {
            let day = DataSources.pyStr(row["jyrq"])
            guard isDayString(day) else { continue }
            switch DataSources.pyStr(row["jybz"]) {
            case "1": trading.insert(day)
            case "0": closed.insert(day)
            default: break       // 既不是 1 也不是 0 → 不收录（宁缺勿错：它落在"未知"里）
            }
        }
        guard !trading.isEmpty || !closed.isEmpty else { return nil }
        return MonthCalendar(month: month, entryCount: rows.count,
                             tradingDays: trading, closedDays: closed)
    }

    // MARK: - 取数（带缓存）

    /// 某一月的日历；取不到（未发布 / 网络失败 / 形状非法）返回 `nil`。
    public static func calendar(forMonth month: String) -> MonthCalendar? {
        guard isMonthString(month) else { return nil }
        // fixture / 回放：不发请求（理由见文件头）。回放判据用 `isBusy`（跨会话也拦），
        // 与 `HistoryReplayMode` 自己写的纪律一致。
        guard DataSources.fixtureDir == nil, !HistoryReplayMode.isBusy else { return nil }
        let key = "szse_cal|\(month)"
        if let hit: MonthCalendar = DataSources.cacheGet(key, ttl: cacheTTL) { return hit }
        defer { DataSources.throttleAfterNetwork() }
        let url = DataSourceEndpoints.szseCalendarMonth + "?month=" + month
        guard let text = DataSources.httpGet(url) else {
            DataSources.logDataSource("szse", "calendar_fail",
                                      "\(month) 官方日历取不到："
                                        + (DataSources.lastFetchFailureReason(matching: url) ?? "无响应"))
            return nil
        }
        guard let cal = parse(text, month: month) else {
            // 空数组是"这个月还没发布"（实测 2027-01 就是这个形状），不是接口挂了
            DataSources.logDataSource("szse", "calendar_unpublished", "\(month) 无日历条目（超出发布窗口）")
            return nil
        }
        DataSources.cachePut(key, cal)
        return cal
    }

    /// 某一天的官方结论（`true` 交易日 / `false` 休市 / `nil` 不知道）。
    public static func isTradingDay(_ day: String) -> Bool? {
        guard isDayString(day) else { return nil }
        return calendar(forMonth: String(day.prefix(7)))?.verdict(day)
    }

    /// 仅读内存缓存的官方日历结论（**零网络、零阻塞**），供健康分计算等热路径使用。
    /// 未缓存 / fixture / 回放模式下返回 `nil`。
    public static func cachedIsTradingDay(_ date: Date) -> Bool? {
        let day = DataSources.dayFormatter.string(from: date)
        guard isDayString(day) else { return nil }
        let month = String(day.prefix(7))
        guard let hit: MonthCalendar = DataSources.cacheGet("szse_cal|\(month)", ttl: cacheTTL) else {
            return nil
        }
        return hit.verdict(day)
    }

    /// 判定并翻成既有的三态结论；**不知道就返回 nil**，让调用方继续用原有判据。
    public static func verdict(for date: Date) -> DataSources.TradingDayVerdict? {
        guard let day = Optional(DataSources.dayFormatter.string(from: date)),
              let trading = isTradingDay(day) else { return nil }
        return trading ? .trading(reason: "深交所官方日历")
                       : .closed(reason: "深交所官方日历：休市")
    }

    // MARK: - 形状校验

    /// `yyyy-MM`（进 URL query，必须严格 ASCII；理由见 `DataSourceEndpoints` 的代码形状闸门）
    static func isMonthString(_ s: String) -> Bool {
        guard s.count == 7, s[s.index(s.startIndex, offsetBy: 4)] == "-" else { return false }
        let y = s.prefix(4), m = s.suffix(2)
        guard y.allSatisfy({ $0.isASCII && $0.isNumber }),
              m.allSatisfy({ $0.isASCII && $0.isNumber }),
              let mi = Int(m), (1...12).contains(mi) else { return false }
        return true
    }

    /// `yyyy-MM-dd`
    static func isDayString(_ s: String) -> Bool {
        guard s.count == 10, isMonthString(String(s.prefix(7))) else { return false }
        let d = s.suffix(2)
        return d.allSatisfy({ $0.isASCII && $0.isNumber }) && (Int(d) ?? 0) >= 1
    }
}
