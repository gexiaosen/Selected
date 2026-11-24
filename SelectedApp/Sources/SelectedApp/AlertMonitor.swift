import Foundation
import AppKit
import SelectedCore

/// 全局提醒开关（设置页「提醒」卡片的那个开关）。
///
/// ⚠ 键名只在这里定义一次，设置页的 `@AppStorage(AlertPause.defaultsKey)` 与
/// `AlertMonitor` 的读取**共用同一常量** —— 写成两个字面量、改一个忘一个，
/// 开关就会与实效相反且界面看不出来。同 `ScheduleTimes.defaultsKey` / `AppearanceStore.defaultsKey` 的做法。
enum AlertPause {
    static let defaultsKey = "alertsPaused"

    /// 当前是否暂停提醒。**每次读 UserDefaults**（不缓存），保证设置页改动即时生效。
    static var isPaused: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }
}

/// 自选提醒的**评估与投递**（App 层）：常驻轮询，独立于任何视图，告警在任何页面都响。
///
/// ## 它是**唯一**的行情轮询方
/// 轮询结果写进 `Store.liveQuotes`（`@Observable`），自选页只读不拉 ——
/// 否则"显示"和"告警"两路各拉一次，既费额度又可能拿到**同一时刻的两个价**。
///
/// ## 轮询节奏
/// | 情形 | 间隔 |
/// |------|------|
/// | 交易时段内 **且** App 在前台 | 5s |
/// | 交易时段内但 App 不在前台 | 60s |
/// | 非交易时段 | 60s |
///
/// ⚠ 「交易时段内」= 非周末 **且** 交易日缓存说今天开盘（审查 #19，见 `pollInterval`）——
///   只判周末的话，节假日（工作日休市）前台仍每 5 秒白拉一轮行情。
/// ⚠ 失焦只退避到 60s、**不停止轮询**（停了告警就依赖停留页面）；告警最迟 1 分钟内到达。
/// ⚠ 已知边界：App Nap 可能节流定时器 —— 那时告警**延迟**而不是丢失
/// （`Scheduler` 在它的调度窗口里持有活动断言，本类不额外持有，避免与它抢）。
///
/// ## ⚠ 为什么评估/落库留在主线程
/// `AlertStore` 读写的是几十行的小表（单次 < 0.1 ms），与 `Store.loadWatch()` 的直读同一量级；
/// 搬后台需要把 `StockQuote` 标 `Sendable` + 一串隔离域跳转，收益为零。
/// ⚠ 若 `watch_alerts` 长到需要全表扫的规模，这里是第一个该搬的地方。
@MainActor
final class AlertMonitor {

    static let shared = AlertMonitor()
    private init() {}

    /// 轮询任务（`start()` 只建一次）
    private var loop: Task<Void, Never>?
    /// 本轮正在跑（`kick()` 与定时轮可能撞上）
    private var ticking = false
    /// 排队中的 kick：`tick()` 正在跑时收到的 kick 在这里**记一笔**，本轮结束再补跑一轮（不静默丢弃）。
    private var pendingKick = false

    /// **会话内**已触发（第二层去重）。
    ///
    /// ⚠ 第一层是库里的 `last_fired_*`；这一层防的是库写入失败时规则**每轮重新触发一次** → 通知轰炸。
    ///
    /// 键的形态决定语义（`AlertFiring.dedupKey`）：
    ///   · 带日期后缀（`…|yyyy-MM-dd`）= 用户规则的「每日重复」→ 跨日重新武装
    ///   · 不带日期后缀 = 用户规则的「单次」→ **本次运行内只响一次**
    private var sessionFired: Set<String> = []
    /// `sessionFired` 归属的日期（用于跨日清理，见 `pruneSessionFired(day:)`）
    private var sessionFiredDay: String = ""

    /// 交易日判定缓存。⚠ **只把 `true` 缓存一整天**，见 `isTradingDay(day:now:)`。
    private var tradingDayCache: (day: String, value: Bool, checkedAt: Date)?

    // MARK: - 生命周期

    /// 启动常驻轮询（App 入口调用一次；重复调用无副作用）
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                guard !Task.isCancelled else { break }
                try? await Task.sleep(for: self?.pollInterval() ?? .seconds(60))
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// 立刻跑一轮（规则刚改完时调用，把最长 60s 的退避压掉）。
    ///
    /// ⚠ 正有一轮在跑时置 `pendingKick` 排队，由本轮结束时的 `defer` 补跑
    ///   （多次 kick 会合并，不会自激）。
    func kick() {
        pendingKick = true
        Task { await tick() }
    }

