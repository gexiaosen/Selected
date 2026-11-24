import Foundation
import SelectedCore

// MARK: - 任务收尾、重试与通知构造

extension Scheduler {

    func finish(task: Task, ok: Bool, json: JSONValue?, errorMessage: String?) {
        runningTaskId = nil
        // ⚠ 任务收尾时清掉句柄，`stop()`/新任务启动才能准确判断"在飞与否"。
        runningTask = nil
        inFlightCancelBox = nil   // 盒子随任务结束失效，`stop()` 不再置位陈旧盒
        // 任务结束后立刻重算并重挂定时器：下一个到点的任务（或失败重试）可以马上接手
        defer { tick(reason: "任务结束") }

        if ok {
            // 状态判定走 `ScanResult` 实体。这三个状态（`data_insufficient` / `persist_failed` /
            // `not_trading_day`）**只由扫描-落库路径产出**，其余任务的 `json` 不会有 → 走 `default`。
            let r = json.map(ScanResult.init)

            // ⚠ **取消是一个终态，不是失败**：`ScanRunner` 被取消时返回 `status=cancelled`（未落库）。
            //   必须放在 `data_insufficient` / `persist_failed` / `not_trading_day` **之前**判：
            //   取消是用户主动行为，既不该重试（用户已经不要了）、
            //   也不该标完成（状态显示"完成"而库里没有这一轮）。
            if r?.status == "cancelled" {
                // 不写 attempts、不递增退避、不发通知 —— 与 `markDone` 的语义差别是
                // 「这一轮没跑」而不是「跑了但没结果」。显式留在 pending，
                // 用户取消调度后可重新触发。
                var st = states[task.id] ?? TaskRuntimeState()
                st.status = .pending
                st.lastFailureAt = nil
                st.message = "已取消（未落库）"
                st.changedAt = Date()
                states[task.id] = st
                saveStates()
                return
            }

            // 数据源健全性失败：引擎判定全量行情不足阈值，本轮未落库。
            // 按可重试失败处理（不标记完成），窗口内自动重试，
            // 避免"任务显示成功但当天其实没有数据"。
            if r?.status == "data_insufficient" {
                markRetry(task: task, message: r?.dataErrorDash ?? "全量行情不足，本轮不落库")
                return
            }
            // 原生落库失败：runScan 不抛错而是置 status=persist_failed。
            // 必须按可重试失败处理 —— 否则界面显示"完成"、库里却没有这一轮。
            if r?.status == "persist_failed" {
                markRetry(task: task, message: "落库失败：" + (r?.persistErrorDash ?? "未知原因"))
                return
            }
            // 非交易日：`ScanRunner` 对休市返回 `status=not_trading_day` 而**不抛错**。
            // 休市不是"扫出了 0 只"，是"根本没扫"：标记完成（避免当天空跑）
            // 但**不发通知**、不写 lastError。
            if r?.status == "not_trading_day" {
                markDone(task)
                return
            }
            // 参数配置非法（画像区间坏）：本轮根本没跑，绝不能进 `markDone` + "选股完成"
            // （审查 B5-7）。按可重试失败处理 —— 用户很可能在补跑窗口（25 分钟）内
            // 就把参数改回来，重试即可成功；重试用尽则终态失败 + 失败通知，可见可查。
            if r?.status == "params_invalid" {
                markRetry(task: task, message: "参数无效：" + (r?.paramsErrorDash ?? "画像区间非法"))
                return
            }
            // ⚠「跑了但没数据」不是成功（2026-10-16 审查 B5-4）：
            //   `CompareStore.runOnce` 在没有可对比轮次时返回 `status=no_data` **且不落库**，
            //   `PhaseReview` 在缺预判时返回 `status=no_predict_data` —— 原先两者都落到
            //   下面的 `markDone` + 成功通知，于是"通知写『三轮对比报告就绪』、
            //   侧栏绿点、页面却是空态、库里一行没写"，用户完全没有线索可查。
            //   按**可重试失败**处理：窗口内自动重试（补跑完轮次后就能出结果），
            //   重试用尽则落终态失败并发失败通知 —— 与"完成"必须区分开。
            //   `no_sel_data`（预判缺选股数据）/`no_new_review`（迭代当日无新复盘）同理
            //   （2026-11-09 审查 #4）：都不落库，报「就绪」是虚报。
            if r?.status == "no_data" || r?.status == "no_predict_data"
                || r?.status == "no_sel_data" || r?.status == "no_new_review" {
                let why: String
                switch r?.status {
                case "no_predict_data": why = "缺预判数据"
                case "no_sel_data":     why = "缺选股数据"
                case "no_new_review":   why = "今日无新复盘落库"
                default:                why = "无可对比轮次"
                }
                markRetry(task: task, message: "没产出（\(why)）：本轮未落库")
                return
            }
            // 迭代计数器未满（not_due）：有效完成（已落库一行 isDue=false），但不发
            // 「报告就绪」—— 非到期日天天虚报会让通知失去意义（审查 #4）。完成广播照发，页面要刷新。
            let notifyDone = r?.status != "not_due"
            markDone(task)

            if let json {
                if notifyDone {
                    let target = Self.notifyTarget(task: task, json: json)
                    Notifier.shared.send(title: task.notifyTitle, body: Self.notifyBody(task: task, json: json),
                                         identifier: "selected.sched.done.\(task.id).\(ChinaTime.day())",
                                         page: target.page?.rawValue, section: target.section?.rawValue,
                                         date: target.date)
                }

                NotificationCenter.default.post(name: .engineTaskCompleted, object: task.id)
            }
            return
        }

        // ⚠ 这里**不得**用"失败文案里含「非交易日」字样"判状态（护栏 `sched_no_text_state` 盯的就是这条）：
        //   文案判定会让任何含这几个字的失败被当成**完成**（不重试、不通知 = 静默丢任务），
        //   而靠注释维持的"文案不能出现这几个字"约束迟早会破。
        //   正路是**结构化判据**（见上面 `if r?.status == "not_trading_day"`）：休市类 Job 都是
        //   **返回** `["status": "not_trading_day", …]`（**不抛错**），走 `ok == true` 那条分支。
        //
        // ⚠ 无文案也要落失败状态：`ok == false && errorMessage == nil` 若直接早退，
        //   状态仍是 `pending` → 判 `.runnable` → **立刻再次执行**（无 attempts 累加、无退避）。
        //   给个默认文案即闭合。
        markRetry(task: task, message: errorMessage ?? "任务失败（未提供原因）")
    }

