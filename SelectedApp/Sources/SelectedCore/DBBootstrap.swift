import Foundation
import SQLite3

private let SQLITE_TRANSIENT_BS = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// 建库 / schema 迁移。
///
/// 职责：
///   · 版本水位：库内 `schema_version >= SCHEMA_VERSION` → 直接返回
///   · 幂等建表：`CREATE TABLE IF NOT EXISTS`（多语句整体执行）
///   · 增量迁移：逐条执行，`duplicate column` 静默跳过（正常的重复执行）
///   · 失败留痕：其余失败写 `data_source_logs(source='db', event='migration_failed')`
///     且**不推进版本号**（下次启动重试）
///
/// 结构定义**不在 Swift 里手抄**：读随包 JSON（`engine/params/db_schema_export.json`）执行；
/// 该文件由构建期导出脚本生成，手改会不一致。
public enum DBBootstrap {

    // MARK: - 导出资源定位

    public struct Schema {
        public let version: Int
        public let schemaSQL: String
        public let migrations: [String]
    }

    private static let lock = NSLock()
    /// `nonisolated(unsafe)`：Swift 6 严格并发禁止非隔离的可变全局状态；这三个都**自带 `lock` 保护**，
    /// 故显式声明豁免（与 DataSources.quoteStat 同一处理方式）。
    private nonisolated(unsafe) static var cachedSchema: Schema?
    private nonisolated(unsafe) static var loadTried = false
    private nonisolated(unsafe) static var _lastError: String?

    /// 最近一次初始化错误（nil = 正常）。App 启动时调用，失败由 Store 展示给用户。
    public static var lastError: String? {
        lock.lock(); defer { lock.unlock() }
        return _lastError
    }

    // MARK: - 测试钩子
    //
    // ⚠ 为什么需要：迁移路径（`ensureSchema` / `ensureSwiftOnlyMigrations`）要能反复测
    //   「老库升级 / 幂等 / 失败不推进」（数据库是「唯一不可再生的资产」），需要三样东西：
    //   ① 清掉进程内的 schema 缓存（否则换个 `SELECTED_DATA_DIR` 也读旧 schema）；
    //   ② 读出真 schema（为了在它基础上**注入一条会失败的迁移**）；
    //   ③ 注入后能还原（否则污染同进程后续测试）。
    //
    // ⚠ **这三个是 `internal` 而非 `public`**：`MigrationCheck.swift` 用
    //   `@testable import SelectedCore` + `swiftc -enable-testing` 编译（见
    //   `Tools/core_lib.sh` 的注释），`internal` + `@testable` 即可访问，
    //   **不需要**放宽到 public（放宽了就成了 App 的公开 API 面）。

    /// 清掉进程内的 schema / 目录缓存（换 `SELECTED_DATA_DIR` 后必须调）。
    public static func invalidateCachesForTest() {
        lock.lock()
        cachedSchema = nil
        loadTried = false
        lock.unlock()
    }

    /// 读出当前 schema 的 (version, migrations) —— 供测试在其基础上注入坏迁移。
    public static func schemaForTest() -> (version: Int, migrations: [String]) {
        // ⚠ 不要在持锁时调 `loadSchema()`（它自己会取锁 ⇒ NSLock 不可重入 ⇒ 死锁）。
        //   故分两段：先在锁内看缓存，没有就**解锁后再加载**，然后重新取锁读。
        lock.lock()
        let cached = cachedSchema
        lock.unlock()
        if let s = cached { return (s.version, s.migrations) }

        let loaded = loadSchema()      // 内部自己取锁
        lock.lock()
        let s = cachedSchema ?? loaded  // loadSchema 内部已写缓存，这里兜底
        lock.unlock()
        guard let s else { return (-1, []) }
        return (s.version, s.migrations)
    }

    /// 临时替换 schema（只为注入坏迁移）。必须配 `restoreSchemaForTest()`。
    public static func overrideSchemaForTest(version: Int, migrations: [String]) {
        lock.lock()
        cachedSchema = Schema(version: version, schemaSQL: cachedSchema?.schemaSQL ?? "",
                              migrations: migrations)
        loadTried = true
        lock.unlock()
    }

    /// 还原被 `overrideSchemaForTest` 替换掉的 schema。
    public static func restoreSchemaForTest() {
        invalidateCachesForTest()
    }

