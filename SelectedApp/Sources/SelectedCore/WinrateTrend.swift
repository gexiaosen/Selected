import Foundation

/// 四层胜率走势的**范围与聚合**。
///
/// ## 背景
/// 固定 20 个有样本选股日（约一个月）的窗口判断不了"策略是不是在变差"（样本太短）；
/// 但直接把窗口放开又会让**逐日折线在几百个点上糊成一条带**、表格长到淹没页面。
///
/// ## 口径（三条，都要写在界面上）
/// 1. **范围**：近 20 / 60 / 120 / 全部（默认 20 = 原行为，不变）
/// 2. **聚合**：范围超过 120 天时，折线**按自然周聚合**（每点 = 该周各口径胜率的**简单平均**）
/// 3. ⚠ **为什么是简单平均而不是按样本数加权**：`reviews.four_layer_json` **只存胜率、
///    不存样本数** ⇒ 加权所需的权重拿不到。这不是"选了个差口径"，是**唯一可得的**口径 ——
///    但它意味着"某天只有 3 只票"与"某天有 300 只票"在周均值里**权重相同** ✗。
///    ⇒ 所以界面上必须写明「按周聚合」，不能让周线被读成日线。
public enum WinrateTrend {

    /// 四个口径的键（顺序即图例顺序）
    public static let layerKeys = ["window", "close", "snapshot", "ceiling"]

    /// 超过这个天数就自动按周聚合（120 个交易日 ≈ 半年；逐日折线到 120 点仍可读）
    public static let weeklyThreshold = 120

    /// 按**自然周**（ISO：周一为一周之始）聚合。
    ///
    /// - 每个输出行的 `date` = **该周的第一个有样本选股日**（用它当行 id 与 x 轴标签；
    ///   用它而不是"周一"是因为周一可能没有样本，那样表格里会出现一个"不存在的那天"）
    /// - 每个口径只对**该周有值**的那些日子求平均（缺值的日子不参与、也不折成 0）
    /// - 输出按 `date` **升序**（与输入同序；调用方直接画折线）
    public static func weekly(_ rows: [WinrateTrendRow]) -> [WinrateTrendRow] {
        guard !rows.isEmpty else { return [] }
        var buckets: [String: [WinrateTrendRow]] = [:]     // key = 周起始（yyyy-MM-dd）
        var order: [String] = []                           // 保持周的先后
        for r in rows {
            let key = weekStart(of: r.date) ?? r.date
            if buckets[key] == nil { buckets[key] = []; order.append(key) }
            buckets[key]?.append(r)
        }
        return order.sorted().compactMap { key in
            guard let days = buckets[key], !days.isEmpty else { return nil }
            // ⚠ 必须是 `[String: Any]`，**不能是 `[String: JSONValue]`**：
            //   `JSONValue.init(_ any: Any?)` 把传进来的东西**原样当 raw 存** ——
            //   内层再包一层 `JSONValue` 的话，`json.str("date")` / `json.num("window")`
            //   取到的都是 `JSONValue` 而不是 `String`/`Double` ⇒ **全部静默读成默认值**
            //   （`declaredKeys` 那套测试**抓不到**这种：键都在、只是值的类型不对）。
            var dict: [String: Any] = ["date": dayKey(days)]
            for layer in layerKeys {
                let vals = days.compactMap { $0.winrate(for: layer) }
                dict[layer] = vals.isEmpty ? NSNull() : (vals.reduce(0, +) / Double(vals.count))
            }
            return WinrateTrendRow(JSONValue(dict))
        }
    }

    /// 一周的展示日期：该周**第一个有样本的选股日**（升序里最小的那个）
    private static func dayKey(_ days: [WinrateTrendRow]) -> String {
        days.map(\.date).min() ?? (days.first?.date ?? "")
    }

    /// `yyyy-MM-dd` → 它所在自然周的起始日（ISO：周一）。解析失败 → `nil`（调用方按原日期兜底）
    static func weekStart(of date: String) -> String? {
        guard let d = ChinaTime.parseDay(date) else { return nil }
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = ChinaTime.zone
        guard let interval = cal.dateInterval(of: .weekOfYear, for: d) else { return nil }
        let f = ChinaTime.formatter("yyyy-MM-dd")
        return f.string(from: interval.start)
    }
}
