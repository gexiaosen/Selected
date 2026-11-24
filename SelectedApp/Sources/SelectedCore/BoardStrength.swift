import Foundation

/// 板块**强度**（0~100，当日**相对**强弱）。
///
/// ## 为什么是"相对分位"而不是绝对分
/// 板块之间的强弱只有在**同一天内比较**才有意义（牛市里 3% 是弱、熊市里 1% 是强）。
/// 所以四个因子全部取**当日全板块内的分位**（0 = 最弱、1 = 最强），再加权成 0~100。
///
/// ## 公式（四个因子，权重和为 1）
/// ```
/// 强度 = 100 × ( 0.40 × 涨幅分位
///              + 0.25 × 上涨家数占比
///              + 0.20 × 主力净流入分位
///              + 0.15 × 涨停家数分位 )
/// ```
/// - **涨幅分位**（0.40）：当日涨幅在全部板块中的分位 —— 主因；
/// - **上涨家数占比**（0.25）：`up/(up+down+flat)`，衡量"是不是整体在涨"而不是被一只票拉起；
/// - **主力净流入分位**（0.20）：资金面（涨幅可能由情绪推动，资金是第二重确认）；
/// - **涨停家数分位**（0.15）：题材发酵的直接证据（"主线"通常有涨停簇）。
///
/// ⚠ 口径声明（写在界面上，别让读者以为这是预测）：
///   · 它是**当日横截面**的相对强弱，**不含任何未来信息**，也不是收益预测；
///   · 四因子等权方案没有标定依据 ⇒ 权重是**可解释的经验值**，要改就改这一处；
///   · 分位用"严格小于它的板块数 / 总数"算 ⇒ 大量并列（如涨停家数多为 0）时
///     并列项同分，不会因为排序抖动而变值。
public enum BoardStrength {

    /// 单板块的强度明细（供界面解释"这个分是怎么来的"）
    public struct Breakdown: Sendable, Equatable {
        public let score: Double          // 0~100
        public let changePctile: Double   // 0~1
        public let upRatio: Double        // 0~1
        public let netPctile: Double      // 0~1
        public let limitUpPctile: Double  // 0~1
        public let limitUpCount: Int      // 当日涨停家数（来自涨停池，按行业名匹配）
    }

    /// 计算全部板块的强度（`limitUpByIndustry`：行业名 → 当日涨停股）
    ///
    /// ⚠ 行业名匹配是**按名称**（`board_heat.board_name` ↔ `limit_up_pool.industry`）：
    ///   两者同源（东财行业）。匹配不上的（改名/退市）只是拿不到涨停加分，不会算错其他三项。
    public static func compute(rows: [BoardHeatPoint],
                               limitUpByIndustry: [String: [LimitUpRecord]]) -> [String: Breakdown] {
        guard !rows.isEmpty else { return [:] }
        let n = Double(rows.count)
        // 分位：严格小于它的个数 / 总数（并列同分；避免"排序不稳定导致分数抖动"）
        //
        // ⚠ 改为**排序一次 + 二分**（2026-10-16 审查 B3）：原先每行做 3 次整表线性计数，
        //   496 个板块 ⇒ 每次调用约 74 万次比较；而 `BoardView` 是在 **body 里**调本函数的
        //   （搜索框每敲一个字符都重渲染），分数却与 `query` 无关。
        //   口径**完全不变**：`countBelow` 数的仍是"严格小于"，并列同分、`n` 为全表条数。
        //   ⚠ 非有限值一律映射成 `+infinity` 参与排序：`inf < v` 恒假 ⇒ 它既不会被计入
        //   "小于"的个数（与原先线性计数一致），又保证数组对 `sorted()` 有全序
        //   （NaN 混进有序数组会让二分前提失效）。
        func rankable(_ v: Double) -> Double { v.isFinite ? v : Double.infinity }
        let changes = rows.map { rankable($0.changePct) }.sorted()
        let nets = rows.map { rankable($0.mainNet) }.sorted()
        let limits = rows.map { rankable(Double(limitUpByIndustry[$0.boardName]?.count ?? 0)) }.sorted()
        func pctile(_ sorted: [Double], _ v: Double) -> Double {
            guard v.isFinite else { return 0 }   // 原口径：`< NaN` 恒假 ⇒ 一个都不算
            var lo = 0, hi = sorted.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if sorted[mid] < v { lo = mid + 1 } else { hi = mid }
            }
            return Double(lo) / n
        }

        var out: [String: Breakdown] = [:]
        for r in rows {
            let breadth = Double(r.upCount + r.downCount + r.flatCount)
            let upRatio = breadth > 0 ? Double(r.upCount) / breadth : 0
            let lu = Double(limitUpByIndustry[r.boardName]?.count ?? 0)
            let pChange = pctile(changes, r.changePct)
            let pNet = pctile(nets, r.mainNet)
            let pLimit = pctile(limits, lu)

            let score = 100 * (0.40 * pChange + 0.25 * upRatio + 0.20 * pNet + 0.15 * pLimit)
            out[r.boardCode] = Breakdown(score: score, changePctile: pChange, upRatio: upRatio,
                                         netPctile: pNet, limitUpPctile: pLimit,
                                         limitUpCount: Int(lu))
        }
        return out
    }
}
