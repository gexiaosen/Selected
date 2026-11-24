import Foundation
import SwiftUI
import Observation
import SelectedCore

/// 全局状态（v2 架构）：
/// - 读操作：SQLiteReader 直读（毫秒级）
/// - 写操作：全部原生（后台线程执行，不阻塞 UI）；失败就直接报错，不静默换引擎
/// - 全局查看日期 viewDate：所有页面联动；历史模式（viewDate ≠ 今天）禁用写操作
extension Store {
    // MARK: - 个股详情弹窗（全局唯一入口：任何页面个股行点击触发，AppShell 挂 sheet）

    /// 详情弹窗目标（code 即标识）
    struct StockDetailTarget: Identifiable {
        let code: String
        let name: String
        var id: String { code }
    }

    /// 弹出个股详情（实时行情 + K 线）
    func showStockDetail(code: String, name: String) {
        stockDetail = StockDetailTarget(code: code, name: name)
    }

    func closeStockDetail() { stockDetail = nil }

    // MARK: - 自选股（watch 模块：分组 + 列表 + 每日判定 + 手动持仓）

    func loadWatch() {
        // 三张自选表走库行实体 —— 视图侧不 poke 字符串键。
        // ⚠ 库行与"判定产出"是两回事：这里 `is_holding` 是 Int 0/1（SQL 里就这么存），
        // 而 `WatchVerdict.isHolding` 是 Bool。
        watchGroups = reader.watchGroups().map(WatchGroupRow.init)
        watchItems = reader.watchlist().map(WatchItemRow.init)
        // ⚠ 归属索引：自选列表按它过滤，而不是按 `WatchItemRow.groupId`（那只存**主分组**）。
        watchMemberships = WatchStore.shared.membershipIndex()
        let d = reader.latestWatchDate() ?? today
        watchDate = d
        watchJudgments = reader.watchJudgments(date: d).map(WatchJudgmentRow.init)
        loadAlerts()
        // ⚠ 自选列表一就位就**立刻补一轮行情**。
        //   `liveQuotes` 的唯一来源是 `AlertMonitor` 的常驻轮询，而它在 App 启动那一刻跑第一轮时
        //   `watchItems` 还是空的（本函数要等自选页出现才被调用），那一轮无事可做就按间隔睡下去
        //   ⇒ 刚进自选页价格列全是「—」，要"过一会"才出数。在这里补一次 `kick()`，
        //   把等待压成**一个网络往返**。
        //
        // ⚠ 只在"有新票还没有行情"时踢：否则每次进出本页、每次自选写操作都会多打一次行情接口。
        // ⚠ `tick()` 自带 `ticking` 互斥与 `sessionFired` 去重，重复踢不会重复提醒。
        if watchItems.contains(where: { liveQuotes[$0.code] == nil }) {
            AlertMonitor.shared.kick()
        }
    }

    /// 加载提醒规则（铃铛图标的"已设置 / 未设置"）。
    ///
    /// 与 `loadWatch()` 分开：弹窗保存后只刷这一项（不需要重读分组/自选/判定三张表）。
    ///
    /// ⚠ 两张表**一起读**（规则 + 时间窗）：设置页的「提醒一览」两个都要显示，
    ///   分两次读会让"规则有了、时间窗还是旧的"这种中间态被渲染出来。
    func loadAlerts() {
        alertRulesByCode = AlertStore.rulesByCode()
        alertWindowsByCode = AlertStore.windowsByCode()
    }

    /// 自选页每次进入时刷新
    func refreshWatch() { loadWatch() }

