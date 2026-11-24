import XCTest
@testable import SelectedCore

/// **同族 host 降级链**的单测。
///
/// ## 为什么这值得测
/// `HostFallback` / `DataSources.rewritingHost` 是纯函数，**完全离线可测**；
/// 而它保护的东西（数据源在某个 host 挂掉时自动切换）**恰恰在出事那天才被需要** ——
/// 那正是没法现测的时刻（真挂了才有现象）。
///
/// ## 覆盖的不变量
/// ① **换 host 不动路径与查询串**（丢一个就等于换了个接口）；
/// ② **首选可用时不降级**（无谓降级会把「谁在服务」弄糊）；
/// ③ **首选失败 → 第二个胜出**，且 `attemptCount` 如实；
/// ④ **全部失败返回 nil** 且**失败原因逐条保留**（诊断要靠它）；
/// ⑤ 降级表里每个候选**都必须真实存在**（写错域名等于全员降级失败）。
///
/// **不测**「真的发 HTTP 请求」—— `run_all.sh` 自述「全部离线、无网络访问」，
///   且 `httpGet` 那条路径已有 `sessionOverride` 注入点（需要时另写联网自检）。
final class HostFallbackTests: XCTestCase {

    // MARK: - ① rewritingHost：只换 host

    func testRewritingHostKeepsPathAndQuery() {
        let url = "https://push2.eastmoney.com/api/qt/clist/get?pn=1&pz=100&fid=f12&ut=abc"
        let out = DataSources.rewritingHost(url, to: "https://push2ex.eastmoney.com")
        let comps = out.flatMap { URLComponents(string: $0) }
        XCTAssertEqual(comps?.host, "push2ex.eastmoney.com")
        XCTAssertEqual(comps?.path, "/api/qt/clist/get")
        // 查询串逐字保留 —— 少一个参数（比如 ut token）源就返回空
        XCTAssertEqual(comps?.query, "pn=1&pz=100&fid=f12&ut=abc")
    }

    func testRewritingHostRejectsGarbage() {
        XCTAssertNil(DataSources.rewritingHost("not a url", to: "https://x.example.com"))
    }

    /// 换 host 后端口要清掉：原 URL 带 `:8443` 之类时，换了新主机还带旧端口必然连不上。
    func testRewritingHostClearsPort() {
        let out = DataSources.rewritingHost("https://push2.eastmoney.com:8443/api/x?a=1",
                                            to: "push2ex.eastmoney.com")
        let comps = out.flatMap { URLComponents(string: $0) }
        XCTAssertEqual(comps?.host, "push2ex.eastmoney.com")
        XCTAssertNil(comps?.port, "端口必须被清掉，否则换 host 后仍连旧端口")
    }

    /// **回归锁**：`comps.host` 只认**裸主机名**。
    /// 调用点拿到的是 `DataSourceEndpoints` 常量（**带 `https://` 的完整 URL**），
    /// 直接混进 `comps.host` 会拼出 `https://https//push2ex.eastmoney.com/...` ⇒
    /// **函数返回 nil、降级静默失效，而且不报错**（最坏的一种失效）。
    /// 本测试钉住「传完整 URL 也能用」。
    func testRewritingHostAcceptsFullURLAsTarget() {
        let out = DataSources.rewritingHost("https://push2.eastmoney.com/api/qt/clist/get?pn=1",
                                            to: DataSourceEndpoints.eastmoneyPush2Ex)
        XCTAssertNotNil(out, "传完整 URL 作目标时不应返回 nil（否则降级静默失效）")
        XCTAssertEqual(URL(string: out ?? "")?.host, "push2ex.eastmoney.com")
        // 拼出的地址里**不能出现双斜杠协议**（`https://https//…`）
        XCTAssertFalse((out ?? "").contains("https://https"), "实际：\(out ?? "nil")")
    }

    /// 换完 host 后**必须仍是合法 URL 且 host 正确** —— 这是 `rewritingHost` 内部的自检口径。
    func testRewritingHostOutputIsAlwaysSane() {
        for target in [DataSourceEndpoints.eastmoneyPush2Ex,
                       "push2ex.eastmoney.com",
                       DataSourceEndpoints.eastmoneyPush2His] {
            let out = DataSources.rewritingHost("https://push2.eastmoney.com/a?b=c&d=e:f", to: target)
            XCTAssertNotNil(out, "目标 \(target) 换 host 失败")
            XCTAssertNotNil(URL(string: out ?? ""), "换出来的必须是合法 URL：\(out ?? "nil")")
        }
    }

    // MARK: - ②③④ firstWorking 的判定

    func testFirstCandidateWinsWithoutTryingOthers() async {
        var probed: [String] = []
        let a = await HostFallback.firstWorking(candidates: ["h1", "h2"]) { h in
            probed.append(h)
            return Data("ok".utf8)
        }
        XCTAssertEqual(a.host, "h1")
        XCTAssertEqual(a.attemptCount, 1)
        XCTAssertEqual(probed, ["h1"], "首选可用时**不许**去碰后面的候选")
    }

