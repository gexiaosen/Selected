import Foundation
import SQLite3

/// 历史日K缓存 —— **独立库** `history.sqlite3`
///
/// ## 为什么独立库，而不是塞进主库
/// 这是**纯缓存**：5 千只 × 1145 根 ≈ **570 万行 / 约 300–400 MB**。
/// 放进主库会让备份、导入、迁移、schema 检查全部变重，而它随时可以删掉重下。
///
/// ## 为什么必须能断点续传
/// 全市场一次下载约 5000 请求 / 10–20 分钟。中途断网、退出、被调度器打断都是常态，
/// 不能每次都从头再来 → `bar_coverage` 记每只票**已覆盖的日期区间**，
/// 下次只补「没覆盖到区间」的票。
///
/// ## ⚠ 连接契约
/// 自持一个 **读写** 连接 + 串行队列。**不要**改用 `SQLiteReader.shared`：
/// 那是主线程专用的共享连接，而本模块的读写会被后台任务调用 ——
/// Apple 系统 libsqlite3 是 multi-thread 模式（非 serialized），
/// **同一连接跨线程并发直接 SIGSEGV**。
///
/// ## ⚠ 存的是**数据源原值**，不是引擎口径
/// `amount` 存**元**（东财原值），引擎口径是**万元** —— 换算放在重建层
/// （`HistoryReplay.quote`）。存原始值、在边界处换算，这样缓存不绑定任何消费方口径。
public enum HistoryBarStore {

    /// 缓存文件名（与主库同目录，由 `DataDirectory.resolve()` 决定）
    public static let fileName = "history.sqlite3"

    /// 建表 DDL。`IF NOT EXISTS` 天然幂等，每次打开都跑一遍。
    ///
    /// 主键 `(code, day)`：同一只票同一天只有一根，`INSERT OR REPLACE` 即可重跑。
    /// 另建 `idx_daily_bars_day`：重建「某一天的全市场」是**按日**查的
    /// （`SELECT ... WHERE day = ?`），主键索引（code 在前）帮不上忙。
    static let createSQL = """
    CREATE TABLE IF NOT EXISTS daily_bars (
        code       TEXT NOT NULL,
        day        TEXT NOT NULL,
        open       REAL NOT NULL DEFAULT 0,
        close      REAL NOT NULL DEFAULT 0,
        high       REAL NOT NULL DEFAULT 0,
        low        REAL NOT NULL DEFAULT 0,
        volume     REAL NOT NULL DEFAULT 0,
        amount     REAL NOT NULL DEFAULT 0,
        amplitude  REAL NOT NULL DEFAULT 0,
        change_pct REAL NOT NULL DEFAULT 0,
        turnover   REAL NOT NULL DEFAULT 0,
        PRIMARY KEY (code, day)
    );
    CREATE INDEX IF NOT EXISTS idx_daily_bars_day ON daily_bars(day);
    CREATE TABLE IF NOT EXISTS index_bars (
        code       TEXT NOT NULL,
        day        TEXT NOT NULL,
        open       REAL NOT NULL DEFAULT 0,
        close      REAL NOT NULL DEFAULT 0,
        high       REAL NOT NULL DEFAULT 0,
        low        REAL NOT NULL DEFAULT 0,
        volume     REAL NOT NULL DEFAULT 0,
        amount     REAL NOT NULL DEFAULT 0,
        amplitude  REAL NOT NULL DEFAULT 0,
        change_pct REAL NOT NULL DEFAULT 0,
        turnover   REAL NOT NULL DEFAULT 0,
        PRIMARY KEY (code, day)
    );
    CREATE TABLE IF NOT EXISTS bar_coverage (
        code       TEXT PRIMARY KEY,
        req_beg    TEXT NOT NULL DEFAULT '',
        req_end    TEXT NOT NULL DEFAULT '',
        bars       INTEGER NOT NULL DEFAULT 0,
        fetched_at TEXT NOT NULL DEFAULT ''
    );
    """

    /// ⚠ 指数**单独一张表**，不塞进 `daily_bars`。
    ///
    /// 理由：重建「某一天的全市场」是 `SELECT … FROM daily_bars WHERE day = ?` ——
    /// 指数若混在里面，`sh000001` 会被当成一只"股票"混进行情字典，
    /// 而它的 `volume` 量级与个股完全不同（上证成交量约 4 亿手），
    /// 会污染硬过滤的统计口径。分表之后两个查询各自无歧义。
    public static let indexTable = "index_bars"

