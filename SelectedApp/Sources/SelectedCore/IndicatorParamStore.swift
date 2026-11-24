import Foundation
import SQLite3

/// 指标筛选参数（B 域）的落库与读取。
///
/// ## 为什么独立表而不是 param_versions
/// 这些参数**不进打分**：改它们不产生选股参数版本、不进调优空间、不影响任何
/// 评分结论 —— 塞进 A 域版本线会让"调筛选阈值"看起来像"改选股策略"，
/// 版本列表被稀释、diff 被污染。独立表 + 变更流水，语义干净。
///
/// ## 读回落
/// 缺键 → 调用方默认（`IndicatorParamSpec.Entry.defaultValue`，与注册表/规则表/
/// Oscillators 出厂值由契约测试钉死一致）。**从不写默认值占位行**：表里只有
/// 用户显式改过的键，"恢复默认"= 删行。
///
/// ## ⚠ 周期类键改动后要重算快照（`period.*`）
/// 快照列值依赖周期；本 Store 只存值，触发重算是 UI 职责（编辑 sheet 保存
/// `period.*` 后调 `Store.refreshIndicatorSnapshot()`）。
public enum IndicatorParamStore {

    public static let table = "indicator_params"
    public static let historyTable = "indicator_param_changes"

    /// 建表 DDL（Swift-only，幂等；纪律同 `indicator_snapshots`）
    public static let createSQL = """
    CREATE TABLE IF NOT EXISTS indicator_params (
        key        TEXT PRIMARY KEY,
        value      REAL NOT NULL,
        updated_at TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS indicator_param_changes (
        ts        TEXT NOT NULL,
        key       TEXT NOT NULL,
        old_value REAL,
        new_value REAL NOT NULL,
        source    TEXT NOT NULL DEFAULT ''
    );
    CREATE INDEX IF NOT EXISTS idx_indicator_param_changes_ts ON indicator_param_changes(ts DESC);
    """

    private static let reader = IndicatorParamReader()

    /// 手动释放本 Store 的连接（换库时由 `DataConnections.closeAll()` 自动覆盖，不需要点名）。
    public static func close() {
        reader.close()
    }

    // MARK: - 读

    /// 单键当前值（缺键 → nil，调用方回落 spec 默认）
    ///
    /// ⚠ 走 reader 的**全表快照缓存**而不是每次一条 SELECT：本函数位于
    ///   `period() → effective() → value()` 的最内层，快照 Job 每只票要调 33 次
    ///   （全市场约 16.5 万条查询打一张十几行的表）。理由与失效纪律见
    ///   `IndicatorParamReader` 的「全表快照缓存」一节。
    public static func value(key: String) -> Double? {
        guard !key.isEmpty else { return nil }
        return reader.value(key)
    }

    /// 全部已显式设置的键值（编辑 sheet 标"已改"用）
    public static func all() -> [String: Double] {
        reader.loadAll()
    }

    /// 生效值 = 表值（须过 spec 区间）否则默认。**脏值（越界/键已废弃）按缺键处理**。
    public static func effective(key: String) -> Double? {
        guard let entry = IndicatorParamSpec.entry(key: key) else { return nil }
        guard let v = value(key: key), v.isFinite, v >= entry.min, v <= entry.max else {
            return entry.defaultValue
        }
        return v
    }

    /// 变更流水（新→旧）
    public struct Change: Sendable {
        public let ts: String
        public let key: String
        public let oldValue: Double?
        public let newValue: Double
        public let source: String
    }

    public static func history(limit: Int = 20) -> [Change] {
        guard limit > 0 else { return [] }
        // ⚠ `ts` 只到秒（nowStamp 口径），同秒连写必须靠 rowid 定序（ts 相同 → 后写 rowid 大）
        return reader.query(
            "SELECT ts, key, old_value, new_value, source FROM \(historyTable)"
            + " ORDER BY ts DESC, rowid DESC LIMIT ?", [limit]).compactMap { r in
            guard let ts = r["ts"] as? String, let key = r["key"] as? String,
                  let nv = r["new_value"] as? Double else { return nil }
            return Change(ts: ts, key: key, oldValue: r["old_value"] as? Double,
                          newValue: nv, source: (r["source"] as? String) ?? "")
        }
    }

