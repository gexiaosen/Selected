import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// SQLite 只读直读层 —— UI 读取为毫秒级。
/// 数据目录解析唯一实现见 `DataDirectory.resolve()`：
/// env SELECTED_DATA_DIR → 打包模式 ~/Library/Application Support/Selected → 开发模式 <工程>/data
///
/// ## ⚠ 连接纪律（编译期契约）
///
/// 每个实例持有一条 sqlite 连接，而 Apple 系统 libsqlite3 是 **multi-thread 模式
/// （非 serialized）** —— 同一条连接被多个线程并发使用**直接 SIGSEGV**。因此：
///
///   · **主线程**：用 `shared`（`@MainActor` 隔离）—— 后台代码**连拿都拿不到它**，
///     引用即编译失败，不依赖"记得别用"这句注释。
///   · **后台**：用 `makeIndependent()` 新建一条自己的连接（或调用自带连接的入口）。
///   · 内部 `NSLock` 只保护 `db` / `dirPath` **句柄本身**的读写，**不**代理整个语句执行。
///
/// ⚠ 本类**不标 `@unchecked Sendable`**：标了的话，`let r = SQLiteReader.shared`
///   再 `Task.detached { r.queryRaw(...) }` 就能编译过 —— 跨线程复用同一连接
///   （已知 SIGSEGV 形态）在编译期拦不住。不标之后：把实例传进 `Task.detached`
///   是编译错误；`makeIndependent()` 的实例不需要 Sendable（调用点是同一表达式内
///   创建 + 使用，不跨 `await`）；`shared` 是 `@MainActor` 隔离的静态属性，也不需要。
///
/// ⚠ 不采用"给实例读方法加 `@MainActor`"的修法：那会废掉后台路径 ——
///   `makeIndependent()` 的实例正是给 `Task.detached` 用的，方法不能 MainActor 隔离。
///   同一类型无法同时满足两侧 ⇒ 只能靠"不 Sendable"来分。
final public class SQLiteReader: DataConnection {

    /// 主线程专用的共享连接 —— `@MainActor` **就是这条契约本身**（见类注释）。
    @MainActor public static let shared = SQLiteReader("SQLiteReader.shared")

    /// 后台读库用：新建一条**独立连接**。
    ///
    /// 契约：返回的实例（及其连接）必须**只由一个执行域使用** —— 不要跨线程共享、
    /// 不要长期缓存后从多处并发调用；用完即释放最省心（开连接是毫秒级）。
    /// 需要在后台跑多次查询时，在**那个**后台域里建一个实例复用，而不是拿 `shared`。
    /// ⚠ 实例名不带编号：同一个后台域里可能先后造多条，日志靠**时刻**分辨即可，
    ///   带自增编号会让 `registeredNames` 这种诊断集合每次运行都不同（测试没法钉）。
    public nonisolated static func makeIndependent() -> SQLiteReader { SQLiteReader("SQLiteReader.independent") }

    private let lock = NSLock()
    private var db: OpaquePointer?
    private var dirPath: String?
    /// 实例名：`shared` 与每一条 `makeIndependent()` 造的短命连接在日志里要分得开
    private let instanceName: String

    private init(_ name: String) {
        self.instanceName = name
        // ⚠ 登记 ⇒ 换库时这条连接一定被放掉（含后台扫描临时造的独立连接）。
        DataConnections.register(self)
    }

    // MARK: - DataConnection

    /// 释放动作 = `invalidate()`（放连接 **且** 清掉 `dirPath` 缓存 ——
    /// 只放连接不清缓存的话，下次仍按**旧目录**重开，换库等于没换）。
    public func releaseConnection() { invalidate() }
    public var connectionName: String { instanceName }

    // MARK: - 库完整性自检

    /// 生产库完整性自检（`PRAGMA quick_check`）。
    ///
    /// 为什么要有：`~/Library/Application Support/Selected/selected.sqlite3`
    /// 是**唯一不可再生资产**（每次打包只做 tar.gz 滚动归档）。若库损坏，UI 侧表现为
    /// "页面全空"，很容易被误读成"今天还没扫描"，而不是"库坏了"。这里主动探测并
    /// 给出可操作提示（去哪个目录找归档），把"静默空"变成"明确故障"。
    ///
    /// ⚠ **实现契约（改前必读）**：
    ///   1. 本方法会被**后台线程**调用（Store.refresh 启动时 detached），**绝不能复用
    ///      共享连接 `db`** —— 单个连接跨线程并发使用直接 SIGSEGV。共享连接仅限主线程。
    ///      此处开**一次性独立连接**：WAL 支持多连接并发，与主线程读、引擎写互不干扰。
    ///      ⚠ 后台调用写法：`SQLiteReader.makeIndependent().integrityIssue()`
    ///      —— 不能写 `SQLiteReader.shared.integrityIssue()`（后台引用不过编译）。
    ///   2. 也绝不能在方法内先拿 `lock` 再调 `open()`：NSLock 不可重入，open() 内部
    ///      拿同一把锁 → 主线程自我死锁（"App 打开一直转圈"）。
    public func integrityIssue() -> String? {
        guard let dir = dataDirPath(),
              FileManager.default.fileExists(atPath: dir + "/selected.sqlite3") else {
            return nil   // 无库（首装/未扫描）不是损坏，不误报
        }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(dir + "/selected.sqlite3", &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let db = handle else {
            // ⚠ 打开失败也必须关（2026-10-16 审查 B2）：`sqlite3_open_v2` 失败时**仍可能已分配
            //   句柄**（"文件存在但无法打开"一类尤其如此），原写法直接 return 就是每次自检
            //   泄漏一个 `sqlite3*` + 一个 fd。同项目其他四处打开点都遵循"失败即关"。
            if let h = handle { sqlite3_close(h) }
            return "数据库无法打开（可能被占用或文件损坏）"
        }

        defer { sqlite3_close(db) }
        // 与 open() 同理由用 READWRITE：WAL 残留 shm 需要写权限恢复，query_only 保证不产生任何写入
        sqlite3_busy_timeout(db, 30_000)   // 自检不该因为一次撞锁就误报"库损坏"
        sqlite3_exec(db, "PRAGMA query_only = ON", nil, nil, nil)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA quick_check(1)", -1, &stmt, nil) == SQLITE_OK else {
            return "数据库自检失败（无法执行完整性检查）"
        }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW,
           let c = sqlite3_column_text(stmt, 0) {
            let msg = String(cString: c)
            if msg.lowercased() != "ok" {
                return "数据库完整性异常：\(msg)"
            }
        }
        return nil
    }

    /// 数据目录（供"打开归档目录"等提示使用）
    public var dataDir: String {
        lock.lock(); defer { lock.unlock() }
        return dirPath ?? resolveDirUnlocked()
    }

