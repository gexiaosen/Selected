import Foundation

/// 历史回放 —— **纯计算层**
///
/// 本文件只放**纯函数**：把「历史日K」变成「引擎口径的行情」。
/// 抓取、落库、编排在 `HistoryBarsSource` / `HistoryBarStore` / 编排器里。
///
/// ## ⚠ 这是「收盘价口径」，不是尾盘口径
/// live 的选股价是 **14:00 / 14:30 / 14:50 的盘中价**，而分时数据**不可回溯**
/// （新浪 5 分钟线只覆盖最近约 5 个交易日）。所以历史回放只能用**收盘价**，
/// 连量比也只能是**全日**量比（live 是盘中时点量比）。
///
/// → 回放样本与 live 样本**口径不同**，`reviews.scan_mode` 是唯一区分依据，
///   调优器默认**不混用**。完整论证见 `docs/specs/README.md`。
///
/// ## 为什么 `change_pct` / `amplitude` **自算而不抄东财**
/// 重建出的快照必须**内部自洽**：下游会拿 `price` 与 `pre_close` 再算一次涨跌幅
/// （`Screener` 的档位与信号、`PhaseReview` 的 `uniformOutcome` 都这么干）。
/// 若这两项直接抄东财、而 `pre_close` 是自己从相邻 bar 取的，两个来源会在**除权日**
/// 悄悄分叉（东财的涨跌幅是按前收盘口径给的），而两边的数字看起来都正常。
/// → 东财原值只作**自检的交叉验证**。
public enum HistoryReplay {

    /// 重建一根 bar 所需的前置 bar 数：1 根前收 + 5 根算量比。
    ///
    /// 取窗口时必须往前多留这么多**交易日**，否则量比会退化成用不足 5 日算 ——
    /// 那不会报错，只会让数字偏低，属于"看起来正常但错"的一类。
    public static let warmupBars = 6

    /// 回放日的报价时间戳：`yyyyMMdd` + `150000`（15:00:00）。
    ///
    /// 为什么必须显式写：`ScanRunner` 有「报价日期闸门」（报价日期 != 本轮日期就整轮不落库），
    /// 而 `quote_time` 是那道闸门唯一的判据。回放日的快照必须自带**回放日**的时间戳。
    public static func quoteTime(_ day: String) -> String {
        day.replacingOccurrences(of: "-", with: "") + "150000"
    }

    /// 取窗口时往前多留的**自然日**数 —— 用来覆盖 `warmupBars` 个交易日。
    ///
    /// 为什么用自然日而不是交易日：取窗口发生在**建日历之前**（日历本身要靠指数缓存），
    /// 所以只能用自然日。6 个交易日最多跨一个长假（春节/国庆 ≈ 9 天），20 天留足余量。
    /// 多取几根 bar 不影响结果（`quote` 只按 `day` 定位），少取才会让量比静默退化。
    public static let warmupCalendarDays = 20

