import Foundation
import SwiftUI
import Observation
import SelectedCore

/// 全局状态（v2 架构）：
/// - 读操作：SQLiteReader 直读（毫秒级）
/// - 写操作：全部原生（后台线程执行，不阻塞 UI）；失败就直接报错，不静默换引擎
/// - 全局查看日期 viewDate：所有页面联动；历史模式（viewDate ≠ 今天）禁用写操作
extension Store {
    // MARK: - 菜单栏「立即全轮选股」：补齐当日缺失轮次

    /// 补跑窗口（**唯一来源 = 调度策略**）：轮次点起 N 分钟内。
    /// ⚠ 不要再在这里写一个数字：窗口长度由 `SchedulePolicy.catchUpMinutes` 定义（两处各写一份迟早打架）。
    static var catchUpWindowMinutes: Int { Scheduler.policy.catchUpMinutes }

    /// 该轮次此刻是否仍在可补跑窗口内（**手动补跑**用；与调度器**有意不同**）。
    ///
    /// **末轮例外** —— 它是当日最后一轮，收盘后的行情就是当日最终状态，
    /// 不存在「用更晚的数据冒充更早轮次」的问题，故当日剩余时间均可补跑。
    /// 判据取 `RoundPlan.slots.last`（写死 `3` 的话，加第 4 轮后**新末轮没有例外、
    /// 旧末轮却永远能超窗补跑** —— 两边都错且不报错）。
    ///
    /// ⚠ 与 `ScheduleEngine.disposition` **有意不同**（调度器没有末轮例外，超窗就记 `missed`），
    ///   不是漏改，也**不该"收敛成一个"**：
    ///   · **调度器是自动的** → 若允许它 16:00 才补跑末轮，那一轮取的是**收盘价**，
    ///     而同一天的前几轮是**盘中价** → 多轮持续信号里混进**两种口径**，
    ///     且**界面上看不出来**（库里没有留痕手段）→ 干脆不自动跑。
    ///   · **手动补跑是用户明确要求的** → 允许，但必须**当场说清**口径差异
    ///     （见 `runMissingRounds` 里的末轮提示）。
    func catchUpWindowOpen(slot: Int, now: Date = Date()) -> Bool {
        guard let t = ScheduleTimes.shared.time(of: RoundPlan.roundKey(slot)) else { return false }
        let cal = ChinaTime.calendar
        let minutes = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
        let start = t.hour * 60 + t.minute
        if minutes < start { return false }   // 未到点：交给调度器，不预跑
        if slot == RoundPlan.slots.last { return true }
        return minutes <= start + Self.catchUpWindowMinutes
    }

    /// 该轮次是否已过**常规**补跑窗口（即：它之所以还能补，靠的是末轮例外）。
    /// 只用于**给用户提示口径差异**，不参与任何判定。
    func beyondNormalWindow(slot: Int, now: Date = Date()) -> Bool {
        guard let t = ScheduleTimes.shared.time(of: RoundPlan.roundKey(slot)) else { return false }
        let cal = ChinaTime.calendar
        let minutes = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
        return minutes > t.hour * 60 + t.minute + Self.catchUpWindowMinutes
    }

