import Foundation

/// 龙虎榜详情卡的**派生**数据（纯函数，可单测）。
///
/// ⚠ 为什么需要它：同一只票**同一天可以有多条上榜口径**（实测一只票同时因
/// 「日涨幅偏离值达 7%」「日换手率达 20%」「三日累计涨幅偏离达 20%」三条上榜），
/// 而各口径的**金额不同** —— 其中两条的金额**完全相同**（同一批成交按两个口径各披露一次）。
///
/// 所以详情卡**不能**"一条口径一行"：用户会看到两行一模一样的数字，像是重复抓取了。
/// 做法：**原因全部列出**（那是"为什么上榜"，信息量高、去重后不重复），
/// 金额与席位只取一条（`primary`），并在界面上标出依据的是哪条。
public enum LhbDigest {

    /// 详情卡要展示的内容
    public struct Card: Equatable, Sendable {
        /// 上榜日期（最近一天）
        public let date: String
        /// 该日全部上榜原因（**已去重**，保持原顺序）
        public let reasons: [String]
        /// 金额与席位所依据的那条记录
        public let primary: LhbRecord
        /// 该日上榜口径条数（可能大于 `reasons.count` —— 不同口径的文案可能重复）
        public let caliberCount: Int

        public init(date: String, reasons: [String], primary: LhbRecord, caliberCount: Int) {
            self.date = date
            self.reasons = reasons
            self.primary = primary
            self.caliberCount = caliberCount
        }
    }

    /// 从某只票的**全部**上榜记录里挑出详情卡要展示的那一天与那一条。
    ///
    /// - 日期取**最近**的一天（调用方传 `LhbStore.records(code:)`，已按 `trade_date DESC` 排序）
    /// - `primary` 取该日**净额绝对值最大**的一条：净额是这张卡的主角，
    ///   取最大者 = 展示当天最显著的那个口径
    ///   ⚠ 用 `abs` 比较而不是直接比大小 —— 净额可能全为负（当日净卖出），
    ///     直接 `max` 会挑到"亏得最少"的那条，与"最显著"正好相反
    /// - `reasons` 去重但保持顺序（顺序 = `change_type` 升序，来自 `LhbStore.records`）
    public static func card(from records: [LhbRecord]) -> Card? {
        guard let newest = records.first, !newest.date.isEmpty else { return nil }
        let sameDay = records.filter { $0.date == newest.date }
        guard !sameDay.isEmpty else { return nil }

        let primary = sameDay.max { abs($0.netAmount) < abs($1.netAmount) } ?? newest

        var reasons: [String] = []
        for r in sameDay where !r.explanation.isEmpty && !reasons.contains(r.explanation) {
            reasons.append(r.explanation)
        }
        return Card(date: newest.date, reasons: reasons, primary: primary,
                    caliberCount: sameDay.count)
    }
}
