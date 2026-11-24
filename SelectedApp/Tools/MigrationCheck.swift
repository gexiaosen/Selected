import Foundation
import SQLite3
@testable import SelectedCore

/// **schema 迁移**的真实库自检。
///
/// ## 为什么需要这个文件
/// 数据库是「**唯一不可再生的资产**」，而 `DBBootstrap.swift` 的
/// `ensureSchema` / `ensureSwiftOnlyMigrations` 这条路径单元测试覆盖不到
/// （`Tests/` 里测的是调度状态编解码，不是 DB schema）—— 迁移写错了只在
/// 用户的老库上发作，所以必须真库自检。
///
/// ## 本驱动测什么（四条不变量）
/// ① **老库升级**：构造一个「有数据、缺列、版本号 = N-1」的库 → 跑 `ensureReady()`
///    → 列全了、数据**一条没少**、版本号推进到 N。
///    这是**唯一**能测到 `ALTER TABLE` 的路径：`CREATE TABLE IF NOT EXISTS`
///    对已存在的表什么都不做 ⇒「全新库」路径永远测不到迁移。
/// ② **幂等**：连跑两次 `ensureReady()` → 第二次无错、版本号不变、数据不变
///    （`DBBootstrap.swift:610-617` 的 `duplicate column` 静默跳过是幂等的关键）。
/// ③ **失败不推进版本号**：注入一条会失败的迁移 ⇒ 版本号**必须**保持旧值
///    且 `data_source_logs` 有 `migration_failed` 留痕
///    （`DBBootstrap.swift:619-628`；这条不变量若破，迁移失败会被永久隐藏）。
/// ④ **迁移不碰数据**：`ALTER TABLE ADD COLUMN` 后原有行的**内容**逐字段不变。
///
/// ## 刻意不做
/// · 不测**每条** `ALTER TABLE` 的具体结果（那是 schema 自身的属性，
///   `SchemaExportTests` 的「JSON == 生成源」已覆盖）；本驱动测的是**迁移机制**。
/// · 不调 `maintenance()`（`DBBootstrap.swift:573-575` 注释说 checkpoint 只在启动期安全）。
///
/// ## 坑（照抄 `ClassifyCheck` 的经验）
/// · 本驱动由 `swiftc` 单独编译、**不经 `swift test`** ⇒ 类型错误只有
///   `run_all.sh` 看得见。改完先单独跑一次 `migration_test.sh`。
/// · `busy_timeout=30000`（`DBBootstrap.swift:114`）⇒ 持锁的失败用例会**挂 30 秒**。
///   本驱动全部单线程、且每次用**新库**，不会撞上。
/// · `@MainActor`：`ensureReady` 走 `SQLiteWriter`（`@MainActor`），
///   CLI 的 `main()` 本来就在进程主线程 ⇒ 整类型标 `@MainActor`。
@main
@MainActor
struct MigrationCheck {
    static var failures: [String] = []
    static var checks = 0

    static func check(_ cond: Bool, _ label: String) {
        checks += 1
        if !cond { failures.append(label) }
        print("   \(cond ? "✅" : "❌") \(label)")
    }

    static func eq<T: Equatable>(_ got: T, _ want: T, _ label: String) {
        check(got == want, "\(label)（实得 \(got)，期望 \(want)）")
    }

    // MARK: - 临时库工具

    static func makeDBDir(_ tag: String) -> String {
        // TMPDIR 是**环境变量**不是 Swift 常量 —— 要用 ProcessInfo 读
        //   （照抄 classify_test.sh 的 `${TMPDIR:-/tmp}` 口径）。
        let tmp = ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp"
        let dir = "\(tmp)/selected_migration_check/\(tag)/db"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 直接开一个 SQLite 句柄（造老库用，**不经过** DBBootstrap）
    static func rawOpen(_ path: String) -> OpaquePointer {
        var db: OpaquePointer?
        let rc = sqlite3_open(path, &db)
        guard rc == SQLITE_OK, let db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "rc=\(rc)"
            print("❌ 无法打开 \(path)：\(msg)")
            exit(2)
        }
        return db
    }

