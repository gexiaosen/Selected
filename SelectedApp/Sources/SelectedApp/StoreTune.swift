import Foundation
import SwiftUI
import Observation
import SelectedCore

/// 全局状态（v2 架构）：
/// - 读操作：SQLiteReader 直读（毫秒级）
/// - 写操作：全部原生（后台线程执行，不阻塞 UI）；失败就直接报错，不静默换引擎
/// - 全局查看日期 viewDate：所有页面联动；历史模式（viewDate ≠ 今天）禁用写操作
extension Store {
    // MARK: - 参数调优

    /// 运行调优（全局参数：以激活版本为基线，结果存为全局新版本）。
    ///
    /// 调优是纯本地重放计算 —— 不联网、不写库，秒级完成；参数不可读或计算抛错都直接报错。
    ///
    /// - Parameter includeReplay: 样本池是否纳入**历史回放样本**。
    ///   默认 `false`（只用 live）。回放是**收盘价口径**、live 是**尾盘盘中口径**，
    ///   混池得到的"最优参数"是两种口径的平均。参数中心调优面板的开关会传进来；
    ///   引擎侧还有工厂参数 `iterate.include_replay` 作为程序化调用的默认值。
    ///
    /// ⚠ 调优是同步阻塞的（随 trials/hill 从毫秒到数秒），必须放后台线程。
    func runTune(includeReplay: Bool = false) {
        guard !tuneRunning else { return }
        tuneRunning = true
        tuneReport = nil
        lastError = nil
        busy.insert("tune")
        guard ParamStore.shared.activeParams() != nil else {
            lastError = "激活参数不可读（数据库与随包文件都读不到），调优未执行"
            lastErrorKey = "tune"
            tuneRunning = false
            busy.remove("tune")
            ToastCenter.shared.show("调优未执行：激活参数不可读", style: .error)
            return
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome: (JSONValue?, String?) = {
                do {
                    return (JSONValue(try PhaseTune.tune(
                        includeReplayOverride: includeReplay)), nil)
                } catch {
                    return (nil, (error as? LocalizedError)?.errorDescription
                            ?? String(describing: error))
                }
            }()
            await MainActor.run {
                guard let self else { return }
                if let json = outcome.0 {
                    self.tuneRunning = false
                    self.busy.remove("tune")
                    if self.lastErrorKey == "tune" { self.lastError = nil; self.lastErrorKey = nil }
                    let tune = TuneResult(json)
                    if !tune.isOK {
                        // 空池是**有效结论**（样本不足），直接展示原因，不回落
                        // ⚠ `errorDash` 缺失时是哨兵 "-"、字段存在但为空时是 "" —— 两种都**不是错误**；
                        //   无条件写进 lastError 会让页面错误横幅（判据 `lastError != nil`）
                        //   渲染出一条无内容的空条 ⇒ 只有拿到真错误文案才落 lastError。
                        let msg = tune.errorDash
                        if msg != "-", !msg.isEmpty {
                            self.lastError = msg
                            self.lastErrorKey = "tune"
                            // 空池是**有效结论**（样本不足），不是告警 ⇒ 中性提醒档
                            // （横幅已门控到库级故障，不补 toast 就静默了）。
                            ToastCenter.shared.show(msg, style: .warning)
                        }
                    } else {
                        self.tuneReport = tune
                    }
                    return
                }
                // 调优抛错（I/O / 计算异常）→ 直接报错，不静默
                self.tuneRunning = false
                self.busy.remove("tune")
                self.lastError = "调优失败：\(outcome.1 ?? "未知")"
                self.lastErrorKey = "tune"
                ToastCenter.shared.show(self.lastError ?? "调优失败", style: .error)
            }
        }
    }

    /// 应用调优候选（全局落点）：diff 另存为新版本（可选激活）
    @discardableResult
    func applyTuneCandidate(versionName: String, diff: [String: Any], activate: Bool = true) -> Bool {
        saveGlobalParams(name: versionName, diff: diff, activate: activate)
    }

    func manualRunRound(slot: Int) {
        // 重入守卫：连点按钮会重复拉起引擎并重复 refresh
        guard !busy.contains("round") else { return }
        // 与调度器互斥：调度器可能正在跑同一轮
        guard !blockedByScheduler("手动扫描") else { return }
        runRoundNative(slot: slot, successMessage: "第\(slot)轮扫描完成")
    }