    /// 自选写操作（返回错误串、空串 = 成功）的统一入口：原生抛错直接报错。
    ///
    /// 关键取舍与参数中心一致：原生返回的**非空错误串是有效结论**
    /// （代码为空 / 分组已存在 / 股票不在自选中…），直接展示、不回落 ——
    /// 回落只会拿到同一条拒绝；只看进程退出码会把错误当成功 → **假成功**。
    ///
    /// 自选操作与全局查看日期无关（`allowHistorical`）。
    @discardableResult
    func runWatchWrite(native: () throws -> String,
                               successMessage: String,
                               key: String = "watch") -> Bool {
        guard !busy.contains(key) else { return false }
        busy.insert(key)
        do {
            let err = try native()
            busy.remove(key)
            guard err.isEmpty else {
                lastError = err
                lastErrorKey = key
                ToastCenter.shared.show(err, style: .error)
                return false
            }
            if lastErrorKey == key { lastError = nil; lastErrorKey = nil }
            loadWatch()
            ToastCenter.shared.show(successMessage)
            return true
        } catch {
            busy.remove(key)
            let why = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            lastError = "自选写入失败：\(why)"
            lastErrorKey = key
            ToastCenter.shared.show(lastError ?? "写入失败", style: .error)
            return false
        }
    }

    /// 加入自选（指定分组）
    ///
    /// 名称解析：UI 通常从证券列表带过来；为空时先查本地证券列表（毫秒级）。
    /// 仍解析不到就**直接拒绝** —— 原生写入不会去拉行情，不能往库里塞空名字。
    func addWatch(code: String, name: String, group: Int = 1) {
        // ⚠ 已在自选的票再加一次，`WatchStore.add` 的 UPSERT 会**静默成功**
        //   ⇒ 提示"已加入自选"，用户以为新增了一条（实际什么都没变）。
        //   这里先查在册状态，给出诚实文案并跳过写库（拖放路径在 `addWatchByCode` 里已提前拦）。
        if isInWatchlist(code) {
            ToastCenter.shared.show("已在自选里，未重复添加", style: .info)
            return
        }
        var resolved = name
        if resolved.isEmpty {
            loadStockList()
            resolved = stockList.first { $0["code"].string == code }?["name"].string ?? ""
        }
        // ⚠ 没有任何网络写路径：拿不到名字就直接拒绝（不静默塞空名字，也不假装成功）
        guard !resolved.isEmpty else {
            lastError = "\(code) 的名称未知（本地证券列表未命中），无法加入自选"
            lastErrorKey = "watch"
            ToastCenter.shared.show("加入自选失败：名称未知", style: .error)
            return
        }
        runWatchWrite(native: { try WatchStore.shared.add(code: code, name: resolved, group: group) },
                      successMessage: "已加入自选")
    }

    /// 「直接按代码加自选」：先实时行情取名称，取不到就交给 `addWatch` 明确拒绝。
    ///
    /// ⚠ 唯一入口，统一"取不到就拒绝"语义 —— 绝不把代码当名字写进库（脏数据）。
    ///
    /// ⚠ **为什么必须先取行情**（不能只靠 `addWatch` 的本地兜底）：本地 `securities` 只有
    ///   A 股 / 场内基金，**港股（hk 前缀）等不在里面** ⇒ 只用本地兜底会把这些代码误拒。
    func addWatchByCode(_ code: String, group: Int) async {
        // ⚠ 提前拦一次（在**联网取名称之前**）：省一次行情请求（源限流时尤其值钱），
        //   且拖放/搜索两条路径文案一致（`addWatch` 里还有一道兜底）。
        if isInWatchlist(code) {
            ToastCenter.shared.show("已在自选里，未重复添加", style: .info)
            return
        }
        let quote = await QuoteAPI.single(code)
        // ⚠ 取不到名称 ⇒ 传**空串**（不是 code！）让 `addWatch` 走
        //   "本地列表兜底 → 仍没有则明确拒绝"这条路 —— 绝不把代码当名字写进库。
        addWatch(code: code, name: quote?.name ?? "", group: group)
    }

    /// 该代码是否已在自选（**大小写不敏感** —— 港股/基金代码可能带前缀大小写差异）。
    /// 用途：重复添加的诚实提示（「已在自选的再加一次」不应报成新增）。
    func isInWatchlist(_ code: String) -> Bool {
        watchItems.contains { $0.code.caseInsensitiveCompare(code) == .orderedSame }
    }