    /// 导出文件路径（`SELECTED_DB_SCHEMA` 可覆盖，供测试脚本用）
    public static func schemaPath() -> String? {
        if let env = ProcessInfo.processInfo.environment["SELECTED_DB_SCHEMA"],
           FileManager.default.fileExists(atPath: env) {
            return env
        }
        return ParamSchema.resourceCandidates("engine/params/db_schema_export.json")
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    private static func loadSchema() -> Schema? {
        lock.lock(); defer { lock.unlock() }
        if loadTried { return cachedSchema }
        loadTried = true
        guard let path = schemaPath(),
              let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = obj["schema_version"] as? Int,
              let sql = obj["schema_sql"] as? String,
              let migrations = obj["migration_sql"] as? [String] else {
            return nil
        }
        let s = Schema(version: version, schemaSQL: sql, migrations: migrations)
        cachedSchema = s
        return s
    }

    // MARK: - 数据目录（唯一实现见 DataDirectory）
    //
    // ⚠ 解析结果必须与各 Store 完全一致：否则会出现"建库在一个目录、读写去另一个目录"
    //   的隐形错位（首装表现为页面全空且无报错）。

    public static func dataDirPath() -> String { DataDirectory.resolve() }

    // MARK: - 入口

    /// 确保库存在且 schema 为最新（幂等，可重复调用）。
    /// 返回错误串（nil = 成功）；错误同时缓存在 `lastError` 供 UI 展示。
    @discardableResult
    public static func ensureReady() -> String? {
        let schema: Schema
        guard let s = loadSchema() else {
            let msg = "DB schema 元数据不可用（缺少随包 engine/params/db_schema_export.json）"
            lock.lock(); _lastError = msg; lock.unlock()
            return msg
        }
        schema = s

        let dir = dataDirPath()
        let path = dir + "/selected.sqlite3"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard FileManager.default.fileExists(atPath: dir) else {
            let msg = "数据目录不可写：\(dir)"
            lock.lock(); _lastError = msg; lock.unlock()
            return msg
        }

        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
                == SQLITE_OK, let db = handle else {
            let msg = "数据库打开/创建失败：\(path)"
            if let h = handle { sqlite3_close(h) }
            lock.lock(); _lastError = msg; lock.unlock()
            return msg
        }
        defer { sqlite3_close(db) }

        // 撞锁等待而非立刻失败；WAL 读写不互斥
        sqlite3_busy_timeout(db, 30_000)
        // ⚠ journal_mode 的返回值必须读（2026-10-16 审查 B2）：网络盘/SMB 主目录上
        //   `PRAGMA journal_mode=WAL` 会**被拒**（SQLite 回落到 delete 但仍返回成功语句结果）。
        //   而 `SQLiteReader` 的整条读路径是按「WAL + -shm 可恢复」设计的（READWRITE 打开
        //   就是为了重建 shm）—— 落到 delete 模式后读写会互斥，表现为随机空页/随机 BUSY，
        //   而且没有任何地方记录"这台机器的库不是 WAL"。
        if exec(db, "PRAGMA journal_mode=WAL") == nil {
            let mode = queryString(db, "PRAGMA journal_mode")
            if mode != "wal" {
                NSLog("[ERROR] 数据库未能进入 WAL 模式（当前 %@）—— 读写将互斥，路径=%@",
                      mode ?? "unknown", path)
            }
        } else {
            NSLog("[ERROR] PRAGMA journal_mode=WAL 执行失败 —— 读写将互斥")
        }


        let err = ensureSchema(db, schema)
        // ⚠ Swift-only 迁移**独立于版本水位与迁移结果**执行：它不属于 `schema.migrations`
        //   （那批受版本号闸门控制），且迁移失败时也必须把它补上 —— 否则两侧表结构
        //   在 `migration-fail` 场景下会不一致。
        //   建表本身失败时这里会 prepare 失败，只 NSLog，不改变错误返回（迁移失败才是主因）。
        // ⚠ 但**事务残留时必须跳过**（2026-10-16 审查 B2）：若上面的回滚没成功、
        //   事务还挂在该连接上，这里建的所有表都会被结尾的 `sqlite3_close` 一起回滚 ——
        //   于是"补建结构"看起来执行了、实际一条都没落地，且没有任何错误。
        if sqlite3_get_autocommit(db) == 0 {
            NSLog("[ERROR] ensureSchema 后事务仍残留 —— 跳过 Swift-only 迁移与 maintenance（下次启动重试）")
        } else {
            ensureSwiftOnlyMigrations(db)
            if err == nil { maintenance(db) }
        }

        // ⚠ `maintenance(db)` **只管主库**，而 `history.sqlite3` 是**独立库**（`HistoryBarStore`），
        //   从不被它探测 —— 数据早被清空但文件不会缩回去，大量空洞一直躺在磁盘上。
        //   ⇒ 这里补一次空洞回收（阈值 50%，正常库不会触发）。
        //   ⚠ 放在 `maintenance` 之后：先让主库收 WAL，再动 history（两者独立，互不阻塞）。
        HistoryBarStore.reclaimSpaceIfHollow()
        lock.lock(); _lastError = err; lock.unlock()
        return err
    }

    // MARK: - Swift-only 迁移

    /// Swift-only 迁移的**总入口**：结构 + 数据补种。`ensureReady` 调这里。
    private static func ensureSwiftOnlyMigrations(_ db: OpaquePointer) {
        ensureSwiftOnlySchema(db)
        // ⚠ 补种**单独一步**，不进 `ensureSwiftOnlySchema`：它会改写
        //   `param_versions.params_json`，而自检驱动只需要结构对齐，
        //   不该被改写参数版本。
        backfillRegimeThresholds(db)
        backfillWatchGroupMembers(db)
        cleanOrphanWatchAlerts(db)
    }

    /// Swift-only 的**结构**迁移：加列 + 建表。**不含任何数据补种。**
    ///
    /// 为什么单独拆出来并公开：自检驱动（`AuditFixesTest` 等）跑在**由导出 schema 建的库**上，
    /// 那里没有 Swift-only 列 —— 写 `sel_price` 等会报 `no column named`，
    /// 所以驱动需要能单独把结构迁移跑齐。
    ///
    /// ## Swift-only 建表纪律（下面各 createXxx / addXxx 共用）
    /// · 这些表/列是**纯运行期**（100% Swift 展示/交互扩展）字段，**不写进** `engine/params/db_schema_export.json`
    ///   —— Core 基础 DDL 单一事实来源见 `SchemaExportData.swift` 与该导出快照（与 `MigrationCheck` 对齐）。
    /// · **必须独立于版本水位执行**：`ensureSchema` 在 `schema_version >= 14` 时直接 return，
    ///   把它们混进 `schema.migrations` 会被**永久跳过**（老库永远拿不到这些表/列）。
    /// · **无条件执行 + 幂等**（`IF NOT EXISTS` / `duplicate column` 静默跳过），每次启动跑一遍。
    /// · 建表失败只 NSLog：**不改变 `ensureReady` 的错误返回** —— 都是展示型结构，
    ///   表建不出来只是相关功能空着，不该让整个 App 判定"数据库不可用"。
    ///
    /// ⚠ 有意**不含** `backfillRegimeThresholds` —— 见 `ensureSwiftOnlyMigrations` 的注释。
    /// ⚠ `effective_from` 的回填**保留**：它只写 Swift-only 列本身。
    ///
    /// `param_versions.effective_from` 粒度是**日期**（`yyyy-MM-dd`）：应用按交易日跑，
    /// 日内先后激活两版无法区分，也不需要区分。
    public static func ensureSwiftOnlySchemaOnDisk() {
        let path = dataDirPath() + "/selected.sqlite3"
        guard FileManager.default.fileExists(atPath: path) else { return }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let db = handle else {
            if let h = handle { sqlite3_close(h) }
            return
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 30_000)
        ensureSwiftOnlySchema(db)
    }

    private static func ensureSwiftOnlySchema(_ db: OpaquePointer) {
        if let e = exec(db, "ALTER TABLE param_versions ADD COLUMN effective_from TEXT") {
            if !e.lowercased().contains("duplicate column") {
                NSLog("[ERROR] Swift-only 迁移失败（param_versions.effective_from）：%@", e)
            }
        }
        // 存量回填：迁移前的行没有生效日期 → 用**该版本首次出现在 scan_rounds 的日期**做代理。
        // 这是数据里真实存在的下界（那一版确实在当天被用过），不是编造的时间。
        // 查不到的（从未跑过扫描的版本）保持 NULL → 反查时回落当前激活版本，不猜。
        if let e = run(db, "UPDATE param_versions SET effective_from = ("
                       + "SELECT MIN(date) FROM scan_rounds"
                       + " WHERE scan_rounds.param_version = param_versions.name"
                       + ") WHERE effective_from IS NULL") {
            NSLog("[ERROR] effective_from 回填失败：%@", e)
        }

        createFundFlows(db)
        createLhb(db)
        createIndexMembers(db)
        createLimitUpPool(db)
        createBoardHeat(db)
        createZtSentiment(db)
        createIndicatorSnapshots(db)
        createIndicatorParams(db)
        dropStockIndustry(db)
        createStockFundamentals(db)
        addOutcomeWindows(db)
        addReviewScanMode(db)
        createWatchAlerts(db)
        createWatchGroupMembers(db)
        createHotPathIndexes(db)
        verifySwiftOnlyStructures(db)
    }

    /// 热路径缺失索引（2026-10-16 审查 B3）。
    ///
    /// ⚠ 为什么走 **Swift-only** 这条路径而不是 `schema.migration_sql`：
    ///   后者受 `schema_version` 闸门控制（只在版本推进时执行），已经跑过那个版本的库
    ///   永远不会再执行它；而 `CREATE INDEX IF NOT EXISTS` 放在 Swift-only 里
    ///   每次启动都跑、幂等、对存量库立即生效。纪律同 `createBoardHeat` 一族。
    ///
    /// 这五条都是拿开发库 `EXPLAIN QUERY PLAN` 实测过 `SCAN`（全表扫）的热点：
    ///   · `excluded_stocks(round_id)` —— 每轮详情渲染 + 删轮都按它过滤
    ///   · `excluded_stocks(date)`     —— 对比/调优按日期集合取
    ///   · `etf_picks(round_id)`       —— 同上，且 `DELETE … WHERE round_id=?` 也是全表扫
    ///   · `etf_picks(date)`
    ///   · `data_source_logs(event)`   —— 诊断页按 `event` 分组/过滤，而该表原先只有 `ts` 索引
    ///     （生产库累计数千条 `event='error'` + 更多 `5min_insufficient`，每次开诊断页全表扫）
    private static func createHotPathIndexes(_ db: OpaquePointer) {
        let ddl = """
        CREATE INDEX IF NOT EXISTS idx_excluded_round ON excluded_stocks(round_id);
        CREATE INDEX IF NOT EXISTS idx_excluded_date ON excluded_stocks(date);
        CREATE INDEX IF NOT EXISTS idx_etf_picks_round ON etf_picks(round_id);
        CREATE INDEX IF NOT EXISTS idx_etf_picks_date ON etf_picks(date);
        CREATE INDEX IF NOT EXISTS idx_dsl_event ON data_source_logs(event, id DESC);
        """
        if let e = exec(db, ddl) {
            NSLog("[ERROR] Swift-only 索引创建失败：%@", e)
        }
    }

    /// **收尾自检**：Swift-only 的表/列是否真的都在。
    ///
    /// 上面这一串建表/加列**失败只 NSLog**（有意不阻断启动 —— 它们都是展示型结构）。
    /// 但"缺表/缺列"的下游表现只是"某功能一直空着"，与"确实没数据"长得一模一样。
    /// ⇒ 把缺的东西**汇总一条**写进 `data_source_logs` —— 诊断页本来就在读这张表
    ///   （按 event 分组 + 「更多」列全量），**不需要新 UI** 就可见。
    ///
    /// ⚠ 设计不变：只做存在性检查、**不改变任何返回值**，仍不阻断启动。
    /// ⚠ 同一天最多记一条（30 天保留 × 每天多次启动会刷噪声）。
    private static func verifySwiftOnlyStructures(_ db: OpaquePointer) {
        let expectedTables = ["stock_fund_flows", "stock_lhb", "stock_lhb_seats", "index_members",
                              "limit_up_pool", "board_heat", "zt_sentiment", "indicator_snapshots",
                              "indicator_params", "indicator_param_changes",
                              "stock_fundamentals", "watch_alerts", "watch_alert_settings",
                              "watch_group_members"]
        // 列里挑**非展示型**的两条：缺了它们不是"少个字段"，是**静默改变结论**
        // （`effective_from` = 参数版本反查、`scan_mode` = 调优池 live/replay 分流）
        let expectedColumns = [("param_versions", "effective_from"),
                               ("reviews", "scan_mode")]
        var missing: [String] = []
        for t in expectedTables {
            let n = intScalar(db, "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='\(t)'") ?? 0
            if n == 0 { missing.append(t) }
        }
        for (t, c) in expectedColumns {
            let n = intScalar(db, "SELECT COUNT(*) FROM pragma_table_info('\(t)') WHERE name='\(c)'") ?? 0
            if n == 0 { missing.append("\(t).\(c)") }
        }
        guard !missing.isEmpty else { return }
        NSLog("[ERROR] Swift-only 结构缺失（不影响启动，但相关功能会静默空着）：%@",
              missing.joined(separator: "、"))
        let today = String(Self.isoTimestamp().prefix(10))
        let already = intScalar(db, "SELECT COUNT(*) FROM data_source_logs "
                                + "WHERE event='swift_only_structure_missing' AND ts LIKE '\(today)%'") ?? 0
        if already == 0 {
            logMigrationFailure(db, "swift_only_structure_missing",
                                "缺：" + missing.joined(separator: "、"))
        }
    }

    /// `watch_alerts` + `watch_alert_settings` 建表（自选提醒）。
    ///
    /// 纪律同上面「Swift-only 建表纪律」。本表**不建二级索引** ——
    /// 主键 `(code, kind, threshold)` 的最左前缀就是 `code`，按 code 查已走主键索引
    /// （理由见 `AlertStore` 类注释）。提醒的表建不出来只是铃铛显示"未设置"。
    private static func createWatchAlerts(_ db: OpaquePointer) {
        if let e = exec(db, AlertStore.createSQL) {
            NSLog("[ERROR] Swift-only 建表失败（watch_alerts / watch_alert_settings）：%@", e)
        }
    }

    /// `watch_group_members` 建表（「复制到分组」—— 一只股票同时在多个分组）。
    ///
    /// `watchlist.code` 是**主键**，一张表存不下"一只股票属于多个分组"
    /// ⇒ 归属关系只能另起一张表。纪律同上面「Swift-only 建表纪律」。
    /// ⚠ 灌数据在 `backfillWatchGroupMembers` —— `ensureSwiftOnlySchema` 明确"不含数据补种"。
    private static func createWatchGroupMembers(_ db: OpaquePointer) {
        if let e = exec(db, WatchStore.createSQL) {
            NSLog("[ERROR] Swift-only 建表失败（watch_group_members）：%@", e)
        }
    }

    /// 把 `watchlist.group_id` 灌进 `watch_group_members`（**幂等**）。
    ///
    /// **为什么必须灌**：归属表是后加的，老库里的自选股只有 `watchlist.group_id`
    /// 那**一个**分组信息。不灌的话升级后**所有老自选股都没有归属** ——
    /// 表现是"自选列表全空"（列表按归属过滤）。
    ///
    /// ⚠ **幂等**：`INSERT OR IGNORE` + 主键 `(code, group_id)` ⇒ 重复跑只留一行。
    /// ⚠ `NOT EXISTS` 那个条件是**必须的**：只灌"归属表里还没有任何行"的票 ——
    ///   否则每次启动都会把**多分组**的票按 `group_id` 重置回单归属，
    ///   用户刚"复制"出来的分组会**静默消失**。
    private static func backfillWatchGroupMembers(_ db: OpaquePointer) {
        if let e = exec(db,
            "INSERT OR IGNORE INTO watch_group_members(code, group_id) "
            + "SELECT w.code, w.group_id FROM watchlist w "
            + "WHERE w.group_id IS NOT NULL "
            + "  AND NOT EXISTS (SELECT 1 FROM watch_group_members m WHERE m.code = w.code)") {
            NSLog("[ERROR] watch_group_members 回填失败：%@", e)
        }
    }

    /// 清理孤儿自选提醒（历史版本删分组或移出自选异常遗留下的 `watch_alerts` / `watch_alert_settings` 行）。
    ///
    /// ⚠ `AlertMonitor` 会把 `AlertStore.rulesByCode().keys` 全部并入轮询队列；
    ///   清理不在 `watchlist` 中的提醒可阻止已移除标的继续后台轮询与弹窗。
    private static func cleanOrphanWatchAlerts(_ db: OpaquePointer) {
        for tbl in ["watchlist", AlertStore.alertsTable, AlertStore.settingsTable] {
            let n = intScalar(db, "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='\(tbl)'") ?? 0
            guard n > 0 else { return }
        }
        if let e = exec(db,
            "DELETE FROM \(AlertStore.alertsTable) "
            + "WHERE NOT EXISTS (SELECT 1 FROM watchlist w WHERE w.code = \(AlertStore.alertsTable).code)") {
            NSLog("[ERROR] 孤儿 watch_alerts 清理失败：%@", e)
        }
        if let e = exec(db,
            "DELETE FROM \(AlertStore.settingsTable) "
            + "WHERE NOT EXISTS (SELECT 1 FROM watchlist w WHERE w.code = \(AlertStore.settingsTable).code)") {
            NSLog("[ERROR] 孤儿 watch_alert_settings 清理失败：%@", e)
        }
    }

    /// `limit_up_pool` 建表（涨停统计）。纪律同上面「Swift-only 建表纪律」（表 + 索引都要登记）。
    private static func createLimitUpPool(_ db: OpaquePointer) {
        if let e = exec(db, LimitUpPoolStore.createSQL) {
            NSLog("[ERROR] Swift-only 建表失败（limit_up_pool）：%@", e)
        }
    }

    /// `board_heat` 建表（板块热度排行）。纪律同上面「Swift-only 建表纪律」。
    private static func createBoardHeat(_ db: OpaquePointer) {
        if let e = exec(db, BoardHeatStore.createSQL) {
            NSLog("[ERROR] Swift-only 建表失败（board_heat）：%@", e)
        }
    }

    /// `zt_sentiment` 建表（昨日涨停表现）。一天一行汇总，主键 `trade_date`，无二级索引。
    /// 纪律同上面「Swift-only 建表纪律」。
    private static func createZtSentiment(_ db: OpaquePointer) {
        if let e = exec(db, ZtSentimentStore.createSQL) {
            NSLog("[ERROR] Swift-only 建表失败（zt_sentiment）：%@", e)
        }
    }

    /// `indicator_snapshots` 建表（指标筛选）。DDL 由 `IndicatorSnapshotStore.createSQL`
    /// 从注册表生成 —— 列名手写必漂。纪律同上面「Swift-only 建表纪律」。
    private static func createIndicatorSnapshots(_ db: OpaquePointer) {
        if let e = exec(db, IndicatorSnapshotStore.createSQL) {
            NSLog("[ERROR] Swift-only 建表失败（indicator_snapshots）：%@", e)
        }
    }

    /// `indicator_params` / `indicator_param_changes` 建表（指标筛选参数，B 域独立存储）。
    /// 纪律同上面「Swift-only 建表纪律」。
    private static func createIndicatorParams(_ db: OpaquePointer) {
        if let e = exec(db, IndicatorParamStore.createSQL) {
            NSLog("[ERROR] Swift-only 建表失败（indicator_params）：%@", e)
        }
    }

    /// `index_members` 建表（指数成份）。纪律同上面「Swift-only 建表纪律」（表 + 索引都要登记）；
    /// 表建不出来只是详情页徽章不显示。
    private static func createIndexMembers(_ db: OpaquePointer) {
        if let e = exec(db, IndexMembersStore.createSQL) {
            NSLog("[ERROR] Swift-only 建表失败（index_members）：%@", e)
        }
    }

    /// `stock_fund_flows` 建表（个股资金流向）。纪律同上面「Swift-only 建表纪律」（表 + 索引都要登记）。
    private static func createFundFlows(_ db: OpaquePointer) {
        if let e = exec(db, FundFlowStore.createSQL) {
            NSLog("[ERROR] Swift-only 建表失败（stock_fund_flows）：%@", e)
        }
    }

    /// `stock_lhb` + `stock_lhb_seats` 建表（龙虎榜）。
    /// 纪律同上面「Swift-only 建表纪律」（**两张表 + 两个索引都要登记**）。
    private static func createLhb(_ db: OpaquePointer) {
        if let e = exec(db, LhbStore.createSQL) {
            NSLog("[ERROR] Swift-only 建表失败（stock_lhb / stock_lhb_seats）：%@", e)
        }
    }

    /// `stock_outcomes` 加 `sel_price` / `t3_close_pct` / `t5_close_pct`（多观察窗回测）。
    ///
    /// **为什么只有两列观察窗、没有 T+1**：T+1 收盘涨跌**已经存在** —— 就是 `close_profit`
    /// （目标交易日 = T+1 的收盘涨跌）。再补一列等于同一列存两遍，两个字段迟早分叉。
    ///
    /// **⚠ `sel_price` 不是观察窗，是基准价**：`stock_outcomes` 原先**不存**选股日价格，
    /// 而 T+3/T+5 是**两天后**才算的。若那时再从 `picks` 反推基准价，一旦 picks 被事后
    /// 补写（重跑扫描会追加轮次），T+3/T+5 就会与 `close_profit` 用上**不同基准** ——
    /// 三个窗不再可比，而界面上三个数看着都正常。落一列把它钉死。
    ///
    /// 执行纪律同上面「Swift-only 建表纪律」（登记进 Swift-only 列清单）。
    /// 失败时回填器在列不存在处自然查不到行、静默跳过。
    private static func addOutcomeWindows(_ db: OpaquePointer) {
        // ⚠ 顺序无关（各自独立 ALTER），但 `sel_price` 排最前以对齐"先有基准价才有观察窗"的读法
        let cols = ["sel_price"] + OutcomeWindow.allCases.map(\.column)
        for col in cols {
            if let e = exec(db, "ALTER TABLE stock_outcomes ADD COLUMN \(col) REAL") {
                if !e.lowercased().contains("duplicate column") {
                    NSLog("[ERROR] Swift-only 迁移失败（stock_outcomes.%@）：%@", col, e)
                }
            }
        }
    }

    /// `reviews` 加 `scan_mode`（历史日期批量重跑）。
    ///
    /// **这一列是什么**：该选股日的**选股轮次的价格口径** —— `'live'`（尾盘盘中价）或
    /// `'replay_close'`（历史回放的收盘价）。回放样本与 live 样本口径不同，
    /// 调优器默认**只用 live**（`PhaseTune.buildPool`），这一列是唯一的区分依据。
    ///
    /// **⚠ `DEFAULT 'live'` 是关键**：存量行、以及**将来其它路径的插入**（不做回放）
    /// 都会自动落到 `'live'`，所以**不需要回填**。回放侧的标记是插入之后由
    /// `PhaseStore.markReviewScanMode` 做的一次 UPDATE —— 有意不往 `persistReview`
    /// 的 INSERT 里加列。
    ///
    /// **⚠ 与结果 JSON 里的 `data_mode` 语义不同**：`data_mode` 说的是"这次复盘的**目标日**
    /// 行情是不是实时取的"，`scan_mode` 说的是"这个**选股日**的选股轮次是什么价格口径"。
    /// 一次真实的 T+1 复盘在补跑时会是 `data_mode=replay_daily_kline` 而 `scan_mode=live`。
    ///
    /// 执行纪律同上面「Swift-only 建表纪律」。这一列补不上的代价只是回放标记写不进去，
    /// 调优器仍按 live 处理，方向安全。
    private static func addReviewScanMode(_ db: OpaquePointer) {
        if let e = exec(db, reviewScanModeSQL) {
            if !e.lowercased().contains("duplicate column") {
                NSLog("[ERROR] Swift-only 迁移失败（reviews.scan_mode）：%@", e)
            }
        }
    }

    /// `reviews.scan_mode` 的迁移语句 —— 抽成常量是为了**单测能锁住 `DEFAULT 'live'`**。
    ///
    /// ⚠ `DEFAULT 'live'` 不是装饰：**存量行**与**其它路径的插入**全靠它落到 `'live'`。
    /// 一旦少了它，那些行是 NULL，而 `PhaseTune.buildPool` 的 `AND scan_mode='live'`
    /// 会把 NULL **静默排除** → 调优池里所有历史样本凭空消失，界面只显示"样本不足"。
    static let reviewScanModeSQL = "ALTER TABLE reviews ADD COLUMN scan_mode TEXT DEFAULT 'live'"

    /// 下线「行业信息」模块后清掉它留下的表（2026-10-28 他拍板删除）。
    ///
    /// **为什么要 DROP 而不是留着**：这张表由 Swift-only 建表纪律创建，模块整条链路删掉后
    /// 它就成了没人建、没人读、也没人清的孤儿表，还会跟着每次数据归档一直传下去
    /// （`DROP TABLE` 会连带删掉它上面的 `idx_stock_industry_name` 索引）。
    /// 表里从来没有过数据（取数判据的死结，见当天的日志与记忆），所以这一句不销毁任何事实。
    private static func dropStockIndustry(_ db: OpaquePointer) {
        if let e = exec(db, "DROP TABLE IF EXISTS stock_industry") {
            NSLog("[ERROR] Swift-only 删表失败（stock_industry）：%@", e)
        }
    }

    /// `stock_fundamentals` 建表（基本面）。纪律同上面「Swift-only 建表纪律」。
    private static func createStockFundamentals(_ db: OpaquePointer) {
        if let e = exec(db, FundamentalStore.createSQL) {
            NSLog("[ERROR] Swift-only 建表失败（stock_fundamentals）：%@", e)
        }
    }

    /// `predict_rules.regime_thresholds` 补键（数据迁移）。
    ///
    /// **为什么需要**：该键是 **schema 项**（进参数中心），而 `validate` 对「**键缺失**」
    /// 一律报错 —— 存量用户版本（库里已存的 `params_json`）没有这个键，
    /// 一旦激活并保存参数就会被拒。
    ///
    /// ⚠ **只增不改**：仅当键**缺失**时注入默认表；已有值**原样保留**。
    ///   注入值 == `PredictRules.defaultRegimeThresholds`，而引擎本来就在缺键时**回落它**
    ///   → **行为不变**（补键只是把"隐式回落"变成"显式写下来"）。
    /// ⚠ **独立于版本水位执行**（同建表）：数据迁移混进 `schema.migrations`
    ///   会在老库被**永久跳过**。
    /// ⚠ **幂等**：第二次跑时没有任何行命中"缺键"，UPDATE 0 行。
    /// ⚠ **只碰用户自建版本**（`is_builtin = 0`）：出厂行由随包文件刷新带进新键。
    /// ⚠ 全程**不用 JSON1 扩展**（`json_extract` / `json_set` 在旧 SQLite 上不一定可用）——
    ///   读出来在 Swift 里解析、写回去，行为可预测。编码器用 `PyJSON.encode`
    ///   （与 `ParamStore.saveVersion` 落库同款，键序按字典序）。
    private static func backfillRegimeThresholds(_ db: OpaquePointer) {
        var stmt: OpaquePointer?
        // ⚠ **只处理用户自建版本**（`is_builtin = 0`）：出厂行每次启动都会按随包文件
        //   刷新，补种逻辑会把新键带进来 —— 在这里改它们既多余，也会破坏
        //   「已有出厂行原文不得被改写」的约定。
        //   （已废弃的旧命名出厂行不在随包清单里、也不会被刷新，但引导会把激活指针
        //    从它们身上重定向走，所以同样不需要补。）
        guard sqlite3_prepare_v2(db, "SELECT name, params_json FROM param_versions"
                                     + " WHERE is_builtin = 0", -1, &stmt, nil)
                == SQLITE_OK else { return }
        // ⚠ `sqlite3_finalize` 用 `defer` 收尾：step 中途失败时的 `return` 若跳过它，
        //   每次失败就泄漏一个语句句柄（`finalize(nil)` 是安全的空操作）。
        defer { sqlite3_finalize(stmt) }
        var rows: [(name: String, json: String)] = []
        var rc = SQLITE_OK
        while true {
            rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }        // 正常结束（没有更多行）
            if rc != SQLITE_ROW {
                // ⚠ step 中途失败 → **丢弃已取到的部分行**：把"出错"当"正常结尾"
                //   会返回**半截结果**且无任何报错。丢弃 = 安全方向。
                NSLog("[ERROR] DBBootstrap.backfillRegimeThresholds step 失败 rc=%d → 丢弃已取的 %d 行",
                      rc, rows.count)
                // ⚠ 本函数返回 Void → 直接返回（已取的 rows 被丢弃，不做半截回填）
                return
            }
            guard let nc = sqlite3_column_text(stmt, 0),
                  let jc = sqlite3_column_text(stmt, 1) else { continue }
            rows.append((String(cString: nc), String(cString: jc)))
        }
        guard !rows.isEmpty else { return }

        // 默认表 → `[String: Any]`（原类型是 [String: [String: Double]]）
        let defaultTable: [String: Any] = PredictRules.defaultRegimeThresholds
            .reduce(into: [String: Any]()) { acc, kv in acc[kv.key] = kv.value }

        var patched = 0
        for (name, json) in rows {
            guard let data = json.data(using: .utf8),
                  var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else {
                NSLog("[ERROR] regime_thresholds 补键：%@ 的 params_json 解析失败（跳过）", name)
                continue
            }
            var rules = (obj["predict_rules"] as? [String: Any]) ?? [:]
            guard rules["regime_thresholds"] == nil else { continue }   // 已有 → 原样保留
            rules["regime_thresholds"] = defaultTable
            obj["predict_rules"] = rules
            if let e = run(db, "UPDATE param_versions SET params_json=? WHERE name=?",
                           [.text(PyJSON.encode(obj)), .text(name)]) {
                NSLog("[ERROR] regime_thresholds 补键失败（%@）：%@", name, e)
                continue
            }
            patched += 1
        }
        if patched > 0 {
            NSLog("[NOTICE] regime_thresholds 补键：%d 个存量参数版本", patched)
        }
    }

