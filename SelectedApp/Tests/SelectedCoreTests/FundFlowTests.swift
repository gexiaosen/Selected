import XCTest
import SQLite3
@testable import SelectedCore

/// 资金流向的契约测试。
///
/// 覆盖三件**真会静默出错**的事：
///   1. **DESC / ASC** —— 新浪的历史端点返回的是"新→旧"，直接用 `suffix` / `.last`
///      会取到**最老**的日期当"最新"，进而把 16 年前的数据写在今天的日期下。
///   2. **快照不带日期** —— 解析出来必须是空串（强制调用方 `stamp`），
///      一旦哪天"顺手填上今天"，数据污染就再也检测不出来。
///   3. **DDL 真的能建表** —— 建表只发生在 App 启动的 `DBBootstrap` 里，
///      失败只 NSLog。SQL 写错了 `swift build` 完全看不出来。
///
/// 解析测试用**真实捕获**的响应文本（`Fixtures/fundflow_*.json`），
/// 不照着代码手写 —— 手写夹具是循环论证（只能证明"代码与我的想象一致"）。
final class FundFlowTests: XCTestCase {

    // MARK: - 夹具

    private static let fixturesDir: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")

    /// 缺失 → **失败**（不是 `XCTSkip`）：本夹具**已纳入版本管理**，
    /// 缺失 = 仓库不完整 / 被误删，**不是"当前环境不具备"** ——
    /// 跳过会把这件事伪装成"全绿"。
    private func fixtureText(_ name: String) throws -> String {
        let url = Self.fixturesDir.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw EntityTestSupport.FixtureMissing(
                path: "Tests/SelectedCoreTests/Fixtures/\(name)")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - 快照解析（真实响应）

    /// 快照：3 行（全是北交所票 —— 实测榜单里 `bj` 排在最前）
    func testParseSnapshotFromRealResponse() throws {
        let pts = FundFlowSource.parseSnapshot(try fixtureText("fundflow_snapshot.json"))
        XCTAssertEqual(pts.count, 3)

        XCTAssertEqual(pts.map(\.code), ["430017", "430090", "430300"],
                       "symbol 的 2 位市场前缀必须被剥掉，且代码要按原顺序保留")
        XCTAssertEqual(pts[0].name, "星昊医药")
        XCTAssertEqual(pts[0].close, 27.0, accuracy: 1e-9)
        XCTAssertEqual(pts[1].name, "同辉信息")
        XCTAssertEqual(pts[1].close, 0.0, accuracy: 1e-9, "停牌票 trade=0 是真实值，不能被过滤掉")

        // 第 3 行有非零值 → 逐字段核对（数值口径：`r0_net` 主力净额 / `netamount` 总净流入）
        XCTAssertEqual(pts[2].close, 15.81, accuracy: 1e-9)
        XCTAssertEqual(pts[2].changePct, 0.00636537, accuracy: 1e-12)
        XCTAssertEqual(pts[2].netAmount, 1_478_645.73, accuracy: 1e-6)
        XCTAssertEqual(pts[2].mainNet, 0.0, accuracy: 1e-9)
    }

    /// **快照解析出来的 `date` 必须是空串**。
    ///
    /// 快照响应里根本没有日期字段。若哪天有人"顺手填个今天"，下面这条会红 ——
    /// 这是**唯一**能拦住"把上一交易日的数据写在今天"的自动化手段。
    func testSnapshotRowsHaveNoDateUntilStamped() throws {
        let pts = FundFlowSource.parseSnapshot(try fixtureText("fundflow_snapshot.json"))
        XCTAssertTrue(pts.allSatisfy { $0.date.isEmpty },
                      "快照不带日期 → 必须留空由 stamp 注入，绝不能自己填今天")
    }

    /// `stamp` 注入日期，其余字段逐字不变
    func testStampInjectsDateWithoutTouchingOtherFields() throws {
        let raw = FundFlowSource.parseSnapshot(try fixtureText("fundflow_snapshot.json"))
        let stamped = FundFlowSource.stamp(raw, date: "2026-09-22")
        XCTAssertEqual(stamped.count, raw.count)
        XCTAssertTrue(stamped.allSatisfy { $0.date == "2026-09-22" })
        for (a, b) in zip(raw, stamped) {
            XCTAssertEqual(a.code, b.code)
            XCTAssertEqual(a.name, b.name)
            XCTAssertEqual(a.close, b.close, accuracy: 0)
            XCTAssertEqual(a.changePct, b.changePct, accuracy: 0)
            XCTAssertEqual(a.netAmount, b.netAmount, accuracy: 0)
            XCTAssertEqual(a.mainNet, b.mainNet, accuracy: 0)
            XCTAssertEqual(a.mainRatio, b.mainRatio, accuracy: 0)
        }
    }

    // MARK: - 历史解析（真实响应）—— DESC → ASC 回归锁

    /// 本文件最重要的一条：新浪历史端点是 **DESC（新→旧）**，输出必须**反转成升序**。
    ///
    /// 实测夹具首行 `2026-09-21`、末行 `2026-08-18`。
    /// 若不反转，`suffix(days)` 取到的是**最老的 days 天**、`.last` 是**最老的日期**。
    func testParseHistoryReturnsAscendingOrder() throws {
        let pts = FundFlowSource.parseHistory(try fixtureText("fundflow_history.json"),
                                              code: "600000")
        XCTAssertEqual(pts.count, 25)
        XCTAssertEqual(pts.first?.date, "2026-08-18", "升序：第一个应是最旧的")
        XCTAssertEqual(pts.last?.date, "2026-09-21", "升序：最后一个应是最新的")

        let dates = pts.map(\.date)
        XCTAssertEqual(dates, dates.sorted(), "整条序列必须严格按日期升序")
        XCTAssertTrue(Set(dates).count == dates.count, "同一日期不应重复")
    }

    /// 最新一天（`2026-09-21` / `sh600000`）的取值 —— 与 spec 记录的实测值逐字核对，
    /// 同时验证**两个端点对同一票同一天返回相同值**（快照里的值这里不重复断言，
    /// 但 `r0_net` / `netamount` 的口径必须落在这两个字段上，不能串位）。
    func testParseHistoryLatestRowValues() throws {
        let pts = FundFlowSource.parseHistory(try fixtureText("fundflow_history.json"),
                                              code: "600000")
        let last = try XCTUnwrap(pts.last)
        XCTAssertEqual(last.date, "2026-09-21")
        XCTAssertEqual(last.close, 9.01, accuracy: 1e-9, "trade")
        XCTAssertEqual(last.changePct, -0.00661521, accuracy: 1e-12, "changeratio")
        XCTAssertEqual(last.netAmount, -75_341_747.67, accuracy: 1e-6, "netamount")
        XCTAssertEqual(last.mainNet, -89_652_312.56, accuracy: 1e-6, "r0_net")
        XCTAssertEqual(last.mainRatio, -0.15105896, accuracy: 1e-12, "r0_ratio")
    }

    /// 历史端点**不返回** `symbol` / `name` → 代码由调用方传入，名称留空
    func testParseHistoryUsesCallerSuppliedCodeAndLeavesNameEmpty() throws {
        let pts = FundFlowSource.parseHistory(try fixtureText("fundflow_history.json"),
                                              code: "000001")
        XCTAssertTrue(pts.allSatisfy { $0.code == "000001" })
        XCTAssertTrue(pts.allSatisfy { $0.name.isEmpty })
    }

    /// 缺 `opendate` 或日期形态不对的行被跳过，而不是整批失败
    func testParseHistorySkipsRowsWithoutValidDate() {
        let text = """
        [{"opendate":"2026-09-21","trade":"9.01","r0_net":"1","netamount":"1","r0_ratio":"0"},
         {"trade":"9.01","r0_net":"1","netamount":"1","r0_ratio":"0"},
         {"opendate":"2026-9-1","trade":"9.01","r0_net":"1","netamount":"1","r0_ratio":"0"}]
        """
        XCTAssertEqual(FundFlowSource.parseHistory(text, code: "600000").count, 1)
    }

    /// 非法 JSON / 空串 → 空数组（不抛、不崩）
    func testParsersTolerateGarbage() {
        for bad in ["", "not json", "{}", "[]", "null"] {
            XCTAssertTrue(FundFlowSource.parseSnapshot(bad).isEmpty, "快照：\(bad)")
            XCTAssertTrue(FundFlowSource.parseHistory(bad, code: "600000").isEmpty, "历史：\(bad)")
        }
    }

    // MARK: - symbol ↔ code

    /// `symbol` → 代码：只认"2 位前缀 + 6 位数字"，**不在这里过滤市场**
    /// （过滤交给 `securities`，否则分页的"满页判定"会因剔掉北交所而失真）
    func testCodeFromSymbol() {
        XCTAssertEqual(FundFlowSource.codeFromSymbol("sh600000"), "600000")
        XCTAssertEqual(FundFlowSource.codeFromSymbol("sz000001"), "000001")
        XCTAssertEqual(FundFlowSource.codeFromSymbol("bj430017"), "430017",
                       "北交所必须能解析出来 —— 否则 fetchSnapshot 会误判'不满一页'")

        XCTAssertNil(FundFlowSource.codeFromSymbol("sh60000"))     // 7 位
        XCTAssertNil(FundFlowSource.codeFromSymbol("sh6000000"))   // 9 位
        XCTAssertNil(FundFlowSource.codeFromSymbol("sh60000X"))    // 非数字
        XCTAssertNil(FundFlowSource.codeFromSymbol(""))
        XCTAssertNil(FundFlowSource.codeFromSymbol("600000"))      // 无前缀
    }

    /// 代码 → 新浪 `symbol`。`DataSources.symbolPrefix` 只认 `6` 开头，
    /// 对北交所会拼出 `sz430017` 这种不存在的 symbol → 取数静默返回空。
    func testSinaSymbolCoversBeijingExchange() {
        XCTAssertEqual(FundFlowSource.sinaSymbol("600000"), "sh600000")
        XCTAssertEqual(FundFlowSource.sinaSymbol("688981"), "sh688981")
        XCTAssertEqual(FundFlowSource.sinaSymbol("000001"), "sz000001")
        XCTAssertEqual(FundFlowSource.sinaSymbol("300750"), "sz300750")
        XCTAssertEqual(FundFlowSource.sinaSymbol("430017"), "bj430017")
        XCTAssertEqual(FundFlowSource.sinaSymbol("830799"), "bj830799")
        XCTAssertEqual(FundFlowSource.sinaSymbol("920819"), "bj920819")
    }

    // MARK: - 汇总统计

    /// 手算一组：净额 [+1, +2, -3, +4, +5]
    func testSummarizeHandComputed() throws {
        let nets: [Double] = [1, 2, -3, 4, 5]
        let pts = nets.enumerated().map { i, n in
            FundFlowPoint(date: String(format: "2026-09-%02d", i + 1), code: "600000",
                          name: "x", close: 10, changePct: 0,
                          netAmount: n, mainNet: n, mainRatio: 0)
        }
        let s = try XCTUnwrap(FundFlowStats.summarize(pts))
        XCTAssertEqual(s.days, 5)
        XCTAssertEqual(s.sumMainNet, 9, accuracy: 1e-9)
        XCTAssertEqual(s.inflowDays, 4)
        XCTAssertEqual(s.consecutiveInflow, 2, "从最后一天往前数：+5、+4 连续两天，-3 截断")
        XCTAssertEqual(s.latestMainNet, 5)
        XCTAssertEqual(s.latestDate, "2026-09-05")
        XCTAssertEqual(s.inflowRatio, 0.8, accuracy: 1e-12)
        XCTAssertTrue(s.isNetInflow)
    }

    /// 最后一天是净流出 → `consecutiveInflow` 归零（"最近在流出"比"连续 N 天流入"更该被看见）
    func testSummarizeStreakIsZeroWhenLatestIsOutflow() throws {
        let pts = [1.0, 2.0, -1.0].enumerated().map { i, n in
            FundFlowPoint(date: "2026-09-0\(i + 1)", code: "600000", name: "",
                          close: 10, changePct: 0, netAmount: n, mainNet: n, mainRatio: 0)
        }
        let s = try XCTUnwrap(FundFlowStats.summarize(pts))
        XCTAssertEqual(s.consecutiveInflow, 0)
        XCTAssertEqual(s.inflowDays, 2)
        XCTAssertTrue(s.isNetInflow, "累计仍为正")
    }

    /// 空输入 → nil（不是"0 天全绿"）
    func testSummarizeEmptyIsNil() {
        XCTAssertNil(FundFlowStats.summarize([]))
    }

    // MARK: - 建表 DDL（真的执行一遍）

    /// 建表只在 App 启动的 `DBBootstrap.ensureSwiftOnlyMigrations` 里跑，**失败只 NSLog**。
    /// SQL 写错（少逗号、列名打错、`IF NOT EXISTS` 漏了）在 `swift build` 里完全看不出来。
    /// 所以这里用**真实 sqlite3** 执行 `createSQL`，逐列核对。
    func testCreateSQLActuallyBuildsTheTable() throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &db), SQLITE_OK)
        let handle = try XCTUnwrap(db)
        defer { sqlite3_close(handle) }

        var errmsg: UnsafeMutablePointer<CChar>?
        XCTAssertEqual(sqlite3_exec(handle, FundFlowStore.createSQL, nil, nil, &errmsg), SQLITE_OK,
                       "createSQL 执行失败：\(errmsg.map { String(cString: $0) } ?? "?")")
        sqlite3_free(errmsg)

        // ① 表存在，且列名/顺序与 DDL 一致
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(handle, "PRAGMA table_info(stock_fund_flows)",
                                          -1, &stmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        var cols: [String] = []
        var pkCols: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let name = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            cols.append(name)
            if sqlite3_column_int(stmt, 5) > 0 { pkCols.append(name) }
        }
        XCTAssertEqual(cols, ["trade_date", "code", "name", "close", "change_pct",
                              "net_amount", "main_net", "main_ratio"])
        XCTAssertEqual(pkCols, ["trade_date", "code"], "主键必须是 (交易日, 代码)")

        // ② 索引存在（详情页按 code 单查靠它，主键索引帮不上忙）
        var idx: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(handle,
            "SELECT COUNT(*) FROM sqlite_master WHERE type='index'"
                + " AND name='idx_stock_fund_flows_code'", -1, &idx, nil), SQLITE_OK)
        defer { sqlite3_finalize(idx) }
        XCTAssertEqual(sqlite3_step(idx), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(idx, 0), 1)

        // ③ **幂等**：同一条 DDL 再跑一遍必须成功（`IF NOT EXISTS` 真的写了）
        XCTAssertEqual(sqlite3_exec(handle, FundFlowStore.createSQL, nil, nil, nil), SQLITE_OK,
                       "DDL 不幂等 —— 每次启动都会失败")

        // ④ 主键真的在挡重复：同 (date, code) 覆盖写而不是追加
        let insert = "INSERT OR REPLACE INTO stock_fund_flows"
            + "(trade_date, code, name, close, change_pct, net_amount, main_net, main_ratio)"
            + " VALUES('2026-09-22','600000','a',9.0,0,1,1,0)"
        XCTAssertEqual(sqlite3_exec(handle, insert, nil, nil, nil), SQLITE_OK)
        let insert2 = insert.replacingOccurrences(of: "'a'", with: "'b'")
        XCTAssertEqual(sqlite3_exec(handle, insert2, nil, nil, nil), SQLITE_OK)
        var cnt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(handle,
            "SELECT COUNT(*), MAX(name) FROM stock_fund_flows", -1, &cnt, nil), SQLITE_OK)
        defer { sqlite3_finalize(cnt) }
        XCTAssertEqual(sqlite3_step(cnt), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(cnt, 0), 1, "同 (date, code) 应覆盖，不应变成两行")
        XCTAssertEqual(sqlite3_column_text(cnt, 1).map { String(cString: $0) }, "b")
    }

    // MARK: - 任务失败文案

    /// `Scheduler.finish` 把**含「非交易日」的失败**当成"当天完成"（静默吞掉）。
    /// 资金流的"数据没准备好"是可重试失败，文案里绝不能出现那四个字。
    func testNotReadyMessageDoesNotLookLikeNonTradingDay() {
        let msg = FundFlowJob.Failure.notReady(latest: "2026-09-21", today: "2026-09-22")
            .errorDescription ?? ""
        XCTAssertFalse(msg.contains("非交易日"), "会被 Scheduler 当成休市而静默完成")
        XCTAssertTrue(msg.contains("2026-09-21"))
        XCTAssertTrue(msg.contains("2026-09-22"))

        let msg2 = FundFlowJob.Failure.fetchFailed("快照为空").errorDescription ?? ""
        XCTAssertFalse(msg2.contains("非交易日"))
        XCTAssertTrue(msg2.contains("快照为空"))
    }
}
