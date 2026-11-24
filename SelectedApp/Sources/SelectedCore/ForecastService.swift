import Foundation

/// 次日区间的**取数入口**
///
/// **为什么单独一个文件**：`ForecastEngine` 是纯计算，一旦掺进取数与 `JSONValue`，
/// 构建就得跟着拖 DataSources/KLineService —— 计算与取数分开，构建边界才清楚。
// MARK: - 取数入口（App 内两个入口共用）

extension ForecastEngine {
    /// 取前复权日K → `forecast`（末 80 根，默认 days=30 / recent=3）。
    ///
    /// **为什么放在这里**：次日区间同时出现在「次日区间」弹窗与「个股详情」页，
    /// 各写一份必然漂移，故只留这一份共用入口。
    ///
    /// 取数失败返回 nil（数据源异常 / 代码无效，调用方展示错误）；
    /// K线不足由 `forecast` 自己返回 `status=insufficient_data`。
    ///
    /// 返回 `ForecastResult`（实体，`Sendable`）而不是裸字典：本函数是 nonisolated async，
    /// 结果要跨隔离域送回主线程 —— 裸 `[String: Any]` 会被 Swift 6 判为数据竞争；
    /// 实体同时让调用方拿到类型化访问（键名拼错 = 编译错误）。
    public static func fetchAndForecast(code: String, name: String = "", baseDays: Int = 30,
                                 recentDays: Int = 3) async -> ForecastResult? {
        let full = StockQuotes.fullCode(code)
        guard let result = await KLineService.fetchKLine(fullCode: full, period: .daily, count: 80),
              !result.items.isEmpty else { return nil }
        // 口径：只取末 80 根
        let bars = result.items.suffix(80).map {
            KLineBar(day: $0.date, open: $0.open, high: $0.high,
                     low: $0.low, close: $0.close, volume: $0.volume)
        }
        return ForecastResult(JSONValue(forecast(code: code, name: name, bars: Array(bars),
                                                 baseDays: baseDays, recentDays: recentDays)))
    }
}