    // `screen` 补键迁移已**移除**（参数中心重构）：P3 初版曾把筛选阈值塞进 A 域
    // `param_versions`，现已撤出 schema、改走 B 域 `indicator_params` 独立表。
    // `ParamSchema.validate` 只遍历 schema 项、**忽略未知键** —— 存量 params_json 里
    // 残留的 `screen` 键无害（不会被读到，也不会报错），不需要清理迁移。

    // MARK: - 启动期库维护

    /// 为什么放在这里：`ensureReady()` 是 App 启动的**第一个**动作
    /// （`SelectedApp.applicationDidFinishLaunching` 里排在 Scheduler/Store 之前），
    /// 此刻只有本连接 —— `wal_checkpoint(TRUNCATE)` 不会被别的读事务挡住。
    ///
    /// 三项都**尽力而为**：失败只留痕，不阻断启动（它们是优化，不是功能）。
    private static func maintenance(_ db: OpaquePointer) {
        // ① WAL 回收。WAL 是只增不减的：每次写都追加帧，只有 checkpoint 才回收。
        //    没有 checkpoint 控制时，长跑进程的 -wal 文件会一直膨胀。
        if let e = exec(db, "PRAGMA wal_checkpoint(TRUNCATE)") {
            // 有其它连接持读锁时 checkpoint 会返回 busy —— 属正常，下次启动再试
            NSLog("[NOTICE] wal_checkpoint 未完成（可能有其它连接持锁）：%@", e)
        }
        // ② 查询规划器统计（SQLite 官方推荐的低成本维护，下次查询自动受益）
        _ = exec(db, "PRAGMA optimize")
        // ③ 数据源日志保留策略。`data_source_logs` 是"只写不清"的：
        //    每次取数成功/失败/降级/覆盖率偏低都写一行（单次全量扫描就 1~3 行）。
        //    保留 30 天，超期删除 —— ts 是 `yyyy-MM-dd'T'HH:mm:ss` 定长格式，字符串比较即时间序。
        let cutoff = isoFormatter.string(from: Date().addingTimeInterval(-30 * 24 * 3600))
        if let e = run(db, "DELETE FROM data_source_logs WHERE ts < ?", [.text(cutoff)]) {
            NSLog("[ERROR] data_source_logs 清理失败：%@", e)
        }
    }

