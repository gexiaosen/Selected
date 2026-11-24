import XCTest
@testable import SelectedCore

/// 「抓取失败」的**如实报错**。
///
/// ## 背景
/// 刷新失败时界面只写「未刷新（保留旧数据）：抓取失败（源无响应或返回不完整）」——
/// 这句话把**被限流 / 没网 / 404 / 超时**全混成一件事，真原因
/// （如 `The network connection was lost.`，出口 IP 被东财 `push2*` 限流）
/// 只进了 `data_source_logs`、没上界面。
/// 所以 `httpGet` 全失败时记下 `(url, 原因)`，上层按 **URL 前缀**取回并拼进文案。
///
/// 本文件里 `testErrorFromAnotherSourceIsNotReported` 是**最重要的那条**：
///   扫描/回放等后台任务会并发发请求，全局记录随时可能被别的源覆盖 ——
///   不做前缀匹配就会"把别的源的错误报成自己的"，那比不报还坏。
final class FetchFailureMessageTests: XCTestCase {

    // MARK: - 文案合成（纯函数）

    func testFailureMessageFallsBackToTheOldWording() {
        XCTAssertEqual(DataSources.fetchFailureMessage(nil),
                       "抓取失败（源无响应或返回不完整）",
                       "拿不到 HTTP 原因时保留旧文案（那是'源有响应但内容不完整'）")
        XCTAssertEqual(DataSources.fetchFailureMessage(""),
                       "抓取失败（源无响应或返回不完整）")
    }

    func testFailureMessageCarriesTheHTTPReason() {
        XCTAssertEqual(DataSources.fetchFailureMessage("The network connection was lost."),
                       "抓取失败：The network connection was lost.")
        XCTAssertEqual(DataSources.fetchFailureMessage("HTTP 502"), "抓取失败：HTTP 502")
    }

    // MARK: - 疑似限流识别

    /// 命中：连接被对端无声掐断这一族（实测限流就是 `network connection was lost`）
    func testThrottleDetectionHitsConnectionDropped() {
        for r in ["The network connection was lost.",
                  "Error Domain=NSPOSIXErrorDomain Code=54 \"Connection reset by peer\"",
                  "连接被重置", "HTTP 000"] {
            XCTAssertTrue(DataSources.isSuspectedThrottle(r), "\(r) 应判为疑似限流")
            XCTAssertNotNil(DataSources.throttleHint(r))
        }
    }

    /// 中文系统本地化：同一 -1005 错误，中文 macOS 下
    /// `localizedDescription` 是「网络连接已中断。」，只判英文串会**静默漏判** ——
    /// 判据必须中英都认。
    func testThrottleDetectionHitsChineseLocalizedReason() {
        for r in ["抓取失败：网络连接已中断。", "网络连接已中断",
                  "Error Domain=NSURLErrorDomain Code=-1005 \"与主机的连接已中断。\"",
                  "与主机的连接已中断"] {
            XCTAssertTrue(DataSources.isSuspectedThrottle(r), "\(r) 应判为疑似限流（中文本地化）")
            XCTAssertNotNil(DataSources.throttleHint(r))
        }
    }

    /// 判别性：**不误报**。超时 / 4xx·5xx / 截断 / 空响应各有明确根因，
    /// 归成"限流"会把用户引去换网络（而真问题是别的）—— 宁可漏报不误报。
    func testThrottleDetectionDoesNotOverMatch() {
        for r in ["HTTP 502", "HTTP 404", "请求 20s 未收到回调（已取消，可能被系统挂起）",
                  "只取到 5226/5561 只（源返回被截断）", "空响应体", "无响应", "",
                  // 中文本地化里"用户自己断网 / 找不到主机"那一族 —— 处置是"查本机网络"，
                  // 不是"换出口 IP"，归进限流就是误报（-1009 / -1003 的 localizedDescription）
                  "未能连接互联网。", "找不到服务器。"] {
            XCTAssertFalse(DataSources.isSuspectedThrottle(r), "\(r) 不该判为限流")
            XCTAssertNil(DataSources.throttleHint(r))
        }
        XCTAssertFalse(DataSources.isSuspectedThrottle(nil), "nil 原因（源有响应但不完整）不是限流")
    }