    // MARK: - 写

    /// 设置一个键（UPSERT + 流水，同事务）。键必须在 spec 里、值必须在区间内 ——
    /// 违规直接抛（写侧守门，UI 不该把脏值送进来）。
    public static func set(key: String, value: Double, source: String = "ui") throws {
        guard let entry = IndicatorParamSpec.entry(key: key) else {
            throw SQLiteWriteError(message: "未知指标参数键：\(key)")
        }
        let v = entry.isInt ? value.rounded() : value
        guard v.isFinite, v >= entry.min, v <= entry.max else {
            throw SQLiteWriteError(message: "参数 \(key) 越界：\(value)（允许 \(entry.min)…\(entry.max)）")
        }
        let stamp = PhaseStore.nowStamp()
        _ = try SQLiteWriter.shared.write { tx in
            // 在同一写事务内读取旧值，消除并发写入下的 TOCTOU
            let old = Num.doubleOrNil(
                try tx.query("SELECT value FROM \(table) WHERE key=?", [key]).first?["value"]
            )
            try tx.execute(
                "INSERT OR REPLACE INTO \(table)(key, value, updated_at) VALUES(?,?,?)",
                [key, v, stamp])
            try tx.execute(
                "INSERT INTO \(historyTable)(ts, key, old_value, new_value, source) VALUES(?,?,?,?,?)",
                [stamp, key, old, v, source])
            return 1
        }
        // ⚠ 写完必须让快照缓存失效（否则 `value()` 继续回旧值，编辑立即生效的语义就破了）
        reader.invalidateCache()
    }

    /// 恢复默认 = 删行 + 流水记一笔（new_value = 默认值，old = 被删值）
    public static func reset(key: String, source: String = "ui") throws {
        guard let entry = IndicatorParamSpec.entry(key: key) else {
            throw SQLiteWriteError(message: "未知指标参数键：\(key)")
        }
        let stamp = PhaseStore.nowStamp()
        _ = try SQLiteWriter.shared.write { tx in
            let old = Num.doubleOrNil(
                try tx.query("SELECT value FROM \(table) WHERE key=?", [key]).first?["value"]
            )
            try tx.execute("DELETE FROM \(table) WHERE key=?", [key])
            if old != nil {
                try tx.execute(
                    "INSERT INTO \(historyTable)(ts, key, old_value, new_value, source) VALUES(?,?,?,?,?)",
                    [stamp, key, old, entry.defaultValue, source + "_reset"])
            }
            return 1
        }
        reader.invalidateCache()   // 同 `set`：删行也是写
    }

    // MARK: - 消费方便捷口（回落链都在这，调用方不各自实现）