    /// 某只票**已按哪个窗口请求过**（断点续传的依据）
    ///
    /// ⚠ **存的是「请求的窗口」，不是「数据实际覆盖的区间」** —— 这一条不显眼但必须守住：
    /// 东财最早只给到约 2022-01-04，若按「实际覆盖区间」记，用 `beg=2020-01-01` 请求后
    /// `reqBeg` 会变成 `2022-01-04 > 2020-01-01` → `covers` 恒为假 → **每次启动都重下全市场**
    /// （5000 请求 / 10–20 分钟），而且不报错，只表现为"下载好像从来没完成过"。
    ///
    /// 反过来，存请求窗口也有个边界：改小 `beg`（想多要几年）会让 `reqBeg > beg` → 判定
    /// "未覆盖" → 重下。这是**安全方向**（重下的代价是时间，漏下的代价是静默缺数据）。
    public struct Coverage: Equatable, Sendable {
        /// 请求窗口的起点（`yyyy-MM-dd`）
        public let reqBeg: String
        /// 请求窗口的终点
        public let reqEnd: String
        /// 那次请求实际落库的根数（0 = 请求成功但源没有数据，如退市票）
        public let bars: Int
        /// 该票**是否已按 `[beg, end]` 请求过**（断点续传的判据）
        public func covers(beg: String, end: String) -> Bool {
            !reqBeg.isEmpty && !reqEnd.isEmpty && reqBeg <= beg && reqEnd >= end
        }
    }

    /// 缓存整体概况（界面与自检用）
    public struct Stats: Equatable, Sendable {
        public let codes: Int
        public let bars: Int
        /// 指数 bar 的根数（与个股分开计数）
        public let indexBars: Int
        public let firstDay: String
        public let lastDay: String
        public var isEmpty: Bool { bars == 0 }
    }

    private static let db = HistoryDB()

    // MARK: - 写

    /// 批量落库（同一 `(code, day)` 覆盖写，故可安全重跑）。返回写入行数。
    ///
    /// ⚠ **必须整批一个事务**：570 万行逐条提交是分钟级 vs 小时级的差别；
    /// 而且半截提交会留下「这个交易日只有一半票」的缓存 —— 那种数据比没有更糟：
    /// 重建出来的市场快照看起来正常，但候选池缺了一大片，且**没有任何信号**。
    @discardableResult
    public static func save(_ bars: [HistoryBar]) throws -> Int {
        try save(bars, into: "daily_bars")
    }

    /// 落**指数**日K（同一套字段，表不同 —— 见 `indexTable` 的理由）
    @discardableResult
    public static func saveIndex(_ bars: [HistoryBar]) throws -> Int {
        try save(bars, into: indexTable)
    }

    private static func save(_ bars: [HistoryBar], into table: String) throws -> Int {
        guard !bars.isEmpty else { return 0 }
        return try db.write { h in
            try exec(h, "BEGIN IMMEDIATE")
            do {
                let sql = "INSERT OR REPLACE INTO \(table)"
                    + "(code, day, open, close, high, low, volume, amount, amplitude, change_pct, turnover)"
                    + " VALUES(?,?,?,?,?,?,?,?,?,?,?)"
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(h, sql, -1, &stmt, nil) == SQLITE_OK, let st = stmt else {
                    throw SQLiteWriteError(message: "prepare 失败：\(errmsg(h))")
                }
                defer { sqlite3_finalize(st) }
                for b in bars {
                    sqlite3_reset(st)
                    sqlite3_clear_bindings(st)
                    bindText(st, 1, b.code)
                    bindText(st, 2, b.day)
                    for (i, v) in [b.open, b.close, b.high, b.low, b.volume,
                                   b.amount, b.amplitude, b.changePct, b.turnover].enumerated() {
                        sqlite3_bind_double(st, Int32(i + 3), v)
                    }
                    guard sqlite3_step(st) == SQLITE_DONE else {
                        throw SQLiteWriteError(message: "写入失败：\(errmsg(h))（\(b.code) \(b.day)）")
                    }
                }
                try exec(h, "COMMIT")
            } catch {
                // 回滚失败不能丢弃：事务会**留在连接上**，而 `HistoryDB` 是**长驻缓存连接**
                // （不像 `SQLiteWriter` 那样可丢），之后每次 `BEGIN IMMEDIATE` 都报
                // "cannot start a transaction within a transaction" → 历史K缓存**整轮写入全废**。
                // 判定与日志与 `SQLiteWriter.performWrite` **共用**（`SQLiteTxn`）；
                // 丢弃动作由本处做 —— 连接是 `HistoryDB` 自持的。
                if SQLiteTxn.rollbackOrDiscard(h, error: error) {
                    // ⚠ 必须走 `discardHandleLocked()` 而**不是** `db.reset()`：
                    //   后者内部是 `queue.sync`，而我们已经在该队列上（嵌套同步 = 死锁）。
                    db.discardHandleLocked()
                }
                throw error
            }
            return bars.count
        }
    }

