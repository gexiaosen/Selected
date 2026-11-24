import Foundation

/// 阶段一 · 早盘预判。
///
/// 红黄绿灯分级 + 逐标的卖出策略（五分支矩阵）＋总体策略文本。
/// 空仓日也生成快照（`is_empty_day`），保证数据链不断裂。
///
/// ⚠ **同步阻塞**（行情 + 外盘 + 落库），调用方必须放后台线程。
public enum PhasePredict {

    /// 看多关键词（`verify` 判「预判方向命中」时也用它）
    public static let bullishKeywords = ["强", "冲高", "反弹", "修复"]

    /// 最近一个有选股数据的交易日（排除今天）
    public static func findLastSelDate(todayStr: String? = nil) -> String? {
        let today = todayStr ?? DataSources.runDate()
        return CompareStore.shared.latestSelDate(before: today)
    }

    /// - Parameter targetDate: 指定选股日（默认最近一个）
    /// - Returns: 结果字典
    public static func predict(targetDate: String? = nil, persist: Bool = true,
                        params: [String: Any]) throws -> [String: Any] {
        // 当日口径走 `DataSources.runDate()`（非墙上时钟）：
        // 回放时 predicts.date（主键）不随运行日期漂移
        let todayStr = DataSources.runDate()
        let rules = (params["predict_rules"] as? [String: Any]) ?? [:]

        let selDate = targetDate ?? findLastSelDate(todayStr: todayStr)
        var result: [String: Any] = [
            "predict_date": todayStr,
            "predict_time": PhaseStore.nowHM(),
            "sel_date": selDate ?? NSNull(),
            "market_env": [String: Any](), "stocks": [Any](), "is_empty_day": true,
        ]
        guard let selDate = selDate else {
            result["status"] = "no_sel_data"
            return result
        }

        let rounds = CompareStore.shared.loadRounds(date: selDate)
        let slots = rounds.keys.sorted()
        guard !rounds.isEmpty else {
            result["status"] = "no_sel_data"
            return result
        }

        // 收集标的与信号分类
        let (order, signals) = SignalClassifier.classifySignals(rounds)
        let codes = order

        // 当日大盘 + 外盘
        let idx = DataSources.fetchIndexQuote()
        let shOpen = PredictRules.num(idx["open"]) ?? 0
        let shPre = PredictRules.num(idx["pre_close"]) ?? 0
        var marketData: [String: Any] = [:]
        // sh_pre <= 0 时保持 int 0（不是 0.0），落库形态不变
        var openPct: Any = 0
        if shPre > 0 { openPct = PyMath.round((shOpen - shPre) / shPre * 100, 2) }
        marketData["sh_open_pct"] = openPct
        marketData["sh_change_pct"] = idx["change_pct"] ?? 0
        let overseas = DataSources.fetchOverseas()
        var usParts: [String] = []
        if let v = PredictRules.num(overseas["dji_change_pct"]) {
            usParts.append(String(format: "道琼斯%+.1f%%", v))
        }
        if let v = PredictRules.num(overseas["ixic_change_pct"]) {
            usParts.append(String(format: "纳指%+.1f%%", v))
        }
        marketData["us_market"] = usParts.isEmpty ? "数据获取失败" : usParts.joined(separator: " ")

        var lastEnv = CompareStore.shared.marketEnv(date: selDate)
        // 3日趋势按 predict 时刻现算（旧值滞后 1~2 个交易日）
        let trend = PredictRules.fresh3dTrend(todayChangePct: PredictRules.num(marketData["sh_change_pct"]) ?? 0)
        lastEnv["sh_3d_trend"] = trend.sh3dTrend
        lastEnv["sh_consecutive_decline"] = trend.shConsecutiveDecline
        lastEnv["sh_3d_decline_count"] = trend.sh3dDeclineCount
        lastEnv["sh_d1"] = trend.shD1 ?? NSNull()
        lastEnv["sh_d2"] = trend.shD2 ?? NSNull()

        var marketClass = PredictRules.classifyMarketLight(marketData: marketData,
                                                           lastEnv: lastEnv, rules: rules)
        // 市场状态机：**纯附加** —— 只多写 `regime` / `ma_period_used` 两个键，
        // `classifyMarketLight` 一字未动（`light` 判定不变）。
        // `today` 与上面 `fresh3dTrend` 用的是同一个当日 —— 否则两侧剔掉的
        // 「当日未完成 bar」不同 → 状态机与连跌结论打架。
        // `HistoryReplayMode.currentDay`：正常模式是墙上时钟，回放模式取回放日。
        let regime = PredictRules.freshRegime(trend, today: HistoryReplayMode.currentDay, rules: rules)
        for (k, v) in regime.json { marketClass[k] = v }
        result["market_env"] = marketClass
        result["is_empty_day"] = codes.isEmpty

        // 个股行情
        let quotes = codes.isEmpty ? [:] : DataSources.fetchTencentQuotes(codes)
        let strategies = (rules["strategies"] as? [String: Any]) ?? [:]

        var stocks: [[String: Any]] = []
        for code in codes.sorted() {
            let meta = signals[code] ?? [:]
            let q = quotes[code] ?? [:]
            // ⚠ 取**最早一轮**的价格（按 slot 升序首个命中即保留）。
            //   `PhaseVerify` 侧的同类逻辑取**最晚一轮**（对齐 review/tuner 的尾盘买入口径）——
            //   两处**有意不同**，改这里会让 predict 与 review 的口径对不上。
            var selPrice: Double = 0
            for s in slots {
                let round = rounds[s] ?? [:]
                for p in ((round["tier1"] as? [[String: Any]]) ?? [])
                    + ((round["tier2"] as? [[String: Any]]) ?? []) {
                    if (p["code"] as? String) == code, selPrice == 0 {
                        selPrice = PredictRules.num(p["price"]) ?? 0
                    }
                }
            }
            let openP = PredictRules.num(q["open"]) ?? 0
            let pre = PredictRules.num(q["pre_close"]) ?? 0
            let signalType = (meta["signal_type"] as? String) ?? ""
            let strategy = PredictRules.buildStrategy(
                marketClass: marketClass, signalType: SignalType(rawValue: signalType),
                selPrice: selPrice, strategies: strategies,
                regimeThresholds: PredictRules.regimeThresholds(from: params))
            var scores: [String: Any] = [:]
            // ⚠ 分类结果里 `scores` 是 `[Int: Double]`（按 slot 号索引，内部形态）；
            //   落库/返回时转成字符串键
            let metaScores = (meta["scores"] as? [Int: Double]) ?? [:]
            for s in slots { scores[String(s)] = metaScores[s] ?? NSNull() }

            var row: [String: Any] = [
                "code": code,
                "name": (meta["name"] as? String) ?? (q["name"] as? String) ?? code,
                "signal_type": signalType,
                "signal_type_name": (meta["signal_type_name"] as? String) ?? "",
                "signal_verified": PredictRules.bool(meta["signal_verified"]) ?? true,
                "sel_price": selPrice,
                "current_price": q["price"] ?? 0,
                "current_pct": q["change_pct"] ?? 0,
                "volume_ratio": q["volume_ratio"] ?? 0,
                "turnover": q["turnover"] ?? 0,
                "scores": scores,
            ]
            // pre <= 0 时保持 int 0（不是 0.0），落库形态不变
            row["open_pct"] = pre > 0 ? PyMath.round((openP - pre) / pre * 100, 2) : 0 as Any
            for (k, v) in strategy { row[k] = v }
            stocks.append(row)
        }

        // 信号强度优先排序（最强 → 持续 → 脉冲 → 未验证），同档按最高分明细。
        // 强度序唯一来源 = `SignalType.rank`（2026-11-09 审查 #6：自实现曾把未验证排在脉冲前，
        // 与文档§四相悖 —— 未验证是"没结论"，不是弱信号）；nil（缺失/未识别）落 9 排最后。
        // ⚠ 稳定排序（Swift `sorted` 不稳定，同键会乱序 —— 用 enumerated 的 offset 兜底）
        stocks = stocks.enumerated().sorted { a, b in
            let ra = SignalType(json: a.element["signal_type"])?.rank ?? 9
            let rb = SignalType(json: b.element["signal_type"])?.rank ?? 9
            if ra != rb { return ra < rb }
            let ma = Self.maxScore(a.element), mb = Self.maxScore(b.element)
            if ma != mb { return ma > mb }
            return a.offset < b.offset
        }.map { $0.element }

        result["stocks"] = stocks
        // 持续性是否经过验证（轮次不足时为 False）
        result["persistence_verified"] = {
            guard let first = order.first, let m = signals[first] else { return false }
            return PredictRules.bool(m["signal_verified"]) ?? true
        }()
        result["overall"] = overallStrategy(marketClass, stocks)
        result["status"] = "ok"

        if persist {
            try PhaseStore.shared.persistPredict(
                date: todayStr, selDate: selDate,
                predictTime: (result["predict_time"] as? String) ?? "",
                marketEnv: marketClass, stocks: stocks,
                isEmptyDay: codes.isEmpty,
                overall: (result["overall"] as? [Any]) ?? [])
        }
        return result
    }

