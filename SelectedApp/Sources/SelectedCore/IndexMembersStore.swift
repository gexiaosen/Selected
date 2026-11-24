import Foundation

/// 指数成份的落库与读取（主库里的 Swift-only 表，建表挂
/// `DBBootstrap.ensureSwiftOnlySchemaOnDisk`）。
///
/// ⚠ **不写进** `engine/params/db_schema_export.json`。
///
/// ⚠ 读只有一处消费方：个股详情页头卡（主线程），故可直接用 `SQLiteReader.shared`
/// （**主线程专用**共享连接）。若将来要在后台读它，**必须**改成自持 `query_only` 连接，
/// 不要直接复用本类的读方法。
public enum IndexMembersStore {

    /// 建表 DDL（`IF NOT EXISTS` 天然幂等，每次打开都跑一遍）
    ///
    /// 主键 `(index_code, code)`：一个指数里一只票只有一行 → `replace` 可安全重跑。
    /// 另建 `idx_index_members_code`：详情页问的是"**这只票**属于哪些指数"，
    /// 主键索引（index_code 在前）帮不上忙。
    public static let createSQL = """
    CREATE TABLE IF NOT EXISTS index_members (
        index_code TEXT NOT NULL,
        code       TEXT NOT NULL,
        name       TEXT NOT NULL DEFAULT '',
        fetched_at TEXT NOT NULL DEFAULT '',
        PRIMARY KEY (index_code, code)
    );
    CREATE INDEX IF NOT EXISTS idx_index_members_code ON index_members(code);
    """

    /// 索引名
    public static let codeIndexName = "idx_index_members_code"

    /// 刷新报告
    public struct Report: Equatable, Sendable {
        /// 成功写入的指数（code）
        public var refreshed: [String] = []
        /// **被下界断言拦下**、因而**保留旧数据**的指数（code → 原因）
        public var rejected: [String: String] = [:]
        /// 各指数的成份数（写入后的）
        public var counts: [String: Int] = [:]

        public var summary: String {
            let ok = refreshed.map { "\($0) \(counts[$0] ?? 0) 只" }.joined(separator: " / ")
            let bad = rejected.map { "\($0)：\($1)" }.sorted().joined(separator: "；")
            var parts: [String] = []
            if !ok.isEmpty { parts.append("已刷新 " + ok) }
            if !bad.isEmpty { parts.append("未刷新（保留旧数据）" + bad) }
            return parts.isEmpty ? "无变化" : parts.joined(separator: "；")
        }
    }

    // MARK: - 写

    /// 整表替换一个指数的成份（同 `securities` 的"整表替换"语义）。
    ///
    /// ⚠ **先删后插必须在同一事务里**：半截提交会留下"这个指数只剩一半成份"，
    /// 那种数据比没有更糟 —— 界面照样显示徽章，只是漏了一大半，而且**没有任何信号**。
    @discardableResult
    public static func replace(indexCode: String, members: [IndexMembers.Member],
                               at stamp: String) throws -> Int {
        guard !indexCode.isEmpty else { return 0 }
        return try SQLiteWriter.shared.write { tx in
            try tx.execute("DELETE FROM index_members WHERE index_code=?", [indexCode])
            let rows: [[Any?]] = members.map { [indexCode, $0.code, $0.name, stamp] }
            try tx.executeBatch(
                "INSERT OR REPLACE INTO index_members(index_code, code, name, fetched_at) VALUES(?,?,?,?)",
                rows: rows)
            return members.count
        }
    }

    /// 清空（成份是可重建的公开数据）
    public static func deleteAll() throws {
        _ = try SQLiteWriter.shared.write { tx in
            try tx.execute("DELETE FROM index_members")
        }
    }

    // MARK: - 抓取 + 落库（带**数量下界断言**）