    /// 补齐当日缺失轮次（菜单栏「立即全轮选股」的真实行为）。
    ///
    /// **硬边界：只补跑仍在其窗口内的缺失轮次。** 跨窗口补跑取到的是同一份
    /// （更晚的）行情快照，会把「只入档一次」的脉冲伪造成「三轮持续」，
    /// 恰好绕过「仅三轮持续信号才买」的纪律 —— 因此宁可留空并明确告知。
    /// 补齐后当日三轮齐全才跑 compare（与 14:50 调度链一致）；轮次不全时
    /// 不跑 compare，否则会把 signal_classes 整体覆盖为 unverified。
    func runMissingRounds() {
        guard !isHistorical else {
            lastError = "历史模式下不可执行写操作，请先回到最新交易日"
            ToastCenter.shared.show(lastError ?? "补跑未开始", style: .warning)
            return
        }
        guard !busy.contains("round"), !busy.contains("compare") else { return }
        // 与调度器互斥：补跑本身就是"再造一轮"，与调度器并发会重复落轮
        guard !blockedByScheduler("补跑轮次") else { return }

        // 用「今天」口径判已扫轮次（不能用 roundSummaries：它跟 viewDate，见 todayDoneSlots 注释）
        // ⚠ 命令执行前必须**实时**读（审查 B3）：`todayDoneSlots` 现在是 refresh() 刷的缓存，
        //   补跑/对比若用它会基于"上一次刷新"决定要不要再造一轮。
        let done = freshTodayDoneSlots()
        let missing = RoundPlan.missing(done)
        guard !missing.isEmpty else {
            ToastCenter.shared.show("当日\(RoundPlan.cn(RoundPlan.count))轮已齐全，无需补跑", style: .info)
            return
        }

        let runnable = missing.filter { catchUpWindowOpen(slot: $0) }
        let expired = missing.filter { !runnable.contains($0) }
        guard !runnable.isEmpty else {
            lastError = "第 \(expired.map(String.init).joined(separator: "、")) 轮已过补跑窗口"
                + "（窗口 = 轮次点起 \(Self.catchUpWindowMinutes) 分钟），未补跑；跨窗口补跑会伪造持续性"
            ToastCenter.shared.show("已过补跑窗口，未执行扫描", style: .warning)
            return
        }
        if !expired.isEmpty {
            ToastCenter.shared.show(
                "第 \(expired.map(String.init).joined(separator: "、")) 轮已过补跑窗口，只补可补的轮次", style: .warning)
        }
        // ⚠ **末轮**若靠末轮例外补跑 → 它取的是**当前行情**（很可能已是收盘价），
        //   而同日的前几轮是盘中价 → **各轮口径不同**，且这一点**不会记在库里** →
        //   必须**当场说清**，否则用户会以为各轮是同一口径。
        if let last = RoundPlan.slots.last, runnable.contains(last), beyondNormalWindow(slot: last) {
            let earlier = RoundPlan.slots.dropLast().map(String.init).joined(separator: "/")
            ToastCenter.shared.show(
                // ⚠ 文案不能用 `**`：本句是 `+` 拼接的 `String`，而 `ToastCenter.show` 收的就是
                //   `String` → 走 verbatim、不解析 Markdown → 星号会**原样显示给用户**。要强调用「」。
                //   （护栏 `md_literal` 盯的正是这个形态。）
                "第 \(last) 轮按「当前行情」补跑（已过 \(Self.catchUpWindowMinutes) 分钟常规窗口）："
                + "该轮可能是收盘价口径，与第 \(earlier) 轮的盘中价不同 —— "
                + "\(RoundPlan.cn(RoundPlan.count))轮持续信号请按此理解",
                style: .warning)
        }
        runCatchUpChain(runnable, index: 0)
    }

    /// 串行补跑（引擎写操作互斥：同一时刻只允许一轮在跑），
    /// 全部补完后由 runCompareIfComplete 收尾。
    func runCatchUpChain(_ slots: [Int], index: Int) {
        guard index < slots.count else {
            runCompareIfComplete()
            return
        }
        let slot = slots[index]
        runRoundNative(slot: slot, successMessage: "第\(slot)轮扫描完成") { [weak self] ok in
            guard let self else { return }
            if ok {
                self.runCatchUpChain(slots, index: index + 1)
            } else {
                ToastCenter.shared.show("第\(slot)轮补跑失败，已中止", style: .error)
            }
        }
    }

