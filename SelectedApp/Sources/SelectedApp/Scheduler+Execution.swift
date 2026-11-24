import Foundation
import os
import SelectedCore

// MARK: - 任务执行分派

extension Scheduler {

    /// 执行任务：**全部原生**。
    ///
    /// 参数不可读 / 原生抛错 → 直接按失败处理（`finish(ok: false)`），由既有的
    /// "窗口内自动重试"逻辑接手 —— 不静默回落（静默回落会掩盖原生 bug）。
    func execute(_ task: Task) {
        runningTaskId = task.id
        lastError = nil

        // 历史回放进行中：**拒绝一切实时任务**
        //
        // 回放是**进程级**开关（`HistoryReplayMode`），激活期间 `DataSources.runDate()`
        // 返回回放日、行情由日K重建。若此刻照常跑，这一轮会把**重建出来的历史行情
        // 当成今天**写进 `scan_rounds` / `picks` / `reviews` —— 而库里没有任何标记
        // 能事后区分"这轮是回放污染的"。
        // 宁可这一轮显式失败（失败是可见的、可重试的），也不要一条假记录。
        // ⚠ 判据是 `isBusy`（`isRunning || isActive`），**不能只查 `activeDay`**：
        //   编排器在**天与天之间**会清掉 `activeDay`（扫描用 D、预判/复盘用 D+1，两段各
        //   begin/end 一次），定时器正好可能在那个空隙里触发 —— 那时若只查 `activeDay`
        //   就会放行一轮**实时扫描**，把实盘行情写进库，而回放正跑到一半。
        if HistoryReplayMode.isBusy {
            let day = HistoryReplayMode.activeDay ?? "（整段回放会话中）"
            finish(task: task, ok: false, json: nil,
                   errorMessage: "历史回放进行中（\(day)），本轮 \(task.id) 被拒绝以避免污染")
            return
        }

        guard let params = ParamStore.shared.activeParams() else {
            finish(task: task, ok: false, json: nil,
                   errorMessage: "激活参数不可读（数据库与随包文件都读不到），任务未执行")
            return
        }

        // ⚠ 取消盒：**所有分支共用**（审查 #12）。
        //   为什么必须是盒：任务执行体全同步、跑在 `Task.detached` 里，
        //   `stop()` 的 `runningTask?.cancel()` 只给 Task 打标记，同步调用链读不到
        //   ⇒ 用一个可变 box 持有取消标志（`Task.isCancelled` 是实例属性，
        //   detached 闭包里没有 `self` 可取它），Core 在每个检查点读一次。
        //   原先只有轮次分支接线，watch/compare/fundflow 等"无取消通道"，
        //   退出后后台照跑照写（SQLite 事务只保证库不损坏，拦不住任务本身）。
        //   ⚠ 四阶段（predict/verify/review/iterate）是 DB 计算为主、秒级收尾，
        //   未接 `shouldStop` 检查点：盒子照常置位，进程退出即终止，不追求秒级响应。
        let box = CancellationBox()
        inFlightCancelBox = box          // stop() 直接置位（见 stop()）
        let shouldStop: @Sendable () -> Bool = { box.isCancelled }

        // 轮次扫描：归属边界由调度设置推导（与轮次时间联动）
        if RoundPlan.isRound(key: task.id) {
            // ⚠ 槽位取不出来时**显式失败**，不回落第 1 轮：原先 `Int(args.last) ?? 1` 会在
            //   args 形状变化时静默把一轮写成 `slot=1` —— 而 `slot` 决定三轮持续判定，
            //   错位的记录在库里和界面上都看不出来。
            guard let slot = task.slot else {
                finish(task: task, ok: false, json: nil,
                       errorMessage: "轮次任务 \(task.id) 取不到槽位号（RoundPlan 与任务注册表不一致），未执行")
                return
            }
            let boundaries = ScheduleTimes.shared.roundBoundaries.joined(separator: ",")
            let version = ParamStore.shared.activeName()
            // ⚠ 句柄收口到 `runningTask`：`stop()` 可取消在飞任务。`[weak self]` 与仓库其余 detached 用法一致。
            //   取消经共享的 `shouldStop`（见 execute 开头）透传：`ScanRunner` 每批请求前读一次
            //   ⇒ 取消响应时间从「整轮 40~60 秒」降到「单批 1~2 秒」。
            runningTask = Swift.Task.detached(priority: .userInitiated) { [weak self] in
                let result = ScanRunner.runRound(params: params, paramVersion: version,
                                                 slot: slot, boundaries: boundaries,
                                                 shouldStop: shouldStop)
                // 在后台线程就装进 JSONValue（`@unchecked Sendable`）再跨隔离域送 ——
                // 裸 `[String: Any]` 不是 Sendable，Swift 6 会拒绝（sending 数据竞争）
                let json = JSONValue(result)
                await MainActor.run {
                    self?.finish(task: task, ok: true, json: json, errorMessage: nil)
                }
            }
            return
        }

        // 自选判定（逐只拉行情 + 日K + 落库，同步阻塞）
        if task.id == "watch" {
            runningTask = Swift.Task.detached(priority: .userInitiated) { [weak self] in
                let outcome: (JSONValue?, String?) = {
                    do {
                        return (JSONValue(try WatchJudge.judge(code: nil, params: params,
                                                               shouldStop: shouldStop)), nil)
                    } catch {
                        return (nil, (error as? LocalizedError)?.errorDescription
                                ?? String(describing: error))
                    }
                }()
                await MainActor.run {
                    guard let json = outcome.0 else {
                        self?.finish(task: task, ok: false, json: nil,
                                     errorMessage: "判定失败：\(outcome.1 ?? "未知")")
                        return
                    }
                    self?.finish(task: task, ok: true, json: json, errorMessage: nil)
                }
            }
            return
        }

        // 三轮对比（读库 → 计算 → 落库；毫秒级但仍在后台跑，与手动入口同一份实现）
        if task.id == "compare" {
            runningTask = Swift.Task.detached(priority: .userInitiated) { [weak self] in
                let outcome: (JSONValue?, String?) = {
                    do {
                        return (JSONValue(try CompareStore.runOnce(date: ChinaTime.day(),
                                                                   shouldStop: shouldStop)), nil)
                    } catch {
                        return (nil, (error as? LocalizedError)?.errorDescription
                                ?? String(describing: error))
                    }
                }()
                await MainActor.run {
                    guard let json = outcome.0 else {
                        self?.finish(task: task, ok: false, json: nil,
                                     errorMessage: "对比失败：\(outcome.1 ?? "未知")")
                        return
                    }
                    self?.finish(task: task, ok: true, json: json, errorMessage: nil)
                }
            }
            return
        }

        // 收盘后资金流向
        //
        // ⚠ **独立任务，不是四阶段的一部分**（刻意）：
        //   它是收盘后的**时点数据**抓取，失败与复盘/迭代毫无关系。
        //   挂进 `PhaseReview` 会让"新浪接口挂了"变成"收盘复盘失败" ——
        //   既误导用户，又会让复盘的重试次数被资金流消耗掉。
        //   独立任务 ⇒ 独立状态 ⇒ 互不牵连（见 `FundFlowJob` 类注释）。
        if task.id == "fundflow" {
            runningTask = Swift.Task.detached(priority: .userInitiated) { [weak self] in
                let outcome: ([String: Any]?, String?) = {
                    do { return (try FundFlowJob.run(shouldStop: shouldStop), nil) }
                    catch { return (nil, (error as? LocalizedError)?.errorDescription
                                    ?? String(describing: error)) }
                }()
                await MainActor.run {
                    guard let json = outcome.0 else {
                        self?.finish(task: task, ok: false, json: nil,
                                     errorMessage: "资金流向失败：\(outcome.1 ?? "未知")")
                        return
                    }
                    self?.finish(task: task, ok: true, json: JSONValue(json), errorMessage: nil)
                }
            }
            return
        }

        // 收盘后龙虎榜
        //
        // ⚠ 同样**独立任务**（理由见 `LhbJob` 类注释）：收盘后时点数据，与复盘/迭代无关。
        if task.id == "lhb" {
            runningTask = Swift.Task.detached(priority: .userInitiated) { [weak self] in
                let outcome: ([String: Any]?, String?) = {
                    do { return (try LhbJob.run(shouldStop: shouldStop), nil) }
                    catch { return (nil, (error as? LocalizedError)?.errorDescription
                                    ?? String(describing: error)) }
                }()
                await MainActor.run {
                    guard let json = outcome.0 else {
                        self?.finish(task: task, ok: false, json: nil,
                                     errorMessage: "龙虎榜失败：\(outcome.1 ?? "未知")")
                        return
                    }
                    self?.finish(task: task, ok: true, json: JSONValue(json), errorMessage: nil)
                }
            }
            return
        }

        // 收盘后涨停统计
        //
        // ⚠ 同样**独立任务**（理由见 `LimitUpPoolJob` 类注释）：收盘后时点数据，与复盘/迭代无关。
        //
        // ⚠ **顺手算昨日涨停表现（情绪）**，不另设调度项 ——
        //   输入是「昨日涨停池 + 今日收盘行情」，与本任务同时点、同数据面。
        //   `runQuietly` 任何失败只留痕（`data_source_logs`），**不影响本任务的状态与通知**：
        //   情绪是展示型增量，它挂了不该把"涨停统计"带成红色。
        if task.id == "limitup" {
            runningTask = Swift.Task.detached(priority: .userInitiated) { [weak self] in
                let outcome: ([String: Any]?, String?) = {
                    do {
                        var json = try LimitUpPoolJob.run(shouldStop: shouldStop)
                        // ⚠ 情绪只在**今天**的池子今天落库时才算：回看补漏（`backfilled`）时
                        //   池子是历史日 D 的，而行情取到的是**今天**的 —— 两者一配就是日期错位
                        //   且不报错。补漏日直接跳过。
                        if json["status"] as? String == "ok",
                           json["backfilled"] as? Bool != true,
                           let day = json["date"] as? String {
                            let (sent, _) = ZtSentimentJob.runQuietly(today: day)
                            if let s = sent {
                                json["zt_sentiment"] = [
                                    "sample": s.sample, "missing": s.missing,
                                    "avg_pct": s.avgPct, "median_pct": s.medianPct,
                                    "promoted": s.promoted, "loss_count": s.lossCount,
                                ]
                            }
                        }
                        return (json, nil)
                    } catch { return (nil, (error as? LocalizedError)?.errorDescription
                                    ?? String(describing: error)) }
                }()
                await MainActor.run {
                    guard let json = outcome.0 else {
                        self?.finish(task: task, ok: false, json: nil,
                                     errorMessage: "涨停统计失败：\(outcome.1 ?? "未知")")
                        return
                    }
                    self?.finish(task: task, ok: true, json: JSONValue(json), errorMessage: nil)
                }
            }
            return
        }

        // 收盘后板块热度
        //
        // ⚠ 同样**独立任务**（理由见 `BoardHeatJob` 类注释）：收盘后时点数据，与复盘/迭代无关。
        if task.id == "boardheat" {
            runningTask = Swift.Task.detached(priority: .userInitiated) { [weak self] in
                let outcome: ([String: Any]?, String?) = {
                    do { return (try BoardHeatJob.run(shouldStop: shouldStop), nil) }
                    catch { return (nil, (error as? LocalizedError)?.errorDescription
                                    ?? String(describing: error)) }
                }()
                await MainActor.run {
                    guard let json = outcome.0 else {
                        self?.finish(task: task, ok: false, json: nil,
                                     errorMessage: "板块热度失败：\(outcome.1 ?? "未知")")
                        return
                    }
                    self?.finish(task: task, ok: true, json: JSONValue(json), errorMessage: nil)
                }
            }
            return
        }

        // 收盘后指标快照
        //
        // ⚠ 同样**独立任务**（理由见 `IndicatorSnapshotJob` 类注释）：收盘后派生数据，
        //   失败与复盘/迭代无关。历史库滞后类失败的文案**指向"设置 › 历史回放"**
        //   （需要用户动作，自动重试补不出来 —— 见该 Job 的 Failure 注释）。
        if task.id == "indsnap" {
            runningTask = Swift.Task.detached(priority: .userInitiated) { [weak self] in
                let outcome: ([String: Any]?, String?) = {
                    do { return (try IndicatorSnapshotJob.run(shouldStop: shouldStop), nil) }
                    catch { return (nil, (error as? LocalizedError)?.errorDescription
                                    ?? String(describing: error)) }
                }()
                await MainActor.run {
                    guard let json = outcome.0 else {
                        self?.finish(task: task, ok: false, json: nil,
                                     errorMessage: "指标快照失败：\(outcome.1 ?? "未知")")
                        return
                    }
                    self?.finish(task: task, ok: true, json: JSONValue(json), errorMessage: nil)
                }
            }
            return
        }

        // 四阶段重算（predict / verify / review / iterate）
        if let phaseRun = Self.phaseRunner(task.id) {
            runningTask = Swift.Task.detached(priority: .userInitiated) { [weak self] in
                let outcome: (JSONValue?, String?) = {
                    do { return (JSONValue(try phaseRun(params)), nil) }
                    catch { return (nil, (error as? LocalizedError)?.errorDescription
                                    ?? String(describing: error)) }
                }()
                await MainActor.run {
                    guard let json = outcome.0 else {
                        self?.finish(task: task, ok: false, json: nil,
                                     errorMessage: "\(task.id)失败：\(outcome.1 ?? "未知")")
                        return
                    }
                    self?.finish(task: task, ok: true, json: json, errorMessage: nil)
                }
            }
            return
        }

        // 任务模板与上面的分支必须一一对应：漏一个就会"静默完成"（宁可显式失败）
        finish(task: task, ok: false, json: nil,
               errorMessage: "任务 \(task.id) 没有原生实现（任务模板与执行分支不一致）")
    }

