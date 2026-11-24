import Foundation
import SQLite3
@testable import SelectedCore

/// 涨停统计**真实库自检** —— 建表 / 整日重插 / 读取 / 覆盖天数。
///
/// 跑之前必须把 `SELECTED_DATA_DIR` 指到**现造的库**（`limit_up_pool_test.sh` 负责）。
/// **全程离线**：本驱动不调 `LimitUpPoolSource`（那是网络），
///   只验证落库与读取；解析由 `LimitUpPoolTests` 用真实响应片段覆盖。
@main
struct LimitUpPoolCheck {
    static var failures: [String] = []
    static var checks = 0

    static func check(_ cond: Bool, _ label: String) {
        checks += 1
        if !cond { failures.append(label) }
        print("   \(cond ? "✅" : "❌") \(label)")
    }

    static func eq<T: Equatable>(_ got: T, _ want: T, _ label: String) {
        check(got == want, "\(label)（实得 \(got)）")
    }

    static func main() {
        print("== limit-up-pool 自检 ==")
        stageBootstrap()
        stageSaveAndRead()
        stageReplacementIsWholeDay()
        stageQueries()
        stageDeleteAll()

        print("—— 检查 \(checks) 项，失败 \(failures.count) 项")
        if !failures.isEmpty {
            for f in failures { print("   ❌ \(f)") }
            exit(1)
        }
        exit(0)
    }

    // MARK: - 建表

    static func stageBootstrap() {
        print("\n[1] 建库 + Swift-only 迁移")
        let dir = DataDirectory.resolve()
        check(!FileManager.default.fileExists(atPath: dir + "/selected.sqlite3"),
              "起点是空目录：\(dir)")
        let err = DBBootstrap.ensureReady()
        check(err == nil, "ensureReady 成功（\(err ?? "ok")）")
        DBBootstrap.ensureSwiftOnlySchemaOnDisk()
        let cols = tableColumns("limit_up_pool")
        for c in ["trade_date", "code", "name", "price", "boards", "first_seal",
                  "broken_count", "industry", "fetched_at"] {
            check(cols.contains(c), "limit_up_pool 有列 \(c)")
        }
        check(tableIndexes("limit_up_pool").contains(LimitUpPoolStore.codeIndexName),
              "有 \(LimitUpPoolStore.codeIndexName) 索引（详情页按 code 查）")
    }

    // MARK: - 夹具

    /// 造一条记录（`code` 用 6 位数字，`boards` 递增便于断言）
    static func rec(_ date: String, _ code: String, boards: Int = 1,
                    firstSeal: String = "09:25:00", broken: Int = 0) -> LimitUpRecord {
        LimitUpRecord(date: date, code: code, name: "样本\(code)", price: 12.11,
                      changePct: 9.99, amount: 68_127_227, turnoverRate: 1.71,
                      floatCap: 3_985_672_239, totalCap: 3_996_579_789,
                      boards: boards, statDays: boards, statBoards: boards,
                      firstSeal: firstSeal, lastSeal: firstSeal,
                      brokenCount: broken, sealFund: 474_986_897, industry: "医疗服务")
    }

    // MARK: - 写入 + 读取

    static func stageSaveAndRead() {
        print("\n[2] 写入 + 读取")
        let date = "2026-09-22"
        let records = [rec(date, "000504", boards: 4),
                       rec(date, "000607", boards: 2, firstSeal: "09:31:00", broken: 3),
                       rec(date, "600743", boards: 1, firstSeal: "10:10:27")]
        let n = (try? LimitUpPoolStore.saveDay(date: date, records: records,
                                               at: "2026-09-22 15:15:00")) ?? -1
        eq(n, 3, "写入 3 条")

        let back = LimitUpPoolStore.dayRecords(date)
        eq(back.count, 3, "读回 3 条")
        // 按**首封时间**升序（早封板的在前）
        eq(back.map(\.code), ["000504", "000607", "600743"], "按首封时间升序")

        // 字段往返（含文本、整数、浮点）
        guard let first = back.first else { return check(false, "读不到第一条") }
        eq(first.boards, 4, "boards 往返")
        eq(first.firstSeal, "09:25:00", "first_seal 文本往返（前导零不能丢）")
        eq(first.industry, "医疗服务", "industry 往返")
        eq(first.price, 12.11, "price 浮点往返")
        eq(first.amount, 68_127_227, "amount 大额浮点往返")
        eq(first.date, date, "trade_date 往返")

        // 炸板次数
        eq(LimitUpPoolStore.dayRecords(date).first { $0.code == "000607" }?.brokenCount, 3,
           "broken_count 往返")
    }