    // MARK: - schema 版本迁移（ensureSchema）

    private static func ensureSchema(_ db: OpaquePointer, _ schema: Schema) -> String? {
        // ① 版本水位：已是当前版本（或更新）→ 直接返回，新迁移不会执行
        if let v = scalarInt(db, "SELECT value FROM meta WHERE key='schema_version'"),
           v >= schema.version {
            return nil
        }

        // ⚠ 建表 + 增量迁移**整体包在一个事务里**。
        //
        // ## 为什么必须
        // 逐条执行、中途失败就停在半路 ⇒ 库里留下**建了一半**的表结构：
        //   · 建表是**多语句整体执行**（`schema.sql` 里 23 条 CREATE TABLE），
        //     第 12 条失败 ⇒ 前 11 条已落库且**不会回滚**；
        //   · 迁移是 14 条独立 `ALTER TABLE`，第 7 条失败 ⇒ 前 6 条的列已加上了。
        // 这类「半成品库」最难处理：版本号没推进（下次启动会重跑全量），
        // 但 `CREATE TABLE IF NOT EXISTS` 遇到已存在的表**什么都不做** ⇒
        // 缺失的那些表**永远补不上**，而错误只在当次启动的 `lastError` 里出现一次。
        //
        // ## 前提
        // SQLite 的 DDL 是**事务安全**的：事务内 CREATE TABLE / ALTER TABLE 后
        // `ROLLBACK` 不留痕迹。⇒ 包裹后「迁移失败」= **库回到迁移前的样子**，
        // 下次启动从干净状态重试。
        //
        // ⚠ **留痕必须在回滚之后**（`migration_failed` 那条 INSERT）：
        //   若写在事务里，回滚会把它一起撤掉 ⇒ **失败原因彻底消失**。
        //   ⇒ 事务只包 建表/迁移/推进版本号/提交；留痕与错误返回都在 COMMIT 或 ROLLBACK 之后。
        if let e = exec(db, "BEGIN IMMEDIATE") {
            // ⚠ 开不了事务（极少：只可能是写锁被别处长期持有）⇒ **降级而不是硬失败**：
            //   把它升级成硬失败会让 App **完全起不来**，而那对「数据其实没坏」的库是不相称的惩罚。
            NSLog("[ERROR] schema 事务开启失败（本次迁移将无回滚保护）：%@", e)
            return migrateWithoutTransaction(db, schema)
        }

        var failed: [String] = []
        // ② 建表（多语句整体执行；IF NOT EXISTS 幂等）
        if let e = exec(db, schema.schemaSQL) {
            failed.append("建表 → \(e)")
        }

        // ③ 增量迁移：duplicate column = 正常的重复执行，静默跳过
        if failed.isEmpty {
            for stmt in schema.migrations {
                if let e = exec(db, stmt) {
                    if e.lowercased().contains("duplicate column") { continue }
                    failed.append("\(stmt) → \(e)")
                }
            }
        }

        if !failed.isEmpty {
            // ⚠ **先回滚，再留痕**（回滚撤销建表/迁移；留痕是事务外写的，不会被撤）
            let detail = failed.joined(separator: "；")
            let rolled = rollbackChecked(db)
            if rolled {
                logMigrationFailure(db, "migration_failed", "已回滚（库回到迁移前状态）；\(detail)")
            } else {
                NSLog("[ERROR] 迁移失败且 ROLLBACK 未完成 —— 留痕写不进该连接，原因只靠 lastError：%@", detail)
            }
            return "schema 迁移未全部成功（\(rolled ? "已回滚" : "⚠ 回滚失败，事务可能残留")，版本号未推进，下次启动重试）：" + detail
        }

        // ④ 推进版本号 —— ⚠ **写失败必须报错**：版本号没推进却报告成功
        //    ⇒ 每次启动重跑全量迁移（每次启动稳定几条 `duplicate column` 噪音），
        //    而**真实原因没有任何出口**。
        //    不变量：**不推进版本号就必须留痕 + 显式失败**。
        if let e = run(db, "INSERT OR REPLACE INTO meta(key, value) VALUES('schema_version', ?)",
                       [.text(String(schema.version))]) {
            let rolled = rollbackChecked(db)
            if rolled {
                logMigrationFailure(db, "schema_version_write_failed", "已回滚；\(e)")
            } else {
                NSLog("[ERROR] schema_version 写失败且 ROLLBACK 未完成：%@", e)
            }
            return "schema_version 写入失败（\(rolled ? "已回滚" : "⚠ 回滚失败，事务可能残留")，版本号未推进，下次启动重试）：\(e)"
        }

        // ⑤ 提交。⚠ 提交失败同样要回滚 + 留痕 —— 否则会留下一个**空转的事务**：
        //    后续所有写都在这个事务里（看不见、直到库满或某处 BUSY），
        //    App 界面一切正常但**数据写不进去**，是最难查的一种故障。
        if let e = exec(db, "COMMIT") {
            let rolled = rollbackChecked(db)
            if rolled {
                logMigrationFailure(db, "migration_commit_failed", "已回滚；\(e)")
            } else {
                NSLog("[ERROR] COMMIT 失败且 ROLLBACK 未完成（事务残留，本连接的后续写入都会被丢弃）：%@", e)
            }
            return "schema 迁移提交失败（\(rolled ? "已回滚" : "⚠ 事务残留")）：\(e)"
        }
        return nil
    }

