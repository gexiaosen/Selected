import XCTest
@testable import SelectedCore

/// 涨停统计。
///
/// 重点是**解析口径**（源字段的单位与形状都很"怪"）与**失败文案**（会被调度器当状态用）。
final class LimitUpPoolTests: XCTestCase {

    /// 真实抓取的片段（截 2 行，字段原样）
    private let realSample = """
    {"rc":0,"rt":110,"svr":177618783,"lt":1,"full":0,"data":{"tc":57,"qdate":20260922,
    "pool":[{"c":"000504","m":0,"n":"南华生物","p":12110,"zdp":9.990917205810547,
    "amount":68127227,"ltsz":3985672239.7799999,"tshare":3996579789.4399998,
    "hs":1.7093032598495484,"lbc":4,"fbt":92500,"lbt":92500,"fund":474986897,"zbc":0,
    "hybk":"医疗服务","zttj":{"days":4,"ct":4}},
    {"c":"000756","m":0,"n":"新华制药","p":16140,"zdp":10.0204496383667,
    "amount":1543178128,"ltsz":8051808783.54,"tshare":11244470721.6,
    "hs":19.20052719116211,"lbc":2,"fbt":92500,"lbt":101027,"fund":88876524,"zbc":7,
    "hybk":"化学制药","zttj":{"days":2,"ct":2}}]}}
    """

    // MARK: - 解析

    func testParseRealResponse() {
        let (rows, total) = LimitUpPoolSource.parsePage(realSample, date: "2026-09-22")
        XCTAssertEqual(total, 57, "tc 是当天总数（完整性检查要用）")
        XCTAssertEqual(rows.count, 2)
        let a = rows[0]
        XCTAssertEqual(a.code, "000504")
        XCTAssertEqual(a.name, "南华生物")
        XCTAssertEqual(a.date, "2026-09-22", "日期由**请求日期**盖章（响应里的 qdate 是服务器当天）")
        XCTAssertEqual(a.price, 12.11, accuracy: 1e-9, "源字段 p 是 ×1000 的整数")
        XCTAssertEqual(a.changePct, 9.990917205810547, accuracy: 1e-6)
        XCTAssertEqual(a.amount, 68127227, accuracy: 1e-6)
        XCTAssertEqual(a.turnoverRate, 1.7093032598495484, accuracy: 1e-9)
        XCTAssertEqual(a.boards, 4, "lbc = 连板数")
        XCTAssertEqual(a.statDays, 4, "zttj.days")
        XCTAssertEqual(a.statBoards, 4, "zttj.ct")
        XCTAssertEqual(a.firstSeal, "09:25:00")
        XCTAssertEqual(a.lastSeal, "09:25:00")
        XCTAssertEqual(a.brokenCount, 0)
        XCTAssertEqual(a.sealFund, 474986897, accuracy: 1e-6)
        XCTAssertEqual(a.industry, "医疗服务")
    }

    /// 第二行：炸板 7 次、首封 09:25 / 末封 10:10:27（`lbt` 是 `101027`）
    func testParseSecondRowCarriesBrokenAndLastSeal() {
        let (rows, _) = LimitUpPoolSource.parsePage(realSample, date: "2026-09-22")
        let b = rows[1]
        XCTAssertEqual(b.brokenCount, 7)
        XCTAssertEqual(b.lastSeal, "10:10:27", "101027 → 10:10:27（必须补零）")
        XCTAssertEqual(b.boards, 2)
    }

    /// 封板时间**必须补零**：`92500` 直接切分会得到 `9:25:00`，
    /// 而排序与展示都按字符串比 → 与 `10:10:27` 混在一起时顺序会错
    func testSealTimePadsZeros() {
        XCTAssertEqual(LimitUpPoolSource.sealTime(92500), "09:25:00")
        XCTAssertEqual(LimitUpPoolSource.sealTime(101027), "10:10:27")
        XCTAssertEqual(LimitUpPoolSource.sealTime(150000), "15:00:00")
        XCTAssertEqual(LimitUpPoolSource.sealTime("92500"), "09:25:00", "字符串形态也认")
    }

    /// 非法/缺失 → `""`（**不是** `"00:00:00"` —— 那会被当成"开盘就封板"）
    func testSealTimeRejectsInvalidInsteadOfZero() {
        XCTAssertEqual(LimitUpPoolSource.sealTime(nil), "")
        XCTAssertEqual(LimitUpPoolSource.sealTime(0), "")
        XCTAssertEqual(LimitUpPoolSource.sealTime("abc"), "")
        XCTAssertEqual(LimitUpPoolSource.sealTime(999999), "", "99:99:99 不合法")
        XCTAssertEqual(LimitUpPoolSource.sealTime(126000), "", "12:60:00 不合法")
    }