    /// scores 的最大值（忽略 None）；全为 None → 0
    private static func maxScore(_ row: [String: Any]) -> Double {
        let scores = (row["scores"] as? [String: Any]) ?? [:]
        let vals = scores.values.compactMap { PredictRules.num($0) }
        return vals.max() ?? 0
    }

    /// 总体策略文本
    public static func overallStrategy(_ mc: [String: Any], _ stocks: [[String: Any]]) -> [String] {
        var lines: [String] = []
        // 分支一律走枚举：`nil`（缺失/未识别）既不是红也不是黄
        let lightLevel = MarketLightLevel(json: mc["light"])
        if lightLevel == .red {
            lines.append("红灯：大盘连跌≥2日，建议空仓观望，不进场。")
            return lines
        }
        let cons = stocks.filter {
            SignalType(json: $0["signal_type"])?.isVerified == true
        }.count
        let unver = stocks.filter {
            SignalType(json: $0["signal_type"]) == .unverified
        }.count
        let pulse = stocks.filter {
            SignalType(json: $0["signal_type"]) == .pulse
        }.count
        if unver > 0 {
            // 轮次不足时不得把"未经确认"说成"持续信号"
            lines.append("⚠ 轮次不足，持续性未经确认：\(unver) 只标的标记为「未验证」，"
                         + "\(pulse) 只为脉冲信号 —— 全部按脉冲处理（短窗口、见好就收）")
        } else {
            lines.append("持续信号：\(cons)只（优先操作）；脉冲信号：\(pulse)只（谨慎操作）")
        }
        if lightLevel == .yellow {
            lines.append("大盘偏弱，总仓位建议≤40%，脉冲信号仅轻仓")
        } else {
            lines.append("大盘正常，总仓位建议≤60%，单票≤15%")
        }
        if let first = stocks.first {
            lines.append("卖出窗口：持续信号 \(first["sell_window_start"] ?? "")~"
                         + "\(first["sell_window_end"] ?? "")，脉冲信号见好就收")
        }
        lines.append("下午策略：不宜持有过夜，清仓为主")
        return lines
    }
}