import Foundation
import SQLite3

/// 一条资金流记录（某标的 · 某交易日）
///
/// ⚠ 单位：`netAmount` / `mainNet` 是**元**（原始值，不折算成万元/亿元 —— 折算留给展示层，
/// 存储保持原始精度）。`changePct` / `mainRatio` 是**小数**（`0.0123` = +1.23%），
/// 与 `DataSources` 的 `changeratio` 原样一致。
public struct FundFlowPoint: Equatable, Sendable {

    /// 交易日 `yyyy-MM-dd`
    public let date: String
    /// 6 位代码（**不带**市场前缀；新浪返回的是 `sh600000`，解析时已剥掉）
    public let code: String
    public let name: String
    /// 收盘价
    public let close: Double
    /// 涨跌幅（小数）
    public let changePct: Double
    /// **总净流入**（元）= `inamount - outamount`
    public let netAmount: Double
    /// **主力净额**（元）= 超大单 + 大单；`r0_in - r0_out` 恒等
    public let mainNet: Double
    /// 主力净占比（小数）
    public let mainRatio: Double

    public init(date: String, code: String, name: String, close: Double,
                changePct: Double, netAmount: Double, mainNet: Double, mainRatio: Double) {
        self.date = date
        self.code = code
        self.name = name
        self.close = close
        self.changePct = changePct
        self.netAmount = netAmount
        self.mainNet = mainNet
        self.mainRatio = mainRatio
    }
}

/// 资金流的存储层：`stock_fund_flows` 表（Swift-only 表）。
/// 建表在 `DBBootstrap.ensureSwiftOnlyMigrations`（**独立于版本水位执行**），
/// 不写进 `engine/params/db_schema_export.json`。
///
/// ## ⚠ 读为什么不用 `SQLiteReader.shared`
/// 本类的读方法会被**后台任务**调用（`FundFlowJob` 在 `Task.detached` 里跑）。
/// 而 `SQLiteReader` 的共享连接是**主线程专用**的 —— Apple 系统 libsqlite3 是
/// multi-thread 模式（非 serialized），**同一个连接跨线程并发使用直接 SIGSEGV**。
/// → 本类自持 `query_only` 只读连接（`ReadOnlyConnection`）+ 串行队列。
/// → 写走 `SQLiteWriter.shared`（它本身就是"串行队列 + 唯一写连接"，跨线程安全）。
public enum FundFlowStore {

    public static let table = "stock_fund_flows"

    /// 建表 DDL。`ensureSwiftOnlyMigrations` 调用；`IF NOT EXISTS` 天然幂等。
    ///
    /// 主键 `(trade_date, code)` —— 同一标的同一天只有一行（`INSERT OR REPLACE` 即可重跑）。
    /// 索引按 `(code, trade_date)` 建：详情页的访问模式是"某只票的近 N 日"，
    /// 主键索引在"按 code 单查"上帮不上忙。
    public static let createSQL = """
    CREATE TABLE IF NOT EXISTS stock_fund_flows (
        trade_date TEXT NOT NULL,
        code       TEXT NOT NULL,
        name       TEXT NOT NULL DEFAULT '',
        close      REAL NOT NULL DEFAULT 0,
        change_pct REAL NOT NULL DEFAULT 0,
        net_amount REAL NOT NULL DEFAULT 0,
        main_net   REAL NOT NULL DEFAULT 0,
        main_ratio REAL NOT NULL DEFAULT 0,
        PRIMARY KEY (trade_date, code)
    );
    CREATE INDEX IF NOT EXISTS idx_stock_fund_flows_code
        ON stock_fund_flows(code, trade_date);
    """

    /// 私有只读连接（**不要**换成 `SQLiteReader.shared`，见类注释）
    private static let reader = FundFlowReader()

    /// 转发到 `FundFlowReader.close()`。
    /// 手动释放本 Store 的连接。
    /// ⚠ 换库清单**不需要**再点名本 Store：连接在 `ReadOnlyConnection.init` 里已登记进
    /// `DataConnections`，`closeAll()` 自动覆盖（原先靠人往清单里加一行，实测漏过 4 个）。
    public static func close() {
        reader.close()
    }

    // MARK: - 写

