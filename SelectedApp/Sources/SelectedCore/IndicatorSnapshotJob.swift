import Foundation

/// 指标快照的**收盘后日更任务**。
///
/// ## 为什么单独一个 job
/// 与 `FundFlowJob` 同理：收盘后时点数据、独立状态、失败不牵连复盘/迭代。
/// 快照值可由"历史K线 + 当日行情"重算，但**历史时点的名次不可重取**
/// （今天的 MACD 金叉列表，明天回看要用今天落库的快照）—— 所以落库。
///
/// ## 数据源架构（两道拼合，单位贯通"手"）
///   · 历史窗口：`history.sqlite3` `daily_bars`（volume=手，仅由设置页"回放"写入）
///   · 今日 bar：收盘后全市场 quote 合成（`EngineQuote` 的 volume 本就是**手**，
///     **不 ×100** —— `EngineIndicators.appendTodayBar` 是引擎"股"单位体系，不可复用）
///   · 停牌/无有效报价 → 今日 bar 造不出来 → **整行不写**（陈旧值冒充今日是禁区）
///
/// ## ⚠ 新鲜度闸门（历史库可能整体滞后或为空）
/// 缺口 = 指数日历（`indexDays(sh000001)`，回放同源）里落在
/// 「个股最后缓存日, 今日」开区间的交易日数。>1 或库空 → `data_insufficient`，
/// 文案**指向"设置页执行回放"**（这是需要用户动作的失败，调度器自动重试补不出来）。
/// 已知盲区（有意接受）：回放整体停摆时个股/指数同日同旧，缺口恒 0 —— 那时
/// 指标窗口含"洞"，与个股长期停牌同类；筛选页按 `trade_date` 展示入库日自证新鲜度。
///
/// ## 幂等
/// 整日重插（`IndicatorSnapshotStore.saveDay`）⇒ 盘中手动触发=盘中快照、
/// 收盘调度=终态覆盖，跑几次结果都是"最后一次的那份"。
public enum IndicatorSnapshotJob {

    /// 指标窗口读取的交易日根数（覆盖全部默认周期的预热：MACD 35、AO 34、
    /// 布林 20，再留 EMA/KAMA 递推收敛余量）
    public static let windowBars = 120

    /// 失败原因（`LocalizedError` → `Scheduler` 取 `errorDescription` 作重试原因文案）
    public enum Failure: LocalizedError {
        /// 历史K线库为空（从没跑过回放）
        case historyEmpty
        /// 历史K线库滞后（缺口 > 1 个交易日）
        case historyStale(latest: String, today: String, gapDays: Int)
        /// 全市场行情覆盖率不足（同扫描口径 `ScanRunner.minQuoteCoverage`）
        case lowCoverage(ratio: Double, requested: Int, returned: Int)

        public var errorDescription: String? {
            switch self {
            case .historyEmpty:
                // ⚠ 不写"稍后重试"：重试补不出历史，要的是用户去设置页动作
                return "历史K线库为空，指标窗口算不出来 —— 请到 设置 › 历史回放 下载日K缓存后重试"
            case .historyStale(let latest, let today, let gapDays):
                return "历史K线库滞后（最新 \(latest)，期望 \(today)，缺 \(gapDays) 个交易日）——"
                    + "请到 设置 › 历史回放 补下后重试"
            case .lowCoverage(let ratio, let requested, let returned):
                return "全量行情覆盖率仅 \(DataSources.pct1(ratio))（请求 \(requested) / 返回 \(returned)），"
                    + "低于阻断阈值 \(ScanRunner.minQuoteCoverage)，本轮不落库"
            }
        }
    }

