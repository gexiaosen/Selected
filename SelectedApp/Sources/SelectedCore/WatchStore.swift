import Foundation
import SQLite3

/// 自选股写操作（分组 / 自选 / 持仓的 CRUD）+ 判定所需的库访问（读 + 判定落库）。
///
///   · 读：`watchItems` / `judgmentsForState` / `latestMarketEnv` / `previousJudgment`
///   · 写：`upsertJudgment` 与 CRUD
///   ⚠ 判定跑在**后台线程**，不能用主线程专用的 `SQLiteReader` → 本类自带一条
///     `query_only` 只读连接（与 `CompareStore` 同一套模式；两处同构是有意的：
///     这类连接的生命周期/锁策略必须逐字相同，抽公共基类反而更容易在并发上出错）
///
/// **错误处理口径**：返回**空串 = 成功**，非空 = 拒绝原因（调用方直接展示）。
///   ⚠ `groupAdd`/`groupRename` 只把 UNIQUE 冲突翻译成"分组已存在"，
///   其它异常照抛（让调用方展示真实原因并报错）。
final public class WatchStore: @unchecked Sendable {
    public static let shared = WatchStore()

    /// 默认组
    public static let defaultGroupID = 1
    public static let defaultGroupName = "默认"

    /// **一只股票 → 多个分组的归属关系**（支撑「复制到分组」）。
    ///
    /// **为什么需要单独一张表**：`watchlist.code` 是**主键**，
    /// 一张表存不下"一只股票同时在多个分组"。所以把**归属关系**拆出来，
    /// `watchlist` 继续管"股票本体"（名称 / 持仓 / 主分组）。
    ///
    /// ⚠ **`watchlist.group_id` 仍要同步维护**（见 `syncPrimaryGroup`）= 该股归属里
    ///   **最小的 `group_id`**。取"最小"而非"最后加入的"是为了**确定性**：
    ///   同一组归属无论怎么改，主分组都得到同一个值（幂等）。
    ///
    /// ⚠ 结构挂 `DBBootstrap.ensureSwiftOnlySchema`，灌数据挂 `ensureSwiftOnlyMigrations`。
    public static let createSQL = """
    CREATE TABLE IF NOT EXISTS watch_group_members (
        code     TEXT NOT NULL,
        group_id INTEGER NOT NULL,
        PRIMARY KEY (code, group_id)
    );
    """

    private init() {}

    // MARK: - 只读连接（后台线程可用；写一律走 SQLiteWriter）

    /// ⚠ 自持只读连接（**不能用 `SQLiteReader.shared`** —— 它是 `@MainActor` 的，
    ///   跨线程读会 SIGSEGV）。四件套（`READWRITE` / `PRAGMA query_only` / `busy_timeout` /
    ///   串行队列）由 `ReadOnlyConnection` **一处**保证。
    ///   数据目录解析的唯一实现见 `DataDirectory.resolve()`。
    private let conn = ReadOnlyConnection(label: "WatchStore", pathProvider: DataDirectory.resolve)

