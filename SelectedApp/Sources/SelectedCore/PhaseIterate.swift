import Foundation

/// 阶段四 · 三天迭代。
///
/// 计数器入库；**空仓日不消耗计数器**；
/// 满 3 个有效交易日触发偏差模式识别，**只输出建议不自动改参数**（铁律）。
///
/// ⚠ **同步阻塞**（读库 + 落库），调用方必须放后台线程。
public enum PhaseIterate {

    public static let counterKey = "iterate_counter"

    // MARK: - 分类判定

    /// 真空仓日：无入档信号（is_empty_day 标记或无标的）。
    ///
    /// ⚠ 红灯日（暴跌日不操作，标的全 skipped）**不是**空仓日 —— 那天有选股动作，
    /// 只是策略规定不进场。空仓占比只统计真空仓，避免把「策略性不操作」计入「无信号」
    /// （两者风控含义不同）。
    public static func isEmptyDay(_ r: [String: Any]) -> Bool {
        if PredictRules.truthy(r["is_empty_day"]) { return true }
        let stocks = (r["stocks"] as? [[String: Any]]) ?? []
        return stocks.isEmpty
    }

    /// 无有效参与样本：有标的但全部 skipped（红灯日不操作 / 数据受限）。
    /// 与空仓同样不累计迭代计数器（无胜率样本可分析），但不计入空仓占比。
    public static func isNoParticipation(_ r: [String: Any]) -> Bool {
        if isEmptyDay(r) { return false }        // 空仓日已单独归类
        let stocks = (r["stocks"] as? [[String: Any]]) ?? []
        return !stocks.isEmpty && stocks.allSatisfy { PredictRules.truthy($0["skipped"]) }
    }

    // MARK: - 主流程