    /// 提示文案是"附加"而非"替换"：原始 HTTP 原因仍要在（供排查），提示只加行动指引
    func testThrottleHintIsActionableAndShort() {
        let hint = DataSources.throttleHint("The network connection was lost.") ?? ""
        XCTAssertTrue(hint.contains("限流"))
        XCTAssertTrue(hint.contains("换网络") || hint.contains("稍后"))
        XCTAssertLessThanOrEqual(hint.count, 30, "toast 只 2 行，提示不能太长")
    }

    // MARK: - 记录与取回（按 URL 前缀）

    func testRecordedErrorIsReadBackOnlyForItsOwnPrefix() {
        let mine = "https://probe.invalid/api/qt/clist/get?pn=1"
        DataSources.recordFetchFailure(mine, "连接被重置")
        XCTAssertEqual(DataSources.lastFetchFailureReason(matching: "https://probe.invalid/api/qt/clist/get"),
                       "连接被重置")
        XCTAssertNil(DataSources.lastFetchFailureReason(matching: "https://probe.invalid/api/qt/kline/get"),
                     "同主机不同端点不许互相认领")
        XCTAssertNil(DataSources.lastFetchFailureReason(matching: "https://other.invalid/"))
    }

    /// **判别性用例**：别的源（后台扫描）刚写过一条错误时，
    /// 本端点读到的必须是 `nil`，不能把它的原因报成自己的。
    func testErrorFromAnotherSourceIsNotReported() {
        let scope = "https://probe2.invalid/api/qt/clist/get"
        DataSources.clearFetchFailure(matching: scope)
        DataSources.recordFetchFailure("https://qt.gtimg.cn/q=sh000001", "TLS 握手失败")
        XCTAssertNil(DataSources.lastFetchFailureReason(matching: scope),
                     "别的源的错误不许张冠李戴 —— 这是本机制唯一的风险点")
    }

    /// 清空**只**作用于同前缀（一次抓取开始前调，保证之后读到的必是本次的）
    func testClearOnlyAffectsItsOwnPrefix() {
        let scope = "https://probe3.invalid/api/qt/clist/get"
        let other = "https://qt.gtimg.cn/q=sh000001"
        DataSources.recordFetchFailure(other, "TLS 握手失败")
        DataSources.recordFetchFailure(scope + "?pn=1", "连接被重置")
        DataSources.clearFetchFailure(matching: scope)
        XCTAssertNil(DataSources.lastFetchFailureReason(matching: scope), "同前缀的旧错误被清掉")
        XCTAssertEqual(DataSources.lastFetchFailureReason(matching: "https://qt.gtimg.cn"),
                       "TLS 握手失败", "别的前缀不受影响")
    }

    /// 分槽（按"去掉 query 的 URL"）的理由：**后台任务写一条不许把我们那条挤掉**。
    /// 单槽实现下这条会红（我们的记录会被覆盖 → 读回 nil → 退回含糊文案）。
    func testAnotherEndpointDoesNotEraseOurRecord() {
        let scope = "https://probe4.invalid/api/qt/clist/get"
        DataSources.clearFetchFailure(matching: scope)
        DataSources.recordFetchFailure(scope + "?pn=1", "连接被重置")
        // 模拟"后台扫描/回放正好在这时写了一条"
        DataSources.recordFetchFailure("https://qt.gtimg.cn/q=sh000001", "TLS 握手失败")
        DataSources.recordFetchFailure("https://probe4.invalid/api/qt/stock/kline/get?secid=1.1",
                                    "超时")
        XCTAssertEqual(DataSources.lastFetchFailureReason(matching: scope), "连接被重置",
                       "同前缀那条必须还在（否则这条机制在回放期间等于没有）")
    }

    /// 同前缀多条 → 取**最新写入**的那条
    func testNewestWinsWithinTheSamePrefix() {
        let scope = "https://probe5.invalid/api/qt/clist/get"
        DataSources.recordFetchFailure(scope + "?pn=1", "第一次失败")
        DataSources.recordFetchFailure(scope + "?pn=2", "第二次失败")
        XCTAssertEqual(DataSources.lastFetchFailureReason(matching: scope), "第二次失败")
    }