    /// `data` 为 null / 非预期形状 → `([], 0)`（**全有或全无**）
    func testParseRejectsMalformed() {
        XCTAssertEqual(LimitUpPoolSource.parsePage("", date: "2026-09-22").rows.count, 0)
        XCTAssertEqual(LimitUpPoolSource.parsePage("<html>", date: "2026-09-22").total, 0)
        XCTAssertEqual(LimitUpPoolSource.parsePage(#"{"data":null}"#, date: "2026-09-22").total, 0)
        // 有 data 但没 pool（比如超出覆盖窗口）→ rows 空、tc 仍可读
        let (r, t) = LimitUpPoolSource.parsePage(#"{"data":{"tc":0}}"#, date: "2026-09-22")
        XCTAssertTrue(r.isEmpty)
        XCTAssertEqual(t, 0)
    }

    /// 代码非法的行跳过（源里偶有异常行）
    func testParseSkipsRowsWithBadCode() {
        // 多行 raw string 要用 `#"""` … `"""#`（单行形态 `#"…"#` 不能跨行）
        let text = #"""
        {"data":{"tc":3,"pool":[
            {"c":"000504","n":"A","p":1000},
            {"c":"12345","n":"B","p":1000},
            {"c":"abc123","n":"C","p":1000}]}}
        """#
        let (rows, total) = LimitUpPoolSource.parsePage(text, date: "2026-09-22")
        XCTAssertEqual(rows.map(\.code), ["000504"], "只留 6 位纯数字代码")
        XCTAssertEqual(total, 3, "tc 照读（完整性检查靠它）")
    }

    /// 缺 `zttj` 时天数/板数回落 0（不崩）
    func testParseToleratesMissingStat() {
        let text = #"{"data":{"tc":1,"pool":[{"c":"000504","n":"A","p":1000,"lbc":1}]}}"#
        let (rows, _) = LimitUpPoolSource.parsePage(text, date: "2026-09-22")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].statDays, 0)
        XCTAssertEqual(rows[0].statBoards, 0)
        XCTAssertEqual(rows[0].boards, 1)
        XCTAssertEqual(rows[0].firstSeal, "")
    }

    // MARK: - 文案

    /// 连板文案：首板 / N 连板 / N 天 M 板
    func testStreakText() {
        func rec(boards: Int, days: Int) -> LimitUpRecord {
            LimitUpRecord(date: "2026-09-22", code: "000504", name: "", price: 0,
                          changePct: 0, amount: 0, turnoverRate: 0, floatCap: 0, totalCap: 0,
                          boards: boards, statDays: days, statBoards: boards,
                          firstSeal: "", lastSeal: "", brokenCount: 0, sealFund: 0,
                          industry: "")
        }
        XCTAssertEqual(rec(boards: 1, days: 1).streakText, "首板")
        XCTAssertEqual(rec(boards: 4, days: 4).streakText, "4 连板")
        XCTAssertEqual(rec(boards: 2, days: 5).streakText, "5 天 2 板", "N 天 M 板不是连板")
    }

    // MARK: - URL 与日期

    func testURLAndDateValidation() {
        let u = LimitUpPoolSource.url(date: "2026-09-22", page: 0)
        for token in ["getTopicZTPool", "dpt=wz.ztzt", "date=20260922",
                      "Pageindex=0", "pagesize=200", "sort=fbt"] {
            XCTAssertTrue(u.contains(token), "URL 缺 \(token)：\(u)")
        }
        XCTAssertTrue(u.hasPrefix("https://push2ex.eastmoney.com/"))
        XCTAssertTrue(LimitUpPoolSource.isDate("2026-09-22"))
        XCTAssertFalse(LimitUpPoolSource.isDate("2026-9-22"))
        XCTAssertFalse(LimitUpPoolSource.isDate(""))
        XCTAssertFalse(LimitUpPoolSource.isDate("20260922"))
    }

    // MARK: - 任务常量与失败文案（文案会被调度器当状态用）

    /// 失败文案里**不能**出现「非交易日」——
    /// `Scheduler.finish` 把含该词的失败当成"当天完成"（标记完成但不通知），
    /// 那会把"数据没准备好"**静默吞掉**，而涨停池只覆盖 10 余天、丢一天就少一天。
    func testNotReadyMessageDoesNotLookLikeANonTradingDay() {
        let msg = LimitUpPoolJob.Failure.notReady(date: "2026-09-22").errorDescription ?? ""
        XCTAssertFalse(msg.contains("非交易日"),
                       "文案含「非交易日」会被调度器当成完成 → 静默丢数据：\(msg)")
        XCTAssertTrue(msg.contains("2026-09-22"), "要写明是哪一天：\(msg)")
        XCTAssertTrue(msg.contains("重试"), "要提示可重试：\(msg)")
    }

    /// 回看窗口与下界都是**有意的值**（改它们等于改"多久之内补得回来"）
    func testJobConstants() {
        XCTAssertEqual(LimitUpPoolJob.lookbackDays, 5, "回看 5 天：覆盖'周五没开机、周一补上'")
        XCTAssertEqual(LimitUpPoolJob.minRecords, 3,
                       "一天的涨停家数下界（判断'这次抓取像不像完整的'，不是判断行情好坏）")
    }

    // MARK: - 建表契约

    /// DDL 的列名与读取处必须逐字对上（错了只会**静默读到 0**）
    func testStoreSchemaMatchesTheReaders() {
        let sql = LimitUpPoolStore.createSQL
        for col in ["trade_date", "code", "name", "price", "change_pct", "amount",
                    "turnover_rate", "float_cap", "total_cap", "boards", "stat_days",
                    "stat_boards", "first_seal", "last_seal", "broken_count",
                    "seal_fund", "industry", "fetched_at"] {
            XCTAssertTrue(sql.contains(col), "limit_up_pool 缺列 \(col)")
        }
        XCTAssertTrue(sql.contains("PRIMARY KEY (trade_date, code)"))
        // 详情页问的是"**这只票**最近涨停过吗" → 必须有 code 上的索引
        XCTAssertTrue(sql.contains("\(LimitUpPoolStore.codeIndexName) ON limit_up_pool(code, trade_date)"))
    }
}