    /// **事务开启失败时的降级路径**：逐条执行、不回滚，如实留痕。
    ///
    /// ⚠ 存在的意义：「开不了事务」时把它升级成硬失败会让 App **完全起不来**。
    ///   ⇒ 照原样跑，但**如实留痕**说「这次没有回滚保护」。
    ///   下次启动会重试迁移（版本号没推进），那时锁多半已经放了 ⇒ 自动回到事务路径。
    private static func migrateWithoutTransaction(_ db: OpaquePointer, _ schema: Schema) -> String? {
        var failed: [String] = []
        if let e = exec(db, schema.schemaSQL) { failed.append("建表 → \(e)") }
        if failed.isEmpty {
            for stmt in schema.migrations {
                if let e = exec(db, stmt) {
                    if e.lowercased().contains("duplicate column") { continue }
                    failed.append("\(stmt) → \(e)")
                }
            }
        }
        if !failed.isEmpty {
            let detail = "⚠ 本次无事务保护（开事务失败）；\(failed.joined(separator: "；"))"
            logMigrationFailure(db, "migration_failed", detail)
            return "schema 迁移未全部成功（\(detail)版本号未推进，下次启动重试）："
                + failed.joined(separator: "；")
        }
        if let e = run(db, "INSERT OR REPLACE INTO meta(key, value) VALUES('schema_version', ?)",
                       [.text(String(schema.version))]) {
            logMigrationFailure(db, "schema_version_write_failed", e)
            return "schema_version 写入失败：\(e)"
        }
        return nil
    }