    /// 记一只票**已按哪个窗口请求过**（断点续传的依据）。
    ///
    /// ⚠ 传 `[beg, end]` 是**请求窗口**，不是返回数据里的首尾日期 —— 见 `Coverage` 的注释。
    public static func markCoverage(code: String, reqBeg: String, reqEnd: String,
                                    bars: Int, at stamp: String) throws {
        try db.write { h in
            try exec(h, "INSERT OR REPLACE INTO bar_coverage"
                + "(code, req_beg, req_end, bars, fetched_at) VALUES(?,?,?,?,?)",
                     [code, reqBeg, reqEnd, Double(bars), stamp])
        }
    }

    // MARK: - 读

    /// 已覆盖区间的全表（`code → Coverage`）
    public static func coverage() -> [String: Coverage] {
        var out: [String: Coverage] = [:]
        for row in db.query("SELECT code, req_beg, req_end, bars FROM bar_coverage", []) {
            guard let code = row["code"] as? String else { continue }
            out[code] = Coverage(reqBeg: row["req_beg"] as? String ?? "",
                                 reqEnd: row["req_end"] as? String ?? "",
                                 bars: row["bars"] as? Int ?? 0)
        }
        return out
    }

    /// 丢弃已打开的连接 —— 下次访问重新按 `DataDirectory.resolve()` 解析路径。
    ///
    /// **为什么需要**：`HistoryDB` 把句柄**缓存**在静态实例里，而 `DataDirectory.resolve()`
    /// 支持 `SELECTED_DATA_DIR` 切换。不重置的话，"换了数据目录"之后所有读写仍打在**旧目录**上，
    /// 而且**不会报错**。测试要把缓存指向临时目录时同样必须先调它。
    ///
    /// ⚠ 调用方负责保证没有并发读写在进行（本方法不取 `HistoryDB` 的串行队列）。
    public static func invalidateConnection() { db.reset() }

    // MARK: - 空洞回收

    /// 空洞率超过这个比例才值得 VACUUM。
    ///
    /// ## 阈值怎么定的
    /// 生产库曾出现空洞率 99.98%（三张表各 0 行、文件仍 176 MB）；
    /// 在副本上实测 `VACUUM`：177 MB → 32 KB、0.01 秒，`integrity_check` = ok。
    ///
    /// ## 为什么是 50% 而不是"只要有空洞就回收"
    /// `VACUUM` 要**重写整个库**（拿写锁、生成新文件、再换回来）。正常使用的库
    /// 空洞率个位数很正常，为此付一次全库重写不划算 ⇒ 只在**过半**时才做。
    static let vacuumFreelistRatio = 0.5

    /// 当前库的空洞情况（页数 / 空闲页 / 空洞率）。供 UI 与自检脚本显示。
    ///
    /// ⚠ 打不开 / 表不存在时返回 `nil`（"没这个库"不是异常，见 `probeFreelist`）。
    public static func spaceReport() -> (pageSize: Int, pageCount: Int, freeCount: Int, ratio: Double)? {
        probeFreelist()
    }

    private static func probeFreelist() -> (pageSize: Int, pageCount: Int, freeCount: Int, ratio: Double)? {
        // ⚠ `DataDirectory.resolve()` 返回**非可选** String（无 `as String?`）
        let path = DataDirectory.resolve() + "/" + HistoryBarStore.fileName
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var handle: OpaquePointer?
        // ⚠ 用**独立句柄**而不是 `HistoryDB` 的缓存连接：`PRAGMA freelist_count`
        //   读的是连接自己的视图，而 VACUUM 之后缓存连接持有的旧页数不会更新
        //   ⇒ 复用它会让「回收后仍报高空洞率」。
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db = handle else { return nil }
        defer { sqlite3_close(db) }
        func intpragma(_ name: String) -> Int {
            var st: OpaquePointer?
            guard sqlite3_prepare_v2(db, "PRAGMA \(name)", -1, &st, nil) == SQLITE_OK,
                  let st else { return 0 }
            defer { sqlite3_finalize(st) }
            return sqlite3_step(st) == SQLITE_ROW ? Int(sqlite3_column_int64(st, 0)) : 0
        }
        let pageCount = intpragma("page_count")
        let freeCount = intpragma("freelist_count")
        let pageSize = intpragma("page_size")
        guard pageCount > 0 else { return nil }
        return (pageSize, pageCount, freeCount, Double(freeCount) / Double(pageCount))
    }