    /// 阶段任务 id → 原生执行体（未覆盖的任务返回 nil → 由 execute 显式报错）
    private static func phaseRunner(_ id: String)
        -> (@Sendable ([String: Any]) throws -> [String: Any])? {
        switch id {
        case "predict":
            return { params in try PhasePredict.predict(persist: true, params: params) }
        case "verify":
            return { params in try PhaseVerify.verify(persist: true, params: params) }
        case "review":
            return { params in try PhaseReview.review(persist: true, params: params) }
        case "iterate":
            return { params in try PhaseIterate.iterate(persist: true, params: params) }
        default:
            return nil
        }
    }
}

// MARK: - 取消状态传递盒

/// 承载"是否已被取消"，供 `ScanRunner` 的同步代码读取。
///
/// ## 为什么需要它
/// `Scheduler.stop()` 会 `runningTask?.cancel()`，但 `ScanRunner.runRound` 是
/// **全同步函数**（在 `Task.detached` 里跑到底），**它内部没有 Task 上下文** ⇒
/// `Task.isCancelled` 恒为 false ⇒ "一并取消在飞任务"实际不会发生。
/// 也不能在 detached 闭包里直接取 Task 句柄读实例属性（类型参数无法推断、Unsafe 语义多余）
/// ⇒ 改为：`stop()` 置位这个盒子，Core 每批请求前读它。语义等价、可测、跨线程安全。
///
/// ## 线程安全
/// `flag` 被写一次（`stop()`）、被读多次（Core 每批）。
/// 用 `OSAllocatedUnfairLock`（macOS 13+；本仓最低 macOS 26，无需降级路径）。
/// 读路径极短、锁内不做任何 IO。
/// ⚠ 标 `nonisolated`（Swift 6）：嵌套类型默认继承外层 `@MainActor` 隔离，
///   而它恰好要在 `Task.detached`（非隔离）里被 Core 每批读取 ⇒ 不标会编译报错。
///   本类型全部状态都由 `OSAllocatedUnfairLock` 保护、本身线程安全 ⇒ 显式声明它**不参与** actor 隔离。
nonisolated final class CancellationBox: @unchecked Sendable {
    private let flag = OSAllocatedUnfairLock(initialState: false)
    /// 由 `stop()` 置位；Core 每批请求前读一次。
    func cancel() { flag.withLock { $0 = true } }
    var isCancelled: Bool { flag.withLock { $0 } }
}
