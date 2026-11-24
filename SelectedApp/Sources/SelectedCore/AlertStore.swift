import Foundation
import SQLite3

/// 自选提醒的落库与读取。
///
/// ## 两张表
/// · `watch_alerts` —— 一条规则一行。**触发状态（`last_fired_*`）就存在规则行上**：
///   「单次 / 每日重复」的判据天然是"这条规则上次什么时候响的"，拆第三张表只会多一次 join。
/// · `watch_alert_settings` —— 每只票一条（提醒时间窗）。它是**每只票一个**的量，
///   塞进规则行会变成"同一个量有 N 份副本"，迟早分叉。
///
/// ## 为什么是主库里的 Swift-only 表
/// 与 `stock_fund_flows` / `stock_lhb` / `index_members` / `limit_up_pool` 同一条路：
/// 建表挂 `DBBootstrap.ensureSwiftOnlySchema`。⚠ **不写进** `engine/params/db_schema_export.json`。
///
/// ## ⚠ 不建二级索引
/// 主键 `(code, kind, threshold)` 的**最左前缀就是 `code`** —— 按 code 查已经走主键索引，
/// 再补一个 `ON watch_alerts(code)` 是纯冗余。
///
/// ## ⚠ 读为什么不用 `SQLiteReader.shared`
/// 本类的读会被**后台轮询任务**（`AlertMonitor`）调用，而 `SQLiteReader` 的共享连接是
/// **主线程专用**的 —— Apple 系统 libsqlite3 为 multi-thread 模式（非 serialized），
/// **同一连接跨线程并发使用直接 SIGSEGV**。→ 自持 `query_only` 只读连接（`ReadOnlyConnection`）+ 串行队列。
/// → 写走 `SQLiteWriter.shared`（本身就是"串行队列 + 唯一写连接"，跨线程安全）。
public enum AlertStore {

    public static let alertsTable = "watch_alerts"
    public static let settingsTable = "watch_alert_settings"

    /// 建表 DDL（`IF NOT EXISTS` 天然幂等，每次启动跑一遍）
    ///
    /// ⚠ 列**不给多余 DEFAULT**：
    ///   · `repeat_mode` 不给 —— 保存时必写；给了 DEFAULT 会让"漏写"静默变成"按默认走"
    ///   · `last_fired_at` / `last_fired_day` 给 `''` —— 新规则天然是"从未触发"，
    ///     且**必须 NOT NULL**：读取层对 `SQLITE_NULL` 是**整列跳过**（不进字典），
    ///     用 NULL 会让"从未触发"表现为**键缺失**，与"读坏了"不可区分
    public static let createSQL = """
    CREATE TABLE IF NOT EXISTS watch_alerts (
        code           TEXT NOT NULL,
        kind           TEXT NOT NULL,
        threshold      REAL NOT NULL,
        repeat_mode    TEXT NOT NULL,
        last_fired_at  TEXT NOT NULL DEFAULT '',
        last_fired_day TEXT NOT NULL DEFAULT '',
        updated_at     TEXT NOT NULL DEFAULT '',
        PRIMARY KEY (code, kind, threshold)
    );
    CREATE TABLE IF NOT EXISTS watch_alert_settings (
        code        TEXT PRIMARY KEY,
        time_window TEXT NOT NULL DEFAULT 'anytime',
        updated_at  TEXT NOT NULL DEFAULT ''
    );
    """

    /// 私有只读连接（**不要**换成 `SQLiteReader.shared`，见类注释）
    private static let reader = AlertReader()

    /// 转发到 `AlertReader.close()`。
    /// 手动释放本 Store 的连接。
    /// ⚠ 换库清单**不需要**再点名本 Store：连接在 `ReadOnlyConnection.init` 里已登记进
    /// `DataConnections`，`closeAll()` 自动覆盖（原先靠人往清单里加一行，实测漏过 4 个）。
    public static func close() {
        reader.close()
    }

    // MARK: - 写

