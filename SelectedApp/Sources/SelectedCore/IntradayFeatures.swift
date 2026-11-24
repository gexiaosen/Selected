import Foundation

/// 5 分钟 bar（引擎侧输入）
///
/// `Sendable`：全是 `String`/`Double` 的值类型。**加它是必需的** ——
/// 详情页要在 `Task.detached` 里取 5 分钟线（网络调用不能占主线程），
/// 取回后跨回主 actor 时，非 `Sendable` 会在**编译期**直接报错
/// （`non-Sendable type '[MinuteBar]' cannot be sent to main actor-isolated context`）。
public struct MinuteBar: Sendable {
    public var day: String = ""
    public var time: String = ""       // "HH:MM"
    public var open: Double = 0
    public var high: Double = 0
    public var low: Double = 0
    public var close: Double = 0
    public var volume: Double = 0

    public init() {}
    public init(json: [String: Any]) {
        func num(_ k: String) -> Double {
            if let d = json[k] as? Double { return d }
            if let i = json[k] as? Int { return Double(i) }
            if let s = json[k] as? String { return Double(s) ?? 0 }
            return 0
        }
        day = (json["day"] as? String) ?? ""
        time = (json["time"] as? String) ?? ""
        open = num("open"); high = num("high"); low = num("low")
        close = num("close"); volume = num("volume")
    }
}

/// 尾盘分时结构特征
public struct IntradayFeatures {
    public var barsToday = 0
    public var lastBarTime = ""
    public var elapsedMinutes = 0
    public var tailWindowMin = 30
    public var tailStart = ""
    public var tailVolRatio: Double?
    public var tailVolShare: Double?
    public var tailGainPct: Double?
    public var tailNewHigh = false
    public var closePosition: Double?
    public var highBucket = ""
    public var dayHighTime = ""
    public var highAgeRatio: Double?

    public var json: [String: Any] {
        var d: [String: Any] = [
            "bars_today": barsToday, "last_bar_time": lastBarTime,
            "elapsed_minutes": elapsedMinutes, "tail_window_min": tailWindowMin,
            "tail_start": tailStart, "tail_new_high": tailNewHigh,
            "high_bucket": highBucket, "day_high_time": dayHighTime,
        ]
        d["tail_vol_ratio"] = tailVolRatio as Any
        d["tail_vol_share"] = tailVolShare as Any
        d["tail_gain_pct"] = tailGainPct as Any
        d["close_position"] = closePosition as Any
        d["high_age_ratio"] = highAgeRatio as Any
        return d
    }
}

/// Selected 引擎 — 尾盘分时结构特征（纯函数）
///
/// **口径设计（重要）**：扫描发生在 14:00 / 14:30 / 14:50，若把「尾盘」固定为
/// 14:30-15:00，那么 14:00 那轮窗口是空的、14:50 那轮只走了 2/3 —— 三轮不可比。
/// 因此用**相对全日强度的倍数**：
///
///     tail_vol_ratio = (尾盘成交量 / 尾盘分钟数) ÷ (当日成交量 / 当日已交易分钟数)
///
/// 基值 1.0 = 尾盘量能与全日平均一致；越大说明尾盘越在放量。它与轮次无关。
public enum IntradayFeaturesCalc {

