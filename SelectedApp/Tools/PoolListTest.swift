import Foundation
import SQLite3
@testable import SelectedCore

/// 列表池缓存自检（Swift 侧）
///
/// 覆盖两个"只服务自选页搜索"的池子（`--pool fund|hk`）：
///   fund  场内基金（funds 表，4 字段）
///   hk    港股（hk_list 表，2 字段）
///
/// 为什么是自检：两个池都只服务自选页搜索，引擎侧没有消费方，
/// 故这里锁**行为契约**（全部离线，
/// 主源不可用走 `SELECTED_STOCK_LIST_HTTP=off` 注入）：
///   schema     随包 schema_sql 能建出该表（列名与顺序）
///   roundtrip  整表替换往返（退市/更名不残留 / 顺序=代码升序 / 空表判定）
///   ttl-hit    当日缓存命中：直接返回缓存，且不产生任何池事件（证明确实走了缓存分支）
///   ttl-miss   过期缓存 + 主源不可用 → 回退过期缓存并留痕 fallback_cache
///   empty      空表 + 主源不可用 → 返回空列表并留痕 fatal（不崩）
///   fresh      TTL 边界（6 天新鲜 / 7 天过期 / nil 与脏日期视为过期）
///   no-table   老库未迁移（缺表）→ 读回空、整表替换抛错（不静默成功）
///
/// 与 `pool_list_test.sh` 同构：.sh 负责建目录与注入环境，本程序只断言并退出码。
@main
struct PoolListTest {
    private static var failures = 0

    /// 被检池子的差异点（其余场景逻辑两个池完全一致）
    private struct Pool {
        let label: String
        let table: String
        let columns: [String]      // PRAGMA table_info 期望（顺序敏感）
        let fields: [String]       // 断言规范化用的字段（与读写回读可比）
        let eventSource: String    // data_source_logs.source（fund_list / hk_list）
        let load: () -> (String?, [[String: Any]])
        let replace: (String, [[String: Any]]) throws -> Void
        let isEmpty: () -> Bool
        let fetch: (Bool) -> [[String: Any]]
        let isFresh: (String?) -> Bool
        let sampleA: [[String: Any]]
        let sampleB: [[String: Any]]
    }

    private static let fundSampleA: [[String: Any]] = [
        ["code": "510300", "name": "沪深300ETF", "market": 1, "kind": "etf"],
        ["code": "159915", "name": "创业板ETF", "market": 0, "kind": "etf"],
        ["code": "501001", "name": "财通精选混合LOF", "market": 1, "kind": "lof"],
    ]
    private static let fundSampleB: [[String: Any]] = [
        ["code": "508000", "name": "华安张江产业园REIT", "market": 1, "kind": "close"],
        ["code": "510300", "name": "沪深300ETF", "market": 1, "kind": "etf"],
    ]
    private static let hkSampleA: [[String: Any]] = [
        ["code": "00001", "name": "长和"],
        ["code": "00700", "name": "腾讯控股"],
        ["code": "01276", "name": "恒瑞医药"],
    ]
    private static let hkSampleB: [[String: Any]] = [
        ["code": "00700", "name": "腾讯控股"],
        ["code": "09988", "name": "阿里巴巴-W"],
    ]

    private static let pools: [String: Pool] = [
        "fund": Pool(
            label: "场内基金", table: "funds",
            columns: ["code", "name", "market", "kind", "cache_date"],
            fields: ["code", "name", "market", "kind"],
            eventSource: "fund_list",
            load: { FundCache.shared.load() },
            replace: { try FundCache.shared.replace(date: $0, list: $1) },
            isEmpty: { FundCache.shared.isEmpty() },
            fetch: { DataSources.fetchFundList(refresh: $0) },
            isFresh: { DataSources.isFundCacheFresh($0) },
            sampleA: fundSampleA, sampleB: fundSampleB),
        "hk": Pool(
            label: "港股", table: "hk_list",
            columns: ["code", "name", "cache_date"],
            fields: ["code", "name"],
            eventSource: "hk_list",
            load: { HkCache.shared.load() },
            replace: { try HkCache.shared.replace(date: $0, list: $1) },
            isEmpty: { HkCache.shared.isEmpty() },
            fetch: { DataSources.fetchHkList(refresh: $0) },
            isFresh: { DataSources.isHkCacheFresh($0) },
            sampleA: hkSampleA, sampleB: hkSampleB),
    ]

