import Foundation

/// 阶段三 · 收盘复盘。
///
/// 四层胜率（快照/收盘/窗口/上限）＋ L3 纪律口径 ＋ L1 跳空口径 ＋ 逐时点盈亏 ＋
/// 预判准确度评分（0-100）。暴跌日（红灯）标的 `skipped` 不参与胜率统计，
/// 输出参考数据验证空仓决策。
///
/// ⚠ **同步阻塞**（行情/日K/分时 + 落库），调用方必须放后台线程。
public enum PhaseReview {

    /// 逐时点盈亏的取样时刻
    public static let timePoints = ["09:35", "10:00", "10:30", "11:00", "11:30",
                             "13:30", "14:00", "14:30", "15:00"]

    /// 准确度评分权重（除大盘方向 20 分外合计 80）。
    ///
    /// ⚠ 用结构体而非 `[String: Int]`：按字符串键强查，拼错一个字母崩的是复盘评分路径
    /// （且只在定时复盘时暴露）；字段化后访问即编译期检查，增减权重只有这一处要改。
    public struct AccuracyWeights: Sendable {
        public var stockOpenDirection = 15
        public var sellWindowHit = 30
        public var targetPriceDiff = 15
        public var stopLossJudgment = 10
        public var riskLevel = 10
    }

    /// 生效权重（现在恒为默认值；留成实例是为了将来能从参数表覆盖，而不必改调用点）
    public static let accuracyWeights = AccuracyWeights()

    // MARK: - 时间工具（"HH:MM" → 分钟数）

    /// "HH:MM" → 分钟数；格式非法返回 nil
    public static func minutes(_ s: String?) -> Int? {
        guard let s = s, s.count >= 5 else { return nil }
        let parts = s.split(separator: ":")
        guard parts.count >= 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        return h * 60 + m
    }

    // MARK: - 单标的准确度评分

    public static func calcAccuracy(pred: [String: Any], actual: [String: Any]) -> Int {
        var score = 0
        // 个股开盘方向（15）
        let predOpen = PredictRules.num(pred["open_pct"]) ?? 0
        let actOpen = PredictRules.num(actual["open_pct"]) ?? 0
        if (predOpen > 0) == (actOpen > 0) { score += accuracyWeights.stockOpenDirection }

        // 卖出窗口命中（30）
        let ht = (actual["high_time"] as? String) ?? ""
        let ws = (pred["sell_window_start"] as? String) ?? ""
        let we = (pred["sell_window_end"] as? String) ?? ""
        if !ht.isEmpty, !ws.isEmpty, !we.isEmpty, !ws.contains("--"), !we.contains("--") {
            if let htM = minutes(ht), let wsM = minutes(ws), let weM = minutes(we) {
                if wsM <= htM && htM <= weM {
                    score += accuracyWeights.sellWindowHit
                } else if abs(htM - wsM) <= 30 || abs(htM - weM) <= 30 {
                    score += accuracyWeights.sellWindowHit / 2
                }
            }
        }

        // 目标价偏差（15）
        let target = PredictRules.num(pred["target_price"]) ?? 0
        let actHigh = PredictRules.num(actual["intraday_high"]) ?? 0
        let sel = PredictRules.num(pred["sel_price"]) ?? 0
        if target > 0 && actHigh > 0 && sel > 0 {
            let diff = abs((target - sel) / sel * 100 - (actHigh - sel) / sel * 100)
            if diff < 0.5 { score += accuracyWeights.targetPriceDiff }
            else if diff < 1 { score += accuracyWeights.targetPriceDiff / 3 * 2 }
            else if diff < 2 { score += accuracyWeights.targetPriceDiff / 3 }
        }

        // 止损判断（10）
        let stop = PredictRules.num(pred["stop_loss_price"]) ?? 0
        let actLow = PredictRules.num(actual["intraday_low"]) ?? 0
        if stop > 0 && actLow > 0 {
            if actLow > stop { score += accuracyWeights.stopLossJudgment }
            else if (PredictRules.num(actual["close_pct"]) ?? 0) < 0 {
                score += accuracyWeights.stopLossJudgment / 2
            }
        }

        // 风险等级（10）
        // 缺失 / 空串 / 未识别 → nil → 三条分支都不命中、不加分
        let risk = RiskLevel(json: pred["risk_level"])
        let closePct = PredictRules.num(actual["close_pct"]) ?? 0
        if (risk == .high || risk == .extreme) && closePct < 0 { score += accuracyWeights.riskLevel }
        else if risk == .low && closePct > 0 { score += accuracyWeights.riskLevel }
        else if risk == .medium { score += accuracyWeights.riskLevel / 2 }
        return score
    }

    // MARK: - 窗口工具