    /// 原生三轮对比：读库 → 计算 → 落库。
    ///
    /// 耗时毫秒级（读几百行 + 写几十行），故直接同步执行。
    ///
    /// 语义：
    ///   · 历史模式下禁止（compare 是写操作，仅"今天"口径）
    ///   · 无轮次数据时不落库（直接返回 status=no_data）
    ///   · 落库失败**直接报错**：错误写进 lastError 让用户看到
    func runCompareNative(successMessage: String?) {
        let key = "compare"
        guard !isHistorical else {
            lastError = "历史模式下不可执行写操作，请先回到最新交易日"
            lastErrorKey = key
            ToastCenter.shared.show(lastError ?? "对比未执行", style: .warning)
            return
        }
        guard !busy.contains(key) else { return }
        busy.insert(key)

        let date = ChinaTime.day()          // 与引擎 ds.run_date() 同口径（本机当天）
        do {
            let report = try CompareStore.runOnce(date: date)
            busy.remove(key)
            guard (report["status"] as? String) != "no_data" else {
                lastError = "今日尚无扫描轮次，无法生成对比"
                lastErrorKey = key
                ToastCenter.shared.show(lastError ?? "对比未执行", style: .warning)
                return
            }
            if lastErrorKey == key { lastError = nil; lastErrorKey = nil }
            refresh()
            if let msg = successMessage { ToastCenter.shared.show(msg) }
        } catch {
            busy.remove(key)
            let why = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            lastError = "对比落库失败：\(why)"
            lastErrorKey = key
            ToastCenter.shared.show(lastError ?? "对比失败", style: .error)
        }
    }

    /// 当日三轮齐全才跑 compare，保证补跑真正产出可用信号（而非停在 unverified）
    func runCompareIfComplete() {
        // 同上：compare 作用于今日，必须按今日口径**实时**判三轮是否齐全
        let done = freshTodayDoneSlots()

        guard done.count >= 3 else {
            ToastCenter.shared.show("补跑完成（当日轮次仍不全，跳过对比）", style: .warning)
            return
        }
        runCompareNative(successMessage: "当日三轮已补齐，对比报告已更新")
    }

    func generateCompare() {
        guard !busy.contains("compare") else { return }
        guard !blockedByScheduler("生成对比") else { return }
        runCompareNative(successMessage: "对比报告已生成")
    }

    func recomputePredict() {
        guard !blockedByScheduler("重算预判") else { return }
        runPhaseNative(key: "predict", successMessage: "预判已重算") { params in
            try PhasePredict.predict(persist: true, params: params)
        }
    }

    func recomputeVerify() {
        guard !blockedByScheduler("重算验证") else { return }
        runPhaseNative(key: "verify", successMessage: "验证已重算") { params in
            try PhaseVerify.verify(persist: true, params: params)
        }
    }

    func recomputeReview() {
        guard !blockedByScheduler("重算复盘") else { return }
        runPhaseNative(key: "review", successMessage: "复盘已重算") { params in
            try PhaseReview.review(persist: true, params: params)
        }
    }

