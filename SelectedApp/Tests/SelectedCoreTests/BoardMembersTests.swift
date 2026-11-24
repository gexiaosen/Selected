import XCTest
@testable import SelectedCore

/// 板块成份涨幅榜（板块详情「强势股」）—— 重点是解析口径：
/// · 个股代码必须 6 位数字，非法行跳过（筛选条件写错时源回别的形状，宁缺勿错）；
/// · 按 `fid=f3` 服务端降序返回，榜头即涨幅最高几只。
///
/// 夹具用**真实抓取**的响应原文（内联，同 `BoardHeatTests` 姿势），不照代码手写。
final class BoardMembersTests: XCTestCase {

    /// 真实抓取 `fs=b:BK0459`（元件板块，成份 67 只，取榜头 5 条）
    private let realSample = #"""
    {"rc":0,"rt":6,"data":{"total":67,"diff":[
      {"f3":20.0,"f6":1144112739.0,"f12":"688655","f14":"迅捷兴"},
      {"f3":20.0,"f6":410407020.01,"f12":"301041","f14":"金百泽"},
      {"f3":14.79,"f6":214681543.1,"f12":"920821","f14":"则成电子"},
      {"f3":11.08,"f6":1465764481.3,"f12":"300964","f14":"本川智能"},
      {"f3":10.94,"f6":883796165.88,"f12":"301132","f14":"满坤科技"}
    ]}}
    """#

    func testParseRealResponse() {
        let (rows, total) = BoardMembersSource.parse(realSample)
        XCTAssertEqual(total, 67, "源报成份总数照读")
        XCTAssertEqual(rows.count, 5)
        let a = rows[0]
        XCTAssertEqual(a.code, "688655")
        XCTAssertEqual(a.name, "迅捷兴")
        XCTAssertEqual(a.changePct, 20.0, accuracy: 1e-6)
        XCTAssertEqual(a.amount, 1144112739.0, accuracy: 1e-3, "成交额（元）")
    }

    /// 代码非 6 位数字 = 筛选条件被改错 → 整行跳过（宁缺勿错）
    func testParseSkipsIllegalCode() {
        let bad = #"{"data":{"total":2,"diff":[{"f3":5.0,"f6":1,"f12":"BK9999","f14":"板块"},{"f3":3.0,"f6":2,"f12":"600000","f14":"浦发银行"}]}}"#
        let (rows, _) = BoardMembersSource.parse(bad)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.code, "600000")
    }

    /// 休市/异常：`f14` 给 `"-"` 哨兵 → 跳过
    func testParseSkipsDashSentinelName() {
        let s = #"{"data":{"total":1,"diff":[{"f3":0.0,"f6":0,"f12":"600000","f14":"-"}]}}"#
        let (rows, _) = BoardMembersSource.parse(s)
        XCTAssertTrue(rows.isEmpty)
    }

    /// 非预期形状（data 缺失）→ 全有或全无，返回空
    func testParseMalformedReturnsEmpty() {
        let (rows, total) = BoardMembersSource.parse("not json")
        XCTAssertTrue(rows.isEmpty)
        XCTAssertEqual(total, 0)
    }

    /// URL 用板块代码拼 `fs=b:`，排序键 `fid=f3`（成份只要榜头，服务端降序即可）
    func testURLShape() {
        let u = BoardMembersSource.url(boardCode: "BK1295", page: 1)
        XCTAssertTrue(u.contains("fs=b:BK1295"), u)
        XCTAssertTrue(u.contains("fid=f3"), u)
    }
}