    /// 保存某只票的全部规则 + 时间窗（**全量替换**，同一事务）。
    ///
    /// 语义：该 code 的规则 = `drafts`（删掉旧的全部，插入新的）。
    /// `drafts` 为空 = **取消该票的全部提醒**（连时间窗一并删）。
    ///
    /// ⚠ **未变规则的触发状态必须继承**（`AlertMerge.carryOver`）：漏了不会报错、
    /// 不会崩、界面全对，只是「每日重复」退化成"每次保存后都能再响一次"。
    ///
    /// ⚠ **读旧状态必须在事务内**（用 `tx.query` 而不是 `reader.query`）：
    /// "读—删—插"三步之间若有别的写进来（`markFired` 就在并发跑），
    /// 会把刚记下的触发状态丢掉。`SQLiteWriter` 已 `BEGIN IMMEDIATE` 持写锁，
    /// 事务内读到的就是一致快照。
    @discardableResult
    public static func save(code: String, drafts: [AlertDraft], window: AlertWindow,
                            at stamp: String) throws -> Int {
        let c = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty else { return 0 }
        return try SQLiteWriter.shared.write { tx in
            let oldRows = try tx.query(
                "SELECT kind, threshold, repeat_mode, last_fired_at, last_fired_day"
                    + " FROM watch_alerts WHERE code=?", [c])
            let existing = oldRows.compactMap(rule(from:))

            try tx.execute("DELETE FROM watch_alerts WHERE code=?", [c])

            guard !drafts.isEmpty else {
                // 规则清空 → 时间窗也删掉（没有规则时它没有意义，留着会让"配了东西吗"读不准）
                try tx.execute("DELETE FROM watch_alert_settings WHERE code=?", [c])
                return 0
            }

            let merged = AlertMerge.carryOver(existing: existing, drafts: drafts)
            for r in merged {
                try tx.execute(
                    "INSERT OR REPLACE INTO watch_alerts"
                        + "(code, kind, threshold, repeat_mode, last_fired_at, last_fired_day, updated_at)"
                        + " VALUES(?,?,?,?,?,?,?)",
                    [c, r.kind.rawValue, r.threshold, r.repeatMode.rawValue,
                     r.lastFiredAt, r.lastFiredDay, stamp])
            }
            try tx.execute(
                "INSERT OR REPLACE INTO watch_alert_settings(code, time_window, updated_at)"
                    + " VALUES(?,?,?)",
                [c, window.rawValue, stamp])
            return merged.count
        }
    }

    /// 记录触发（更新 `last_fired_*`）。返回实际更新的行数。
    ///
    /// ⚠ 返回行数为 0 说明"这条规则在库里不存在"——调用方（`AlertMonitor`）据此
    /// 判断"用户在评估与落库之间把规则删了"，此时**不该再弹通知**。
    /// 静默当成功会让用户收到一条他已经取消掉的提醒。
    @discardableResult
    public static func markFired(_ firings: [AlertFiring]) throws -> Int {
        guard !firings.isEmpty else { return 0 }
        return try SQLiteWriter.shared.write { tx in
            var n = 0
            for f in firings {
                n += try tx.execute(
                    "UPDATE watch_alerts SET last_fired_at=?, last_fired_day=?"
                        + " WHERE code=? AND kind=? AND threshold=?",
                    [f.firedAt, f.day, f.code, f.kind.rawValue, f.threshold])
            }
            return n
        }
    }

    /// 清掉某只票的全部提醒（移出自选时用；`save` 传空 drafts 是等价路径）
    @discardableResult
    public static func removeAll(code: String) throws -> Int {
        try SQLiteWriter.shared.write { tx in
            let n = try tx.execute("DELETE FROM watch_alerts WHERE code=?", [code])
            try tx.execute("DELETE FROM watch_alert_settings WHERE code=?", [code])
            return n
        }
    }

    // MARK: - 读

    /// 某只票的全部规则（按 kind / threshold 升序，稳定顺序）
    public static func rules(code: String) -> [AlertRule] {
        reader.query("SELECT kind, threshold, repeat_mode, last_fired_at, last_fired_day"
                     + " FROM watch_alerts WHERE code=? ORDER BY kind, threshold", [code])
            .compactMap(rule(from:))
    }

    /// 全表按 code 归组（`AlertMonitor` 每轮取一次；`Store` 加载铃铛状态也用它）
    public static func rulesByCode() -> [String: [AlertRule]] {
        let rows = reader.query("SELECT code, kind, threshold, repeat_mode, last_fired_at,"
                                + " last_fired_day FROM watch_alerts ORDER BY code, kind, threshold")
        var out: [String: [AlertRule]] = [:]
        for row in rows {
            guard let c = row["code"] as? String, !c.isEmpty, let r = rule(from: row) else { continue }
            out[c, default: []].append(r)
        }
        return out
    }