    // MARK: - 路径解析

    /// 无锁路径解析（绝不在持锁状态下调用任何会拿锁的方法）。
    /// 数据目录解析 —— 唯一实现见 `DataDirectory.resolve()`
    private func resolveDirUnlocked() -> String { DataDirectory.resolve() }

    public func dataDirPath() -> String? {
        lock.lock(); defer { lock.unlock() }
        if let d = dirPath { return d }
        let resolved = resolveDirUnlocked()
        dirPath = resolved
        return resolved
    }

    /// 关闭并清空缓存的连接与数据目录 —— 导入/迁移换了库、或改了 SELECTED_DATA_DIR 后调用。
    /// 不这样做的话，缓存的连接会一直读旧 inode 直到重启。
    /// 沿用本类既有锁策略（共享连接仅主线程用，调用方在主线程回调里）。
    public func invalidate() {
        lock.lock(); defer { lock.unlock() }
        if let handle = db { sqlite3_close(handle) }
        db = nil
        dirPath = nil
    }

    public func dataDirURL() -> URL? {
        dataDirPath().map { URL(fileURLWithPath: $0) }
    }

    private func open() -> OpaquePointer? {
        lock.lock(); defer { lock.unlock() }
        if db != nil { return db }
        // 锁内直接用缓存/无锁解析，绝不调用 dataDirPath()（NSLock 不可重入）
        let dir = dirPath ?? {
            let r = resolveDirUnlocked()
            dirPath = r
            return r
        }()
        guard FileManager.default.fileExists(atPath: dir + "/selected.sqlite3") else { return nil }
        var handle: OpaquePointer?
        // 必须以 READWRITE 打开（再用 query_only 禁写）：
        // 引擎写 WAL、主文件是旧快照；若 shm 索引失效（引擎服务被 SIGTERM 后残留），
        // READONLY 连接无权重建 shm → 静默回退只读主文件 → 读到旧数据（打开看板全空的根因）。
        // READWRITE 可创建/恢复 shm 正常读 WAL；query_only 确保连接不产生任何写入
        if sqlite3_open_v2(dir + "/selected.sqlite3", &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
           let h = handle {
            // 撞锁时等待而非立刻失败：不设 busy_timeout 时，WAL 恢复或 checkpoint
            // 期间 prepare/step 会立刻返回 SQLITE_BUSY，而 `query` 对失败是
            // `return []` → 界面静默空页，且没有任何报错可查。
            sqlite3_busy_timeout(h, 30_000)
            sqlite3_exec(h, "PRAGMA query_only = ON", nil, nil, nil)
            db = h
            return db
        }
        // ⚠ 必须先关掉 RW 那次尝试留下的句柄（2026-10-16 审查 B2）：
        //   `sqlite3_open_v2` **失败时也可能已分配句柄**，而原写法把同一个 `&handle`
        //   直接交给下一次 READONLY 尝试 —— 指针被覆写，上一个连接与它的 fd
        //   就**永远关不掉**（只读卷/权限异常环境下每次取数都泄漏一个）。
        if let h = handle { sqlite3_close(h) }
        handle = nil
        // 兜底：文件只读权限时退回 READONLY（老行为）
        if sqlite3_open_v2(dir + "/selected.sqlite3", &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
           let h = handle {
            sqlite3_busy_timeout(h, 30_000)   // 同上：撞锁等待，不静默返回空
            db = h
            return db
        }
        sqlite3_close(handle)
        return nil
    }

    // MARK: - 查询基础

    /// 只读查询入口（内部/诊断/测试用）。
    /// 用途之一：验证写连接（SQLiteWriter）提交的数据对只读层**立即可见**
    /// —— WAL 模式下每个语句都是新读事务，不需要 invalidate 连接。
    public func queryRaw(_ sql: String, _ params: [Any] = []) -> [[String: Any]] {
        query(sql, params)
    }

    /// 最近的数据源日志（新鲜度徽章用）：按 `ts` 倒序取最近 `limit` 条。
    ///
    /// ⚠ 只取 3 列（`ts` / `source` / `event`）—— `detail` 最长 500 字符，
    /// 徽章用不到它，取回来只是白白搬运。
    /// `ts` 是 ISO 文本（`yyyy-MM-dd'T'HH:mm:ss`，上海时区），字典序即时序，
    /// 故 `ORDER BY ts DESC` 与 `idx_dsl_ts` 索引一致，不需要额外排序。
    public func dataSourceLogs(limit: Int = 400) -> [[String: Any]] {
        query("SELECT ts, source, event FROM data_source_logs ORDER BY ts DESC LIMIT ?",
              [max(1, limit)])
    }

    /// 表是否存在。
    ///
    /// ⚠ 为什么需要：`query` 在「表不存在」时返回**空数组**，与「表存在但没数据」
    ///   **完全无法区分** —— 诊断界面要给出「老库未迁移，去跑数据迁移」这种**可操作**提示，
    ///   就必须能分辨这两种空。
    /// ⚠ 只查 `sqlite_master` 的表名，不开事务、不缓存（每次调用一次 `sqlite_master` 查询，
    ///   开销可忽略；这个接口只在「打开诊断页」时用）。
    public func hasTable(_ name: String) -> Bool {
        guard let db = open() else { return false }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db,
              "SELECT 1 FROM sqlite_master WHERE type='table' AND name=? LIMIT 1",
              -1, &stmt, nil) == SQLITE_OK, let stmt else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    /// 数据源日志的**带明细**版本（诊断界面用）。
    ///
    /// ⚠ 与上面 `dataSourceLogs(limit:)` 的区别：那处**只取 3 列**（给新鲜度徽章，
    ///   刻意不搬 `detail` 免得白搬 500 字 × 400 行）；这里**要 `detail`**，
    ///   因为诊断的全部价值就在那一行字。
    /// ⇒ 两条查询**故意并存**，不改既有那条（改它会让徽章白白搬 20 万字）。
    public func dataSourceLogDetails(limit: Int = 200) -> [[String: Any]] {
        query("""
            SELECT id, ts, source, event, substr(detail, 1, 500) AS detail
            FROM data_source_logs ORDER BY id DESC LIMIT ?
            """, [max(1, limit)])
    }

    private func query(_ sql: String, _ params: [Any] = []) -> [[String: Any]] {
        guard let db = open() else { return [] }
        var stmt: OpaquePointer?
        // ⚠ prepare 失败不能静默 `return []`（2026-10-16 审查 B2）：
        //   `[]` 与"今天确实没有数据"在界面上**完全同形**（页面显示空态、零报错），
        //   而最常见的触发原因是 Swift-only 列/表没建成（`DBBootstrap` 的补建
        //   按设计不阻断启动）。同族的另外三处实现
        //   （`ReadOnlyConnection` / `HistoryBarStore` / `SQLiteWriter`）都会记错误原因，
        //   这里补齐 —— 失败可见才有得可查。
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            let msg = sqlite3_errmsg(db).map { String(cString: $0) } ?? "?"
            NSLog("[ERROR] DB prepare 失败: %@ | SQL: %@", msg, String(sql.prefix(120)))
            return []
        }
        defer { sqlite3_finalize(stmt) }

        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            // ⚠ 分支顺序**刻意保持**：`Int` 会桥接到 `NSNumber`、`Bool` 也会，
            //   调换顺序会改变已有类型的绑定路径（例如大整数被当 Double 丢精度）。
            //   未识别的类型**不能静默不绑定**（占位符保持 NULL → 查询返回空却不报错，
            //   极难排查），也不能用 `assertionFailure`（Release 下是空操作）——
            //   兜底必须留可检索日志。
            if let s = p as? String {
                sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
            } else if let n = p as? Int {
                sqlite3_bind_int64(stmt, idx, Int64(n))
            } else if let d = p as? Double {
                sqlite3_bind_double(stmt, idx, d)
            } else if let b = p as? Bool {
                sqlite3_bind_int64(stmt, idx, b ? 1 : 0)
            } else if let n = p as? Int64 {
                sqlite3_bind_int64(stmt, idx, n)
            } else if let n = p as? Int32 {
                sqlite3_bind_int64(stmt, idx, Int64(n))
            } else if let f = p as? Float {
                sqlite3_bind_double(stmt, idx, Double(f))
            } else {
                NSLog("[NOTICE] SQLiteReader.query 不支持的参数类型 %@"
                      + "（占位符 %d 保持 NULL，查询结果可能为空）",
                      String(describing: type(of: p)), idx)
            }
        }
        var rows: [[String: Any]] = []
        var rc = SQLITE_OK
        while true {
            rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }        // 正常结束（没有更多行）
            if rc != SQLITE_ROW {
                // ⚠ step 中途失败 → **丢弃已取到的部分行**：
                //   把"出错"当"正常结尾"、返回半截结果且无报错是危险的，丢弃 = 安全方向。
                NSLog("[ERROR] SQLiteReader.query step 失败 rc=%d → 丢弃已取的 %d 行（不回半截）",
                      rc, rows.count)
                return []
            }
            var row: [String: Any] = [:]
            let colCount = sqlite3_column_count(stmt)
            for i in 0..<colCount {
                let name = String(cString: sqlite3_column_name(stmt, i))
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: row[name] = Int(sqlite3_column_int64(stmt, i))
                case SQLITE_FLOAT: row[name] = Double(sqlite3_column_double(stmt, i))
                case SQLITE_TEXT:
                    // ⚠ 判 nil：TEXT 列在 OOM 等边界下可能返回 NULL 指针，
                    // 裸解引用会崩（而这一层崩了表现是"整个 App 挂掉"，极难归因到某次查询）。
                    row[name] = sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? ""
                case SQLITE_NULL: continue   // 不塞 NSNull：NSNull 非 nil，会让 `?? 0`
                                             // 与 `as? Int` 双双失效 → 该字段在 UI 上空白、
                                             // 甚至整只标的被静默过滤掉
                default: continue
                }
            }
            rows.append(row)
        }
        return rows
    }

    private func parseJSON(_ raw: Any?) -> Any? {
        guard let s = raw as? String, !s.isEmpty else { return nil }
        guard let data = s.data(using: .utf8) else { return nil }
        // ⚠ 解析失败要留痕（2026-10-16 审查 B2）：原先是裸 `try?` → nil →
        //   上层 `jdict()/jarray()` 折成 `[:]`/`[]` —— 于是"整列 payload 坏了"
        //   与"这行本来没有明细"在界面上同形（分数正常显示、深度信息卡空白、零日志）。
        //   最常见成因是列里写进了非法 JSON（如 `inf`/`nan`），已在上游堵住，
        //   这里补最后一道可见性。只记前 80 字符，避免把整份持仓明细灌进系统日志。
        guard let obj = try? JSONSerialization.jsonObject(with: data) else {
            NSLog("[ERROR] DB *_json 列解析失败（前 80 字符）: %@", String(s.prefix(80)))
            return nil
        }
        return obj
    }

    private func jarray(_ raw: Any?) -> Any { parseJSON(raw) ?? [] }
    private func jdict(_ raw: Any?) -> Any { parseJSON(raw) ?? [:] }

    // MARK: - 今日概览

    /// 今日各轮（每轮取最新一次运行）
    public func todayRounds(_ date: String) -> [JSONValue] {
        let rows = query(
            "SELECT id, slot, slot_label, run_time, tier1_count, tier2_count, param_version, market_env_json "
            + "FROM scan_rounds WHERE date=? ORDER BY run_time ASC", [date])
        var bySlot: [Int: JSONValue] = [:]
        for r in rows {
            bySlot[r["slot"] as? Int ?? 0] = JSONValue([
                "round_id": r["id"] ?? 0, "slot": r["slot"] ?? 0,
                "slot_label": r["slot_label"] ?? "", "run_time": r["run_time"] ?? "",
                "tier1_count": r["tier1_count"] ?? 0, "tier2_count": r["tier2_count"] ?? 0,
                "param_version": r["param_version"] ?? "",
                "market_env": jdict(r["market_env_json"]),
            ])
        }
        return RoundPlan.slots.compactMap { bySlot[$0] }

    }

    public func signals(date: String) -> [JSONValue] {
        query("SELECT code, name, signal_type, trend, scores_json FROM signal_classes WHERE date=?", [date])
            .map { JSONValue([
                "code": $0["code"] ?? "", "name": $0["name"] ?? "",
                "signal_type": $0["signal_type"] ?? "", "trend": $0["trend"] ?? "",
                "scores": jdict($0["scores_json"]),
            ]) }
    }

    // MARK: - 轮次明细

    /// 该**选股日**全部轮次的分数快照：`code → [slot: score]`。
    ///
    /// 用途：结果页每行显示"这只票在第 1/2/3 轮各是多少分"。
    /// ⚠ **一次查完**，不是每行查一次 —— 该日 picks 只有几十行，按行查会把
    ///   30 行变成 30 次查询（主视图里同步 I/O 是本项目的大忌）。
    /// ⚠ 走建表时就有的 `idx_picks_date(date, code)` 索引。
    /// ⚠ 缺席的轮次**不填 0**：字典里没有这个 key 就是"那轮没这只票" ——
    ///   与"那轮 0 分"是两件事（`0` 在本项目是**有意义的值**，既有纪律）。
    public func roundScores(date: String) -> [String: [Int: Double]] {
        let rows = query("SELECT code, slot, score FROM picks WHERE date=?", [date])
        var out: [String: [Int: Double]] = [:]
        for r in rows {
            guard let code = r["code"] as? String, !code.isEmpty else { continue }
            guard let slot = Num.intOrNil(r["slot"]), slot > 0 else { continue }
            out[code, default: [:]][slot] = Num.doubleOrZero(r["score"])
        }
        return out
    }

    public func roundDetail(date: String, slot: Int) -> JSONValue? {
        guard let round = query(
            "SELECT * FROM scan_rounds WHERE date=? AND slot=? ORDER BY run_time DESC LIMIT 1",
            [date, slot]).first else { return nil }
        let roundId = round["id"] as? Int ?? 0

        // 注意：这里**不能**写成 ORDER BY COALESCE(score_raw, score) —— 老库未迁移时
        // 该列不存在会让整条查询直接报错、页面全空。排序放到内存里做（见下方 ordered）
        let picks = query("SELECT * FROM picks WHERE round_id=? ORDER BY score DESC", [roundId])
        let pickDicts: [[String: Any]] = picks.map { p in
            [
                "code": p["code"] ?? "", "name": p["name"] ?? "",
                "tier": p["tier"] ?? 3, "score": p["score"] ?? 0,
                // 均线锁档的原始分与资格标记。
                // 列不存在/值为 NULL 时给 NSNull —— 消费端是 JSONValue，能正确识别为 null
                // 并落回 score（这里与"行解析层不塞 NSNull"的规则不冲突：那是为了避免
                // `?? 0` 失效，此处是显式构造给 JSONValue 用的字面量）
                "score_raw": p["score_raw"] ?? NSNull(),
                "ma_qualified": p["ma_qualified"] ?? NSNull(),
                "tier_lock_applied": p["tier_lock_applied"] ?? NSNull(),
                "price": p["price"] ?? 0, "change_pct": p["change_pct"] ?? 0,
                "volume_ratio": p["volume_ratio"] ?? 0, "turnover": p["turnover"] ?? 0,
                "amplitude": p["amplitude"] ?? 0, "amount": p["amount"] ?? 0,
                "avg_price": p["avg_price"] ?? 0,
                "deep_info": jdict(p["deep_info_json"]),
                "score_details": jarray(p["score_details_json"]),
                "penalty_details": jarray(p["penalty_details_json"]),
                "market_weak": p["market_weak"] ?? 0,
            ]
        }

        // 展示排序：一/二档 score == score_raw（未被压制），与 SQL 排序一致；
        // 三档里被均线锁档的票按**原始分**排序，不再出现"78 分与 33 分同为 49、顺序随机"。
        // 只影响展示顺序 —— 档位归属由引擎判定，不受此处影响。
        func shown(_ d: [String: Any]) -> Double {
            let locked = (d["tier_lock_applied"] as? Int ?? 0) == 1
            if locked { return d["score_raw"] as? Double ?? d["score"] as? Double ?? 0 }
            return d["score"] as? Double ?? 0
        }
        let orderedPicks = pickDicts.sorted { shown($0) > shown($1) }

        // 注意：存 [[String: Any]]（勿先包 JSONValue——外层 JSONValue(result) 会二次包装，
        // 数组内 JSONValue 元素无法 as? [String:Any] 而丢失，此前深度排除空数据的根因）
        let excluded: [[String: Any]] = query("SELECT code, name, reason FROM excluded_stocks WHERE round_id=?", [roundId])
            .map { ["code": $0["code"] ?? "", "name": $0["name"] ?? "", "reason": $0["reason"] ?? ""] }

        let etfs: [[String: Any]] = query("SELECT * FROM etf_picks WHERE round_id=? ORDER BY change_pct DESC", [roundId])
            .map { [
                "code": $0["code"] ?? "", "name": $0["name"] ?? "",
                "price": $0["price"] ?? 0, "change_pct": $0["change_pct"] ?? 0,
                "volume_ratio": $0["volume_ratio"] ?? 0, "turnover": $0["turnover"] ?? 0,
                "amount": $0["amount"] ?? 0,
            ] }

        var result: [String: Any] = [
            "status": "ok", "date": date, "slot": slot,
            "slot_label": round["slot_label"] ?? "", "run_time": round["run_time"] ?? "",
            "param_version": round["param_version"] ?? "",
            "market_env": jdict(round["market_env_json"]),
            "stats": [
                "total_scanned": round["total_scanned"] ?? 0,
                "after_hard_filter": round["after_hard_filter"] ?? 0,
                "after_profile_filter": round["after_profile_filter"] ?? 0,
                "after_form_filter": round["after_form_filter"] ?? 0,
                "excluded_count": round["excluded_count"] ?? 0,
                "final_count": round["final_count"] ?? 0,
                "tier1_count": round["tier1_count"] ?? 0,
                "tier2_count": round["tier2_count"] ?? 0,
            ],
            "excluded_deep_trend": excluded,
            "etf_recommendations": etfs,
        ]
        for t in 1...3 {
            result["tier\(t)"] = orderedPicks.filter { ($0["tier"] as? Int) == t }
        }
        return JSONValue(result)
    }

    // MARK: - 报告类

    public func compareReport(date: String) -> JSONValue? {
        guard let r = query("SELECT json FROM compare_reports WHERE date=?", [date]).first,
              let obj = parseJSON(r["json"]) else { return nil }
        return JSONValue(obj)
    }

    public func latestCompareReport() -> JSONValue? {
        guard let r = query("SELECT json FROM compare_reports ORDER BY date DESC LIMIT 1").first,
              let obj = parseJSON(r["json"]) else { return nil }
        return JSONValue(obj)
    }

    public func predict(date: String) -> JSONValue? { predictRow(cond: "date=?", params: [date]) }
    public func latestPredict() -> JSONValue? { predictRow(cond: "date=(SELECT MAX(date) FROM predicts)", params: []) }
    /// 按选股日查预判（历史模式口径：T 日选股 → T+1 日 09:30 生成）
    ///
    /// ⚠ 必须 `ORDER BY date DESC`（2026-10-16 审查 B5-1）：`sel_date` **不是唯一键**
    ///   （`date` 才是 PK），同一选股日可能有多份预判（补跑、重算、导入都会留新行）。
    ///   原先只写 `LIMIT 1` ⇒ 返回的是主键序里**第一条**（实测开发库 `sel_date=2026-09-10`
    ///   有 2 行，本函数返回旧行），而 `PhaseStore.predictRow(selDate:)` 同语义读的是
    ///   `ORDER BY date DESC` 的新行 —— 于是**预判页显示旧的、验证/复盘用新的**，
    ///   两侧都在"正常出结果"，没有任何报错。现在两处口径统一。
    public func predictBySelDate(_ date: String) -> JSONValue? {
        predictRow(cond: "sel_date=?", params: [date], orderBy: "ORDER BY date DESC")
    }

    private func predictRow(cond: String, params: [Any], orderBy: String = "") -> JSONValue? {
        guard let r = query("SELECT date, sel_date, predict_time, market_env_json, stocks_json, is_empty_day, overall_json FROM predicts WHERE \(cond) \(orderBy) LIMIT 1", params).first else { return nil }

        return JSONValue([
            "status": "ok",
            "predict_date": r["date"] ?? "", "sel_date": r["sel_date"] ?? "",
            "predict_time": r["predict_time"] ?? "",
            "market_env": jdict(r["market_env_json"]),
            "stocks": jarray(r["stocks_json"]),
            "is_empty_day": r["is_empty_day"] ?? 0,
            "overall": jarray(r["overall_json"]),
        ])
    }

    public func latestVerify() -> JSONValue? { verifyRow("ORDER BY sel_date DESC", []) }
    /// 按选股日查盘中验证（T 日选股 → T+1 日 10:00 快照）
    public func verifyBySelDate(_ date: String) -> JSONValue? { verifyRow("WHERE sel_date=?", [date]) }

    private func verifyRow(_ cond: String, _ params: [Any]) -> JSONValue? {
        guard let r = query("SELECT sel_date, verify_time, stats_json, detail_json, deviation_json, warnings_json, is_empty_day FROM verifies \(cond) LIMIT 1", params).first else { return nil }
        // 空仓日兜底：旧记录无 is_empty_day 列/值，但 stats 空 + 明细空 → 判定空仓
        let emptyFlag = (r["is_empty_day"] as? NSNumber)?.intValue ?? (r["is_empty_day"] as? Int ?? 0)
        let stats = JSONValue(jdict(r["stats_json"]))
        let detail = JSONValue(jarray(r["detail_json"]))
        let isEmpty = emptyFlag == 1 || (stats.dict.isEmpty && detail.array.isEmpty)
        return JSONValue([
            "status": "ok",
            "sel_date": r["sel_date"] ?? "", "verify_time": r["verify_time"] ?? "",
            "stats": stats.raw, "detail": detail.raw,
            "deviations": jarray(r["deviation_json"]), "warnings": jarray(r["warnings_json"]),
            "is_empty_day": isEmpty,
        ])
    }

    public func latestReview() -> JSONValue? { reviewRow("ORDER BY sel_date DESC", []) }
    /// 按选股日查收盘复盘（T 日 15:05 生成，复盘 T 日选股标的）
    public func reviewBySelDate(_ date: String) -> JSONValue? { reviewRow("WHERE sel_date=?", [date]) }

    private func reviewRow(_ cond: String, _ params: [Any]) -> JSONValue? {
        guard let r = query("SELECT sel_date, review_time, four_layer_json, accuracy_json, stocks_json, is_empty_day, insights_json, reference_json FROM reviews \(cond) LIMIT 1", params).first else { return nil }
        return JSONValue([
            "status": "ok",
            "sel_date": r["sel_date"] ?? "", "review_time": r["review_time"] ?? "",
            "four_layer_winrate": jdict(r["four_layer_json"]),
            "accuracy": jdict(r["accuracy_json"]),
            "stocks": jarray(r["stocks_json"]),
            "is_empty_day": r["is_empty_day"] ?? 0,
            "insights": jarray(r["insights_json"]),
            "reference": jdict(r["reference_json"]),
        ])
    }

    public func latestIterate() -> JSONValue? { iterateRow("ORDER BY trigger_date DESC", []) }
    /// 按触发日查迭代报告（T 日 15:30 生成）
    public func iterateByDate(_ date: String) -> JSONValue? { iterateRow("WHERE trigger_date=?", [date]) }

    private func iterateRow(_ cond: String, _ params: [Any]) -> JSONValue? {
        guard let r = query("SELECT trigger_date, is_empty_day_report, counter, insights_json, empty_trend_json, four_layer_avg_json FROM iterate_reports \(cond) LIMIT 1", params).first else { return nil }
        return JSONValue([
            "trigger_date": r["trigger_date"] ?? "",
            "is_empty_day_report": r["is_empty_day_report"] ?? 0,
            "counter": r["counter"] ?? 0,
            "insights": jarray(r["insights_json"]),
            "empty_trend": jdict(r["empty_trend_json"]),
            "four_layer_avg": jdict(r["four_layer_avg_json"]),
        ])
    }

    // MARK: - 有数据的日期（供级联选择器）

    /// 空仓选股日：三轮齐全且入档（一/二档）为 0。
    /// 复盘/验证对此类日期无标的可算——空态应直接说明空仓，而非显示「未生成」
    public func isPicklessDay(_ date: String) -> Bool {
        let slotsRow = query("SELECT COUNT(DISTINCT slot) AS n FROM scan_rounds WHERE date=? AND status='ok'", [date]).first
        let slots = (slotsRow?["n"] as? NSNumber)?.intValue ?? 0
        guard slots >= 3 else { return false }
        let picksRow = query("SELECT COUNT(*) AS n FROM picks WHERE date=? AND tier<=2", [date]).first
        return ((picksRow?["n"] as? NSNumber)?.intValue ?? 0) == 0
    }

    /// 返回 日期 → 环节位掩码：
    /// bit0 轮次 · bit1 对比 · bit2 预判 · bit3 验证 · bit4 复盘 · bit5 迭代
    public func availableDays() -> [String: Int] {
        var mask: [String: Int] = [:]
        func mark(_ sql: String, _ bit: Int) {
            for r in query(sql) {
                if let d = r["d"] as? String, d.count == 10 {
                    mask[d, default: 0] |= bit
                }
            }
        }
        // 轮次位只认 status='ok'：失败/数据不足的轮次未落库，点亮会导致
        // 管道条/日期点阵/看板"已扫描 x/3"失真（与 isPicklessDay 的有效口径一致）
        mark("SELECT DISTINCT date AS d FROM scan_rounds WHERE status='ok'", 1)
        mark("SELECT DISTINCT date AS d FROM compare_reports", 2)
        mark("SELECT DISTINCT sel_date AS d FROM predicts", 4)
        mark("SELECT DISTINCT sel_date AS d FROM verifies", 8)
        mark("SELECT DISTINCT sel_date AS d FROM reviews", 16)
        mark("SELECT DISTINCT trigger_date AS d FROM iterate_reports", 32)
        return mask
    }

    // MARK: - 历史

    /// 全链路查询（口径：选股日 T）
    /// rounds/compare：T 日发生；predicts：T 日选股 → T+1 执行（按 sel_date=T 查）；
    /// verify/review：验证 T 日选股标的的次日表现（按 sel_date=T 查）
    public func history(date: String) -> JSONValue? {
        // 注意：存 [[String: Any]]（勿先包 JSONValue，外层包装会丢数组内元素——同 excluded 双重包装 bug）
        let rounds: [[String: Any]] = query("SELECT slot, slot_label, run_time, tier1_count, tier2_count FROM scan_rounds WHERE date=? ORDER BY slot", [date])
            .map { [
                "slot": $0["slot"] ?? 0, "slot_label": $0["slot_label"] ?? "",
                "run_time": $0["run_time"] ?? "",
                "tier1_count": $0["tier1_count"] ?? 0, "tier2_count": $0["tier2_count"] ?? 0,
            ] }
        // 同 `predictBySelDate`：`sel_date` 非唯一，必须显式取最新一份（审查 B5-1）
        let predict = predictRow(cond: "sel_date=?", params: [date], orderBy: "ORDER BY date DESC")
        let verify = query("SELECT sel_date, verify_time FROM verifies WHERE sel_date=?", [date]).first
        let review = query("SELECT sel_date, review_time, four_layer_json FROM reviews WHERE sel_date=?", [date]).first
        let iterate = query("SELECT trigger_date, counter, insights_json FROM iterate_reports WHERE trigger_date=?", [date]).first
        let compare = compareReport(date: date)

        if rounds.isEmpty && predict == nil && verify == nil && review == nil && iterate == nil && compare == nil {
            return nil
        }
        var obj: [String: Any] = ["date": date, "rounds": rounds]
        obj["predict"] = predict?.raw ?? NSNull()
        obj["compare"] = compare?.raw ?? NSNull()
        if let v = verify {
            obj["verify"] = ["sel_date": v["sel_date"] ?? "", "verify_time": v["verify_time"] ?? ""]
        } else { obj["verify"] = NSNull() }
        if let r = review {
            obj["review"] = ["sel_date": r["sel_date"] ?? "", "review_time": r["review_time"] ?? "",
                             "four_layer": jdict(r["four_layer_json"])]
        } else { obj["review"] = NSNull() }
        if let it = iterate {
            obj["iterate"] = ["trigger_date": it["trigger_date"] ?? "", "counter": it["counter"] ?? 0,
                              "insights": jarray(it["insights_json"])]
        } else { obj["iterate"] = NSNull() }
        return JSONValue(obj)
    }

    // MARK: - 自选股（watch 模块）

    /// 自选分组列表（含每组股票数/持仓数；默认组排最前）
    ///
    /// ⚠ **默认组（id=1）= 「所有分组的去重总量」视图**：
    ///   计数直接取 `watchlist` 全表（一只票一行 ⇒ 天然去重），**不数归属表里 `group_id=1` 的行**。
    ///   这样"从默认组复制到/移动到别的组"都不会让默认组的数掉下来。
    public func watchGroups() -> [JSONValue] {
        // ⚠ 非默认组计数按**归属表**：一只股票可以同时在多个分组，
        //   而 `watchlist.group_id` 只存**主分组**（归属里最小的那个）。
        //   若仍按 `group_id` 统计，"复制到分组"出来的票在目标分组里
        //   会**列表有它、胶囊计数却是 0**。
        let byMembership =
            "SELECT g.id, g.name, "
            + "(CASE WHEN g.id=1 THEN (SELECT COUNT(*) FROM watchlist) "
            + "        ELSE (SELECT COUNT(*) FROM watch_group_members m WHERE m.group_id=g.id) END) AS stock_count, "
            + "(CASE WHEN g.id=1 THEN (SELECT COUNT(*) FROM watchlist WHERE is_holding=1) "
            + "        ELSE (SELECT COUNT(*) FROM watch_group_members m JOIN watchlist w ON w.code=m.code "
            + "              WHERE m.group_id=g.id AND w.is_holding=1) END) AS holding_count "
            + "FROM watch_groups g ORDER BY (g.id=1) DESC, g.id ASC"
        // ⚠ 降级：归属表由 `DBBootstrap.ensureSwiftOnlySchema` 建好并灌数据，
        //   但那条路径失败时**只 NSLog**（不改 `ensureReady` 的返回值）。
        //   真出现那种情况，上面那条 SQL 会报错 → `query` 返回 `[]` → **整排胶囊全空**
        //   （看起来像"自选全丢了"）。宁可计数少算，也要回落到旧口径把分组显示出来。
        let legacy =
            "SELECT g.id, g.name, "
            + "(CASE WHEN g.id=1 THEN (SELECT COUNT(*) FROM watchlist) "
            + "        ELSE (SELECT COUNT(*) FROM watchlist w WHERE w.group_id=g.id) END) AS stock_count, "
            + "(CASE WHEN g.id=1 THEN (SELECT COUNT(*) FROM watchlist WHERE is_holding=1) "
            + "        ELSE (SELECT COUNT(*) FROM watchlist w WHERE w.group_id=g.id AND w.is_holding=1) END) AS holding_count "
            + "FROM watch_groups g ORDER BY (g.id=1) DESC, g.id ASC"
        var rows = query(byMembership)
        if rows.isEmpty { rows = query(legacy) }
        return rows.map { JSONValue([
            "id": $0["id"] ?? 0, "name": $0["name"] ?? "",
            "stock_count": $0["stock_count"] ?? 0,
            "holding_count": $0["holding_count"] ?? 0,
        ]) }
    }

    /// 自选列表（含分组与手动持仓信息 + 最近一次判定动作/得分）
    public func watchlist() -> [JSONValue] {
        let rows = query(
            "SELECT w.code, w.name, w.added_at, w.group_id, w.is_holding, w.cost_price, w.shares, "
            + "j.action, j.score, j.target_price, j.stop_loss_price "
            + "FROM watchlist w LEFT JOIN watch_judgments j "
            + "ON j.code = w.code AND j.date = (SELECT MAX(date) FROM watch_judgments) "
            + "ORDER BY w.added_at")
        return rows.map { JSONValue([
            "code": $0["code"] ?? "", "name": $0["name"] ?? "",
            "added_at": $0["added_at"] ?? "",
            "group_id": $0["group_id"] ?? 1,
            "is_holding": $0["is_holding"] ?? 0,
            "cost_price": $0["cost_price"] ?? 0, "shares": $0["shares"] ?? 0,
            "action": $0["action"] ?? "", "score": $0["score"] ?? 0,
            "target_price": $0["target_price"] ?? 0, "stop_loss_price": $0["stop_loss_price"] ?? 0,
        ]) }
    }

    /// 某日全量判定（右侧判定卡 + 触碰提醒的数据源）
    public func watchJudgments(date: String) -> [JSONValue] {
        query(
            "SELECT code, name, action, score, details_json, target_price, stop_loss_price, "
            + "baseline_price, sell_window, position_advice, risk_level, market_light "
            + "FROM watch_judgments WHERE date=? ORDER BY code", [date])
            .map { JSONValue([
                "code": $0["code"] ?? "", "name": $0["name"] ?? "",
                "action": $0["action"] ?? "", "score": $0["score"] ?? 0,
                "details": jdict($0["details_json"]) ?? [:],
                "target_price": $0["target_price"] ?? 0, "stop_loss_price": $0["stop_loss_price"] ?? 0,
                "baseline_price": $0["baseline_price"] ?? 0,
                "sell_window": $0["sell_window"] ?? "",
                "position_advice": $0["position_advice"] ?? "",
                "risk_level": $0["risk_level"] ?? "",
                "market_light": $0["market_light"] ?? "",
            ]) }
    }

    /// 个股判定历史（近 N 日，轨迹条用）
    public func watchHistory(code: String, days: Int = 14) -> [JSONValue] {
        // ⚠ `days` 必须夹住并改成**绑定参数**（2026-10-16 审查 B2）：
        //   `LIMIT -1` 在 SQLite 里的语义是**不限**，`LIMIT 0` 是空 —— 而 `days` 是
        //   公开 API 的 Int 入参（调用方常从数据算出来，如 `count - offset`）。
        //   一旦传进 0/负值，"只要 14 条"就变成"整张 `watch_judgments` 全捞进内存"，
        //   在主线程读路径上直接放大成卡顿。同文件 `recentReviewWinrates` 是夹住的，
        //   这里是漏的那一个。
        let n = max(1, min(days, 400))
        return query(
            "SELECT date, action, score, target_price, stop_loss_price FROM watch_judgments "
            + "WHERE code=? ORDER BY date DESC LIMIT ?", [code, n])
            .map { JSONValue([
                "date": $0["date"] ?? "", "action": $0["action"] ?? "",
                "score": $0["score"] ?? 0,
                "target_price": $0["target_price"] ?? 0, "stop_loss_price": $0["stop_loss_price"] ?? 0,
            ]) }
            .reversed()
    }

    /// 自选判定最近日期（判断今日是否已判定）
    public func latestWatchDate() -> String? {
        (query("SELECT MAX(date) AS d FROM watch_judgments", []).first?["d"] as? String)
    }

    // MARK: - 四层胜率跨日走势（与复盘页同口径）

    /// 近 N 个**有样本**复盘的选股日四层胜率（升序返回，供走势折线图）。
    ///
    /// 过滤规则：空仓日 / 红灯全 skipped 日的四层是全 0 结构（winrate=0,total=0），
    /// 画进走势图会形成"胜率跳水"的假信号 —— 只保留 window.total>0 的日子。
    /// 老记录 four_layer_json 缺层（如 disciplined/gap）时按 0 处理，不影响四层主图。
    public func recentReviewWinrates(limit: Int = 20) -> [JSONValue] {
        // ⚠ limit 加上界：调用方"全部"档可能传很大的值（本函数再乘 2 去过滤无样本日）
        //   ⇒ 无上界等于"把整张表连同 four_layer_json 全捞出来逐行 JSON 解析"，
        //   代价在 Swift 侧逐行 `jdict()`，随行数线性放大。
        //   2 万条 ≈ 80 年日复盘，到这个量级说明用法变了（该改按日期范围查），
        //   而不是继续放大 limit。
        let n = min(max(limit, 1), 20_000)
        let rows = query(
            "SELECT sel_date, four_layer_json FROM reviews "
            + "WHERE is_empty_day=0 ORDER BY sel_date DESC LIMIT ?", [n * 2])
        var out: [JSONValue] = []
        for r in rows {
            guard let date = r["sel_date"] as? String,
                  let fl = jdict(r["four_layer_json"]) as? [String: Any] else { continue }
            let win = (fl["window"] as? [String: Any]) ?? [:]
            let total = (win["total"] as? Int) ?? 0
            guard total > 0 else { continue }   // 全 0 结构 = 无样本日
            func wr(_ layer: String) -> Double {
                let d = (fl[layer] as? [String: Any]) ?? [:]
                if let v = d["winrate"] as? Double { return v }
                if let v = d["winrate"] as? Int { return Double(v) }
                return 0
            }
            out.append(JSONValue([
                "date": date,
                "snapshot": wr("snapshot"), "close": wr("close"),
                "window": wr("window"), "ceiling": wr("ceiling"),
            ]))
            if out.count >= limit { break }
        }
        return out.reversed()   // DESC 查询 → 反转成升序（图从左到右为时间序）
    }

    /// 近 N 个有样本选股日的「多观察窗」**原始行**。
    ///
    /// ⚠ 返回**原始行**而不是 SQL 聚合结果：浮点求和必须走 `PyMath.sum`
    ///   （SQLite 的 `SUM`/`AVG` 是朴素加法，`[1e16, 1, -1e16]` 会丢掉那个 1）。
    ///   聚合由 `MultiWindowSummary.make(rows:)` 做。
    /// ⚠ `skipped = 0`：红灯日空仓的标的不参与统计（与 `PhaseTune.actualMapFor` 同口径）。
    /// ⚠ 取「最近 N 个**有样本**的选股日」而不是「最近 N 天」：没跑过复盘的日期
    ///   `stock_outcomes` 里没有行，按天取会让样本白白变少（与 `recentReviewWinrates` 同款）。
    /// ⚠ `t3_close_pct` / `t5_close_pct` 在**库升级后**才存在；列不存在时 SQL 直接失败返回 `[]`
    ///   → 界面走空态，不崩。
    public func recentOutcomeWindowRows(limit: Int = 20) -> [[String: Any]] {
        let days = query(
            "SELECT DISTINCT sel_date FROM stock_outcomes WHERE skipped = 0"
            + " ORDER BY sel_date DESC LIMIT ?", [limit]).compactMap { $0["sel_date"] as? String }
        guard !days.isEmpty else { return [] }
        let marks = Array(repeating: "?", count: days.count).joined(separator: ",")
        return query(
            "SELECT sel_date, disc_profit, close_profit, t3_close_pct, t5_close_pct"
            + " FROM stock_outcomes WHERE skipped = 0 AND sel_date IN (\(marks))"
            + " ORDER BY sel_date ASC, code ASC", days)
    }

    // MARK: - 参数版本
    //
    // ⚠ 参数版本列表**不在这里**：唯一权威实现是 `ParamStore.listVersions()`
    //   （带 `deletable` 裁决）。本类不得再有一份只读副本 ——
    //   副本会与权威实现漂移（规则改了、界面仍按旧口径显示）。

    /// 证券列表（securities 表缓存，个股搜索用）。
    ///
    /// 与取数层共用 `securities` 表（写入见 SecuritiesCache，写入前必经 clean_name，
    /// 故这里不再清洗 NUL 名称）。表不存在（老库未建库/迁移）或表为空时返回 []。
    public func stockList() -> [JSONValue] {
        query("SELECT code, name FROM securities ORDER BY code").map { row in
            JSONValue(["code": row["code"] ?? "", "name": row["name"] ?? ""])
        }
    }
}

