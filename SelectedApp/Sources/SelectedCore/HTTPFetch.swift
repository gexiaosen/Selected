import Foundation

/// 带**状态码校验**的 HTTP GET（async）—— 直连 `URLSession` 的**唯一**出口。
///
/// ## 为什么必须有这个文件
/// 直连 `URLSession` 时若把 `URLResponse` 扔掉（`let (data, _) = …`），
/// **任何状态码都被当成成功**：403 / 500 返回的 **HTML 错误页会被当数据去解析** ——
/// 表现是"这只票没数据"或"解析出 0 条"，而**不是报错**。这类故障最难查：
/// 数据源挂了，界面看起来只是"今天票少"。
///
/// ## 用法
///
/// ```swift
/// let data = try await HTTPFetch.get(req)                       // ✅ 非 2xx 抛错
/// let (data, _) = try await URLSession.shared.data(for: req)    // ❌ 状态码被丢掉
/// ```
///
/// ⚠ **只在 2xx 时返回**。调用方照旧 `do/catch` 后 `return nil`。
/// ⚠ 禁止直连 `URLSession` 丢掉响应 —— 一律走本函数。
public enum HTTPFetch {

    /// 取数失败的原因（**带上状态码与响应体开头**，便于分辨"403 限流"与"500 源故障"）
    public struct Failure: Swift.Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    /// ⚠ **可注入的 session**（默认 `nil` ⇒ 用 `.shared`，行为不变）。
    ///
    /// ## 为什么需要
    /// 没有注入点时，`get()` 里那三段分支（非 HTTP 响应 / 非 2xx / 2xx）
    /// 无法离线覆盖 —— 而它们恰恰是数据源故障时最常走的路径
    /// （403 限流 / 500 源故障 / 代理注入 HTML 错误页）。
    ///
    /// ## 怎么用（测试里）
    /// ```swift
    /// HTTPFetch.sessionOverride = URLSession(configuration: .ephemeral)  // 配 protocolClasses
    /// defer { HTTPFetch.sessionOverride = nil }
    /// ```
    /// 用 `URLProtocol` 子类拦截，不发真实请求 ⇒ 离线可测、结果确定。
    ///
    /// ## 为什么用 `nonisolated(unsafe)` 而不是 actor
    /// 它是**测试专用的逃逸口**，生产代码永远不写。`URLSession` 在 macOS 上属 Foundation，
    /// **不违反** `CoreLayeringTests` 的 `bannedImports`（那里只禁 SwiftUI/AppKit/Cocoa/
    /// Observation/Charts/UserNotifications）。
    nonisolated(unsafe) public static var sessionOverride: URLSession?

    /// 实际使用的 session（有 override 用 override）。
    static var activeSession: URLSession { sessionOverride ?? .shared }

    /// GET → 响应体。非 2xx / 非 HTTP 响应 → **抛错**。
    ///
    /// ⚠ 3xx 不用特判：`URLSession` 默认跟随重定向，这里拿到的是**最终**响应。
    ///   若某天真需要"不跟随"，那要改 `URLSessionConfiguration`，不是改这里。
    public static func get(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await activeSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Failure(message: "响应不是 HTTPURLResponse（拿不到状态码）")
        }
        guard (200...299).contains(http.statusCode) else {
            // ⚠ 不带响应体原文（2026-10-16 审查 B4）：原先取"前 80 字节"塞进错误文案，
            //   而这个 `Failure.message` 会经 `errorDescription` 一路冒到
            //   **toast 与系统通知**（`Scheduler` 的失败通知直接用它）——
            //   于是代理门户/认证页面的 HTML（可能含 URL query、会话参数）
            //   会被写进用户可见通道并长期留在通知中心。
            //   状态码 + Content-Type + 字节数已经足够分辨"限流页 / 错误页 / 空体"。
            let ctype = http.value(forHTTPHeaderField: "Content-Type") ?? "未知"
            throw Failure(message: "HTTP \(http.statusCode)（非 2xx → 不把响应体当数据解析）"
                          + "；类型 \(ctype) · \(data.count) 字节")
        }
        return data
    }
}