    /// **整日重插**：新的一份更少时必须把旧的清掉（否则留下"幽灵涨停股"）
    static func stageReplacementIsWholeDay() {
        print("\n[3] 整日重插（不是追加）")
        let date = "2026-09-21"
        _ = try? LimitUpPoolStore.saveDay(date: date, records: [rec(date, "000001"),
                                                                rec(date, "000002")],
                                          at: "t1")
        eq(LimitUpPoolStore.dayRecords(date).count, 2, "先写 2 条")
        _ = try? LimitUpPoolStore.saveDay(date: date, records: [rec(date, "000003")], at: "t2")
        let after = LimitUpPoolStore.dayRecords(date)
        eq(after.map(\.code), ["000003"], "换成 1 条后只剩这 1 条（旧的被清掉）")
        check(!after.contains { $0.code == "000001" }, "旧的 000001 不该残留（幽灵涨停股）")
        // 其它日期不受影响
        eq(LimitUpPoolStore.dayRecords("2026-09-22").count, 3, "换 09-21 不影响 09-22")
    }

    // MARK: - 查询

    static func stageQueries() {
        print("\n[4] 查询（详情页与调度任务用的那些）")
        // 覆盖天数（详情页用它决定整张卡显不显示）
        eq(LimitUpPoolStore.days(), ["2026-09-22", "2026-09-21"], "days 降序")
        eq(LimitUpPoolStore.counts()["2026-09-22"], 3, "counts 报 3")
        eq(LimitUpPoolStore.counts()["2026-09-21"], 1, "counts 报 1")

        // hasDay（回看补漏据此跳过已有日子）
        check(LimitUpPoolStore.hasDay("2026-09-22"), "hasDay 命中")
        check(!LimitUpPoolStore.hasDay("2026-09-18"), "未入库的日子 → false（补漏会去抓它）")
        check(!LimitUpPoolStore.hasDay(""), "空日期 → false（不发查询）")

        // latestRecord：同一只票跨两天时取**最近**那天
        _ = try? LimitUpPoolStore.saveDay(date: "2026-09-18",
                                          records: [rec("2026-09-18", "000504", boards: 3)],
                                          at: "t3")
        eq(LimitUpPoolStore.latestRecord(code: "000504")?.date, "2026-09-22",
           "latestRecord 取最近那天")
        check(LimitUpPoolStore.latestRecord(code: "000504")?.boards == 4,
              "latestRecord 的 boards 是 4（实得 \(LimitUpPoolStore.latestRecord(code: "000504")?.boards as Any)）")
        eq(LimitUpPoolStore.latestRecord(code: "000504", upTo: "2026-09-20")?.date, "2026-09-18",
           "upTo 只看该日及更早")
        check(LimitUpPoolStore.latestRecord(code: "000504", upTo: "2026-09-20")?.boards == 3,
              "upTo 那天是 3 连板")
        check(LimitUpPoolStore.latestRecord(code: "999999") == nil, "从未涨停 → nil")
        check(LimitUpPoolStore.latestRecord(code: "") == nil, "空 code → nil（不发查询）")

        // recentRecords：升序、受 limit 约束
        let recent = LimitUpPoolStore.recentRecords(code: "000504", limit: 5)
        eq(recent.map(\.date), ["2026-09-18", "2026-09-22"], "升序返回")
        eq(LimitUpPoolStore.recentRecords(code: "000504", limit: 1).count, 1, "limit 生效")
        eq(LimitUpPoolStore.recentRecords(code: "000504", limit: 0).count, 0, "limit 0 → 空")
    }

    static func stageDeleteAll() {
        print("\n[5] 清空")
        try? LimitUpPoolStore.deleteAll()
        eq(LimitUpPoolStore.days(), [], "days 空")
        eq(LimitUpPoolStore.counts(), [:], "counts 空")
        check(LimitUpPoolStore.latestRecord(code: "000504") == nil, "latestRecord 空")
        check(!LimitUpPoolStore.hasDay("2026-09-22"), "hasDay false")
    }

    // MARK: - 库工具

    static func tableColumns(_ table: String) -> [String] {
        try! SQLiteWriter.shared.write { tx in
            try tx.query("PRAGMA table_info(\(table))", [])
        }.compactMap { $0["name"] as? String }
    }

    static func tableIndexes(_ table: String) -> [String] {
        try! SQLiteWriter.shared.write { tx in
            try tx.query("PRAGMA index_list(\(table))", [])
        }.compactMap { $0["name"] as? String }
    }
}
