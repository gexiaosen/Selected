import Foundation

/// 行情抓取层 —— 数据源矩阵的统一实现。
///
/// 数据源矩阵：
///   · 全量实时行情：行情池三源（腾讯 / 东财 / 新浪）运行时选路，见 `QuotePool` + `QuoteAPI`
///   · 证券主列表：新浪 Market_Center 分页 HTTP → 过期缓存 → 随包基线（三层兜底）
///   · 日K线(65日) / 指数日K / 5分钟K线：新浪 JSONP
///   · 交易日判定：深交所官方日历 `monthList`（取不到才回落"上证行情报价日期"这条间接判据）
///   · 指数 / 外盘：腾讯
///
/// ================= 关键契约 =================
/// 1. **fixture 模式**：环境变量 `SELECTED_FIXTURE_DIR` 指向快照目录时，所有取数改读该目录下的
///    JSON 快照；未设置时**零行为变化**（生产链路完全不受影响）。快照文件缺失 → 回落真实网络。
///    快照目录布局：`meta.json / quotes.json / index_quote.json / overseas.json / stock_list.json /
///    index_daily_kline.json / daily_kline/<code>.json / m5/<code>.json`。
/// 2. **单位「手」**：腾讯字段 `volume`（下标 36）单位是**手**，`amount`（下标 37）单位是**万元**；
///    下游折算到股数时自行 ×100。返回的 double 值**直接参与落库 JSON**，故取整顺序（
///    change_pct/volume_ratio/turnover/amplitude/pe 先取原始值再 `PyMath.round(_,2)`）与精度必须逐位一致。
/// 3. **新浪日K不含当日 bar**：`scale=240` 盘中返回的末根 = 前一交易日。需要「末根=今日」的调用方
///    必须自行合成当日 bar。离线快照同样是抓取时刻的原始状态，也不含当日 bar（保证回放一致）。
/// 4. **fixture 回放与墙上时钟解耦**：`runDate()` 优先取快照 `meta.json` 的 date → 同一份快照
///    在任何日期回放都得同一结果；线上才用本机当天（Asia/Shanghai）。
/// 5. **指数日K 在 fixture 模式忽略 `datalen`**：直接返回快照全部 bar（不做 `[-datalen:]`）—— 既有行为。
/// 6. **证券主列表全失败不抛错**：返回 `[]` 并记 `logDataSource`，由调用方按空列表处理
///    （避免把「列表拿不到」升级成崩溃）。
/// 7. **引擎口径的市场前缀只分沪深**：`symbolPrefix(code)` = 6 开头 → `sh`，否则 `sz`
///    （**与 StockQuotes.fullCode 的多市场推断不同**，勿混用）。
/// ================================================================================================

public enum DataSources {

    // MARK: - 常量

    static let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Chrome/126.0 Safari/537.36"
    static let requestTimeout = 15
    /// 腾讯单批只数：线上服务端上限 600（1000 只触发 HTTP 414），取 500 留安全余量
    static let tencentBatchSize = 500
    /// 分片失败重试次数，仍失败则对半拆片（最多 2 层）
    static let tencentChunkRetries = 2
    /// 全量行情**整轮**预算（秒）。为什么必须有：
    ///   单批最坏 = 3 次尝试 × 15s 超时 + 退避 ≈ 46s；失败再对半拆到 2 层
    ///   → 单批 500 只最坏 ≈ 322s；全市场 10 批 ≈ **50+ 分钟**。
    ///   期间 `Scheduler.runningTaskId` 恒非 nil、`Store.hasBusyWriteCommand` 拒绝一切
    ///   手动写操作 → **全天调度停摆**（而且没有任何日志说明"卡在哪"）。
    ///   ⇒ 整轮必须有硬预算，超时即带着已有数据返回并留痕。
    static let quoteRoundBudgetSec: TimeInterval = 180
    /// 连续空批熔断阈值：连续这么多个批次一条都没解析出来 → 判定数据源整体不可用，立即收工
    /// （比"等满 180s"更快，也避免对已经挂掉的服务端持续打请求）
    static let quoteRoundFailureLimit = 3
    /// 证券列表分页参数（新浪服务端 num>100 强制回落为 100）
    static let sinaListPageSize = 100
    static let sinaListMaxPages = 90
    // ⚠ 页间必须有下限（2026-10-16 审查 B4）：原值是 0.0，理由写的"HTTP 主源无需节流"——
    //   但一次列表抓取是**串行 90 页**（`sinaListMaxPages`），0 间隔即"连续 90 次打同一个 host"，
    //   正是本项目记录过的封禁形态。0.05s 只给整轮多约 4.5 秒，换的是不被限流。
    static let sinaListDelay: Double = 0.05


    /// 场内基金列表来源节点（新浪 Market_Center）与安全页数上限
    /// 规模：etf/lof/close 合计约 2145 只，抓取约 10s
    static let fundNodes: [(node: String, kind: String)] = [
        ("etf_hq_fund", "etf"), ("lof_hq_fund", "lof"), ("close_fund", "close"),
    ]
    static let fundMaxPages = 30
    /// 基金列表缓存有效期（天）：成分变动缓慢，7 天内直接用缓存，避免每次搜索都抓 10s
    public static let fundCacheTTLDays = 7
    /// K线请求节流默认值（秒）；可用 SELECTED_KLINE_DELAY 覆盖
    static let defaultKlineDelay: Double = 0.05
    /// 健全性闸门：全量行情少于该数量视为数据源异常（本文件只透出统计，闸门在调用方）
    public static let minExpectedQuotes = 4000

    // MARK: - 中国时间（本文件为了自包含用本地实例；语义等同 ChinaTime，均 Asia/Shanghai）