// MARK: - 实时行情（URLSession 直连）

public enum LiveQuotes {
    private static let gbk: String.Encoding = {
        let cf = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        return String.Encoding(rawValue: cf)
    }()

    /// ⚠ 失败重试 1 次再放弃：偶发限流/超时会让看板「3 日趋势 / 连跌检测」整块缺失
    ///   且界面无提示（腾讯这类瞬时故障多为"立即重试即成功"）；两次之间稍停，避免踩限流窗口。
    private static func retryOnce<T>(_ work: () async -> T?) async -> T? {
        for attempt in 0..<2 {
            if let r = await work() { return r }
            if attempt == 0 { try? await Task.sleep(for: .milliseconds(300)) }
        }
        return nil
    }

    /// 上证指数实时行情
    public static func fetchIndex(symbol: String = "sh000001") async -> JSONValue? {
        await Self.retryOnce {
            guard let url = URL(string: DataSourceEndpoints.tencentQuotes + symbol) else { return nil }
            var req = URLRequest(url: url, timeoutInterval: 8)
            req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
            do {
                let data = try await HTTPFetch.get(req)
                guard let text = String(data: data, encoding: gbk),
                      let payload = text.components(separatedBy: "=\"").last?
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\";\n\r"))
                else { return nil }
                let f = payload.split(separator: "~", omittingEmptySubsequences: false).map(String.init)
                guard f.count > 40, let price = Double(f[3]), price > 0 else { return nil }
                return JSONValue([
                    "price": price,
                    "pre_close": Double(f[4]) ?? 0,
                    "change_pct": Double(f[32]) ?? 0,
                    "high": Double(f[33]) ?? 0,
                    "low": Double(f[34]) ?? 0,
                ])
            } catch {
                // ⚠ 失败不能无痕（"指数一直不动"要能排障），但只 NSLog：
                //   **不写 `data_source_logs`** —— 本函数 60s 轮询一次，写库会淹掉诊断页。
                //   UI 上不提示是有意的：顶栏有时间戳可看出"多久没更新"，
                //   60s 一次的抖动提示只会变噪声。
                NSLog("[NOTICE] 实时指数抓取失败（保留旧值，60s 后重试）：%@", String(describing: error))
                return nil
            }
        }
    }

    /// 腾讯日K**单行**解析：取出「非今日」那一行的收盘价；不适用返回 `nil`。
    ///
    /// `day` 行的形态是 `[date, open, close, high, low, volume]`。
    ///
    /// ⚠ **必须先校验行长度**：任一行字段数 < 3（接口改版 / 半截响应 / 空行）即越界
    ///   trap，而 Swift 数组越界**不可 catch**（用户只能重启）；本函数被看板与大盘灯
    ///   调用，崩溃点在解析外部数据处。
    /// ⚠ 抽成**纯函数**是为了能被 `swift test` 覆盖（「短行不崩」用例）：
    ///   内联在 `for` 循环里的话，把守卫删掉**没有任何测试会变红**。
    static func klineRowClose(_ row: [Any], today: String) -> Double? {
        guard row.count >= 3,
              let date = row[0] as? String, date != today,
              let close = Double(String(describing: row[2])), close > 0 else { return nil }
        return close
    }

    /// 最近 3 个完成交易日的上证涨跌幅（腾讯日K，天然排除周末/节假日；不含今天）
    /// 返回 "前日+0.20% 昨日+0.28%"（与引擎 sh_3d_trend 文案同格式）
    public static func fetch3DayTrend() async -> String? {
        // ⚠ 失败重试 1 次再放弃（同 `retryOnce`，看板路径不可静默缺失）
        await Self.retryOnce {
            guard let url = URL(string: DataSourceEndpoints.tencentKLine + "?param=sh000001,day,,,7,qfq") else { return nil }
            var req = URLRequest(url: url, timeoutInterval: 8)
            req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
            do {
                let data = try await HTTPFetch.get(req)
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let d = json["data"] as? [String: Any],
                      let idx = d["sh000001"] as? [String: Any],
                      let day = idx["day"] as? [[Any]] else { return nil }
                let f = ChinaTime.dayFormatter
                let today = f.string(from: Date())
                // day 行: [date, open, close, high, low, volume]
                var closes: [Double] = []
                for row in day {
                    // 解析走纯函数 `klineRowClose`（行长度校验在那里，被「短行不崩」测试钉住）。
                    if let close = Self.klineRowClose(row, today: today) { closes.append(close) }
                }
                guard closes.count >= 4 else { return nil }
                let t = Array(closes.suffix(4))   // t0 基准 + 最近 3 个完成交易日
                let c2 = (t[2] / t[1] - 1) * 100   // 前日
                let c3 = (t[3] / t[2] - 1) * 100   // 昨日
                return String(format: "前日%+.2f%% 昨日%+.2f%%", c2, c3)
            } catch {
                return nil
            }
        }
    }

    /// 最近完成交易日的上证涨跌幅序列（不含今日，从最近到最远），如 [昨日, 前日, 大前日, …]
    /// 供看板"实时灯"判定：结合今日实时涨跌推算盘中连续下跌天数
    public static func fetchRecentDiffs() async -> [Double]? {
        // ⚠ 失败重试 1 次再放弃（同 `retryOnce`，连跌检测不可静默缺失）
        await Self.retryOnce {
            guard let url = URL(string: DataSourceEndpoints.tencentKLine + "?param=sh000001,day,,,8,qfq") else { return nil }
            var req = URLRequest(url: url, timeoutInterval: 8)
            req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
            do {
                let data = try await HTTPFetch.get(req)
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let d = json["data"] as? [String: Any],
                      let idx = d["sh000001"] as? [String: Any],
                      let day = idx["day"] as? [[Any]] else { return nil }
                let f = ChinaTime.dayFormatter
                let today = f.string(from: Date())
                var closes: [Double] = []
                for row in day {
                    if let close = Self.klineRowClose(row, today: today) { closes.append(close) }
                }
                guard closes.count >= 5 else { return nil }
                let t = Array(closes.suffix(5))          // t0 基准 + 最近 4 个完成交易日
                var diffs: [Double] = []
                for i in stride(from: t.count - 1, through: 1, by: -1) {
                    diffs.append((t[i] / t[i - 1] - 1) * 100)
                }
                return diffs                            // [昨日, 前日, …]
            } catch {
                return nil
            }
        }
    }
}