    public static func iterate(persist: Bool = true, todayStr: String? = nil,
                        params: [String: Any]) throws -> [String: Any] {
        let itCfg = (params["iterate"] as? [String: Any]) ?? [:]
        let thr = (itCfg["thresholds"] as? [String: Any]) ?? [:]
        let runDay = DataSources.runDate()
        let day = todayStr ?? runDay
        let isLiveDay = (day == runDay)

        var result: [String: Any] = [
            "trigger_date": day, "trigger_time": PhaseStore.nowHM(),
            "is_empty_day_report": false, "counter": NSNull(),
            "insights": [Any](), "empty_trend": NSNull(), "status": "ok",
            "data_mode": isLiveDay ? "live" : "replay",
        ]
        var doPersist = persist
        if !isLiveDay && doPersist {
            // 历史日重跑只读：计数器是"每日推进一次"的节奏器，回放不能改它。
            // ⚠ 只把 persist 置 False 是不够的：下面**每处写库动作**（setCounter / persist）
            //   都必须各自判断，否则回放会静默推进线上计数器。
            doPersist = false
            result["data_mode"] = "replay_readonly"
        }

        // 幂等：计数器必须"每日最多推进一次"，同日重跑不得再次推进、
        // 也不得把当天已生成的迭代报告覆盖成"未到期"报告。
        if let prev = PhaseStore.shared.iterateReport(triggerDate: day) {
            result["status"] = "already_done"
            result["counter"] = prev.counter
            let stored = (PhaseStore.jsonLoads(prev.insightsJSON) as? [Any]) ?? []
            result["insights"] = stored + ["\(day) 已完成迭代，重跑不改变计数器（幂等）"]
            return result
        }

        let triggerInterval = PredictRules.int(itCfg["trigger_interval"]) ?? 3
        let emptyTrendDays = PredictRules.int(itCfg["empty_trend_days"]) ?? 10
        let warningPct = PredictRules.num(itCfg["warning_pct"]) ?? 0
        let noticePct = PredictRules.num(itCfg["notice_pct"]) ?? 0

        // 今日复盘（最新一条）：空仓或红灯无参与样本均不累计计数器，但语义分开记录
        let recent = PhaseStore.shared.recentReviews(1)
        // ⚠ "最新一条复盘"必须**确认是本次要收的那条**（2026-10-16 审查 B5-15）：
        //   `recentReviews(1)` 是按 sel_date 倒序取第一条，它**不保证是今天生成的**。
        //   于是 15:05 的复盘任务失败（或晚于 15:30 的迭代才跑完）时，
        //   今天取到的仍是**昨天那条复盘** —— 而它已经被昨天的迭代消费过了：
        //   结果计数器为同一个复盘日**推进两次**、三日窗口里同一条复盘被**重复计入**，
        //   界面与库里都没有任何痕迹（报告照发、洞察照出）。
        //   判据用 `updated_at` 的日期部分（库里 `reviews` 没有 review_date 列，
        //   `review_time` 只有 HH:MM，`updated_at` 才是落库时刻）。
        //   ⚠ 只在 live 日拦：`data_mode=replay_readonly` 的历史重跑本来就要读旧复盘。
        let latestReview = recent.first
        let reviewWrittenToday = ((latestReview?["updated_at"] as? String) ?? "")
            .prefix(10) == DataSources.runDate()
        if isLiveDay, latestReview != nil, !reviewWrittenToday {
            result["status"] = "no_new_review"
            result["counter"] = PhaseStore.shared.counter(counterKey)
            result["insights"] = ["今天没有新的复盘落库（最新一条 sel_date=\(latestReview?["sel_date"] ?? "无")）"
                                  + "⇒ 本次迭代不推进计数器、不重复消费同一条复盘；"
                                  + "请先检查 15:05 收盘复盘任务是否失败"]
            DataSources.logDataSource("iterate", "no_new_review",
                                      "最新复盘 updated_at 非本日（sel_date="
                                      + "\((latestReview?["sel_date"] as? String) ?? "无")）→ 不推进计数器")
            return result
        }
        let todayEmpty = latestReview.map { isEmptyDay($0) } ?? false
        let todayNoPart = latestReview.map { isNoParticipation($0) } ?? false
        var counter = PhaseStore.shared.counter(counterKey)
        result["counter"] = counter


        // 近 N 日空仓趋势（仅真空仓；红灯日单独计数）
        let allRecent = PhaseStore.shared.recentReviews(emptyTrendDays)
        let emptyCount = allRecent.filter { isEmptyDay($0) }.count
        let noPartCount = allRecent.filter { isNoParticipation($0) }.count
        let totalCount = allRecent.count
        let emptyRatio = totalCount > 0
            ? PyMath.round(Double(emptyCount) / Double(totalCount) * 100, 1) : 0
        result["empty_trend"] = [
            "total_days": totalCount, "empty_days": emptyCount,
            "no_participation_days": noPartCount, "empty_ratio": emptyRatio,
            "daily": allRecent.map { r -> [String: Any] in
                let stocks = (r["stocks"] as? [[String: Any]]) ?? []
                return [
                    "date": r["sel_date"] ?? "",
                    "is_empty": isEmptyDay(r),
                    "is_no_participation": isNoParticipation(r),
                    "stocks": stocks.count,
                    "participating": stocks.filter { !PredictRules.truthy($0["skipped"]) }.count,
                ]
            },
        ]

        var insights: [String] = []
        if todayEmpty || todayNoPart {
            result["is_empty_day_report"] = true
            if todayNoPart && !todayEmpty {
                insights.append("红灯日（暴跌日不操作）：有入档信号但策略规定不进场，无胜率样本，不累计迭代计数器")
            }
            if emptyRatio >= warningPct {
                insights.append("警告：近\(totalCount)日空仓占比\(PyJSON.numStr(emptyRatio))%"
                                + "（≥\(PyJSON.numStr(warningPct))%），市场持续偏弱，"
                                + "建议关注大盘止跌信号（缩量、地量、连续小阳），不建议放宽筛选条件")
            } else if emptyRatio >= noticePct {
                insights.append("近\(totalCount)日空仓占比\(PyJSON.numStr(emptyRatio))%，"
                                + "市场处于弱势震荡，空仓观望是正确风控策略")
            } else {
                insights.append("近期市场有涨有跌，空仓属于正常波动，无需特别调整")
            }
            insights.append("本日无胜率样本（空仓/红灯），不累计迭代计数器"
                            + "（当前 \(counter)/\(triggerInterval)）")
            result["insights"] = insights
            if doPersist { try persistIterate(result, isDue: false) }
            return result
        }

        // 有效交易日：计数器 +1
        counter += 1
        result["counter"] = counter
        if counter < triggerInterval {
            if doPersist { try PhaseStore.shared.setCounter(counterKey, counter) }
            result["status"] = "not_due"
            insights.append("计数器 \(counter)/\(triggerInterval)，未满不触发迭代")
            result["insights"] = insights
            if doPersist { try persistIterate(result, isDue: false) }
            return result
        }

        // 满 N 触发，清零
        if doPersist { try PhaseStore.shared.setCounter(counterKey, 0) }
        result["counter"] = 0

        // 近 N 有效日数据
        let reviews = PhaseStore.shared.recentReviews(10)
            .filter { !isEmptyDay($0) }
            .prefix(triggerInterval)
        var allStocks: [[String: Any]] = []
        for r in reviews {
            allStocks.append(contentsOf: ((r["stocks"] as? [[String: Any]]) ?? [])
                .filter { !PredictRules.truthy($0["skipped"]) })
        }

        /// ⚠ 只统计**有样本**（`total > 0`）的日子：无样本的日子（红灯日全 skipped、
        /// replay 日没有 5 分钟线）若直接取 `winrate`（缺失时为 0）会以 **0% 胜率**计入均值，
        /// 系统性拉低 avgWindow / avgSnap / avgClose，并虚假触发下面那组洞察
        /// （「四层胜率均偏低」「窗口优于快照」…）。`allStocks` 一侧同样剔除 skipped —— 两侧口径一致。
        func avgLayer(_ layer: String) -> Double {
            let vals: [Double] = reviews.compactMap { r in
                let fl = (r["four_layer_winrate"] as? [String: Any]) ?? [:]
                guard let d = fl[layer] as? [String: Any],
                      (PredictRules.num(d["total"]) ?? 0) > 0 else { return nil }
                return PredictRules.num(d["winrate"]) ?? 0
            }
            guard !vals.isEmpty else { return 0 }
            return PyMath.round(vals.reduce(0, +) / Double(vals.count), 1)
        }
        let avgSnap = avgLayer("snapshot"), avgClose = avgLayer("close")
        let avgWindow = avgLayer("window"), avgHigh = avgLayer("ceiling")
        result["four_layer_avg"] = ["snapshot": avgSnap, "close": avgClose,
                                    "window": avgWindow, "ceiling": avgHigh]

        if allStocks.count < 5 {
            var skippedAll: [[String: Any]] = []
            for r in PhaseStore.shared.recentReviews(10).prefix(triggerInterval) {
                skippedAll.append(contentsOf: (r["stocks"] as? [[String: Any]]) ?? [])
            }
            let cw = skippedAll.filter { PredictRules.num($0["close_win"]) != nil }
            let refWr = cw.isEmpty ? 0
                : PyMath.round(cw.reduce(0.0) { $0 + (PredictRules.num($1["close_win"]) ?? 0) }
                               / Double(cw.count) * 100, 1)
            insights.append("有效样本不足（\(allStocks.count)只），参考数据（含暴跌日跳过标的）："
                            + "收盘持有胜率\(PyJSON.numStr(refWr))%，"
                            + (refWr < 50 ? "验证了暴跌日空仓决策正确性" : "可关注大盘止跌后信号强化"))
        } else {
            // 按信号类型分组：只有已确认持续（strongest/consensus）算持续信号；
            // 未验证（轮次不足）与脉冲同组，避免把未经确认的算进持续信号表现
            // ⚠ 空串 / 未识别 → 非「持续」→ 归 pulse
            let cons = allStocks.filter { SignalType(json: $0["signal_type"])?.isVerified == true }
            let pulse = allStocks.filter { !(SignalType(json: $0["signal_type"])?.isVerified == true) }

            func wr(_ stocks: [[String: Any]]) -> (Double, Int) {
                let v = stocks.filter { PredictRules.num($0["window_win"]) != nil }
                guard !v.isEmpty else { return (0, 0) }
                let sum = v.reduce(0.0) { $0 + (PredictRules.num($1["window_win"]) ?? 0) }
                return (PyMath.round(sum / Double(v.count) * 100, 1), v.count)
            }
            let (consWr, consN) = wr(cons)
            let (pulseWr, pulseN) = wr(pulse)
            let groupSignal = PredictRules.num(thr["group_signal"]) ?? 0
            if consN > 0 && pulseN > 0 && consWr - pulseWr > groupSignal {
                insights.append("信号类型差异：持续信号窗口可用胜率\(PyJSON.numStr(consWr))%(\(consN)只) "
                                + "vs 脉冲信号\(PyJSON.numStr(pulseWr))%(\(pulseN)只)"
                                + " → 脉冲信号建议降低仓位或缩短持有时间")
            }
            result["group_analysis"] = [
                "consensus": ["winrate": consWr, "count": consN],
                "pulse": ["winrate": pulseWr, "count": pulseN],
            ]

            // 四层交叉偏差
            let vsSnap = PredictRules.num(thr["window_vs_snap"]) ?? 0
            let vsClose = PredictRules.num(thr["window_vs_close"]) ?? 0
            let hiVsWin = PredictRules.num(thr["high_vs_window"]) ?? 0
            let lowWr = PredictRules.num(thr["low_winrate"]) ?? 0
            let lowHWr = PredictRules.num(thr["low_high_winrate"]) ?? 0
            // 全部加 `> 0` 守卫：avgX 为 0 表示**当日无样本**，不是「胜率为零」；
            // 没有守卫时无样本日会稳定命中「胜率均偏低」这类结论。
            if avgWindow > 0 && avgSnap > 0 && avgWindow > avgSnap + vsSnap {
                insights.append("窗口可用胜率(\(PyJSON.numStr(avgWindow))%)显著高于快照胜率"
                                + "(\(PyJSON.numStr(avgSnap))%) → 当前卖出窗口合理，10点验证过早")
            }
            if avgWindow > 0 && avgWindow > avgClose + vsClose {
                insights.append("窗口可用胜率(\(PyJSON.numStr(avgWindow))%)高于收盘持有胜率"
                                + "(\(PyJSON.numStr(avgClose))%) → 存在午后跳水，加强「午前必卖」提示")
            }
            if avgHigh > 0 && avgHigh > avgWindow + hiVsWin {
                insights.append("策略上限胜率(\(PyJSON.numStr(avgHigh))%)显著高于窗口可用胜率"
                                + "(\(PyJSON.numStr(avgWindow))%) → 卖出窗口可能偏窄，考虑扩大窗口或分批卖出")
            }
            if avgWindow > 0 && avgHigh > 0 && avgWindow < lowWr && avgHigh < lowHWr {
                insights.append("四层胜率均偏低(窗口\(PyJSON.numStr(avgWindow))%/上限"
                                + "\(PyJSON.numStr(avgHigh))%) → 选股策略需收紧，检查筛选条件")
            }

            // 日内高点分布
            let highTimes = allStocks.compactMap { $0["high_time"] as? String }.filter { !$0.isEmpty }
            if !highTimes.isEmpty {
                let morning = highTimes.filter { $0 < "11:30" }.count
                let afternoon = highTimes.filter { $0 >= "13:00" }.count
                let morningRatio = PredictRules.num(thr["morning_ratio"]) ?? 0
                let afternoonRatio = PredictRules.num(thr["afternoon_ratio"]) ?? 0
                if Double(morning) > Double(highTimes.count) * morningRatio {
                    insights.append("日内高点分布：\(morning)/\(highTimes.count)出现在上午 → "
                                    + "上午卖出策略正确，维持10:30-11:30窗口")
                } else if Double(afternoon) > Double(highTimes.count) * afternoonRatio {
                    insights.append("日内高点分布：\(afternoon)/\(highTimes.count)出现在下午 → "
                                    + "高点偏下午，考虑延后卖出窗口至13:30-14:30")
                }
            }
        }

        // 空仓趋势并入
        if emptyRatio >= 70 {
            insights.append("近\(totalCount)日空仓占比\(PyJSON.numStr(emptyRatio))%，市场持续偏弱 → "
                            + "空仓策略正在规避风险，不建议放宽筛选条件")
        } else if emptyRatio >= 40 {
            insights.append("近\(totalCount)日空仓占比\(PyJSON.numStr(emptyRatio))%，市场震荡偏弱 → "
                            + "维持现有筛选条件")
        }

        if insights.isEmpty {
            insights.append("近3日无显著偏差模式，当前策略配置合理，维持现有参数")
        }
        insights.append("本报告仅输出建议，不自动修改任何参数；人工确认后在参数中心手动调整")
        result["insights"] = insights

        if doPersist { try persistIterate(result, isDue: true) }
        return result
    }

    /// 落库迭代报告：`counter` 取 `result["counter"]`（None/0 都给 0）
    private static func persistIterate(_ result: [String: Any], isDue _: Bool) throws {
        let counter = PredictRules.int(result["counter"]) ?? 0
        try PhaseStore.shared.persistIterate(
            triggerDate: (result["trigger_date"] as? String) ?? "",
            isEmptyDayReport: PredictRules.truthy(result["is_empty_day_report"]),
            counter: counter,
            insights: (result["insights"] as? [Any]) ?? [],
            emptyTrend: result["empty_trend"] ?? NSNull(),
            fourLayerAvg: (result["four_layer_avg"] as? [String: Any]) ?? [:])
    }
}