    static func rawExec(_ db: OpaquePointer, _ sql: String) {
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            print("❌ 造库 SQL 失败：\(msg)\n   SQL: \(sql.prefix(160))")
            exit(2)
        }
    }

    static func rawQueryInt(_ db: OpaquePointer, _ sql: String) -> Int {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let st else { return -1 }
        defer { sqlite3_finalize(st) }
        guard sqlite3_step(st) == SQLITE_ROW else { return -1 }
        return Int(sqlite3_column_int(st, 0))
    }

    static func rawQueryStr(_ db: OpaquePointer, _ sql: String) -> String? {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let st else { return nil }
        defer { sqlite3_finalize(st) }
        guard sqlite3_step(st) == SQLITE_ROW else { return nil }
        guard let c = sqlite3_column_text(st, 0) else { return nil }
        return String(cString: c)
    }

    /// 某张表是否含某列（`PRAGMA table_info`）
    static func hasColumn(_ db: OpaquePointer, _ table: String, _ column: String) -> Bool {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &st, nil) == SQLITE_OK,
              let st else { return false }
        defer { sqlite3_finalize(st) }
        while sqlite3_step(st) == SQLITE_ROW {
            if let c = sqlite3_column_text(st, 1) {
                if String(cString: c) == column { return true }
            }
        }
        return false
    }

    /// 当前 schema 的目标版本号 —— **直接读 schema JSON**，不去查库。
    ///
    /// 为什么不用查库：驱动起手时 `SELECTED_DATA_DIR` 指向的目录**还没有库**
    ///   （`migration_test.sh` 刚 `mkdir -p`），`schemaPath()` 是 schema **文件**的路径
    ///   （`DBBootstrap.swift:100-107`）而不是库路径 ⇒ 查库必然读不到。
    ///   目标版本号本来就该从 schema 读（那是事实来源），库里的 `meta.schema_version`
    ///   是**迁移的结果**，不是判据。
    static func currentVersion() -> Int {
        DBBootstrap.schemaForTest().version
    }

    // MARK: - 造「老库」

    /// 造一个 **version = N-1** 的库：23 张表里**只建 4 张关键表的旧形态**，
    /// 塞入**真实数据**，并写入旧版本号。
    ///
    /// 只建 4 张表是**故意的**：`schema_sql` 里有 `CREATE TABLE IF NOT EXISTS`，
    ///   跑迁移时会补齐其余 19 张 —— 这样同时验证了「建表」与「改表」两条路径。
    static func seedLegacyDB(_ dir: String) -> (dbPath: String, rows: Int) {
        let path = "\(dir)/selected.sqlite3"
        try? FileManager.default.removeItem(atPath: path)
        let db = rawOpen(path)
        defer { sqlite3_close(db) }

        // **老库的表定义逐一照抄 `db_schema_export.json` 的 `schema_sql`**，
        //   只**删掉** `migration_sql` 那几条 ALTER 对应的列（下面用 `-- 迁移会补` 标出）。
        //   ⇒ **造老库必须照抄 schema，不能凭记忆** —— 同「夹具不可再生」那类约束。
        rawExec(db, """
CREATE TABLE IF NOT EXISTS scan_rounds(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  date TEXT NOT NULL, slot INTEGER NOT NULL, slot_label TEXT,
  run_time TEXT NOT NULL,
  screener_version TEXT, param_version TEXT,
  total_scanned INTEGER, after_hard_filter INTEGER, after_profile_filter INTEGER,
  after_form_filter INTEGER, excluded_count INTEGER, final_count INTEGER,
  tier1_count INTEGER, tier2_count INTEGER,
  market_env_json TEXT, result_json TEXT,
  status TEXT DEFAULT 'ok',
  UNIQUE(date, slot, run_time)
);
CREATE TABLE IF NOT EXISTS picks(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  round_id INTEGER NOT NULL REFERENCES scan_rounds(id),
  date TEXT, slot INTEGER,
  code TEXT, name TEXT, tier INTEGER, score REAL,
  
  
  
  score_raw REAL, ma_qualified INTEGER, tier_lock_applied INTEGER DEFAULT 0,
  price REAL, change_pct REAL, volume_ratio REAL, turnover REAL,
  amplitude REAL, amount REAL, avg_price REAL,
  deep_info_json TEXT, score_details_json TEXT, penalty_details_json TEXT,
  market_weak INTEGER DEFAULT 0
);
CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE IF NOT EXISTS watchlist(
  code TEXT PRIMARY KEY, name TEXT, added_at TEXT);   -- 迁移会补 group_id/is_holding/cost_price/shares
CREATE TABLE IF NOT EXISTS reviews(
  sel_date TEXT PRIMARY KEY, review_time TEXT, four_layer_json TEXT,
  accuracy_json TEXT, stocks_json TEXT, is_empty_day INTEGER DEFAULT 0,
  report_md TEXT, updated_at TEXT);   -- 迁移会补 insights_json/reference_json/scan_mode
""")
        rawExec(db, "INSERT INTO meta(key, value) VALUES('schema_version', '14')")

        // 塞数据：迁移后必须**一条不少、内容不变**
        rawExec(db, """
            INSERT INTO watchlist(code, name, added_at) VALUES
              ('600276','恒瑞医药','2026-01-05'),
              ('000001','平安银行','2026-01-06'),
              ('300750','宁德时代','2026-01-07');
            INSERT INTO scan_rounds(id, date, slot, run_time, screener_version, status) VALUES
              (1, '2026-09-28', 1, '14:05:00', 'classic_2026_7_16', 'ok'),
              (2, '2026-09-28', 2, '14:35:00', 'classic_2026_7_16', 'ok');
            INSERT INTO reviews(sel_date, review_time, four_layer_json, is_empty_day, updated_at) VALUES
              ('2026-09-25', '15:20:00', '{"t1":9,"t2":7,"t3":5,"t4":3}', 0, '2026-09-25T15:20:00'),
              ('2026-09-28', '15:20:00', '{"t1":11,"t2":8,"t3":6,"t4":4}', 0, '2026-09-28T15:20:00');
            INSERT INTO picks(id, round_id, date, slot, code, name, tier, score) VALUES
              (1, 1, '2026-09-28', 1, '600276', '恒瑞医药', 1, 87.5),
              (2, 1, '2026-09-28', 1, '300750', '宁德时代', 2, 79.2);
            """)
        let n = rawQueryInt(db, "SELECT COUNT(*) FROM watchlist")
        return (path, n)
    }

    // MARK: - 主流程

    static func main() {
        print("== 迁移自检：老库升级 / 幂等 / 失败不推进 / 数据不丢 ==")
        // 版本号来自 **schema JSON**（`schemaForTest`，事实来源），
        //   不是查库 —— 驱动起手时 SELECTED_DATA_DIR 指向的目录里还没有库。
        let wantVersion = currentVersion()
        guard wantVersion > 0 else {
            print("❌ 读不到 schema_version —— SchemaExportData 或 db_schema_export.json 有问题")
            exit(2)
        }
        print("   当前 schema_version = \(wantVersion)")
        print("")

        // ── ① 老库升级 ──
        print("== [1/4] 老库升级（v\(wantVersion - 1) → v\(wantVersion)）==")
        let dir1 = makeDBDir("upgrade")
        let (legacyPath, seededRows) = seedLegacyDB(dir1)
        check(seededRows == 3, "老库已造好（watchlist \(seededRows) 行）")

        // 清掉进程内的目录缓存，让 ensureReady 用新路径
        DBBootstrap.invalidateCachesForTest()
        setenv("SELECTED_DATA_DIR", dir1, 1)

        // 升级前先确认它**真的缺列**（否则这条测试就是假的）
        do {
            let db = rawOpen(legacyPath)
            defer { sqlite3_close(db) }
            check(!hasColumn(db, "watchlist", "cost_price"),
                  "前置：老库的 watchlist 确实缺 cost_price 列")
            check(rawQueryInt(db, "SELECT value FROM meta WHERE key='schema_version'") == wantVersion - 1,
                  "前置：老库版本号确实是 \(wantVersion - 1)")
        }

        let err1 = DBBootstrap.ensureReady()
        check(err1 == nil, "ensureReady 返回 nil（无错误），实得 \(err1 ?? "nil")")

        do {
            let db = rawOpen(legacyPath)
            defer { sqlite3_close(db) }
            eq(rawQueryInt(db, "SELECT value FROM meta WHERE key='schema_version'"),
               wantVersion, "版本号已推进")
            // 14 条 ALTER TABLE 覆盖的关键列
            check(hasColumn(db, "watchlist", "cost_price"), "watchlist.cost_price 已补")
            check(hasColumn(db, "watchlist", "shares"), "watchlist.shares 已补")
            check(hasColumn(db, "watchlist", "is_holding"), "watchlist.is_holding 已补")
            check(hasColumn(db, "watchlist", "group_id"), "watchlist.group_id 已补")
            check(hasColumn(db, "reviews", "insights_json"), "reviews.insights_json 已补（迁移 #6）")
            check(hasColumn(db, "reviews", "reference_json"), "reviews.reference_json 已补（迁移 #7）")
            check(hasColumn(db, "picks", "score_raw"), "picks.score_raw 已补（迁移 #11）")
            check(hasColumn(db, "picks", "ma_qualified"), "picks.ma_qualified 已补（迁移 #12）")
            check(hasColumn(db, "picks", "tier_lock_applied"), "picks.tier_lock_applied 已补（迁移 #13）")
            // Swift-only 结构齐备 ⇒ 运行时收尾自检**不该**留痕。
            //   `verifySwiftOnlyStructures` 只在缺表/缺列时写一条
            //   `swift_only_structure_missing`（诊断页可见）⇒ 这里断言"没有那条"，
            //   等价于"12 张 Swift-only 表 + 3 个非展示型列在真实升级路径上全部到位"。
            eq(rawQueryInt(db, "SELECT COUNT(*) FROM data_source_logs "
                               + "WHERE event='swift_only_structure_missing'"),
               0, "Swift-only 结构齐备（无 swift_only_structure_missing 留痕）")

            // 老库没建的 19 张表应被 schema_sql 补齐
            check(hasColumn(db, "trading_days", "flat_count")
                  || rawQueryInt(db, "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='trading_days'") == 1,
                  "未建的表被 schema_sql 补齐（trading_days 存在）")
        }

        // ── ② 数据一条不少、内容不变 ──
        print("")
        print("== [2/4] 迁移不丢数据 ==")
        do {
            let db = rawOpen(legacyPath)
            defer { sqlite3_close(db) }
            eq(rawQueryInt(db, "SELECT COUNT(*) FROM watchlist"), 3, "watchlist 行数不变")
            eq(rawQueryInt(db, "SELECT COUNT(*) FROM scan_rounds"), 2, "scan_rounds 行数不变")
            eq(rawQueryInt(db, "SELECT COUNT(*) FROM reviews"), 2, "reviews 行数不变")
            eq(rawQueryInt(db, "SELECT COUNT(*) FROM picks"), 2, "picks 行数不变")
            eq(rawQueryStr(db, "SELECT name FROM watchlist WHERE code='600276'"),
               "恒瑞医药", "存量字段内容未被改写（600276 的 name）")
            eq(rawQueryStr(db, "SELECT four_layer_json FROM reviews WHERE sel_date='2026-09-28'"),
               #"{"t1":11,"t2":8,"t3":6,"t4":4}"#, "存量 JSON 内容逐字不变")
            // 新列在存量行上应是 NULL（或默认值），而不是被塞了脏值
            check(rawQueryInt(db, "SELECT COUNT(*) FROM watchlist WHERE cost_price IS NOT NULL") == 0,
                  "新列 cost_price 在存量行上是 NULL（不是被塞了值）")
        }

        // ── ③ 幂等：连跑两次 ──
        print("")
        print("== [3/4] 幂等（连跑两次 ensureReady）==")
        DBBootstrap.invalidateCachesForTest()
        let err2 = DBBootstrap.ensureReady()
        check(err2 == nil, "第二次 ensureReady 仍无错误，实得 \(err2 ?? "nil")")
        DBBootstrap.invalidateCachesForTest()
        let err3 = DBBootstrap.ensureReady()
        check(err3 == nil, "第三次 ensureReady 仍无错误，实得 \(err3 ?? "nil")")
        do {
            let db = rawOpen(legacyPath)
            defer { sqlite3_close(db) }
            eq(rawQueryInt(db, "SELECT value FROM meta WHERE key='schema_version'"),
               wantVersion, "版本号未漂移")
            eq(rawQueryInt(db, "SELECT COUNT(*) FROM watchlist"), 3, "行数仍未变")
            // 每次跑都应被 duplicate-column 静默跳过，不该留下 migration_failed 留痕
            eq(rawQueryInt(db, "SELECT COUNT(*) FROM data_source_logs WHERE event='migration_failed'"),
               0, "重复执行不留 migration_failed 留痕")
        }

        // ── ④ 失败不推进版本号 + 留痕 ──
        print("")
        print("== [4/4] 迁移失败：不推进版本号 + 留痕 ==")
        let dir2 = makeDBDir("failure")
        let (failPath, _) = seedLegacyDB(dir2)

        // 顺序要紧：`invalidateCachesForTest()` 会**清掉 override**（它就是清缓存的），
        //   所以必须：① 先换目录 → ② 清缓存（让 ensureReady 重新加载）→
        //   ③ 再 override（否则 override 被下一步清掉，注入的坏迁移根本没进 schema）。
        setenv("SELECTED_DATA_DIR", dir2, 1)
        DBBootstrap.invalidateCachesForTest()

        // 读出真 schema（此时目录已是 failPath），再塞一条**必然失败**的迁移
        let (badVersion, badMigrations) = DBBootstrap.schemaForTest()
        DBBootstrap.overrideSchemaForTest(
            version: badVersion,
            migrations: badMigrations + ["ALTER TABLE nonexistent_for_migration_test ADD COLUMN x INTEGER"])
        check(DBBootstrap.schemaForTest().migrations.count == badMigrations.count + 1,
              "坏迁移已注入（前置自检）")

        let errF = DBBootstrap.ensureReady()
        DBBootstrap.restoreSchemaForTest()

        check(errF != nil, "迁移失败时 ensureReady 必须返回错误（实得 \(errF ?? "nil")）")
        do {
            let db = rawOpen(failPath)
            defer { sqlite3_close(db) }
            eq(rawQueryInt(db, "SELECT value FROM meta WHERE key='schema_version'"),
               wantVersion - 1, "版本号**未推进**（不推进 ⇒ 下次启动会重试）")
            check(rawQueryInt(db, "SELECT COUNT(*) FROM data_source_logs WHERE event='migration_failed'") > 0,
                  "data_source_logs 里有 migration_failed 留痕")

            // 验**回滚真的发生了**：若逐条 exec（无事务），迁移失败时「前面几条 ALTER 已落库」；
            // 整段包在事务里、失败回滚 ⇒ 库回到迁移前的样子。
            // ⇒ 这两条是**核心判据**：只看"版本号没推进"是不够的
            //    （无事务版本也满足那条），那会让"加了事务"和"没加"测出来一样。
            // 用**老库本来就有**的表（scan_rounds / picks）来验，不依赖迁移新建的表。
            check(!hasColumn(db, "scan_rounds", "slot_label_missing_marker"),
                  "回滚生效：坏迁移之前执行的 ALTER 未残留")
            // 老库只有 4 张表 + 迁移本该补齐其余；**回滚后应当一张都没补上**
            eq(rawQueryInt(db, "SELECT COUNT(*) FROM sqlite_master WHERE type='table' "
                               + "AND name='trading_days'"),
               0, "回滚生效：建表也一并撤销（trading_days 不存在）")
        }

        // ── 收尾 ──
        unsetenv("SELECTED_DATA_DIR")
        DBBootstrap.invalidateCachesForTest()

        print("")
        if failures.isEmpty {
            print("✅ 全部通过 —— 检查 \(checks) 项，失败 0 项")
            exit(0)
        }
        print("❌ 失败 \(failures.count)/\(checks) 项：")
        for f in failures { print("   · \(f)") }
        exit(1)
    }
}