    /// 刷新若干指数（默认全部）。
    ///
    /// ⚠ **下界断言是这一步存在的理由**：`IndexMembersSource.fetch` 对"抓取失败"与
    /// "真的是空"都返回 `[]`，而节点名写错时新浪就是返回空数组。若拿 `[]` 直接覆盖，
    /// 界面表现为"这只票不是任何指数成份"——完全看不出是错的。
    /// 所以：数量低于 `Index.minCount` → **不写，保留旧数据**，并如实报告。
    ///
    /// - Parameter fetch: 抓取闭包，默认走真实网络；**可注入**是为了让下界护栏能被离线验证。
    /// - Returns: 每个指数的结局（成功的、被拦下的、以及写入后的数量）
    @discardableResult
    public static func refresh(_ targets: [IndexMembers.Index] = IndexMembers.indices,
                               fetch: (IndexMembers.Index) -> [IndexMembers.Member]
                                    = IndexMembersSource.fetch) -> Report {
        var report = Report()
        let stamp = PhaseStore.nowStamp()
        for idx in targets {
            let members = fetch(idx)
            let verdict = IndexMembersSource.acceptance(count: members.count, index: idx)
            guard verdict.ok else {
                let why = verdict.reason ?? "数量不足"
                report.rejected[idx.code] = why
                DataSources.logDataSource("sina", "index_members_rejected",
                                          "\(idx.name)（node=\(idx.node)）\(why) → 保留旧数据")
                continue
            }
            do {
                let n = try replace(indexCode: idx.code, members: members, at: stamp)
                report.refreshed.append(idx.code)
                report.counts[idx.code] = n
            } catch {
                report.rejected[idx.code] = "落库失败：\(error)"
                DataSources.logDataSource("sina", "index_members_write_failed",
                                          "\(idx.name)：\(error)")
            }
        }
        return report
    }
    /// 后台线程专用读入口：由调用方传入独立只读连接（`SQLiteReader.makeIndependent()`），
    /// 避免跨线程触碰 `@MainActor SQLiteReader.shared`。
    public static func indicesOf(code: String, reader: SQLiteReader) -> [String] {
        guard !code.isEmpty else { return [] }
        let rows = reader.queryRaw(
            "SELECT DISTINCT index_code FROM index_members WHERE code=?", [code])
        let hit = Set(rows.compactMap { $0["index_code"] as? String })
        // 按清单顺序返回（界面上"沪深300 / 中证500"的先后是固定的，不随查询顺序漂）
        return IndexMembers.indices.map(\.code).filter { hit.contains($0) }
    }
}

// MARK: - 读（走主线程专用共享连接 ⇒ `@MainActor`，编译器强制）

/// 读方法全部走 `SQLiteReader.shared`（**主线程专用**共享连接），故整段用 `@MainActor` 收口：
/// 新加读方法只要落在这个 extension 里就自动继承约束，后台代码引用它会**直接编译失败**。
@MainActor
extension IndexMembersStore {

    /// 某只票所属的指数（`code` 列表，按 `IndexMembers.indices` 的顺序返回）。
    public static func indicesOf(code: String) -> [String] {
        indicesOf(code: code, reader: SQLiteReader.shared)
    }

    /// 各指数的成份数（`index_code → 只数`）。用于设置页/自检展示。
    public static func counts() -> [String: Int] {
        var out: [String: Int] = [:]
        for r in SQLiteReader.shared.queryRaw(
            "SELECT index_code, COUNT(*) AS n FROM index_members GROUP BY index_code", []) {
            guard let c = r["index_code"] as? String else { continue }
            out[c] = (r["n"] as? Int) ?? 0
        }
        return out
    }

    /// 最近一次刷新时间（`index_code → fetched_at`）
    public static func lastFetched() -> [String: String] {
        var out: [String: String] = [:]
        for r in SQLiteReader.shared.queryRaw(
            "SELECT index_code, MAX(fetched_at) AS t FROM index_members GROUP BY index_code", []) {
            guard let c = r["index_code"] as? String, let t = r["t"] as? String else { continue }
            out[c] = t
        }
        return out
    }

    /// 某个指数的全部成份代码（自检用；也供将来的"只做权重股"开关）
    public static func members(ofIndex indexCode: String) -> [String] {
        guard !indexCode.isEmpty else { return [] }
        return SQLiteReader.shared.queryRaw(
            "SELECT code FROM index_members WHERE index_code=? ORDER BY code", [indexCode])
            .compactMap { $0["code"] as? String }
    }
}