    private func markDone(_ task: Task) {
        var st = states[task.id] ?? TaskRuntimeState()
        st.status = .done
        st.attempts = max(1, st.attempts)
        st.lastFailureAt = nil
        st.message = nil
        st.changedAt = Date()
        states[task.id] = st
        saveStates()
    }

    /// 可重试失败：状态置 `failed`（`ScheduleEngine` 会在窗口内按重试间隔安排重试）。
    /// 重试次数耗尽、或执行跨过了补跑窗口 → 转 `missed`（终态，UI 显式可见）。
    private func markRetry(task: Task, message msg: String) {
        let now = Date()
        var st = states[task.id] ?? TaskRuntimeState()
        st.attempts += 1
        st.lastFailureAt = now
        st.message = msg
        st.status = .failed
        st.changedAt = now
        lastError = "\(task.label): \(msg)"

        // 窗口判定（审查 #18）：必须与 `ScheduleEngine.disposition` **同一口径** ——
        // 盘中任务的补跑窗口被收回到当段收盘（第三轮 14:50 的窗口是 15:00，不是 14:50+25=15:15）。
        // 原先这里用未截断的 `dueDate + catchUpMinutes`：15:05 失败时判"窗口未过"、
        // 通知承诺"将自动重试"，而引擎下一次评估即 `outOfWindow` → 永不重试（谎报）。
        let close = ScheduleEngine.effectiveWindowClose(task.spec, on: now, policy: Self.policy)
        let windowOver = now > close
        // 下一次重试的到点时刻已在窗口外 ⇒ 重试必然被引擎拒（`outOfWindow`），
        // 同样不得承诺"将自动重试"：直接落终态，文案说真话。
        let retryAt = now.addingTimeInterval(Double(Self.policy.retryIntervalSeconds))
        let noRetryRoom = !windowOver && retryAt > close

        if st.attempts >= Self.policy.maxAttempts || windowOver || noRetryRoom {
            st.status = .missed
            let tail = windowOver ? "执行期间已超出补跑窗口"
                       : noRetryRoom ? "剩余补跑窗口不足一次重试间隔"
                       : "已重试 \(st.attempts - 1) 次仍失败"
            // ⚠ **真因必须留在 `st.message` 里**（原先这里整句换成通用文案，把传进来的真因覆盖掉了）：
            //   「调度」栏只显示这一句，而 NSLog 在这份 ad-hoc 签名包里 `log show` 读不到、
            //   有些失败分支（如 `FundFlowJob` 的日期闸门）连 `data_source_logs` 都不写
            //   ⇒ 覆盖一次就等于"事后无从知道今天为什么没出数据"。
            st.message = msg.isEmpty ? "\(tail)，当日不再重试" : "\(msg)（\(tail)，当日不再重试）"
            states[task.id] = st
            saveStates()
            lastScheduleNote = "\(task.label) \(st.message ?? "")"
            NSLog("[NOTICE] [Scheduler] 任务放弃：%@ —— %@", task.label, st.message ?? "")
            // ⚠ 文案必须与**真实原因**一致：这条分支也会被"超窗放弃"走到（那时 `attempts` 可能只有 1），
            //   恒写"已重试 N 次仍失败"会播报出与真相不符的线索。上面 `st.message` 已区分两种原因 → 直接用。
            Notifier.shared.send(title: "\(task.label)失败",
                                 body: String((st.message ?? "当日不再重试").prefix(200)),
                                 identifier: "selected.sched.fail.\(task.id).\(ChinaTime.day())")
            return
        }

        states[task.id] = st
        saveStates()
        if st.attempts == 1 {
            Notifier.shared.send(title: "\(task.label)失败",
                                 body: "\(String(msg.prefix(120)))｜将自动重试（第 \(st.attempts)/\(Self.policy.maxAttempts) 次）",
                                 identifier: "selected.sched.retry.\(task.id).\(ChinaTime.day())")
        }
        // 中间重试失败（2..<maxAttempts）静默：仅更新 lastError，避免通知轰炸
    }

