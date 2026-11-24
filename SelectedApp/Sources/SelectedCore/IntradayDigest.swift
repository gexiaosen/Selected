import Foundation

/// 详情页「尾盘结构」卡的派生输入（纯函数，可单测）。
///
/// 与 `IntradayFeaturesCalc.compute` 的分工：`compute` 只认**一个** `today` 与一份行情；
/// 这里负责**挑哪一天**、以及**给那一天配一份口径一致的行情**。
///
/// ⚠ 为什么必须有这一层（否则会静默算错）：
/// `compute` 里
///
///     close_position = (quote.price − 当日最低) ÷ (当日最高 − 当日最低)
///
/// 若把**今天的实时价**配**上一个交易日的分时高低点**，得到的是一个毫无意义的分位 ——
/// 而且**不报错、不越界**，界面上看着就像一个正常数字。
/// 所以：非当日一律用**那一天的 bar** 重建行情。
public enum IntradayDigest {

    /// 挑出来的那一天的输入
    public struct Picked {
        /// 交易日 `yyyy-MM-dd`
        public let day: String
        /// 仅该日的 bar（顺序保持原样；升序由 `compute` 负责）
        public let bars: [MinuteBar]
        /// 与该日**口径一致**的行情
        public let quote: EngineQuote
        /// 行情是否取自"实时"（当日）；`false` = 由当日 bar 重建
        public let usedLiveQuote: Bool

        public init(day: String, bars: [MinuteBar], quote: EngineQuote, usedLiveQuote: Bool) {
            self.day = day
            self.bars = bars
            self.quote = quote
            self.usedLiveQuote = usedLiveQuote
        }
    }

    /// 从（可能跨多日的）5 分钟线里挑**最近一个"够算"的交易日**，并给出该日的口径一致输入。
    ///
    /// 两条挑选规则：
    ///   1. **优先挑 bar 数 ≥ `minBars` 的最近一天** —— 盘中（尤其上午）当天的 bar 只有几根，
    ///      远不够算；而同一份响应里**上一个交易日的完整尾盘结构**是现成的、也更有参考价值。
    ///      不这么做的话，整个上午卡片都只会显示"数据不足"，明明有数据却看不到。
    ///   2. 若没有任何一天够算，退回到**最近的一天** —— 让调用方拿到真实的 bar 数去显示
    ///      "不足 N 根"，而不是含糊的"没有数据"。
    ///
    /// 为什么不是"固定用今天"：周末 / 开盘前 / 节假日时 `today` 根本没有 bar，卡片会整个空掉。
    ///
    /// - Parameters:
    ///   - today: 当前交易日（`ChinaTime.day()`），**仅用于判断"能不能用实时行情"**
    ///   - liveQuote: 实时行情；只在 `day == today` 时采用（与引擎扫描同口径），否则忽略
    ///   - minBars: 与 `IntradayFeaturesCalc.compute` 的 `minBars` **传同一个值**，
    ///     否则会出现"这里挑了够算的一天、那边却算不出来"的错位
    public static func pickLatest(_ bars: [MinuteBar], today: String,
                                  liveQuote: EngineQuote?,
                                  minBars: Int = 20) -> Picked? {
        // 只认有日期又有时间的 bar（与 `compute` 的筛选口径一致）
        let usable = bars.filter { !$0.day.isEmpty && !$0.time.isEmpty }
        guard !usable.isEmpty else { return nil }
        let byDay = Dictionary(grouping: usable, by: \.day)
        let threshold = minBars == 0 ? 20 : minBars      // 与 compute 的 `0 → 20` 兜底对齐
        let day = byDay.filter { $0.value.count >= threshold }.keys.max() ?? byDay.keys.max()
        guard let day, let dayBars = byDay[day], !dayBars.isEmpty else { return nil }

        // 当日且拿得到实时行情 → 用它（引擎扫描走的就是这条路）
        if day == today, let live = liveQuote, live.price != 0 || live.volume != 0 {
            return Picked(day: day, bars: dayBars, quote: live, usedLiveQuote: true)
        }

        // 否则用该日自己的 bar 重建，避免"今日实时价 × 那日高低点"的混口径。
        var q = EngineQuote()
        q.price = dayBars[dayBars.count - 1].close
        // ⚠ `compute` 内部对 `quote.volume` 做 `* 100`（手 → 股）后再与 bar 量之和取大值：
        //     dayVol = max(barsVol, quote.volume * 100)
        // 这里先 ÷100 抵消 → `max` 退化成 barsVol，也就是"以 bar 为准"。
        q.volume = PyMath.sum(dayBars.map(\.volume)) / 100
        return Picked(day: day, bars: dayBars, quote: q, usedLiveQuote: false)
    }
}
