import Foundation
import SQLite3
@testable import SelectedCore

/// **按需**审计驱动（`alert_realdb_check.sh`）：把自选提醒放到**真实形状的库**上验一遍。
///
/// ## 为什么它**不进** `run_all.sh`
/// 它需要**用户本机真实库**（`~/Library/Application Support/Selected/selected.sqlite3`）——
/// 非 hermetic：新机器上没有那个库、CI 上也没有。同 `compare_live_check.sh` 一类，
/// 属于**按需审计**（跑法见脚本头部）。
///
/// ## 它覆盖 `AlertCheck` 覆盖不到的两件事
///   ① `AlertCheck` 的库是 `DBBootstrap.ensureReady` **现造的空库** —— 空库里
///      "建表"与"老库迁移"走的是同一条路，**测不出**"真实的 30 MB 老库能不能拿到这两张表"。
///      本审计**在副本上主动 `DROP` 掉提醒两张表**来构造"迁移前"状态（`dropAlertTables`）——
///      依赖"生产库此刻恰好还没有这两张表"在功能上线后必然失效（App 跑过一次表就存在了）。
///   ② 真实库里的提醒规则读写往返（REAL 精度、代码列、多规则）只有真库能证明。
///
/// ## 安全边界
/// · 全程只碰 `SELECTED_DATA_DIR` 指向的**库副本**（脚本负责 `cp` 主文件 + `-wal` + `-shm`）；
///   脚本末尾会回读原库 mtime 与 `sqlite_master` 作证。
/// · **不打网络**：全部是本地库读写。
/// · 第 3 阶段会在副本上写提醒再清干净 —— 跑完副本回到"刚迁移完"的状态。
@main
struct AlertRealDBCheck {
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

    static func must<T>(_ label: String, _ body: () throws -> T) -> T? {
        do { return try body() }
        catch { check(false, "\(label) 抛错：\(error)"); return nil }
    }

    static func main() {
        print("== 自选提醒 · 真实库审计 ==")
        let dir = DataDirectory.resolve()
        print("   数据目录：\(dir)")
        guard FileManager.default.fileExists(atPath: dir + "/selected.sqlite3") else {
            print("❌ 副本不存在，先跑脚本拷贝"); exit(2)
        }

        stagePreexisting()
        stageMigrateOnRealDB()
        stageWriteOnRealDB()

        print("\n—— 检查 \(checks) 项，失败 \(failures.count) 项")
        if !failures.isEmpty {
            for f in failures { print("   ❌ \(f)") }
            exit(1)
        }
        exit(0)
    }

    // MARK: - [1] 迁移前：把副本**构造成**"老库"

    static func stagePreexisting() {
        print("\n[1] 迁移前（在副本上构造「老库」，不依赖生产库处于哪个阶段）")
        // 依赖"外部状态恰好是某样"的断言 = 一条**会过期的**断言
        //   （App 只要跑过一次，表就存在了）。
        //   ⇒ **在副本上主动删掉**两张表，自己构造"迁移前"状态：
        //     不依赖生产库处于哪个阶段，永远有效；而且它本来就是副本，删了无副作用。
        let alreadyMigrated = !tableColumns("watch_alerts").isEmpty
        print("   （记录：生产库此刻\(alreadyMigrated ? "已" : "尚未")有 watch_alerts；"
              + "下面的断言不依赖它）")
        dropAlertTables()
        check(tableColumns("watch_alerts").isEmpty, "副本已回到「迁移前」：无 watch_alerts")
        check(tableColumns("watch_alert_settings").isEmpty, "副本已回到「迁移前」：无 watch_alert_settings")
        check(!tableColumns("watch_judgments").isEmpty,
              "但有 watch_judgments（真实数据）")
        let rows = must("数判定行") {
            try SQLiteWriter.shared.write { tx in
                try tx.query("SELECT COUNT(*) AS n, COUNT(DISTINCT date) AS d"
                             + " FROM watch_judgments", [])
            }
        }?.first
        eq(rows?["n"] as? Int, 28, "28 行判定")
        eq(rows?["d"] as? Int, 6, "跨 6 天")
    }

    /// 在**副本**上把提醒两张表删掉，构造"迁移前"状态。
    /// 只对本审计的副本生效 —— 原库在开跑前就被拷走了，脚本前后还会校验原库的
    ///   `mtime` 与 `sqlite_master` 指纹（见 `alert_realdb_check.sh`）。
    static func dropAlertTables() {
        for t in ["watch_alerts", "watch_alert_settings"] {
            must("DROP TABLE IF EXISTS \(t)") {
                try SQLiteWriter.shared.write { tx in
                    try tx.execute("DROP TABLE IF EXISTS \(t)", [])
                }
            }
        }
    }

    // MARK: - [2] 在真实库上跑迁移

