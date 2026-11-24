import XCTest
import SQLite3
@testable import SelectedCore

/// 龙虎榜的契约测试。
///
/// 覆盖四件**真会静默出错**的事：
///   1. **主键选错** —— `(date, code)` 不唯一（实测 7 只票一天多榜）。选错 = 一天的上榜
///      记录被 `INSERT OR REPLACE` 悄悄吃掉几条，而**没有任何报错**。
///   2. **前瞻字段入库** —— `D1/D2/D5/D10_CLOSE_ADJCHRATE` 是**事后回填的未来收益**。
///      存下来就是时点污染，且数据"看着完全正常"，事后无法识别。
///   3. **席位表的键** —— 席位没有可证明的自然键（营业部会重复、顺序不是金额序），
///      用 `INSERT OR REPLACE` 会把"换了排序"误判成"同一条记录的更新"。
///   4. **DDL 真的能建表** —— 建表只发生在 App 启动的 `DBBootstrap` 里，失败只 NSLog。
///      SQL 写错了 `swift build` 完全看不出来。
///
/// 解析测试用**真实捕获**的响应文本（`Fixtures/lhb_*.json`，
/// 只裁剪行数、行内容逐字保留），不照着代码手写 —— 手写夹具是循环论证。
final class LhbTests: XCTestCase {

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

    // MARK: - 主表解析（真实响应）

    /// 9 行：000002×1 / 000668×1 / 002528×2 / 600721×3 / 920427×2
    func testParseDayFromRealResponse() throws {
        let rs = LhbSource.parseDay(try fixtureText("lhb_day.json"))
        XCTAssertEqual(rs.count, 9)

        // 日期从 "2026-09-21 00:00:00" 截断而来 —— 不能带时间尾巴
        XCTAssertEqual(Set(rs.map(\.date)), ["2026-09-21"])

        XCTAssertEqual(rs.map(\.code),
                       ["000002", "000668", "002528", "002528",
                        "600721", "600721", "600721", "920427", "920427"])
        XCTAssertEqual(rs[0].name, "万科A")
        XCTAssertEqual(rs[0].market, "SZ")
        XCTAssertEqual(rs[0].tradeMarket, "深交所主板")
        XCTAssertEqual(rs[0].changePct, 9.9398, accuracy: 1e-9)
        XCTAssertEqual(rs[0].turnoverRate, 8.589, accuracy: 1e-9)
        XCTAssertEqual(rs[0].netAmount, -192_221_507.43, accuracy: 0.01)
        XCTAssertEqual(rs[0].tradeId, 100_415_818)

        // 上榜原因文案（人工可读）
        // 这两条是**短文案**变体 —— 同一条规则码的长文案见下一个测试
        XCTAssertEqual(rs[0].explanation, "日涨幅偏离值达到7%的前5只证券")
        XCTAssertEqual(rs[1].explanation, "日跌幅偏离值达到7%的前5只证券")
    }

    /// 这是本项存在的理由：**同一只票一天可以上榜多次**（不同规则）
    func testParseDayKeepsMultipleReasonsForSameStock() throws {
        let rs = LhbSource.parseDay(try fixtureText("lhb_day.json"))
        let byCode = Dictionary(grouping: rs, by: \.code)
        XCTAssertEqual(byCode["600721"]?.count, 3, "百花医药当天 3 条上榜记录，一条都不能丢")
        XCTAssertEqual(byCode["002528"]?.count, 2)
        XCTAssertEqual(Set(byCode["600721"]!.map(\.changeType)).count, 3,
                       "3 条的 changeType 必须互不相同")
    }

    /// `(date, code, changeType)` 必须唯一 —— 否则主键挡不住重复
    func testParseDayKeyIsUnique() throws {
        let rs = LhbSource.parseDay(try fixtureText("lhb_day.json"))
        let keys = Set(rs.map { "\($0.date)|\($0.code)|\($0.changeType)" })
        XCTAssertEqual(keys.count, rs.count, "主键有重复 → 会静默丢行")
        // 反证：去掉 changeType 就**不**唯一了（说明它必须进主键）
        let weak = Set(rs.map { "\($0.date)|\($0.code)" })
        XCTAssertLessThan(weak.count, rs.count, "(date, code) 本就不唯一")
    }

