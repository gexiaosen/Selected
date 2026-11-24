import XCTest
import SQLite3
@testable import SelectedCore

/// 昨日涨停表现 —— 纯计算，重点在**晋级判据**与**停牌处理**：
/// · 停牌/缺价 → 计入 `missing`、**不进均值**（否则停牌 0% 把情绪拉平）；
/// · 晋级按**该票自己的板块上限**判（用昨日封板涨幅反推，不硬编码代码前缀表）。
final class ZtSentimentTests: XCTestCase {

    // MARK: - 板块上限反推

    /// 昨日封板涨幅 → 板块涨停上限（四档：5 / 10 / 20 / 30）
    func testBoardLimitFromYesterdayPct() {
        XCTAssertEqual(ZtSentiment.boardLimitPct(9.99), 10, "主板")
        XCTAssertEqual(ZtSentiment.boardLimitPct(10.0), 10)
        XCTAssertEqual(ZtSentiment.boardLimitPct(19.98), 20, "创业板/科创板")
        XCTAssertEqual(ZtSentiment.boardLimitPct(20.0), 20)
        XCTAssertEqual(ZtSentiment.boardLimitPct(29.9), 30, "北交所")
        XCTAssertEqual(ZtSentiment.boardLimitPct(4.5), 10, "异常低（连 ST 板都够不着）保守归 10")
    }

    /// ⚠ ST 主板 ±5% 必须有自己的一档（2026-10-16 审查 B5-8）。
    /// 修复前 `case ..<15: return 10` 把 +5.0% 的 ST 涨停归到主板 10% 档，
    /// 于是 `isPromoted` 要求今天 ≥9.8% ⇒ **ST 二连板永远不算晋级**，
    /// 连板晋级率被系统性压低、亏损面被抬高（这两个数直接展示在板块页）。
    /// 归档即证据：能进昨日涨停池 ⇒ 昨天封在涨停价上 ⇒ 昨天涨幅就等于它的板块上限。
    func testSTBandIsFivePercentNotTen() {
        XCTAssertEqual(ZtSentiment.boardLimitPct(5.0), 5, "ST 主板封板涨幅约 +5.00%")
        XCTAssertEqual(ZtSentiment.boardLimitPct(5.10), 5, "四舍五入到分会略高（如昨收 3.33 → 3.50）")
        XCTAssertEqual(ZtSentiment.boardLimitPct(4.95), 5, "也可能略低（如昨收 5.05 → 5.30）")
        // ST 二连板（+5.02%）必须判为晋级
        XCTAssertTrue(ZtSentiment.isPromoted(todayChangePct: 5.02, yesterdayChangePct: 5.0),
                      "ST 昨日封板、今日再封 +5% ⇒ 应计晋级")
        // ST 今天只涨 3%（没封住）→ 不算晋级
        XCTAssertFalse(ZtSentiment.isPromoted(todayChangePct: 3.0, yesterdayChangePct: 5.0))
    }


    /// 晋级判定：今天涨幅 ≥ 板块上限 − 容差
    func testIsPromoted() {
        // 主板昨涨停，今天又封住（+10%）→ 晋级
        XCTAssertTrue(ZtSentiment.isPromoted(todayChangePct: 10.02, yesterdayChangePct: 9.99))
        // 主板今天只涨 9.7%（没封住）→ 不算晋级（差一口气，容差 0.2 挡在外面）
        XCTAssertFalse(ZtSentiment.isPromoted(todayChangePct: 9.7, yesterdayChangePct: 9.99))
        // 创业板昨涨停（+20%），今天 +19.9% → 晋级（上限 20，容差 0.2 → 阈值 19.8）
        XCTAssertTrue(ZtSentiment.isPromoted(todayChangePct: 19.9, yesterdayChangePct: 19.98))
        // 创业板今天只涨 10%（主板水平）→ 不晋级
        XCTAssertFalse(ZtSentiment.isPromoted(todayChangePct: 10.0, yesterdayChangePct: 19.98))
    }

    // MARK: - 汇总