    /// 任务完成通知点击后的落点：页面 +（可选）页内段落 + 报告所属日期。与 ``notifyBody(task:json:)``
    /// 放在一起，新增任务时两张表在同一段代码里，不会一个改了另一个忘。
    ///
    /// 轮次一律由 `RoundPlan` 判定：写死 `case "round1","round2","round3"` 的话，
    /// 加第 4 轮后那一轮的通知**点了不跳转**（落进 `default`），且没有任何报错。
    ///
    /// ⚠ 段落标记不能省：三轮对比已并入结果页（2026-10-29 M1），只跳页会把人放在**页面顶部**，
    ///   而通知正文写的是对比结论 —— 没有 `section` 就等于入口指错了地方。
    /// ⚠ 日期同理不能省（2026-11-09 审查 #2）：预判/验证/复盘挂在**选股日**下（T+1 产出），
    ///   落地不带日期会停在「今天」的空态（通知说就绪、页面说没生成）。
    /// 返回 `page = nil` = 该任务没有对应页面（如收盘后的抓取类），点击只把 App 带到前台。
    private static func notifyTarget(task: Task, json: JSONValue) -> (page: Page?, section: NotifySection?, date: String?) {
        if RoundPlan.isRound(key: task.id) { return (.results, nil, ChinaTime.day()) }
        switch task.id {
        case "compare":                    return (.results, .compare, ChinaTime.day())
        case "predict", "verify":          return (.predict, nil, json["sel_date"].string)
        case "review":                     return (.review, nil, json["sel_date"].string)
        case "iterate":                    return (.history, nil, ChinaTime.day())
        case "watch":                      return (.watch, nil, nil)
        case "boardheat":                  return (.board, nil, nil)
        case "indsnap":                    return (.indicators, nil, nil)
        default:                           return (nil, nil, nil)
        }
    }