    /// 收盘后跑一次：闸门 → 读窗口 → 合成今日 bar → 全指标末值 → 整日重插。
    ///
    /// - Returns: `status` = `ok` / `not_trading_day`（后者不抛错，同 `FundFlowJob` 约定）
    /// - Throws: `Failure`（可重试类失败，由调度器补跑窗口处理）
    /// - Parameter shouldStop: 取消检查闭包（审查 #12）：行情批处理与落库前各读一次，
    ///   `Scheduler.stop()` 置位取消盒后不再取数、不再写库。
    public static func run(shouldStop: () -> Bool = { false }) throws -> [String: Any] {
        let started = Date()
        let today = ChinaTime.day()

        // ① 交易日闸门
        let (isTrading, reason) = DataSources.isTradingDay()
        guard isTrading else {
            DataSources.logDataSource("indsnap", "skip_not_trading_day", "非交易日（\(reason)）→ 跳过")
            return ["status": "not_trading_day", "trading_day_reason": reason, "date": today]
        }

        // ② 新鲜度闸门（在抓取之前判，别用网络换一次注定作废的计算）
        let stockDays = HistoryBarStore.tradingDays()
        guard let lastCached = stockDays.last else { throw Failure.historyEmpty }
        let calendar = TradingCalendar(days: HistoryBarStore.indexDays(
            symbol: HistoryReplayJob.indexSymbols[0]))
        let gap = Self.gapDays(calendar: calendar, lastCached: lastCached, today: today)
        guard gap <= 1 else {
            throw Failure.historyStale(latest: lastCached, today: today, gapDays: gap)
        }

        // ③ 全市场收盘行情（批处理/熔断在 `fetchAllQuotes` 内部）
        let (rawQuotes, source) = DataSources.fetchAllQuotes(shouldStop: shouldStop)
        let stat = DataSources.lastQuoteStat()
        let req = stat["requested"] as? Int ?? rawQuotes.count
        let got = stat["returned"] as? Int ?? rawQuotes.count
        let ratio = stat["ratio"] as? Double ?? (req > 0 ? PyMath.round(Double(got) / Double(req), 4) : 0)
        guard ratio >= ScanRunner.minQuoteCoverage else {
            throw Failure.lowCoverage(ratio: ratio, requested: req, returned: got)
        }

        // ④ 读历史窗口（一次查询按 code 分组；beg = 个股缓存里倒数第 windowBars 个交易日）
        guard stockDays.count >= 2 else {
            throw Failure.historyStale(latest: lastCached, today: today, gapDays: stockDays.count)
        }
        let beg = stockDays[max(0, stockDays.count - Self.windowBars)]
        let historyByCode = HistoryBarStore.barsByCode(from: beg, to: today)

        // ⑤ 逐只：合成今日 bar → 全指标末值。无今日 bar（停牌/脏报价）整行不写。
        var rows: [IndicatorSnapshotStore.Row] = []
        rows.reserveCapacity(historyByCode.count)
        for (code, cached) in historyByCode {
            guard let raw = rawQuotes[code] else { continue }
            let quote = EngineQuote(json: raw)
            guard let todayBar = Self.makeTodayBar(quote: quote, code: code, day: today) else {
                continue
            }
            var bars = cached
            if Self.shouldAppendToday(lastCachedDay: bars.last?.day ?? "", today: today) {
                bars.append(todayBar)
            }
            rows.append(IndicatorSnapshotStore.Row(code: code, values: Self.snapshotValues(bars: bars)))
        }
        guard !rows.isEmpty else {
            throw Failure.lowCoverage(ratio: 0, requested: historyByCode.count, returned: 0)
        }

        // ⑥ 整日重插 + 日志 —— 取消检查（审查 #12）：退出时不再写库
        if shouldStop() { return ["status": "cancelled", "date": today] }
        let stamp = PhaseStore.nowStamp()
        let saved = try IndicatorSnapshotStore.saveDay(date: today, rows: rows, at: stamp)
        let elapsed = Date().timeIntervalSince(started)
        DataSources.logDataSource("indsnap", "indsnap_ok",
                                  "\(today) 落库 \(saved) 只（行情源 \(source)，"
                                    + "耗时 \(String(format: "%.1f", elapsed))s）")
        return [
            "status": "ok",
            "date": today,
            "saved": saved,
            "window_from": beg,
            "quote_source": source,
            "elapsed_sec": elapsed,
        ]
    }