    /// 龙虎榜**不做** `securities` 过滤（与资金流相反）——
    /// 北交所会合法上榜，而 `securities` 表里没有北交所标的。
    /// 一旦有人"顺手对齐"资金流的过滤，这 8 条 BJ 记录会被静默丢掉。
    func testParseDayKeepsBeijingExchangeRows() throws {
        let rs = LhbSource.parseDay(try fixtureText("lhb_day.json"))
        let bj = rs.filter { $0.market == "BJ" }
        XCTAssertEqual(bj.count, 2, "北交所票必须保留（920427 华维设计）")
        XCTAssertEqual(bj.first?.tradeMarket, "北京证券交易所")
    }

    /// `EXPLANATION → CHANGE_TYPE` 必须单值 —— 这正是"用 `changeType` 当键"的前提。
    ///
    /// 反方向**不成立**（同一个 `changeType` 有多个文案变体，实测 `137001004001` 有 3 个），
    /// 所以 `EXPLANATION` 只能当展示列，**不能**进主键。
    func testExplanationMapsToOneChangeType() throws {
        let rs = LhbSource.parseDay(try fixtureText("lhb_day.json"))
        var seen: [String: Set<String>] = [:]
        for r in rs { seen[r.explanation, default: []].insert(r.changeType) }
        for (expl, cts) in seen {
            XCTAssertEqual(cts.count, 1, "「\(expl)」对应了多个 changeType：\(cts)")
        }
        // 9 行只有 8 种文案：000668 与 002528 的**同一条规则**用了同一段文字
        XCTAssertEqual(seen.count, 8)
    }

    /// 反方向**不成立**：同一个 `changeType` 有**多个文案变体**（供应商的历史文案修订）。
    ///
    /// 夹具里就能直接看到 —— 规则码 `137001002001001`：
    ///   · 对 `000002` 是短文案「日涨幅偏离值达到7%的前5只证券」
    ///   · 对 `600721` 是长文案「有价格涨跌幅限制的日收盘价格涨幅偏离值达到7%的前五只证券」
    /// （全量数据里该规则码实测有 3 个变体。）
    ///
    /// 这正是 `explanation` **不能**进主键的原因：拿它当键，
    /// 供应商改一次文案就等于把同一行变成"新行"，而旧行永远留在库里。
    func testChangeTypeMapsToManyExplanations() throws {
        let rs = LhbSource.parseDay(try fixtureText("lhb_day.json"))
        let byCt = Dictionary(grouping: rs, by: \.changeType)
        let multi = byCt.filter { Set($0.value.map(\.explanation)).count > 1 }
        XCTAssertFalse(multi.isEmpty, "夹具应当体现 changeType → 多文案（否则这条约束没被覆盖）")
        XCTAssertEqual(Set(byCt["137001002001001"]!.map(\.explanation)).count, 2)
    }

