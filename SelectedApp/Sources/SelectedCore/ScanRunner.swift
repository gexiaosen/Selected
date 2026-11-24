import Foundation

/// 选股扫描编排 —— 一轮完整扫描的流水线。
///
/// 八层流水线：交易日 → 全量行情（含健全性/报价日期两道闸门）→ 大盘环境 → 硬性过滤 →
/// 候选字段体检 → 稳健画像+避雷 → K线形态 → 深度验证+排除+评分+分档，末尾 ETF 与落库。
///
/// **调用约定**
///   · `params` / `paramVersion` 由调用方给（原生侧 = `ParamStore.activeParams()` +
///     `activeName()`）；本文件不读库取参数，也不读 CLI 环境变量（除 DataSources 的 fixture 开关）
///   · **同步阻塞**（网络 + 落库），调用方负责放到后台队列，不要在主线程调用
///   · `persist = true` 时经 `ScanStore.persistRound` 落库（同 date+slot 幂等）
public enum ScanRunner {

    /// 与 `config.SCREENER_VERSION` 逐字一致（落库字段，改了要同步两侧）
    public static let screenerVersion = "Selected-Engine 1.0.0 (基线: late-day-stock-picker-2 2026.9.10.r1)"
    /// 与 `config.MIN_EXPECTED_QUOTES` 一致
    public static let minExpectedQuotes = 4000
    /// 全量行情**覆盖率**阻断阈值。
    ///
    /// 选取依据：
    ///   · 健康日覆盖率约 **0.9996**（黄金夹具：5222/5224）—— 正常缺失极少
    ///   · 停牌股天然被 parse 跳过，正常偏低通常仍 >0.95（`DataSourcesQuotes` 的 low_coverage 仅提醒）
    ///   · 单批失败（500/≈5224 ≈ 9.5%）会把覆盖率砸到 ≈0.90 —— 跌破 0.93 即被拦截
    ///   ⇒ 0.93 = 能抓住"至少一批整批失败"，又给正常停牌波动留出余量。有意取舍，可调。
    public static let minQuoteCoverage = 0.93
    /// 与 `config.SLOT_LABELS` 一致
    public static let slotLabels = RoundPlan.labels


    // MARK: - 主流程

