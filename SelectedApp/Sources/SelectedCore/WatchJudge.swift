import Foundation

/// 自选股每日判定。
///
/// 三层判定模型（与引擎口径完全一致）：
///   第一层 · 市场层：大盘红灯（连跌≥2日）→ 全部自选 = 空仓观望，不给买入点
///   第二层 · 个股层：复用扫描打分体系（`Screener.scoreStock`）——
///                   买入/观察/回避 三条线**读生效参数的档位门槛**（`scoring.tiers`）
///   第三层 · 持仓层：持仓中（基准 = 信号日收盘价）——
///                   触及目标价→止盈 / 跌破止损价→止损 / 打分跌破二档门槛→动能衰竭清仓
///
/// 买入信号走五分支矩阵的 pulse 分支（单日打分未经三轮验证，保守口径）。
///
/// ⚠ **同步阻塞**（行情 + 日K + 落库），调用方必须放后台线程。
public enum WatchJudge {

    /// 持仓状态机的终结动作
    public static let terminalActions: Set<String> = ["止盈卖出", "止损卖出", "清仓卖出", "空仓观望"]

    /// 打分阈值兜底值（生效参数缺 `scoring.tiers` 时才用）
    public static let defaultBuyScore: Double = 70
    public static let defaultWatchScore: Double = 50

    /// (买入线, 观察线, 衰减线)。
    ///
    /// 与扫描器档位**同源**（读生效参数）：硬编码阈值与生效参数脱钩会出现
    /// 「扫描器判二档观察、自选页判买入信号」的自相矛盾。
    /// 衰减线 = 二档门槛（跌破即动能衰竭）。
    ///
    /// 三条线按大盘状态**整体浮动** `score_adj` 分（多头回调/修复放松、空头收紧；
    /// `UNKNOWN` → 0 = 不浮动）。
    public static func scoreThresholds(_ params: [String: Any], regime: String = "")
        -> (buy: Double, watch: Double, decay: Double) {
        let tiers = ((params["scoring"] as? [String: Any])?["tiers"] as? [String: Any]) ?? [:]
        let buy: Double, watch: Double
        if let w = PredictRules.num(tiers["tier2_min"]),
           let b = PredictRules.num(tiers["tier1_min"]) {
            buy = b; watch = w
        } else {
            buy = defaultBuyScore; watch = defaultWatchScore
        }
        let adj = PredictRules.regimeAdjustment(
            regime: regime, thresholds: PredictRules.regimeThresholds(from: params))
        return (buy + adj.scoreAdj, watch + adj.scoreAdj, watch + adj.scoreAdj)
    }

    // MARK: - 市场层

