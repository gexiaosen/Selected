import XCTest
import SQLite3
@testable import SelectedCore

/// 板块热度 —— 重点是**解析口径**与两个静默失效点：
/// · `"-"` 是**休市时段的哨兵值**（盘前 `f6/f62/f128/f140` 全是 `"-"`），
///   不能变成叫 `"-"` 的领涨股 / 不能污染成交额与净流入；
/// · 板块代码必须 `BK` 前缀 —— 筛选条件写错时源会回别的形状，非法行要跳过（宁缺勿错）。
///
/// 解析测试用**真实抓取**的响应原文（内联，与 `IndustryTests` 同一姿势），
/// 不照着代码手写 —— 手写夹具是循环论证。
final class BoardHeatTests: XCTestCase {

    /// 真实抓取（盘中，字段原样；含一只下跌板块 `f3<0`、一只沪市领涨股 `f141:1`）
    private let realSample = #"""
    {"rc":0,"rt":6,"svr":180606386,"data":{"total":496,"diff":[
      {"f2":1111.88,"f3":19.98,"f12":"BK1296","f14":"视频媒体","f20":43026578000,
       "f62":268003552.0,"f104":1,"f105":0,"f106":0,"f128":"芒果超媒","f140":"300413","f141":0},
      {"f2":4969.64,"f3":7.78,"f12":"BK1518","f14":"种子","f20":63652709000,
       "f62":807839376.0,"f104":10,"f105":0,"f106":0,"f128":"万向德农","f140":"600371","f141":1},
      {"f2":3902.79,"f3":-2.5,"f12":"BK1299","f14":"影视动漫制作","f20":141658913000,
       "f62":-687581904.0,"f104":3,"f105":11,"f106":0,"f128":"上海电影","f140":"601595","f141":1}
    ]}}
    """#

    /// 盘前真实抓取（休市：`f6/f62/f128/f140/f141` 全是 `"-"` 哨兵）
    private let closedSample = #"""
    {"rc":0,"rt":6,"data":{"total":496,"diff":[
      {"f2":831.12,"f3":0.0,"f6":"-","f8":0.0,"f12":"BK1564","f14":"体育Ⅲ","f20":15751182000,
       "f62":"-","f104":0,"f105":0,"f106":3,"f128":"-","f140":"-","f141":"-"}
    ]}}
    """#

    // MARK: - 解析（真实响应）

    func testParseRealResponse() {
        let (rows, total) = BoardHeatSource.parse(realSample, date: "2026-10-12")
        XCTAssertEqual(total, 496, "源报总数照读（完整性检查要用）")
        XCTAssertEqual(rows.count, 3)
        let a = rows[0]
        XCTAssertEqual(a.date, "2026-10-12", "日期由**请求日期盖章**（响应不带日期）")
        XCTAssertEqual(a.boardCode, "BK1296")
        XCTAssertEqual(a.boardName, "视频媒体")
        XCTAssertEqual(a.index, 1111.88, accuracy: 1e-6)
        XCTAssertEqual(a.changePct, 19.98, accuracy: 1e-6)
        XCTAssertEqual(a.mainNet, 268003552.0, accuracy: 1e-3, "主力净流入（元）")
        XCTAssertEqual(a.upCount, 1)
        XCTAssertEqual(a.downCount, 0)
        XCTAssertEqual(a.flatCount, 0)
        XCTAssertEqual(a.leaderName, "芒果超媒")
        XCTAssertEqual(a.leaderCode, "300413")
        XCTAssertEqual(a.leaderMarket, 0)
    }

    /// 下跌板块：`f3<0` 与 `f62<0` 必须原样带符号（净流入可为负）
    func testParseCarriesNegativeValues() {
        let (rows, _) = BoardHeatSource.parse(realSample, date: "2026-10-12")
        guard let down = rows.first(where: { $0.boardCode == "BK1299" }) else {
            return XCTFail("BK1299 应被解析出来")
        }
        XCTAssertEqual(down.changePct, -2.5, accuracy: 1e-6)
        XCTAssertEqual(down.mainNet, -687581904.0, accuracy: 1e-3, "净流出是负数，不是绝对值")
        XCTAssertEqual(down.downCount, 11)
    }

    // MARK: - 哨兵值（休市时段）

    /// `"-"` 是**哨兵**（休市时段源给）：`f62`/`f6` 折成 0、领涨股折成空串，
    /// 绝不能变成叫 `"-"` 的领涨股。
    func testParseFoldsSentinels() {
        let (rows, _) = BoardHeatSource.parse(closedSample, date: "2026-10-12")
        XCTAssertEqual(rows.count, 1)
        let r = rows[0]
        XCTAssertEqual(r.boardName, "体育Ⅲ", "罗马数字三级板块名，原样保留")
        XCTAssertEqual(r.mainNet, 0, "f62 == \"-\" → 0（不是数据）")
        XCTAssertEqual(r.amount, 0, "f6 == \"-\" → 0")
        XCTAssertEqual(r.leaderName, "", "f128 == \"-\" → 空串")
        XCTAssertEqual(r.leaderCode, "", "f140 == \"-\" → 空串")
        XCTAssertEqual(r.leaderMarket, -1, "f141 == \"-\"（非 NSNumber）→ -1 表示没给")
        XCTAssertEqual(r.flatCount, 3, "f106 平盘家数照常读")
    }

    // MARK: - 非法行剔除

    /// 板块代码非 `BK` 前缀 / 名称为 `"-"` → 跳过（筛选条件写错时不塞垃圾行）
    func testParseRejectsBadRows() {
        let bad = #"""
        {"data":{"total":3,"diff":[
          {"f12":"600000","f14":"不是板块","f3":1.0,"f62":1.0},
          {"f12":"BK9999","f14":"-","f3":1.0,"f62":1.0},
          {"f12":"BK1000","f14":"正常板块","f3":1.0,"f62":1.0}
        ]}}
        """#
        let (rows, total) = BoardHeatSource.parse(bad, date: "2026-10-12")
        XCTAssertEqual(total, 3)
        XCTAssertEqual(rows.map(\.boardCode), ["BK1000"], "只有 BK 前缀 + 名称非 \"-\" 的行留下")
    }

    /// `data` 为 null / 非预期形状 → `([], 0)`（**全有或全无**）
    func testParseRejectsMalformed() {
        XCTAssertEqual(BoardHeatSource.parse("", date: "2026-10-12").rows.count, 0)
        XCTAssertEqual(BoardHeatSource.parse("<html>", date: "2026-10-12").total, 0)
        XCTAssertEqual(BoardHeatSource.parse(#"{"data":null}"#, date: "2026-10-12").total, 0)
        let (r, t) = BoardHeatSource.parse(#"{"data":{"total":0}}"#, date: "2026-10-12")
        XCTAssertTrue(r.isEmpty)
        XCTAssertEqual(t, 0)
    }

    /// `np=1` 时 `diff` 是数组；不带 `np` 时是**字典**（键是序号）—— 两种都认
    func testParseAcceptsDictShape() {
        let dictShape = #"""
        {"data":{"total":2,"diff":{
          "0":{"f12":"BK1000","f14":"甲","f3":1.0,"f62":100.0},
          "1":{"f12":"BK1001","f14":"乙","f3":2.0,"f62":200.0}
        }}}
        """#
        let (rows, total) = BoardHeatSource.parse(dictShape, date: "2026-10-12")
        XCTAssertEqual(total, 2)
        XCTAssertEqual(rows.map(\.boardCode), ["BK1000", "BK1001"], "字典形态按序号升序还原")
    }

    // MARK: - 领涨股代码归一化

    /// `f140` 实测是字符串；万一是数字要补零成 6 位；`0`/非法 → 空串
    func testLeaderCodeNormalization() {
        XCTAssertEqual(BoardHeatSource.leaderCode("300413"), "300413")
        XCTAssertEqual(BoardHeatSource.leaderCode(NSNumber(value: 413)), "000413", "数字补零")
        XCTAssertEqual(BoardHeatSource.leaderCode("-"), "")
        XCTAssertEqual(BoardHeatSource.leaderCode(NSNumber(value: 0)), "")
        XCTAssertEqual(BoardHeatSource.leaderCode(nil), "")
    }

    // MARK: - URL 拼装

    func testUrlCarriesBoardFilterAndFields() {
        let u = BoardHeatSource.url(page: 1)
        XCTAssertTrue(u.contains("fs=m:90+t:2"), "行业板块域筛选")
        XCTAssertTrue(u.contains("pz=100"), "服务端上限 100")
        // 排序键必须是**稳定的 f12**：实测 `fid=f3`（涨幅）会让源每次请求重排列表，
        //   分页之间漂移 → 5 页去重只剩 493/496。
        XCTAssertTrue(u.contains("fid=f12"), "分页必须按稳定键排序")
        XCTAssertFalse(u.contains("fid=f3"), "不许按实时涨幅排（分页不确定）")
        XCTAssertTrue(BoardHeatSource.url(page: 2).contains("pn=2"))
        XCTAssertTrue(u.contains("f104"), "涨跌家数字段必须在列")
    }

    // MARK: - 建表 DDL（真的执行一遍，与 FundFlowTests 同一姿势）

    /// 建表只在 App 启动的 `DBBootstrap.ensureSwiftOnlySchema` 里跑，**失败只 NSLog**。
    /// SQL 写错（少逗号、列名打错、`IF NOT EXISTS` 漏了）在 `swift build` 里完全看不出来。
    func testCreateSQLActuallyBuildsTheTable() throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &db), SQLITE_OK)
        let handle = try XCTUnwrap(db)
        defer { sqlite3_close(handle) }

        var errmsg: UnsafeMutablePointer<CChar>?
        XCTAssertEqual(sqlite3_exec(handle, BoardHeatStore.createSQL, nil, nil, &errmsg), SQLITE_OK,
                       "createSQL 执行失败：\(errmsg.map { String(cString: $0) } ?? "?")")
        sqlite3_free(errmsg)

        // ① 列名/顺序与 DDL 一致
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(handle, "PRAGMA table_info(board_heat)", -1, &stmt, nil),
                       SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        var cols: [String] = []
        var pkCols: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let name = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            cols.append(name)
            if sqlite3_column_int(stmt, 5) > 0 { pkCols.append(name) }
        }
        XCTAssertEqual(cols, ["trade_date", "board_code", "board_name", "board_index",
                              "change_pct", "amount", "turnover_rate", "total_cap", "main_net",
                              "up_count", "down_count", "flat_count",
                              "leader_name", "leader_code", "leader_market", "fetched_at"],
                       "列清单必须与 `BoardHeatStore.point()` 的取值键逐字对上（错了只会静默读 0）")
        XCTAssertEqual(pkCols, ["trade_date", "board_code"], "主键必须是 (交易日, 板块代码)")

        // ② 索引存在（boardHistory 按板块查历史靠它）
        var idx: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(handle,
            "SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name=?",
            -1, &idx, nil), SQLITE_OK)
        defer { sqlite3_finalize(idx) }
        sqlite3_bind_text(idx, 1, BoardHeatStore.boardIndexName, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        XCTAssertEqual(sqlite3_step(idx), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(idx, 0), 1)

        // ③ 幂等：同一条 DDL 再跑一遍必须成功（每次启动都跑）
        XCTAssertEqual(sqlite3_exec(handle, BoardHeatStore.createSQL, nil, nil, nil), SQLITE_OK,
                       "DDL 不幂等 —— 每次启动都会失败")
    }
}