    /// 轮询间隔（见类注释的表）。
    /// ⚠ 审查 #19：必须吃**交易日缓存**，不能只判周末 —— 节假日（工作日休市）
    ///   旧逻辑照样"时段内 + 前台 = 5 秒"，白打全自选行情接口。
    ///   缓存由 `tick()` 每轮开头刷新（`true` 存一整天、`false` 60 秒复检，见 `isTradingDay`），
    ///   这里只做同步读取；缓存缺席（首轮尚未判定）按周末口径兜底。
    private func pollInterval(now: Date = Date()) -> Duration {
        let cachedClosed = tradingDayCache.map { $0.day == ChinaTime.day(now) && !$0.value } ?? false
        let inSession = !ChinaTime.isWeekend(now) && !cachedClosed
            && AlertWindow.inSession(minuteOfDay: ChinaTime.minutesOfDay(now))
        // ⚠ 口径来自 `AlertWindow.sessionRanges`（Core 里**唯一一份**交易时段定义），不在这里重写一份。
        guard inSession else { return .seconds(60) }
        return NSApp?.isActive == true ? .seconds(5) : .seconds(60)
    }

    // MARK: - 一轮

    private func tick() async {
        guard !ticking else { return }
        ticking = true
        defer {
            ticking = false
            // ⚠ 排队的 kick 必须在**释放 `ticking` 之后**才补跑，否则会被上面的 `guard` 拦掉。
            //   spawn 新 Task 而非递归调用；`pendingKick` 消费一次即清，不会自激。
            if pendingKick {
                pendingKick = false
                Task { await tick() }
            }
        }

        let now = Date()
        pruneSessionFired(day: ChinaTime.day(now))

        // ⚠ 交易日判定上提到每轮开头（审查 #19）：
        //   ① `pollInterval` 靠这份缓存决定 5s/60s 节奏（原先只看周末，节假日白拉 5 秒）；
        //   ② 原先缓存只在 `evaluateAndNotify` 里更新，而"无规则/已暂停"路径根本走不到它
        //     ⇒ 缓存永不落地，间隔判定也就永远拿不到值。
        //   周末在 `tradingDayVerdict` 里短路返回、不产生网络请求；代价只有节假日
        //   每 60 秒一次判定（`false` 的复检节奏，见 `isTradingDay`）。
        let tradingDay = await isTradingDay(day: ChinaTime.day(now), now: now)

        let rulesByCode = AlertStore.rulesByCode()

        // ⚠ 轮询的是**并集**：自选列表（供界面显示）+ 配了提醒的代码。
        //   后者不能省 —— 否则"从没打开过自选页"（`watchItems` 为空）时告警永远不响。
        var codes = Store.shared.watchItems.map(\.code)
        var seen = Set(codes)
        for c in rulesByCode.keys where seen.insert(c).inserted { codes.append(c) }
        guard !codes.isEmpty else {
            if !Store.shared.liveQuotes.isEmpty { Store.shared.liveQuotes = [:] }
            return
        }

        let quotes = await QuoteAPI.batch(codes)
        // ⚠ **「因缺行情被跳过」的条数**要显式计数：`evaluateAndNotify` 会把没行情的代码静默跳过。
        //   整批失败时配了提醒的票**全部**跳过（漏报一整轮），而 `liveQuotes` 保留上一轮价格
        //   ⇒ 界面完全看不出异常。记进 `skippedNoQuote` 由设置页显示
        //   （不复用 `Notifier.suppressedCount` —— 那个的含义是"因未授权被系统拦下"，混用会误导诊断）。
        let quotedCodes = Set(quotes.keys)
        let skippedNoQuote = rulesByCode.keys.filter { !quotedCodes.contains($0) }.count
        // ⚠ 网络抖动防护：整批失败时**保留上一轮价格**，不覆盖成空（否则自选列全部变"—"且提醒漏报一轮）。
        // 有数据（哪怕部分）仍覆盖：展示可得的最新价，缺失批次下次轮询自愈。
        if quotes.isEmpty, !Store.shared.liveQuotes.isEmpty {
            NSLog("[NOTICE] 自选行情整批获取失败（%d 只），保留上一轮 %d 条价格；"
                  + "本轮 %d 只配了提醒的票未判定", codes.count,
                  Store.shared.liveQuotes.count, skippedNoQuote)
        } else {
            Store.shared.liveQuotes = quotes
            Store.shared.liveQuotesUpdatedAt = now
        }
        // ⚠ 无论整批失败还是部分缺失都要记（部分缺失同样会漏判）
        Notifier.shared.recordSkippedNoQuote(skippedNoQuote)

        // ⚠ 暂停开关在**取行情之后**判断：暂停的是"提醒"，不是"自选页的价格列"
        //   （把取行情一起停掉会让用户以为行情坏了）。
        // ⚠ 暂停期间**不动 `last_fired_*`**：恢复后规则仍按"今天还没响过"评估（这是"暂停"不是"跳过今天"）。
        if AlertPause.isPaused { return }

        // 用户自定义提醒（**唯一**的通知来源：引擎的止盈/止损价位只做参考，不自动提醒）
        guard !rulesByCode.isEmpty else { return }
        await evaluateAndNotify(quotes: quotes, rulesByCode: rulesByCode, now: now,
                                tradingDay: tradingDay)
    }

