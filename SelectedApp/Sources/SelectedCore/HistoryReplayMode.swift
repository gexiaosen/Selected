import Foundation

/// 历史回放模式 —— **进程级开关**
///
/// ## 它做什么
/// 激活后 `DataSources` 的全部取数改由 `history.sqlite3` 缓存供给：
/// 「当日」变成回放日、行情由日K重建、5 分钟线恒空（→ 尾盘分时维度自动跳过）。
/// **关闭后行为回到正常** —— 回归测试与黄金夹具是这条的护栏。
///
/// ## ⚠ 为什么必须防并发
/// 这是**进程级**状态，而调度器会在定时器上跑实时扫描。若两者交叠，
/// 调度器那一轮会以为「今天是回放日」，把**重建出来的历史行情当成今天**
/// 写进 `scan_rounds` / `picks` / `reviews` —— 库被静默污染，事后无法区分。
/// → 调度器与界面的手动扫描入口都必须先查 `isActive` 并跳过（见 `Scheduler`）。
///
/// ## ⚠ 不可嵌套
/// `begin` 在已激活时返回 `false`。嵌套意味着两个回放日共用同一份全局状态，
/// 后进入的那个会静默改写前一个的日期，而两边都不会报错。
///
/// ## 为什么是全局开关而不是参数
/// 需要它的地方在调用链深处且**没有参数可传**：`Screener.buildMarketEnv` 内部
/// 硬编码 `DataSources.runDate()`，`DataSources.isTradingDay()` 连调用方都没有。
/// 把日期一路穿下去要改十几个签名，而回放是**显式的批处理操作**
/// （由编排器成对 `begin` / `end`），全局开关是这里更小的改动面。
/// 代价就是上面那条并发纪律。
public enum HistoryReplayMode {

    /// 状态盒子。
    ///
    /// ⚠ 必须是 `final class + @unchecked Sendable`，不能写成 `private static var day: String?`：
    /// Swift 6 严格并发**不允许裸的可变全局状态**（编译期直接报
    /// `static property is not concurrency-safe`）。锁由类自己持有 ——
    /// 与 `DataSources.KLineCache` 同一写法、同一理由。
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var day: String?
        private var session = false

        var value: String? {
            lock.lock(); defer { lock.unlock() }
            return day
        }

        var sessionRunning: Bool {
            lock.lock(); defer { lock.unlock() }
            return session
        }

        /// 只在**尚未激活**时写入。返回是否写入成功（不覆盖已有的回放日）
        func activate(_ d: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard day == nil else { return false }
            day = d
            return true
        }

        func clear() {
            lock.lock(); defer { lock.unlock() }
            day = nil
        }

        func startSession() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !session else { return false }
            session = true
            return true
        }

        func stopSession() {
            lock.lock(); defer { lock.unlock() }
            session = false
        }
    }

    private static let box = Box()

    /// 当前回放日（`yyyy-MM-dd`）；`nil` = 未启用
    public static var activeDay: String? { box.value }

    public static var isActive: Bool { box.value != nil }

    /// ⚠ **整段**回放是否正在进行（跨天）—— 与 `activeDay` **不是同一件事**。
    ///
    /// `activeDay` 在**每一天的两段之间**会被清掉（扫描用 D、预判/复盘用 D+1，两段各
    /// `begin`/`end` 一次）。若只看它，调度器就可能正好在那个空隙里触发一轮**实时扫描**：
    /// 那时回放模式是关的，于是它把**实盘行情**写进库 —— 而回放正跑到一半，
    /// 事后完全无法区分哪些行是回放写的、哪些是实时写的。
    ///
    /// → 「回放期间不得并发取数」这条纪律要成立，判据必须是
    /// **`isActive || isRunning`**（`HistoryReplayMode.isBusy`），不能只看 `isActive`。
    public static var isRunning: Bool { box.sessionRunning }

    /// 合起来的判据 —— **调用方一律用这个**，别只查 `isActive`。
    public static var isBusy: Bool { box.sessionRunning || box.value != nil }

    /// 进入回放。已激活 / `day` 为空 → 返回 `false`（**不覆盖**已有的回放日）
    @discardableResult
    public static func begin(_ d: String) -> Bool {
        guard !d.isEmpty else { return false }
        return box.activate(d)
    }

    /// 退出回放。未激活时是空操作（便于 `defer`）
    public static func end() { box.clear() }

    /// 开启**整段**回放会话（编排器在跑多天时用）。已在会话中 → `false`（不嵌套）
    @discardableResult
    public static func beginSession() -> Bool { box.startSession() }

    /// 结束整段回放会话。不在会话中时是空操作（便于 `defer`）
    public static func endSession() { box.stopSession() }

    /// 在回放模式下执行 `body`，**无论成败都退出**。
    /// 已在回放中 → 直接返回 `nil`（不嵌套，见类型注释）。
    public static func withDay<T>(_ d: String, _ body: () throws -> T) rethrows -> T? {
        guard begin(d) else { return nil }
        defer { end() }
        return try body()
    }

    /// 「当日」的**回放感知**取法 —— 给那些「用当日剔除未完成 bar」的纯计算用。
    ///
    /// · 正常模式（live / fixture）→ 墙上时钟。
    ///   ⚠ 不能统一改成 `runDate()`：fixture 的日历里含快照日**之后**的 bar，
    ///   一旦按快照日剔除，"当日"那根就不再被剔掉 → 连跌结论变化。
    /// · 回放模式 → 回放日。
    ///
    /// 为什么必须区分：这些函数拿 `today` 去**剔除指数日K里"当日那根未完成的 bar"**，
    /// 同时把当日涨跌**另外**作为参数传进来（`marketConsecutiveDecline` 的
    /// `todayChangePct`）。回放时若仍用墙上时钟，回放日那根 bar 既进 `deltas`、
    /// 又被当成 `todayChangePct` 加一次 —— **同一个交易日被数两遍**。
    public static var currentDay: String { activeDay ?? ChinaTime.day() }
}