    /// 卖出窗口内最高价（含边界）
    public static func windowHigh(_ bars: [MinuteBar], start: String, end: String) -> Double {
        guard let s = minutes(start), let e = minutes(end) else { return 0 }
        let highs = bars.filter {
            guard let m = minutes($0.time) else { return false }
            return s <= m && m <= e
        }.map(\.high)
        return highs.max() ?? 0
    }

    /// 卖出窗口内的 5 分钟线（含边界，按时间升序）
    public static func windowBars(_ bars: [MinuteBar], start: String, end: String) -> [MinuteBar] {
        if bars.isEmpty || start.contains("--") || start.isEmpty || end.contains("--") || end.isEmpty {
            return []
        }
        guard let s = minutes(start), let e = minutes(end) else { return [] }
        return bars.filter {
            guard let m = minutes($0.time) else { return false }
            return s <= m && m <= e
        }.sorted { $0.time < $1.time }
    }

    /// L3 纪律口径：卖出窗口内**首次触及 +target_pct%** 即视为已成交。
    ///
    /// 这是真实可执行的口径 ——「次日午前必卖，目标 +1.5%~+2%」：
    ///   · 窗口内任一根 5 分钟线的最高价 ≥ 目标价 → 限价单成交，收益 = target_pct
    ///   · 全程未触及 → 按窗口最后一根的收盘价卖出（有 5 分钟线才计算）
    ///
    /// 与「窗口内最高价」(ceiling) 的关键区别：后者假设卖在最高点，不可实现。
    public static func disciplinedOutcome(_ bars: [MinuteBar], start: String, end: String,
                                   selPrice: Double, targetPct: Double)
        -> (hit: Bool?, profit: Double?, time: String?) {
        if selPrice <= 0 || targetPct <= 0 { return (nil, nil, nil) }
        let wb = windowBars(bars, start: start, end: end)
        if wb.isEmpty { return (nil, nil, nil) }
        let targetPrice = selPrice * (1 + targetPct / 100)
        for b in wb where b.high >= targetPrice {
            return (true, PyMath.round(targetPct, 2), b.time)
        }
        let lastClose = wb.last?.close ?? 0
        if lastClose == 0 { return (false, nil, nil) }
        return (false, PyMath.round((lastClose - selPrice) / selPrice * 100, 2), nil)
    }

    /// 统一政策的次日结果
    /// （用同一把尺子量**所有**已评分标的，让调优器能把「评分/档位变动」与真实收益对上）
    public static func uniformOutcome(quote: [String: Any], todayBars: [MinuteBar], selPrice: Double,
                               window: (String, String), targetPct: Double) -> [String: Any] {
        let (ws, we) = window
        let pre = PredictRules.num(quote["pre_close"]) ?? 0
        let openPct: Any = pre > 0
            ? PyMath.round(((PredictRules.num(quote["open"]) ?? 0) - pre) / pre * 100, 2) : NSNull()
        let (hit, profit, hitTime) = disciplinedOutcome(todayBars, start: ws, end: we,
                                                        selPrice: selPrice, targetPct: targetPct)
        let windowHighV = todayBars.isEmpty ? 0 : windowHigh(todayBars, start: ws, end: we)

        func pnl(_ px: Double) -> Any {
            guard px != 0, selPrice > 0 else { return NSNull() }
            return PyMath.round((px - selPrice) / selPrice * 100, 2)
        }
        return [
            "open_pct": openPct,
            "disc_hit": hit.map { $0 ? 1 : 0 } ?? NSNull(),
            "disc_profit": profit ?? NSNull(),
            "disc_win": profit.map { $0 > 0 ? 1 : 0 } ?? NSNull(),
            "disc_hit_time": hitTime ?? NSNull(),
            "window_profit": windowHighV != 0 ? pnl(windowHighV) : NSNull(),
            "close_profit": pnl(PredictRules.num(quote["price"]) ?? 0),
            "high_profit": pnl(PredictRules.num(quote["high"]) ?? 0),
            "target_pct": targetPct, "window_start": ws, "window_end": we,
        ]
    }

    // MARK: - 历史日行情重建

    /// 并发扇出的**按序槽位**：每个迭代只写自己那一格（互不重叠，锁只是形式保护）。
    ///
    /// Swift 6 不允许在并发闭包里改捕获的 `var`，而"所有改动都在锁内"这件事编译器
    /// 看不出来 —— 用类型把意图写死。强调**按序**：组装一律按 `codes` 原序回读，
    /// 保证 `stock_outcomes` 的落库行序稳定。
    private final class ParallelSlots<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var slots: [T?]

        init(count: Int) { slots = Array(repeating: nil, count: count) }

        func set(_ i: Int, _ v: T) {
            lock.lock(); defer { lock.unlock() }
            slots[i] = v
        }