    /// Oscillators 判读阈值（详情页 Zone 用；缺键回落出厂 Config）。
    public static func oscConfig() -> Oscillators.Config {
        var c = Oscillators.Config()
        func d(_ key: String, _ fallback: Double) -> Double { effective(key: key) ?? fallback }
        c.kdjPeriod = Int(d("osc.kdj.period", Double(c.kdjPeriod)))
        c.kdjObK = d("osc.kdj.obK", c.kdjObK)
        c.kdjObD = d("osc.kdj.obD", c.kdjObD)
        c.kdjObJ = d("osc.kdj.obJ", c.kdjObJ)
        c.kdjOsK = d("osc.kdj.osK", c.kdjOsK)
        c.kdjOsD = d("osc.kdj.osD", c.kdjOsD)
        c.rsiPeriod = Int(d("osc.rsi.period", Double(c.rsiPeriod)))
        c.rsiOb = d("osc.rsi.ob", c.rsiOb)
        c.rsiSevereOb = d("osc.rsi.severeOb", c.rsiSevereOb)
        c.rsiOs = d("osc.rsi.os", c.rsiOs)
        c.rsiSevereOs = d("osc.rsi.severeOs", c.rsiSevereOs)
        c.cciPeriod = Int(d("osc.cci.period", Double(c.cciPeriod)))
        c.cciOb = d("osc.cci.ob", c.cciOb)
        c.cciOs = d("osc.cci.os", c.cciOs)
        c.crPeriod = Int(d("osc.cr.period", Double(c.crPeriod)))
        c.crSell = d("osc.cr.sell", c.crSell)
        c.crBuy = d("osc.cr.buy", c.crBuy)
        c.wrPeriod = Int(d("osc.wr.period", Double(c.wrPeriod)))
        c.wrOb = d("osc.wr.ob", c.wrOb)
        c.wrOs = d("osc.wr.os", c.wrOs)
        c.vrPeriod = Int(d("osc.vr.period", Double(c.vrPeriod)))
        c.vrSellLow = d("osc.vr.sellLow", c.vrSellLow)
        c.vrSellHigh = d("osc.vr.sellHigh", c.vrSellHigh)
        c.vrBuyLow = d("osc.vr.buyLow", c.vrBuyLow)
        c.vrBuyHigh = d("osc.vr.buyHigh", c.vrBuyHigh)
        return c
    }

    /// 指标周期取数（快照 Job 用）：`period.<id>.<param>`，缺键/越界回落默认。
    public static func period(id: String, param: String, default def: Int) -> Int {
        guard let v = effective(key: "period.\(id).\(param)") else { return def }
        return max(1, Int(v.rounded()))
    }

    public static func period(id: String, param: String, default def: Double) -> Double {
        effective(key: "period.\(id).\(param)") ?? def
    }
}

/// B 域参数的**私有只读连接**（与 `BoardHeatReader` 同构；后台线程可读）。
private final class IndicatorParamReader: @unchecked Sendable {

    private let conn = ReadOnlyConnection(label: "IndicatorParamStore",
                                          pathProvider: DataDirectory.resolve)

    // MARK: 全表快照缓存
    //
    // ⚠ 为什么必须有（2026-10-16 审查 B3）：`IndicatorSnapshotJob.snapshotValues`
    //   每只票要经 `period()` → `effective()` → `value()` 发 **33 条**
    //   `SELECT value FROM indicator_params WHERE key=?`；全市场 ~5000 只 ⇒
    //   单轮约 **16.5 万次** 队列往返 + prepare/step/finalize，
    //   而底下这张表总共只有十几行。详情页 `oscConfig()` 同理，一次 24 条。
    //   缓存失效纪律：任何写入（`set`/`reset`）与 `close()`（换库）都必须清空 ——
    //   写只发生在本进程内（无外部写者），所以"写后即清"是充分的。
    private let cacheLock = NSLock()
    private var cache: [String: Double]?

    /// 单键取值（命中缓存则不碰数据库）。
    func value(_ key: String) -> Double? {
        cacheLock.lock()
        if let c = cache {
            let hit = c[key]
            cacheLock.unlock()
            return hit
        }
        cacheLock.unlock()
        let loaded = loadAll()
        cacheLock.lock()
        cache = loaded
        let hit = loaded[key]
        cacheLock.unlock()
        return hit
    }

    func invalidateCache() {
        cacheLock.lock(); cache = nil; cacheLock.unlock()
    }

    /// 全表读一次（表极小：只有用户显式改过的键）
    func loadAll() -> [String: Double] {
        var out: [String: Double] = [:]
        for r in query("SELECT key, value FROM \(IndicatorParamStore.table)", []) {
            if let k = r["key"] as? String, let v = Num.doubleOrNil(r["value"]) { out[k] = v }
        }
        return out
    }

    func close() {
        conn.close()
        invalidateCache()
    }

    func query(_ sql: String, _ params: [Any?] = []) -> [[String: Any]] {
        conn.queryRows(sql, params)
    }
}
