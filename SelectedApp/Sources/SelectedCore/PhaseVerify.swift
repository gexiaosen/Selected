import Foundation

/// 阶段二 · 盘中验证。
///
/// 快照胜率追踪 + 预判交叉对比 + 风险警告。空仓日仍记录大盘环境。
///
/// ⚠ **同步阻塞**（行情 + 落库），调用方必须放后台线程。
public enum PhaseVerify {

    /// 胜率累计器（每组 win / loss / winPnl / lossPnl）。
    ///
    /// ⚠ 用结构体而非嵌套字典：靠"初始化恰好列全所有键"保证强解包不崩太脆弱 ——
    /// 加一组、改一个键名，崩的是盘中/收盘定时报表路径（要等下一次触发才暴露）。
    /// 字段化后"缺键"这个状态直接不存在。
    private struct WinLoss {
        var win = 0.0, loss = 0.0, winPnl = 0.0, lossPnl = 0.0
    }

    /// 分组键 —— rawValue 就是**落库用的组名**（`total` / `consensus` / `pulse`），改不得。
    /// Swift 内部只认枚举，出口统一转回 rawValue（见 `result["stats"]`）。
    private enum WinGroup: String, CaseIterable {
        case total, consensus, pulse
    }

    public static func verify(persist: Bool = true, todayStr: String? = nil,
                       params _: [String: Any]) throws -> [String: Any] {
        let runDay = DataSources.runDate()
        let day = todayStr ?? runDay
        let isLiveDay = (day == runDay)
        // **为什么历史日不允许落库**：本函数取的是**实时行情**，它只能反映"此刻"。
        // 用今天的实时行情去验证某历史 T+1 的 10:00 快照是错的，而那些错数据会进
        // verifies 表供后续对比。故非本机当日时自动降级为只读。
        var doPersist = persist
        if !isLiveDay && doPersist { doPersist = false }
        let selDate = PhasePredict.findLastSelDate(todayStr: day)

        var result: [String: Any] = [
            "sel_date": selDate ?? NSNull(), "verify_date": day,
            "verify_time": PhaseStore.nowHM(),
            "data_mode": isLiveDay ? "live" : "replay_readonly",
            "persisted": doPersist,
            "groups": [String: Any](), "stats": [String: Any](),
            "deviations": [Any](), "warnings": [Any](),
        ]
        var warnings: [String] = []
        if !isLiveDay {
            warnings.append("指定日 \(day) 不是本机当日（\(runDay)）：盘中验证依赖实时行情，"
                            + "历史日无法复原 10:00 快照 → 本次只读展示、不落库")
        }
        guard let selDate = selDate else {
            result["status"] = "no_sel_data"
            result["warnings"] = warnings
            return result
        }

        let rounds = CompareStore.shared.loadRounds(date: selDate)
        guard !rounds.isEmpty else {
            result["status"] = "no_sel_data"
            result["warnings"] = warnings
            return result
        }
        let (order, signals) = SignalClassifier.classifySignals(rounds)
        let codes = order
        let slots = rounds.keys.sorted()

        // 空仓日：仅记录（带空仓标记，UI 识别后不再误读为"全 0 空卡"）
        if codes.isEmpty {
            result["status"] = "empty_day"
            result["warnings"] = warnings
            if doPersist {
                try PhaseStore.shared.persistVerify(
                    selDate: selDate, verifyTime: (result["verify_time"] as? String) ?? "",
                    stats: [:], detail: [], deviations: [], warnings: warnings, isEmptyDay: true)
            }
            return result
        }

        let quotes = DataSources.fetchTencentQuotes(codes)

        var detail: [[String: Any]] = []
        var counters: [WinGroup: WinLoss] = [:]
        // 三组**先建齐**：一组都没样本时也要报 0，而不是缺键（消费方按固定键集读）
        for g in WinGroup.allCases { counters[g] = WinLoss() }
        for code in codes.sorted() {
            let meta = signals[code] ?? [:]
            let q = quotes[code] ?? [:]
            // 入场锚点：取**最晚一轮**的价格（对齐 review/tuner 的「尾盘 14:50 买入」口径）。
            // ⚠ `PhasePredict` 里的同名逻辑**有意**取最早一轮 —— 两处不同是既定事实，
            //   不要"顺手统一"。
            var selPrice: Double = 0
            for s in slots {
                let round = rounds[s] ?? [:]
                for p in ((round["tier1"] as? [[String: Any]]) ?? [])
                    + ((round["tier2"] as? [[String: Any]]) ?? []) {
                    if (p["code"] as? String) == code { selPrice = PredictRules.num(p["price"]) ?? 0 }
                }
            }
            let curPrice = PredictRules.num(q["price"]) ?? 0
            let chg = PredictRules.num(q["change_pct"]) ?? 0
            let hasData = curPrice > 0 && selPrice > 0
            // 收益口径：从入场锚点到现价（真实可执行收益）；T+1 当日涨跌另存 intraday_pct，
            // 它服务的是「预判方向命中」（相对昨收的方向），**不是**胜率 ——
            // 用当日涨跌当胜率会把"高开 6% 后回落 1%"记成亏损，验证页与复盘页口径不可比。
            let entryReturn: Double? = hasData
                ? PyMath.round((curPrice - selPrice) / selPrice * 100, 2) : nil
            let outcome = hasData
                ? ((entryReturn! > 0) ? "盈利" : (entryReturn! < 0 ? "亏损" : "持平")) : "无数据"

            var scores: [String: Any] = [:]
            let metaScores = (meta["scores"] as? [Int: Double]) ?? [:]
            for s in slots { scores[String(s)] = metaScores[s] ?? NSNull() }

            let signalType = (meta["signal_type"] as? String) ?? ""
            detail.append([
                "code": code,
                "name": (meta["name"] as? String) ?? (q["name"] as? String) ?? code,
                "signal_type": signalType,
                "sel_price": selPrice,
                // current_price 缺失 → NSNull（不是 0），保持落库形态
                "current_price": q["price"] ?? NSNull(),
                "current_pct": chg,
                "intraday_pct": chg,               // 兼容/语义显式化：T+1 当日涨跌
                "entry_return_pct": entryReturn ?? NSNull(),  // 真实收益（胜率与分组统计用这个）
                "volume_ratio": q["volume_ratio"] ?? NSNull(),
                "turnover": q["turnover"] ?? NSNull(),
                "scores": scores,
                "outcome": outcome,
            ])
            if hasData, let er = entryReturn {
                // 只有「已确认为持续」的才进 consensus 组；未验证（轮次不足）与脉冲同组，
                // 避免把未经确认的标的算进"最强+持续"的胜率里虚高
                let grp: WinGroup = (SignalType(rawValue: signalType)?.isVerified == true)
                    ? .consensus : .pulse
                for group in [WinGroup.total, grp] {
                    if er > 0 {
                        counters[group, default: WinLoss()].win += 1
                        counters[group, default: WinLoss()].winPnl += er
                    } else if er < 0 {
                        counters[group, default: WinLoss()].loss += 1
                        counters[group, default: WinLoss()].lossPnl += er
                    }
                }
            }
        }

        var stats: [WinGroup: [String: Any]] = [:]
        for (name, c) in counters {
            let n = c.win + c.loss
            stats[name] = [
                "verified": Int(n), "wins": Int(c.win), "losses": Int(c.loss),
                "winrate": n > 0 ? PyMath.round(c.win / n * 100, 1) : 0,
                "avg_profit": c.win > 0 ? PyMath.round(c.winPnl / c.win, 2) : 0,
                "avg_loss": c.loss > 0 ? PyMath.round(c.lossPnl / c.loss, 2) : 0,
            ]
        }
        result["groups"] = ["最强+持续": stats[.consensus] ?? [String: Any](),
                            "脉冲信号": stats[.pulse] ?? [String: Any]()]
        // ⚠ 落库键必须是**原字符串**：枚举只活在 Swift 内部，出口统一转回 rawValue，
        //   一次算好，`result` 与落库共用同一个字典（避免两处各转一遍、日后漂移）
        let statsOut = Dictionary(uniqueKeysWithValues: stats.map { ($0.key.rawValue, $0.value) })
        result["stats"] = statsOut

        // 预判交叉对比
        var deviations: [[String: Any]] = []
        let predStocks = CompareStore.shared.predictStocks(selDate: selDate)
        if !predStocks.isEmpty {
            var predByCode: [String: [String: Any]] = [:]
            for s in predStocks { if let c = s["code"] as? String { predByCode[c] = s } }
            for d in detail {
                let code = (d["code"] as? String) ?? ""
                guard let pred = predByCode[code], !(d["current_price"] is NSNull) else { continue }
                let direction = (pred["predict_direction"] as? String) ?? ""
                let predBullish = PhasePredict.bullishKeywords.contains { direction.contains($0) }
                let actualBullish = (PredictRules.num(d["current_pct"]) ?? 0) > 0
                if predBullish != actualBullish {
                    deviations.append([
                        "code": code, "name": d["name"] ?? "",
                        "predicted": direction,
                        "actual_pct": d["current_pct"] ?? NSNull(),
                    ])
                }
            }
        }
        result["deviations"] = deviations

        // 风险警告
        if slots.count < 3 {
            warnings.append("仅 \(slots.count)/3 轮数据，各标的持续性未经确认（信号标记为未验证），"
                            + "下方分组胜率仅供参考、不代表「持续信号」表现")
        }
        // ⚠ 胜率类警告必须先过**样本量门槛**（2026-10-16 审查 B5-3）：
        //   原先判据只有 `verified > 0 && winrate < 40` ⇒ **1 只票输了就报
        //   「总体胜率仅0.0%，建议空仓观望等待企稳」** —— 这是一句会直接改变
        //   用户当天仓位动作的输出，而它建立在 1 个样本上。
        //   仓库里已有现成的门槛（`SampleGate.defaultThreshold` = 30，
        //   此前只接进了调优池 `PhaseTune`），这里复用同一个数字，不再另起一套。
        let gate = SampleGate.defaultThreshold
        if let pulse = stats[.pulse] {
            let n = PredictRules.int(pulse["verified"]) ?? 0
            let wr = PredictRules.num(pulse["winrate"]) ?? 0
            if n >= gate, wr < 40 {
                warnings.append("脉冲信号胜率仅\(PyJSON.numStr(wr))%（低于40%阈值，样本 \(n) 只），"
                                + "建议只操作持续信号标的")
            } else if n > 0 && n < gate {
                warnings.append("脉冲信号样本仅 \(n) 只（门槛 \(gate) 只），"
                                + "不足以给出「只操作持续信号」的结论 —— 继续积累后再看")
            }
        }
        if let tot = stats[.total] {
            let n = PredictRules.int(tot["verified"]) ?? 0
            let wr = PredictRules.num(tot["winrate"]) ?? 0
            if n >= gate, wr < 40 {
                warnings.append("总体胜率仅\(PyJSON.numStr(wr))%（低于40%，样本 \(n) 只），"
                                + "建议空仓观望等待企稳")
            } else if n > 0 && n < gate {
                // 空仓建议的影响面最大，样本不足时**明确不出这句**
                warnings.append("总体样本仅 \(n) 只（门槛 \(gate) 只），"
                                + "不足以判断是否需要空仓观望 —— 本期不给仓位结论")
            }
        }
        result["warnings"] = warnings

        result["detail"] = detail
        result["status"] = "ok"
        if doPersist {
            try PhaseStore.shared.persistVerify(
                selDate: selDate, verifyTime: (result["verify_time"] as? String) ?? "",
                stats: statsOut, detail: detail, deviations: deviations,
                warnings: warnings, isEmptyDay: false)
        }
        return result
    }
}