    /// 执行一轮完整扫描，返回结构化结果（含 round_id）。
    /// - Parameters:
    ///   - slot: 1/2/3；nil 时按当前时间判定轮次（`Screener.resolveSlot`，边界可被环境变量覆盖）
    ///   - ignoreTradingDay: 显式逃生阀（人工知情回放）：跳过交易日与报价日期两道闸门
    /// - Parameter shouldStop: **取消检查闭包**。
    ///   ⚠ 为什么需要它：本函数是**全同步**的（`runRound` 也在 `Task.detached` 里同步跑），
    ///   **没有 Task 上下文** ⇒ `Task.isCancelled` 在这里恒为 false ⇒
    ///   `Scheduler.stop()` 的 `runningTask?.cancel()` **对实际任务无效**。
    ///   ⇒ 由调用方（`Scheduler`）传入一个能读到 Task 取消状态的闭包。
    ///   缺省 `{ false }` ⇒ 不检查取消。
    public static func runScan(params: [String: Any], paramVersion: String,
                        slot: Int? = nil, slotLabel: String? = nil,
                        persist: Bool = true, ignoreTradingDay: Bool = false,
                        boundaries: [Int]? = nil,
                        shouldStop: () -> Bool = { false }) -> [String: Any] {
        let tStart = Date().timeIntervalSince1970
        let today = DataSources.runDate()

        // 判定轮次
        var resolvedSlot = slot
        var label = slotLabel
        if resolvedSlot == nil {
            // ⚠ `boundaries` 显式传下去，不走环境变量。
            let r = Screener.resolveSlot(now: nil, bounds: boundaries)
            resolvedSlot = r.slot
            label = r.label
        }
        let slotValue = resolvedSlot ?? 1
        let labelValue = label ?? Self.slotLabels[slotValue] ?? ""

        var result: [String: Any] = [
            "date": today, "slot": slotValue, "slot_label": labelValue,
            "run_time": Self.nowStamp(),
            "screener_version": Self.screenerVersion,
            "param_version": paramVersion,
            "market_env": [String: Any](), "stats": [String: Any](),
            "tier1": [Any](), "tier2": [Any](), "tier3": [Any](),
            "excluded_deep_trend": [Any](), "etf_recommendations": [Any](),
            "elapsed_sec": 0, "round_id": NSNull(),
        ]

        // ---- 第1层：交易日判断 ----
        let (isTrading, reason) = DataSources.isTradingDay()
        result["trading_day"] = isTrading
        result["trading_day_reason"] = reason
        if !isTrading && !ignoreTradingDay {
            result["status"] = "not_trading_day"
            return result
        }

        // ---- 第1.5层：画像区间自检（坏配置必须显式失败，不能"0 只但报 ok"）----
        // ⚠ 2026-10-16 审查 B5-7：`Screener.passesProfileRisk` 对非法区间是
        //   `guard … else { return false }` ⇒ 拒绝**每一只**票，而原先本轮仍以
        //   `status="ok"` 落库（`after_profile_filter=0`），`Signals.compare` 接着给出
        //   「末轮个股全部被淘汰，建议空仓观望」—— 参数错误被翻译成了交易结论。
        //   放在全量取数**之前**：配置坏时不白打 40–60 秒的网络。
        if let badRange = Screener.profileRangeProblem(Self.dict(params["profile_filter"])) {
            DataSources.logDataSource("params", "profile_range_invalid", badRange)
            result["status"] = "params_invalid"
            result["params_error"] = badRange
            return result
        }

        // ---- 第2层：全量扫描 ----
        let stockList = DataSources.fetchStockList()


        // ⚠ 取数前的一道取消检查：
        //   全量行情是**本轮最耗时的一步**（全市场 5000+ 只、分批请求，整轮 40~60 秒），
        //   也是最该能被中断的一步。
        if shouldStop() {
            result["status"] = "cancelled"
            result["data_error"] = "任务在取数前被取消（未落库）"
            result["elapsed_sec"] = PyMath.round(Date().timeIntervalSince1970 - tStart, 1)
            DataSources.logDataSource("scheduler", "cancelled",
                                      "第 \(resolvedSlot.map(String.init) ?? "?") 轮在取数前被取消")
            return result
        }

        let (rawQuotes, source) = DataSources.fetchAllQuotes(stockList, shouldStop: shouldStop)
        result["data_source"] = source
        var stats: [String: Any] = ["total_scanned": rawQuotes.count]
        // 行情覆盖率（请求数 vs 实得数）：让「缺了一大片」在界面上可见，而不是静默按"无行情"剔除。
        // ⚠ 放结果**顶层**而不是 stats：stats 是回归测试逐键比对的黄金结果，
        //   往 stats 加键会让"确定性回归"无谓变红。
        let qstat = DataSources.lastQuoteStat()
        if !qstat.isEmpty {
            result["quote_coverage"] = qstat["ratio"] ?? 0
            result["quote_requested"] = qstat["requested"] ?? 0
        }

        // ---- 健全性闸门：全量行情异常时中止本轮，不落库 ----
        // 网络整体故障时 is_trading_day() 会宽松返回"工作日(默认)"，扫描出 0 只却照样落一条
        // tier1=tier2=0 的轮次，污染 tuner 历史重放与 iterate 迭代统计。
        // 宁可这一轮没有记录，也不要一条假记录。
        if rawQuotes.count < Self.minExpectedQuotes {
            result["status"] = "data_insufficient"
            result["data_error"] = "全量行情仅 \(rawQuotes.count) 只，低于健全性阈值 "
                + "\(Self.minExpectedQuotes)，本轮不落库（等待自动重试）"
            result["elapsed_sec"] = PyMath.round(Date().timeIntervalSince1970 - tStart, 1)
            DataSources.logDataSource("tencent", "insufficient",
                                      "\(rawQuotes.count)只 < \(Self.minExpectedQuotes)，中止本轮不落库")
            return result
        }

        // ---- 覆盖率闸门 ----
        // 整批失败只影响约 500 只时，上面 4000 只闸门拦不住 —— 缺失个股被静默当"无行情"剔除，
        // 本轮照常落库并参与三轮信号与调优标签（结果偏了却无阻断，只有 low_coverage 日志留痕）。
        // 覆盖率跌破阈值 → 与健全性闸门同样处置：按可重试失败处理，不落库。
        // ⚠ 依赖 `quote_coverage`（`fetchAllQuotes` 顶部已写入 result）；复用上面的 `qstat`（恒非空，刚跑过）。
        if let ratio = qstat["ratio"] as? Double, ratio < Self.minQuoteCoverage {
            let req = qstat["requested"] as? Int ?? 0
            let got = qstat["returned"] as? Int ?? 0
            result["status"] = "data_insufficient"
            result["data_error"] = "全量行情覆盖率仅 \(DataSources.pct1(ratio))（请求 \(req) / 返回 \(got)），"
                + "低于阻断阈值 \(Self.minQuoteCoverage)，本轮不落库（等待自动重试）"
            result["elapsed_sec"] = PyMath.round(Date().timeIntervalSince1970 - tStart, 1)
            DataSources.logDataSource("tencent", "insufficient_coverage",
                                      "覆盖率 \(DataSources.pct1(ratio))（\(got)/\(req)）< \(Self.minQuoteCoverage)，中止本轮不落库")
            return result
        }

        // ---- 报价日期闸门（与 is_trading_day 同源）----
        // 节假日/数据源停更时腾讯仍返回**上一交易日**的全量行情（只数照样 5000+，
        // 上面的健全性闸门拦不住）。若照常落库，就会用昨日价格伪造出今日的三轮记录，
        // 进而让「三轮持续信号」成立 —— 污染信号分类、复盘与调优标签。
        if !ignoreTradingDay {
            if let staleDate = DataSources.staleQuoteDate(rawQuotes, today: today) {
                result["status"] = "data_insufficient"
                result["data_error"] = "全量行情报价日期为 \(staleDate)（非 \(today)）→ "
                    + "数据源未更新（休市或延迟），本轮不落库"
                result["elapsed_sec"] = PyMath.round(Date().timeIntervalSince1970 - tStart, 1)
                DataSources.logDataSource("tencent", "stale_quotes",
                                          "报价日期 \(staleDate) != 本轮日期 \(today)，中止本轮不落库")
                return result
            }
        }

        // 行情 → 引擎类型（后续各层都在 EngineQuote 上做，避免字典取值到处兜底）
        var quotes: [String: EngineQuote] = [:]
        quotes.reserveCapacity(rawQuotes.count)
        for (code, q) in rawQuotes { quotes[code] = EngineQuote(json: q) }

        // ---- 第4层：大盘环境（含涨跌家数与连跌检测）----
        let marketEnv = Screener.buildMarketEnv(params: params, allQuotes: quotes)
        result["market_env"] = marketEnv

        // ---- 第3层：硬性过滤 ----
        let hf = Self.dict(params["hard_filter"])
        let candidates = Screener.hardFilter(quotes, hf)
        stats["after_hard_filter"] = candidates.count

        // ---- 第5层：候选池字段体检 ----
        // 腾讯主源解析保证 volume_ratio/turnover/avg_price/open/high/low 全部存在（缺失填 0.0），
        // 不存在「字段为 None 需要二次拉取」的场景。
        // 这里做显式健壮性体检：关键字段为 0 的候选统计出来，异常时留痕，
        // 避免数据源悄悄退化却无人知晓。
        let zeroField = candidates.filter {
            $0.value.volumeRatio == 0 || $0.value.turnover == 0
                || $0.value.open == 0 || $0.value.high == 0 || $0.value.low == 0
        }
        stats["candidates_zero_field"] = zeroField.count
        if !zeroField.isEmpty {
            DataSources.logDataSource("tencent", "candidate_zero_field",
                                      "\(zeroField.count)/\(candidates.count) 只候选关键字段为0（会被画像/形态过滤挡掉）")
        }

        // ---- 第6层：稳健筛选 + 避雷 + ST/北交所排除 ----
        let pf = Self.dict(params["profile_filter"])
        let rf = Self.dict(params["risk_filter"])
        let stPattern = Self.regex(Self.str(hf["exclude_st_pattern"]))
        let bsePrefix = Self.str(hf["exclude_bse_prefix"])
        let afterRisk = candidates.filter { code, q in
            Screener.passesProfileRisk(code: code, q: q, pf: pf, rf: rf,
                                       stPattern: stPattern, bsePrefix: bsePrefix)
        }
        stats["after_profile_filter"] = afterRisk.count

        // ---- 第7层：K线形态过滤 ----
        let ff = Self.dict(params["form_filter"])
        var formPass: [String: (score: Int, details: [String])] = [:]
        for (code, q) in afterRisk {
            let (fs, details) = EngineIndicators.formCheck(
                q.open, q.price, q.high, q.low,
                upperShadowRatio: Self.num(ff["upper_shadow_ratio"]) ?? 0,
                closeHighRatio: Self.num(ff["close_high_ratio"]) ?? 0,
                bodyRatioMin: Self.num(ff["body_ratio_min"]) ?? 0)
            if Double(fs) >= (Self.num(ff["pass_threshold"]) ?? 0) {
                formPass[code] = (fs, details)
            }
        }
        stats["after_form_filter"] = formPass.count

        // ---- 第8层：深度验证 + 排除 + 评分 + 分档 ----
        let deepCfg = Self.dict(params["deep_filter"])
        let exclCfg = Self.dict(params["exclusion"])
        let scoring = Self.dict(params["scoring"])
        let tiersCfg = Self.dict(scoring["tiers"])
        let icCfg = Self.dict(scoring["intraday"])
        let budCfg = Self.dict(params["budget"])
        let budgetSec = Self.num(budCfg["deep_budget_sec"]) ?? 0
        let maxDeep = Self.int(budCfg["max_deep_candidates"]) ?? 0
        let klineDays = Self.int(deepCfg["kline_days"]) ?? 65
        let volAvgDays = Self.int(deepCfg["vol_avg_days"]) ?? 5
        let volMultNormalize = Self.bool(deepCfg["vol_mult_normalize"], true)
        let ma20SlopeLookback = Self.int(deepCfg["ma20_slope_lookback"]) ?? 5
        let icEnabled = Self.bool(icCfg["enabled"], true)
        let icMinBars = Self.int(icCfg["min_bars"]) ?? 20
        let icTailWindowMin = Self.int(icCfg["tail_window_min"]) ?? 30

        var excluded: [[String: Any]] = []
        var scored: [[String: Any]] = []

        // 深挖顺序：先看形态分（越高越好）、再看量比 —— 只在预算/上限真正触发时才有影响，
        // 不触发时全部候选都会被处理，结果与不排序完全一致（保证没预算压力时零行为变化）。
        // 注意：after_risk 里含未通过形态过滤的代码，必须先与 form_pass 取交集再排序。
        let formCodes = afterRisk.keys.filter { formPass[$0] != nil }
        let deepOrder = formCodes.sorted { a, b in
            let fa = formPass[a]?.score ?? 0, fb = formPass[b]?.score ?? 0
            if fa != fb { return fa > fb }
            let va = candidates[a]?.volumeRatio ?? 0, vb = candidates[b]?.volumeRatio ?? 0
            if va != vb { return va > vb }
            return a < b
        }
        let deepStarted = Date().timeIntervalSince1970
        var deepProcessed = 0
        var deepSkipped: [String] = []

        for code in deepOrder {
            if maxDeep > 0 && deepProcessed >= maxDeep {
                deepSkipped.append(code)
                continue
            }
            if budgetSec > 0 && (Date().timeIntervalSince1970 - deepStarted) > budgetSec {
                deepSkipped.append(code)
                continue
            }
            deepProcessed += 1
            guard let q = candidates[code] else { continue }
            var kline = DataSources.fetchDailyKline(code, datalen: klineDays)
            // ⚠ 新浪日K盘中不含当日 bar（末根 = T-1），而 `computeDeepInfo` 的全部索引
            //   都假定「末根 = 今日」。不补当日 bar 会让 vol_mult_5d / cum_5d / consec_up /
            //   prev_1d 整体错位一个交易日，且三轮恒等。
            kline = EngineIndicators.appendTodayBar(kline, q, today: today)
            let deepOpt = EngineIndicators.computeDeepInfo(
                kline, q, volAvgDays: volAvgDays,
                volMultNormalize: volMultNormalize,
                ma20SlopeLookback: ma20SlopeLookback)
            // 限速由 fetchDailyKline 内部的 KlineThrottle 承担：只在真的走网络时睡，
            // 缓存命中不白付 0.05s/次。
            guard let deep = deepOpt else { continue }

            // 深度趋势排除
            if deep.distFromHigh < (Self.num(exclCfg["deep_trend_threshold"]) ?? 0) {
                let thr = Self.num(exclCfg["deep_trend_threshold"]) ?? 0
                excluded.append([
                    "code": code, "name": q.name,
                    "reason": String(format: "距高点%.1f%%<-%.0f%% 深度下降趋势",
                                     deep.distFromHigh, abs(thr)),
                ])
                continue
            }

            // 脉冲双因子排除（使用当只标的 deep 数据，先算后用）
            let pulseGain = Self.num(exclCfg["pulse_gain_ratio"]) ?? 0
            let pulseShadow = Self.num(exclCfg["pulse_shadow_body"]) ?? 0
            if deep.gainRatio < pulseGain && deep.shadowBodyRatio > pulseShadow {
                excluded.append([
                    "code": code, "name": q.name,
                    "reason": String(format: "脉冲双因子(收益率%.2f<", deep.gainRatio)
                        + PyJSON.numStr(exclCfg["pulse_gain_ratio"] ?? 0)
                        + String(format: "+影体比%.2f>", deep.shadowBodyRatio)
                        + PyJSON.numStr(exclCfg["pulse_shadow_body"] ?? 0) + ")",
                ])
                continue
            }

            // 尾盘分时结构：放在两道排除之后，只对真正要打分的候选付 5 分钟线的请求成本
            var intradayJSON: [String: Any]?
            var intradayAttempted = false
            if icEnabled {
                intradayAttempted = true
                let m5 = DataSources.fetch5minBars(code)
                if let ic = IntradayFeaturesCalc.compute(m5, today: today, quote: q,
                                                         minBars: icMinBars,
                                                         tailWindowMin: icTailWindowMin) {
                    intradayJSON = ic.json
                } else {
                    // 抛异常与返回 nil 最终都是 deep["intraday"] = None，这里只留痕、不区分。
                    DataSources.logDataSource("sina", "5min_insufficient", code)
                    intradayJSON = nil
                }
                // 限速由 fetch5minBars 内部承担
            }

            let formScore = formPass[code]?.score ?? 0
            // K 线形态组合：用**上面这份已经 append 过当日 bar 的 `kline`** 现算，
            // 不额外发请求（65 根 × 12 个判据，代价可忽略）。
            // ⚠ 默认关闭时 `scoreStock` 里那一段不执行 → 与旧行为一致。
            // ⚠ `dropUnformedTail` 兜住"当日 bar 尚未形成"（`appendTodayBar` 在极端
            //   行情缺失时可能给出全 0 的一根）—— 不剔的话形态会落在那条假 K 线上且不报错。
            let patternResult = KLinePatterns.detect(
                KLinePatterns.dropUnformedTail(kline),
                config: KLinePatterns.config(from: params))
            var meta: [String: Any] = [:]
            let (score, sd, pd) = Screener.scoreStock(quote: q, deep: deep, intraday: intradayJSON,
                                                      patterns: patternResult,
                                                      formScore: formScore, marketEnv: marketEnv,
                                                      params: params, meta: &meta)
            var deepJSON = deep.json
            if intradayAttempted { deepJSON["intraday"] = intradayJSON ?? NSNull() }
            // 趋势状态 / 锁档信心落在 `deep_info` 里，**不给 picks 加列** ——
            //   加列要走 DB 迁移 + schema 导出同步；deep_info 是 JSON 列，
            //   写进去即随轮次落库。
            deepJSON["trend_state"] = meta["trend_state"] ?? "INSUFFICIENT"
            deepJSON["lock_confidence"] = meta["lock_confidence"] ?? "none"
            // K 线数据质量（跨度 / 缺口诊断）。同样**只加信息、不改判定**，
            //   判据直接用上面这份 `kline`（已 append 当日 bar），不额外发请求。
            //   暴露的是"根数够、但日期跨度异常"（长期停牌）这一类静默失真 ——
            //   引擎原有的两道防线（<10 根直接跳过、不足 6 根 cum_5d 给 null）都覆盖不到。
            deepJSON["data_quality"] = DataQuality.evaluate(kline).json
            let pick: [String: Any] = [
                "score_raw": meta["score_raw"] ?? score,
                "ma_qualified": meta["ma_qualified"] ?? true,
                "tier_lock_applied": meta["tier_lock_applied"] ?? false,
                "code": code, "name": q.name, "price": q.price,
                "change_pct": q.changePct, "volume_ratio": q.volumeRatio,
                "turnover": q.turnover, "amplitude": q.amplitude,
                "amount": q.amount, "avg_price": q.avgPrice,
                "score": score, "deep_info": deepJSON,
                "score_details": sd, "penalty_details": pd,
                "market_weak": !(Self.bool(marketEnv["sh_ok"], true)),
            ]
            scored.append(pick)
        }

        // ⚠ 必须**稳定排序**（Swift `sorted` 不稳定，用原始下标兜底）—— 否则同分票的先后会随机换序。
        // ⚠ 分数用 `num` 而不是 `int`：参数版本里的 `scoring.bonus.vol_mult_*[1]` 可能是小数
        //   （调优候选会产出），score 可能是 float（见 `Screener.ScoreAcc`）——
        //   截断成 Int 会让排序与档位切分口径不一致
        let orderedScored = scored.enumerated().sorted { a, b in
            let sa = Self.num(a.element["score"]) ?? 0, sb = Self.num(b.element["score"]) ?? 0
            if sa != sb { return sa > sb }
            return a.offset < b.offset
        }.map { $0.element }

        let tier1Min = Self.num(tiersCfg["tier1_min"]) ?? 0
        let tier2Min = Self.num(tiersCfg["tier2_min"]) ?? 0
        let scores = orderedScored.map { Self.num($0["score"]) ?? 0 }
        let tier1 = zip(orderedScored, scores).filter { $0.1 >= tier1Min }.map { $0.0 }
        let tier2 = zip(orderedScored, scores).filter {
            $0.1 >= tier2Min && $0.1 < tier1Min
        }.map { $0.0 }
        let tier3 = zip(orderedScored, scores).filter { $0.1 < tier2Min }.map { $0.0 }

        result["tier1"] = tier1
        result["tier2"] = tier2
        result["tier3"] = tier3
        result["excluded_deep_trend"] = excluded
        stats["excluded_count"] = excluded.count
        stats["final_count"] = orderedScored.count
        stats["tier1_count"] = tier1.count
        stats["tier2_count"] = tier2.count
        stats["deep_processed"] = deepProcessed
        stats["deep_skipped_budget"] = deepSkipped.count
        result["stats"] = stats
        // 耗时预算触发时留下明确痕迹：这一轮是"截断过的"，不能当成完整轮次看
        result["budget_limited"] = !deepSkipped.isEmpty
        // 被跳过的**具体代码**也要落库：只记一个 bool，信号分类就无法判断"某只票这轮缺席
        // 是因为没入选，还是压根没被评分" —— 二者对"三轮持续"的结论完全相反。
        result["budget_skipped_codes"] = deepSkipped
        if !deepSkipped.isEmpty {
            let detail = "耗时预算触发：深挖 \(deepProcessed) 只后停止"
                + "（上限 \(String(format: "%.0f", budgetSec))s / \(maxDeep > 0 ? String(maxDeep) : "不限")只），"
                + "跳过 \(deepSkipped.count) 只未评分"
            result["budget_note"] = detail
            DataSources.logDataSource("engine", "deep_budget_hit", detail)
        }

        // ---- ETF 筛选 ----
        let etfCfg = Self.dict(params["etf"])
        let etfCodes = (etfCfg["codes"] as? [String]) ?? []
        let etfQuotes = DataSources.fetchTencentQuotes(etfCodes)
        // 按 etf.codes 的**请求序**构造（`screenEtf` 的稳定排序并列时依赖它）
        let etfPairs: [(code: String, quote: EngineQuote)] = etfCodes.compactMap { c in
            guard let raw = etfQuotes[c] else { return nil }
            return (c, EngineQuote(json: raw))
        }
        result["etf_recommendations"] = Screener.screenEtf(params: params, quotes: etfPairs)

        result["elapsed_sec"] = PyMath.round(Date().timeIntervalSince1970 - tStart, 1)
        result["status"] = "ok"

        if persist {
            do {
                result["round_id"] = try ScanStore.shared.persistRound(result)
            } catch {
                // 落库失败必须让调用方看见（不得静默当成"落过了"）——状态改为 error 并带上原因
                result["status"] = "persist_failed"
                result["persist_error"] = String(describing: error)
                DataSources.logDataSource("engine", "persist_failed", String(describing: error))
            }
        }
        return result
    }