    /// 某只票的提醒时间窗。无记录 → `.anytime`（出厂默认，与 DDL 的 DEFAULT 同值）
    ///
    /// ⚠ 值无法识别时（例如被更高版本写过、又降级回来）也回落 `.anytime` ——
    /// 这是**放宽**方向的回落：宁可多提醒，也不因为一个认不出的值把提醒静默关掉。
    public static func window(code: String) -> AlertWindow {
        let v = reader.query("SELECT time_window FROM watch_alert_settings WHERE code=?", [code])
            .first?["time_window"] as? String
        return v.flatMap(AlertWindow.init(rawValue:)) ?? .anytime
    }

    /// 全表时间窗（按 code 归组）
    public static func windowsByCode() -> [String: AlertWindow] {
        var out: [String: AlertWindow] = [:]
        for row in reader.query("SELECT code, time_window FROM watch_alert_settings", []) {
            guard let c = row["code"] as? String, !c.isEmpty else { continue }
            let raw = row["time_window"] as? String ?? ""
            out[c] = AlertWindow(rawValue: raw) ?? .anytime
        }
        return out
    }

    /// 配了提醒的代码集合（铃铛图标"已设置/未设置"的**唯一判据**）
    public static func configuredCodes() -> Set<String> {
        Set(rulesByCode().keys)
    }

    /// 规则总行数（自检用）
    public static func ruleCount() -> Int {
        reader.query("SELECT COUNT(*) AS n FROM watch_alerts", []).first?["n"] as? Int ?? 0
    }

    /// 时间窗总行数（自检用）
    public static func settingsCount() -> Int {
        reader.query("SELECT COUNT(*) AS n FROM watch_alert_settings", []).first?["n"] as? Int ?? 0
    }

    // MARK: - 行 → 实体

    /// 行 → `AlertRule`。认不出的 `kind` / `repeat_mode` → `nil`（**跳过**，不猜）。
    ///
    /// ⚠ 这里与 `window(code:)` 的回落方向**故意相反**：
    ///   时间窗认不出 → 放宽（`.anytime`）；规则类型认不出 → **跳过**。
    ///   因为一条认不出类型的规则，我们既不知道它该在什么条件下触发、也不知道该报什么文案 ——
    ///   硬套一个默认类型会**凭空造出一条用户没设过的提醒**。
    static func rule(from row: [String: Any]) -> AlertRule? {
        guard let rawKind = row["kind"] as? String,
              let kind = AlertKind(rawValue: rawKind),
              let rawRepeat = row["repeat_mode"] as? String,
              let repeatMode = AlertRepeat(rawValue: rawRepeat) else { return nil }
        return AlertRule(kind: kind,
                         threshold: num(row["threshold"]),
                         repeatMode: repeatMode,
                         lastFiredAt: row["last_fired_at"] as? String ?? "",
                         lastFiredDay: row["last_fired_day"] as? String ?? "")
    }

    /// REAL 列 → Double，转发 `Num.doubleOrZero`（含 `isFinite` 守卫）。
    ///
    /// ⚠ 首选 `Double`：读取层对 `SQLITE_FLOAT` 返回的就是 `Double`；
    ///   `doubleValue` 对长小数**不是正确舍入**，不做首选。
    private static func num(_ v: Any?) -> Double { Num.doubleOrZero(v) }
}
/// 提醒表的**私有只读连接**。
///
/// 连接管理（`READWRITE` 开连接 / `PRAGMA query_only` / `busy_timeout` / 串行队列）
/// 全部由 `ReadOnlyConnection` 一处保证，本类只负责**行怎么解码**。
private final class AlertReader: @unchecked Sendable {

    private let conn = ReadOnlyConnection(label: "AlertStore", pathProvider: DataDirectory.resolve)

    /// 关闭只读连接。
    ///
    /// ⚠ 换库时这条连接**一定会被放掉** —— `ReadOnlyConnection.init` 把它登记进 `DataConnections`，
    ///   不再依赖"有人记得往 `Store.invalidateAllDataConnections()` 里加一行"（原先就是靠记得，
    ///   实测漏过 4 个 ⇒ 换库后**继续读旧库**而界面显示新库数据）。
    ///   顺带清掉 `openLocked()` 缓存的 openError —— 那是"永久放弃重试"的门闩，不清则新库也读不到。
    func close() {
        conn.close()
    }

    /// 读：默认行解码（唯一一份实现在 `ReadOnlyConnection.queryRows` —— 
    /// 「整列跳过 NULL」，塞 `NSNull` 会让调用侧的 `as? Int ?? 0` 把"缺值"读成 0）。
    func query(_ sql: String, _ params: [Any?] = []) -> [[String: Any]] {
        conn.queryRows(sql, params)
    }
}