    /// 读。
    ///
    /// ⚠ 行解码**刻意留在这里**（不进 `ReadOnlyConnection`）：本处对 NULL 列是 `NSNull()`，
    ///   而 `SQLiteReader` 那处是「**整列跳过**」—— **有意不同**，强行统一会改语义。
    private func query(_ sql: String, _ params: [Any?] = []) -> [[String: Any]] {
        conn.query(sql, params) { stmt in
            var row: [String: Any] = [:]
            for i in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, i))
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: row[name] = Int(sqlite3_column_int64(stmt, i))
                case SQLITE_FLOAT: row[name] = sqlite3_column_double(stmt, i)
                case SQLITE_TEXT: row[name] = SQLiteColumn.text(stmt, i)
                default: row[name] = NSNull()
                }
            }
            return row
        }
    }

    /// 关闭只读连接（测试与换库用）
    public func close() {
        conn.close()
    }

    // MARK: - 判定所需的读

    /// 自选列表（按 added_at 升序）
    public func watchItems() -> [[String: Any]] {
        query("SELECT code, name, added_at, group_id, is_holding, cost_price, shares "
              + "FROM watchlist ORDER BY added_at")
    }

    /// 判定历史（持仓状态机用，按日期倒序）
    public func judgmentsForState(code: String) -> [[String: Any]] {
        query("SELECT action, baseline_price, target_price, stop_loss_price "
              + "FROM watch_judgments WHERE code=? ORDER BY date DESC, id DESC", [code])
    }

    /// 最近一轮扫描的大盘环境（跨日期取最新一条）
    public func latestMarketEnv() -> [String: Any] {
        let rows = query("SELECT market_env_json FROM scan_rounds WHERE market_env_json IS NOT NULL "
                         + "ORDER BY date DESC, run_time DESC LIMIT 1")
        guard let s = rows.first?["market_env_json"] as? String,
              let d = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return obj
    }

    /// 当日已存在的判定行（覆盖写前保留锚点用）
    public func previousJudgment(date: String, code: String) -> [String: Any]? {
        query("SELECT baseline_price, target_price, stop_loss_price, sell_window, "
              + "position_advice, risk_level FROM watch_judgments WHERE date=? AND code=?",
              [date, code]).first
    }

    /// 写入一条判定（INSERT OR REPLACE；details_json 由调用方给 JSON 字符串）
    public func upsertJudgment(date: String, code: String, name: String, action: String,
                        score: Any?, detailsJSON: String, targetPrice: Double?,
                        stopLossPrice: Double?, baselinePrice: Double?, sellWindow: String?,
                        positionAdvice: String?, riskLevel: String?, marketLight: String,
                        createdAt: String) throws {
        _ = try write { tx in
            try tx.execute(
                "INSERT OR REPLACE INTO watch_judgments"
                + "(date, code, name, action, score, details_json, target_price, stop_loss_price,"
                + " baseline_price, sell_window, position_advice, risk_level, market_light, created_at)"
                + " VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                [date, code, name, action, score, detailsJSON, targetPrice, stopLossPrice,
                 baselinePrice, sellWindow, positionAdvice, riskLevel, marketLight, createdAt])
        }
    }

    /// 写库时刻 `yyyy-MM-dd HH:mm:ss`（**北京时间**）。
    ///
    /// ⚠ 统一走 `ChinaTime`（与 `ScanRunner` 一致）：不设 timeZone 的话，
    ///   非上海时区设备上两者相差数小时（跨零点还会差一天），且不报错。
    ///   换过时区的设备上，历史行（本地时间写的）与新行（北京时间）会混用 ——
    ///   不可回填，按「已知不足」接受。
    public static func timestamp() -> String {
        ChinaTime.formatter("yyyy-MM-dd HH:mm:ss").string(from: Date())
    }

    private func write<T>(_ body: (WriteTx) throws -> T) throws -> T {
        try SQLiteWriter.shared.write(body)
    }

    /// 默认组兜底：老库（group_id 列已加但组行缺失）首次写入时补建。
    /// `INSERT OR IGNORE` —— 组行已存在（含被改名的情况）时不覆盖。
    private func ensureDefaultGroup(_ tx: WriteTx) throws {
        try tx.execute("INSERT OR IGNORE INTO watch_groups(id, name, created_at) VALUES(?,?,?)",
                       [Self.defaultGroupID, Self.defaultGroupName, Self.timestamp()])
    }

    private static func trim(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isUniqueViolation(_ error: Error) -> Bool {
        String(describing: error).contains("UNIQUE")
    }

    // MARK: - 分组

    /// 新增分组
    @discardableResult
    public func groupAdd(name: String) throws -> String {
        let n = Self.trim(name)
        if n.isEmpty { return "分组名为空" }
        if n == Self.defaultGroupName { return "默认组已存在" }
        do {
            try write { tx in
                try ensureDefaultGroup(tx)
                try tx.execute("INSERT INTO watch_groups(name, created_at) VALUES(?,?)",
                               [n, Self.timestamp()])
            }
        } catch {
            if Self.isUniqueViolation(error) { return "分组「\(n)」已存在" }
            throw error
        }
        return ""
    }

    /// 重命名分组（默认组不可改）
    @discardableResult
    public func groupRename(id: Int, name: String) throws -> String {
        let n = Self.trim(name)
        if n.isEmpty { return "分组名为空" }
        if id == Self.defaultGroupID { return "默认组不可重命名" }
        do {
            return try write { tx in
                let n1 = try tx.execute("UPDATE watch_groups SET name=? WHERE id=?", [n, id])
                return n1 == 0 ? "分组不存在" : ""
            }
        } catch {
            if Self.isUniqueViolation(error) { return "分组「\(n)」已存在" }
            throw error
        }
    }

    /// 删除分组：连同独属该组的自选股与关联提醒一并删除（UI 负责二次确认）；
    /// 判定历史保留（审计可回溯）。返回空串 = 成功。
    ///
    /// 多分组下：只有「除了这一组再没有别的归属」的票才真正移出；
    /// 还在别的分组里的只失去这一条归属，并把 `watchlist.group_id` 同步更新为剩余归属里的最小组。
    @discardableResult
    public func groupDelete(id: Int) throws -> String {
        if id == Self.defaultGroupID { return "默认组不可删除" }
        return try write { tx in
            let n = try tx.execute("DELETE FROM watch_groups WHERE id=?", [id])
            if n == 0 { return "分组不存在" }

            // 先锁定本组受影响股票（成员归属或主分组落在此组）
            let affectedRows = try tx.query(
                "SELECT DISTINCT code FROM ("
                + "  SELECT code FROM watch_group_members WHERE group_id = ?"
                + "  UNION"
                + "  SELECT code FROM watchlist WHERE group_id = ?"
                + ")", [id, id])
            let affectedCodes = affectedRows.compactMap { $0["code"] as? String }

            try tx.execute("DELETE FROM watch_group_members WHERE group_id=?", [id])

            let hasAlerts = try tableExists(tx, AlertStore.alertsTable)
            let hasAlertSettings = try tableExists(tx, AlertStore.settingsTable)

            for code in affectedCodes {
                let remaining = try tx.query(
                    "SELECT 1 FROM watch_group_members WHERE code=? LIMIT 1", [code])
                if remaining.isEmpty {
                    try tx.execute("DELETE FROM watchlist WHERE code=?", [code])
                    if hasAlerts {
                        try tx.execute("DELETE FROM watch_alerts WHERE code=?", [code])
                    }
                    if hasAlertSettings {
                        try tx.execute("DELETE FROM watch_alert_settings WHERE code=?", [code])
                    }
                } else {
                    try syncPrimaryGroup(tx, code: code)
                }
            }
            return ""
        }
    }

    /// 全部分组（`id, name`，按 id 升序）—— **自检驱动用**；
    /// 界面走 `SQLiteReader.watchGroups()`（库行实体），不走这里。
    public func groupRows() -> [[String: Any]] {
        query("SELECT id, name FROM watch_groups ORDER BY id")
    }

    // MARK: - 自选 / 持仓

    /// 加入自选。
    /// 名称由调用方给（UI 从证券列表带过来）；名称解析不到时调用方走引擎（会实时拉行情）。
    ///
    /// ⚠ UPSERT 而非 INSERT OR REPLACE：后者会清掉既有分组与持仓信息。
    /// 冲突时**只更新名称**（不动 group_id）：已在自选里的股票换个分组加一次，不会把它挪走。
    @discardableResult
    public func add(code: String, name: String, group: Int = WatchStore.defaultGroupID) throws -> String {
        let c = Self.trim(code)
        if c.isEmpty { return "代码为空" }
        try write { tx in
            try ensureDefaultGroup(tx)
            try tx.execute(
                "INSERT INTO watchlist(code, name, added_at, group_id) VALUES(?,?,?,?) "
                + "ON CONFLICT(code) DO UPDATE SET name=excluded.name",
                [c, name, Self.timestamp(), group])
            // ⚠ 归属表也要写：上面的 UPSERT 冲突分支**不改** `watchlist.group_id`
            //   （"换个分组再加一次不会把它挪走"），但用户既然又指定了一次分组，
            //   归属就该加上 ⇒ 效果是"同时在两个分组"。`INSERT OR IGNORE` 保证幂等。
            try tx.execute(
                "INSERT OR IGNORE INTO watch_group_members(code, group_id) VALUES(?,?)",
                [c, group])
        }
        return ""
    }

    /// 移出自选（不在自选也返回成功 —— 幂等）
    @discardableResult
    public func remove(code: String) throws -> String {
        _ = try write { tx in
            try tx.execute("DELETE FROM watchlist WHERE code=?", [code])
            // ⚠ 归属与提醒同一事务清理：否则重加自选会带回幽灵归属，或孤儿提醒继续轮询。
            try tx.execute("DELETE FROM watch_group_members WHERE code=?", [code])
            if try tableExists(tx, AlertStore.alertsTable) {
                try tx.execute("DELETE FROM watch_alerts WHERE code=?", [code])
            }
            if try tableExists(tx, AlertStore.settingsTable) {
                try tx.execute("DELETE FROM watch_alert_settings WHERE code=?", [code])
            }
        }
        return ""
    }

    /// 移动到分组 —— ⚠ **单归属语义**：同时把**归属表重置**成"只有 `group` 这一个分组"
    /// （否则多分组下 `watchlist.group_id` 会与归属表分叉）。
    /// 界面上的「移动到分组」走 `moveWithin(code:from:to:)`，不要混用。
    @discardableResult
    public func move(code: String, group: Int) throws -> String {
        try write { tx in
            let n = try tx.execute("UPDATE watchlist SET group_id=? WHERE code=?", [group, code])
            if n == 0 { return "股票不在自选中" }
            try tx.execute("DELETE FROM watch_group_members WHERE code=?", [code])
            try tx.execute(
                "INSERT OR IGNORE INTO watch_group_members(code, group_id) VALUES(?,?)",
                [code, group])
            return ""
        }
    }

    // MARK: - 分组归属（多分组，支撑「复制到分组」）

    /// 全部归属的**扁平行**（一只股票 N 个分组 → N 行），供自选列表按分组过滤。
    /// ⚠ 调用方自己去重 / 建索引（本方法不做）。
    public func memberships() -> [[String: Any]] {
        query("SELECT code, group_id FROM watch_group_members ORDER BY code, group_id")
    }

    /// 全部归属，按 `code` 归并成 `Set<Int>` —— **App 层的列表过滤直接用这个**
    /// （省得每个消费方各自解析 `[[String: Any]]`）。
    public func membershipIndex() -> [String: Set<Int>] {
        var out: [String: Set<Int>] = [:]
        for row in memberships() {
            guard let code = row["code"] as? String,
                  let g = (row["group_id"] as? NSNumber)?.intValue else { continue }
            out[code, default: []].insert(g)
        }
        return out
    }

    /// 一只股票的全部归属分组（升序）。不在任何分组 → `[]`。
    public func groups(of code: String) -> [Int] {
        query("SELECT group_id FROM watch_group_members WHERE code=? ORDER BY group_id", [code])
            .compactMap { ($0["group_id"] as? NSNumber)?.intValue }
    }

    /// **复制**到分组：加到目标分组，**其它归属全部保留**。
    @discardableResult
    public func copyTo(code: String, group: Int) throws -> String {
        try write { tx in
            guard try isWatched(tx, code: code) else { return "股票不在自选中" }
            try tx.execute(
                "INSERT OR IGNORE INTO watch_group_members(code, group_id) VALUES(?,?)",
                [code, group])
            try syncPrimaryGroup(tx, code: code)
            return ""
        }
    }

    /// **组内移动**：从 `from` 组移到 `to` 组，**其它归属保留**。
    ///
    /// 语义：「只在作出操作的组操作」—— 即 `from` 之外的归属**不动**。
    /// ⚠ **默认组例外**：`from == 默认组` 时**不移出默认组**，只往 `to` 加一份
    ///   —— 效果等同 `copyTo`。理由：默认组现在是「所有分组的去重总量」视图（不是物理归属），
    ///   从它"移走"没有意义：票还在别的组里，总量视图就该还有它。
    /// ⚠ 与 `move(code:group:)` 的区别：后者**重置全部归属**（单归属语义）；
    ///   本方法是**组内**操作。界面上的「移动到分组」用本方法。
    @discardableResult
    public func moveWithin(code: String, from: Int, to: Int) throws -> String {
        if from == to { return "" }        // 原地不动：成功且无副作用（幂等）
        return try write { tx in
            guard try isWatched(tx, code: code) else { return "股票不在自选中" }
            // 默认组是总量视图 ⇒ 不删它的归属（见方法注释）
            if from != Self.defaultGroupID {
                try tx.execute(
                    "DELETE FROM watch_group_members WHERE code=? AND group_id=?", [code, from])
            }
            try tx.execute(
                "INSERT OR IGNORE INTO watch_group_members(code, group_id) VALUES(?,?)",
                [code, to])
            try syncPrimaryGroup(tx, code: code)
            return ""
        }
    }

    /// 这只票在不在自选里（归属方法的前置检查；返回 `false` 时调用方给"不在自选中"）。
    private func isWatched(_ tx: WriteTx, code: String) throws -> Bool {
        try !tx.query("SELECT 1 FROM watchlist WHERE code=?", [code]).isEmpty
    }

    private func tableExists(_ tx: WriteTx, _ name: String) throws -> Bool {
        try !tx.query(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", [name]).isEmpty
    }

    /// 把 `watchlist.group_id` 同步成该股归属里**最小**的那个（见 `createSQL` 的注释）。
    /// ⚠ 归属为空时**保留原值**（`COALESCE` 兜底）—— 那说明数据坏了，
    ///   与其写一个 NULL 出来，不如留着让对账去报。
    private func syncPrimaryGroup(_ tx: WriteTx, code: String) throws {
        _ = try tx.execute(
            "UPDATE watchlist SET group_id = COALESCE("
            + "  (SELECT MIN(group_id) FROM watch_group_members WHERE code = ?), group_id) "
            + "WHERE code = ?", [code, code])
    }

    /// 设置/更新手动持仓（仅 UI 盈亏显示；引擎信号判定不受影响）
    @discardableResult
    public func setHolding(code: String, cost: Double, shares: Double) throws -> String {
        if cost <= 0 || shares <= 0 { return "成本价与数量必须大于 0" }
        return try write { tx in
            let n = try tx.execute(
                "UPDATE watchlist SET is_holding=1, cost_price=?, shares=? WHERE code=?",
                [cost, shares, code])
            return n == 0 ? "股票不在自选中，请先添加" : ""
        }
    }

    /// 清仓（移出持仓视图）
    @discardableResult
    public func clearHolding(code: String) throws -> String {
        _ = try write { tx in
            try tx.execute(
                "UPDATE watchlist SET is_holding=0, cost_price=NULL, shares=NULL WHERE code=?",
                [code])
        }
        return ""
    }
}