    /// 奇数样本：中位数取中间值；平均/晋级/亏损面各自计数
    func testComputeOddSample() {
        let samples: [ZtSentiment.Sample] = [
            .init(changePct: 10.0, promoted: true),
            .init(changePct: -3.0, promoted: false),
            .init(changePct: 5.0, promoted: false),
        ]
        let r = ZtSentiment.compute(date: "2026-10-12", samples: samples, missing: 2)
        XCTAssertEqual(r.sample, 3)
        XCTAssertEqual(r.missing, 2)
        XCTAssertEqual(r.avgPct, (10 - 3 + 5) / 3.0, accuracy: 0.01)
        XCTAssertEqual(r.medianPct, 5.0, accuracy: 1e-9, "排序后 [-3,5,10] 中位 = 5")
        XCTAssertEqual(r.promoted, 1)
        XCTAssertEqual(r.lossCount, 1, "-3% 是唯一亏损")
        XCTAssertEqual(r.promotionRate, 1.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(r.lossRate, 1.0 / 3.0, accuracy: 1e-9)
    }

    /// 偶数样本：中位数取中间两值平均
    func testComputeEvenMedian() {
        let samples: [ZtSentiment.Sample] = [
            .init(changePct: 2.0, promoted: false),
            .init(changePct: 4.0, promoted: false),
            .init(changePct: 6.0, promoted: false),
            .init(changePct: 8.0, promoted: false),
        ]
        let r = ZtSentiment.compute(date: "2026-10-12", samples: samples, missing: 0)
        XCTAssertEqual(r.medianPct, 5.0, accuracy: 1e-9, "(4+6)/2")
    }

    /// 空样本 → 全 0，**不除零**（`sample == 0` 时 rate 返回 0）
    func testComputeEmptySafe() {
        let r = ZtSentiment.compute(date: "2026-10-12", samples: [], missing: 5)
        XCTAssertEqual(r.sample, 0)
        XCTAssertEqual(r.missing, 5, "全停牌也要如实报 missing")
        XCTAssertEqual(r.avgPct, 0)
        XCTAssertEqual(r.medianPct, 0)
        XCTAssertEqual(r.promotionRate, 0)
        XCTAssertEqual(r.lossRate, 0)
    }

    /// 亏损面：`< 0` 才算跌，`== 0`（平盘）不算
    func testLossCountExcludesFlat() {
        let samples: [ZtSentiment.Sample] = [
            .init(changePct: 0.0, promoted: false),
            .init(changePct: -0.01, promoted: false),
            .init(changePct: 0.01, promoted: false),
        ]
        let r = ZtSentiment.compute(date: "2026-10-12", samples: samples, missing: 0)
        XCTAssertEqual(r.lossCount, 1, "只有 -0.01 算亏损，平盘 0 不算")
    }

    // MARK: - 建表 DDL（真的执行一遍，与 FundFlowTests 同一姿势）

    func testCreateSQLActuallyBuildsTheTable() throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &db), SQLITE_OK)
        let handle = try XCTUnwrap(db)
        defer { sqlite3_close(handle) }

        var errmsg: UnsafeMutablePointer<CChar>?
        XCTAssertEqual(sqlite3_exec(handle, ZtSentimentStore.createSQL, nil, nil, &errmsg), SQLITE_OK,
                       "createSQL 执行失败：\(errmsg.map { String(cString: $0) } ?? "?")")
        sqlite3_free(errmsg)

        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(handle, "PRAGMA table_info(zt_sentiment)", -1, &stmt, nil),
                       SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        var cols: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            cols.append(sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "")
        }
        XCTAssertEqual(cols, ["trade_date", "sample", "missing", "avg_pct", "median_pct",
                              "promoted", "loss_count", "fetched_at"],
                       "列清单必须与 `ZtSentimentStore.result()` 的取值键逐字对上")

        // 幂等（每次启动都跑）
        XCTAssertEqual(sqlite3_exec(handle, ZtSentimentStore.createSQL, nil, nil, nil), SQLITE_OK)
    }
}