    // MARK: - 纯函数（单测面）

    /// 缺口交易日数：日历里落在 `(lastCached, today)` 开区间的天数。
    /// 日历为空（指数没回放）→ 退化为 0（无法判缺口，交给"库空"闸门兜底）。
    public static func gapDays(calendar: TradingCalendar, lastCached: String, today: String) -> Int {
        calendar.days.filter { $0 > lastCached && $0 < today }.count
    }

    /// 是否追加今日 bar：缓存末根**已经含今日**（回放抓到当天）→ 不追加，防双计。
    public static func shouldAppendToday(lastCachedDay: String, today: String) -> Bool {
        lastCachedDay < today
    }

    /// 用收盘 quote 合成今日 `HistoryBar`（volume 保持**手**，与 daily_bars 同单位）。
    /// 脏报价（≤0 / 高低自相矛盾 / 缺 code）→ nil = 当日无可信 bar（停牌等），调用方整行跳过。
    /// ⚠ `amount` 是 quote 原值（腾讯口径=万元；`daily_bars` 里东财口径=元）——
    ///   指标库**不读** amount/振幅/换手，混存无影响，但别拿这张表的 amount 跨源比较。
    public static func makeTodayBar(quote: EngineQuote, code: String, day: String) -> HistoryBar? {
        let o = quote.open, h = quote.high, l = quote.low, c = quote.price
        guard !code.isEmpty, !day.isEmpty else { return nil }
        guard min(min(o, h), min(l, c)) > 0 else { return nil }
        guard h >= max(o, c), l <= min(o, c) else { return nil }
        return HistoryBar(code: code, day: day, open: o, close: c, high: h, low: l,
                          volume: quote.volume, amount: quote.amount,
                          amplitude: quote.amplitude, changePct: quote.changePct,
                          turnover: quote.turnover)
    }

