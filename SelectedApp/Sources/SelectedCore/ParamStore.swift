import Foundation
import SQLite3

/// 参数版本管理。
///
/// 读：`listVersions` / `activeName` / `versionParams`；
/// 写：`activate`（写 counters）/ `saveVersion`（写入非出厂版本）；
/// 删：`delete`（删行 + 墓碑，规则见下）；
/// 依赖元数据的路径（`ParamSchema` 从随包 JSON 读元数据）：
/// `activeParams` / `paramsForSchema` / `saveEditedVersion`
/// —— 校验 → 合并 → 落库全在 Swift 内完成。
///
/// 每次读/写版本前先 `ensureBuiltinSeeded()`：若不补种，新库没有任何出厂版本行。
///
/// **删除规则**：除「默认」与**当前激活版本**外都可删，含出厂版本。
/// 删出厂版本必须记**墓碑**（`counters.params_deleted_builtins`）——否则补种时
/// 会按随包文件把它补回来，用户看到的是"删了没用"的假删除。
/// ⚠ 墓碑**只对出厂版本名记录**、自定义版本名不进墓碑（见 `delete`）。
final public class ParamStore: @unchecked Sendable {
    public static let shared = ParamStore()

    /// 唯一不可删的版本（经典基线）。当前激活版本也不可删，但那个从库里读、不写死。
    public static let protectedVersions: Set<String> = ["默认"]
    public static let deletedBuiltinsKey = "params_deleted_builtins"

    /// ⚠ 自持只读连接（**不能用 `SQLiteReader.shared`** —— 它是 `@MainActor` 的，
    ///   跨线程读会 SIGSEGV）。四件套（`READWRITE` / `PRAGMA query_only` / `busy_timeout` /
    ///   串行队列）由 `ReadOnlyConnection` **一处**保证。
    ///   数据目录解析的唯一实现见 `DataDirectory.resolve()`。
    private let conn = ReadOnlyConnection(label: "ParamStore", pathProvider: DataDirectory.resolve)

    private init() {}

    // MARK: 路径（与只读/写/compare 三层同一套解析规则）

    /// 数据目录解析 —— 唯一实现见 `DataDirectory.resolve()`
    private func resolveDirUnlocked() -> String { DataDirectory.resolve() }