    /// 移出自选。
    ///
    /// ⚠ 连同该票的提醒规则与时间窗在 `WatchStore.remove` 同一写事务里清理：
    ///   `AlertMonitor` 轮询的是「自选 ∪ 配了提醒的代码」，留着规则会让已经不在自选里的票继续弹提醒。
    func removeWatch(code: String) {
        // ⚠ 快照必须在移出之前取 —— 移出后 `watchItems` / 提醒缓存里就没有它了
        let snap = captureWatchRemoval(code: code)
        let ok = runWatchWrite(native: {
            try WatchStore.shared.remove(code: code)
        }, successMessage: "已移出自选")
        // ⚠ 只有**真的成功**才登记撤销 —— 失败还登记，会让 Cmd+Z 去"撤销"一件没发生的事
        if ok, let snap { registerRestoreUndo(snap) }
    }

    // MARK: 撤销（Cmd+Z 恢复「移出自选 / 清仓」）

    /// 「移出自选」的撤销快照：行数据 + **提醒规则**。
    /// ⚠ 提醒必须一起恢复：`removeWatch` 会把该票的提醒一起删（有意设计），
    ///   撤销若只把票放回来，"票回来了、提醒没了" —— 用户往往直到漏掉一次提醒才发现。
    struct WatchRemovalSnapshot {
        let code: String
        let name: String
        let group: Int
        let alertRules: [AlertRule]
        let alertWindow: AlertWindow
    }

    /// 「清仓」的撤销快照（成本价 / 股数）
    struct HoldingSnapshot {
        let code: String
        let cost: Double
        let shares: Double
    }

    /// 取「移出自选」快照（行上已查不到 → `nil`，不登记撤销）
    func captureWatchRemoval(code: String) -> WatchRemovalSnapshot? {
        guard let row = watchItems.first(where: { $0.code == code }) else { return nil }
        return WatchRemovalSnapshot(
            code: code,
            name: row.name,          // ⚠ 原样（不折成 displayName）—— 撤销是"恢复当时的状态"
            group: row.groupId,
            alertRules: alertRulesByCode[code] ?? [],
            alertWindow: alertWindowsByCode[code] ?? .anytime)
    }

    /// 取「清仓」快照（成本价与股数都为 0 = 本来就没有持仓数据 → 不登记撤销）
    func captureHoldingClear(code: String) -> HoldingSnapshot? {
        guard let row = watchItems.first(where: { $0.code == code }),
              row.costPrice > 0 || row.shares > 0 else { return nil }
        return HoldingSnapshot(code: code, cost: row.costPrice, shares: row.shares)
    }

    /// 恢复一只被移出的票（撤销「移出自选」的唯一入口；成功后登记它的逆操作 = 重做）
    func restoreWatch(_ snap: WatchRemovalSnapshot) {
        let ok = runWatchWrite(native: {
            let err = try WatchStore.shared.add(code: snap.code, name: snap.name, group: snap.group)
            guard err.isEmpty else { return err }
            if !snap.alertRules.isEmpty {
                _ = try AlertStore.save(code: snap.code,
                                        drafts: snap.alertRules.map(\.draft),
                                        window: snap.alertWindow,
                                        at: WatchStore.timestamp())
            }
            return ""
        }, successMessage: "已撤销移出")
        if ok { registerRemovalUndo(snap) }
    }

    /// 恢复持仓（撤销「清仓」的唯一入口）
    func restoreWatchHolding(_ snap: HoldingSnapshot) {
        let ok = runWatchWrite(native: {
            try WatchStore.shared.setHolding(code: snap.code, cost: snap.cost, shares: snap.shares)
        }, successMessage: "已撤销清仓")
        if ok { registerClearUndo(snap) }
    }

    // ⚠ UndoManager 的标准配对：在**撤销处理器里**再注册一次，登记到的就是"重做"。
    //   四个函数两两成对，处理器一律调**公开动作**（`removeWatch` / `restoreWatch` / …），
    //   由动作自己在成功时登记逆操作 —— 不在处理器里手写第二份写库逻辑。
    private func registerRestoreUndo(_ snap: WatchRemovalSnapshot) {
        undoManager?.registerUndo(withTarget: self) { store in
            store.restoreWatch(snap)
        }
        undoManager?.setActionName("移出自选")
    }