    /// 原生轮次扫描的统一入口：激活参数不可读即失败并提示。
    ///
    /// 语义（这条是**主路径**，任何一条漏掉都会造成静默故障）：
    ///   · 历史模式禁止（`allowHistorical` 默认 false）
    ///   · `busy["round"]` 互斥、成功才刷新 UI + 弹提示
    ///   · status 三态都按**失败**处理且如实告知：`not_trading_day` / `data_insufficient` /
    ///     `persist_failed`（落库失败时 runScan 不抛错而是置状态，必须当成失败，
    ///     否则界面会显示"扫描完成"而库里其实没有这一轮）
    ///
    /// ⚠ 整轮扫描是**同步阻塞**的（网络 + 落库），必须放后台线程 —— 主线程会被卡住数十秒。
    func runRoundNative(slot: Int, successMessage: String,
                                onFinish: (@MainActor (Bool) -> Void)? = nil) {
        let key = "round"
        guard !isHistorical else {
            lastError = "历史模式下不可执行写操作，请先回到最新交易日"
            lastErrorKey = key
            ToastCenter.shared.show(lastError ?? "扫描未执行", style: .warning)
            onFinish?(false)
            return
        }
        guard !busy.contains(key) else { return }
        // 历史回放进行中：拒绝手动扫描（理由见 `Scheduler.execute` 同一处 —— 回放是
        // 进程级开关，此刻扫描会把重建出来的历史行情当成今天写进库）。
        // ⚠ 判据是 `isBusy`，不能只查 `activeDay`（天与天之间它是空的）。
        if HistoryReplayMode.isBusy {
            let day = HistoryReplayMode.activeDay ?? "整段回放会话"
            lastError = "历史回放进行中（\(day)），暂不可手动扫描"
            lastErrorKey = key
            ToastCenter.shared.show(lastError ?? "扫描未执行", style: .error)
            onFinish?(false)
            return
        }
        // 归属边界与调度设置的轮次时间联动（引擎 resolve_slot 按此判定轮次）
        let boundaries = ScheduleTimes.shared.roundBoundaries.joined(separator: ",")
        guard let params = ParamStore.shared.activeParams() else {
            // 参数不可读（库与随包文件都取不到）→ 明确报错，不静默跳过
            lastError = "激活参数不可读（数据库与随包文件都读不到），第\(slot)轮未执行"
            lastErrorKey = key
            ToastCenter.shared.show(lastError ?? "扫描未执行", style: .error)
            onFinish?(false)
            return
        }
        let version = ParamStore.shared.activeName()
        busy.insert(key)
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = ScanRunner.runRound(params: params, paramVersion: version,
                                             slot: slot, boundaries: boundaries)
            // 在后台线程就装进 JSONValue（`@unchecked Sendable`）再跨隔离域送 ——
            // 裸 `[String: Any]` 不是 Sendable，Swift 6 会拒绝（sending 数据竞争）
            let json = JSONValue(result)
            await MainActor.run {
                guard let self else { return }
                self.finishRound(slot: slot, json: json,
                                 successMessage: successMessage, onFinish: onFinish)
            }
        }
    }

    /// 原生轮次的收尾（状态判定 + 刷新 + 提示）。**先释放 busy 再回调 onFinish** ——
    /// 补跑链是在 onFinish 里启动下一轮的，busy 没释放会被自己的重入守卫挡住。
    func finishRound(slot: Int, json: JSONValue, successMessage: String,
                             onFinish: (@MainActor (Bool) -> Void)?) {
        let key = "round"
        busy.remove(key)
        var ok = true
        // 状态判定走 `ScanResult` 实体：裸键名写错只会**安静地走到 default 分支**（当成成功）。
        let r = ScanResult(json)
        switch r.status {
        case "not_trading_day":
            lastError = "今日非交易日，引擎已跳过"
            lastErrorKey = key
            ToastCenter.shared.show("今日非交易日，引擎已跳过", style: .warning)
            ok = false
        case "data_insufficient":
            // 健全性闸门：全量行情不足阈值，本轮未落库（避免假轮次污染迭代/调优）
            lastError = r.dataErrorDash
            lastErrorKey = key
            ToastCenter.shared.show(r.dataErrorDash, style: .error)
            ok = false
        case "persist_failed":
            lastError = "本轮未落库：\(r.persistErrorDash)"
            lastErrorKey = key
            ToastCenter.shared.show("本轮未落库：\(r.persistErrorDash)", style: .error)
            ok = false
        default:
            if lastErrorKey == key { lastError = nil; lastErrorKey = nil }
            refresh()
            loadRound(slot: slot)
            ToastCenter.shared.show(successMessage)
        }
        onFinish?(ok)
    }

}