    /// 「截断」也是失败原因：`fetchAll` 的完整性判定会往**同一个通道**写
    /// （实测一次跑到 5226/5561 只被丢弃，卡片上不能只显示含糊的"源无响应或返回不完整"）。
    func testTruncatedFetchIsReportedAsAReason() {
        let scope = "https://probe6.invalid/api/qt/clist/get"
        DataSources.clearFetchFailure(matching: scope)
        DataSources.recordFetchFailure(scope + "?pn=1", "只取到 5226/5561 只（源返回被截断）")
        XCTAssertEqual(DataSources.lastFetchFailureReason(matching: scope),
                       "只取到 5226/5561 只（源返回被截断）")
        XCTAssertEqual(DataSources.fetchFailureMessage(
                        DataSources.lastFetchFailureReason(matching: scope)),
                       "抓取失败：只取到 5226/5561 只（源返回被截断）")
    }

    /// query 不参与分槽（同一个端点的不同分页算同一条）
    func testQueryIsNotPartOfTheSlotKey() {
        XCTAssertEqual(DataSources.fetchFailureKey("https://h/p?a=1&b=2"), "https://h/p")
        XCTAssertEqual(DataSources.fetchFailureKey("https://h/p"), "https://h/p")
    }

    /// 基本面 / 板块热度 / 板块成份虽然共用 `clist/get` 路径，但通过 `fs=` 业务域隔离
    /// `failureScope` 与分槽键：各自不同分页仍落同一业务槽，互相之间绝不串台或误清。
    func testFailureScopesAreIsolatedByBusinessDomain() {
        let funScope = FundamentalSource.failureScope
        let heatScope = BoardHeatSource.failureScope
        let membersScope = BoardMembersSource.failureScope
        XCTAssertNotEqual(funScope, heatScope)
        XCTAssertNotEqual(funScope, membersScope)
        XCTAssertNotEqual(heatScope, membersScope)

        XCTAssertTrue(DataSources.fetchFailureKey(FundamentalSource.url(page: 1)).hasPrefix(funScope),
                      "基本面 slot 必须匹配 failureScope=\(funScope)")
        XCTAssertEqual(DataSources.fetchFailureKey(FundamentalSource.url(page: 1)),
                       DataSources.fetchFailureKey(FundamentalSource.url(page: 2)),
                       "同一业务域分页不应裂槽")
        XCTAssertTrue(DataSources.fetchFailureKey(BoardHeatSource.url(page: 1)).hasPrefix(heatScope),
                      "板块热度 slot 必须匹配 failureScope=\(heatScope)")
        XCTAssertTrue(DataSources.fetchFailureKey(BoardMembersSource.url(boardCode: "BK1295", page: 1))
                        .hasPrefix(membersScope),
                      "板块成份 slot 必须匹配 failureScope=\(membersScope)")

        // 并发/独立失败隔离：板块热度或成份失败不得覆盖/串台到基本面，且清理基本面不影响板块
        DataSources.clearFetchFailure(matching: funScope)
        DataSources.clearFetchFailure(matching: heatScope)
        DataSources.clearFetchFailure(matching: membersScope)
        defer {
            DataSources.clearFetchFailure(matching: funScope)
            DataSources.clearFetchFailure(matching: heatScope)
            DataSources.clearFetchFailure(matching: membersScope)
        }
        DataSources.recordFetchFailure(BoardHeatSource.url(page: 1), "板块热度超时")
        DataSources.recordFetchFailure(BoardMembersSource.url(boardCode: "BK1295", page: 1), "成份连接被重置")
        XCTAssertNil(DataSources.lastFetchFailureReason(matching: funScope),
                     "板块域的失败不得污染基本面失败槽")

        DataSources.recordFetchFailure(FundamentalSource.url(page: 1), "基本面限流")
        DataSources.clearFetchFailure(matching: funScope)
        XCTAssertEqual(DataSources.lastFetchFailureReason(matching: heatScope), "板块热度超时")
        XCTAssertEqual(DataSources.lastFetchFailureReason(matching: membersScope), "成份连接被重置")

        XCTAssertTrue(HistoryBarsSource.url(secid: "1.600000", beg: "20260101", end: "20260924",
                                            adjust: true)
                        .hasPrefix(HistoryBarsSource.host + "/api/qt/stock/kline/get"),
                      "日K 的 URL 前缀同样要对得上（节流与报错都靠它定位）")
    }
}