    private func registerRemovalUndo(_ snap: WatchRemovalSnapshot) {
        undoManager?.registerUndo(withTarget: self) { store in
            store.removeWatch(code: snap.code)
        }
        undoManager?.setActionName("移出自选")
    }

    private func registerRestoreHoldingUndo(_ snap: HoldingSnapshot) {
        undoManager?.registerUndo(withTarget: self) { store in
            store.restoreWatchHolding(snap)
        }
        undoManager?.setActionName("清仓")
    }

    private func registerClearUndo(_ snap: HoldingSnapshot) {
        undoManager?.registerUndo(withTarget: self) { store in
            store.clearWatchHolding(code: snap.code)
        }
        undoManager?.setActionName("清仓")
    }

    // MARK: 提醒（用户自定义告警）

    /// 保存某只票的提醒（**全量替换**该票的规则；`drafts` 为空 = 取消该票全部提醒）。
    ///
    /// 返回空串 = 成功（与 `runWatchWrite` 同口径）；失败走 toast，不静默。
    func saveAlerts(code: String, drafts: [AlertDraft], window: AlertWindow,
                    successMessage: String) {
        let key = "alert"
        guard !busy.contains(key) else { return }
        busy.insert(key)
        defer { busy.remove(key) }
        do {
            _ = try AlertStore.save(code: code, drafts: drafts, window: window,
                                    at: WatchStore.timestamp())
            loadAlerts()
            // 规则刚改完 → 立刻重算一轮，把最长 60s 的退避压掉
            // （`AlertStore.save` 已把未变规则的触发状态继承过来，故不会因此重复响）
            AlertMonitor.shared.kick()
            ToastCenter.shared.show(successMessage)
        } catch {
            let why = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            ToastCenter.shared.show("提醒保存失败：\(why)", style: .error)
        }
    }

    /// **组内移动**：从 `from` 组移走 + 加到 `to` 组，**其它归属保留**
    /// （只在作出操作的组操作）。例：某股同时在 A、B 两组，在 **A 组**里右键「移动到 C」⇒ 变成 **B、C**。
    ///
    /// ⚠ 与 Core 的 `move(code:group:)` **不是一回事**：后者**重置全部归属**（单归属语义，
    ///   对账驱动调的是它）。界面走本方法。
    func moveWatch(code: String, from: Int, to: Int) {
        runWatchWrite(native: { try WatchStore.shared.moveWithin(code: code, from: from, to: to) },
                      successMessage: "已移动到「\(groupName(to))」")
    }

    /// **复制**到分组：加到目标分组，**其它归属全部保留**（一只股票可以同时在多个分组）。
    func copyWatch(code: String, to: Int) {
        runWatchWrite(native: { try WatchStore.shared.copyTo(code: code, group: to) },
                      successMessage: "已复制到「\(groupName(to))」")
    }

    /// 分组 id → 名称。找不到就回落到 `分组 N`（**不静默吞**，名字对不上能一眼看出来）。
    private func groupName(_ id: Int) -> String {
        watchGroups.first { $0.id == id }?.name ?? "分组 \(id)"
    }

    // MARK: 分组管理

    @discardableResult
    func addWatchGroup(name: String) -> Bool {
        runWatchWrite(native: { try WatchStore.shared.groupAdd(name: name) },
                      successMessage: "分组已创建")
    }

    @discardableResult
    func renameWatchGroup(id: Int, name: String) -> Bool {
        runWatchWrite(native: { try WatchStore.shared.groupRename(id: id, name: name) },
                      successMessage: "分组已重命名")
    }

    /// 删除分组（引擎连组内股票一并删除；UI 负责二次确认）
    func deleteWatchGroup(id: Int) {
        runWatchWrite(native: { try WatchStore.shared.groupDelete(id: id) },
                      successMessage: "分组已删除")
    }

    // MARK: 手动持仓（仅 UI 盈亏显示；引擎信号判定独立）