    /// 原生轮次的**统一入口**（手动扫描 / 调度器 / 补跑共用）。
    ///
    /// 与 `runScan` 的区别只有两点：
    ///   · 轮次边界解析后**显式传给** `runScan`（调用方显式给了 slot 时不影响结果）
    ///   · 固定 `persist=true`
    ///
    /// ⚠ **同步阻塞**（网络 + 落库，整轮数十秒），调用方必须放到后台线程；
    ///   参数由调用方解析（`ParamStore.activeParams()` / `activeName()`），
    ///   本文件不读库取参数。
    public static func runRound(params: [String: Any], paramVersion: String,
                         slot: Int?, boundaries: String,
                         shouldStop: () -> Bool = { false }) -> [String: Any] {
        // ⚠ **不用 `setenv`**：边界**显式传下去**。环境变量当参数通道的话——
        //   后台线程写、从不清理，并发路径（历史回放 + 实时扫描）会**读到对方的边界**。
        //   解析走纯函数 `Screener.parseBounds`（可单测；格式不对 → nil → 回落默认）。
        return runScan(params: params, paramVersion: paramVersion, slot: slot, persist: true,
                       boundaries: Screener.parseBounds(boundaries), shouldStop: shouldStop)
    }

    // MARK: - 取值工具（动态类型 → Swift 显式转换）
    public static func dict(_ v: Any?) -> [String: Any] { (v as? [String: Any]) ?? [:] }
    public static func str(_ v: Any?, _ def: String = "") -> String { (v as? String) ?? def }