    /// 文件字节数（取不到返回 0 —— 调用方只用于「回收了多少」的信息展示）。
    private static func fileSize(_ path: String) -> Int {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.size] as? NSNumber)?.intValue ?? 0
    }

    /// 回收空洞：超过 `vacuumFreelistRatio` 时执行 `VACUUM`。
    ///
    /// ## 为什么 App 需要它
    /// 这个库会被反复"全量替换"（下载日K缓存 → 清空 → 再下载），
    /// 而 SQLite 的 `DELETE` 只把页挂到 freelist、**不归还给文件系统** ⇒
    /// 文件只会单调变大，可以出现"99.98% 是空洞"的状态。
    /// `DBBootstrap.maintenance()` 只管主库 `selected.sqlite3`，**从不探测本库** ——
    /// 没人回收就没人报警。
    ///
    /// ## 安全性
    /// · 只在**启动期**调（与 `DBBootstrap.maintenance` 同一时机），此时无并发读写；
    /// · `VACUUM` 本身事务安全，中途失败不会损坏数据（SQLite 保证）；
    /// · 跑之前先 `wal_checkpoint(TRUNCATE)`，避免 WAL 也被搬一遍；
    /// · 回收后 `invalidateConnection()` —— 缓存句柄持有的是旧文件的页视图。
    ///
    /// - Returns: 回收前后的字节数（未回收时 `before == after`），供日志与自检断言。
    @discardableResult
    public static func reclaimSpaceIfHollow() -> (before: Int, after: Int) {
        let path = DataDirectory.resolve() + "/" + fileName
        let before = fileSize(path)
        guard let r = spaceReport(), r.ratio >= vacuumFreelistRatio else {
            return (before, before)
        }
        NSLog("[NOTICE] history 库空洞率 %.1f%%（%d/%d 页），执行 VACUUM",
              r.ratio * 100, r.freeCount, r.pageCount)
        // ⚠ **用独立句柄，不走 `db.write`**：`db.write` 会先 `open()`，而 `open()` 内部跑
        //   **建表语句** —— 一旦库里的表结构与当前 schema 有差异，就会在 `open()` 阶段
        //   报「建表失败」而**根本走不到 VACUUM**。VACUUM 是**纯文件级操作**，
        //   不需要表结构正确 ⇒ 自己开句柄最稳。
        //   同时先 `wal_checkpoint(TRUNCATE)`：否则 VACUUM 要把 WAL 里的帧也搬一遍。
        var h: OpaquePointer?
        guard sqlite3_open_v2(path, &h, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db = h else {
            NSLog("[ERROR] history 库 VACUUM 跳过：无法以读写方式打开")
            if let h { sqlite3_close(h) }
            return (before, before)
        }
        var closed = false
        defer { if !closed { sqlite3_close(db) } }
        // 与项目其余 SQLite 调用一致：自检/维护不该因一次撞锁就失败
        sqlite3_busy_timeout(db, 30_000)
        // checkpoint 失败不阻断回收（它只是"少搬一遍 WAL"的优化）
        do {
            try exec(db, "PRAGMA wal_checkpoint(TRUNCATE)")
        } catch {
            NSLog("[NOTICE] history 库 wal_checkpoint 未完成（可能有其它连接持锁）：%@",
                  String(describing: error))
        }
        do {
            try exec(db, "VACUUM")
        } catch {
            NSLog("[ERROR] history 库 VACUUM 失败：%@", String(describing: error))
            return (before, before)
        }
        // ⚠ 必须**先关句柄再量大小**：`defer` 此刻还没执行，而未关闭的连接仍持有
        //   WAL/临时文件 ⇒ `attributesOfItem` 量到的是**回收前**的尺寸 ⇒
        //   日志出现「回收 0.0 MB」而 `ls` 显示 32 KB 的自相矛盾。回收本身是成功的，只是量错了时机。
        sqlite3_close(db)
        closed = true
        let after = fileSize(path)
        NSLog("[NOTICE] history 库 VACUUM 完成：%d → %d 字节（回收 %.1f MB）",
              before, after, Double(before - after) / 1024.0 / 1024.0)
        // ⚠ 必须丢弃缓存句柄：它仍持有旧文件的页视图（freelist_count 会继续报旧值）。
        invalidateConnection()
        return (before, after)
    }

    /// 某只票**截止 `day`（含）**的最近 `limit` 根，按日期**升序**返回。
    ///
    /// 这正是回放模式下 `DataSources.fetchDailyKline(code, datalen:)` 的语义：
    /// 「截止当前回放日的最近 datalen 根」。先 DESC 取最近 N 根再反转 ——
    /// 与 `FundFlowStore.history` 同一手法（那里是新浪给 DESC、我们反转）。
    public static func bars(code: String, upTo day: String, limit: Int) -> [HistoryBar] {
        guard limit > 0, !day.isEmpty else { return [] }
        let rows = db.query(
            "SELECT code, day, open, close, high, low, volume, amount, amplitude, change_pct, turnover"
                + " FROM daily_bars WHERE code = ? AND day <= ?"
                + " ORDER BY day DESC LIMIT ?", [code, day, Double(limit)])
        return rows.compactMap(bar).reversed()
    }

    /// **某一天的全市场** bar（重建当日行情用）。按 code 升序，保证可复现。
    public static func bars(on day: String) -> [HistoryBar] {
        guard !day.isEmpty else { return [] }
        return db.query(
            "SELECT code, day, open, close, high, low, volume, amount, amplitude, change_pct, turnover"
                + " FROM daily_bars WHERE day = ? ORDER BY code ASC", [day]).compactMap(bar)
    }

    /// 日期窗口 `[beg, end]` 内的全部 bar，**按 code 归组**（每组升序）。
    ///
    /// 这是重建「某一天的全市场」的主查询：一次取回窗口内所有票的 bar，
    /// 每只票都自带「前收 + 前 5 日量」，不必对 5 千只票各查一次库。
    /// 窗口只需覆盖「回放日往前 `HistoryReplay.warmupBars` 个交易日」。
    public static func barsByCode(from beg: String, to end: String) -> [String: [HistoryBar]] {
        guard !beg.isEmpty, !end.isEmpty, beg <= end else { return [:] }
        let rows = db.query(
            "SELECT code, day, open, close, high, low, volume, amount, amplitude, change_pct, turnover"
                + " FROM daily_bars WHERE day >= ? AND day <= ?"
                + " ORDER BY code ASC, day ASC", [beg, end])
        var out: [String: [HistoryBar]] = [:]
        for r in rows {
            guard let b = bar(r) else { continue }
            out[b.code, default: []].append(b)
        }
        return out
    }

    /// 指数**截止 `day`（含）的全部** bar，升序。
    ///
    /// ⚠ 与个股的 `bars(code:upTo:limit:)` 不同，这里**不设 limit**：
    /// `TradingCalendar` 靠它拿长历史，而只给最近 N 根会让历史日的
    /// `nextTradingDay` 静默退化成"下一个工作日"（`TradingCalendar.swift:53-62`），
    /// 进而把**错误日**的收益写进 `stock_outcomes` 污染调优标签。
    /// 与 fixture 模式下"指数日K 忽略 datalen"是同一条规则。
    public static func indexBars(symbol: String, upTo day: String) -> [HistoryBar] {
        guard !symbol.isEmpty, !day.isEmpty else { return [] }
        return db.query(
            "SELECT code, day, open, close, high, low, volume, amount, amplitude, change_pct, turnover"
                + " FROM \(indexTable) WHERE code = ? AND day <= ? ORDER BY day ASC",
            [symbol, day]).compactMap(bar)
    }

    /// 指数在 `day` 那根（重建指数行情用）；没有则 `nil`
    public static func indexBar(symbol: String, on day: String) -> HistoryBar? {
        guard !symbol.isEmpty, !day.isEmpty else { return nil }
        return db.query(
            "SELECT code, day, open, close, high, low, volume, amount, amplitude, change_pct, turnover"
                + " FROM \(indexTable) WHERE code = ? AND day = ? LIMIT 1",
            [symbol, day]).compactMap(bar).first
    }

    /// 缓存里出现过的全部交易日（升序）—— 回放的**日期候选**与交易日历的交叉验证用
    public static func tradingDays() -> [String] {
        db.query("SELECT DISTINCT day FROM daily_bars ORDER BY day ASC", [])
            .compactMap { $0["day"] as? String }
            .filter { !$0.isEmpty }
    }

    /// 指数缓存里出现过的全部交易日（升序）。
    ///
    /// ⚠ 与 `tradingDays()`（个股）**不可互换**：回放构造交易日历必须用**指数**日历 ——
    /// 个股停牌日在自己那行里是没有 bar 的，用它当日历会凭空少掉交易日，
    /// 进而让 `nextTradingDay` 把 T+1 推错一格（把错误日的收益写进 `stock_outcomes`）。
    public static func indexDays(symbol: String) -> [String] {
        guard !symbol.isEmpty else { return [] }
        return db.query("SELECT DISTINCT day FROM \(indexTable) WHERE code = ? ORDER BY day ASC",
                        [symbol])
            .compactMap { $0["day"] as? String }
            .filter { !$0.isEmpty }
    }

    /// 缓存概况
    public static func stats() -> Stats {
        let one = db.query(
            "SELECT COUNT(DISTINCT code) AS codes, COUNT(*) AS bars,"
                + " MIN(day) AS first_day, MAX(day) AS last_day FROM daily_bars", []).first ?? [:]
        let idx = db.query("SELECT COUNT(*) AS n FROM \(indexTable)", []).first?["n"] as? Int ?? 0
        return Stats(codes: one["codes"] as? Int ?? 0,
                     bars: one["bars"] as? Int ?? 0,
                     indexBars: idx,
                     firstDay: one["first_day"] as? String ?? "",
                     lastDay: one["last_day"] as? String ?? "")
    }

    /// 清空缓存（缓存可随时删除重建；调用方负责同时清 `bar_coverage`）
    public static func deleteAll() throws {
        try db.write { h in
            try exec(h, "DELETE FROM daily_bars")
            try exec(h, "DELETE FROM \(indexTable)")
            try exec(h, "DELETE FROM bar_coverage")
        }
    }

    // MARK: - 内部

    private static func bar(_ row: [String: Any]) -> HistoryBar? {
        guard let code = row["code"] as? String, let day = row["day"] as? String,
              !code.isEmpty, !day.isEmpty else { return nil }
        return HistoryBar(code: code, day: day,
                          open: num(row["open"]), close: num(row["close"]),
                          high: num(row["high"]), low: num(row["low"]),
                          volume: num(row["volume"]), amount: num(row["amount"]),
                          amplitude: num(row["amplitude"]),
                          changePct: num(row["change_pct"]),
                          turnover: num(row["turnover"]))
    }

    /// REAL 列 → Double，转发 `Num.doubleOrZero`（含 `isFinite` 守卫）。
    /// 首选 `Double`（读取层对 `SQLITE_FLOAT` 返回的就是它）；
    /// `doubleValue` 对长小数**不是正确舍入**，不做首选。
    private static func num(_ v: Any?) -> Double { Num.doubleOrZero(v) }
}