    // MARK: - 轻量 sqlite3 封装（建库路径独立于 SQLiteWriter：
    //  Writer 只对「已存在的库」开放写，且首次建库必须先于它可用）

    private enum Bind {
        case text(String)
        case int(Int)
    }

    /// **迁移失败的留痕**（多处调用点共用）。
    ///
    /// ## 为什么不能直接 INSERT
    /// ⚠ **留痕的目标表本身可能是"没建出来"的那一张** ——
    ///   建表包在事务里，而**建表失败 ⇒ 全部回滚** ⇒ `data_source_logs` 依然不存在 ⇒
    ///   直接 INSERT 报 "no such table" ⇒ **失败原因被彻底丢掉**。
    ///   而"失败原因只在当次启动的 lastError 里出现一次"正是这条路径要消灭的东西。
    ///
    /// ⇒ 这里先 `CREATE TABLE IF NOT EXISTS` 再写。
    ///   ⚠ 只在**迁移失败**这条路走（正常启动一次都不执行），额外开销可以忽略。
    ///   ⚠ 建表语句与 `schema.sql` 里的**逐字一致** —— 两处不一致会让
    ///   "先建的"与"迁移建的"长得不一样，诊断时看到两种结构会更困惑。
    private static func logMigrationFailure(_ db: OpaquePointer, _ event: String, _ detail: String) {
        // ⚠ 写成单行：多行字符串字面量（`"""`）的收尾定界符必须独占一行，
        //   插进 `exec(db, …)` 的参数列表里极易踩到编译错误。
        let ddl = "CREATE TABLE IF NOT EXISTS data_source_logs("
            + "id INTEGER PRIMARY KEY AUTOINCREMENT, ts TEXT, source TEXT, event TEXT, detail TEXT)"
        if let e = exec(db, ddl) {
            NSLog("[ERROR] 迁移留痕表建不出来：%@（失败原因只能靠 lastError）", e)
            return
        }
        let ts = Self.isoTimestamp()
        if let e = run(db, "INSERT INTO data_source_logs(ts, source, event, detail) VALUES(?,?,?,?)",
                       [.text(ts), .text("db"), .text(event), .text(detail.prefix(500).description)]) {
            NSLog("[ERROR] 迁移留痕写入失败：%@（失败原因只能靠 lastError）", e)
        }
    }