        var snapshot: [T?] {
            lock.lock(); defer { lock.unlock() }
            return slots
        }
    }

    /// 从日K重建指定交易日的「行情」（non-T+1 复盘用）。
    ///
    /// 为什么必须重建、不能沿用实时行情：`uniformOutcome` 吃的是**目标交易日**的
    /// open/high/close/pre_close。若在 T+5 重跑复盘仍用实时行情，就会把 T+5 的价格
    /// 当成 T+1 的收益写进 `stock_outcomes`，而 tuner 正是用这张表调参
    /// → 调优标签被静默污染。
    ///
    /// ⚠ **并发**用 `concurrentPerform` 扇出。安全性依赖两件既有事实：
    ///   `DataSources.klineCache` 自带锁；新浪的节流已被 `KlineThrottle` 收成全局排队
    ///   （全局速率上界 1/delay），**不会因为并发而多打扰数据源**。
    public static func historicalQuotes(codes: [String], day: String) -> [String: [String: Any]] {
        // `concurrentPerform(iterations: 0)` 会 trap —— 空入参必须提前返回
        guard !codes.isEmpty else { return [:] }
        let slots = ParallelSlots<[String: Any]>(count: codes.count)
        DispatchQueue.concurrentPerform(iterations: codes.count) { i in
            let code = codes[i]
            let bars = DataSources.fetchDailyKline(code, datalen: 70)
            // 限速由 fetchDailyKline 内部的 KlineThrottle 承担
            guard let idx = bars.firstIndex(where: { $0.day == day }) else {
                return
            }
            let b = bars[idx]
            let prevClose = idx > 0 ? bars[idx - 1].close : 0
            slots.set(i, ["code": code, "pre_close": prevClose,
                          "open": b.open, "high": b.high, "low": b.low, "price": b.close,
                          // change_pct 必须产出：缺键时下游 `num(q["change_pct"]) ?? 0` 恒取 0 ——
                          // 准确度评分里 `risk_level`(10 分) 与 `stop_loss_judgment` 的
                          // `close_pct < 0` 分支**永不成立**，且 0 是"假值"而非 null，
                          // 会当成真实涨跌写进 reviews.stocks_json。
                          "change_pct": prevClose > 0
                              ? PyMath.round((b.close - prevClose) / prevClose * 100, 2) : 0])
        }
        // 按 `codes` 原序组装（重复 code 时后者覆盖前者）
        var out: [String: [String: Any]] = [:]
        let done = slots.snapshot
        for (i, code) in codes.enumerated() {
            if let row = done[i] { out[code] = row }
        }
        return out
    }

    /// 上证指数在指定交易日的涨跌幅（%）
    public static func historicalIndexClosePct(_ day: String) -> Double {
        let bars = DataSources.fetchIndexDailyKline(symbol: "sh000001", datalen: 70)
        for (i, b) in bars.enumerated() where b.day == day && i > 0 {
            let prev = bars[i - 1].close
            return prev > 0 ? PyMath.round((b.close - prev) / prev * 100, 2) : 0
        }
        return 0
    }

    /// 并发取「目标交易日」的分时，返回与 `codes` **同序**的数组（缺数据为 `[]`）。
    ///
    /// 只做取数（`fetch5minBars` + 按日过滤，都是纯查/纯算），不做任何组装 ——
    /// 顺序敏感的部分（`uniformOutcome`、`outcomes.append`）留在调用方按原序执行。
    /// 与 `historicalQuotes` 同样依赖 `KlineThrottle` 把并发收成全局排队。
    private static func fetchTargetDayBars(codes: [String], day: String) -> [[MinuteBar]] {
        guard !codes.isEmpty else { return [] }
        let slots = ParallelSlots<[MinuteBar]>(count: codes.count)
        DispatchQueue.concurrentPerform(iterations: codes.count) { i in
            slots.set(i, DataSources.fetch5minBars(codes[i]).filter { $0.day == day })
        }
        return slots.snapshot.map { $0 ?? [] }
    }

    // MARK: - 主流程

    public static func review(persist: Bool = true, selDate: String? = nil,
                       params: [String: Any]) throws -> [String: Any] {
        let iterateCfg = (params["iterate"] as? [String: Any]) ?? [:]
        let thr = (iterateCfg["thresholds"] as? [String: Any]) ?? [:]
        // L3 纪律口径的目标幅度（对齐「次日午前必卖 +1.5%~+2%」）
        let discTargetPct = PredictRules.num(thr["discipline_target_pct"]).flatMap { $0 == 0 ? nil : $0 } ?? 1.5
        let runDay = DataSources.runDate()

        guard let predData = PhaseStore.shared.predictRow(selDate: selDate) else {
            return ["status": "no_predict_data"]
        }
        let selDateValue = (predData["sel_date"] as? String) ?? ""
        let predStocks = (predData["stocks"] as? [[String: Any]]) ?? []
        let predEnv = (predData["market_env"] as? [String: Any]) ?? [:]

        // 目标交易日（T+1）：优先交易日历；日历里没有"未来交易日"时（节后首日）用今日行情确认
        var uncertain = false
        let calendar = TradingCalendar(indexBars: DataSources.fetchIndexDailyKline(
            symbol: "sh000001", datalen: 260))
        let targetDay = calendar.nextTradingDay(
            selDateValue, uncertain: &uncertain,
            today: runDay, todayIsTrading: DataSources.isTradingDay().trading)
        let isLiveDay = (targetDay == runDay)
        let lamp = (predEnv["light"] as? String) ?? ""
        // 红灯=空仓观望日：标的不参与统计（`nil`/未识别 → 非 crash）
        let crashDay = (MarketLightLevel(json: predEnv["light"]) == .red)

        var result: [String: Any] = [
            "review_date": runDay, "review_time": PhaseStore.nowHM(),
            "sel_date": selDateValue, "target_day": targetDay,
            "target_day_estimated": uncertain,
            "data_mode": isLiveDay ? "live" : "replay_daily_kline",
            "light": lamp, "crash_day": crashDay,
            "is_empty_day": PredictRules.bool(predData["is_empty_day"]) ?? false,
            "stocks": [Any](), "four_layer_winrate": [String: Any](), "accuracy": [String: Any](),
            "insights": [Any](), "reference": NSNull(),
        ]

        // 上证收盘涨跌（大盘方向命中，20分）——非当日复盘必须取目标日的指数收盘，不能用实时
        let shClosePct: Double
        if isLiveDay {
            shClosePct = PredictRules.num(DataSources.fetchIndexQuote()["change_pct"]) ?? 0
        } else {
            shClosePct = historicalIndexClosePct(targetDay)
        }
        let predOpenPct = PredictRules.num(predEnv["sh_open_pct"]) ?? 0
        let marketHit = (predOpenPct > 0) == (shClosePct > 0)

        // ---- 全量已评分标的的次日结果台账（解 tuner 幸存者偏差，与 predict 无关）----
        let scored = PhaseStore.shared.scoredPicks(date: selDateValue)
        var uniSet = Set(predStocks.compactMap { $0["code"] as? String })
        uniSet.formUnion(scored.compactMap { $0["code"] as? String })
        let uni = uniSet.sorted()
        let discWindow = (thr["discipline_window"] as? [String]) ?? ["09:30", "11:30"]
        let uwin = (discWindow.count > 1 ? discWindow[0] : "09:30",
                    discWindow.count > 1 ? discWindow[1] : "11:30")

        var quotes: [String: [String: Any]] = [:]
        if uni.isEmpty {
            quotes = [:]
        } else if isLiveDay {
            quotes = DataSources.fetchTencentQuotes(uni)
        } else {
            // 非 T+1 当日：实时行情是"今天"的，不能拿来冒充目标日 → 从日K重建
            quotes = historicalQuotes(codes: uni, day: targetDay)
            DataSources.logDataSource("review", "replay_mode",
                                      "非 T+1 当日复盘：目标日 \(targetDay) 行情改由日K重建（实时行情不可用于历史日）")
        }

        var barsByCode: [String: [MinuteBar]] = [:]
        var outcomes: [[String: Any]] = []
        // 分时取数**并发**（串行 = 几十次请求 + 几十次全局限速）。
        // ⚠ 只并发**取数**；下面的组装（`uniformOutcome` / `outcomes.append`）仍按 `scored`
        //   原序执行 → `stock_outcomes` 的落库行序稳定。
        let scoredCodes = scored.map { ($0["code"] as? String) ?? "" }
        let barsList = fetchTargetDayBars(codes: scoredCodes, day: targetDay)
        for (i, c) in scored.enumerated() {
            let code = scoredCodes[i]
            // 分时只取**目标交易日**的 bar；取不到就留空 —— 宁缺勿错，绝不混入其它日期的分时
            let bars = barsList[i]
            barsByCode[code] = bars
            var o = uniformOutcome(quote: quotes[code] ?? [:], todayBars: bars,
                                   selPrice: PredictRules.num(c["sel_price"]) ?? 0,
                                   window: uwin, targetPct: discTargetPct)
            o["code"] = code
            o["name"] = c["name"] ?? NSNull()
            o["tier"] = c["tier"] ?? NSNull()
            o["skipped"] = crashDay ? 1 : 0
            // 落**基准价**：T+3/T+5 是两天后才算的，那时再从 picks 反推基准价会与这里的
            // close_profit 用上不同基准（重跑扫描会追加 picks 轮次 → "最晚一轮"的价会变）
            // → 三个窗不再可比。
            o["sel_price"] = c["sel_price"] ?? NSNull()
            outcomes.append(o)
        }
        result["outcomes"] = ["count": outcomes.count, "window": [uwin.0, uwin.1],
                              "target_pct": discTargetPct]
        if persist && !outcomes.isEmpty {
            try PhaseStore.shared.persistOutcomes(selDate: selDateValue, rows: outcomes)
        }

        // 多观察窗回填（T+3 / T+5 收盘）。
        //
        // ⚠ **位置很关键**：必须在 T+1 结果刚落库之后、且**早于**下面 `predStocks.isEmpty`
        //   的提前 return —— 空仓日同样要补历史行。
        // ⚠ 只有 `persist` 才做（它是写操作）。
        // ⚠ 异常已在 `runAndLog` 内吞掉：补不上不该让整个复盘判定失败。
        if persist {
            OutcomeWindowBackfill.runAndLog(calendar: calendar)
        }

        if predStocks.isEmpty {
            result["status"] = "empty_day"
            result["accuracy"] = ["avg_score": 0, "market_hit": marketHit]
            if persist { try persistReview(result, thr: thr) }
            return result
        }

        var stockResults: [[String: Any]] = []
        for st in predStocks {
            let code = (st["code"] as? String) ?? ""
            let q = quotes[code] ?? [:]
            let selPrice = PredictRules.num(st["sel_price"]) ?? 0
            let closePrice = PredictRules.num(q["price"]) ?? 0
            let closePct = PredictRules.num(q["change_pct"]) ?? 0
            let pre = PredictRules.num(q["pre_close"]) ?? 0
            let openPct = pre > 0
                ? PyMath.round(((PredictRules.num(q["open"]) ?? 0) - pre) / pre * 100, 2) : 0

            if barsByCode[code] == nil {
                // 只认目标交易日（用墙上时钟的今日，重跑时会取到今天的分时）
                barsByCode[code] = DataSources.fetch5minBars(code).filter { $0.day == targetDay }
            }
            let todayBars = barsByCode[code] ?? []

            var intradayHigh = todayBars.map(\.high).max() ?? 0
            if intradayHigh == 0 { intradayHigh = PredictRules.num(q["high"]) ?? 0 }
            var intradayLow = todayBars.map(\.low).min() ?? 0
            if intradayLow == 0 { intradayLow = PredictRules.num(q["low"]) ?? 0 }
            var highTime: String? = nil
            if !todayBars.isEmpty {
                highTime = todayBars.max { $0.high < $1.high }?.time
            }

            // 9时点盈亏
            var tpProfits: [String: Any] = [:]
            for tp in timePoints {
                let p = todayBars.first { $0.time == tp }?.close
                if let p = p, selPrice > 0 {
                    tpProfits[tp] = PyMath.round((p - selPrice) / selPrice * 100, 2)
                } else {
                    tpProfits[tp] = NSNull()
                }
            }

            func pnl(_ price: Double) -> Any {
                guard price != 0, selPrice > 0 else { return NSNull() }
                return PyMath.round((price - selPrice) / selPrice * 100, 2)
            }

            let snapshotProfit = tpProfits["10:00"] ?? NSNull()
            let closeProfit = pnl(closePrice)
            let ws = (st["sell_window_start"] as? String) ?? ""
            let we = (st["sell_window_end"] as? String) ?? ""
            let windowHighV = (!todayBars.isEmpty && !ws.contains("--") && !we.contains("--"))
                ? windowHigh(todayBars, start: ws, end: we) : 0
            let windowProfit: Any = windowHighV != 0 ? pnl(windowHighV) : NSNull()
            let highProfit = pnl(intradayHigh)

            // L3 纪律口径：窗口内首次触及目标价即视为成交（可执行）
            // ⚠ 目标幅度必须用**这只票实际被告知的那个数**（2026-10-16 审查 B5-10）：
            //   原先这里传的是全局 `discTargetPct`（政策 `discipline_target_pct`，默认 1.5），
            //   而同一行展示给用户的 `target_price` 来自策略的
            //   `strategy.target_pct ± regime_thresholds.target_adj`（牛市回调下是 1.0）。
            //   于是"可执行主口径"的胜率是在 **+1.5%** 上度量一个用户被 told 到 **+1.0%** 的计划
            //   ⇒ 系统性**低估**了真实建议的胜率（目标越近越容易触及）。
            //   反推优先：用 `target_price / sel_price` 得到真实幅度；推不出（价格缺失）才回落政策值。
            let stTargetPrice = PredictRules.num(st["target_price"]) ?? 0
            let rowTargetPct = (stTargetPrice > 0 && selPrice > 0)
                ? PyMath.round((stTargetPrice - selPrice) / selPrice * 100, 2)
                : discTargetPct
            let disc = disciplinedOutcome(todayBars, start: ws, end: we,
                                          selPrice: selPrice, targetPct: rowTargetPct)

            let discWin: Any = disc.profit.map { $0 > 0 ? 1 : 0 } ?? NSNull()
            // L1 跳空口径：次日开盘是否高开（最贴近「高开卖出」但成交价不可控）。
            // 取不到行情（`pre <= 0`）时 openPct 恒为 0，若仍写 `gap_win = openPct > 0 ? 1 : 0`
            // 会把"**没有数据**"记成**一次亏损** —— 同一只票的 `close_profit = pnl(0)`
            // 却是 NSNull 被排除，两层口径必须一致。
            // `layerWinrate` 会跳过 nil，所以给 NSNull 即"不计入 L1 分母"。
            let hasQuote = pre > 0
            let gapProfit: Any = hasQuote ? openPct : NSNull()
            let gapWin: Any = hasQuote ? (openPct > 0 ? 1 : 0) : NSNull()

            let skipped = ws.contains("--") || we.contains("--")
            let actual: [String: Any] = [
                "open_pct": openPct, "high_time": highTime ?? NSNull(),
                "intraday_high": intradayHigh, "intraday_low": intradayLow,
                "close_pct": closePct,
            ]
            let acc = calcAccuracy(pred: st, actual: actual) + (marketHit ? 20 : 0)

            func winOf(_ v: Any) -> Any {
                guard let d = PredictRules.num(v) else { return NSNull() }
                return d > 0 ? 1 : 0
            }
            // ⚠ 拆成逐项赋值：整块字典字面量会让类型检查器超时
            var row: [String: Any] = [:]
            row["code"] = code
            row["name"] = st["name"] ?? code
            row["signal_type"] = st["signal_type"] ?? NSNull()
            row["sel_price"] = selPrice
            row["close_price"] = closePrice
            row["close_pct"] = closePct
            row["open_pct"] = openPct
            row["intraday_high"] = intradayHigh
            row["intraday_low"] = intradayLow
            row["high_time"] = highTime ?? NSNull()
            row["snapshot_profit"] = snapshotProfit
            row["snapshot_win"] = winOf(snapshotProfit)
            row["close_profit"] = closeProfit
            row["close_win"] = winOf(closeProfit)
            row["window_high"] = windowHighV != 0 ? windowHighV : NSNull()
            row["window_profit"] = windowProfit
            row["window_win"] = winOf(windowProfit)
            row["high_profit"] = highProfit
            row["high_win"] = winOf(highProfit)
            row["skipped"] = skipped
            row["accuracy_score"] = acc
            row["sell_window"] = "\(ws)-\(we)"
            row["target_price"] = st["target_price"] ?? 0
            row["stop_loss_price"] = st["stop_loss_price"] ?? 0
            row["risk_level"] = st["risk_level"] ?? ""
            row["tp_profits"] = tpProfits
            // L3 纪律口径（可执行的主口径，供 tuner 使用）
            row["disc_win"] = discWin
            row["disc_profit"] = disc.profit ?? NSNull()
            // ⚠ `disc_hit` 在 stock_results 里是**原始布尔**，而 `stock_outcomes` 里是 1/0
            //   （`uniformOutcome` 转换过）—— 两处口径**有意不同**，不要"顺手统一"。
            row["disc_hit"] = disc.hit ?? NSNull()
            row["disc_hit_time"] = disc.time ?? NSNull()
            row["disc_target_pct"] = rowTargetPct

            // L1 跳空口径
            row["gap_win"] = gapWin
            row["gap_profit"] = gapProfit
            stockResults.append(row)
        }

        // 四层胜率汇总（仅参与统计：非 skipped）
        let participating = stockResults.filter { !PredictRules.truthy($0["skipped"]) }
        let allSkipped = !stockResults.isEmpty && participating.isEmpty

        func layerWinrate(_ key: String, _ profitKey: String) -> [String: Any] {
            let valid = participating.filter { PredictRules.num($0[key]) != nil }
            guard !valid.isEmpty else {
                return ["winrate": 0, "wins": 0, "total": 0, "avg_profit": 0]
            }
            let wins = valid.reduce(0) { $0 + Int(PredictRules.num($1[key]) ?? 0) }
            // ⚠ 浮点求和必须走 `PyMath.sum`（Neumaier 补偿）：朴素 `reduce(0.0)` 会在末位
            // 累积误差 → 除以条数再 `round(_, 2)` 后可能差 0.01，进而影响复盘胜率与洞察触发。
            // （上一行 `wins` 是 0/1 整数求和，两种算法都精确，保持原样。）
            let avg = PyMath.sum(valid.map { PredictRules.num($0[profitKey]) ?? 0 })
                / Double(valid.count)
            return ["winrate": PyMath.round(Double(wins) / Double(valid.count) * 100, 1),
                    "wins": wins, "total": valid.count,
                    "avg_profit": PyMath.round(avg, 2)]
        }

        let fourLayer: [String: Any] = [
            "snapshot": layerWinrate("snapshot_win", "snapshot_profit"),
            "close": layerWinrate("close_win", "close_profit"),
            "window": layerWinrate("window_win", "window_profit"),
            "ceiling": layerWinrate("high_win", "high_profit"),
            // L3：窗口内首次触及目标价（可执行主口径）
            "disciplined": layerWinrate("disc_win", "disc_profit"),
            // L1：次日开盘跳空为正
            "gap": layerWinrate("gap_win", "gap_profit"),
        ]
        result["four_layer_winrate"] = fourLayer
        result["disciplined_target_pct"] = discTargetPct
        // ⚠ "L3 纪律口径"在本报告里其实是**两套**测量，名字撞在一起过（审查 B5-10），
        //   现在把两者的坐标显式写出来，避免下游（含人）拿一个名字读两份数：
        //   · `stock_results.disc_*`（四层胜率读的这套）= **各标的策略卖出窗口** + **该行 target_price 反推的幅度**
        //   · `stock_outcomes.disc_*`（调优器标签读的这套）= **政策 discipline_window** + `discipline_target_pct`
        result["disc_caliber"] = [
            "stock_results": ["window": "各标的 strategy.sell_window_*",
                              "target_pct": "该行 target_price 反推（缺失才回落 discipline_target_pct）"],
            "stock_outcomes": ["window": (thr["discipline_window"] as? [String]) ?? [],
                               "target_pct": discTargetPct],
        ]


        // 准确度汇总
        let avgAcc = stockResults.isEmpty ? 0
            : PyMath.round(Double(stockResults.reduce(0) { $0 + (PredictRules.int($1["accuracy_score"]) ?? 0) })
                           / Double(stockResults.count), 1)
        let windowHits = stockResults.filter {
            !($0["high_time"] is NSNull) && !(($0["sell_window"] as? String) ?? "").contains("--")
        }.count
        let windowTotal = stockResults.filter {
            !(($0["sell_window"] as? String) ?? "").contains("--")
        }.count
        var targetDiffs: [Double] = []
        for r in stockResults {
            let t = PredictRules.num(r["target_price"]) ?? 0
            let h = PredictRules.num(r["intraday_high"]) ?? 0
            let s = PredictRules.num(r["sel_price"]) ?? 0
            if t > 0 && h > 0 && s > 0 {
                targetDiffs.append(abs((t - s) / s * 100 - (h - s) / s * 100))
            }
        }
        result["accuracy"] = [
            "avg_score": avgAcc, "market_hit": marketHit,
            "window_hit_rate": windowTotal > 0
                ? PyMath.round(Double(windowHits) / Double(windowTotal) * 100, 1) : 0,
            // 浮点求和走 PyMath.sum（Neumaier 补偿，同 layerWinrate）
            "avg_target_diff": targetDiffs.isEmpty ? 0
                : PyMath.round(PyMath.sum(targetDiffs) / Double(targetDiffs.count), 2),
        ]

        // 洞察
        var insights: [String] = []
        if allSkipped {
            let cw = stockResults.filter { PredictRules.num($0["close_win"]) != nil }
            let hw = stockResults.filter { PredictRules.num($0["high_win"]) != nil }
            result["reference"] = [
                // 浮点求和走 PyMath.sum（Neumaier 补偿，同 layerWinrate）
                "close_winrate": cw.isEmpty ? 0
                    : PyMath.round(PyMath.sum(cw.map { PredictRules.num($0["close_win"]) ?? 0 })
                                   / Double(cw.count) * 100, 1),
                "ceiling_winrate": hw.isEmpty ? 0
                    : PyMath.round(PyMath.sum(hw.map { PredictRules.num($0["high_win"]) ?? 0 })
                                   / Double(hw.count) * 100, 1),
            ]
            insights.append("暴跌日：所有标的均不参与胜率统计，空仓观望是正确策略")
        } else {
            func wr(_ layer: String) -> Double {
                PredictRules.num((fourLayer[layer] as? [String: Any])?["winrate"]) ?? 0
            }
            // ⚠ "有没有样本"必须问 `total`，不能拿 `winrate > 0` 当代理判据
            //   （2026-10-16 审查 B5-2）：`layerWinrate` 对**空集**返回的是 `winrate: 0`，
            //   而 0% 恰好也是"5 只全亏"的合法结果。原先所有诊断分支都写成 `w > 0 && h > 0 …`，
            //   于是**最糟的一天（全亏 ⇒ 胜率 0）会让每一条分支都判假**，
            //   直接落到末尾的 `insights.isEmpty` 分支，输出
            //   「四层胜率无显著偏差模式，当前策略配置合理」——
            //   在策略当天彻底失败的那天，界面给出一句"配置合理"。
            func tot(_ layer: String) -> Int {
                Num.intOrNil((fourLayer[layer] as? [String: Any])?["total"]) ?? 0
            }

            let w = wr("window"), s = wr("snapshot"), c = wr("close"), h = wr("ceiling")
            let d = wr("disciplined")
            let hasW = tot("window") > 0, hasS = tot("snapshot") > 0
            let hasC = tot("close") > 0, hasH = tot("ceiling") > 0, hasD = tot("disciplined") > 0
            let vsSnap = PredictRules.num(thr["window_vs_snap"]) ?? 0
            let vsClose = PredictRules.num(thr["window_vs_close"]) ?? 0
            let hiVsWin = PredictRules.num(thr["high_vs_window"]) ?? 0
            let lowWr = PredictRules.num(thr["low_winrate"]) ?? 0
            let lowHWr = PredictRules.num(thr["low_high_winrate"]) ?? 0
            if hasW && hasS && w > s + vsSnap {
                insights.append("窗口可用胜率(\(PyJSON.numStr(w))%)显著高于快照胜率(\(PyJSON.numStr(s))%) → "
                                + "卖点偏晚，10点还没涨起来但窗口内涨了，维持当前窗口建议")
            }
            if hasW && hasC && w > c + vsClose {
                insights.append("窗口可用胜率(\(PyJSON.numStr(w))%)高于收盘持有胜率(\(PyJSON.numStr(c))%) → "
                                + "午后跳水，必须在上午卖，加强「午前必卖」提示")
            }
            if hasH && hasW && h > w + hiVsWin {
                insights.append("策略上限胜率(\(PyJSON.numStr(h))%)高于窗口可用胜率(\(PyJSON.numStr(w))%) → "
                                + "选股没问题但卖出时机判断有偏差，考虑调整窗口时间段")
            }
            if hasD && hasH && h > d + hiVsWin {
                insights.append("纪律口径胜率(\(PyJSON.numStr(d))%, 目标=各行 disc_target_pct)"
                                + "远低于策略上限(\(PyJSON.numStr(h))%) → "
                                + "目标幅度偏乐观，窗口内多数标的摸不到目标价；可考虑下调目标或延后卖出窗口")
            }

            if hasW && hasH && w < lowWr && h < lowHWr {
                insights.append("四层胜率都偏低(窗口\(PyJSON.numStr(w))%/上限\(PyJSON.numStr(h))%) → "
                                + "选股策略或大盘环境判断有问题，检查筛选条件")
            }
            if insights.isEmpty {
                // 分两种收尾：**有样本但没触发任何偏差模式** 才是"配置合理"；
                // 四层全都没有样本时不能说"合理"，只能说"今天无从判断"。
                if !hasW && !hasS && !hasC && !hasH {
                    insights.append("四层胜率均无有效样本（当日标的全部 skipped 或未落库），"
                                    + "本期无法判断配置，不给出结论")
                } else {
                    insights.append("四层胜率无显著偏差模式，当前策略配置合理")
                }
            }
        }

        result["insights"] = insights

        result["stocks"] = stockResults
        result["status"] = "ok"
        if persist { try persistReview(result, thr: thr) }
        return result
    }

    // MARK: - 落库（含 accuracy_track 追踪行）

    private static func persistReview(_ result: [String: Any], thr _: [String: Any]) throws {
        let fl = (result["four_layer_winrate"] as? [String: Any]) ?? [:]
        let acc = (result["accuracy"] as? [String: Any]) ?? [:]
        let insights = (result["insights"] as? [Any]) ?? []
        // ⚠ reference 未触发暴跌日时是 null（落库为 "null"）
        let reference = result["reference"] ?? NSNull()
        let isEmpty = PredictRules.bool(result["is_empty_day"]) ?? false
        try PhaseStore.shared.persistReview(
            selDate: (result["sel_date"] as? String) ?? "",
            reviewTime: (result["review_time"] as? String) ?? "",
            fourLayer: fl, accuracy: acc,
            stocks: (result["stocks"] as? [[String: Any]]) ?? [],
            isEmptyDay: isEmpty, insights: insights, reference: reference)
        // 追加 prediction_accuracy 追踪行
        try PhaseStore.shared.appendAccuracyTrack(detail: [
            "sel_date": result["sel_date"] ?? "",
            "snap": fl["snapshot"] ?? [String: Any](),
            "close": fl["close"] ?? [String: Any](),
            "window": fl["window"] ?? [String: Any](),
            "ceiling": fl["ceiling"] ?? [String: Any](),
            "accuracy": acc,
        ])
    }
}