    /// 实现委托 `Num.doubleOrNilKeepingNonFinite`（遗留口径，**保留** `inf` / `nan`；语义勿改）
    public static func num(_ v: Any?) -> Double? { Num.doubleOrNilKeepingNonFinite(v) }

    public static func int(_ v: Any?) -> Int? {
        guard let v else { return nil }
        if let n = v as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? 1 : 0 }
            return n.intValue
        }
        if let s = v as? String { return Int(s) }
        return nil
    }

    public static func bool(_ v: Any?, _ def: Bool) -> Bool {
        guard let v else { return def }
        if let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
        if let b = v as? Bool { return b }
        return def
    }

    /// ST 正则：编译失败**不退化为中断整轮**，而是"永不匹配"并留痕 ——
    /// 宁可少一层排除，也不要因为参数写错让整轮扫描崩掉（用户会看到"今天没选股"却不知为何）。
    public static func regex(_ pattern: String) -> NSRegularExpression {
        if let re = try? NSRegularExpression(pattern: pattern) { return re }
        DataSources.logDataSource("params", "invalid_st_pattern", "\(pattern) 非法，本轮按不排除处理")
        return (try? NSRegularExpression(pattern: "(?!)")) ?? NSRegularExpression()
    }

    /// 写库时间戳 `yyyy-MM-dd HH:mm:ss`（委托 `ChinaTime.stamp()`，同格式同语义）
    public static func nowStamp() -> String {
        ChinaTime.stamp()
    }
}