    /// 落库（同一 `(date, code)` 覆盖写，故可安全重跑）。返回写入行数。
    ///
    /// 走 `SQLiteWriter.shared.write`：单事务提交 —— 要么整批进去，要么一行都不进
    /// （避免"抓了一半就断网"留下一个**半截的交易日**，那种数据比没有更糟：
    ///  覆盖率检查看不出，而按日聚合会系统性偏低）。
    @discardableResult
    public static func save(_ rows: [FundFlowPoint]) throws -> Int {
        guard !rows.isEmpty else { return 0 }
        return try SQLiteWriter.shared.write { tx in
            let batch: [[Any?]] = rows.map { r in
                [r.date, r.code, r.name, r.close, r.changePct, r.netAmount, r.mainNet, r.mainRatio]
            }
            try tx.executeBatch(
                "INSERT OR REPLACE INTO stock_fund_flows"
                + "(trade_date, code, name, close, change_pct, net_amount, main_net, main_ratio)"
                + " VALUES(?,?,?,?,?,?,?,?)",
                rows: batch)
            return rows.count
        }
    }

    // MARK: - 读

    /// 某日已落库的行数（幂等检查用）
    ///
    /// ⚠ 读取层对 `SQLITE_INTEGER` 列返回的是 **`Int`**（不是 `NSNumber`）；
    /// 直接判 `Int` 与读取层契约对齐（`as? NSNumber` 只是隐式桥接、不是契约）。
    public static func count(date: String) -> Int {
        reader.query("SELECT COUNT(*) AS n FROM stock_fund_flows WHERE trade_date = ?", [date])
            .first?["n"] as? Int ?? 0
    }

    /// 表内最新的交易日（无数据返回 nil）
    ///
    /// ⚠ 空表时 `MAX()` 返回 NULL，而读取层对 `SQLITE_NULL` 是**整列跳过**（不进字典），
    /// 所以这里既可能拿到 `nil` 也可能拿到空串，两种都要当"没有"。
    public static func latestDate() -> String? {
        let d = reader.query("SELECT MAX(trade_date) AS d FROM stock_fund_flows", [])
            .first?["d"] as? String
        return (d?.isEmpty ?? true) ? nil : d
    }

    /// 某只票的近 `days` 个交易日（**按日期升序**返回，便于直接画趋势）。
    ///
    /// 先 `ORDER BY trade_date DESC LIMIT n` 取"最近 n 天"，再反转成升序 ——
    /// 与 `FundFlowSource` 的对外约定一致（那里是新浪给 DESC、我们反转）。
    public static func history(code: String, days: Int = FundFlowSource.defaultHistoryDays)
        -> [FundFlowPoint] {
        guard days > 0 else { return [] }
        let rows = reader.query(
            "SELECT trade_date, code, name, close, change_pct, net_amount, main_net, main_ratio"
                + " FROM stock_fund_flows WHERE code = ?"
                + " ORDER BY trade_date DESC LIMIT ?", [code, days])
        let pts = rows.compactMap { row -> FundFlowPoint? in
            guard let d = row["trade_date"] as? String, !d.isEmpty else { return nil }
            return FundFlowPoint(
                date: d,
                code: row["code"] as? String ?? code,
                name: row["name"] as? String ?? "",
                close: num(row["close"]),
                changePct: num(row["change_pct"]),
                netAmount: num(row["net_amount"]),
                mainNet: num(row["main_net"]),
                mainRatio: num(row["main_ratio"]))
        }
        return pts.reversed()          // DESC 取"最近 N 天" → 反转为升序
    }

    /// `securities` 全表的代码集合 —— **覆盖率的基准**。
    ///
    /// ⚠ 必须走本类的私有连接（本方法在后台任务里被 `FundFlowJob` 调用），
    /// 不能图省事用 `SQLiteReader.shared.stockList()`（主线程专用）。
    ///
    /// ⚠ 也**不能**拿"快照里出现的代码"当基准：那等于拿结果当基准，
    /// 覆盖率恒为 1.0，"抓漏了"永远检测不出来。
    public static func securityCodes() -> Set<String> {
        Set(reader.query("SELECT code FROM securities", []).compactMap { $0["code"] as? String })
    }

    /// 该代码是否在 `securities` 里 —— 即"本表的合法标的"。
    ///
    /// 存在的理由：详情页对**任何**个股都可用（含 ETF / 指数 / 搜索到的冷门代码），
    /// 而 `stock_fund_flows` 的口径是「A 股个股」。没有这道闸门时，
    /// 点开一只 ETF 就会把 ETF 的行写进这张表 —— 表名不变、含义悄悄变宽，
    /// 而下游（覆盖率、按日聚合）都看不出来。
    ///
    /// 与 `FundFlowJob` 用的是**同一个全集**（`securities`），
    /// 所以"日更任务写的"与"详情页回填的"标的范围一致。
    public static func isKnownStock(_ code: String) -> Bool {
        !reader.query("SELECT 1 AS ok FROM securities WHERE code = ?", [code]).isEmpty
    }

