import XCTest
@testable import SelectedCore

/// 指数成份。
///
/// 本文件的重点是**节点名**与**数量下界** —— 它们的失败方式都是静默的：
/// 节点名写错时新浪返回**空数组**，与"这个指数没有成份"在响应上完全不可区分。
final class IndexMembersTests: XCTestCase {

    // MARK: - 节点名（实测钉住，防止被"顺手改对"改错）

    /// 节点名与数量下界是**实测值**，不是推测。
    ///
    /// 两个"看着对其实错"的写法（实测）：
    /// - `zhishu_000300` **返回空数组**（沪深300 的正确节点是 `hs300`）
    /// - `hs_s`（看着像 ST 板块）**返回的是指数**（上证指数 / Ａ股指数…）
    ///
    /// 谁把 `hs300` 改成 `zhishu_000300`（或反过来），这条立刻红。
    func testNodeNamesAreTheVerifiedOnes() {
        let table: [(code: String, name: String, node: String, minCount: Int)] = [
            ("hs300", "沪深300", "hs300", 250),
            ("zz500", "中证500", "zhishu_000905", 400),
            ("sz50", "上证50", "zhishu_000016", 40),
        ]
        XCTAssertEqual(IndexMembers.indices.count, table.count, "跟踪的指数个数变了")
        for want in table {
            guard let got = IndexMembers.index(want.code) else {
                XCTFail("缺指数 \(want.code)"); continue
            }
            XCTAssertEqual(got.name, want.name)
            XCTAssertEqual(got.node, want.node,
                           "\(want.code) 的 node 是实测值 —— 改成 zhishu_000\(want.code) 会返回空数组")
            XCTAssertEqual(got.minCount, want.minCount)
        }
        // 反例钉住：这两个"看着对"的写法**不许**出现在清单里
        XCTAssertFalse(IndexMembers.indices.contains { $0.node == "zhishu_000300" },
                       "zhishu_000300 实测返回空数组，不是沪深300 的节点")
        XCTAssertFalse(IndexMembers.indices.contains { $0.node == "hs_s" },
                       "hs_s 实测返回的是指数，不是 ST 板块")
    }

    /// 下界必须为正、且**明显低于**指数标称只数（否则调仓/停牌会让刷新永久失败）
    func testMinCountsLeaveRoomForConstituentChanges() {
        let nominal = ["hs300": 300, "zz500": 500, "sz50": 50]
        for idx in IndexMembers.indices {
            guard let n = nominal[idx.code] else { XCTFail("未知指数 \(idx.code)"); continue }
            XCTAssertGreaterThan(idx.minCount, 0)
            XCTAssertLessThan(idx.minCount, n, "\(idx.code)：下界不能等于标称只数")
            XCTAssertGreaterThan(idx.minCount, n * 2 / 3, "\(idx.code)：下界太松，拦不住'只拿到三分之一'")
        }
    }

    /// 下界断言的**方向**：恰好等于下界 → 接受（`>=` 不是 `>`）
    func testAcceptanceBoundaryIsInclusive() {
        let idx = IndexMembers.indices[0]      // hs300, minCount 250
        XCTAssertTrue(IndexMembersSource.acceptance(count: idx.minCount, index: idx).ok)
        XCTAssertTrue(IndexMembersSource.acceptance(count: idx.minCount + 1, index: idx).ok)
        let low = IndexMembersSource.acceptance(count: idx.minCount - 1, index: idx)
        XCTAssertFalse(low.ok, "差一只就该拦下（宁可保留旧数据，也不要半份成份表）")
        XCTAssertNotNil(low.reason)
        XCTAssertTrue(low.reason!.contains("下界"), "拒绝原因要写清是下界拦的：\(low.reason!)")
        XCTAssertFalse(IndexMembersSource.acceptance(count: 0, index: idx).ok,
                       "抓取失败（0 只）必须被拦下 —— 否则会拿空表覆盖好数据")
    }

    // MARK: - URL 拼装

    func testURLCarriesNodeAndPaging() {
        let u = IndexMembersSource.url(node: "zhishu_000905", page: 3)
        for token in ["getHQNodeData", "node=zhishu_000905", "page=3", "num=100",
                      "sort=symbol", "asc=1"] {
            XCTAssertTrue(u.contains(token), "URL 缺 \(token)：\(u)")
        }
        XCTAssertTrue(u.hasPrefix("https://vip.stock.finance.sina.com.cn/"),
                      "必须与证券列表同主机（零新第三方）")
    }

    // MARK: - 解析（真实响应形状）

