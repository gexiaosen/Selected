import XCTest
import Foundation
@testable import SelectedCore

/// `HTTPFetch.get()` 的**离线**测试。
///
/// ## 为什么需要这个文件
/// `HTTPFetch` 是全仓「带状态码校验的 HTTP GET」的**唯一出口**，它内部有三段分支：
/// ① 响应不是 `HTTPURLResponse` → 抛「拿不到状态码」
/// ② 非 2xx → 抛错，**且不把响应体当数据返回**（这正是它存在的意义）
/// ③ 2xx → 正常返回
///
/// 这三段恰恰是**数据源故障时最常走的路径**（403 限流 / 500 源故障 / 代理注入 HTML 错误页），
/// 而全仓回归「全部离线、无网络访问」⇒ 没有这个文件，故障路径就完全不在回归里。
///
/// ## 怎么做到离线
/// 用 `URLProtocol` 子类**拦截**所有请求：既不发真实网络请求，也不依赖网络状态。
/// 这也是本仓**唯一**合理使用 `HTTPFetch.sessionOverride` 的地方 —— 它是测试专用逃逸口。
final class HTTPFetchTests: XCTestCase {

    // MARK: - 拦截器

    /// 按 `nextResult` 返回预设结果的 `URLProtocol` 子类。
    ///
    /// `URLProtocol` 的 `canInit(with:)` **对每个请求都返回 true**，不做 host 过滤 ——
    ///   这是**故意的**：本测试只验证 `HTTPFetch` 对响应的处理，不关心请求打到哪个 host。
    ///   （若将来要测多 host 场景，需要在 `startLoading` 里按 `request.url` 分派。）
    private final class StubProtocol: URLProtocol {
        /// 供测试逐个用例改写（`StubProtocol.next` 是全局状态，故每个用例用 `defer` 复位）。
        nonisolated(unsafe) static var next: StubResult = .success(Data("ok".utf8))
        /// 记录请求确实经过了这里（用来证明"拦截成功，而不是真的联网成功了"）。
        nonisolated(unsafe) static var hitCount = 0

        struct StubResult {
            let status: Int
            let body: Data
            /// 非 HTTP 响应用：`URLResponse`（无状态码）
            let isHTTP: Bool
            /// 传输层错误（如超时 / 连接失败）
            let error: Error?

            static func success(_ body: Data) -> StubResult {
                .init(status: 200, body: body, isHTTP: true, error: nil)
            }
            static func status(_ code: Int, _ body: String = "") -> StubResult {
                .init(status: code, body: Data(body.utf8), isHTTP: true, error: nil)
            }
            static func nonHTTP(_ body: String) -> StubResult {
                .init(status: 0, body: Data(body.utf8), isHTTP: false, error: nil)
            }
            static func transportError(_ message: String) -> StubResult {
                .init(status: 0, body: Data(), isHTTP: true,
                      error: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut,
                                     userInfo: [NSLocalizedDescriptionKey: message]))
            }
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}

        override func startLoading() {
            Self.hitCount += 1
            let r = Self.next
            if let err = r.error {
                client?.urlProtocol(self, didFailWithError: err)
                return
            }
            let response: URLResponse = r.isHTTP
                ? HTTPURLResponse(url: request.url!, statusCode: r.status,
                                  httpVersion: "HTTP/1.1", headerFields: nil)!
                : URLResponse(url: request.url!, mimeType: "text/plain",
                              expectedContentLength: r.body.count, textEncodingName: nil)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: r.body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    // MARK: - 测试脚手架

    /// 装上拦截器、跑 body、必复原（否则会污染同批其他测试）。
    private func withStub<Result>(
        _ result: StubProtocol.StubResult,
        _ body: () async throws -> Result
    ) async throws -> Result {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProtocol.self]
        HTTPFetch.sessionOverride = URLSession(configuration: cfg)
        StubProtocol.next = result
        StubProtocol.hitCount = 0
        defer {
            HTTPFetch.sessionOverride = nil
            StubProtocol.next = .success(Data())
        }
        return try await body()
    }

    private let req = URLRequest(url: URL(string: "https://example.invalid/probe")!)

    // MARK: - ① 2xx 正常路径