// MARK: - 自持连接

/// `history.sqlite3` 的**私有读写连接**（串行队列 + 单一连接）。
///
/// 与 `FundFlowStore` / `PhaseStore` 的自持只读连接同构，唯一差别是这里需要**写**
/// （建表、灌数据），所以用 `SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE` 而不是 `query_only`。
private final class HistoryDB: @unchecked Sendable, DataConnection {

    private let queue = DispatchQueue(label: "com.selected.history.bars")
    private var handle: OpaquePointer?
    private var openError: String?

    /// ⚠ 登记进换库清单。`history.sqlite3` 是**另一个文件**、不走 `ReadOnlyConnection`，
    ///   原先靠 `Store.invalidateAllDataConnections()` 里手写一行点名它
    ///   （扫 `ReadOnlyConnection` 声明形态的护栏抓不到它）⇒ 漏掉的表现是
    ///   "导入/换库后主库重开、回放库仍指**旧 inode**"，回放与补算把两套数据混着读，且无任何报错。
    init() { DataConnections.register(self) }

    var connectionName: String { "HistoryBarStore(HistoryDB)" }
    func releaseConnection() { reset() }

    /// 串行执行 + 统一错误包装。闭包内可直接用句柄。
    func write<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        try queue.sync {
            guard let h = open() else {
                throw SQLiteWriteError(message: openError ?? "history.sqlite3 打开失败")
            }
            return try body(h)
        }
    }

    func query(_ sql: String, _ params: [Any?]) -> [[String: Any]] {
        queue.sync { () -> [[String: Any]] in
            guard let h = open() else { return [] }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(h, sql, -1, &stmt, nil) == SQLITE_OK, let st = stmt else {
                // ⚠ prepare 失败**不能静默返回空**：撞锁 / 列缺失 / OOM 与"真的没有数据"
                //   **完全同形**，而本 Store 服务**历史日期批量重跑**（长任务）→
                //   出错只会表现成"这段区间没数据"。
                NSLog("[ERROR] HistoryBarStore.query prepare 失败（返回空）：%@",
                      String(cString: sqlite3_errmsg(h)))
                return []
            }
            defer { sqlite3_finalize(st) }
            bindAll(st, params)
            var rows: [[String: Any]] = []
            var rc = SQLITE_OK
            while true {
                rc = sqlite3_step(st)
                if rc == SQLITE_DONE { break }        // 正常结束（没有更多行）
                if rc != SQLITE_ROW {
                    // ⚠ step 中途失败 → **丢弃已取到的部分行**：把"出错"当"正常结尾"
                    //   会返回**半截结果**且无任何报错。丢弃 = 安全方向
                    //   （与"分页异常整轮作废"同一取向）。
                    NSLog("[ERROR] HistoryBarStore.query step 失败 rc=%d → 丢弃已取的 %d 行（不回半截）",
                          rc, rows.count)
                    return []
                }
                var row: [String: Any] = [:]
                for i in 0..<sqlite3_column_count(st) {
                    let name = String(cString: sqlite3_column_name(st, i))
                    switch sqlite3_column_type(st, i) {
                    case SQLITE_INTEGER: row[name] = Int(sqlite3_column_int64(st, i))
                    case SQLITE_FLOAT: row[name] = sqlite3_column_double(st, i)
                    case SQLITE_TEXT:
                        row[name] = sqlite3_column_text(st, i).map { String(cString: $0) } ?? ""
                    default: row[name] = NSNull()
                    }
                }
                rows.append(row)
            }
            return rows
        }
    }

    /// 丢弃句柄（下次访问重新解析路径并建表）
    func reset() {
        queue.sync {
            if let h = handle { sqlite3_close(h) }
            handle = nil
            openError = nil
        }
    }

    /// 丢弃句柄 —— **只许在 `write` 的闭包内调用**（那时已经在该串行队列上）。
    ///
    /// ⚠ 存在的唯一理由：事务回滚失败、且 `sqlite3_get_autocommit` 判定事务仍残留时，
    /// 必须把连接丢掉重建（否则之后每次 `BEGIN IMMEDIATE` 全废）。而 `reset()` 内部是
    /// `queue.sync`，从 `write` 的闭包里调它就是**对同一串行队列嵌套同步 → 死锁**。
    /// 所以这里只做字段操作，不碰队列。
    func discardHandleLocked() {
        if let h = handle { sqlite3_close(h) }
        handle = nil
        openError = nil
    }

    /// 打开（首次）并建表。失败时记 `openError` 并返回 nil ——
    /// 不抛错是为了让**读**路径在库不存在时安静返回空（界面显示"尚未下载"），
    /// 而**写**路径会把它升级成 `SQLiteWriteError`（见 `write`）。
    private func open() -> OpaquePointer? {
        if let h = handle { return h }
        if openError != nil { return nil }
        let path = DataDirectory.resolve() + "/" + HistoryBarStore.fileName
        var h: OpaquePointer?
        guard sqlite3_open_v2(path, &h,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let opened = h else {
            let why = h.map { String(cString: sqlite3_errmsg($0)) } ?? "未知"
            if let x = h { sqlite3_close(x) }
            // ⚠ 瞬时打开失败不写 `openError`（2026-10-16 审查 B2，同 `SQLiteWriter`）：
            //   `openError` 只有 `reset()` 会清，缓存下来就是"本次会话再也不尝试"——
            //   于是一次磁盘/占用类瞬时故障让回放**永久读空、写抛错**。
            //   下面的**建表**失败仍要缓存：那是结构性状态，重试没有意义。
            NSLog("[ERROR] DB history.sqlite3 打开失败（下次调用会重试）: %@ — %@", path, why)
            return nil
        }

        sqlite3_busy_timeout(opened, 30_000)
        // 批量灌数据：WAL + NORMAL 是「快一个数量级且仍然安全」的组合
        // （崩溃最多丢最后一个事务，而缓存本来就可重建）
        sqlite3_exec(opened, "PRAGMA journal_mode = WAL", nil, nil, nil)
        sqlite3_exec(opened, "PRAGMA synchronous = NORMAL", nil, nil, nil)
        if sqlite3_exec(opened, HistoryBarStore.createSQL, nil, nil, nil) != SQLITE_OK {
            openError = "history.sqlite3 建表失败：\(errmsg(opened))"
            sqlite3_close(opened)
            return nil
        }
        healStaleCoverageShape(opened)
        handle = opened
        return opened
    }

    /// 缓存**自愈**：`bar_coverage` 若还是旧形状（`first_day`/`last_day`），整表重建。
    ///
    /// **为什么需要**：`CREATE TABLE IF NOT EXISTS` 对已存在的表**什么都不做** ——
    /// 于是旧形状的 `bar_coverage` 会带着缺列活下来，随后 `coverage()` 的
    /// `SELECT req_beg …` 直接报 `no such column`（而读路径是**静默吞错返回空**的），
    /// 表现为"断点续传失灵、每次都重下全市场"。
    ///
    /// **为什么是 DROP 而不是 ALTER**：这张表是**纯续传簿记**，没有任何不可再生信息 ——
    /// 丢掉它的后果只是"下次重新请求一遍"，方向是安全的（多花时间，不会缺数据）。
    /// ALTER + 回填要多写十几行，还要处理"旧行填什么值"这个没有正确答案的问题。
    private func healStaleCoverageShape(_ h: OpaquePointer?) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(h, "PRAGMA table_info(bar_coverage)", -1, &stmt, nil) == SQLITE_OK,
              let st = stmt else { return }
        // ⚠ `defer` 保证 finalize：step 失败中途 `return` 时会泄漏语句句柄
        //   （`finalize(nil)` 是安全的空操作）。
        defer { sqlite3_finalize(stmt) }
        var hasReqBeg = false
        var rc = SQLITE_OK
        while true {
            rc = sqlite3_step(st)
            if rc == SQLITE_DONE { break }        // 正常结束（没有更多行）
            if rc != SQLITE_ROW {
                // ⚠ step 中途失败 → **本次不重建**：把"出错"当"正常结尾"会让
                //   `hasReqBeg` 停在 `false` → 一张可能完好的表被当成"旧形状"**DROP 掉**。
                //   形状读不出来时**什么都不做**是安全方向
                //   （宁可多一次 PRAGMA，也不误丢续传簿记）。
                NSLog("[ERROR] HistoryBarStore.healStaleCoverageShape step 失败 rc=%d → 形状未知，"
                      + "本次不重建（不误丢续传簿记）", rc)
                return
            }
            if let c = sqlite3_column_text(st, 1), String(cString: c) == "req_beg" {
                hasReqBeg = true
                break
            }
        }
        guard !hasReqBeg else { return }
        NSLog("[NOTICE] history.sqlite3：bar_coverage 为旧形状 → 重建（续传簿记，可安全丢弃）")
        sqlite3_exec(h, "DROP TABLE IF EXISTS bar_coverage", nil, nil, nil)
        sqlite3_exec(h, HistoryBarStore.createSQL, nil, nil, nil)
    }
}