    /// 真实抓取的 `node=hs300` 首页片段（截取 3 行，字段原样）
    private let realSample = """
    [{"symbol":"sh600000","code":"600000","name":"\\u6d66\\u53d1\\u94f6\\u884c","trade":"9.010",
      "pricechange":0,"changepercent":0,"buy":"9.010","sell":"9.020","settlement":"9.010",
      "open":"9.030","high":"9.070","low":"8.970","volume":33938157,"amount":306451150,
      "ticktime":"11:30:00","per":5.928,"pb":0.398,"mktcap":30008560.3083,
      "nmc":30008560.3083,"turnoverratio":0.1019},
     {"symbol":"sh600009","code":"600009","name":"\\u4e0a\\u6d77\\u673a\\u573a","trade":"22.870",
      "pricechange":-0.04,"changepercent":-0.175,"per":38.1,"pb":1.9},
     {"symbol":"sz000001","code":"000001","name":"\\u5e73\\u5b89\\u94f6\\u884c","trade":"11.70",
      "per":5.22,"pb":0.48}]
    """

    func testParseRealResponse() {
        let got = IndexMembersSource.parse(realSample)
        XCTAssertEqual(got.map(\.code), ["000001", "600000", "600009"],
                       "应按 code 升序（与查询顺序无关，保证可复现）")
        XCTAssertEqual(got.first(where: { $0.code == "600000" })?.name, "浦发银行")
        XCTAssertEqual(got.first(where: { $0.code == "000001" })?.name, "平安银行")
    }

    /// 空数组 / 非数组 / 截断 → `[]`（**全有或全无**）：
    /// 半截数据比没有数据更危险 —— 会被当成"完整的一份成份表"。
    func testParseRejectsNonArrayAndTruncated() {
        XCTAssertTrue(IndexMembersSource.parse("[]").isEmpty, "空数组是合法的'没抓到'")
        XCTAssertTrue(IndexMembersSource.parse("").isEmpty)
        XCTAssertTrue(IndexMembersSource.parse("<html>404</html>").isEmpty, "非数组 → 空")
        XCTAssertTrue(IndexMembersSource.parse("[{\"code\":\"600000\"").isEmpty, "截断的 JSON → 空")
    }

    /// 缺 `code` / 非数字 code 的行跳过（新浪偶有 `code` 为 `None` 的行）
    func testParseSkipsRowsWithoutNumericCode() {
        let text = """
        [{"code":"600000","name":"A"},{"name":"B"},{"code":"","name":"C"},
         {"code":"abc","name":"D"},{"code":"000001","name":"E"}]
        """
        XCTAssertEqual(IndexMembersSource.parse(text).map(\.code), ["000001", "600000"])
    }

    /// 重复 code 去重（分页临界点可能重复）
    func testParseDeduplicates() {
        let text = """
        [{"code":"600000","name":"A"},{"code":"600000","name":"A"},
         {"code":"600009","name":"B"}]
        """
        XCTAssertEqual(IndexMembersSource.parse(text).map(\.code), ["600000", "600009"])
    }

    /// 名称缺失 → 空串（不是 nil、不是 "None"）
    func testParseMissingNameBecomesEmptyString() {
        let got = IndexMembersSource.parse("[{\"code\":\"600000\"}]")
        XCTAssertEqual(got.count, 1)
        XCTAssertEqual(got[0].name, "")
    }

    // MARK: - 清单查表

    func testIndexOfCodeLooksUpTheTable() {
        XCTAssertEqual(IndexMembers.index("hs300")?.name, "沪深300")
        XCTAssertEqual(IndexMembers.index("zz500")?.name, "中证500")
        XCTAssertEqual(IndexMembers.index("sz50")?.name, "上证50")
        XCTAssertNil(IndexMembers.index("nope"))
        XCTAssertNil(IndexMembers.index(""))
    }

    /// 三个指数的 code 互不相同（落库主键的一部分）
    func testIndexCodesAreDistinct() {
        let codes = IndexMembers.indices.map(\.code)
        XCTAssertEqual(Set(codes).count, codes.count)
        XCTAssertFalse(codes.contains(""))
    }

    // MARK: - 建表契约

    /// DDL 的列名与读取处必须逐字对上（错了只会**静默读到 0 行**）
    func testStoreSchemaMatchesTheReaders() {
        let sql = IndexMembersStore.createSQL
        for col in ["index_code", "code", "name", "fetched_at"] {
            XCTAssertTrue(sql.contains(col), "index_members 缺列 \(col)")
        }
        XCTAssertTrue(sql.contains("PRIMARY KEY (index_code, code)"))
        // 详情页问的是"**这只票**属于哪些指数" → 必须有 code 上的索引
        // （主键索引 index_code 在前，帮不上忙）
        XCTAssertTrue(sql.contains("\(IndexMembersStore.codeIndexName) ON index_members(code)"))
    }

    /// 报告文案：把"没刷新"的原因说出来（否则用户看到徽章消失会以为功能坏了）
    func testReportSummaryNamesBothOutcomes() {
        var r = IndexMembersStore.Report()
        r.refreshed = ["hs300"]
        r.counts = ["hs300": 300]
        r.rejected = ["zz500": "抓到 0 只 < 下界 400"]
        XCTAssertTrue(r.summary.contains("已刷新"))
        XCTAssertTrue(r.summary.contains("300 只"))
        XCTAssertTrue(r.summary.contains("保留旧数据"))
        XCTAssertTrue(r.summary.contains("zz500"))
        XCTAssertEqual(IndexMembersStore.Report().summary, "无变化")
    }
}