    func test2xxReturnsBodyVerbatim() async throws {
        let body = try await withStub(.success(Data("v=1.23%3C4%3E".utf8))) {
            try await HTTPFetch.get(req)
        }
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "v=1.23%3C4%3E",
                       "2xx 必须原样返回响应体（上游就是 GBK/百分号编码的查询串，不能被改写）")
    }

    func test299IsTreatedAsSuccess() async throws {
        let body = try await withStub(.status(299, "edge")) { try await HTTPFetch.get(req) }
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "edge",
                       "299 属 2xx 上界，必须成功（判据是闭区间 200...299）")
    }

    // MARK: - ② 非 2xx 必须抛错，且**不把响应体当数据返回**

    /// 本测试是这个文件里**最重要的一条** ——
    /// 防的是：把 `URLResponse` 扔掉 ⇒ 任何状态码都被当成成功，
    /// 403/500 返回的 HTML 错误页被当数据去解析。
    func test403ThrowsAndDoesNotReturnHTMLBody() async throws {
        let html = "<html><body>403 Forbidden</body></html>"
        do {
            let body = try await withStub(.status(403, html)) { try await HTTPFetch.get(req) }
            XCTFail("403 必须抛错，却返回了 \(String(decoding: body, as: UTF8.self))"
                    + " —— 这是本文件要防的那个回归")
        } catch let e as HTTPFetch.Failure {
            let m = e.message
            XCTAssertTrue(m.contains("403"), "错误信息要带状态码便于分辨限流与源故障，实际：\(m)")
            // ⚠ 口径已反转（2026-10-16 审查 B4）：错误信息**不得**再带响应体原文 ——
            //   这个 message 会经 `errorDescription` 冒到 toast 与**系统通知**，
            //   代理门户/认证页的 HTML（可能含 URL query、会话参数）会长期留在通知中心。
            //   改记「Content-Type + 字节数」，同样能分辨"限流页 / 错误页 / 空体"。
            XCTAssertFalse(m.contains("Forbidden"),
                           "错误信息不应外泄响应体原文，实际：\(m)")
            XCTAssertTrue(m.contains("字节"),
                          "错误信息应带响应字节数作为替代线索，实际：\(m)")
        }

    }

    func test500Throws() async throws {
        do {
            _ = try await withStub(.status(500, "server error")) { try await HTTPFetch.get(req) }
            XCTFail("500 必须抛错")
        } catch let e as HTTPFetch.Failure {
            XCTAssertTrue(e.message.contains("500"), "实际：\(e.message)")
        }
    }

    /// 199（1xx）与 300（3xx 边界）都应判失败。
    ///
    /// 3xx 在真实 `URLSession` 里默认被跟随（`HTTPURLResponse.swift:37-38` 已注明），
    ///   所以线上几乎遇不到 3xx 落到这里；但**闭区间判据**本身要钉住 —— 若将来有人把
    ///   `(200...299)` 改成 `200..<300` 之类的手滑，这里能抓到。
    func testNon2xxBoundariesThrow() async throws {
        for code in [100, 199, 300, 400, 418] {
            do {
                _ = try await withStub(.status(code, "x")) { try await HTTPFetch.get(req) }
                XCTFail("\(code) 应判失败")
            } catch is HTTPFetch.Failure {
                // 预期
            }
        }
    }

    // MARK: - ③ 非 HTTP 响应

    func testNonHTTPResponseThrowsWithExplicitMessage() async throws {
        do {
            _ = try await withStub(.nonHTTP("plain")) { try await HTTPFetch.get(req) }
            XCTFail("非 HTTPURLResponse 必须抛错")
        } catch let e as HTTPFetch.Failure {
            XCTAssertTrue(e.message.contains("HTTPURLResponse"),
                          "错误信息要点明「拿不到状态码」，实际：\(e.message)")
        }
    }

    // MARK: - ④ 传输层错误

    /// 超时 / 连接失败**不是** `HTTPFetch.Failure`（那是应用层的），而是 `URLError`
    /// ⇒ 调用方的 `catch` 必须能区分「拿到响应但状态码不对」与「压根没拿到响应」。
    func testTransportErrorPropagatesAsURLError() async throws {
        do {
            _ = try await withStub(.transportError("timed out")) { try await HTTPFetch.get(req) }
            XCTFail("传输层错误必须抛")
        } catch let e as HTTPFetch.Failure {
            XCTFail("传输层错误不该被包装成 Failure（会与「状态码不对」混淆），实际：\(e.message)")
        } catch {
            let ns = error as NSError
            XCTAssertEqual(ns.domain, NSURLErrorDomain)
            XCTAssertEqual(ns.code, NSURLErrorTimedOut)
        }
    }

    // MARK: - ⑤ 拦截器本身生效（防"测试其实联网了但通过"）

    func testStubProtocolActuallyIntercepts() async throws {
        _ = try await withStub(.success(Data("x".utf8))) { try await HTTPFetch.get(req) }
        XCTAssertGreaterThan(StubProtocol.hitCount, 0,
                             "StubProtocol 一次都没被命中 ⇒ 测试可能真的联网了（或注入点没生效）")
    }

    // MARK: - ⑥ 注入点复原后回到 .shared

    /// 防「某个测试忘了复位 `sessionOverride`，污染后续所有测试」。
    func testSessionOverrideIsNilByDefault() {
        XCTAssertNil(HTTPFetch.sessionOverride,
                     "默认必须是 nil（用 URLSession.shared）—— 有测试忘了复原")
    }
}