    static func main() {
        let args = CommandLine.arguments
        func value(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            return args[i + 1]
        }

        guard let scenario = value("--scenario"), let poolKey = value("--pool"),
              let pool = pools[poolKey] else {
            print("用法：PoolListTest --pool <fund|hk> --scenario <schema|roundtrip|ttl-hit|"
                  + "ttl-miss|empty|fresh|no-table> --schema <db_schema_export.json>")
            exit(2)
        }
        let dataDir = ProcessInfo.processInfo.environment["SELECTED_DATA_DIR"] ?? ""
        guard !dataDir.isEmpty else {
            print("❌ 需要 SELECTED_DATA_DIR（自检库目录）")
            exit(2)
        }

        print("== \(poolKey).\(scenario) ==")
        switch scenario {
        case "schema":
            guard setupDB(dir: dataDir, schemaPath: value("--schema"), withSchema: true) else { exit(2) }
            let cols = tableColumns(pool.table)
            check(cols == pool.columns,
                  "\(pool.table) 表列与导出 schema 一致（实际 \(cols)）")
        case "roundtrip":
            guard setupDB(dir: dataDir, schemaPath: value("--schema"), withSchema: true) else { exit(2) }
            roundtrip(pool)
        case "ttl-hit":
            guard setupDB(dir: dataDir, schemaPath: value("--schema"), withSchema: true) else { exit(2) }
            guard writeCache(pool, date: dayFormatter.string(from: Date()), list: pool.sampleA) else { exit(2) }
            let returned = pool.fetch(false)
            check(canon(pool, returned) == canon(pool, pool.sampleA), "当日缓存命中：直接返回缓存（未触网）")
            let events = events(pool)
            check(events.isEmpty, "缓存命中不产生 \(pool.eventSource) 事件（实际 \(events)）")
        case "ttl-miss":
            guard setupDB(dir: dataDir, schemaPath: value("--schema"), withSchema: true) else { exit(2) }
            guard writeCache(pool, date: daysAgo(30), list: pool.sampleA) else { exit(2) }
            let returned = pool.fetch(false)
            check(canon(pool, returned) == canon(pool, pool.sampleA), "过期缓存 + 主源不可用 → 回退过期缓存")
            check(events(pool).contains("fallback_cache"), "回退留痕 fallback_cache（实际 \(events(pool))）")
        case "empty":
            guard setupDB(dir: dataDir, schemaPath: value("--schema"), withSchema: true) else { exit(2) }
            let returned = pool.fetch(false)
            check(returned.isEmpty, "空表 + 主源不可用 → 返回空列表（不崩）")
            check(events(pool).contains("fatal"), "留痕 fatal（实际 \(events(pool))）")
        case "fresh":
            check(pool.isFresh(dayFormatter.string(from: Date())), "今日 → 新鲜")
            check(pool.isFresh(daysAgo(6)), "6 天 → 新鲜（TTL 7 天）")
            check(!pool.isFresh(daysAgo(7)), "7 天 → 过期（边界）")
            check(!pool.isFresh(nil), "nil → 过期")
            check(!pool.isFresh("2026-13-99"), "脏日期 → 过期（触发刷新）")
        case "no-table":
            guard setupDB(dir: dataDir, schemaPath: value("--schema"), withSchema: false) else { exit(2) }
            let (date, list) = pool.load()
            check(date == nil && list.isEmpty, "老库缺 \(pool.table) 表 → 读回空（不崩）")
            check(pool.isEmpty(), "缺表判定为空")
            var threw = false
            do {
                try pool.replace(dayFormatter.string(from: Date()), pool.sampleA)
            } catch {
                threw = true
            }
            check(threw, "缺表整表替换必须抛错（不静默成功）")
        default:
            print("❌ 未知场景：\(scenario)")
            exit(2)
        }

        print(failures == 0 ? "✅ \(poolKey).\(scenario)：全部断言通过"
                            : "❌ \(poolKey).\(scenario)：\(failures) 项断言失败")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - 场景实现

    /// 整表替换往返：写 A → 读回 → 写 B（A 中不在 B 的代码必须消失）→ 读回 → 写空 → 空表判定
    private static func roundtrip(_ pool: Pool) {
        let today = dayFormatter.string(from: Date())
        guard writeCache(pool, date: today, list: pool.sampleA) else { return }
        var (date, loaded) = pool.load()
        check(date == today, "缓存日期回读一致（实际 \(date ?? "nil")）")
        check(canon(pool, loaded) == canon(pool, pool.sampleA), "整表写入后读回一致")
        check(loaded.map { $0["code"] as? String ?? "" }
                == (pool.sampleA.map { $0["code"] as? String ?? "" }).sorted(),
              "读回顺序=代码升序（实际 \(loaded.map { $0["code"] as? String ?? "" })）")
        check(!pool.isEmpty(), "非空表判定为 false")

        guard writeCache(pool, date: today, list: pool.sampleB) else { return }
        (date, loaded) = pool.load()
        check(canon(pool, loaded) == canon(pool, pool.sampleB), "整表替换后读回 = B")
        let gone = pool.sampleA.map { $0["code"] as? String ?? "" }
            .filter { c in !pool.sampleB.contains { ($0["code"] as? String ?? "") == c } }
        check(!loaded.contains { gone.contains($0["code"] as? String ?? "") },
              "整表替换：B 中不存在的代码不得残留（退市/更名）")

        guard writeCache(pool, date: today, list: []) else { return }
        let (_, afterEmpty) = pool.load()
        check(afterEmpty.isEmpty, "写入空列表后读回为空")
        check(pool.isEmpty(), "空表判定为 true")
    }

    private static func writeCache(_ pool: Pool, date: String, list: [[String: Any]]) -> Bool {
        do {
            try pool.replace(date, list)
            return true
        } catch {
            check(false, "写缓存失败：\(error)")
            return false
        }
    }

    // MARK: - 工具

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? TimeZone.current
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static func daysAgo(_ n: Int) -> String {
        let d = Calendar(identifier: .gregorian).date(byAdding: .day, value: -n, to: Date()) ?? Date()
        return dayFormatter.string(from: d)
    }

    private static func check(_ cond: Bool, _ msg: String) {
        print(cond ? "   ✅ \(msg)" : "   ❌ \(msg)")
        if !cond { failures += 1 }
    }

    /// 断言用规范化：只取该池的字段、按代码升序（读回与写入口径可比）
    private static func canon(_ pool: Pool, _ list: [[String: Any]]) -> [String] {
        list.map { x in
            pool.fields.map { f in
                if f == "market" { return String((x[f] as? Int) ?? Int((x[f] as? NSNumber)?.intValue ?? 0)) }
                return x[f] as? String ?? ""
            }.joined(separator: "|")
        }.sorted()
    }

    /// 建库：withSchema=true 执行随包导出 schema_sql；false 模拟老库（只有 meta，无池表）
    @discardableResult
    private static func setupDB(dir: String, schemaPath: String?, withSchema: Bool) -> Bool {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open_v2(dir + "/selected.sqlite3", &handle,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let db = handle else {
            print("❌ 建库失败：\(dir)")
            return false
        }
        defer { sqlite3_close(db) }

        let sql: String
        if withSchema {
            guard let path = schemaPath,
                  let data = FileManager.default.contents(atPath: path),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let exported = obj["schema_sql"] as? String else {
                print("❌ 无法读取 schema 导出：\(schemaPath ?? "(缺 --schema)")")
                return false
            }
            sql = exported
        } else {
            sql = "CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT); "
                + "INSERT OR REPLACE INTO meta(key, value) VALUES('schema_version', '12');"
        }
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            print("❌ 执行 schema 失败：\(err.map { String(cString: $0) } ?? "未知")")
            if let err = err { sqlite3_free(err) }
            return false
        }
        return true
    }

    private static func openReadOnly() -> OpaquePointer? {
        let dir = ProcessInfo.processInfo.environment["SELECTED_DATA_DIR"] ?? ""
        var handle: OpaquePointer?
        guard sqlite3_open_v2(dir + "/selected.sqlite3", &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return nil
        }
        return handle
    }

    /// `PRAGMA table_info(<table>)` 的列名（表不存在 → []）
    private static func tableColumns(_ table: String) -> [String] {
        guard let db = openReadOnly() else { return [] }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "")
        }
        return out
    }

    /// 该池事件（按写入顺序）
    private static func events(_ pool: Pool) -> [String] {
        guard let db = openReadOnly() else { return [] }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db,
                "SELECT event FROM data_source_logs WHERE source='\(pool.eventSource)' ORDER BY id",
                -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "")
        }
        return out
    }
}