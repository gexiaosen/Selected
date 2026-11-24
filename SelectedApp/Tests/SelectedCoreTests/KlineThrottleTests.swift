import Testing
import Foundation
@testable import SelectedCore

/// `DataSources.KlineThrottle` —— 新浪 K 线请求的**全局**限速器。
///
/// 为什么值得单独钉：它的价值完全体现在"并发下排队"，而**任何单条串行路径都测不出来**
/// （线程级睡眠在串行下与全局排队逐字等价）。一旦它退化成线程级睡眠，数据源的限速
/// 会**静默失效** —— 表现只是"某天开始偶尔取不到数"，没有任何断言会响。
///
/// 用**独立实例**（不是 `DataSources.klineThrottle` 全局那个）：Swift Testing 默认
/// 并行执行，用例之间不该通过全局单例互相干扰。
@Suite("K线全局限速器（并发排队，串行等价旧行为）", .serialized)
struct KlineThrottleTests {


    /// `interval <= 0`（fixture 模式 / `SELECTED_KLINE_DELAY=0`）必须**立刻返回**：
    /// 离线跑批（单测等）一秒钟都不该付。
    @Test func zeroIntervalDoesNotBlock() {
        let throttle = DataSources.KlineThrottle()
        let t0 = Date()
        for _ in 0..<50 { throttle.wait(0) }
        // ⚠ 上界放宽到 0.5s（2026-10-16 审查 B7）：原先卡 `< 0.05` 是**真实墙钟**比较，
        //   在满载 runner（15 个套件顺序编译 + 并发跑）上 50 次空转也可能越过 50ms，
        //   于是一条"限速器没退化"的断言变成了随机红。判据要表达的是
        //   "**不睡眠**"，那 50 次最多是微秒级 —— 0.5s 足够把"真的睡了 50×0.05=2.5s"分开。
        #expect(Date().timeIntervalSince(t0) < 0.5, "interval=0 必须直接返回（不睡眠）")
    }

    /// `klineDelay()` 在**非 fixture** 模式下不允许降到 0（2026-10-16 审查 B4 加的下界）。
    /// 原来 `SELECTED_KLINE_DELAY=0` 等于把全局限速整个关掉，而
    /// `KlineThrottle.wait` 在 `interval <= 0` 时是先返回再取锁 —— 并发取数于是无上限。
    /// 这条钉住"环境变量是调速旋钮、不是开关"。
    @Test func envCannotDisableThrottle() {
        setenv("SELECTED_KLINE_DELAY", "0", 1)
        defer { unsetenv("SELECTED_KLINE_DELAY") }
        let d = DataSources.klineDelay()
        #expect(d >= DataSources.minNetworkKlineDelay,
                "环境变量给 0 也必须落到下界，实际：\(d)")
    }

    /// 串行：N 次 wait 的总耗时 ≈ N × interval。
    /// 只用**下界**卡（sleep 保证不早醒），上界留给调度抖动。
    @Test func serialWaitsAccumulate() {
        let throttle = DataSources.KlineThrottle()
        let t0 = Date()
        for _ in 0..<4 { throttle.wait(0.05) }
        #expect(Date().timeIntervalSince(t0) >= 0.2)
    }

    /// 并发：4 个线程同时 wait → 总耗时 ≥ 4 × interval（排队）。
    ///
    /// 这条就是本类存在的全部理由：若实现退回成"各线程各睡 0.05"，总耗时会落在 ~0.05，
    /// 用例必红 —— 而那种退化在串行用例里**看不出来**。
    @Test func concurrentWaitsAreSerialized() {
        let throttle = DataSources.KlineThrottle()
        let t0 = Date()
        DispatchQueue.concurrentPerform(iterations: 4) { _ in throttle.wait(0.05) }
        #expect(Date().timeIntervalSince(t0) >= 0.2)
    }

    /// 异步限速器：interval <= 0 立即返回（零阻塞）
    @Test func asyncZeroIntervalDoesNotBlock() async {
        let throttle = DataSources.AsyncKlineThrottle()
        let t0 = Date()
        for _ in 0..<50 { await throttle.wait(0) }
        #expect(Date().timeIntervalSince(t0) < 0.5)
    }

    /// 异步限速器：并发 TaskGroup 调用必须按截止时刻错峰排队（防 actor 可重入性绕过限速）
    @Test func asyncConcurrentWaitsAreSerialized() async {
        let throttle = DataSources.AsyncKlineThrottle()
        let t0 = Date()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask { await throttle.wait(0.05) }
            }
        }
        #expect(Date().timeIntervalSince(t0) >= 0.19)
    }
}