    /// 四阶段重算的**统一入口**：历史模式禁止（写操作）、busy 互斥、成功才刷新；
    /// 提示直接给出阶段摘要（判定/复盘的结果比"完成"更有信息量）。
    ///
    /// ⚠ 四个阶段都**同步阻塞**（行情/日K/分时 + 落库），必须放后台线程。
    func runPhaseNative(key: String, successMessage: String,
                                run: @escaping @Sendable ([String: Any]) throws -> [String: Any]) {
        guard !isHistorical else {
            lastError = "历史模式下不可执行写操作，请先回到最新交易日"
            lastErrorKey = key
            ToastCenter.shared.show(lastError ?? "未执行", style: .warning)
            return
        }
        guard !busy.contains(key) else { return }
        // 历史回放进行中：拒绝阶段重算（理由见 `Scheduler.execute` 同一处）。
        // ⚠ 判据是 `isBusy`，不能只查 `activeDay`（天与天之间它是空的）。
        if HistoryReplayMode.isBusy {
            let day = HistoryReplayMode.activeDay ?? "整段回放会话"
            lastError = "历史回放进行中（\(day)），暂不可重算阶段"
            lastErrorKey = key
            ToastCenter.shared.show(lastError ?? "未执行", style: .error)
            return
        }
        guard let params = ParamStore.shared.activeParams() else {
            lastError = "激活参数不可读（数据库与随包文件都读不到），\(key) 未执行"
            lastErrorKey = key
            ToastCenter.shared.show(lastError ?? "未执行", style: .error)
            return
        }
        busy.insert(key)
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome: (JSONValue?, String?) = {
                do { return (JSONValue(try run(params)), nil) }
                catch { return (nil, (error as? LocalizedError)?.errorDescription
                                ?? String(describing: error)) }
            }()
            await MainActor.run {
                guard let self else { return }
                self.busy.remove(key)
                guard let json = outcome.0 else {
                    // 抛错（I/O / 取数异常）→ 直接报错
                    self.lastError = "\(key)失败：\(outcome.1 ?? "未知")"
                    self.lastErrorKey = key
                    ToastCenter.shared.show(self.lastError ?? "失败", style: .error)
                    return
                }
                if self.lastErrorKey == key { self.lastError = nil; self.lastErrorKey = nil }
                self.refresh()
                ToastCenter.shared.show(Self.phaseSummary(key: key, json: json) ?? successMessage)
            }
        }
    }

    /// 四阶段的提示摘要（比"完成"更能一眼看出结果；取不到就回退到默认提示）。
    /// ⚠ 整段走实体：裸键名写错只会**安静地显示 0 / "-"**，实体有编译期检查。
    static func phaseSummary(key: String, json: JSONValue) -> String? {
        switch key {
        case "predict":
            let r = PredictResult(json)
            return "预判：\(r.marketLightDash)｜标的 \(r.stocks.count) 只"
        case "verify":
            let t = VerifyResult(json).stats.total
            return "验证：总体胜率 \(t.winrate)%（\(t.verified) 只有效）"
        case "review":
            let fl = ReviewResult(json).fourLayerWinrate
            return "复盘：窗口胜率 \(fl.window.winrate)%｜纪律口径 \(fl.disciplined.winrate)%"
        case "iterate":
            let r = IterateResult(json)
            return r.status == "already_done"
                ? "迭代：今日已完成（幂等，计数器未变）"
                : "迭代：计数器 \(r.counter)｜\(r.statusDash)"
        default:
            return nil
        }
    }

    func recomputeIterate() {
        guard !blockedByScheduler("重算迭代") else { return }
        runPhaseNative(key: "iterate", successMessage: "迭代报告已更新") { params in
            try PhaseIterate.iterate(persist: true, params: params)
        }
    }

    /// 数据源自检：原生直探数据源。
    ///
    /// 探测是**同步阻塞**的（HTTP 请求，最坏情况十几秒）→ 必须放后台线程。
    /// 实现不会抛错（取数失败即该渠道 ok=false，报告本身仍是有效结论）
    /// —— FAIL 报告就是结论，不是错误。
    func runSelftest() {
        guard !busy.contains("selftest") else { return }
        busy.insert("selftest")
        Task.detached(priority: .utility) { [weak self] in
            let json = JSONValue(PhaseOps.selftest())
            await MainActor.run {
                guard let self else { return }
                self.busy.remove("selftest")
                self.lastSelftestAt = Date()
                self.selftestReport = json
                ToastCenter.shared.show("数据源检测完成", style: .info)
            }
        }
    }

    /// 1 小时定时自检（设置页常驻数据源健康）
    func startSelftestLoop() {
        guard selftestTimer == nil else { return }
        // ⚠ 必须挂 `.common` 而不是 `Timer.scheduledTimer`：`scheduledTimer` 注册在 run loop 的
        //   **default** 模式 → 滚动 / 拖拽 / 菜单跟踪期间**不触发**
        //   （`Scheduler.swift` 为此用 `Timer(...) + RunLoop.main.add(_:forMode:.common)`）。
        //   1 小时的周期任务被一次拖拽吃掉就白等一小时 —— 而它没有任何报错。
        // ⚠ 有意**不**加 `invalidate()`：`selftestTimer` 是**进程级单例**
        //   （上面 `guard` 保证只建一次），随进程退出自动释放，没有实际收益（不写死代码）。
        let t = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runSelftest() }
        }
        RunLoop.main.add(t, forMode: .common)
        selftestTimer = t
    }

    /// 应用启动后 8 秒做首次自检（避免与启动流程抢资源）
    func scheduleInitialSelftest() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            await MainActor.run {
                guard let self, self.selftestReport == nil else { return }
                self.runSelftest()
            }
        }
    }

    /// 原生激活版本：改 counters 一行，毫秒级完成。
    ///
    /// 无需「延迟后再读一次」的时序兜底 —— 那是针对**子进程写**的；
    /// 原生写是同步提交（`SQLiteWriter.write` 返回时已 COMMIT），且 WAL 下读连接
    /// 每个语句都是新读事务（"写后立即读可见"已验证）。
    func activateParam(_ name: String) {
        runParamWrite(op: "activate", name: name,
                      native: { try ParamStore.shared.activate(name) },
                      successMessage: "已激活版本 \(name)",
                      failMessage: "版本不存在：\(name)")
    }

    /// 原生删除版本（保护「默认」与当前激活版本；出厂版本记墓碑防补种复活）
    func deleteParam(_ name: String) {
        runParamWrite(op: "delete", name: name,
                      native: { try ParamStore.shared.delete(name) },
                      successMessage: "版本已删除",
                      failMessage: "该版本不可删除（默认版本与当前激活版本受保护）")
    }

    /// 参数写操作的统一入口（激活 / 删除）：失败直接报错
    func runParamWrite(op: String, name: String,
                               native: () throws -> Bool,
                               successMessage: String,
                               failMessage: String) {
        let key = "param"
        guard !isHistorical else {
            lastError = "历史模式下不可执行写操作，请先回到最新交易日"
            lastErrorKey = key
            ToastCenter.shared.show(lastError ?? "未执行", style: .warning)
            return
        }
        guard !busy.contains(key) else { return }
        busy.insert(key)
        do {
            let ok = try native()
            busy.remove(key)
            guard ok else {
                lastError = failMessage
                lastErrorKey = key
                // ⚠ 成功路径有 toast，失败也必须补一个：横幅已门控到库级故障，
                //   只写横幅这里会**静默**（用户点了没反应）。补上钉住的 error toast。
                ToastCenter.shared.show(failMessage, style: .error)
                return
            }
            if lastErrorKey == key { lastError = nil; lastErrorKey = nil }
            refreshParams()
            ToastCenter.shared.show(successMessage)
        } catch {
            busy.remove(key)
            let why = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            lastError = "参数操作失败（\(op)）：\(why)"
            lastErrorKey = key
            ToastCenter.shared.show("参数操作失败：\(why)", style: .error)
        }
    }

    /// 丢弃**全部**长连接与目录缓存，下次访问按当前 `DataDirectory.resolve()` 重新解析。
    ///
    /// 存在的理由：只失效一部分会让各 Store 的 `dirPath` 与连接残留 → 换库后"读新库、写旧库"；
    /// 而 `SQLiteWriter.openError` 一旦写入就永久缓存，不清除则首次打不开库之后
    /// 所有写操作永久失败、库恢复也不回来。靠"记得逐个失效"是记不住的 —— 收口成这一个入口。
    ///
    /// 调用时机：导入/迁移换库之后、`SELECTED_DATA_DIR` 变更之后。
    ///
    /// ⚠ 放在 Store 而不是 `DataDirectory.swift`：各对账脚本只编译源文件子集，
    ///   低层的 DataDirectory 必须保持零依赖，不能引用任何 Store 单例。
    static func invalidateAllDataConnections() {
        // ⚠ 清单唯一来源是 `DataConnections`：每条连接在**自己的 init 里登记**
        //   ⇒ "拿得到一条连接"与"换库时它会被放掉"是同件事，新增 Store 不可能只做前者。
        //   原先这里是手写的 20 行点名清单（`XStore.close()` 逐个列），与"谁持有连接"
        //   是两处靠人同步的列表 —— **实测漏过 4 个**：换库后提醒规则/资金流/涨停池/龙虎榜
        //   继续读旧库，数据错位且 openError 被缓存后永不重试。
        DataConnections.closeAll()
    }
}
