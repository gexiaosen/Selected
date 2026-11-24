import Foundation

/// 个股基本面的落库与读取。
///
/// ## 为什么是主库里的 Swift-only 表
/// 与 `index_members` / `limit_up_pool` / `board_heat` 同一条路：建表挂
/// `DBBootstrap.ensureSwiftOnlySchemaOnDisk`。⚠ **不写进** `engine/params/db_schema_export.json`。
///
/// ## ⚠ 读为什么**可以**用 `SQLiteReader.shared`
/// 本表目前**唯一的读方是详情页与设置页，都在主线程**。
/// ⚠ **若将来要在后台读它**（比如某个 job 要按 ROE 过滤），**必须**改成自持
/// `query_only` 连接 + 串行队列 —— 否则同连接跨线程并发会 **SIGSEGV**。
///
/// ## ⚠ 为什么**不**落进 `securities`
/// `securities` 是"**整表替换**的证券主列表"，来源是**新浪**；
/// 基本面来自**东财**（另一个源）。混进一张表会让两个源的刷新互相覆盖，而且是**静默**的。
///
/// ## ⚠ 列**可为 NULL**（源用 `"-"` 表示"没有"）→ **一律不给 `DEFAULT`**
/// `NULL` 才是"源没给"的正确表示。给个 `DEFAULT 0` 会让界面显示
/// "资产负债率 0%"（那是"无负债"，与"没数据"完全不同的结论）。
/// ⚠ 这与 `reviews.scan_mode` 的 `DEFAULT 'live'` **恰好相反** —— 那里 DEFAULT 是必须的。
public enum FundamentalStore {

    /// 建表 DDL（`IF NOT EXISTS` 天然幂等，每次打开都跑一遍）。
    ///
    /// ⚠ **不建二级索引**：本表的查询只有 `WHERE code=?`（主键），
    /// 需要按某列**聚合读回一批代码**的表才配索引；本表只按 code 点查，加了是白付写入成本。
    /// 少一个索引 = 少一处要登记的东西。
    public static let createSQL = """
    CREATE TABLE IF NOT EXISTS stock_fundamentals (
        code            TEXT PRIMARY KEY,
        name            TEXT NOT NULL DEFAULT '',
        pe_dynamic      REAL,
        pe_static       REAL,
        pe_ttm          REAL,
        pb              REAL,
        eps             REAL,
        bvps            REAL,
        roe             REAL,
        revenue         REAL,
        net_profit      REAL,
        revenue_yoy     REAL,
        net_profit_yoy  REAL,
        debt_ratio      REAL,
        fetched_at      TEXT NOT NULL DEFAULT ''
    );
    """

    // MARK: - 写