    func testFallsBackToSecondCandidateAndKeepsFailure() async {
        let a = await HostFallback.firstWorking(candidates: ["h1", "h2"]) { h in
            if h == "h1" { throw URLError(.cannotConnectToHost) }
            return Data("ok".utf8)
        }
        XCTAssertEqual(a.host, "h2")
        XCTAssertEqual(a.attemptCount, 2)
        // 第一个候选的失败原因必须留痕 —— 否则诊断时只剩"降级成功了"，看不到"原来为什么挂"
        XCTAssertEqual(a.tried.count, 1)
        XCTAssertEqual(a.tried.first?.host, "h1")
        // **不能断言 `localizedDescription` 含错误文本** —— macOS 上
        //   `URLError(.cannotConnectToHost).localizedDescription` 实测就是 `"(null)"`
        //   （CFNetwork 的错误文案本地化缺失，断言含文本必然假红）。
        //   ⇒ 只断言「留了痕且非空」；具体文案格式不该被测试钉死。
        XCTAssertFalse((a.tried.first?.reason ?? "").isEmpty,
                       "失败原因不能为空（否则诊断时看不到原来为什么挂）")
    }

    /// 空响应（HTTP 200 但 body 空）与抛错**同样算失败** ——
    /// 实测东财限流时正是"连上了但返回空"，那种情况不降级就会拿到 0 条数据。
    func testEmptyDataIsTreatedAsFailure() async {
        let a = await HostFallback.firstWorking(candidates: ["h1", "h2"]) { h in
            h == "h1" ? Data() : Data("ok".utf8)
        }
        XCTAssertEqual(a.host, "h2")
        XCTAssertEqual(a.tried.first?.reason, "空响应")
    }

    func testAllCandidatesFailReturnsNil() async {
        let a = await HostFallback.firstWorking(candidates: ["h1", "h2", "h3"]) { _ in
            throw URLError(.timedOut)
        }
        XCTAssertNil(a.host)
        XCTAssertEqual(a.attemptCount, 3)
        XCTAssertEqual(a.tried.count, 3, "三个候选的失败原因都要留痕")
    }

    func testDescribeMentionsWinningAndLosingHosts() {
        let ok = HostFallback.Attempt(host: "h2", tried: [(host: "h1", reason: "空响应")], attemptCount: 2)
        let d = HostFallback.describe(ok)
        XCTAssertTrue(d.contains("h2"), "应说出胜出的 host：\(d)")
        XCTAssertTrue(d.contains("h1"), "应说出失败的 host：\(d)")

        let bad = HostFallback.Attempt(host: nil, tried: [(host: "h1", reason: "超时")], attemptCount: 1)
        XCTAssertTrue(HostFallback.describe(bad).contains("超时"), "全败时必须说出原因")
    }

    // MARK: - ⑤ 降级表自身的卫生

    /// 表里的每个候选都得是**像 host 的绝对 URL**，且**不能与首选相同**
    /// （相同 ⇒ 降级永远命中第一个，降级逻辑形同虚设）。
    func testFallbackTableIsWellFormed() {
        XCTAssertFalse(DataSources.hostFallbacks.isEmpty, "降级表不该是空的")
        for (primary, candidates) in DataSources.hostFallbacks {
            XCTAssertTrue(primary.hasPrefix("https://"), "表键应是 https 绝对 URL：\(primary)")
            XCTAssertGreaterThanOrEqual(candidates.count, 2,
                                        "\(primary) 只有 1 个候选 ⇒ 降级不会发生")
            XCTAssertEqual(candidates.first, primary, "\(primary) 的**首选必须是自己**（否则语义反了）")
            for c in candidates.dropFirst() {
                XCTAssertTrue(c.hasPrefix("https://"), "候选应是绝对 URL：\(c)")
                XCTAssertNotEqual(c, primary, "候选与首选相同 ⇒ 降级空转：\(c)")
            }
            // 同族校验：**只换 host、不换数据源** ⇒ 同一 registrable domain
            //   （取最后两段：`eastmoney.com`）。判据用"后两段"而不是"第一段" ——
            //   `push2` / `push2ex` / `push2his` 第一段各不同，但**都是 eastmoney 族**。
            let fam = Set(candidates.compactMap { u -> String? in
                guard let h = URL(string: u)?.host else { return nil }
                let parts = h.split(separator: ".")
                return parts.count >= 2 ? "\(parts[parts.count - 2]).\(parts[parts.count - 1])" : h
            })
            XCTAssertEqual(fam.count, 1,
                           "\(primary) 的候选跨了源（\(candidates)）—— 跨源降级要重写口径映射，不该在这里做")
        }
    }

    /// 表里出现的每个 host 在 `DataSourceEndpoints` 都有对应常量（防拼错域名）。
    func testFallbackHostsAreDeclaredInEndpoints() {
        let declared = Set([
            DataSourceEndpoints.eastmoneyPush2,
            DataSourceEndpoints.eastmoneyPush2Ex,
            DataSourceEndpoints.eastmoneyPush2His,
            DataSourceEndpoints.eastmoneyDataCenter,
        ])
        for (_, candidates) in DataSources.hostFallbacks {
            for c in candidates {
                XCTAssertTrue(declared.contains(c), "候选 \(c) 不在 DataSourceEndpoints 的常量集合里")
            }
        }
    }

    /// `push2` 仅承载 `clist/get`，而 `push2ex` 无该路径：不该挂进降级表避免无效尝试与假失败噪音。
    func testClistPush2DoesNotPairInvalidPush2ExFallback() {
        XCTAssertNil(DataSources.hostFallbacks[DataSourceEndpoints.eastmoneyPush2],
                     "clist/get 在 push2ex 上恒 404，不得挂无效同族降级")
        XCTAssertEqual(DataSources.hostFallbacks[DataSourceEndpoints.eastmoneyPush2His],
                       [DataSourceEndpoints.eastmoneyPush2His, DataSourceEndpoints.eastmoneyPush2Ex],
                       "历史日K push2his 保留经实测可用的 push2ex 降级")
    }
}