    func setWatchHolding(code: String, cost: Double, shares: Double) {
        runWatchWrite(native: { try WatchStore.shared.setHolding(code: code, cost: cost, shares: shares) },
                      successMessage: "持仓已保存")
    }

    func clearWatchHolding(code: String) {
        let snap = captureHoldingClear(code: code)
        let ok = runWatchWrite(native: { try WatchStore.shared.clearHolding(code: code) },
                               successMessage: "已清仓（移出持仓视图）")
        if ok, let snap { registerRestoreHoldingUndo(snap) }
    }

    // MARK: 判定

    /// 全量判定（手动触发；调度 14:50 自动跑）
    func runWatchJudge() {
        // allowHistorical：自选判定是对**今天**的操作，与全局查看日期无关——
        // 其他页面选了历史日期不应拦截自选页的手动判定。
        guard !blockedByScheduler("手动判定") else { return }
        runWatchJudgeNative(code: nil, key: "watch", successMessage: "全量判定完成")
    }

    /// 单股判定（列表行手动触发）
    func runWatchJudge(code: String) {
        runWatchJudgeNative(code: code, key: "watch-\(code)", successMessage: "判定完成")
    }

    /// 原生自选判定。
    ///
    /// busy 互斥、成功才刷新；提示直接显示判定摘要（"买入 1 · 卖出 3 · 大盘黄灯"），
    /// 比只说"完成"更能一眼看出今天有没有动作。
    ///
    /// ⚠ 判定是**同步阻塞**的（逐只拉行情 + 日K + 落库），必须放后台线程。
    func runWatchJudgeNative(code: String?, key: String, successMessage: String) {
        guard !busy.contains(key) else { return }
        // ⚠ 回放进行中不可手动判定（2026-10-16 审查 B6 补漏）：
        //   `WatchJudge` 读的是 `DataSources.fetchIndexQuote()`，那个函数**会**在回放模式
        //   下返回回放日的大盘环境；而自选价走 `QuoteAPI.batch`，那条**不查**回放开关、
        //   仍是今日实价。两者混在一行 `watch_judgments` 里写进库，事后无法区分是哪天判的。
        //   调度侧已有同一守卫（`Scheduler.execute`），手动侧此前只有
        //   `blockedByScheduler`（它只查调度任务在飞，手动回放时为空 ⇒ 拦不住）。
        //   同纪律的其它手动入口（板块/指标快照/调优/阶段重算）都各自查了 `isBusy`。
        if HistoryReplayMode.isBusy {
            let day = HistoryReplayMode.activeDay ?? "整段回放会话"
            lastError = "历史回放进行中（\(day)），自选判定已拒绝以避免混口径落库"
            lastErrorKey = key
            ToastCenter.shared.show("历史回放进行中，暂不可手动判定", style: .warning)
            return
        }
        guard let params = ParamStore.shared.activeParams() else {

            lastError = "激活参数不可读（数据库与随包文件都读不到），判定未执行"
            lastErrorKey = key
            ToastCenter.shared.show("判定未执行：激活参数不可读", style: .error)
            return
        }
        busy.insert(key)
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome: (JSONValue?, String?) = {
                do {
                    return (JSONValue(try WatchJudge.judge(code: code, params: params)), nil)
                } catch {
                    return (nil, (error as? LocalizedError)?.errorDescription
                            ?? String(describing: error))
                }
            }()
            await MainActor.run {
                guard let self else { return }
                self.busy.remove(key)
                if let json = outcome.0 {
                    if self.lastErrorKey == key { self.lastError = nil; self.lastErrorKey = nil }
                    self.loadWatch()
                    // 走 `WatchJudgeResult` 实体
                    let summary = WatchJudgeResult(json).summary
                    ToastCenter.shared.show(summary.isEmpty ? successMessage : summary)
                    return
                }
                // 抛错（I/O / 取数异常）→ 直接报错
                self.lastError = "判定失败：\(outcome.1 ?? "未知")"
                self.lastErrorKey = key
                ToastCenter.shared.show(self.lastError ?? "判定失败", style: .error)
            }
        }
    }

}