    /// `result` 为 `null`（无数据）时必须是空数组，不是崩溃也不是"1 行垃圾"
    func testParseDayToleratesNullResult() {
        XCTAssertTrue(LhbSource.parseDay(#"{"success":true,"message":"ok","result":null}"#).isEmpty)
        XCTAssertTrue(LhbSource.parseDay("不是 JSON").isEmpty)
        XCTAssertTrue(LhbSource.parseDay(#"{"result":{"data":[]}}"#).isEmpty)
    }

    // MARK: - 席位解析（真实响应）

    /// 每组 `(code, changeType)` 内 `rank` 必须是从 1 起的连续序号
    func testParseSeatsRankSequentialPerGroup() throws {
        for (file, side) in [("lhb_seats_buy.json", "BUY"), ("lhb_seats_sell.json", "SELL")] {
            let seats = LhbSource.parseSeats(try fixtureText(file), side: side)
            XCTAssertEqual(seats.count, 45, "\(file)：9 组 × 5 个席位")
            let groups = Dictionary(grouping: seats, by: { "\($0.code)|\($0.changeType)" })
            XCTAssertEqual(groups.count, 9)
            for (key, g) in groups {
                XCTAssertEqual(g.map(\.rank), Array(1...g.count), "\(key) 的 rank 必须 1..n 连续")
                XCTAssertEqual(g.count, 5, "\(key) 每组恰好 5 个席位")
            }
            XCTAssertTrue(seats.allSatisfy { $0.side == side })
        }
    }

    /// 席位**没有自然键** —— 用测试把这个事实钉住，避免有人以后改成 `INSERT OR REPLACE`
    /// 并在注释里写"营业部名可以当键"。
    ///
    /// 重复的根源是**机构专用席位被匿名化并按机构拆成多行**：实测 `000668` 的买入席位里
    /// `机构专用`（营业部代码 `'0'`）出现 **3 次**，金额各不相同 ——
    /// 供应商不披露机构名称，只用多行表示"几家机构"。
    /// 全量数据里这类重复有 25/26 组，最多一组 4 行。
    func testSeatNaturalKeyIsNotUnique() throws {
        let seats = LhbSource.parseSeats(try fixtureText("lhb_seats_buy.json"), side: "BUY")
        let natural = seats.map { "\($0.code)|\($0.changeType)|\($0.deptName)" }
        XCTAssertLessThan(Set(natural).count, natural.count,
                          "席位 (code, changeType, 营业部) **不唯一** → 不能当主键")

        // 具体地：000668 有 3 行同名「机构专用」，营业部代码都是 '0'
        let inst = seats.filter { $0.code == "000668" && $0.isInstitution }
        XCTAssertEqual(inst.count, 3)
        XCTAssertEqual(Set(inst.map(\.deptCode)), ["0"], "匿名化：代码恒为 '0'")
        XCTAssertEqual(Set(inst.map(\.buy)).count, 3, "3 行金额互不相同（各代表一家机构）")

        // 加上 rank 之后才唯一（rank = 响应顺序，不是金额名次）
        let withRank = seats.map { "\($0.code)|\($0.changeType)|\($0.side)|\($0.rank)" }
        XCTAssertEqual(Set(withRank).count, withRank.count)

        // TRADE_ID 也**不是**席位行的键 —— 它是"上榜记录"的 id，同组 5 行共用一个
        XCTAssertLessThan(Set(seats.map { "\($0.code)|\($0.changeType)" }).count, seats.count)
    }

    /// 实测恒等式：`net == buy - sell`（680 行零反例）
    func testSeatNetEqualsBuyMinusSell() throws {
        for (file, side) in [("lhb_seats_buy.json", "BUY"), ("lhb_seats_sell.json", "SELL")] {
            for s in LhbSource.parseSeats(try fixtureText(file), side: side) {
                XCTAssertEqual(s.net, s.buy - s.sell, accuracy: 0.01,
                               "\(s.deptName) 的 net 与 buy-sell 不一致")
            }
        }
    }

    /// 源字段 `BUY` / `SELL` 可能是 `null`（该侧无成交）→ 必须按 **0** 处理。
    /// 若按"解析失败"整行跳过，会**静默少掉席位**（实测 680 行里 260 行有一侧为 null）。
    func testNullSideBecomesZeroNotSkipped() throws {
        let seats = LhbSource.parseSeats(try fixtureText("lhb_seats_buy.json"), side: "BUY")
        // 一行都不能少 —— 这是"按 0 处理而不是跳过"的直接体现
        XCTAssertEqual(seats.count, 45)

        let c600721 = seats.filter { $0.code == "600721" }
        XCTAssertEqual(c600721.count, 15, "600721 的 3 条记录各有 5 个买入席位")
        XCTAssertTrue(c600721.allSatisfy { $0.sell == 0 },
                      "600721 买入席位的 SELL 源字段全为 null → 必须落成 0")
        XCTAssertTrue(c600721.allSatisfy { $0.buy > 0 })
        XCTAssertTrue(c600721.allSatisfy { $0.net == $0.buy },
                      "sell 为 null 时 net 仍等于 buy - sell（= buy）")
    }

    /// 机构 / 股通是**可从席位名直接判读**的参与方类型 ——
    /// 这正是"不需要额外的机构买卖汇总端点"的依据。
    func testInstitutionAndStockConnectFlags() throws {
        let buy = LhbSource.parseSeats(try fixtureText("lhb_seats_buy.json"), side: "BUY")
        let sell = LhbSource.parseSeats(try fixtureText("lhb_seats_sell.json"), side: "SELL")

        // 股通专用：000002（万科A）买卖两侧各 1 行「深股通专用」
        XCTAssertEqual(buy.filter { $0.isStockConnect }.map(\.code), ["000002"])
        XCTAssertEqual(sell.filter { $0.isStockConnect }.map(\.code), ["000002"])

        // 机构专用：买入侧 3 行（全是 000668）；卖出侧 3 行（000668 ×2 + 000002 ×1）
        XCTAssertEqual(buy.filter { $0.isInstitution }.map(\.code), ["000668", "000668", "000668"])
        XCTAssertEqual(sell.filter { $0.isInstitution }.map(\.code).sorted(),
                       ["000002", "000668", "000668"])

        // 普通营业部既不是机构也不是股通（两个判据不能互相误伤）
        let normal = buy.filter { $0.deptName.contains("证券营业部") }
        XCTAssertFalse(normal.isEmpty)
        XCTAssertTrue(normal.allSatisfy { !$0.isInstitution && !$0.isStockConnect })
    }

    // MARK: - 决策锁（防回归）

    /// 前瞻字段**绝不能**出现在 DDL 里。
    /// 这些列一旦建出来，写入端"顺手填上"就会把未来收益混进时点数据，
    /// 而**任何现有测试都不会变红** —— 所以用一条静态断言把它挡住。
    func testDDLContainsNoForwardLookingColumns() {
        let sql = LhbStore.createSQL.lowercased()
        for bad in ["adjchrate", "d1_", "d2_", "d5_", "d10_", "d20_", "d30_",
                    "rise_probability", "buyrio", "sellrio", "salestimes",
                    "buy_seat", "sell_seat", "sum_buy_amt", "sum_sell_amt", "net_bs_amt",
                    "explain"] {
            XCTAssertFalse(sql.contains(bad),
                           "DDL 里出现了被否决的字段 `\(bad)` —— 见决策台账 事实⑥")
        }
    }

    /// 主键形状：主表含 `change_type`（稳定规则码），**不含** `explanation`（会变的文案）
    func testPrimaryKeysMatchDesign() throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &db), SQLITE_OK)
        let handle = try XCTUnwrap(db)
        defer { sqlite3_close(handle) }
        try exec(handle, LhbStore.createSQL)

        let recCols = try columns(handle, "stock_lhb")
        XCTAssertTrue(recCols.contains("change_type"))
        XCTAssertTrue(recCols.contains("explanation"))
        XCTAssertEqual(try pkColumns(handle, "stock_lhb"),
                       ["trade_date", "code", "change_type"],
                       "主表主键必须是 (交易日, 代码, 规则码)")
        XCTAssertEqual(try pkColumns(handle, "stock_lhb_seats"),
                       ["trade_date", "code", "change_type", "side", "rank"],
                       "席位表主键必须含 side 与 rank（它没有自然键）")
    }

    /// DDL 真的能建出**两张表 + 两个索引**，且幂等
    func testCreateSQLBuildsBothTables() throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &db), SQLITE_OK)
        let handle = try XCTUnwrap(db)
        defer { sqlite3_close(handle) }

        try exec(handle, LhbStore.createSQL)

        XCTAssertEqual(try columns(handle, "stock_lhb").count, 21)
        XCTAssertEqual(try columns(handle, "stock_lhb_seats").count, 10)
        for idx in ["idx_stock_lhb_code", "idx_stock_lhb_seats_code"] {
            XCTAssertEqual(try count(handle, "SELECT COUNT(*) FROM sqlite_master"
                                     + " WHERE type='index' AND name='\(idx)'"), 1, idx)
        }

        // 幂等：同一条 DDL 再跑一遍必须成功（`IF NOT EXISTS` 真的写了）
        XCTAssertEqual(sqlite3_exec(handle, LhbStore.createSQL, nil, nil, nil), SQLITE_OK,
                       "DDL 不幂等 —— 每次启动都会失败")
    }

    /// 「删该日 → 整批插入」的语义（`saveDay` 用的就是它）
    ///
    /// 这里验证的是**SQL 语义**，不是 `saveDay` 本身（后者走 `SQLiteWriter.shared`，
    /// 指向真实库路径，单测里不便驱动）。`saveDay` 的真实验证在端到端自检里做。
    func testDeleteThenInsertReplacesWholeDay() throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &db), SQLITE_OK)
        let handle = try XCTUnwrap(db)
        defer { sqlite3_close(handle) }
        try exec(handle, LhbStore.createSQL)

        func seed(_ rows: [(String, String)]) {
            try? exec(handle, "DELETE FROM stock_lhb WHERE trade_date = '2026-09-21'")
            for (code, ct) in rows {
                try? exec(handle, "INSERT INTO stock_lhb(trade_date, code, change_type)"
                          + " VALUES('2026-09-21','\(code)','\(ct)')")
            }
        }
        seed([("600721", "a"), ("600721", "b"), ("600721", "c")])
        XCTAssertEqual(try count(handle, "SELECT COUNT(*) FROM stock_lhb"), 3)

        // 重跑（比如供应商修正了当日数据）→ 必须**整日替换**，不能残留旧的 'c'
        seed([("600721", "a"), ("600721", "b")])
        XCTAssertEqual(try count(handle, "SELECT COUNT(*) FROM stock_lhb"), 2,
                       "删日重写没有生效 → 会留下上一次的残影")
        XCTAssertEqual(try count(handle,
            "SELECT COUNT(*) FROM stock_lhb WHERE change_type = 'c'"), 0)

        // 别的日期不受影响
        try? exec(handle, "INSERT INTO stock_lhb(trade_date, code, change_type)"
                  + " VALUES('2026-09-18','000001','x')")
        seed([("600721", "a")])
        XCTAssertEqual(try count(handle, "SELECT COUNT(*) FROM stock_lhb"), 2,
                       "删日重写不能碰其他交易日")
    }

    // MARK: - 输入校验

    /// `date` 是唯一进入查询表达式的外部输入 → 必须百分号编码 + 先过格式校验
    func testApiURLPercentEncodesFilter() {
        let url = LhbSource.apiURL(report: LhbSource.dayReport,
                                   date: "2026-09-21", pageSize: 500)
        XCTAssertTrue(url.contains("filter=(TRADE_DATE%3D%272026-09-21%27)"),
                      "filter 的 = 与 ' 必须编码：\(url)")
        XCTAssertTrue(url.contains("reportName=RPT_DAILYBILLBOARD_DETAILSNEW"))
        XCTAssertTrue(url.contains("pageSize=500"))
    }

    func testIsDateRejectsInjectionAndJunk() {
        XCTAssertTrue(LhbSource.isDate("2026-09-21"))
        for bad in ["2026-9-21", "2026-09-21 00:00:00", "20260921", "",
                    "2026-09-21') OR 1=1 --", "abcd-ef-gh", "2026-09-2a"] {
            XCTAssertFalse(LhbSource.isDate(bad), "应拒绝：\(bad)")
        }
        // 非法日期不得被拼进 URL（fetch 直接返回空）
        XCTAssertTrue(LhbSource.fetchDay("2026-09-21') OR 1=1 --").isEmpty)
    }

    func testDayOfHandlesTimestampAndJunk() {
        XCTAssertEqual(LhbSource.dayOf("2026-09-21 00:00:00"), "2026-09-21")
        XCTAssertEqual(LhbSource.dayOf("2026-09-21"), "2026-09-21")
        XCTAssertNil(LhbSource.dayOf("2026-09"))
        XCTAssertNil(LhbSource.dayOf(nil))
        XCTAssertNil(LhbSource.dayOf(NSNull()))
    }

    // MARK: - 日更任务（纯函数部分）

    /// 回看窗口必须**跳过周末**（龙虎榜只在交易日有数据，周末去请求是纯浪费）
    ///
    /// 2026-09-22 是周二 → 往前是 09-21(一) 09-20(日) 09-19(六) 09-18(五) …
    func testRecentDaysSkipsWeekends() {
        XCTAssertEqual(LhbJob.recentDays(before: "2026-09-22", count: 5),
                       ["2026-09-21", "2026-09-18", "2026-09-17", "2026-09-16", "2026-09-15"])
        // 从周一往前：直接跨过周末到上周五
        XCTAssertEqual(LhbJob.recentDays(before: "2026-09-21", count: 3),
                       ["2026-09-18", "2026-09-17", "2026-09-16"])
    }

    func testRecentDaysHandlesZeroAndJunk() {
        XCTAssertTrue(LhbJob.recentDays(before: "2026-09-22", count: 0).isEmpty,
                      "count=0 不能崩（`1...0` 会 trap）")
        XCTAssertTrue(LhbJob.recentDays(before: "不是日期", count: 3).isEmpty)
    }

    /// `Scheduler.finish` 把**含「非交易日」的失败**当成"当天已完成"而静默跳过。
    /// 龙虎榜"尚未发布"是**可重试**的情形，文案里绝不能出现那个词。
    func testFailureTextDoesNotLookLikeNonTradingDay() {
        for msg in [LhbJob.Failure.notReady(date: "2026-09-22").errorDescription ?? "",
                    LhbJob.Failure.fetchFailed("网络超时").errorDescription ?? ""] {
            XCTAssertFalse(msg.contains("非交易日"),
                           "含该词会被当成「今天已完成」→ 数据没准备好被静默吞掉：\(msg)")
            XCTAssertFalse(msg.isEmpty)
        }
        XCTAssertTrue((LhbJob.Failure.notReady(date: "2026-09-22").errorDescription ?? "")
                        .contains("2026-09-22"))
    }

    // MARK: - 小工具

    private func exec(_ db: OpaquePointer, _ sql: String) throws {
        var errmsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errmsg)
        let msg = errmsg.map { String(cString: $0) } ?? "?"
        sqlite3_free(errmsg)
        XCTAssertEqual(rc, SQLITE_OK, "SQL 执行失败：\(msg) | \(sql)")
    }

    private func columns(_ db: OpaquePointer, _ table: String) throws -> [String] {
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &stmt, nil),
                       SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "")
        }
        return out
    }

    /// 主键列，按 `PRAGMA table_info` 的 `pk` 序号（1 起）排序
    private func pkColumns(_ db: OpaquePointer, _ table: String) throws -> [String] {
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &stmt, nil),
                       SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        var pairs: [(Int, String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let pk = Int(sqlite3_column_int(stmt, 5))
            guard pk > 0 else { continue }
            pairs.append((pk, sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""))
        }
        return pairs.sorted { $0.0 < $1.0 }.map(\.1)
    }

    private func count(_ db: OpaquePointer, _ sql: String) throws -> Int {
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &stmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return -1 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    // MARK: - 完整性闸门的读数

    /// `result.count` → 源报总数。固定 `pageNumber=1` + `dayPageSize=500`，超上限会被静默截断，
    /// 判"实得 < 源报总数"就靠这个数。
    func testDataTotalReadsResultCount() {
        let text = #"{"result":{"data":[{"a":1}],"count":513}}"#
        XCTAssertEqual(LhbSource.dataTotal(text), 513, "必须读 result.count")
    }

    /// `JSONSerialization` 给的是 `NSNumber` —— 若 JSON 里写成浮点（`500.0`），
    ///   直接 `as? Int` 会失败。这里钉住"两种都认"。
    func testDataTotalAcceptsFloatingCount() {
        XCTAssertEqual(LhbSource.dataTotal(#"{"result":{"data":[],"count":500.0}}"#), 500)
    }

    /// 源没给总数 / 响应不可解析 → `nil`（= **无法验证**）。
    /// ⚠ 旧口径是 `-1`，而两个闸门写作 `total > 0, count < total` ⇒ `-1` 让闸门整体跳过，
    ///   于是"源没报总数"被当成"数据完整"，超过分页上限的半截日子照样落库
    ///   （2026-10-16 审查 B2 修正）。现在 `nil` 由调用方按
    ///   "不可验证 + 实得已达分页上限 ⇒ 拒绝"处理。
    func testDataTotalIsNilWhenAbsent() {
        XCTAssertNil(LhbSource.dataTotal(#"{"result":{"data":[]}}"#))
        XCTAssertNil(LhbSource.dataTotal("not json"))
        XCTAssertNil(LhbSource.dataTotal(""))
    }

    /// 越界/非有限值不得崩（`Int(1e30)` 是不可 catch 的 trap，见 `Num.intSafe`）
    func testDataTotalOutOfRangeIsNilNotCrash() {
        XCTAssertNil(LhbSource.dataTotal(#"{"result":{"data":[],"count":1e30}}"#))
    }
}