    /// 最近一轮扫描环境优先（含涨跌比 ratio_ok），无则仅指数口径。
    /// 返回 (env, marketClass)
    public static func marketEnvForWatch(params: [String: Any])
        -> (env: [String: Any], marketClass: [String: Any]) {
        let rules = (params["predict_rules"] as? [String: Any]) ?? [:]
        let idx = DataSources.fetchIndexQuote()
        let shPre = PredictRules.num(idx["pre_close"]) ?? 0
        let shOpen = PredictRules.num(idx["open"]) ?? 0
        let shChange = PredictRules.num(idx["change_pct"]) ?? 0
        // sh_pre <= 0 时保持 int 0（不是 0.0），落库形态不变
        var openPct: Any = 0
        if shPre > 0 { openPct = PyMath.round((shOpen - shPre) / shPre * 100, 2) }
        let marketData: [String: Any] = [
            "sh_open_pct": openPct,
            "sh_change_pct": idx["change_pct"] ?? 0,
        ]

        // 涨跌比等环境量：复用最近一轮扫描的快照（watch-judge 排在第3轮后）
        var lastEnv = WatchStore.shared.latestMarketEnv()
        if lastEnv.isEmpty {
            // 无任何扫描记录（如清晨手动跑）：仅指数口径，ratio_ok 缺失 → 不加环境分
            let th = PredictRules.num((params["exclusion"] as? [String: Any])?["market_change_threshold"]) ?? 0
            lastEnv = ["sh_change_pct": marketData["sh_change_pct"] ?? 0,
                       "sh_ok": shChange > th,
                       "ratio_ok": false]
        }

        // 3日趋势现算（与 predict 同口径，不复用隔夜旧值）
        let trend = PredictRules.fresh3dTrend(todayChangePct: shChange)
        // ⚠ 只覆盖这 5 个键（trend 结构里的 streak/lookback/days_cfg 不写进来）
        lastEnv["sh_3d_trend"] = trend.sh3dTrend
        lastEnv["sh_consecutive_decline"] = trend.shConsecutiveDecline
        lastEnv["sh_3d_decline_count"] = trend.sh3dDeclineCount
        lastEnv["sh_d1"] = trend.shD1 ?? NSNull()
        lastEnv["sh_d2"] = trend.shD2 ?? NSNull()

        var marketClass = PredictRules.classifyMarketLight(marketData: marketData,
                                                           lastEnv: lastEnv, rules: rules)
        // 市场状态机（**纯附加**，与扫描/预判同一个纯函数）。
        // 自选侧用它做门槛浮动；`UNKNOWN`（历史不足）时偏移恒为 0。
        let regime = PredictRules.freshRegime(trend, today: ChinaTime.day(), rules: rules)
        for (k, v) in regime.json { marketClass[k] = v }
        return (lastEnv, marketClass)
    }

    // MARK: - 持仓层

    /// 从判定历史推导持仓状态 → `{holding: Bool, baseline/target/stop: Double}`
    ///
    /// ⚠ 「持有 + 锚点」也算持仓中：判定表按 (date, code) 覆盖写，同一天重跑会把
    ///   「买入」改成「持有」→ 只认「买入」会让建仓锚点整行消失，持仓被判成空仓。
    public static func holdingState(code: String) -> [String: Any] {
        for r in WatchStore.shared.judgmentsForState(code: code) {
            let action = (r["action"] as? String) ?? ""
            if terminalActions.contains(action) { return ["holding": false] }
            let baseline = PredictRules.num(r["baseline_price"]) ?? 0
            if action == "买入" || (action == "持有" && baseline > 0) {
                return ["holding": true,
                        "baseline": baseline,
                        "target": PredictRules.num(r["target_price"]) ?? 0,
                        "stop": PredictRules.num(r["stop_loss_price"]) ?? 0]
            }
        }
        return ["holding": false]
    }

    // MARK: - 主流程