// MARK: - 绑定助手

/// ⚠ `nil` 作为 destructor 等价 `SQLITE_STATIC` —— 对 Swift 的**临时桥接指针**是错的：
/// 语句步进时指针可能已失效，读出来是**空/乱码而且不报错**。
/// 必须用 `SQLITE_TRANSIENT`（让 SQLite 自己拷一份）。
/// 与 `PhaseStore.bind` / `SQLiteWriter` 同一写法。
private let SQLITE_TRANSIENT_H = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private func errmsg(_ h: OpaquePointer?) -> String {
    h.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unknown"
}

private func bindText(_ st: OpaquePointer?, _ i: Int32, _ s: String) {
    sqlite3_bind_text(st, i, s, -1, SQLITE_TRANSIENT_H)
}

private func bindAll(_ st: OpaquePointer?, _ params: [Any?]) {
    for (i, p) in params.enumerated() {
        let idx = Int32(i + 1)
        switch p {
        case let v as String: bindText(st, idx, v)
        case let v as Double: sqlite3_bind_double(st, idx, v)
        case let v as Int: sqlite3_bind_int64(st, idx, Int64(v))
        case let v as Int64: sqlite3_bind_int64(st, idx, v)
        case is NSNull, nil: sqlite3_bind_null(st, idx)
        // ⚠ 未知类型不能**静默写成 TEXT**（`Bool`/`Float` 会被存成 `'1.0'` 而不是 1.0）——
        //   同一职责在 `SQLiteWriter` 是**抛错**的，两套口径里宽松那侧不报错。
        //   ⇒ "显式失败可见"：绑 NULL ＋ 留痕，不猜类型。
        //   ⚠ 当前调用点只传 String/Double/Int/Int64/NSNull ⇒ 行为不变（预防性加固）。
        default:
            NSLog("[ERROR] HistoryBarStore.bindAll: 不支持的绑定类型 \(type(of: p))（参数索引 \(idx)）→ 按 NULL 绑定")
            sqlite3_bind_null(st, idx)
        }
    }
}

private func exec(_ h: OpaquePointer?, _ sql: String, _ params: [Any?] = []) throws {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(h, sql, -1, &stmt, nil) == SQLITE_OK, let st = stmt else {
        throw SQLiteWriteError(message: "prepare 失败：\(errmsg(h)) | \(sql)")
    }
    defer { sqlite3_finalize(st) }
    bindAll(st, params)
    let rc = sqlite3_step(st)
    guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
        throw SQLiteWriteError(message: "执行失败 rc=\(rc)：\(errmsg(h)) | \(sql)")
    }
}