    /// 全指标末值 → 列名字典（键必须与 `IndicatorSnapshotStore.columns` 双向一致，
    /// 由 `IndicatorSnapshotJobTests` 钉死；预热不足 → nil → 落库 NULL）。
    ///
    /// ⚠ 周期/参数从 B 域 `indicator_params`（`period.*` 键）取，缺键回落注册表默认。
    ///   **改了周期必须重算快照**（编辑 sheet 负责触发）。
    public static func snapshotValues<B: Sequence>(bars: B) -> [String: Double?]
    where B.Element: VolumeBar {
        let last = IndicatorPrimitives.last
        func pi(_ id: String, _ param: String, _ def: Int) -> Int {
            IndicatorParamStore.period(id: id, param: param, default: def)
        }
        func pf(_ id: String, _ param: String, _ def: Double) -> Double {
            IndicatorParamStore.period(id: id, param: param, default: def)
        }
        var v: [String: Double?] = [:]

        // 趋势
        v["ema_value"] = last(TrendIndicators.ema(bars, period: pi("ema", "period", 20)))
        let macd = TrendIndicators.macd(bars,
                                        fast: pi("macd", "fast", 12),
                                        slow: pi("macd", "slow", 26),
                                        signal: pi("macd", "signal", 9))
        v["macd_line"] = last(macd.line)
        v["macd_signal"] = last(macd.signal)
        v["macd_hist"] = last(macd.histogram)
        v["hma_value"] = last(TrendIndicators.hma(bars, period: pi("hma", "period", 20)))
        v["kama_value"] = last(TrendIndicators.kama(bars,
                                                    erPeriod: pi("kama", "er", 10),
                                                    fast: pi("kama", "fast", 2),
                                                    slow: pi("kama", "slow", 30)))

        // 动量
        v["rsi_wilder_value"] = last(MomentumIndicators.rsiSeries(bars, period: pi("rsiWilder", "period", 14)))
        let st = MomentumIndicators.stochastic(bars, period: pi("stochastic", "period", 14),
                                               smooth: pi("stochastic", "smooth", 3))
        v["stochastic_k"] = last(st.k)
        v["stochastic_d"] = last(st.d)
        v["stochastic_rsi_value"] = last(MomentumIndicators.stochasticRsi(bars, period: pi("stochasticRsi", "period", 14)))
        let ppo = MomentumIndicators.ppo(bars,
                                         fast: pi("ppo", "fast", 12),
                                         slow: pi("ppo", "slow", 26),
                                         signal: pi("ppo", "signal", 9))
        v["ppo_line"] = last(ppo.line)
        v["ppo_signal"] = last(ppo.signal)
        v["ppo_hist"] = last(ppo.histogram)
        v["awesome_oscillator_value"] = last(MomentumIndicators.awesomeOscillator(
            bars, short: pi("awesomeOscillator", "short", 5), long: pi("awesomeOscillator", "long", 34)))
        v["ultimate_oscillator_value"] = last(MomentumIndicators.ultimateOscillator(
            bars, short: pi("ultimateOscillator", "short", 7),
            medium: pi("ultimateOscillator", "medium", 14), long: pi("ultimateOscillator", "long", 28)))

        // 波动率
        let atrPeriod = pi("atrSma", "period", 14)
        v["atr_sma_value"] = last(VolatilityIndicators.atrSmaSeries(bars, period: atrPeriod))
        let bb = VolatilityIndicators.bollingerBands(bars, period: pi("bollingerBands", "period", 20),
                                                     multiplier: pf("bollingerBands", "multiplier", 2))
        v["bollinger_bands_mid"] = last(bb.middle)
        v["bollinger_bands_upper"] = last(bb.upper)
        v["bollinger_bands_lower"] = last(bb.lower)
        v["bollinger_bands_bandwidth"] = last(bb.bandwidth)
        v["bollinger_bands_percent_b"] = last(bb.percentB)
        let dc = VolatilityIndicators.donchianChannel(bars, period: pi("donchianChannel", "period", 20))
        v["donchian_channel_upper"] = last(dc.upper)
        v["donchian_channel_mid"] = last(dc.middle)
        v["donchian_channel_lower"] = last(dc.lower)
        let kc = VolatilityIndicators.keltnerChannel(bars, period: pi("keltnerChannel", "period", 20),
                                                     multiplier: pf("keltnerChannel", "multiplier", 2))
        v["keltner_channel_mid"] = last(kc.middle)
        v["keltner_channel_upper"] = last(kc.upper)
        v["keltner_channel_lower"] = last(kc.lower)
        let supertrend = VolatilityIndicators.superTrend(bars, period: pi("superTrend", "period", 14),
                                                        multiplier: pf("superTrend", "multiplier", 2.5))
        v["super_trend_value"] = last(supertrend.line)
        v["super_trend_up"] = (supertrend.trendUp.last ?? nil).map { $0 ? 1 : 0 }
        v["ulcer_index_value"] = last(VolatilityIndicators.ulcerIndex(bars, period: pi("ulcerIndex", "period", 14)))

        // 成交量
        v["vwap_value"] = last(VolumeIndicators.vwap(bars, period: pi("vwap", "period", 14)))
        v["cmf_value"] = last(VolumeIndicators.cmf(bars, period: pi("cmf", "period", 20)))
        v["emv_value"] = last(VolumeIndicators.emv(bars, period: pi("emv", "period", 14)))
        v["force_index_value"] = last(VolumeIndicators.forceIndex(bars, period: pi("forceIndex", "period", 13)))
        v["money_flow_multiplier_value"] = VolumeIndicators.moneyFlowMultiplier(bars).last
        v["money_flow_volume_value"] = VolumeIndicators.moneyFlowVolume(bars).last

        // 基础列（非指标，筛选规则的比价基准；见 Store.baseColumns）
        let close = Array(bars).last?.close ?? 0
        v["close_value"] = close > 0 ? close : nil
        if let atr = last(VolatilityIndicators.atrSmaSeries(bars, period: atrPeriod)), close > 0 {
            v["atr_sma_percent"] = atr / close * 100
        } else {
            v["atr_sma_percent"] = nil
        }
        return v
    }
}
