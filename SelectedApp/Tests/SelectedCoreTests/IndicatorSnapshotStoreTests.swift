import Testing
import Foundation
import SQLite3
@testable import SelectedCore

/// `IndicatorSnapshotStore` 的库级测试
///
/// 姿势与 `HistoryReplayJobTests` 同款：`SELECTED_DATA_DIR` 指临时目录 +
/// 逐个失效连接（写连接 `SQLiteWriter.shared.close()` + 自持读连接
/// `IndicatorSnapshotStore.close()`），表结构手动执行注册表生成的 `createSQL`
/// —— 顺带验证"DDL 真能在 SQLite 落下来"。
@Suite(.serialized)
struct IndicatorSnapshotStoreTests {

    // MARK: - 临时库脚手架

    private func withTempDB(_ body: () throws -> Void) throws {
        let dir = NSTemporaryDirectory() + "/selected-ind_snap-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        setenv("SELECTED_DATA_DIR", dir, 1)
        SQLiteWriter.shared.close()
        IndicatorSnapshotStore.close()
        ParamStore.shared.close()
        IndicatorParamStore.close()
        // 手动建主库：快照表 + B 域参数表（均由注册表/spec 生成的 DDL）
        // + ranking 要 join 的最小 securities
        var h: OpaquePointer?
        guard sqlite3_open(dir + "/selected.sqlite3", &h) == SQLITE_OK, let db = h else {
            throw NSError(domain: "test", code: 1)
        }
        defer { sqlite3_close(db) }
        // 上一用例的连接关闭与文件删除是异步收尾（写队列串行），偶发 "database is locked"
        // ⇒ 建表前挂 busy_timeout 等锁释放，而不是把环境抖动当回归
        sqlite3_busy_timeout(db, 5000)
        for sql in [IndicatorSnapshotStore.createSQL,
                    IndicatorParamStore.createSQL,
                    "CREATE TABLE securities(code TEXT PRIMARY KEY, name TEXT NOT NULL DEFAULT '', market INTEGER NOT NULL DEFAULT 0);",
                    "CREATE TABLE data_source_logs(ts TEXT, source TEXT, event TEXT, detail TEXT);"] {
            var err: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
                throw NSError(domain: "test", code: 2,
                              userInfo: [NSLocalizedDescriptionKey:
                                        "建表失败：\(err.map { String(cString: $0) } ?? "?")"])
            }
        }
        do { try body() } catch {
            SQLiteWriter.shared.close(); IndicatorSnapshotStore.close(); ParamStore.shared.close()
            IndicatorParamStore.close()
            unsetenv("SELECTED_DATA_DIR")
            try? FileManager.default.removeItem(atPath: dir)
            throw error
        }
        SQLiteWriter.shared.close()
        IndicatorSnapshotStore.close()
        ParamStore.shared.close()
        IndicatorParamStore.close()
        unsetenv("SELECTED_DATA_DIR")
        try? FileManager.default.removeItem(atPath: dir)
    }

    private func row(_ code: String, _ values: [String: Double?]) -> IndicatorSnapshotStore.Row {
        IndicatorSnapshotStore.Row(code: code, values: values)
    }

    /// 只给部分列的行（其余列缺省 → 全 NULL）
    private func partial(_ code: String, _ values: [String: Double]) -> IndicatorSnapshotStore.Row {
        var all: [String: Double?] = [:]
        for c in IndicatorSnapshotStore.columns { all[c] = nil }
        for (k, v) in values { all[k] = v }
        return row(code, all)
    }

    // MARK: - 整日重插

    @Test("saveDay 整日重插：同日二次写入=覆盖，不留旧行")
    func saveDayIsFullReplace() throws {
        try withTempDB {
            let day = "2026-10-14"
            let n1 = try IndicatorSnapshotStore.saveDay(
                date: day,
                rows: [partial("600000", ["ema_value": 10, "super_trend_up": 1]),
                       partial("600001", ["ema_value": 20, "super_trend_up": 0])],
                at: "2026-10-14T15:25:00")
            #expect(n1 == 2)
            #expect(IndicatorSnapshotStore.count(on: day) == 2)
            // 二次只写一只 → 当日只剩这只（重插，不是增量）
            _ = try IndicatorSnapshotStore.saveDay(
                date: day, rows: [partial("600002", ["ema_value": 30])],
                at: "2026-10-14T17:00:00")
            #expect(IndicatorSnapshotStore.count(on: day) == 1)
            let r = IndicatorSnapshotStore.row(date: day, code: "600002")
            #expect(r?["ema_value"] == 30)
            #expect(IndicatorSnapshotStore.row(date: day, code: "600000") == nil)
        }
    }

    @Test("saveDay 拒绝非白名单列名（写侧也守白名单）")
    func saveDayRejectsUnknownColumn() throws {
        try withTempDB {
            var caught = false
            do {
                _ = try IndicatorSnapshotStore.saveDay(
                    date: "2026-10-14",
                    rows: [row("600000", ["ema_value": 1, "drop_table_please": 2])],
                    at: "t")
            } catch { caught = true }
            #expect(caught, "非白名单键必须抛错，不能静默丢列")
        }
    }

    // MARK: - NULL 语义（读回不是 0）

    @Test("未提供的列读回 nil；super_trend_up 的 1/0 整型往返")
    func nullSemanticsRoundTrip() throws {
        try withTempDB {
            _ = try IndicatorSnapshotStore.saveDay(
                date: "2026-10-14",
                rows: [partial("600000", ["ema_value": 10.5, "super_trend_up": 1]),
                       partial("600001", ["ema_value": 11, "super_trend_up": 0])],
                at: "t")
            let a = IndicatorSnapshotStore.row(date: "2026-10-14", code: "600000")
            #expect(a?["ema_value"] == 10.5)
            #expect(a?["super_trend_up"] == 1)
            // 没写的列：值 nil（**不是 0**）
            #expect(a?["macd_signal"].flatMap { $0 } == nil)
            let b = IndicatorSnapshotStore.row(date: "2026-10-14", code: "600001")
            #expect(b?["super_trend_up"] == 0, "下降方向 0 不许被读成 nil")
        }
    }

    // MARK: - ranking

    @Test("ranking：降序、NULL 排除、join 出 name、非法列名返回空")
    func rankingBasics() throws {
        try withTempDB {
            _ = try IndicatorSnapshotStore.saveDay(
                date: "2026-10-14",
                rows: [partial("600000", ["ema_value": 10]),
                       partial("600001", ["ema_value": 30]),
                       partial("600002", ["ema_value": 20]),
                       partial("600003", [:])],   // 全 NULL：预热不足，不进排行
                at: "t")
            // name 走 securities join
            var h: OpaquePointer?
            #expect(sqlite3_open(DataDirectory.databasePath, &h) == SQLITE_OK)
            sqlite3_exec(h, "INSERT INTO securities(code,name) VALUES('600001','浦发银行')", nil, nil, nil)
            sqlite3_close(h)
            IndicatorSnapshotStore.close()   // 让读连接重新打开看到新行

            let desc = IndicatorSnapshotStore.ranking(date: "2026-10-14", column: "ema_value")
            #expect(desc.map(\.value) == [30, 20, 10], "NULL 行必须被排除，其余降序")
            #expect(desc.first?.name == "浦发银行")
            let asc = IndicatorSnapshotStore.ranking(date: "2026-10-14", column: "ema_value",
                                                     ascending: true, limit: 2)
            #expect(asc.map(\.value) == [10, 20])
            // 注入面：非白名单列名 → 空数组（SQL 根本不拼）
            #expect(IndicatorSnapshotStore.ranking(date: "2026-10-14",
                                                   column: "1; DROP TABLE indicator_snapshots") .isEmpty)
            #expect(!IndicatorSnapshotStore.days().isEmpty, "表还活着")
        }
    }

    // MARK: - 筛选执行（与库级用例同套件串行，见 IndicatorScreenerTests 头注）

    @Test("filter 规则：RSI 超卖升序（最低在前），NULL 不命中")
    func screenFilterRSI() throws {
        try withTempDB {
            _ = try IndicatorSnapshotStore.saveDay(
                date: "2026-10-14",
                rows: [partial("A", ["rsi_wilder_value": 25]),
                       partial("B", ["rsi_wilder_value": 35]),
                       partial("C", ["rsi_wilder_value": 20]),
                       partial("D", [:])],
                at: "t")
            let hits = IndicatorScreener.screen(indicatorId: "rsiWilder", date: "2026-10-14")
            #expect(hits.map(\.code) == ["C", "A"], "超卖升序应 C(20)→A(25)，实得 \(hits.map(\.code))")
        }
    }

    @Test("cross 规则：MACD 金叉要求昨日线≤信号、今日线>信号；无前一日则空")
    func screenCrossMacd() throws {
        try withTempDB {
            _ = try IndicatorSnapshotStore.saveDay(
                date: "2026-10-13",
                rows: [partial("X", ["macd_line": 1, "macd_signal": 2]),      // 昨弱
                       partial("Y", ["macd_line": 3, "macd_signal": 2])],     // 昨已强
                at: "t")
            _ = try IndicatorSnapshotStore.saveDay(
                date: "2026-10-14",
                rows: [partial("X", ["macd_line": 3, "macd_signal": 2, "macd_hist": 1]),
                       partial("Y", ["macd_line": 4, "macd_signal": 2, "macd_hist": 2])],
                at: "t")
            let hits = IndicatorScreener.screen(indicatorId: "macd", date: "2026-10-14")
            #expect(hits.map(\.code) == ["X"], "只有 X 是今日新金叉，实得 \(hits.map(\.code))")
            // 无前一日的那天：金叉类返回空（不硬造）
            #expect(IndicatorScreener.screen(indicatorId: "macd", date: "2026-10-13").isEmpty)
        }
    }

    @Test("乖离类 valueSQL：(close/ema−1)×100 正确出数与排序")
    func screenDeviationValue() throws {
        try withTempDB {
            _ = try IndicatorSnapshotStore.saveDay(
                date: "2026-10-14",
                rows: [partial("A", ["close_value": 110, "ema_value": 100]),   // +10%
                       partial("B", ["close_value": 105, "ema_value": 100]),   // +5%
                       partial("C", ["close_value": 90, "ema_value": 100])],   // 不命中
                at: "t")
            let hits = IndicatorScreener.screen(indicatorId: "ema", date: "2026-10-14")
            #expect(hits.map(\.code) == ["A", "B"])
            #expect(abs(hits[0].value - 10) < 1e-9)
        }
    }

    // MARK: - 多条件 AND（2026-10-26 指标筛选页改版）

    @Test("多条件 AND：两条谓词同时满足才命中；逐条件一列；排序键可切换")
    func screenMultiConditionAnd() throws {
        try withTempDB {
            _ = try IndicatorSnapshotStore.saveDay(
                date: "2026-10-14",
                rows: [partial("A", ["close_value": 110, "ema_value": 100, "cmf_value": 0.5]),
                       partial("B", ["close_value": 105, "ema_value": 100, "cmf_value": 0.05]),
                       partial("C", ["close_value": 90, "ema_value": 100, "cmf_value": 0.9]),
                       partial("D", ["close_value": 130, "ema_value": 100, "cmf_value": 0.2])],
                at: "t")
            let rows = IndicatorScreener.screen(indicatorIds: ["ema", "cmf"], date: "2026-10-14")
            #expect(rows.map(\.code) == ["D", "A"], "乖离降序，实得 \(rows.map(\.code))")
            #expect(rows.first?.values.count == 2)
            #expect(abs((rows.first?.values[0] ?? 0) - 30) < 1e-9)
            #expect(abs((rows.first?.values[1] ?? 0) - 0.2) < 1e-9)
            // 收盘价来自快照基础列；没有前一快照日 → 涨跌幅为 nil（不硬造 0）
            #expect(rows.first?.close == 130)
            #expect(rows.first?.changePct == nil)
            // 排序键 = 第二条（CMF 降序）
            let byCmf = IndicatorScreener.screen(indicatorIds: ["ema", "cmf"],
                                                 date: "2026-10-14", sortBy: "cmf")
            #expect(byCmf.map(\.code) == ["A", "D"])
            // 未知 id → 整体空（不静默丢条件）
            #expect(IndicatorScreener.screen(indicatorIds: ["ema", "nope"], date: "2026-10-14").isEmpty)
            #expect(IndicatorScreener.count(indicatorIds: ["ema", "cmf"], date: "2026-10-14") == 2)
            #expect(IndicatorScreener.count(indicatorIds: ["ema", "cmf", "rsiWilder"],
                                           date: "2026-10-14") == 0)
        }
    }

    @Test("多条件里混一条穿叉规则：只加一个前一日 join；没有前一日 → 空")
    func screenMultiConditionCross() throws {
        try withTempDB {
            _ = try IndicatorSnapshotStore.saveDay(
                date: "2026-10-13",
                rows: [partial("A", ["macd_line": 1, "macd_signal": 2, "close_value": 90, "ema_value": 100])],
                at: "t")
            _ = try IndicatorSnapshotStore.saveDay(
                date: "2026-10-14",
                rows: [partial("A", ["macd_line": 3, "macd_signal": 2, "macd_hist": 1,
                                     "close_value": 110, "ema_value": 100])],
                at: "t")
            let rows = IndicatorScreener.screen(indicatorIds: ["macd", "ema"], date: "2026-10-14")
            #expect(rows.map(\.code) == ["A"])
            #expect(rows.first?.values.count == 2)
            // 有前一快照日 → 当日涨跌幅 = 110/90 − 1 ≈ 22.22%
            #expect(abs((rows.first?.changePct ?? 0) - (110.0 / 90.0 - 1) * 100) < 1e-9)
            // 10-13 没有更早的快照日 → 穿叉类不可算
            #expect(IndicatorScreener.screen(indicatorIds: ["macd", "ema"], date: "2026-10-13").isEmpty)
        }
    }

    @Test("唐奇安：与**前一日**上轨比（旧规则 close>当日上轨恒 0）")
    func screenDonchianUsesPreviousDayUpper() throws {
        try withTempDB {
            _ = try IndicatorSnapshotStore.saveDay(
                date: "2026-10-13",
                rows: [partial("A", ["close_value": 9, "donchian_channel_upper": 10])],
                at: "t")
            _ = try IndicatorSnapshotStore.saveDay(
                date: "2026-10-14",
                rows: [partial("A", ["close_value": 11, "donchian_channel_upper": 12]),  // 11 > 昨上轨 10
                       partial("B", ["close_value": 10, "donchian_channel_upper": 12]),  // = 昨上轨，不命中
                       partial("C", ["close_value": 9, "donchian_channel_upper": 12])],  // 不命中
                at: "t")
            let hits = IndicatorScreener.screen(indicatorId: "donchianChannel", date: "2026-10-14")
            #expect(hits.map(\.code) == ["A"], "只有当日的收盘超过**昨日**上轨才算新高，实得 \(hits.map(\.code))")
            #expect(abs(hits.first!.value - 10) < 1e-9)
            // 没有前一日 → 空（不拿当日上轨硬造）
            #expect(IndicatorScreener.screen(indicatorId: "donchianChannel", date: "2026-10-13").isEmpty)
        }
    }

    @Test("单日命中数：filter 与 cross 同表；没有前一日时 cross 不给数")
    func screenSingleCounts() throws {
        try withTempDB {
            _ = try IndicatorSnapshotStore.saveDay(
                date: "2026-10-13",
                rows: [partial("A", ["macd_line": 1, "macd_signal": 2])],
                at: "t")
            _ = try IndicatorSnapshotStore.saveDay(
                date: "2026-10-14",
                rows: [partial("A", ["macd_line": 3, "macd_signal": 2, "macd_hist": 1,
                                     "rsi_wilder_value": 20]),
                       partial("B", ["macd_line": 4, "macd_signal": 2, "macd_hist": 2,
                                     "rsi_wilder_value": 35]),
                       partial("C", ["rsi_wilder_value": 15])],
                at: "t")
            let counts = IndicatorScreener.singleCounts(date: "2026-10-14")
            #expect(counts["macd"] == 1, "只有 A 金叉，实得 \(String(describing: counts["macd"]))")
            #expect(counts["rsiWilder"] == 2, "A、C 超卖，实得 \(String(describing: counts["rsiWilder"]))")
            #expect(IndicatorScreener.count(indicatorIds: ["macd", "rsiWilder"],
                                           date: "2026-10-14") == 1)
            // 最早那天没有前一日 ⇒ 穿叉类无计数（显示「—」而不是 0）
            let firstDay = IndicatorScreener.singleCounts(date: "2026-10-13")
            #expect(firstDay["macd"] == nil)
            #expect(firstDay["rsiWilder"] == 0)
        }
    }

    @Test("R0 端到端：B 域 set rsi_oversold=25 → 命中收紧；reset → 回落默认 30")
    func screenThresholdFollowsIndicatorParams() throws {
        try withTempDB {
            _ = try IndicatorSnapshotStore.saveDay(
                date: "2026-10-14",
                rows: [partial("A", ["rsi_wilder_value": 20]),
                       partial("B", ["rsi_wilder_value": 27]),
                       partial("C", ["rsi_wilder_value": 35])],
                at: "t")
            // 默认（表空 → 回落 spec/规则默认 30）：20、27 命中
            let def = IndicatorScreener.screen(indicatorId: "rsiWilder", date: "2026-10-14")
            #expect(def.map(\.code) == ["A", "B"], "默认阈值 30 应命中 A、B，实得 \(def.map(\.code))")
            // B 域收紧到 25 → 只剩 A
            try IndicatorParamStore.set(key: "screen.rsi_oversold", value: 25, source: "test")
            let tight = IndicatorScreener.screen(indicatorId: "rsiWilder", date: "2026-10-14")
            #expect(tight.map(\.code) == ["A"], "阈值 25 应只剩 A，实得 \(tight.map(\.code))")
            // reset = 删行回落默认（不产生新选股参数版本 —— 这就是 B 域独立的意义）
            try IndicatorParamStore.reset(key: "screen.rsi_oversold", source: "test")
            let back = IndicatorScreener.screen(indicatorId: "rsiWilder", date: "2026-10-14")
            #expect(back.map(\.code) == ["A", "B"], "reset 后应回落默认 30")
        }
    }

    // MARK: - B 域参数（碰库用例统一收在本套件，见文件头）

    @Test("B 域 set/value/effective/reset：写读往返、回落、删行、流水")
    func indicatorParamRoundTrip() throws {
        try withTempDB {
            #expect(IndicatorParamStore.value(key: "screen.rsi_oversold") == nil)
            #expect(IndicatorParamStore.effective(key: "screen.rsi_oversold") == 30)
            try IndicatorParamStore.set(key: "screen.rsi_oversold", value: 25, source: "test")
            #expect(IndicatorParamStore.value(key: "screen.rsi_oversold") == 25)
            #expect(IndicatorParamStore.all() == ["screen.rsi_oversold": 25])
            try IndicatorParamStore.reset(key: "screen.rsi_oversold", source: "test")
            #expect(IndicatorParamStore.value(key: "screen.rsi_oversold") == nil)
            #expect(IndicatorParamStore.effective(key: "screen.rsi_oversold") == 30)
            let hist = IndicatorParamStore.history(limit: 10)
            #expect(hist.count == 2, "set + reset 各记一笔")
            #expect(hist[0].source == "test_reset" && hist[0].oldValue == 25)
            #expect(hist[1].oldValue == nil, "首笔 set 的 old_value 必须 NULL（=首次设置）")
        }
    }

    @Test("B 域写侧守门：未知键/越界抛错；整数键取整；oscConfig 与 period 回落")
    func indicatorParamGuards() throws {
        try withTempDB {
            #expect(throws: (any Error).self) {
                try IndicatorParamStore.set(key: "screen.not_a_key", value: 1)
            }
            #expect(throws: (any Error).self) {
                try IndicatorParamStore.set(key: "screen.rsi_oversold", value: 150)
            }
            try IndicatorParamStore.set(key: "screen.rsi_oversold", value: 24.6, source: "test")
            #expect(IndicatorParamStore.value(key: "screen.rsi_oversold") == 25, "int 键四舍五入")
            // oscConfig：缺键回落出厂，设置后覆盖
            let factory = Oscillators.Config()
            #expect(IndicatorParamStore.oscConfig().rsiOb == factory.rsiOb)
            try IndicatorParamStore.set(key: "osc.rsi.ob", value: 70, source: "test")
            #expect(IndicatorParamStore.oscConfig().rsiOb == 70)
            #expect(IndicatorParamStore.oscConfig().kdjObK == factory.kdjObK)
            // period 取数：回落 + 覆盖 + Double 重载
            #expect(IndicatorParamStore.period(id: "macd", param: "fast", default: 12) == 12)
            try IndicatorParamStore.set(key: "period.macd.fast", value: 8, source: "test")
            #expect(IndicatorParamStore.period(id: "macd", param: "fast", default: 12) == 8)
            #expect(IndicatorParamStore.period(id: "superTrend", param: "multiplier", default: 2.5) == 2.5)
        }
    }

    @Test("周期改动贯通快照计算：period.ema.period=5 时 ema_value 跟随（同数据不同值）")
    func periodFlowsIntoSnapshot() throws {
        try withTempDB {
            let bars = (1...60).map { i -> HistoryBar in
                let p = 10 + Double(i % 13) * 0.2
                return HistoryBar(code: "600000", day: String(format: "d%03d", i),
                                 open: p, close: p, high: p + 0.1, low: p - 0.1,
                                 volume: 1000, amount: 1e7, amplitude: 2, changePct: 0, turnover: 1)
            }
            let def = ((IndicatorSnapshotJob.snapshotValues(bars: bars)["ema_value"] ?? nil) ?? -1) as Double
            try IndicatorParamStore.set(key: "period.ema.period", value: 5, source: "test")
            let fast = ((IndicatorSnapshotJob.snapshotValues(bars: bars)["ema_value"] ?? nil) ?? -1) as Double
            #expect(abs(def - fast) > 1e-9, "周期 20→5 后 EMA 末值必须不同")
        }
    }

    // MARK: - 新鲜度

    @Test("latestDay/days 降序；lastFetchedAt 读 indsnap_ok 日志")
    func freshness() throws {
        try withTempDB {
            _ = try IndicatorSnapshotStore.saveDay(date: "2026-10-13",
                                                   rows: [partial("600000", ["ema_value": 1])], at: "t")
            _ = try IndicatorSnapshotStore.saveDay(date: "2026-10-14",
                                                   rows: [partial("600000", ["ema_value": 2])], at: "t")
            #expect(IndicatorSnapshotStore.latestDay() == "2026-10-14")
            #expect(IndicatorSnapshotStore.days() == ["2026-10-14", "2026-10-13"])
            #expect(IndicatorSnapshotStore.lastFetchedAt() == nil)
            var h: OpaquePointer?
            #expect(sqlite3_open(DataDirectory.databasePath, &h) == SQLITE_OK)
            sqlite3_exec(h, "INSERT INTO data_source_logs(ts,source,event,detail)"
                            + " VALUES('2026-10-14T15:25:30','indsnap','indsnap_ok','x')", nil, nil, nil)
            sqlite3_close(h)
            IndicatorSnapshotStore.close()
            #expect(IndicatorSnapshotStore.lastFetchedAt() == "2026-10-14T15:25:30")
        }
    }

    @Test("ranking 与 screen 支持整型列解码为 Double")
    func integerColumnValueDecodesToDouble() throws {
        try withTempDB {
            _ = try IndicatorSnapshotStore.saveDay(
                date: "2026-10-15",
                rows: [partial("600001", ["super_trend_up": 1, "close_value": 10]),
                       partial("600002", ["super_trend_up": 0, "close_value": 20])],
                at: "t")
            let rank = IndicatorSnapshotStore.ranking(date: "2026-10-15", column: "super_trend_up")
            #expect(rank.count == 2)
            #expect(rank.first(where: { $0.code == "600001" })?.value == 1.0)
            let intRule = IndicatorScreener.Rule(
                indicatorId: "superTrend", title: "test-int",
                valueLabel: "dir", valueSQL: "t.super_trend_up",
                whereSQL: "t.super_trend_up = 1")
            let hits = IndicatorSnapshotStore.screen(rule: intRule, date: "2026-10-15")
            #expect(hits.map(\.code) == ["600001"])
            #expect(hits.first?.value == 1.0)
        }
    }
}