    static func stageMigrateOnRealDB() {
        print("\n[2] 在真实库上跑迁移（模拟 App 启动）")
        let err = DBBootstrap.ensureReady()
        check(err == nil, "ensureReady 成功（\(err ?? "ok")）")
        DBBootstrap.ensureSwiftOnlySchemaOnDisk()

        eq(tableColumns("watch_alerts"),
           ["code", "kind", "threshold", "repeat_mode",
            "last_fired_at", "last_fired_day", "updated_at"],
           "⚠ 真实库上补出了 watch_alerts，列序与 DDL 逐字一致")
        eq(tableColumns("watch_alert_settings"), ["code", "time_window", "updated_at"],
           "⚠ 真实库上补出了 watch_alert_settings")
        eq(AlertStore.ruleCount(), 0, "新建的表是空的（没污染任何既有数据）")
        eq(AlertStore.settingsCount(), 0, "设置表也是空的")

        // 迁移**不该**动既有数据（`ensureReady` 顺带跑 maintenance / 补种，
        // 但那是既有行为；这里只确认判定行没被碰）
        let n = must("复查判定行数") {
            try SQLiteWriter.shared.write { tx in
                try tx.query("SELECT COUNT(*) AS n FROM watch_judgments", [])
            }
        }?.first?["n"] as? Int
        eq(n, 28, "迁移后判定行数不变（28）")
    }

    // MARK: - [3] 在真实库上写读提醒

    static func stageWriteOnRealDB() {
        print("\n[3] 在真实库上写读提醒（写完清干净）")
        let code = "600276"
        let n = must("save") {
            try AlertStore.save(code: code,
                                drafts: [AlertDraft(kind: .upPrice, threshold: 46.84,
                                                    repeatMode: .daily),
                                         AlertDraft(kind: .downPrice, threshold: 45.0,
                                                    repeatMode: .once),
                                         // 涨跌额族：在**真实库**上验它也能
                                         // 按 rawValue 原样往返（新 kind 零 schema 变更，见设计 §13.3）
                                         AlertDraft(kind: .upAmount, threshold: 1.00,
                                                    repeatMode: .daily)],
                                window: .anytime, at: "2026-09-23 09:20:00")
        }
        eq(n ?? -1, 3, "写入 3 条")
        eq(AlertStore.configuredCodes(), ["600276"], "configuredCodes 报它")
        let back = AlertStore.rules(code: code)
        eq(back.map { $0.kind.rawValue }, ["down_price", "up_amount", "up_price"],
           "按 kind 文本升序读回（down_price < up_amount < up_price）")
        eq(back.map(\.threshold), [45.0, 1.00, 46.84], "阈值逐条对位")
        eq(back.first { $0.kind == .upPrice }?.threshold, 46.84,
           "⚠ 用真实锚点值 46.84 当阈值 → 精确往返")
        eq(back.first { $0.kind == .upAmount }?.threshold, 1.00,
           "涨跌额阈值 1.00 在真实库上精确往返")

        // 触发 → 落库（在真实库上验一次写路径）
        // `changeAmount` 显式给
        let subj = AlertSubject(code: code, name: "恒瑞医药", price: 47.00,
                                changeAmount: 1.05, changePercent: 1.0,
                                rules: back, window: AlertStore.window(code: code))
        let f = AlertEval.evaluate([subj], at: AlertClock(day: "2026-09-23", minuteOfDay: 600,
                                                          isTradingDay: true,
                                                          stamp: "2026-09-23 10:00:00"))
        eq(f.count, 2, "47.00 ≥ 46.84 且涨 1.05 元 ≥ 1.00 → 触发 2 条")
        eq(Set(f.map(\.kind)), Set([AlertKind.upPrice, AlertKind.upAmount]),
           "两条 kind 不同（到价 + 涨额各一条）")
        eq(must("markFired") { try AlertStore.markFired(f) } ?? -1, 2, "落库 2 行")
        eq(AlertStore.rules(code: code).first { $0.kind == .upPrice }?.lastFiredDay,
           "2026-09-23", "真实库上 last_fired_day 落库")

        // 清干净（副本也要留成"和迁移后一样"的状态）
        eq(must("removeAll") { try AlertStore.removeAll(code: code) } ?? -1, 3, "清掉 3 条")
        eq(AlertStore.ruleCount(), 0, "规则表回到空")
        eq(AlertStore.settingsCount(), 0, "设置表回到空")
    }

    // MARK: - 工具

    static func tableColumns(_ table: String) -> [String] {
        let rows = must("PRAGMA table_info(\(table))") {
            try SQLiteWriter.shared.write { tx in
                try tx.query("PRAGMA table_info(\(table))", [])
            }
        }
        return (rows ?? []).compactMap { $0["name"] as? String }
    }
}