    /// 执行每日自选判定，结果落库 `watch_judgments`。
    ///
    /// - Parameter code: 非空 = 单股判定（列表行手动触发）：只拉该股行情与K线
    /// - Parameter params: 生效参数（调用方从 `ParamStore.activeParams()` 取）
    /// - Parameter shouldStop: 取消检查闭包（审查 #12）。本函数**逐只拉日K**、
    ///   整轮分钟级，`Scheduler.stop()` 置位取消盒后必须真的停下来：每只开始前读一次，
    ///   命中即返回 `status=cancelled`（已落库的逐只判定是 (date, code) 覆盖写，
    ///   半轮残留下次重跑会盖掉，不构成脏数据）。
    /// - Returns: 结果字典（status/date/judged/market_light/buys/sells/results…）
    public static func judge(code: String? = nil, params: [String: Any],
                             shouldStop: () -> Bool = { false }) throws -> [String: Any] {
        let onlyCode = (code?.isEmpty == false) ? code : nil
        let items = WatchStore.shared.watchItems().filter {
            onlyCode == nil || ($0["code"] as? String) == onlyCode
        }
        let today = ChinaTime.day()
        let now = WatchStore.timestamp()

        if items.isEmpty {
            return ["status": "ok", "date": today, "judged": 0, "market_light": "",
                    "summary": onlyCode == nil ? "自选列表为空" : "\(onlyCode!) 不在自选中"]
        }

        // 交易日闸门（审查 #17）：「节假日 + 判不出交易日」时 `Scheduler` 的缓存退回
        // "非周末即开盘" ⇒ 这一轮会被照常派发。原先本函数**没有任何闸门**，于是休市日
        // 把上一交易日的收盘价逐只写进 `watch_judgments`、还广播"自选判定完成"。
        // 与 `BoardHeatJob` 同一纪律（写型任务）：`.closed` / `.unknown` 都**不落库** ——
        // 判不出就宁可跳过，见 `TradingDayVerdict` 注释。
        // ⚠ 手动单股判定（`code != nil`，用户在界面上点的那一下）**不受闸门**：
        //   用户主动要结果，行情取不到时自然落"数据缺失"行。
        if onlyCode == nil {
            switch DataSources.tradingDayVerdict() {
            case .trading:
                break
            case .closed(let reason):
                return ["status": "not_trading_day", "trading_day_reason": reason, "date": today]
            case .unknown(let reason):
                return ["status": "not_trading_day",
                        "trading_day_reason": "无从确认（\(reason)）→ 今日不判定",
                        "date": today]
            }
        }

        let (marketEnv, marketClass) = marketEnvForWatch(params: params)
        // 门槛按大盘状态浮动 —— 先拿 marketClass（含 regime）再算三条线
        let (buyScore, watchScore, decayScore) = scoreThresholds(
            params, regime: (marketClass["regime"] as? String) ?? "")
        let marketLight = (marketClass["light"] as? String) ?? ""
        let red = MarketLightLevel(json: marketClass["light"]) == .red

        let codes = items.compactMap { $0["code"] as? String }
        let quotes = DataSources.fetchTencentQuotes(codes, shouldStop: shouldStop)

        let deepFilter = (params["deep_filter"] as? [String: Any]) ?? [:]
        let volAvgDays = PredictRules.int(deepFilter["vol_avg_days"]) ?? 5
        let volMultNormalize = PredictRules.bool(deepFilter["vol_mult_normalize"]) ?? true
        let ma20SlopeLookback = PredictRules.int(deepFilter["ma20_slope_lookback"]) ?? 5
        let formFilter = (params["form_filter"] as? [String: Any]) ?? [:]
        let strategies = ((params["predict_rules"] as? [String: Any])?["strategies"]
                          as? [String: Any]) ?? [:]

        var results: [[String: Any]] = []

        for it in items {
            // 取消检查（审查 #12）：逐只日K是分钟级大头，每只开始前读一次
            if shouldStop() {
                return ["status": "cancelled", "date": today, "judged": results.count,
                        "summary": "判定中途取消（已落 \(results.count) 只）"]
            }
            let codeValue = (it["code"] as? String) ?? ""
            let nameValue = (it["name"] as? String) ?? ""
            let name = nameValue.isEmpty ? codeValue : nameValue
            var entry: [String: Any] = [
                "code": codeValue, "name": name,
                "action": "回避", "score": NSNull(),
                "score_details": [Any](), "penalty_details": [Any](),
                "target_price": NSNull(), "stop_loss_price": NSNull(),
                "baseline_price": NSNull(), "sell_window": NSNull(),
                "position_advice": NSNull(), "risk_level": NSNull(),
                "market_light": marketLight,
            ]

            guard let q = quotes[codeValue], (PredictRules.num(q["price"]) ?? 0) != 0 else {
                entry["action"] = "数据缺失"
                entry["score_details"] = ["行情获取失败"]
                results.append(entry)
                continue
            }
            let quote = EngineQuote(json: q)

            // 个股打分（复用扫描体系：日K + 今日bar → 深度指标 → 打分）
            //
            // ⚠ 日K取数失败（返回空）**不算数据错误**：取数内部已兜住网络异常返回 [] →
            //   落到「回避」。本实现没有"取数抛错"路径（`Screener.scoreStock` 取值全部兜底），
            //   所以不存在 `data_error` 分支。
            // score 是 int/float 两态（见 `Screener.ScoreAcc`）：整数参数下恒为 int，
            // 只有 pair 加分被写成小数时才变 float —— 保持原样传给落库与结果 JSON
            var score: Any? = nil
            var kline = DataSources.fetchDailyKline(codeValue, datalen: 65)
            kline = EngineIndicators.appendTodayBar(kline, quote, today: today)
            let deep = EngineIndicators.computeDeepInfo(
                kline, quote, volAvgDays: volAvgDays,
                volMultNormalize: volMultNormalize,
                ma20SlopeLookback: ma20SlopeLookback)
            if let deep = deep {
                let formScore = EngineIndicators.formCheck(
                    quote.open, quote.price, quote.high, quote.low,
                    upperShadowRatio: PredictRules.num(formFilter["upper_shadow_ratio"]) ?? 0,
                    closeHighRatio: PredictRules.num(formFilter["close_high_ratio"]) ?? 0,
                    bodyRatioMin: PredictRules.num(formFilter["body_ratio_min"]) ?? 0).0
                var meta: [String: Any] = [:]
                // ⚠ **不传 intraday**：自选判定不拉 5 分钟线 → 无尾盘分时加分
                let (sc, sd, pd) = Screener.scoreStock(
                    quote: quote, deep: deep, intraday: nil, formScore: formScore,
                    marketEnv: marketEnv, params: params, meta: &meta)
                score = sc
                entry["score"] = sc
                entry["score_details"] = sd
                entry["penalty_details"] = pd
            }

            let pos = holdingState(code: codeValue)
            let price = quote.price

            if red {
                // 第一层：大盘红灯 → 一票否决，全部空仓观望
                entry["action"] = "空仓观望"
                entry["score_details"] = ["大盘连跌≥2日，红灯：空仓观望，不操作"]
                    + ((entry["score_details"] as? [Any]) ?? [])
            } else if (PredictRules.bool(pos["holding"]) ?? false) {
                // 第三层：持仓判定（止盈/止损/动能衰竭/持有）
                let target = PredictRules.num(pos["target"]) ?? 0
                let stop = PredictRules.num(pos["stop"]) ?? 0
                entry["baseline_price"] = pos["baseline"] ?? NSNull()
                entry["target_price"] = target
                entry["stop_loss_price"] = stop
                if target != 0 && price >= target {
                    entry["action"] = "止盈卖出"
                } else if stop != 0 && price <= stop {
                    entry["action"] = "止损卖出"
                } else if let sc = score, let scN = PredictRules.num(sc), scN < decayScore {
                    entry["action"] = "清仓卖出"
                    entry["score_details"] = ["打分跌破\(Self.scoreText(decayScore))：动能衰竭，建议清仓"]
                        + ((entry["score_details"] as? [Any]) ?? [])
                } else {
                    entry["action"] = "持有"
                }
            } else {
                // 第二层：买入判定（阈值 = 生效参数的一档/二档门槛）
                if let sc = score, let scN = PredictRules.num(sc), scN >= buyScore {
                    entry["action"] = "买入"
                    // 单日打分未经验证 → pulse 分支（保守：半仓、更短窗口）
                    let st = PredictRules.buildStrategy(
                        marketClass: marketClass, signalType: .pulse,
                        selPrice: price, strategies: strategies,
                        regimeThresholds: PredictRules.regimeThresholds(from: params))
                    entry["target_price"] = st["target_price"] ?? NSNull()
                    entry["stop_loss_price"] = st["stop_loss_price"] ?? NSNull()
                    entry["baseline_price"] = price
                    entry["sell_window"] = "\(st["sell_window_start"] ?? "")~\(st["sell_window_end"] ?? "")"
                    entry["position_advice"] = st["position_advice"] ?? NSNull()
                    entry["risk_level"] = st["risk_level"] ?? NSNull()
                } else if let sc = score, let scN = PredictRules.num(sc), scN >= watchScore {
                    entry["action"] = "观察"
                } else {
                    entry["action"] = "回避"
                }
            }

            entry["price"] = price
            entry["change_pct"] = q["change_pct"] ?? 0
            // ⚠ `is_holding` 来自 SQLite 的 INTEGER 列（1/0），不是 JSON 布尔 ——
            //   严格布尔判定会把它读成 false，必须走 `truthy`
            entry["is_holding"] = PredictRules.truthy(it["is_holding"])
            entry["cost_price"] = it["cost_price"] ?? NSNull()
            entry["shares"] = it["shares"] ?? NSNull()

            // 覆盖写前保留既有锚点：判定表是 (date, code) 唯一，同一天重跑时若本次
            // 没算出锚点（典型：动作由「买入」变为「持有」），旧行的锚点会被整行覆盖掉，
            // 之后 `holdingState` 就再也找不到建仓点。
            //
            // ⚠ **必须在 `results.append` 之前算完**：Swift 的 `[String: Any]` 是**值类型**，
            //   append 时已复制 —— append 之后再改 `entry`，返回结果里的锚点会丢失
            //   （库里写得对，但界面判定卡上目标价/止损价为空白）。
            var baseline = PredictRules.num(entry["baseline_price"])
            var target = PredictRules.num(entry["target_price"])
            var stop = PredictRules.num(entry["stop_loss_price"])
            var sellWindow = entry["sell_window"] as? String
            var positionAdvice = entry["position_advice"] as? String
            var riskLevel = entry["risk_level"] as? String
            // 判据：None 与 0 都算"没有锚点"
            let hasBaseline = (baseline ?? 0) > 0
            if let prev = WatchStore.shared.previousJudgment(date: today, code: codeValue),
               (PredictRules.num(prev["baseline_price"]) ?? 0) > 0, !hasBaseline {
                baseline = PredictRules.num(prev["baseline_price"])
                target = target ?? PredictRules.num(prev["target_price"])
                stop = stop ?? PredictRules.num(prev["stop_loss_price"])
                sellWindow = sellWindow ?? (prev["sell_window"] as? String)
                positionAdvice = positionAdvice ?? (prev["position_advice"] as? String)
                riskLevel = riskLevel ?? (prev["risk_level"] as? String)
                entry["baseline_price"] = baseline ?? NSNull()
                entry["target_price"] = target ?? NSNull()
                entry["stop_loss_price"] = stop ?? NSNull()
                entry["sell_window"] = sellWindow ?? NSNull()
                entry["position_advice"] = positionAdvice ?? NSNull()
                entry["risk_level"] = riskLevel ?? NSNull()
            }
            results.append(entry)

            let details = PyJSON.encode([
                "score_details": entry["score_details"] ?? [Any](),
                "penalty_details": entry["penalty_details"] ?? [Any](),
            ])
            try WatchStore.shared.upsertJudgment(
                date: today, code: codeValue, name: name,
                action: (entry["action"] as? String) ?? "回避",
                score: score,
                detailsJSON: details,
                targetPrice: target, stopLossPrice: stop, baselinePrice: baseline,
                sellWindow: sellWindow, positionAdvice: positionAdvice, riskLevel: riskLevel,
                marketLight: marketLight, createdAt: now)
        }

        func label(_ r: [String: Any]) -> String {
            let n = (r["name"] as? String) ?? ""
            return n.isEmpty ? ((r["code"] as? String) ?? "") : n
        }
        let buys = results.filter { ($0["action"] as? String) == "买入" }.map(label)
        let sells = results.filter {
            ["止盈卖出", "止损卖出", "清仓卖出"].contains(($0["action"] as? String) ?? "")
        }.map { [($0["action"] as? String) ?? "", label($0)] as [Any] }
        let summary = "买入 \(buys.count) · 卖出 \(sells.count) · 大盘\(marketLight)"

        return [
            "status": "ok", "date": today, "judged": results.count,
            "market_light": marketLight,
            "market_trend": marketClass["sh_3d_trend"] ?? "",
            "buys": buys, "sells": sells, "summary": summary,
            "results": results,
        ]
    }

    /// `f"{decay_score:.0f}"` 的等价（Python 里是 0 位小数的定点格式）
    private static func scoreText(_ v: Double) -> String {
        String(format: "%.0f", v)
    }
}