    private func query(_ sql: String, _ params: [Any?] = []) -> [[String: Any]] {
        conn.query(sql, params) { stmt in
            var row: [String: Any] = [:]
            for i in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, i))
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: row[name] = Int(sqlite3_column_int64(stmt, i))
                case SQLITE_FLOAT: row[name] = sqlite3_column_double(stmt, i)
                case SQLITE_TEXT:
                    row[name] = sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? ""
                default: row[name] = NSNull()
                }
            }
            return row
        }
    }


    // MARK: 读

    public func activeName() -> String {
        ensureBuiltinSeeded()
        let rows = query("SELECT value FROM counters WHERE key='active_param_version'")
        let v = (rows.first?["value"] as? String) ?? ""
        return v.isEmpty ? "" : v
    }

    /// 版本列表（含 deletable 裁决）
    public func listVersions() -> [[String: Any]] {
        ensureBuiltinSeeded()
        let rows = query("SELECT name, is_builtin, note, created_at FROM param_versions "
                         + "ORDER BY is_builtin DESC, created_at ASC")
        let active = activeName()
        return rows.map { r in
            let name = (r["name"] as? String) ?? ""
            return [
                "name": name,
                "is_builtin": Self.intOf(r["is_builtin"]) == 1,
                "note": (r["note"] as? String) ?? "",
                "created_at": Self.intOf(r["created_at"]) ?? 0,
                "is_active": name == active,
                "deletable": !Self.protectedVersions.contains(name) && name != active,
            ]
        }
    }

    public func versionExists(_ name: String) -> Bool {
        !query("SELECT 1 FROM param_versions WHERE name=?", [name]).isEmpty
    }

    /// 版本的参数 JSON 字符串（原样返回，调用方自行解析）
    public func versionParamsJSON(_ name: String) -> String? {
        query("SELECT params_json FROM param_versions WHERE name=?", [name])
            .first?["params_json"] as? String
    }

    public func deletedBuiltins() -> Set<String> {
        let rows = query("SELECT value FROM counters WHERE key=?", [Self.deletedBuiltinsKey])
        guard let s = rows.first?["value"] as? String, !s.isEmpty else { return [] }
        guard let d = s.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: d) as? [String] else { return [] }
        return Set(arr)
    }

    // MARK: 出厂参数补种

    private static let seedLock = NSLock()
    /// `nonisolated(unsafe)`：Swift 6 严格并发禁止非隔离的可变全局状态；访问**全部在 `seedLock` 内**，
    /// 故显式声明豁免（与 DataSources.quoteStat 同一处理方式）。
    private nonisolated(unsafe) static var builtinSeeded = false

    /// 出厂版本**补种**（幂等，每进程一次）：**只补缺失的行，永不覆盖已有行**。
    ///
    /// 必须在所有版本读写前执行：`listVersions()` 直接读 DB、`activate()` 要求
    /// DB 有行，不补种的新库会"一个出厂版本都看不到、也激活不了"。
    ///
    /// ⚠ 2026-10-15 语义变更（老板拍板）：出厂行落库后即用户数据——启动**不再**按
    ///   随包文件刷新参数或描述（原先每次启动内容比对刷新，用户改不动也删不掉旧值）。
    ///   把出厂行覆盖回随包状态的唯一入口是界面上的「恢复出厂设置」（`restoreBuiltins`）。
    ///
    /// 行为：
    ///   · 缺行新建（note 取随包文件），跳过墓碑中的出厂版本
    ///   · 随包文件缺失或损坏 → 记 `builtin_load_error` 并**不动 DB**
    ///   · 激活指针缺失 → 出厂默认；指向已废弃出厂行 → 自动回退默认（记 active_redirected）
    ///   · 出厂默认升级（一次性）：supersededDefaults + 标记键（记 active_migrated）
    ///   · 全部变更在一个事务内提交，结尾记 `builtin_synced`
    ///
    /// ⚠ 遍历顺序用导出里的 `builtin_order`：`created_at` 同为整秒时 list_versions
    ///   的稳定顺序由插入序决定，Swift 的 Set 无序不能直接用。
    ///
    /// ⚠ 本函数持 `seedLock` 执行：内部**绝不能**调用 `activeName()` / `query()` 等入口
    ///   （它们会回调本函数 → 死锁），一律直接用事务句柄读写。
    public func ensureBuiltinSeeded() {
        Self.seedLock.lock()
        defer { Self.seedLock.unlock() }
        if Self.builtinSeeded { return }

        let schema = ParamSchema.shared
        // 元数据不可用 → 不补种（也不置 once：元数据恢复后还能补）
        guard schema.isAvailable, !schema.builtinOrder.isEmpty else { return }

        var refreshed: [String] = []
        do {
            try SQLiteWriter.shared.write { tx in
                // ⚠ `try`：墓碑读失败会抛出 → 走到下面的 catch（失败不置 once 标记，下次调用重试）；
                //   墓碑状态未知时**不能补种**（那会把用户删过的出厂版本重新种回来）。
                let deleted = try Self.deletedSet(tx)
                let now = Int(Date().timeIntervalSince1970)
                for name in schema.builtinOrder {
                    if deleted.contains(name) { continue }
                    guard let file = schema.builtinFile(name), let params = Self.loadBuiltinFile(file) else {
                        Self.log(tx, "params", "builtin_load_error", "\(name): 随包文件缺失或损坏")
                        continue
                    }
                    let payload = PyJSON.encode(params)
                    let note = (params["note"] as? String) ?? ""
                    // 已有行**一律不动**（出厂行落库后即用户数据；覆盖只走「恢复出厂设置」）
                    if try tx.query("SELECT 1 FROM param_versions WHERE name=?", [name]).isEmpty {
                        try tx.execute("INSERT INTO param_versions"
                                       + "(name, params_json, is_builtin, note, created_at) VALUES(?,?,?,?,?)",
                                       [name, payload, 1, note, now])
                        refreshed.append("\(name)(新建)")
                    }
                }

                // ── 激活指针兜底
                let active = try Self.counter(tx, "active_param_version") ?? ""
                if active.isEmpty {
                    try Self.setCounter(tx, "active_param_version", schema.defaultActive)
                } else if schema.builtinFile(active) == nil {
                    // 指针停在"已废弃的旧命名出厂行"（名字已不在出厂清单）：不会被上面的
                    // 补种覆盖，引擎会长期用旧参数且毫无报错 → 自动回退出厂默认
                    let stale = try tx.query("SELECT 1 FROM param_versions WHERE name=? AND is_builtin=1",
                                             [active])
                    if !stale.isEmpty {
                        try Self.setCounter(tx, "active_param_version", schema.defaultActive)
                        Self.log(tx, "params", "active_redirected",
                                 "激活版本 \(active) 已废弃（不在出厂清单内）→ 自动回退 \(schema.defaultActive)")
                        refreshed.append("active:\(active)→\(schema.defaultActive)")
                    }
                }

                // ── 出厂默认升级（一次性）
                // 旧默认仍在出厂清单里（保留回滚），指针不会"失效"，故需要标记键只触发一次；
                // 用户此后手动切回旧版不会被反复改回。
                let flag = try Self.counter(tx, schema.migrationFlagKey) ?? ""
                if flag != schema.defaultActive {
                    let curName = ((try Self.counter(tx, "active_param_version") ?? "").isEmpty)
                        ? schema.defaultActive
                        : (try Self.counter(tx, "active_param_version") ?? "")
                    if let target = schema.supersededDefaults[curName], schema.builtinFile(target) != nil {
                        try Self.setCounter(tx, "active_param_version", target)
                        Self.log(tx, "params", "active_migrated", "出厂默认升级：\(curName) → \(target)")
                        refreshed.append("active:\(curName)→\(target)")
                    }
                    try Self.setCounter(tx, schema.migrationFlagKey, schema.defaultActive)
                }
            }
        } catch {
            // 失败不置 once 标记 → 下次调用重试
            Self.logEvent("params", "builtin_seed_error",
                          (error as? LocalizedError)?.errorDescription ?? String(describing: error))
            return
        }

        Self.builtinSeeded = true
        if !refreshed.isEmpty {
            Self.logEvent("params", "builtin_synced", refreshed.joined(separator: "、"))
        }
    }

    /// **恢复出厂设置**（界面上的显式用户动作；启动补种**不**做这件事）：
    /// 把出厂清单里每个版本用随包文件覆盖（参数 + 描述），被墓碑删除的行重建并清墓碑。
    /// 用户版本一律不动。返回覆盖/重建的行数。
    ///
    /// ⚠ 随包文件读取在事务**外**完成（纯文件 IO，读失败不碰库）；事务内只做落库。
    public func restoreBuiltins() throws -> Int {
        let schema = ParamSchema.shared
        guard schema.isAvailable, !schema.builtinOrder.isEmpty else {
            throw SQLiteWriteError(message: "参数元数据不可用（随包 JSON 缺失或损坏），无法恢复出厂设置")
        }
        var targets: [(name: String, payload: String, note: String)] = []
        for name in schema.builtinOrder {
            guard let file = schema.builtinFile(name), let params = Self.loadBuiltinFile(file) else { continue }
            targets.append((name, PyJSON.encode(params), (params["note"] as? String) ?? ""))
        }
        guard !targets.isEmpty else {
            throw SQLiteWriteError(message: "随包出厂文件全部缺失或损坏，无可恢复内容")
        }
        return try SQLiteWriter.shared.write { tx in
            let now = Int(Date().timeIntervalSince1970)
            var restored: [String] = []
            var deleted = try Self.deletedSet(tx)
            for t in targets {
                if try tx.query("SELECT 1 FROM param_versions WHERE name=?", [t.name]).isEmpty {
                    try tx.execute("INSERT INTO param_versions"
                                   + "(name, params_json, is_builtin, note, created_at) VALUES(?,?,?,?,?)",
                                   [t.name, t.payload, 1, t.note, now])
                } else {
                    try tx.execute("UPDATE param_versions SET params_json=?, note=?, is_builtin=1 WHERE name=?",
                                   [t.payload, t.note, t.name])
                }
                // 恢复的行同时清墓碑（否则下次启动补种仍会跳过它）
                deleted.remove(t.name)
                restored.append(t.name)
            }
            // 墓碑写回：序列化失败**必须抛错**，不许回落空数组（理由同 `delete`）
            guard let d = try? JSONSerialization.data(withJSONObject: deleted.sorted()),
                  let json = String(data: d, encoding: .utf8) else {
                throw SQLiteWriteError(message: "墓碑序列化失败，恢复已中止")
            }
            try Self.setCounter(tx, Self.deletedBuiltinsKey, json)
            Self.log(tx, "params", "builtin_restored", "恢复出厂版本 \(restored.count) 个：\(restored.joined(separator: "、"))")
            return restored.count
        }
    }

    /// 只更新版本描述（不碰参数）。出厂与用户版本都可改——出厂行落库后即用户数据，
    /// 启动补种不会覆盖回来（见 `ensureBuiltinSeeded` 的 2026-10-15 语义变更）。
    @discardableResult
    public func setNote(name: String, note: String) throws -> Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return try SQLiteWriter.shared.write { tx in
            try tx.execute("UPDATE param_versions SET note=? WHERE name=?", [note, name]) > 0
        }
    }

    /// 随包出厂参数文件（按文件名读；与 `builtinParams` 同源）
    private static func loadBuiltinFile(_ file: String) -> [String: Any]? {
        for path in ParamSchema.resourceCandidates("engine/params/" + file) {
            guard let data = FileManager.default.contents(atPath: path),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            return obj
        }
        return nil
    }

    private static func counter(_ tx: WriteTx, _ key: String) throws -> String? {
        let rows = try tx.query("SELECT value FROM counters WHERE key=?", [key])
        return rows.first?["value"] as? String
    }

    private static func setCounter(_ tx: WriteTx, _ key: String, _ value: String) throws {
        try tx.execute("INSERT OR REPLACE INTO counters(key, value) VALUES(?, ?)", [key, value])
    }

    // 委托 ChinaTime.formatter（与 DataSources.logDataSource 同格式）
    private static let seedLogFormatter = ChinaTime.formatter("yyyy-MM-dd'T'HH:mm:ss")

    /// 事务内写 data_source_logs（与 DataSources.logDataSource 同格式，detail 截断 500）
    private static func log(_ tx: WriteTx, _ source: String, _ event: String, _ detail: String) {
        // ⚠ 写失败不能静默吞掉：留一行 NSLog 痕迹，主流程不阻断（与 DataSources.logDataSource 同语义）。
        if (try? tx.execute("INSERT INTO data_source_logs(ts, source, event, detail) VALUES(?,?,?,?)",
                        [seedLogFormatter.string(from: Date()), source, event,
                         String(detail.prefix(500))])) == nil {
            NSLog("[NOTICE] data_source_logs 写入失败（事务内，参数日志丢失）：%@",
                  String(detail.prefix(80)))
        }
    }

    /// 事务外写 data_source_logs（自备连接；与 DataSources.logDataSource 同语义，写失败静默）。
    /// 不复用 DataSources：本类是参数/DB 层，不该耦合到行情抓取层。
    private static func logEvent(_ source: String, _ event: String, _ detail: String) {
        do {
            _ = try SQLiteWriter.shared.write { tx in
                try tx.execute("INSERT INTO data_source_logs(ts, source, event, detail) VALUES(?,?,?,?)",
                               [seedLogFormatter.string(from: Date()), source, event,
                                String(detail.prefix(500))])
            }
        } catch {
            // 写失败留一行痕迹，主流程不阻断（与 log() 同语义）。
            NSLog("[NOTICE] data_source_logs 写入失败（事务外，参数日志丢失）：%@",
                  String(describing: error))
        }
    }

    // MARK: 参数解析

    /// 随包出厂参数文件（DB 行缺失时的兜底；正常情况下 `ensureBuiltinSeeded` 已补种，走 DB）
    private func builtinParams(_ name: String) -> [String: Any]? {
        guard let file = ParamSchema.shared.builtinFile(name) else { return nil }
        return Self.loadBuiltinFile(file)
    }

    private static func parse(_ json: String) -> [String: Any]? {
        guard let d = json.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }

    /// 激活版本的完整参数：DB → 出厂文件 → 出厂默认版本兜底。
    /// 返回 nil 只可能是"库与随包文件都读不到"——调用方必须**明确报错**
    /// （无回落，也绝不能静默用空参数继续算）
    public func activeParams() -> [String: Any]? {
        ensureBuiltinSeeded()
        let name = activeName()
        let effective = name.isEmpty ? ParamSchema.shared.defaultActive : name
        if let json = versionParamsJSON(effective), let d = Self.parse(json) { return d }
        if let d = builtinParams(effective) { return d }
        return builtinParams(ParamSchema.shared.defaultActive)
    }

    /// 指定版本的参数：出厂版本读随包文件（被删的出厂版本返回 nil）
    public func versionParams(_ name: String) -> [String: Any]? {
        if ParamSchema.shared.builtinFile(name) != nil {
            if deletedBuiltins().contains(name) { return nil }
            return builtinParams(name)
        }
        if let json = versionParamsJSON(name) { return Self.parse(json) }
        return nil
    }

    /// UI 表单基线。
    ///
    /// ⚠ 与 `versionParams` 有意不同：出厂版本这里**不查墓碑** ——
    /// 编辑一个已删的出厂版本时仍以随包文件为基线。
    public func paramsForSchema(version: String?) -> [String: Any]? {
        guard let v = version, !v.isEmpty else { return activeParams() }
        if ParamSchema.shared.builtinFile(v) != nil { return builtinParams(v) }
        if let json = versionParamsJSON(v), let d = Self.parse(json) { return d }
        return activeParams()
    }

    // MARK: 写

    /// 激活版本。返回 false = 版本不存在（不静默成功）
    @discardableResult
    public func activate(_ name: String) throws -> Bool {
        ensureBuiltinSeeded()   // 出厂行必须先补种，否则新库激活不了
        guard versionExists(name) else { return false }
        try SQLiteWriter.shared.write { tx in
            _ = try tx.execute("INSERT OR REPLACE INTO counters(key, value) "
                               + "VALUES('active_param_version', ?)", [name])
            // 记下这一版从**哪一天**起生效 —— 调优要按每条样本的 sel_date
            // 反查"当天用的是哪一版"（见 `versionEffectiveOn`）。
            // 列由 `DBBootstrap.ensureSwiftOnlyMigrations` 保证存在；缺列会显式抛错，不静默跳过。
            _ = try tx.execute("UPDATE param_versions SET effective_from=? WHERE name=?",
                               [ChinaTime.day(), name])
        }
        return true
    }

    /// 某交易日**当天生效的参数版本** —— 取 `effective_from <= date` 里最近的一版。
    ///
    /// 返回 nil = 查不到（该日期早于所有已记录版本 / 所有版本都没生效日期）→
    /// **调用方回落当前激活版本，不猜**。
    public func versionEffectiveOn(date: String) -> String? {
        guard !date.isEmpty else { return nil }
        let rows = query("SELECT name FROM param_versions "
                         + "WHERE effective_from IS NOT NULL AND effective_from <= ? "
                         + "ORDER BY effective_from DESC, name ASC LIMIT 1", [date])
        return rows.first?["name"] as? String
    }

    /// 删除版本。返回 false = 受保护 / 不存在。
    ///
    /// ⚠ 墓碑**只对出厂版本名**记录：自定义版本名若被永久记进墓碑，
    /// 日后它若成为新的出厂版本名，`ensureBuiltinSeeded` 会一直跳过它
    /// → `listVersions` 里看不到、`activate` 也激活不了，且没有任何提示。
    @discardableResult
    public func delete(_ name: String) throws -> Bool {
        if name.isEmpty || Self.protectedVersions.contains(name) { return false }
        if name == activeName() { return false }          // 当前激活版本不可删
        // 出厂名判定在事务外取一次即可（出厂名集合来自随包 JSON，运行期不变）
        let isBuiltin = ParamSchema.shared.builtinNames.contains(name)
        return try SQLiteWriter.shared.write { tx in
            let n = try tx.execute("DELETE FROM param_versions WHERE name=?", [name])
            if n > 0 && isBuiltin {
                var names = Array(try Self.deletedSet(tx)).sorted()
                if !names.contains(name) { names.append(name); names.sort() }
                // ⚠ 序列化失败**必须抛错**，不能回落 `"[]"`：下面这行是 `INSERT OR REPLACE` ——
                //   用空数组覆写 counters 会把此前所有墓碑抹掉 → 下次启动 `ensureBuiltinSeeded`
                //   把用户删过的出厂版本全部补种回来（"删了又回来"，且无任何报错）。
                //   宁可不写，也不能用空集合覆盖既有墓碑。
                let data = try JSONSerialization.data(withJSONObject: names)
                guard let json = String(data: data, encoding: .utf8) else {
                    throw SQLiteWriteError(message: "墓碑列表序列化后不是合法 UTF-8")
                }
                try tx.execute("INSERT OR REPLACE INTO counters(key, value) VALUES(?, ?)",
                               [Self.deletedBuiltinsKey, json])
            }
            return n > 0
        }
    }

    /// 读「已删除的出厂版本」墓碑集合。
    ///
    /// ⚠ **读失败必须抛错，不许回落空集合**：`delete()` 拿到空集合后会用 `[name]`
    ///   覆写 counters，把此前所有墓碑抹掉 → 下一次 `ensureBuiltinSeeded`
    ///   会把用户删掉的出厂版本全部补种回来。这种故障不报错、不崩，只是结果悄悄错。
    ///
    /// ⚠ 但**「键不存在」与「键存在但为空」是正常状态**（首次启动没有墓碑），返回空集合；
    ///   只有"读失败"与"值不是字符串数组"才抛错。
    private static func deletedSet(_ tx: WriteTx) throws -> Set<String> {
        let rows = try tx.query("SELECT value FROM counters WHERE key=?", [deletedBuiltinsKey])
        guard let s = rows.first?["value"] as? String, !s.isEmpty else { return [] }
        guard let d = s.data(using: .utf8) else {
            throw SQLiteWriteError(message: "墓碑 counters 值不是合法 UTF-8")
        }
        guard let arr = try JSONSerialization.jsonObject(with: d) as? [String] else {
            throw SQLiteWriteError(message: "墓碑 counters 值不是字符串数组")
        }
        return Set(arr)
    }

    /// 另存为新版本（不改变激活状态）。返回 false = 名称为空 / 受保护名 / 出厂版本名。
    /// ⚠ 调用方需自行保证 params 已通过校验（见 `saveEditedVersion`）。
    @discardableResult
    public func saveVersion(_ name: String, paramsJSON: String, note: String = "") throws -> Bool {
        if name.isEmpty || Self.protectedVersions.contains(name) { return false }
        if ParamSchema.shared.builtinNames.contains(name) { return false }   // 出厂版本不可覆盖
        let ts = Int(Date().timeIntervalSince1970)
        return try SQLiteWriter.shared.write { tx in
            try tx.execute("INSERT OR REPLACE INTO param_versions"
                           + "(name, params_json, is_builtin, note, created_at) VALUES(?,?,0,?,?)",
                           [name, paramsJSON, note, ts])
            return true
        }
    }

    /// 另存为新版本（字典形态）。
    ///
    /// 落库 JSON 用 `PyJSON.encode`，避免 `JSONSerialization` 把 Double 3.0 写成 `3`
    /// 导致落库口径退化。键序按字典序，取值按键路径，语义等价。
    @discardableResult
    public func saveVersion(_ name: String, params: [String: Any], note: String = "") throws -> Bool {
        try saveVersion(name, paramsJSON: PyJSON.encode(params), note: note)
    }

    // MARK: 保存

    /// 从 UI 保存编辑后的参数为新版本（diff 与激活版本合并，校验通过才落库）。
    /// 返回错误串，空串 = 成功，便于调用方直接展示。
    ///
    /// 校验顺序：出厂名 → 空名 → 合并 → 校验 → 落库。
    /// 激活参数读不到时返回可读错误（不静默写空参数）。
    public func saveEditedVersion(name: String, diff: [String: Any], note: String = "") throws -> String {
        let schema = ParamSchema.shared
        guard schema.isAvailable else { return "参数元数据不可用" }
        if schema.builtinNames.contains(name) { return "出厂版本不可覆盖，请使用新名称" }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "版本名称不能为空" }
        guard let base = activeParams() else { return "参数合并失败：激活版本参数不可读" }
        var merged = schema.applyDiff(base: base, diff: diff)
        // ⚠ 正则可编译性与结构化形状（如 .timePair HH:mm / 阈值表键）在保存兜底再查一次，
        //   不并进 `validate`（理由见 `ParamSchema.regexParamErrors` 与 `ParamSchemaContractTests`）。
        let shapeErrors = diff.keys.sorted().compactMap { key -> String? in
            guard ParamTableSpecs.has(key), let v = ParamSchema.getValue(merged, key) else { return nil }
            return ParamTableSpecs.problem(key, value: v)
        }
        let errors = schema.validate(merged) + ParamSchema.regexParamErrors(merged) + shapeErrors
        if !errors.isEmpty {
            return "参数校验失败：" + errors.prefix(5).joined(separator: "；")
        }
        merged["version_name"] = name
        let ok = try saveVersion(name, params: merged, note: note)
        return ok ? "" : "保存失败：版本名冲突或非法"
    }

    /// 实现收敛到 `Num.intOrNil`（与 `CompareStore.intOf` / `Signals.intOf` 同一语义）。
    public static func intOf(_ v: Any?) -> Int? { Num.intOrNil(v) }

    public func close() {
        conn.close()
    }
}