    private static func notifyBody(task: Task, json: JSONValue) -> String {
        if RoundPlan.isRound(key: task.id) {
            // 走 `ScanResult` 实体（键名编译期检查）
            let r = ScanResult(json)
            var body = "一档 \(r.stats.tier1Count) 只 / 二档 \(r.stats.tier2Count) 只"
            // ⚠ 只在真有数值时附上 —— 用 `shChangePct`（缺省 0）会凭空播报"上证 +0.00%"
            if let pct = r.marketEnv.shChangePctOrNil {
                body += "｜上证 \(String(format: "%+.2f", pct))%"
            }
            return body
        }
        switch task.id {
        case "compare":
            // 走 `CompareReport` 实体
            let st = CompareReport(json).stability
            // 轮次不足时不得播报"高置信"——持续性未经确认（缺失轮次会伪造出一致性）
            // ⚠ 用 `isExplicitlyUnverified`（显式 false 才算）
            if st.isExplicitlyUnverified {
                let missing = st.missingSlots.map(String.init).joined(separator: "、")
                return missing.isEmpty
                    ? "轮次不足，持续性未验证，按脉冲对待"
                    : "缺第 \(missing) 轮，持续性未验证，按脉冲对待"
            }
            return st.alwaysTier1.isEmpty
                ? "无三轮稳定标的，谨慎操作"
                : "高置信：\(st.alwaysTier1.joined(separator: "、"))"
        case "predict":
            // 走 `PredictResult` 实体
            let r = PredictResult(json)
            let tail = r.isExplicitlyUnverified ? "｜轮次不足·未验证" : ""
            return "灯级：\(r.marketEnv.lightDash)｜标的 \(r.stocks.count) 只\(tail)"
        case "verify":
            return "总体胜率 \(VerifyResult(json).stats.total.winrate)%"
        case "fundflow":
            // ⚠ 这里的键名与 `FundFlowJob.run()` 的返回字典一一对应，
            // 但没有实体包着（不像 ScanResult 那样有编译期检查）→ 改键名必须两边一起改。
            let saved = json["saved"].int ?? 0
            let inflow = json["inflow_count"].int ?? 0
            var body = "落库 \(saved) 只｜主力净流入 \(inflow) 只"
            // ⚠ 只在**确实净流入**时才报"最强"：全市场普跌时 `max` 会挑出
            //   "流出最少的那只"，播报成"最强"是反的。
            if (json["top_main_net"].double ?? 0) > 0,
               let name = json["top_name"].string, !name.isEmpty {
                body += "｜最强 \(name)"
            }
            return body
        case "lhb":
            // ⚠ 这里的键名与 `LhbJob.run()` 的返回字典一一对应，
            // 但没有实体包着（不像 ScanResult 那样有编译期检查）→ 改键名必须两边一起改。
            let records = json["records"].int ?? 0
            let inst = json["inst_count"].int ?? 0
            var body = "上榜 \(records) 条｜机构买入 \(inst) 只"
            // ⚠ 只在**确实净买入**时才报"最强"：全市场普跌时 `max` 会挑出
            //   "卖出最少的那只"，播报成"最强"是反的（与资金流同一条理由）。
            if (json["top_net"].double ?? 0) > 0,
               let name = json["top_name"].string, !name.isEmpty {
                body += "｜最强 \(name)"
            }
            // 回看补漏时把补的是哪一天写出来 —— 否则用户会以为这是"今天的数据"
            if json["backfilled"].bool == true, let d = json["date"].string {
                body += "（补 \(d)）"
            }
            return body
        case "limitup":
            // 涨停统计摘要，顺带播报昨日涨停表现。
            //   ⚠ 键名与 `LimitUpPoolJob.run()` / `zt_sentiment` 子字典一一对应（无实体包着）。
            let records = json["records"].int ?? 0
            var body = "涨停 \(records) 只"
            if (json["max_boards"].int ?? 0) > 0 {
                body += "｜最高 \(json["max_boards"].int ?? 0) 连板"
                if let name = json["top_name"].string, !name.isEmpty { body += "（\(name)）" }
            }
            // 情绪（功能 A）：只有算出来才播报（跳过时 `zt_sentiment` 键不存在）
            let s = json["zt_sentiment"]
            if !s.isNull {
                let avg = s["avg_pct"].double ?? 0
                let promo = s["promoted"].int ?? 0
                let sample = s["sample"].int ?? 0
                body += "｜昨涨停今均涨 \(String(format: "%+.2f", avg))%｜晋级 \(promo)/\(sample)"
            }
            return body
        case "boardheat":
            // ⚠ 键名与 `BoardHeatJob.run()` 一一对应（无实体包着）。
            let records = json["records"].int ?? 0
            var body = "板块 \(records) 个"
            // ⚠ 只在**确实上涨**时才报"领涨"：全市场普跌时 `max` 会挑出"跌最少的板块"，
            //   播报成"领涨"是反的（与资金流/龙虎榜同一条理由）。
            if (json["top_pct"].double ?? 0) > 0,
               let name = json["top_name"].string, !name.isEmpty {
                body += "｜领涨 \(name) \(String(format: "%+.2f", json["top_pct"].double ?? 0))%"
            }
            return body
        case "indsnap":
            // ⚠ 键名与 `IndicatorSnapshotJob.run()` 一一对应（无实体包着）。
            let saved = json["saved"].int ?? 0
            let date = json["date"].string ?? ""
            return "落库 \(saved) 只｜最新日 \(date)"
        case "review":
            return "窗口可用胜率 \(ReviewResult(json).fourLayerWinrate.window.winrate)%"
        case "watch":
            // 走 `WatchJudgeResult` 实体
            // 自选判定摘要：买入/卖出数 + 大盘灯（空列表时如实说明）
            let r = WatchJudgeResult(json)
            if r.judged == 0 {
                return r.summary.isEmpty ? "自选列表为空" : r.summary
            }
            var parts = [r.summary]
            if !r.buys.isEmpty {
                parts.append("买入：\(r.buys.joined(separator: "、"))")
            }
            // `sells` 每项是 `[原因, 名称]` 二元组
            let txt = r.sells.compactMap { pair -> String? in
                guard let a = pair.first, let n = pair.last, !a.isEmpty, !n.isEmpty else { return nil }
                return "\(n)(\(a.replacingOccurrences(of: "卖出", with: "")))"
            }.joined(separator: "、")
            if !txt.isEmpty { parts.append("卖出：\(txt)") }
            return parts.filter { !$0.isEmpty }.joined(separator: "｜")
        default:
            return task.label
        }
    }
}