    /// HH:MM → 当日分钟数（用于窗口筛选）；解析失败返回 -1
    public static func hhmmToMin(_ t: String) -> Int {
        let parts = t.split(separator: ":")
        guard parts.count >= 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return -1 }
        return h * 60 + m
    }

    /// 从 5 分钟线算尾盘分时结构。数据不足返回 nil（不猜）。
    ///
    /// ⚠ `minBars == 0` 必须兜底成 20（与配置默认值对齐）：否则空 `tb` 也通过闸门，
    /// 下面 `tb[tb.count - 1]` **直接数组越界崩溃**。
    /// 另加 `tb.isEmpty` 显式短路 —— 即使将来 minBars 被改成负数也不会越界。
    public static func compute(_ bars: [MinuteBar], today: String, quote: EngineQuote,
                        minBars: Int = 20, tailWindowMin: Int = 30) -> IntradayFeatures? {
        let minBars = minBars == 0 ? 20 : minBars
        var tb = bars.filter { $0.day == today && !$0.time.isEmpty }
        if tb.isEmpty || tb.count < minBars { return nil }
        tb.sort { $0.time < $1.time }

        let lastMin = hhmmToMin(tb[tb.count - 1].time)
        let elapsed = EngineIndicators.elapsedMinutesAt(tb[tb.count - 1].time)
        if elapsed <= 0 { return nil }

        guard let dayLow = tb.map(\.low).min(), let dayHigh = tb.map(\.high).max() else { return nil }
        if dayHigh <= dayLow { return nil }

        // 当日量：5分钟线求和可能残缺（停牌/丢根），用实时累计量取大值兜底（手 → 股）
        let barsVol = PyMath.sum(tb.map(\.volume))
        let dayVol = max(barsVol, quote.volume * 100)
        if dayVol <= 0 { return nil }

        // ---- 尾盘窗口：以「已交易时段的最后 N 分钟」为准，与第几轮无关 ----
        // ⚠ 两处修正（2026-10-16 审查 B5-14）：
        //   ① 原先写作 `max(120, lastMin - tailWindowMin)`，注释说"不跨午休"，
        //      但 `120` 是**分钟数 = 02:00**，那条下界在真实时段里永远不生效（no-op）。
        //      午休边界只有一份（`AlertWindow.sessionRanges`：570-690 / 780-900）；
        //      尾盘落点 14:00/14:30/14:50 都在下午段 ⇒ 下界应是 780（13:00），
        //      手扫在上午时下界是 570（09:30）。
        //   ② 原先 `tailSpan = lastMin - startMin` 是**墙钟分钟**，而 `dayIntensity`
        //      的分母是**交易分钟**（`elapsed`）—— 不同量纲相除。窗口只要跨过午休，
        //      `tail_vol_ratio` 就被系统性压低：13:30 手扫、窗口 60 分钟 → 实际只有
        //      13:00→13:30 这 30 根交易分钟，比值直接减半；14:00 轮末根 13:55 时同理偏低。
        //      改成两端都过 `elapsedMinutesAt`，分子分母同一把尺子。
        let pmOpen = 13 * 60, amOpen = 9 * 60 + 30
        let startFloor = lastMin >= pmOpen ? pmOpen : amOpen
        let startMin = max(startFloor, lastMin - tailWindowMin)
        let tail = tb.filter { hhmmToMin($0.time) >= startMin }
        if tail.count < 2 { return nil }

        let startElapsed = EngineIndicators.elapsedMinutesAt(
            String(format: "%02d:%02d", startMin / 60, startMin % 60))
        let tailSpan = max(1, elapsed - startElapsed)

        let tailVol = PyMath.sum(tail.map(\.volume))
        let tailIntensity = tailVol / Double(tailSpan)
        let dayIntensity = dayVol / Double(elapsed)
        let tailVolRatio = dayIntensity > 0 ? PyMath.round(tailIntensity / dayIntensity, 2) : nil
        let tailVolShare = dayVol > 0 ? PyMath.round(tailVol / dayVol, 4) : nil

        // ---- 尾盘价格行为 ----
        let firstClose = tail[0].close
        let lastClose = tail[tail.count - 1].close
        let tailGainPct = firstClose > 0 ? PyMath.round((lastClose - firstClose) / firstClose * 100, 2) : nil
        guard let tailHigh = tail.map(\.high).max() else { return nil }
        let tailNewHigh = tailHigh >= dayHigh - 1e-6

        // ---- 收盘强度分位（优先用实时价，缺失时用末根收盘）----
        let closePx = quote.price != 0 ? quote.price : (lastClose != 0 ? lastClose : 0)
        let closePosition = (dayHigh > dayLow && closePx > 0)
            ? PyMath.round((closePx - dayLow) / (dayHigh - dayLow), 3) : nil

        // ---- 日内最高价出现的时段（并列取**第一根**）----
        var hiBar = tb[0]
        for b in tb where b.high > hiBar.high { hiBar = b }
        let hiMin = hhmmToMin(hiBar.time)
        let highBucket: String
        if hiMin < 11 * 60 + 30 { highBucket = "morning" }
        else if hiMin < 14 * 60 { highBucket = "midday" }
        else { highBucket = "tail" }

        // ---- 高点陈旧度：距最高价出现已过去的时长 / 已交易时长 ----
        // 不用 high_bucket 判定：早盘天然占已交易时长的 ~58%（14:25 时），
        // 于是「高点在早盘」会命中 60% 的标的 —— 那是时间权重，不是信号。
        let hiElapsed = EngineIndicators.elapsedMinutesAt(hiBar.time)
        let highAgeRatio = elapsed > 0
            ? PyMath.round(max(0, min(1, Double(elapsed - hiElapsed) / Double(elapsed))), 3) : nil

        return IntradayFeatures(
            barsToday: tb.count, lastBarTime: tb[tb.count - 1].time,
            elapsedMinutes: elapsed, tailWindowMin: tailWindowMin,
            tailStart: tail[0].time, tailVolRatio: tailVolRatio,
            tailVolShare: tailVolShare, tailGainPct: tailGainPct,
            tailNewHigh: tailNewHigh, closePosition: closePosition,
            highBucket: highBucket, dayHighTime: hiBar.time, highAgeRatio: highAgeRatio)
    }

    // MARK: - 早盘窗口

    /// 早盘窗口结构 —— **只展示**，不进评分。
    ///
    /// ## ⚠ 为什么口径与 `IntradayFeatures` **不同**
    /// `compute` 的窗口是「**最后 N 分钟**」，基准是「**当日已交易平均**」——
    /// 那套口径在**尾盘**成立（窗口只占全天一小段），但在**早盘**不成立：
    /// 10:00 时窗口 == 全天已交易时段 → 比值**恒等于 1**，指标没有意义。
    ///
    /// 所以这里用**跨日同窗口对比**：`今日早盘量 ÷ 前 N 个交易日同时段均量`。
    /// 它天然不受「A股成交量呈 **U 形**分布」（早盘、尾盘量大，午间小）影响 ——
    /// 同窗口比同窗口。
    ///
    /// ⚠ 也**不能**用"按早盘速率外推到全天、再比历史全日均量"：U 形分布会让外推
    /// **系统性高估**（早盘本来就是全天最活跃的时段）。
    ///
    /// ⚠ **零额外请求**：新浪 5 分钟线一次给约 4~5 天（`datalen=240`），
    /// 前序交易日的早盘量就在同一份 `bars` 里。
    /// ⚠ 历史回放模式下 `fetch5minBars` 恒空 → 本项在回放日不可用（与尾盘结构同一限制）。
    public struct MorningWindow: Equatable, Sendable {
        public let from: String
        public let to: String
        /// 窗口内的 bar 数
        public let bars: Int
        /// 今日早盘量 ÷ 前 N 个交易日**同时段**均量。⚠ 没有前序日 → `nil`（不猜）
        public let volRatioVsPriorDays: Double?
        /// 今日早盘量 ÷ 今日量。
        /// ⚠ **收盘后看才有意义** —— 盘中看时"今日量"其实是"至今量"，分母会偏小
        public let volShareOfDay: Double?
        /// 窗口内涨幅（末收 ÷ 首收 − 1，%）
        public let gainPct: Double?
        /// 窗口内最高是否 ≥ **当日**最高
        public let newHigh: Bool
        /// 参与对比的历史交易日数（0 = 没有前序日）
        public let priorDays: Int
        /// 窗口内最后一根的时间（口径可见性：卡上要显示"截止到几点"）
        public let lastTime: String
    }

    /// 算早盘窗口结构。数据不足返回 `nil`（不猜）。
    ///
    /// - Parameters:
    ///   - from / to: 窗口边界（`HH:MM`，**两端都含**，与 `compute` 的 `>= startMin` 同风格）。
    ///     默认 `09:30 ~ 10:00` —— 与「盘中验证」的 10:00 时点对齐。
    ///   - maxPriorDays: 最多拿几个前序交易日做对比（5 分钟线一次约给 4~5 天）
    public static func morningWindow(_ bars: [MinuteBar], today: String,
                                     from: String = "09:30", to: String = "10:00",
                                     maxPriorDays: Int = 4) -> MorningWindow? {
        let lo = hhmmToMin(from)
        let hi = hhmmToMin(to)
        guard lo >= 0, hi > lo, !today.isEmpty else { return nil }

        // 按交易日归组（只收有 day 与 time 的 bar）
        var byDay: [String: [MinuteBar]] = [:]
        for b in bars where !b.day.isEmpty && !b.time.isEmpty {
            byDay[b.day, default: []].append(b)
        }
        guard let rawToday = byDay[today] else { return nil }
        let todayBars = rawToday.sorted { $0.time < $1.time }

        func inWindow(_ day: [MinuteBar]) -> [MinuteBar] {
            day.filter { let m = hhmmToMin($0.time); return m >= lo && m <= hi }
                .sorted { $0.time < $1.time }
        }

        let win = inWindow(todayBars)
        // 至少要两根：只有一根时"窗口内涨幅"无从谈起
        guard win.count >= 2, let first = win.first, let last = win.last else { return nil }

        // 今日全天量（含窗口外）—— 用于"早盘量占当日比"
        let todayVol = PyMath.sum(todayBars.map(\.volume))
        let winVol = PyMath.sum(win.map(\.volume))

        // ---- 跨日同窗口对比 ----
        // ⚠ 只取**日期更早**的交易日（`byDay` 里可能还有比 today 更晚的，理论上不该有，
        //   但真出现时把它算进"历史"会让结论反向）
        let priorDays = byDay.keys.filter { $0 < today }.sorted(by: >).prefix(maxPriorDays)
        let priorWindowVols = priorDays.compactMap { d -> Double? in
            guard let db = byDay[d] else { return nil }
            let w = inWindow(db)
            guard w.count >= 2 else { return nil }       // 该日窗口残缺 → 不参与对比
            return PyMath.sum(w.map(\.volume))
        }
        let priorAvg = priorWindowVols.isEmpty ? 0 : PyMath.sum(priorWindowVols) / Double(priorWindowVols.count)

        let dayHigh = todayBars.map(\.high).max() ?? 0
        let winHigh = win.map(\.high).max() ?? 0

        return MorningWindow(
            from: from, to: to, bars: win.count,
            volRatioVsPriorDays: priorAvg > 0 ? PyMath.round(winVol / priorAvg, 2) : nil,
            volShareOfDay: todayVol > 0 ? PyMath.round(winVol / todayVol, 4) : nil,
            gainPct: first.close > 0
                ? PyMath.round((last.close - first.close) / first.close * 100, 2) : nil,
            newHigh: dayHigh > 0 && winHigh >= dayHigh - 1e-6,
            priorDays: priorWindowVols.count,
            lastTime: last.time)
    }
}