    /// 时间戳格式 `yyyy-MM-dd'T'HH:mm:ss`（委托 ChinaTime.formatter）
    private static let isoFormatter = ChinaTime.formatter("yyyy-MM-dd'T'HH:mm:ss")

    private static func isoTimestamp() -> String { isoFormatter.string(from: Date()) }

    /// 回滚事务并**确认事务真的结束了**（2026-10-16 审查 B2）。
    ///
    /// 原先三处失败分支都写作 `_ = exec(db, "ROLLBACK")`（**忽略返回值**）后紧接
    /// `logMigrationFailure(db, …)`：一旦 ROLLBACK 本身失败且事务仍挂在连接上，
    /// 那条留痕 INSERT 会被 `ensureReady` 末尾的 `defer { sqlite3_close(db) }` **一起回滚掉** ——
    /// 失败原因彻底消失，而这正是本文件反复声明要防的事（"失败原因必须可见"）。
    /// 判据与 `SQLiteTxn.mustDiscardConnection` 一致：回滚失败后 `autocommit == 0`
    /// 说明事务还在，此后该连接上的任何写入都不作数。
    ///
    /// - Returns: `true` = 事务已结束，后续留痕/建表可安全写入该连接。
    @discardableResult
    private static func rollbackChecked(_ db: OpaquePointer) -> Bool {
        if exec(db, "ROLLBACK") == nil { return true }
        let stillOpen = sqlite3_get_autocommit(db) == 0
        if stillOpen {
            NSLog("[ERROR] ROLLBACK 失败且事务仍残留 —— 本连接上的后续写入都会被丢弃")
        }
        return !stillOpen
    }