    /// **整表替换**（先清空再整批插，同一事务）。
    ///
    /// ⚠ 先清后插必须同事务：半截提交会留下"一半票有基本面、一半没有"——
    /// 界面上看不出异常（只是有些票的卡片空着），而真相是数据缺了一半。
    @discardableResult
    public static func replaceAll(_ items: [Fundamental.Item], at stamp: String) throws -> Int {
        try SQLiteWriter.shared.write { tx in
            try tx.execute("DELETE FROM stock_fundamentals")
            let rows: [[Any?]] = items.map { it in
                [it.code, it.name, it.peDynamic, it.peStatic, it.peTtm, it.pb,
                 it.eps, it.bvps, it.roe, it.revenue, it.netProfit,
                 it.revenueYoy, it.netProfitYoy, it.debtRatio, stamp]
            }
            try tx.executeBatch(
                "INSERT OR REPLACE INTO stock_fundamentals"
                + "(code, name, pe_dynamic, pe_static, pe_ttm, pb, eps, bvps, roe,"
                + " revenue, net_profit, revenue_yoy, net_profit_yoy, debt_ratio, fetched_at)"
                + " VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                rows: rows)
            return items.count
        }
    }

    /// 清空（基本面是可重取的公开数据）
    public static func deleteAll() throws {
        _ = try SQLiteWriter.shared.write { tx in
            try tx.execute("DELETE FROM stock_fundamentals")
        }
    }

    // MARK: - 抓取 + 落库（带**下界护栏**）

    /// 抓全市场基本面并整表替换。
    ///
    /// ⚠ **下界护栏**：
    /// `FundamentalSource.fetchAll` 对"抓取失败"与"真的一只都没有"都返回 `nil`
    /// （它分不清），所以这里必须再判一次条数 —— 低于 `Fundamental.minStocks` 就
    /// **不写库、保留旧数据**，并如实报告原因。
    /// - Parameter fetch: 抓取闭包。默认走真实网络；**可注入**是为了让"下界护栏"
    ///   能被离线验证（`Tools/classify_test.sh` 注入假 fetch 走的就是这个口子）。
    @discardableResult
    public static func refresh(fetch: () -> FundamentalFetch? = FundamentalSource.fetchAll)
        -> Fundamental.Report {
        var report = Fundamental.Report()
        // ⚠ 先清掉本端点的旧 HTTP 错误，再在失败时**如实带上真原因** ——
        //   否则"源无响应或返回不完整"会把"被限流"与"没网"混成一件事，界面上看不出该往哪查。
        DataSources.clearFetchFailure(matching: FundamentalSource.failureScope)
        guard let fetched = fetch() else {
            report.rejected = DataSources.fetchFailureMessage(
                DataSources.lastFetchFailureReason(matching: FundamentalSource.failureScope))
            DataSources.logDataSource("fundamental", "refresh_failed", report.rejected ?? "")
            return report
        }
        let items = fetched.items
        guard items.count >= Fundamental.minStocks else {
            report.rejected = "只拿到 \(items.count) 只 < 下界 \(Fundamental.minStocks)"
            DataSources.logDataSource("fundamental", "refresh_rejected", report.rejected ?? "")
            return report
        }
        do {
            let n = try replaceAll(items, at: PhaseStore.nowStamp())
            report.stocks = n
            // ⚠ "刷新了 5000 只"与"其中 5000 只有数据"是两件事 ——
            //   源对退市/停牌票会返回全 `-`，那些行**落库了但没有数据**。
            //   如实分开报，否则用户会以为基本面覆盖很全。
            report.withData = items.filter { $0.peDynamic != nil || $0.roe != nil
                || $0.revenue != nil }.count
        } catch {
            report.rejected = "落库失败：\(error)"
            DataSources.logDataSource("fundamental", "refresh_write_failed", "\(error)")
        }
        return report
    }

    // MARK: - 读（走主线程专用共享连接 ⇒ 逐个标 `@MainActor`，编译器强制）

    /// 读方法全部走 `SQLiteReader.shared`（**主线程专用**共享连接），故标 `@MainActor`：
    /// 后台代码引用它们会**直接编译失败**。
    /// ⚠ 本文件读段后面还有非隔离的解析辅助（`num`），所以没法像 `IndexMembersStore`
    /// 那样整段收进 `@MainActor extension` —— 新加读方法时**记得自己带上 `@MainActor`**。

    /// 后台线程专用读入口：由调用方传入独立只读连接（`SQLiteReader.makeIndependent()`），
    /// 避免跨线程触碰 `@MainActor SQLiteReader.shared`。
    public static func fundamentals(of code: String, reader: SQLiteReader) -> Fundamental.Item? {
        guard !code.isEmpty else { return nil }
        guard let r = reader.queryRaw(
            "SELECT * FROM stock_fundamentals WHERE code=? LIMIT 1", [code]).first else {
            return nil
        }
        func d(_ k: String) -> Double? { num(r[k]) }
        return Fundamental.Item(
            code: (r["code"] as? String) ?? code,
            name: (r["name"] as? String) ?? "",
            peDynamic: d("pe_dynamic"), peStatic: d("pe_static"), peTtm: d("pe_ttm"),
            pb: d("pb"), eps: d("eps"), bvps: d("bvps"), roe: d("roe"),
            revenue: d("revenue"), netProfit: d("net_profit"),
            revenueYoy: d("revenue_yoy"), netProfitYoy: d("net_profit_yoy"),
            debtRatio: d("debt_ratio"))
    }

    /// 某只票的基本面；无记录 → `nil`
    @MainActor
    public static func fundamentals(of code: String) -> Fundamental.Item? {
        fundamentals(of: code, reader: SQLiteReader.shared)
    }

    /// 表里有多少只票（0 = 还没抓过 → 详情页卡片不显示）
    @MainActor
    public static func total() -> Int {
        (SQLiteReader.shared.queryRaw("SELECT COUNT(*) AS n FROM stock_fundamentals", [])
            .first?["n"] as? Int) ?? 0
    }

    /// **至少一项有值**的只数。
    ///
    /// ⚠ 与 `total()` **必须分开报**：源对退市 / 长期停牌票会返回**全 `-`**，
    /// 那些行**落库了但没有数据**。"刷新了 5000 只"与"5000 只有数据"是两件事 ——
    /// 只报前者会让用户以为基本面覆盖很全。
    ///
    /// ⚠ 判据取"三个不同组的代表字段"（估值 / 盈利 / 规模），
    /// 而不是"13 个字段全非空" —— 后者会把"只有 PE 没有 ROE"的票也算成没数据。
    @MainActor
    public static func withDataCount() -> Int {
        (SQLiteReader.shared.queryRaw(
            "SELECT COUNT(*) AS n FROM stock_fundamentals"
            + " WHERE pe_dynamic IS NOT NULL OR roe IS NOT NULL OR revenue IS NOT NULL", [])
            .first?["n"] as? Int) ?? 0
    }

    /// 最近一次刷新时间
    @MainActor
    public static func lastFetched() -> String? {
        let v = SQLiteReader.shared
            .queryRaw("SELECT MAX(fetched_at) AS t FROM stock_fundamentals", [])
            .first?["t"] as? String
        return (v?.isEmpty ?? true) ? nil : v
    }

    /// REAL 列 → `Double?`（`NULL` 保持 `nil`，**不折成 0**）。
    ///
    /// ⚠ 首选 `Double`：读取层对 `SQLITE_FLOAT` 返回的就是 `Double`。
    /// 不用 `NSNumber.doubleValue` 做首选 —— 那对长小数**不是正确舍入**
    /// （见 `FundamentalSource.num`）。
    static func num(_ v: Any?) -> Double? {
        if v == nil || v is NSNull { return nil }
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let dec = v as? NSDecimalNumber { return Double(dec.stringValue) }
        if let n = v as? NSNumber { return n.doubleValue }
        return nil
    }
}