    /// `day` 往前 `n` 个**自然日**（`n` 可为负 → 往后）。非法输入原样返回，不猜。
    ///
    /// 锚在**正午**：任何时区/DST 边界都不会把日期挤到前后一天。
    /// （中国无夏令时，但锚正午是零成本的保险，且让这个函数在任何时区下都稳定。）
    public static func shiftCalendarDays(_ day: String, _ n: Int) -> String {
        guard !day.isEmpty else { return day }
        let parts = day.split(separator: "-")
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return day }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? TimeZone(identifier: "UTC")!
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d; comps.hour = 12
        guard let base = cal.date(from: comps) else { return day }
        // ⚠ `Calendar` 对越界分量是**宽容**的：`2026-13-45` 不会失败，而是被规范化成
        //     2027-02-14（13 月 → 次年 1 月，45 日 → 再往后推）。若不拦，用户在区间选择器里
        //     输错一个数字就会得到一段**看起来正常**的日期区间，然后回放一堆他并不想要的日子。
        // → 判据是"回读分量是否与输入逐项一致"，顺带覆盖 `2026-02-30` 这类不存在的日期。
        let back = cal.dateComponents([.year, .month, .day], from: base)
        guard back.year == y, back.month == m, back.day == d else { return day }
        guard let shifted = cal.date(byAdding: .day, value: n, to: base) else { return day }
        // 委托 ChinaTime.formatter（cal.timeZone 即 Asia/Shanghai）
        let f = ChinaTime.formatter("yyyy-MM-dd")
        return f.string(from: shifted)
    }

    /// 把一只票在 `day` 的行情**重建**成引擎口径（键名与 `EngineQuote(json:)` 完全一致）。
    ///
    /// - Parameter bars: **同一只票**、按 `day` **升序**的 bar 序列，必须包含 `day`
    ///   以及它前面的若干根（前收 + 算量比）。
    /// - Returns: `nil` = 数据不足 → **该票当轮整体剔除**（不是"填 0 继续"）。
    ///   缺 `day` 那根、或 `day` 是序列首根（拿不到前收）、或前收非正 → 都返回 `nil`。
    public static func quote(code: String, name: String, day: String,
                             bars: [HistoryBar]) -> [String: Any]? {
        guard !code.isEmpty, !day.isEmpty else { return nil }
        guard let idx = bars.firstIndex(where: { $0.day == day }), idx > 0 else { return nil }
        let b = bars[idx]
        let preClose = bars[idx - 1].close
        // 前收非正 → 算不出涨跌幅。不复权序列理论上不会出现，但真出现时
        // "当作 0" 会让 change_pct 变成一个巨大的假值，必须剔除。
        guard preClose > 0 else { return nil }

        // 量比 = 当日全日量 ÷ 过去 5 个交易日全日均量。
        // ⚠ 口径差异：live 的 volume_ratio 是**盘中时点**量比（腾讯字段 49），
        //   这里只能是**全日**量比 —— 见文件头。
        // 用 PyMath.sum（Neumaier 补偿求和），与引擎求和口径一致。
        let priorVolumes = Array(bars[max(0, idx - 5)..<idx].map(\.volume))
        let avgVolume = priorVolumes.isEmpty ? 0 : PyMath.sum(priorVolumes) / Double(priorVolumes.count)
        let volumeRatio = avgVolume > 0 ? PyMath.round(b.volume / avgVolume, 2) : 0

        // 均价 = 成交额(元) ÷ 成交量(手) ÷ 100 = 元/股。
        // ⚠ 东财不直接给均价，这是**推导值**；与腾讯的 avg_price 相差约 0.02%
        //   （腾讯的分母口径略有不同）。`avg_price` 不参与任何阈值比较，只落库展示。
        let avgPrice = b.volume > 0 ? PyMath.round(b.amount / (b.volume * 100), 2) : 0

        return [
            "code": code,
            "name": name,
            "price": b.close,
            "pre_close": preClose,
            "open": b.open,
            "high": b.high,
            "low": b.low,
            "volume": b.volume,
            "change_pct": PyMath.round((b.close - preClose) / preClose * 100, 2),
            "amplitude": PyMath.round((b.high - b.low) / preClose * 100, 2),
            // ⚠ 单位换算：东财是**元**，引擎口径是**万元**（腾讯字段 37）。
            //     漏了这一步不会报错，只会让落库的成交额差 10000 倍。
            "amount": PyMath.round(b.amount / 10000, 2),
            "turnover": b.turnover,
            "volume_ratio": volumeRatio,
            "avg_price": avgPrice,
            "quote_time": quoteTime(day),
        ]
    }

    /// 重建 `day` 的**全市场**行情。
    ///
    /// - Parameter byCode: `HistoryBarStore.barsByCode(from:to:)` 的结果
    ///   （窗口必须含 `day` 及其前 `warmupBars` 个交易日）
    /// - Parameter names: 代码 → 名称（来自证券主列表；回放用**当前**清单）
    /// - Returns: `code → 行情字典`，只含重建成功的票
    public static func quotes(day: String, byCode: [String: [HistoryBar]],
                              names: [String: String]) -> [String: [String: Any]] {
        var out: [String: [String: Any]] = [:]
        out.reserveCapacity(byCode.count)
        for (code, bars) in byCode {
            guard let q = quote(code: code, name: names[code] ?? "", day: day, bars: bars) else {
                continue
            }
            out[code] = q
        }
        return out
    }
}