    /// 单值文本查询（只用于 PRAGMA 一类自检读数）；失败返回 nil。
    private static func queryString(_ db: OpaquePointer, _ sql: String) -> String? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: c)
    }

    /// 执行 SQL（可多语句），失败返回错误文案
    private static func exec(_ db: OpaquePointer, _ sql: String) -> String? {
        var errmsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errmsg)
        if rc != SQLITE_OK {
            let msg = errmsg.map { String(cString: $0) } ?? "rc=\(rc)"
            sqlite3_free(errmsg)
            return msg
        }
        return nil
    }

    /// 执行单条带参 SQL（失败返回错误文案）
    @discardableResult
    private static func run(_ db: OpaquePointer, _ sql: String, _ params: [Bind] = []) -> String? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return sqlite3_errmsg(db).map { String(cString: $0) } ?? "prepare 失败"
        }
        defer { sqlite3_finalize(stmt) }
        for (i, p) in params.enumerated() {
            switch p {
            case .text(let s): sqlite3_bind_text(stmt, Int32(i + 1), s, -1, SQLITE_TRANSIENT_BS)
            case .int(let n): sqlite3_bind_int64(stmt, Int32(i + 1), Int64(n))
            }
        }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            return sqlite3_errmsg(db).map { String(cString: $0) } ?? "rc=\(rc)"
        }
        return nil
    }

    /// 读一个**整数**标量（`COUNT(*)` 这类）。
    /// ⚠ 别和 `scalarInt` 混用：`scalarInt` 只认 `SQLITE_TEXT`（给 `meta.value`
    ///   这类 TEXT 列用的）—— 拿它读 `COUNT(*)` 会**恒为 nil**。
    private static func intScalar(_ db: OpaquePointer, _ sql: String) -> Int? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private static func scalarInt(_ db: OpaquePointer, _ sql: String) -> Int? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW,
              sqlite3_column_type(stmt, 0) == SQLITE_TEXT,
              let c = sqlite3_column_text(stmt, 0) else { return nil }
        return Int(String(cString: c))
    }
}