    static let shanghai = TimeZone(identifier: "Asia/Shanghai") ?? TimeZone.current
    // 委托 ChinaTime.formatter（en_US_POSIX + Asia/Shanghai）
    static let dayFormatter = ChinaTime.formatter("yyyy-MM-dd")
    static let timestampFormatter = ChinaTime.formatter("yyyy-MM-dd'T'HH:mm:ss")
    static let shCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = shanghai
        return c
    }()

    // MARK: - 离线 fixture 注入层

    /// SELECTED_FIXTURE_DIR（空串视作未设置）。每次读取，方便测试运行时切换。
    public static var fixtureDir: String? {
        guard let d = ProcessInfo.processInfo.environment["SELECTED_FIXTURE_DIR"], !d.isEmpty else {
            return nil
        }
        return d
    }

    /// 读 fixture 文件；未启用或文件缺失/损坏返回 nil（调用方回落真实网络）
    static func fixture(_ name: String) -> Any? {
        guard let dir = fixtureDir else { return nil }
        // ⚠ 名称必须收口（2026-10-16 审查 B4）：`name` 有部分是调用方拼进来的代码，
        //   如 `fixture("daily_kline/\(code).json")`（`DataSourcesKline`），
        //   而 `NSString.appendingPathComponent` **不消解 `..`** ⇒ 越出 fixture 目录
        //   读到磁盘上任意文件。这里按"目录内相对路径"处理，绝对路径与 `..` 一律拒绝。
        guard !name.hasPrefix("/"), !name.contains("..") else {
            NSLog("[ERROR] fixture 名称含越界片段，已拒绝：%@", String(name.prefix(80)))
            return nil
        }
        let path = (dir as NSString).appendingPathComponent(name)

        guard FileManager.default.fileExists(atPath: path),
              let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return obj
    }

    /// fixture 模式返回快照自带日期（meta.json 的 date）；非 fixture 返回 nil
    public static func fixtureDate() -> String? {
        guard let fx = fixture("meta.json") as? [String: Any],
              let date = fx["date"], !(date is NSNull) else { return nil }
        let s = pyStr(date)
        return s.isEmpty ? nil : s
    }

    /// 本轮「当日」日期的**唯一出口**。
    ///
    /// 为什么不能在扫描内部直接用 `Date()`：同一份离线快照在不同日期回放会得到不同结果 ——
    /// m5 快照的 bar 日期与墙上时钟不符时分时特征整块算不出；指数连跌检测按墙上时钟剔「当日」
    /// 会剔错。fixture 回放取快照日期 → 「同快照必同结果」。
    public static func runDate() -> String {
        // 回放模式：回放日**优先于一切** —— 它是编排器显式设定的事实，不是"今天"。
        // 与 fixture 的 meta.json 同一条纪律：回放日的行情快照在不同日期跑必须得到同一结果。
        if let d = HistoryReplayMode.activeDay { return d }
        if let d = fixtureDate() { return d }
        return dayFormatter.string(from: Date())
    }

    /// K线请求间隔。fixture 模式无网络请求、不需节流 → 0（否则离线整轮白付 0.15s/只的节流税）。
    ///
    /// ⚠ 真实网络下**不允许降到 0**（2026-10-16 审查 B4）：`KlineThrottle.wait` 在
    ///   `interval <= 0` 时是**先返回、再取锁**，于是 `SELECTED_KLINE_DELAY=0`
    ///   等于把全局限速整个关掉；叠加 `PhaseReview` 的无上限 `concurrentPerform`
    ///   就变成"几十个同时打的阻塞请求"。本项目的出口 IP 已经被这个形态打进过限流名单
    ///   （见 `docs/specs/README.md` 与 `run_all.sh` 的 `push2_throttled` 护栏）。
    ///   ⇒ 环境变量的语义改成"调速"，不再是"开关"；离线仍由 `fixtureDir` 分支给 0。
    public static func klineDelay() -> Double {
        if fixtureDir != nil { return 0.0 }
        if let s = ProcessInfo.processInfo.environment["SELECTED_KLINE_DELAY"], let v = Double(s), v > 0 {
            return max(minNetworkKlineDelay, v)
        }
        return defaultKlineDelay
    }

    /// 真实网络下的节流下界（理由见 `klineDelay()`）
    static let minNetworkKlineDelay: Double = 0.05

    // MARK: - K 线内存缓存

    /// 为什么必须有：没有缓存时，三轮扫描各自对**同一批候选**重拉日K + 5 分钟线，
    /// `WatchJudge`、`PhaseReview` 又各自重拉，每次还白付 `klineDelay()`（默认 0.05s）。
    /// 这是 `budget.deep_budget_sec`（默认 120s）被触发的直接原因 —— 而预算一触发，
    /// 剩余候选就被降为"未评分"，进而在信号分类里变成 `unverified` →
    /// **信号质量被网络延迟决定**。
    ///
    /// 口径：
    ///   · 日K/指数K按 `(标的, datalen, 当日)` 缓存 —— 新浪盘中**不含当日 bar**，
    ///     同一交易日内结果恒定，跨日由日期键自然失效；
    ///   · 5 分钟线带 60s TTL —— 盘中在变，但一轮扫描/一次判定内复用完全够用；
    ///   · **fixture 模式不缓存**：离线回放本就是本地读文件，缓存只会引入
    ///     "跨场景残留"的风险（各测试脚本在同一进程内切换快照）。
    ///   · **只缓存非空结果**：一次网络抖动不该把"今天这只票没数据"钉死一整天。
    ///
    /// 实现用 `final class + @unchecked Sendable`：Swift 6 严格并发不允许裸的可变全局状态，
    /// 锁由类自己持有。
    final class KLineCache: @unchecked Sendable {
        private let lock = NSLock()
        private var store: [String: (value: Any, at: Date)] = [:]
        /// 累计元素数（数组取元素数、非数组取 1）—— 内存的代理量
        private var totalWeight = 0

        /// 容量上界：按**累计元素数**而非键数。
        /// 日K ~250 根、5分钟线 240 点 ⇒ 500_000 元素 ≈ 2000 份全量历史，约合数百 MB 级上限。
        private static let maxTotalWeight = 500_000

        private static func weight(of value: Any) -> Int {
            (value as? [Any])?.count ?? 1
        }

        func get<T>(_ key: String, ttl: TimeInterval?, enabled: Bool) -> T? {
            guard enabled else { return nil }
            lock.lock(); defer { lock.unlock() }
            guard let entry = store[key] else { return nil }
            if let ttl = ttl, Date().timeIntervalSince(entry.at) > ttl {
                store.removeValue(forKey: key)
                totalWeight -= Self.weight(of: entry.value)
                return nil
            }
            return entry.value as? T
        }

        func put(_ key: String, _ value: Any, enabled: Bool) {
            guard enabled else { return }
            lock.lock(); defer { lock.unlock() }
            let w = Self.weight(of: value)
            if let old = store[key] { totalWeight -= Self.weight(of: old.value) }
            totalWeight += w
            // ⚠ 超限**逐条淘汰最旧**（写完当前键，避免自删）：只限键数且超限 `removeAll()`
            //   的话，单键值无界会让长跑进程（历史回放全市场 5000 只）驻留数百 MB。
            //
            // ⚠ 这里找最旧是 `filter + min` 的 **O(n) 扫描**，且只在 `totalWeight` 超上限时才进入循环。
            //   刻意不改：① 淘汰只在**超出上限后**触发，正常路径零成本；
            //   ② n 被 `maxTotalWeight` 间接约束（键值都是 K 线数组/文本块，量级千），
            //      单次扫描 ~µs 级，而 put 的频率 = 网络请求频率（~10 次/分钟）；
            //   ③ 换成有序结构要动缓存的读写两侧（回放/详情/扫描三处消费），收益量不出来。
            //   **重议条件**：若 put 频率升到每秒级，或 `maxTotalWeight` 调到 10^7 以上，
            //   再来换堆/双端队列。
            while totalWeight > Self.maxTotalWeight, !store.isEmpty {
                guard let oldest = store.filter({ $0.key != key })
                    .min(by: { $0.value.at < $1.value.at })?.key,
                      let e = store.removeValue(forKey: oldest) else { break }
                totalWeight -= Self.weight(of: e.value)
            }
            store[key] = (value, Date())
        }
    }

    /// 新浪 K 线请求的**全局限速器**。
    ///
    /// **为什么必须有**：裸的 `Thread.sleep` 是**线程级**睡眠。串行调用时它
    /// 等价于"相邻两次网络请求间隔 ≥ 网络耗时 + delay"，但一旦出现并发调用
    /// （`PhaseReview` 的 per-stock 扇出、以及将来任何扇出），N 个线程各睡各的 →
    /// 全局 QPS = N/delay，限速**形同虚设**，而调用方以为自己受保护。
    ///
    /// **语义**：把 sleep 收进一把锁 —— 串行调用下与逐次 sleep **等价**（仍是"每次网络请求后
    /// 睡 delay"，只多一次纳秒级加解锁），并发调用下退化为"排队睡"，全局速率上界 = 1/delay。
    ///
    /// **为什么是 `Thread.sleep` 而不是 `Task.sleep`**：调用它的 `fetchDailyKline` /
    /// `fetchIndexDailyKline` / `fetch5minBars` 都是**同步函数**，被扫描管线、四阶段管线、
    /// 回放与后台任务共用。改 async 会沿调用链传染 4 个入口，代价远大于"睡眠不占线程"的收益。
    ///
    /// ⚠ 锁内 sleep 的前提是**不嵌套其它锁**：`throttleAfterNetwork` 的调用点全在
    ///   数据源叶子函数里（`defer` 收尾），缓存锁在其之前已释放。
    final class KlineThrottle: @unchecked Sendable {
        private let lock = NSLock()

        /// 请求结束后调用。`interval <= 0`（fixture 模式 / `SELECTED_KLINE_DELAY=0`）
        /// 直接返回 —— 不争锁：离线跑批一秒钟都不该付。
        func wait(_ interval: Double) {
            guard interval > 0 else { return }
            lock.lock(); defer { lock.unlock() }
            Thread.sleep(forTimeInterval: interval)
        }
    }

    /// 异步网络请求的**全局限速器**（供 Swift Concurrency `async` 取数路径使用，如
    /// `EastmoneyQuoteProvider`、`KLineService.fetchEastmoneyMinute`）。
    ///
    /// 与 `KlineThrottle` 的区别：不阻塞当前线程，而是以 `actor` 串行预定下一可用时刻并用
    /// `Task.sleep` 挂起等待 —— 避免把耗时阻塞带进 Swift Concurrency 协作线程池，
    /// 同时杜绝 actor 可重入性导致多并发任务同时醒来（仍保证全局间隔 ≥ interval）。
    actor AsyncKlineThrottle {
        private var nextSlot: ContinuousClock.Instant?

        init() {}

        func wait(_ interval: Double) async {
            guard interval > 0 else { return }
            let clock = ContinuousClock()
            let now = clock.now
            let gap = Duration.seconds(interval)
            let target = (nextSlot.map { max(now, $0) } ?? now) + gap
            nextSlot = target
            let sleepDuration = now.duration(to: target)
            if sleepDuration > .zero {
                try? await clock.sleep(for: sleepDuration)
            }
        }
    }

    static let klineCache = KLineCache()
    static let klineThrottle = KlineThrottle()
    static let asyncKlineThrottle = AsyncKlineThrottle()
    static let kline5minTTL: TimeInterval = 60
    /// fixture 模式下禁用缓存
    static var klineCacheEnabled: Bool { fixtureDir == nil }

    static func cacheGet<T>(_ key: String, ttl: TimeInterval?) -> T? {
        klineCache.get(key, ttl: ttl, enabled: klineCacheEnabled)
    }

    static func cachePut(_ key: String, _ value: Any) {
        klineCache.put(key, value, enabled: klineCacheEnabled)
    }

    /// 真的走了网络才限速。缓存命中时不再白付节流税 —— 节流的意义本就是"少打扰数据源"。
    ///
    /// ⚠ 必须走 `klineThrottle`（**全局**限速）而不是裸 `Thread.sleep`：并发调用下前者
    ///   才真正限住全局 QPS，理由见 `KlineThrottle` 的注释。
    /// ⚠ **东财 `push2*` 家族也必须走它**：`HistoryBarsSource` / `FundamentalSource` /
    ///   `BoardHeatSource` 都要调用 —— 漏掉过一次：1904 次连发把出口 IP 打进了限流名单。
    static func throttleAfterNetwork() {
        klineThrottle.wait(klineDelay())
    }

    /// `async` 调用点的全局限速入口（不阻塞 Swift Concurrency 协作线程）。
    static func throttleAfterNetworkAsync() async {
        await asyncKlineThrottle.wait(klineDelay())
    }

    // MARK: - 最近一次「抓取为什么没成」（供上层"如实报错"）

    /// 最近一次抓取失败的 `(url, 原因)`。
    ///
    /// **为什么需要**：若失败原因只进 `data_source_logs`，而设置页统一显示
    /// 「抓取失败（源无响应或返回不完整）」—— "没网 / 被限流 / 404 / 超时"
    /// **在界面上长得一模一样**，用户和我们只能猜。真因（如
    /// `The network connection was lost.`，即东财对出口 IP 限流）会被含糊文案吃掉。
    ///
    /// ⚠ 它承载的**不只是 HTTP 错误**：上层的"完整性判定"也往这里写
    /// （如"只取到 5226/5561 只（源返回被截断）"）—— 因为**消费方要的是同一件事**：
    /// "这次抓取为什么没成"。所以名字是 `recordFetchFailure` 而不是 `recordHTTPError`。
    ///
    /// ⚠ **读的时候必须按 URL 前缀匹配**（`lastFetchFailureReason(matching:)`）：
    ///   扫描 / 回放等后台任务会并发发请求，不加前缀就会把**别的源**的错误报成自己的
    ///   （"张冠李戴的报错"比不报还坏）。
    /// ⚠ 也**不能只留一个槽位**：后台任务写一条就会把我们刚记的那条挤掉 → 读回 `nil`、
    ///   退回含糊文案。⇒ 按**端点（去掉 query 的 URL）**分槽，读时取同前缀里最新的一条。
    private static let httpErrLock = NSLock()
    /// key = 去掉 query 的 URL；value = 原因
    private nonisolated(unsafe) static var httpErrReasons: [String: String] = [:]
    /// 同一 key 的写入序号（读时用"最新的那条"）
    private nonisolated(unsafe) static var httpErrSeq: [String: Int] = [:]
    private nonisolated(unsafe) static var httpErrCounter = 0

    /// `https://h/p?a=1&b=2` → `https://h/p`；若含东财域筛选参数 `fs=`（`clist/get` 用它
    /// 区分基本面 / 板块热度 / 板块成份），保留 `?fs=<值>`（剔除 `pn`/`pz`/`fid`/`fields`
    /// 等分页与列参数），防止不同业务域的失败原因互相覆盖或被清错。
    static func fetchFailureKey(_ url: String) -> String {
        let parts = url.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let base = String(parts.first ?? "")
        guard parts.count == 2 else { return base }
        for param in parts[1].split(separator: "&") where param.hasPrefix("fs=") && param.count > 3 {
            return "\(base)?\(param)"
        }
        return base
    }

    /// 记一次 HTTP 失败（`httpGet` 内部调）
    static func recordFetchFailure(_ url: String, _ reason: String) {
        let key = fetchFailureKey(url)
        httpErrLock.lock(); defer { httpErrLock.unlock() }
        httpErrCounter += 1
        httpErrReasons[key] = reason
        httpErrSeq[key] = httpErrCounter
    }

    /// 清掉与 `prefix` 同前缀的记录 —— 一次抓取**开始前**调，保证之后读到的必定是本次的
    /// （否则上一次尝试的旧错误会被当成这一次的原因）
    static func clearFetchFailure(matching prefix: String) {
        httpErrLock.lock(); defer { httpErrLock.unlock() }
        for k in httpErrReasons.keys where k.hasPrefix(prefix) {
            httpErrReasons.removeValue(forKey: k)
            httpErrSeq.removeValue(forKey: k)
        }
    }

    /// 最近一次 HTTP 失败的原因；**URL 前缀不匹配 → `nil`**（见上方并发说明）。
    /// 同前缀有多条时取**最新写入**的那条。
    public static func lastFetchFailureReason(matching prefix: String) -> String? {
        httpErrLock.lock(); defer { httpErrLock.unlock() }
        let newest = httpErrSeq.filter { $0.key.hasPrefix(prefix) }
            .max { $0.value < $1.value }?.key
        return newest.flatMap { httpErrReasons[$0] }
    }

    /// 抓取失败的统一文案：**能拿到 HTTP 层原因就带上**。
    /// 拿不到（`nil` / 空串）时保留旧文案 —— 那是"源返回了但内容不完整"的情形。
    public static func fetchFailureMessage(_ httpReason: String?) -> String {
        guard let r = httpReason, !r.isEmpty else { return "抓取失败（源无响应或返回不完整）" }
        return "抓取失败：\(r)"
    }

    /// 这条失败原因**是否像"出口 IP 被限流"**（启发式判定）。
    ///
    /// ## 为什么需要
    /// 东财 `push2*` 对批量列表端点**按出口 IP 限流**（`clist` / `kline`），被限流后
    /// 服务端**直接关闭连接、无响应** ⇒ `httpGet` 拿到的就是 `The network connection was lost.`
    /// 一类"连接层"错误。刷新失败时必须区分**限流**（该换网络/等冷却）、**断网**（该查自己网络）、
    /// **源挂了**（该稍后再试）—— 处置完全不同，混在一起会把人引到错误的修复路径上。
    ///
    /// ## 判据（保守：只认连接被对端关闭/重置这一族）
    /// 命中 = 疑似限流；**不命中**的（超时 / HTTP 4xx·5xx / 截断 / 空响应体）各有明确根因，
    /// 不归限流 —— 宁可漏报也不误报：误报"限流"会让用户去换网络，而真问题是别的。
    /// ⚠ 这是**启发式**、不是确证：源侧没有"你被限流了"的显式回执，只能从"连接被无声掐断"
    ///   这个症状反推。所以文案用"疑似"，且只作为**附加提示**，不替换原始原因。
    public static func isSuspectedThrottle(_ httpReason: String?) -> Bool {
        guard let r = httpReason, !r.isEmpty else { return false }
        let lower = r.lowercased()
        // 连接被对端直接关闭 / 重置 / 无响应 —— 限流时就是这个
        return lower.contains("network connection was lost")
            || lower.contains("connection was lost")
            || lower.contains("connection reset")
            || lower.contains("连接被重置")
            || lower.contains("连接被对端关闭")
            // ⚠ 中文系统下 URLSession 的 `localizedDescription` 会把 -1005 本地化成
            //   「网络连接已中断。」—— 只判英文串会**静默漏判**（判据跟着系统语言漂）。
            //   故中英两版都要认。刻意**不含**「未连接到互联网」(-1009)：那是用户自己断网，
            //   处置完全不同，归进限流就是误报（判据保守：宁可漏报不误报）。
            || r.contains("网络连接已中断")
            || r.contains("与主机的连接已中断")
            || r.contains("HTTP 000")        // 同族降级里 push2 不可用的表现（无状态码）
    }

    /// 限流命中时给用户的**可行动提示**（追加在失败文案后；未命中返回 nil）。
    /// 文案刻意短（toast 只 2 行）、且给出去路（换网络 / 稍后再试），不是又一条"失败了"。
    public static func throttleHint(_ httpReason: String?) -> String? {
        isSuspectedThrottle(httpReason) ? "疑似出口 IP 被限流 · 换网络或稍后再试" : nil
    }

    // MARK: - 名称清洗

    /// 去除 NUL 等控制字符与首尾空白（新浪定宽字段常见名称尾部带 \x00）
    public static func cleanName(_ name: String) -> String {
        if name.isEmpty { return "" }
        let filtered = String(name.unicodeScalars.filter {
            !($0.value <= 0x1f || $0.value == 0x7f)
        })
        return filtered.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - HTTP（同步，带重试）

    /// GET 结果盒子：URLSession 回调在后台线程，用锁把结果安全带回同步调用方
    private final class HTTPResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var text: String?
        private var error: String?
        func store(text: String) { lock.lock(); self.text = text; lock.unlock() }
        func store(error: String) { lock.lock(); self.error = error; lock.unlock() }
        func load() -> (text: String?, error: String?) {
            lock.lock(); defer { lock.unlock() }
            return (text, error)
        }
    }

    static let gb18030: String.Encoding = {
        let cf = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        return String.Encoding(rawValue: cf)
    }()

    /// HTTP GET（带重试）。**同步**阻塞当前线程（这些函数会被后台线程调用，不要假设主线程）。
    /// 全部失败返回 nil 并记 logDataSource("http","error",...)。HTTP 200 才算成功。
    /// `deadline`：整轮取数预算。传了就**不再跨过该时刻重试** ——
    /// 否则一个已经超预算的批次仍会把 3 次重试全跑完（最坏再拖 46s），预算就形同虚设。
    /// 某个 host 的**同族降级候选**（首个是当前代码写死的那个）。
    ///
    /// ## 为什么只列 `push2his` → `push2ex`（实测）
    /// 连打 3 次、带完整 UA + Referer：
    /// · `push2ex/api/qt/clist/get` ⇒ HTTP 404（该路径在 push2ex 上**不存在**，
    ///   因此 `push2` 承载的基本面/板块 `clist` 不配进本表，避免无效降级尝试与 `host_fallback_failed` 噪音）；
    /// · `push2ex/api/qt/stock/kline/get` ⇒ 200（**新子域自带历史 K 线路径**，供 `HistoryBarsSource` 降级）。
    static let hostFallbacks: [String: [String]] = [
        DataSourceEndpoints.eastmoneyPush2His: [
            DataSourceEndpoints.eastmoneyPush2His,
            DataSourceEndpoints.eastmoneyPush2Ex,    // 实测 push2ex 也有 kline 路径
        ],
    ]

    /// 把 URL 里的 host 换成候选表里的那一个。**只换前缀、不动路径与查询串** ——
    /// 这是"同族降级"的前提：调用方只对已验证同路径可用的端点配表，
    /// 换过去后由调用方的解析/完整性校验继续把关。
    ///
    /// ⚠ **参数是裸主机名，不是完整 URL**（`URLComponents.host` 只认裸主机名）：
    ///   传完整 URL 会拼出 `https://https//...` 这种非法地址 ⇒ 函数返回 nil，
    ///   **降级静默失效**（而且不报错 —— 最坏的一种）。⇒ 入口处把 `https://` 前缀剥掉。
    static func rewritingHost(_ path: String, to newHost: String) -> String? {
        let bare = newHost.hasPrefix("https://") ? String(newHost.dropFirst("https://".count))
               : (newHost.hasPrefix("http://") ? String(newHost.dropFirst("http://".count)) : newHost)
        guard !bare.isEmpty else { return nil }
        guard var comps = URLComponents(string: path) else { return nil }
        // ⚠ `URLComponents(url:)` 的属性是 get-only，改 host 要用 `init(string:)` 那个**可变**初始化器。
        //   它对「带端口」「查询串里有 `:`（如 fs=m:0+t:6）」都解析正确。
        comps.host = bare
        // ⚠ 显式清端口：原 URL 若带非标准端口，换 host 后它对不上新主机
        comps.port = nil
        // ⚠ 改完**自检**：拼不出合法 URL 就返回 nil（宁可降级失败，也不要发出一个畸形请求）
        guard let out = comps.string, let check = URL(string: out), check.host == bare else { return nil }
        return out
    }

    /// 带**同族 host 降级**的 GET。成功即返回；全部候选失败返回 `nil`。
    ///
    /// ⚠ 降级只发生在「传输层失败或空响应」时 —— **解析失败不触发降级**
    ///   （那是数据/代码问题，换 host 只会掩盖它）。
    /// ⚠ 降级**必留痕**（`data_source_logs` 记 `host_degraded`）——
    ///   否则「悄悄换了个源」用户与开发者都不知道。
    static func httpGetWithHostFallback(
        _ path: String, timeout: Int = requestTimeout,
        referer: String? = nil, gbk: Bool = false,
        retries: Int = 2, deadline: Date? = nil
    ) -> String? {
        let candidates = hostFallbacks[prefix(of: path)] ?? [prefix(of: path)]
        guard candidates.count > 1 else {
            return httpGet(path, timeout: timeout, referer: referer,
                           gbk: gbk, retries: retries, deadline: deadline)
        }
        var failures: [String] = []
        for (i, host) in candidates.enumerated() {
            let target = i == 0 ? path : (rewritingHost(path, to: host) ?? path)
            if let text = httpGet(target, timeout: timeout, referer: referer,
                                   gbk: gbk, retries: retries, deadline: deadline),
               !text.isEmpty {
                if i > 0 {
                    logDataSource("http", "host_degraded",
                                  "\(prefix(of: path)) 不可用 → 降级到 \(host)（第 \(i + 1) 个候选）；"
                                  + "此前失败：\(failures.joined(separator: "；"))")
                }
                return text
            }
            failures.append("\(host) → 空/失败")
        }
        logDataSource("http", "host_fallback_failed",
                      "同族降级全部失败（\(candidates.joined(separator: ", "))）："
                      + String(fetchFailureKey(path).prefix(90)))
        return nil
    }

    /// 取 URL 的 `scheme://host` 前缀（作为降级表的键）。
    private static func prefix(of path: String) -> String {
        guard let url = URL(string: path), let scheme = url.scheme, let host = url.host else { return path }
        return "\(scheme)://\(host)"
    }

    static func httpGet(_ path: String, timeout: Int = requestTimeout,
                                referer: String? = nil, gbk: Bool = false,
                                retries: Int = 2, deadline: Date? = nil) -> String? {
        guard let url = URL(string: path) else {
            logDataSource("http", "error", "\(String(path.prefix(80))) 非法 URL")
            return nil
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = TimeInterval(timeout)
        request.setValue(ua, forHTTPHeaderField: "User-Agent")
        if let referer = referer { request.setValue(referer, forHTTPHeaderField: "Referer") }

        var lastErr = "unknown"
        let attempts = max(1, retries + 1)
        for attempt in 0..<attempts {
            if let dl = deadline, Date() >= dl {
                lastErr = "整轮预算已耗尽，放弃剩余重试"
                break
            }
            let box = HTTPResultBox()
            let sem = DispatchSemaphore(value: 0)
            let task = URLSession.shared.dataTask(with: request) { data, response, error in
                defer { sem.signal() }
                if let error = error { box.store(error: error.localizedDescription); return }
                guard let http = response as? HTTPURLResponse else { box.store(error: "无响应"); return }
                guard http.statusCode == 200 else { box.store(error: "HTTP \(http.statusCode)"); return }
                guard let data = data else { box.store(error: "空响应体"); return }
                box.store(text: decode(data, gbk: gbk))
            }
            task.resume()
            // ⚠ `sem.wait()` 不能无限等待：URLSession 超时
            //   对"已排队未开始传输"的请求不严格生效（App Nap 挂起时回调可能长期不来），
            //   后台线程会无限阻塞，外层整轮 `deadline` 拦不住单次 wait。
            //   ⇒ 加独立超时兜底：超时后取消任务并如实记错，让上层看到"请求超时"而不是卡死。
            if sem.wait(timeout: .now() + .seconds(timeout + 5)) == .timedOut {
                task.cancel()
                box.store(error: "请求 \(timeout + 5)s 未收到回调（已取消，可能被系统挂起）")
            }
            let (text, err) = box.load()
            if let text = text { return text }
            lastErr = err ?? "unknown"
            if attempt < retries {
                Thread.sleep(forTimeInterval: 0.3 * Double(attempt + 1))
            }
        }
        // ⚠ 只记 `scheme://host/path`，**不带 query**（2026-10-16 审查 B4）：
        //   原先写 `String(path.prefix(80))`，而涨停池那条 URL 的
        //   `https://push2ex.eastmoney.com/getTopicZTPool?ut=` 恰好 48 字符 ——
        //   80 字符的窗口把**整枚 `ut` token 的尾部抄进 `data_source_logs.detail`**，
        //   而这张表会随 `scripts/backup_data.sh` 一起归档外发。
        //   token 本身是公开的（见 `DataSourceEndpoints` 的注释），但它不该
        //   以"凭证的形状"散落在用户数据备份与诊断页里。
        logDataSource("http", "error",
                      "\(String(fetchFailureKey(path).prefix(80))) \(lastErr)")

        // 供上层"如实报错"（见 `lastFetchFailureReason(matching:)`）：只记不抛
        recordFetchFailure(path, lastErr)
        return nil
    }

    /// 解码响应体。`gbk=true` 按 GB18030 解；否则优先 UTF-8（新浪 JSON 接口均为 UTF-8），
    /// 失败再回退 GB18030，避免中文乱码。
    ///
    /// ⚠ 降级必须留痕：`String(decoding:as:)` **永不失败**，非法字节会被写成 U+FFFD。
    ///   GBK 响应只要有一个坏字节，整段中文名就变乱码，而数字字段是 ASCII 仍能正常解析
    ///   → **乱码名称照常落库**，界面上一片"锟斤拷"却查不到任何数据源日志。
    ///   ⇒ 走降级路径就记一条 `data_source_logs`，并返回 U+FFFD 计数供上层判断。
    static func decode(_ data: Data, gbk: Bool) -> String {
        let strict: String? = gbk ? String(data: data, encoding: gb18030)
                                  : (String(data: data, encoding: .utf8)
                                     ?? String(data: data, encoding: gb18030))
        if let s = strict { return s }
        let fallback = String(decoding: data, as: UTF8.self)
        let bad = fallback.unicodeScalars.filter { $0 == "\u{FFFD}" }.count
        logDataSource("http", "decode_fallback",
                      "严格解码失败，回退 UTF-8 替换（\(data.count) 字节，\(bad) 个非法字符）")
        return fallback
    }

    // MARK: - 交易日历

    /// 行情时间戳（quote_time = YYYYMMDDHHMMSS）→ YYYY-MM-DD。
    /// 只取前 8 位；缺失/非数字返回 nil（不猜日期）。
    public static func quoteDate(_ quote: [String: Any]) -> String? {
        let raw = pyStr(quote["quote_time"])
        let d = String(raw.prefix(8))
        guard d.count == 8, d.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return "\(d.prefix(4))-\(d.dropFirst(4).prefix(2))-\(d.dropFirst(6))"
    }

    /// 整批行情的报价日期若**落后于 today**，返回该日期；否则 nil。
    ///
    /// 为什么取样本中的**最大值**：停牌股的时间戳停在停牌前，只有「有任何一只在更新」
    /// 才说明这批行情是活的 —— 取最大值可避免把正常交易日误判成休市。
    public static func staleQuoteDate(_ quotes: [String: [String: Any]], today: String,
                               sample: Int = 200) -> String? {
        if quotes.isEmpty || today.isEmpty { return nil }
        var best: String?
        var i = 0
        for q in quotes.values {
            if i >= sample { break }
            i += 1
            if let d = quoteDate(q), best == nil || d > best! { best = d }
        }
        if let best = best, best < today { return best }
        return nil
    }

    /// (是否交易日, 原因)。周末直接跳过；工作日以「上证行情是否为当日」判定。
    ///
    /// 先看报价时间戳的**日期**：与「今日」不符即视为休市/数据未更新（节假日腾讯仍返回上一
    /// 交易日行情，只看 volume>0 会把休市误判为交易日）。时间戳缺失时退回旧口径 volume>0。
    ///
    /// ⚠ **fixture 分支必须在周末判定之前**：fixture 模式下快照是唯一事实来源 ——
    ///   若先判周末，同一份离线快照在**周末**回放会被判成「周末」→ 整轮跳过，
    ///   而快照的 meta 明明写着 `is_trading_day: true`，违反核心不变量
    ///   「**同快照必同结果**」（结果绝不能取决于"你哪天跑"）。
    /// 交易日判定的**置信度**。
    ///
    /// ⚠ 为什么要把"猜"从结论里分出来（2026-10-16 审查 B5-5）：
    ///   指数行情取不到时结论只能是"工作日，默认开盘"。对时间敏感的三轮扫描，
    ///   折叠成 `true` 是对的（宁可多扫，不要全天不扫）；但对**整日重插型**任务
    ///   （板块热度：删今天再插、源本身**没有日期字段**），
    ///   "猜今天开盘"会让上一交易日的 496 个板块被盖章成今天、
    ///   覆盖库里原有当日数据，且界面上与真数据毫无区别（还报「已更新」）。
    ///   ⇒ 写型任务判 `tradingDayVerdict` 并把 `.unknown` 当作"今天不写"。
    public enum TradingDayVerdict: Equatable, Sendable {
        case trading(reason: String)
        case closed(reason: String)
        /// 无从判断（指数行情为空/超时）：`isTradingDay` 会折叠成 `true`
        case unknown(reason: String)
    }

    public static func tradingDayVerdict(_ d: Date = Date()) -> TradingDayVerdict {
        // 回放模式：回放日是从缓存交易日历里挑出来的，**恒为交易日**（且是确认过的）。
        //
        // ⚠ 不能让它走下面的行情日期判定：那条会拿**实时**指数报价比对
        // `quoteDate(idx) < 今天` → 而回放日的报价日期必然 < 今天 →
        // 被判成"行情未更新（休市）"，整轮回放当场作废。
        // `d` 参数只有默认值一个调用形态（`Date()`），故不参与判定。
        if let day = HistoryReplayMode.activeDay { return .trading(reason: "回放 \(day)") }
        if let fx = fixture("meta.json") as? [String: Any] {
            let key = "is_trading_day"
            // ⚠ fixture 分支必须在周末判定之前（原注释的理由不变）：离线快照是唯一事实来源，
            //   同一份快照绝不能因为"你哪天跑"得出不同结论。
            if !fx.keys.contains(key) { return .trading(reason: "fixture") }   // 键缺失默认 true
            if let b = fx[key] as? Bool {
                return b ? .trading(reason: "fixture") : .closed(reason: "fixture")
            }
            return .closed(reason: "fixture")                                    // 显式为 null → false
        }
        // Calendar.weekday：1=周日 … 7=周六
        let wd = shCalendar.component(.weekday, from: d)
        if wd == 1 || wd == 7 { return .closed(reason: "周末") }
        // 工作日先问**交易所官方日历**（深交所 monthList，含调休与未来日）：
        // 拿"行情有没有在更新"当节假日判据是间接证据 —— 上一交易日的报价照样能取到，
        // 反之指数取不到时又只能"默认开盘"。官方结论拿到就不再猜；
        // 取不到（未发布 / 网络失败 / fixture / 回放）返回 nil，继续走下面的行情推断。
        if let official = TradingCalendarSource.verdict(for: d) { return official }
        let idx = fetchIndexQuote()
        if !idx.isEmpty {
            if let qd = quoteDate(idx), qd < dayFormatter.string(from: d) {
                return .closed(reason: "行情未更新（报价日期 \(qd)，非今日）→ 视为休市")
            }
            // 先看报价时间戳的**日期**：与「今日」不符即视为休市/数据未更新（节假日腾讯仍返回上一
            // 交易日行情，只看 volume>0 会把休市误判为交易日）。时间戳缺失时退回旧口径 volume>0。
            if let v = numValue(idx["volume"]), v > 0 { return .trading(reason: "交易日") }
            return .closed(reason: "节假日(无成交)")
        }
        return .unknown(reason: "工作日(默认)")
    }

    /// 交易日判定（既有 API）。
    ///
    /// ⚠ **fail-open**：判据来源不可得时按"开盘"处理并返回 reason="工作日(默认)"。
    ///   时间敏感的扫描要用它；**会整表覆盖某天的写入**请用 ``tradingDayVerdict(_:)``
    ///   并对 `.unknown` 拒绝（理由见该类型注释）。
    public static func isTradingDay(_ d: Date = Date()) -> (trading: Bool, reason: String) {
        switch tradingDayVerdict(d) {
        case .trading(let r): return (true, r)
        case .closed(let r): return (false, r)
        case .unknown(let r): return (true, r)
        }
    }


    // MARK: - 私有工具

    /// Any → String：缺失/null → ""（配合 zfill/cleanName 的「空即跳过」语义）；
    /// bool → "True"/"False"（与快照/引擎文本形态一致）
    static func pyStr(_ v: Any?) -> String {
        guard let v = v, !(v is NSNull) else { return "" }
        if let s = v as? String { return s }
        if let n = v as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "True" : "False" }
            return String(describing: n)
        }
        return String(describing: v)
    }

    /// 数值取值（Double/Int/NSNumber/String→Double），失败 nil
    ///
    /// ⚠ `inf` / `nan` 一律折成 `nil`：`Double("inf")` 与 `Double("1e400")` 都得到 `inf`，
    ///   而下游存在 `Int(<Double>)` 的调用点（如 `LhbSource` 的 `tradeId`）→
    ///   **`Int(inf)` 直接 trap 且不可 catch**。折 `nil` 而不是 `0`：
    ///   `0` 在本项目里是**有意义的值**（如「资产负债率 0%」）。
    ///   实现是 `Num.doubleOrNil`。
    static func numValue(_ v: Any?) -> Double? { Num.doubleOrNil(v) }

    /// JSON 数值（新浪字段通常是 String，也可能直接是数字）；缺失/非法 nil
    ///
    /// ⚠ 同 `numValue`：`inf` / `nan` 折 `nil`。实现是 `Num.doubleOrNil`。
    static func jsonNum(_ v: Any?) -> Double? { Num.doubleOrNil(v) }

    /// `arr[-n:]` 切片语义（含 -0/负数的极端边界；调用方实际只传正数 datalen）
    static func pyTail<T>(_ arr: [T], _ n: Int) -> [T] {
        if n == 0 { return arr }              // Python arr[-0:] == arr[:]
        if n < 0 {
            let start = -n
            return start < arr.count ? Array(arr[start...]) : []
        }
        return Array(arr.suffix(n))
    }

    static func klineBar(_ d: [String: Any]) -> KLineBar {
        KLineBar(day: d["day"] as? String ?? "",
                 open: jsonNum(d["open"]) ?? 0, high: jsonNum(d["high"]) ?? 0,
                 low: jsonNum(d["low"]) ?? 0, close: jsonNum(d["close"]) ?? 0,
                 volume: jsonNum(d["volume"]) ?? 0)
    }

    static func zfill6(_ s: String) -> String {
        if s.count >= 6 { return s }
        return String(repeating: "0", count: 6 - s.count) + s
    }

    /// 格式化为 1 位小数的百分数（`{x:.1%}` 语义）
    static func pct1(_ x: Double) -> String {
        String(format: "%.1f%%", x * 100)
    }
}