    /// 跨日清理 `sessionFired`：**只丢带日期后缀的键**（用户规则的「每日重复」）。
    ///
    /// ⚠ 不带日期的键（「单次」用户规则）**必须留着** —— 它们本次运行内只该响一次。集合规模因此有界：`规则数 × 天数`，旧日期每天被丢掉。
    private func pruneSessionFired(day: String) {
        guard day != sessionFiredDay else { return }
        sessionFiredDay = day
        sessionFired = sessionFired.filter { key in
            guard let last = key.split(separator: "|").last else { return true }
            guard last.count == 10, last.contains("-") else { return true }   // 不是日期 → 保留
            return last == day
        }
    }

    /// 数值转换：收敛到 `Num.doubleOrZero`（保留本名以不动调用点）。
    private static func num(_ v: Any?) -> Double { Num.doubleOrZero(v) }

    private func evaluateAndNotify(quotes: [String: StockQuote],
                                   rulesByCode: [String: [AlertRule]],
                                   now: Date,
                                   tradingDay: Bool) async {
        let day = ChinaTime.day(now)
        // 判定由 `tick()` 每轮开头统一做（审查 #19），这里只消费结果
        guard tradingDay else { return }

        let windows = AlertStore.windowsByCode()
        // 名称优先取自选列表（用户熟悉的名字），回落行情自带的名称
        var names: [String: String] = [:]
        for item in Store.shared.watchItems { names[item.code] = item.displayName }

        var subjects: [AlertSubject] = []
        for (code, rules) in rulesByCode {
            guard let q = quotes[code] else { continue }
            subjects.append(AlertSubject(code: code,
                                         name: names[code] ?? q.name,
                                         price: q.currentPrice,
                                         // ⚠ 取**接口原值** `q.change`（腾讯 f[31]）—— 与自选表「涨跌额」列**同源**，
                                         //   判据必须与用户看到的数一致：`f[31]` 缺失时界面回落 0.00，判据也必须是 0.00
                                         //   （若自算，会变成"界面说没动、提醒却响了"）。
                                         changeAmount: q.change,
                                         changePercent: q.changePercent,
                                         rules: rules,
                                         window: windows[code] ?? .anytime))
        }

        let clock = AlertClock(day: day,
                               minuteOfDay: ChinaTime.minutesOfDay(now),
                               isTradingDay: true,
                               stamp: ChinaTime.stamp(now))
        let firings = AlertEval.evaluate(subjects, at: clock)
            .filter { !sessionFired.contains($0.dedupKey) }
        guard !firings.isEmpty else { return }

        // 投递优先，落库挪到后台（2026-10-16 审查 B3）：
        //   `AlertStore.markFired` 走 `SQLiteWriter.write`（串行队列 `queue.sync`，
        //   且 `busy_timeout=30s`），而本函数跑在 `@MainActor` 的 5 秒轮询里 ——
        //   只要此刻后台正有一个大事务在落扫描结果，主线程就被按住到它提交为止，
        //   表现是"盘中点什么都没反应"。
        //   语义不变：写失败仍**不阻断**投递，会话内去重靠 `sessionFired`（下面立刻置位）。
        for f in firings {
            sessionFired.insert(f.dedupKey)
            Notifier.shared.send(title: f.title, body: f.body, identifier: f.identifier)
        }
        let toPersist = firings
        Task.detached(priority: .utility) {
            do {
                let n = try AlertStore.markFired(toPersist)
                if n < toPersist.count {
                    // 行数对不上 = 规则在"评估 → 落库"之间被删了（或阈值对不上）。
                    // 只记日志不改行为：这一条本来就该响。
                    NSLog("[NOTICE] 提醒触发落库行数不符：更新 %d 行 / 触发 %d 条", n, toPersist.count)
                }
            } catch {
                NSLog("[ERROR] 提醒触发落库失败（本轮仍投递，会话内不会重复）：%@",
                      String(describing: error))
            }
        }
    }

    // MARK: - 交易日判定

    /// 当日是否交易日。
    ///
    /// ⚠ **只把 `true` 缓存一整天**：App 可能在指数报价更新**之前**启动，那时
    /// `DataSources.isTradingDay()` 返回 `false`（"行情未更新 → 视为休市"）——
    /// 缓存 `false` 一整天 = 一整天都不提醒且界面看不出来。故 `false` 每 60 秒复检一次。
    ///
    /// ⚠ 必须**离开主线程**调用：`DataSources.isTradingDay()` 内部是同步 `httpGet`（阻塞网络）。
    private func isTradingDay(day: String, now: Date) async -> Bool {
        if let c = tradingDayCache, c.day == day {
            if c.value { return true }
            if now.timeIntervalSince(c.checkedAt) < 60 { return false }
        }
        let value = await Task.detached(priority: .utility) {
            DataSources.isTradingDay().trading
        }.value
        tradingDayCache = (day, value, now)
        return value
    }
}