    /// REAL 列 → Double，转发 `Num.doubleOrZero`（含 `isFinite` 守卫）。
    ///
    /// ⚠ 首选 `Double`：读取层对 `SQLITE_FLOAT` 返回的就是 `Double`；
    ///   其余分支只为防御（TEXT 列被手工写过库 / 别处传进来的原始行）。
    ///   `doubleValue` 对长小数**不是正确舍入**，不做首选。
    private static func num(_ v: Any?) -> Double { Num.doubleOrZero(v) }
}

/// 资金流的**私有只读连接**。
///
/// 存在的唯一理由：`SQLiteReader.shared` 是主线程专用的共享连接，
/// 而本模块的读会被后台任务调用 → 复用它会跨线程并发用同一连接 → SIGSEGV。
private final class FundFlowReader: @unchecked Sendable {

    /// ⚠ 自持只读连接（**不能用 `SQLiteReader.shared`** —— 它是 `@MainActor` 的，
    ///   跨线程读会 SIGSEGV）。四件套（`READWRITE` / `PRAGMA query_only` / `busy_timeout` /
    ///   串行队列）由 `ReadOnlyConnection` **一处**保证。
    ///   数据目录解析的唯一实现见 `DataDirectory.resolve()`。
    private let conn = ReadOnlyConnection(label: "FundFlowStore", pathProvider: DataDirectory.resolve)

    /// 关闭只读连接。
    ///
    /// ⚠ 换库时这条连接**一定会被放掉** —— `ReadOnlyConnection.init` 把它登记进 `DataConnections`，
    ///   不再依赖"有人记得往 `Store.invalidateAllDataConnections()` 里加一行"（原先就是靠记得，
    ///   实测漏过 4 个 ⇒ 换库后**继续读旧库**而界面显示新库数据）。
    ///   顺带清掉 `openLocked()` 缓存的 openError —— 那是"永久放弃重试"的门闩，不清则新库也读不到。
    func close() {
        conn.close()
    }

    func query(_ sql: String, _ params: [Any?] = []) -> [[String: Any]] {
        conn.queryRows(sql, params)
    }
}

/// 资金流的展示统计（纯函数，单测入口）。
///
/// ⚠ **只展示、不参与任何判定**。这些数字**不进** `deep_info`、**不进**评分 ——
/// 与 `ChipDistribution` 同一原则。见 `docs/specs/README.md`。
public struct FundFlowStats: Equatable, Sendable {

    /// 参与统计的交易日数
    public let days: Int
    /// 区间累计**主力净额**（元）
    public let sumMainNet: Double
    /// 主力净流入的天数
    public let inflowDays: Int
    /// 最近**连续**主力净流入天数（从最后一天往前数）
    public let consecutiveInflow: Int
    /// 最近一日的主力净额（元）；无数据为 nil
    public let latestMainNet: Double?
    /// 最近一日的交易日
    public let latestDate: String?

    /// 主力净额为正的天数占比，0–1
    public var inflowRatio: Double {
        days > 0 ? Double(inflowDays) / Double(days) : 0
    }

    /// 区间是否整体净流入
    public var isNetInflow: Bool { sumMainNet > 0 }

    /// 从升序序列汇总。
    ///
    /// ⚠ `consecutiveInflow` 的语义：从**最后一天**往前数连续 `mainNet > 0` 的天数。
    /// 最后一天不是净流入 → 0（"最近在流出"比"连续 N 天流入"更该被看见）。
    public static func summarize(_ points: [FundFlowPoint]) -> FundFlowStats? {
        guard !points.isEmpty else { return nil }
        var inflow = 0
        var sum = 0.0
        for p in points {
            sum += p.mainNet
            if p.mainNet > 0 { inflow += 1 }
        }
        var streak = 0
        for p in points.reversed() {
            guard p.mainNet > 0 else { break }
            streak += 1
        }
        return FundFlowStats(days: points.count, sumMainNet: sum, inflowDays: inflow,
                             consecutiveInflow: streak,
                             latestMainNet: points.last?.mainNet,
                             latestDate: points.last?.date)
    }

    public init(days: Int, sumMainNet: Double, inflowDays: Int, consecutiveInflow: Int,
                latestMainNet: Double?, latestDate: String?) {
        self.days = days
        self.sumMainNet = sumMainNet
        self.inflowDays = inflowDays
        self.consecutiveInflow = consecutiveInflow
        self.latestMainNet = latestMainNet
        self.latestDate = latestDate
    }
}
