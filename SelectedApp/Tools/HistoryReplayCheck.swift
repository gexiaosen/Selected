import Foundation
import SQLite3
@testable import SelectedCore

/// 历史回放**真实库自检** —— 隔离规则 / 口径标记 / 断点续传 / secid 口径。
///
/// 跑之前必须把 `SELECTED_DATA_DIR` 指到**现造的干净库**（`history_replay_test.sh` 负责）。
/// **绝不碰生产库**。
///
/// 为什么这些断言要放在这里而不是 XCTest：它们需要「真库 + 真 schema + 可切换的数据目录」，
/// 而 `PhaseStore` / `SQLiteWriter` 的句柄是**进程级缓存**的 —— 单测里换目录会写错库。
///
/// 本驱动**只做不需要网络的部分**：`replayOne` 的两个分支都在发请求之前就返回
/// （隔离规则 / 交易日历），所以整份自检是**离线**的、可进 `run_all.sh`。
@main
struct HistoryReplayCheck {
    static var failures: [String] = []
    static var checks = 0

    static func check(_ cond: Bool, _ label: String) {
        checks += 1
        if !cond { failures.append(label) }
        print("   \(cond ? "✅" : "❌") \(label)")
    }

    static func eq<T: Equatable>(_ got: T, _ want: T, _ label: String) {
        check(got == want, "\(label)（实得 \(got)）")
    }

    /// 可空字符串专用：`eq` 的泛型要求两侧同型，`String?` 与 `String` 配不上
    static func eqs(_ got: String?, _ want: String?, _ label: String) {
        check(got == want, "\(label)（实得 \(got.map { "「\($0)」" } ?? "nil")）")
    }

    static func main() {
        let stage = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "all"
        switch stage {
        case "bootstrap": stageBootstrap()
        case "secid": stageSecid()
        case "schema": stageSchema()
        case "isolation": stageIsolation()
        case "resume": stageResume()
        case "pool": stagePool()
        default:
            stageBootstrap(); stageSecid(); stageSchema(); stageIsolation()
            stageResume(); stagePool()
        }
        print("—— \(stage)：检查 \(checks) 项，失败 \(failures.count) 项")
        if !failures.isEmpty {
            for f in failures { print("   ❌ \(f)") }
            exit(1)
        }
        exit(0)
    }

    // MARK: - 建库（在空目录里现造，不依赖生产库）

    /// 用 `DBBootstrap.ensureReady()` 现造一个库（schema + 迁移 + 出厂参数补种）。
    ///
    /// **为什么不用「生产库的副本」**：副本依赖用户机器上恰好有一份真实数据，
    /// CI/新克隆上就没有 → 护栏会在最需要它的时候静默缺席。现造则**逐次完全一致**。
    static func stageBootstrap() {
        print("\n[0] 建库（空目录 → schema + 迁移 + 出厂参数）")
        let dir = DataDirectory.resolve()
        check(!FileManager.default.fileExists(atPath: dir + "/selected.sqlite3"),
              "起点是空目录（否则上一轮的残留会让断言失真）：\(dir)")
        let err = DBBootstrap.ensureReady()
        check(err == nil, "ensureReady 成功（\(err ?? "ok")）")
        check(FileManager.default.fileExists(atPath: dir + "/selected.sqlite3"), "库已建出")

        // ---- 存量行的 DEFAULT：老库升级时那一批 reviews 行必须变成 'live' ----
        //
        // 这是「`scan_mode='live'` 严格过滤」成立的前提。SQLite 的
        // `ALTER TABLE ADD COLUMN … DEFAULT 'live'` 对**已存在的行**返回该默认值
        // （不是 NULL）—— 但这是"依赖一个具体行为"，所以在这里实测一次：
        // 若哪天真返回 NULL，`buildPool` 会把**全部历史样本**静默排除，
        // 表现为"调优池为空"，而用户明明跑过扫描。
        //
        // 为什么用手写 SQL 而不是"造一个老库再 ensureReady"：`ensureReady` **本身**
        //   就会调 `ensureSwiftOnlyMigrations`，所以它建出来的库永远已有这一列 ——
        //   走那条路根本测不到"补列时存量行怎么办"。
        checkLegacyRowsGetDefault()

        DBBootstrap.ensureSwiftOnlySchemaOnDisk()
        check(tableColumns("reviews").contains("scan_mode"), "ensureSwiftOnlySchemaOnDisk 补上了 scan_mode")
        check(tableColumns("stock_outcomes").contains("sel_price"), "同一次调用也补了 stock_outcomes.sel_price")
    }

    /// `ALTER TABLE ADD COLUMN … DEFAULT 'live'` 对**存量行**的返回必须是 `'live'`（不是 NULL）。
    ///
    /// 两条对照：带 DEFAULT 的必须是 `live`，**不带 DEFAULT 的必须是 NULL** ——
    /// 后者用来证明这个断言真的在测那一条行为（否则"读到 live"可能只是列本来就非空）。
    static func checkLegacyRowsGetDefault() {
        let path = DataDirectory.resolve() + "/__legacy_probe.sqlite3"
        try? FileManager.default.removeItem(atPath: path)
        var h: OpaquePointer?
        guard sqlite3_open(path, &h) == SQLITE_OK, let db = h else {
            check(false, "打不开探针库：\(path)")
            return
        }
        defer { sqlite3_close(db); try? FileManager.default.removeItem(atPath: path) }

        func scalar(_ sql: String) -> String? {
            var st: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let s = st else { return nil }
            defer { sqlite3_finalize(s) }
            guard sqlite3_step(s) == SQLITE_ROW else { return nil }
            if sqlite3_column_type(s, 0) == SQLITE_NULL { return nil }
            return sqlite3_column_text(s, 0).map { String(cString: $0) }
        }

        _ = sqlite3_exec(db, "CREATE TABLE with_default(sel_date TEXT PRIMARY KEY);"
            + " INSERT INTO with_default VALUES('2019-01-02');"
            + " ALTER TABLE with_default ADD COLUMN scan_mode TEXT DEFAULT 'live';",
            nil, nil, nil)
        eqs(scalar("SELECT scan_mode FROM with_default"), "live",
            "⚠ 补列前就存在的行，补列后读出来必须是 'live'")

        _ = sqlite3_exec(db, "CREATE TABLE no_default(sel_date TEXT PRIMARY KEY);"
            + " INSERT INTO no_default VALUES('2019-01-02');"
            + " ALTER TABLE no_default ADD COLUMN scan_mode TEXT;",
            nil, nil, nil)
        eqs(scalar("SELECT scan_mode FROM no_default"), nil,
            "对照：不带 DEFAULT 的补列 → 存量行是 NULL（证明上一条真的在测那条行为）")
    }

    // MARK: - secid 口径（纯函数，无需网络/库）

    /// 指数与个股的 `secid` **不是同一套规则**。
    /// 指数 `000001` 若走个股规则（6 开头才沪）会拼出 `0.000001` = **深市 000001 平安银行**
    /// —— 一只真票的数据、格式完全合法、只是**不是指数**。交易日历会据此算错 T+1。
    static func stageSecid() {
        print("\n[1] secid 口径")
        eq(HistoryBarsSource.secid("600519"), "1.600519", "沪市个股 → 1.")
        eq(HistoryBarsSource.secid("000001"), "0.000001", "深市个股 → 0.")
        eq(HistoryBarsSource.secid("920427"), "0.920427", "北交所 → 0.")
        eq(HistoryBarsSource.secidIndex("sh000001"), "1.000001", "上证指数 → 1.000001")
        eq(HistoryBarsSource.secidIndex("sz399001"), "0.399001", "深证成指 → 0.399001")
        eq(HistoryBarsSource.secidIndex("SH000001"), "1.000001", "大写前缀也认")
        check(HistoryBarsSource.secidIndex("sh000001") != HistoryBarsSource.secid("000001"),
              "指数 secid 必须与同名个股不同（否则拿平安银行当日历）")
        // 无前缀 → 退回个股规则，不猜
        eq(HistoryBarsSource.secidIndex("600519"), "1.600519", "无市场前缀 → 退回个股规则")

        let stock = HistoryBarsSource.url(secid: "1.600519", beg: "2020-01-01",
                                          end: "2026-09-22", adjust: true)
        let index = HistoryBarsSource.url(secid: "1.000001", beg: "2020-01-01",
                                          end: "2026-09-22", adjust: false)
        check(stock.contains("&fqt=1"), "个股前复权 fqt=1")
        check(index.contains("&fqt=0"), "指数不复权 fqt=0")
        check(stock.contains("beg=20200101&end=20260922"), "日期去掉横线（东财要 yyyyMMdd）")
        check(stock.contains("fields2=f51,f52,f53,f54,f55,f56,f57,f58,f59,f60,f61"),
              "字段清单固定（顺序即解析下标，重排会静默错位）")

        eq(HistoryReplayJob.defaultBeg, "2020-01-01", "下载起始日")
        eq(HistoryReplayJob.indexSymbols, ["sh000001"], "指数符号（交易日历唯一来源）")
        eq(HistoryReplayJob.replaySlot, 3, "回放轮次必须是 3（SignalClassifier 按它判尾盘信号）")
        check(HistoryReplayJob.replaySlotLabel != "14:50",
              "回放标签不得冒充 14:50（价格是收盘价，不是尾盘盘中价）")
    }

    // MARK: - schema 与口径标记

    static func stageSchema() {
        print("\n[2] reviews.scan_mode 迁移与 DEFAULT 语义")
        DBBootstrap.ensureSwiftOnlySchemaOnDisk()

        let cols = tableColumns("reviews")
        check(cols.contains("scan_mode"), "reviews 有 scan_mode 列")
        let dflt = columnDefault("reviews", "scan_mode")
        eq(dflt, "'live'", "scan_mode 的 DEFAULT 必须是 'live'")

        // 另一个写入方插行（**列清单里没有 scan_mode**）
        // → 必须自动落到 'live'。这条不成立的话，存量行都是 NULL，
        //   而 buildPool 的 `scan_mode='live'` 会把 NULL 静默排除 → 历史样本全没了。
        let pyDay = "2019-01-02"
        _ = try! SQLiteWriter.shared.write { tx in
            try tx.execute("DELETE FROM reviews WHERE sel_date=?", [pyDay])
            try tx.execute("INSERT OR REPLACE INTO reviews(sel_date, review_time,"
                + " four_layer_json, accuracy_json, stocks_json, is_empty_day,"
                + " insights_json, reference_json, report_md, updated_at)"
                + " VALUES(?,?,?,?,?,?,?,?,?,?)",
                [pyDay, "15:05", "{}", "{}", "[]", 0, "[]", NSNull(), "", "2019-01-02T15:05:00"])
        }
        eqs(PhaseStore.shared.reviewScanMode(selDate: pyDay), "live",
            "Python 式插入（不带 scan_mode）自动落到 live")
        eqs(PhaseStore.shared.reviewScanMode(selDate: "1999-01-01"), nil,
            "没有该日的行 → nil（不是空串，也不是 live）")

        // 回放标记：插入**之后**的一次 UPDATE（有意不动 persistReview 的 INSERT）
        let changed = (try? PhaseStore.shared.markReviewScanMode(
            selDate: pyDay, mode: HistoryReplayJob.scanModeReplay)) ?? -1
        eq(changed, 1, "标记命中 1 行")
        eqs(PhaseStore.shared.reviewScanMode(selDate: pyDay), "replay_close",
            "标记后读回来是 replay_close")
        let none = (try? PhaseStore.shared.markReviewScanMode(
            selDate: "1999-01-01", mode: HistoryReplayJob.scanModeReplay)) ?? -1
        eq(none, 0, "标记不存在的日期 → 0 行，不抛错")
    }

    // MARK: - 隔离规则

    /// 隔离规则是「live 数据永不被回放改写」的**唯一**保证，所以既要证"有数据就跳过"，
    /// 也要证"没数据不跳过" —— 只测前者的话，一个恒返回 `skipped` 的实现也能全绿。
    static func stageIsolation() {
        print("\n[3] 隔离规则：只写库里还没有该日数据的日期")
        let withData = "2026-08-12"
        let noData = "2026-08-13"
        insertFakeRound(date: withData)

        let before = dbSnapshot()
        let r1 = try! HistoryReplayJob.replayOne(day: withData, params: [:], paramVersion: "t")
        eq(r1.status, HistoryReplayJob.Status.skippedHasData, "有数据的日期 → 整日跳过")
        check(r1.detail.contains("隔离规则"), "跳过原因写明是隔离规则")
        eq(r1.roundID, 0, "跳过时不该有 round_id")
        eq(dbSnapshot(), before, "跳过之后库**逐表零变化**（picks/scan_rounds/reviews）")

        // 同一天再跑一次也必须还是跳过（幂等：回放不会把 live 数据覆盖掉）
        let r1b = try! HistoryReplayJob.replayOne(day: withData, params: [:], paramVersion: "t")
        eq(r1b.status, HistoryReplayJob.Status.skippedHasData, "重复调用仍跳过")

        // 反证：没有数据的日期**不**返回 skipped_has_data（否则这条规则等于没生效）
        let r2 = try! HistoryReplayJob.replayOne(day: noData, params: [:], paramVersion: "t")
        check(r2.status != HistoryReplayJob.Status.skippedHasData,
              "无数据的日期不该被判为 skipped_has_data（实得 \(r2.status)）")
        eq(r2.status, HistoryReplayJob.Status.skippedNoCalendar,
           "本驱动没下载指数 → 无数据的日期停在'交易日历缺失'")
        check(r2.detail.contains("指数缓存"), "原因指向指数缓存，不指向隔离")
        eq(dbSnapshot(), before, "两次跳过之后库仍零变化")

        // 有数据但日期是"脏"的（非交易日）：隔离优先 —— 先判能不能写，再去取数
        let r3 = try! HistoryReplayJob.replayOne(day: "1990-01-02", params: [:],
                                                 paramVersion: "t")
        eq(r3.status, HistoryReplayJob.Status.skippedNoCalendar, "无数据+无日历 → 日历缺失")
    }

    // MARK: - 断点续传

    static func stageResume() {
        print("\n[4] 断点续传（bar_coverage）")
        let beg = HistoryReplayJob.defaultBeg, end = "2026-09-22"
        try! HistoryBarStore.deleteAll()
        check(HistoryBarStore.coverage().isEmpty, "清空后无覆盖记录")

        // 未覆盖 → 会被请求（这里**不真发请求**，只看判据）
        check(HistoryBarStore.coverage()["600519"]?.covers(beg: beg, end: end) != true,
              "未覆盖的票判为需要下载")

        try! HistoryBarStore.markCoverage(code: "600519", reqBeg: beg, reqEnd: end,
                                          bars: 1145, at: "2026-09-22 08:00:00")
        check(HistoryBarStore.coverage()["600519"]?.covers(beg: beg, end: end) == true,
              "记过之后判为已覆盖")
        // 真发请求的那条路径：全部已覆盖 → requested == 0（**不发任何网络请求**）
        let rep = HistoryReplayJob.downloadBars(codes: ["600519", "600519"], beg: beg, end: end)
        eq(rep.requested, 0, "已覆盖 → 一次请求都不发")
        eq(rep.skipped, 1, "去重后按 1 只跳过（重复代码不该被算两次）")

        // 请求窗口**变宽**必须重下：这是"漏下数据"与"多花时间"之间的方向选择
        check(HistoryBarStore.coverage()["600519"]?.covers(beg: "2015-01-01", end: end) == false,
              "窗口变宽 → 判为未覆盖（安全方向：宁可重下）")
        check(HistoryBarStore.coverage()["600519"]?.covers(beg: beg, end: "2027-01-01") == false,
              "窗口终点变晚 → 判为未覆盖")

        // 指数键必须是**引擎符号**：读取侧 indexBars(symbol: "sh000001") 用的就是它。
        // 两边不一致时读侧只会安静返回空 → 表现为"回放日没有指数数据"，看不出是键错。
        _ = try! HistoryBarStore.saveIndex([
            HistoryBar(code: "sh000001", day: "2026-08-11", open: 3400, close: 3400,
                       high: 3400, low: 3400, volume: 1, amount: 1, amplitude: 1,
                       changePct: 0, turnover: 1),
            HistoryBar(code: "sh000001", day: "2026-08-12", open: 3410, close: 3410,
                       high: 3410, low: 3410, volume: 1, amount: 1, amplitude: 1,
                       changePct: 0, turnover: 1),
        ])
        eq(HistoryBarStore.indexDays(symbol: "sh000001"), ["2026-08-11", "2026-08-12"],
           "指数日按引擎符号可读")
        eq(HistoryBarStore.indexDays(symbol: "000001"), [],
           "裸代码读不到（键写错会静默返回空，所以这条必须钉住）")
        eq(HistoryBarStore.tradingDays(), [], "指数不混进个股表（混进去会参与硬过滤统计）")

        // 有指数缓存之后，同一天应当能走到"扫描"那一步之前（日历可判、T+1 可推）
        let days = HistoryBarStore.indexDays(symbol: "sh000001")
        let cal = TradingCalendar(days: days)
        check(cal.isTradingDay("2026-08-11"), "2026-08-11 是交易日")
        var unc = false
        let n = cal.nextTradingDay("2026-08-11", uncertain: &unc, today: nil, todayIsTrading: false)
        eq(n, "2026-08-12", "T+1 精确到 2026-08-12")
        check(!unc, "T+1 不是猜的")
        // 日历最后一天 → 推不出确定的 T+1（必须置 uncertain，让上层跳过）
        var unc2 = false
        _ = cal.nextTradingDay("2026-08-12", uncertain: &unc2, today: nil, todayIsTrading: false)
        check(unc2, "日历最后一天推 T+1 必须置 uncertain（回落工作日 = 把错误日写进标签）")
    }

    // MARK: - 调优池：默认只用 live（切片 4）

    /// 造两天**结构完全相同**的样本日，只有 `scan_mode` 不同 —— 于是"池里有没有它"
    /// 就只可能由那条过滤决定，不可能被别的差异解释掉。
    ///
    /// 这条断言必须落在**真池**上。只断言 `liveOnlyClause` 的返回值是不够的：
    /// 片段对不对、有没有被拼进 SQL、窗口诊断有没有同步带上，是三件不同的事。
    static func stagePool() {
        print("\n[5] 调优池默认只用 live（iterate.include_replay 默认 false）")
        let liveDay = "2026-08-12"
        let replayDay = "2026-08-13"
        insertFakeSampleDay(liveDay, scanMode: HistoryReplayJob.scanModeLive, code: "600519")
        insertFakeSampleDay(replayDay, scanMode: HistoryReplayJob.scanModeReplay, code: "000001")

        let liveOnly = PhaseTune.buildPool(poolDays: 120)
        let all = PhaseTune.buildPool(poolDays: 120, includeReplay: true)
        check(liveOnly.contains { $0.date == liveDay }, "live 日进池")
        check(!liveOnly.contains { $0.date == replayDay }, "回放日**不进**池（默认只用 live）")
        check(all.contains { $0.date == replayDay }, "显式 includeReplay → 回放日进池")
        check(all.count > liveOnly.count, "开启后池更大（\(all.count) > \(liveOnly.count)）")
        check(!all.isEmpty && !liveOnly.isEmpty, "两边的池都非空（否则上面的包含断言没有意义）")

        // 窗口诊断必须与池**同一份过滤** —— 漏了它会出现"池里 1 个交易日、诊断说窗口里 2 个"，
        // 而两个数看着都正常。判据：给两天各插一条 excluded_stocks，诊断只该数到 live 那天。
        insertExcluded(date: liveDay, code: "600519")
        insertExcluded(date: replayDay, code: "000001")
        guard let tuned = try? PhaseTune.tune(trials: 1, hillRounds: 1, seed: 42),
              let cf = tuned["counterfactual"] as? [String: Any] else {
            check(false, "tune 跑不起来（拿不到 counterfactual）")
            return
        }
        eq(tuned["pool_dates"] as? Int, 1, "tune 的 pool_dates 只数 live 那天")
        eq(cf["excluded_in_window"] as? Int, 1,
           "窗口诊断也只数 live 那天（=1；若忘了同步过滤会是 2）")
        eq(tuned["pool_size"] as? Int, liveOnly.count, "tune 的池大小与 buildPool(默认) 一致")
    }

    /// 造一个"能被 buildPool 收下"的样本日：reviews（够长的 stocks_json）+ scan_rounds +
    /// picks + stock_outcomes（`actualMapFor` 优先走它）。
    static func insertFakeSampleDay(_ date: String, scanMode: String, code: String) {
        _ = try! SQLiteWriter.shared.write { tx in
            try tx.execute("DELETE FROM picks WHERE round_id IN"
                + " (SELECT id FROM scan_rounds WHERE date=?)", [date])
            try tx.execute("DELETE FROM scan_rounds WHERE date=?", [date])
            try tx.execute("DELETE FROM reviews WHERE sel_date=?", [date])
            try tx.execute("DELETE FROM stock_outcomes WHERE sel_date=?", [date])
            try tx.execute("DELETE FROM excluded_stocks WHERE date=?", [date])
            try tx.execute("INSERT INTO scan_rounds(date, slot, slot_label, run_time,"
                + " screener_version, param_version, total_scanned, after_hard_filter,"
                + " after_profile_filter, after_form_filter, excluded_count, final_count,"
                + " tier1_count, tier2_count, market_env_json, result_json, status)"
                + " VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                [date, 3, "14:50", "\(date) 14:50:00", "t", "t",
                 5200, 900, 300, 120, 20, 8, 1, 0, "{}", "{}", "ok"])
            let rid = tx.lastInsertRowID
            try tx.execute("INSERT INTO picks(round_id, date, slot, code, name, tier, score,"
                + " score_raw, ma_qualified, tier_lock_applied, price, change_pct, volume_ratio,"
                + " turnover, amplitude, amount, avg_price, deep_info_json, score_details_json,"
                + " penalty_details_json, market_weak)"
                + " VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                [rid, date, 3, code, "样本", 1, 88.5, 90.0, 1, 0,
                 10.0, 1.2, 1.1, 0.5, 2.0, 500000.0, 9.98, "{}", "[]", "[]", 0])
            // `length(stocks_json)>10` 是 buildPool 的日期条件
            try tx.execute("INSERT OR REPLACE INTO reviews(sel_date, review_time,"
                + " four_layer_json, accuracy_json, stocks_json, is_empty_day,"
                + " insights_json, reference_json, report_md, updated_at, scan_mode)"
                + " VALUES(?,?,?,?,?,?,?,?,?,?,?)",
                [date, "15:05", "{}", "{}", "[{\"code\":\"\(code)\"}]", 0,
                 "[]", NSNull(), "", "\(date)T15:05:00", scanMode])
            // `actualMapFor` 优先走 stock_outcomes（含三档的统一政策标签）
            try tx.execute("INSERT OR REPLACE INTO stock_outcomes(sel_date, code, name, tier,"
                + " open_pct, disc_profit, disc_win, disc_hit, window_profit, close_profit,"
                + " high_profit, target_pct, window_start, window_end, skipped, updated_at,"
                + " sel_price) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                [date, code, "样本", 1, 0.5, 1.2, 1, 1, 2.0, 1.0, 2.5, 1.5,
                 "09:30", "11:30", 0, "\(date)T15:05:00", 10.0])
        }
    }

    static func insertExcluded(date: String, code: String) {
        _ = try! SQLiteWriter.shared.write { tx in
            try tx.execute("INSERT INTO excluded_stocks(round_id, date, slot, code, name, reason)"
                + " VALUES((SELECT id FROM scan_rounds WHERE date=? LIMIT 1),?,?,?,?,?)",
                [date, date, 3, code, "样本", "测试用"])
        }
    }

    // MARK: - 库工具

    static func insertFakeRound(date: String) {
        _ = try! SQLiteWriter.shared.write { tx in
            try tx.execute("DELETE FROM picks WHERE round_id IN"
                + " (SELECT id FROM scan_rounds WHERE date=?)", [date])
            try tx.execute("DELETE FROM scan_rounds WHERE date=?", [date])
            try tx.execute("INSERT INTO scan_rounds(date, slot, slot_label, run_time,"
                + " screener_version, param_version, total_scanned, after_hard_filter,"
                + " after_profile_filter, after_form_filter, excluded_count, final_count,"
                + " tier1_count, tier2_count, market_env_json, result_json, status)"
                + " VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                [date, 3, "14:50", "2026-08-12 14:50:00", "t", "t",
                 5200, 900, 300, 120, 20, 8, 3, 5, "{}", "{}", "ok"])
            let rid = tx.lastInsertRowID
            try tx.execute("INSERT INTO picks(round_id, date, slot, code, name, tier, score,"
                + " score_raw, ma_qualified, tier_lock_applied, price, change_pct, volume_ratio,"
                + " turnover, amplitude, amount, avg_price, deep_info_json, score_details_json,"
                + " penalty_details_json, market_weak)"
                + " VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                [rid, date, 3, "600519", "贵州茅台", 1, 88.5, 90.0, 1, 0,
                 1400.0, 1.2, 1.1, 0.5, 2.0, 500000.0, 1398.0, "{}", "[]", "[]", 0])
        }
    }

    /// 库的逐表行数 —— **拼成固定顺序的字符串**，不能直接比较字典的 `description`
    /// （Swift 字典的 description **不保证键顺序**，那样比较会间歇性红）。
    static func dbSnapshot() -> String {
        let rows = try! SQLiteWriter.shared.write { tx in
            try tx.query("SELECT"
                + " (SELECT COUNT(*) FROM scan_rounds) AS rounds,"
                + " (SELECT COUNT(*) FROM picks) AS picks,"
                + " (SELECT COUNT(*) FROM reviews) AS reviews,"
                + " (SELECT COUNT(*) FROM stock_outcomes) AS outcomes,"
                + " (SELECT COUNT(*) FROM predicts) AS predicts", [])
        }
        let r = rows.first ?? [:]
        func n(_ k: String) -> Int { (r[k] as? Int) ?? -1 }
        return "rounds=\(n("rounds")) picks=\(n("picks")) reviews=\(n("reviews"))"
            + " outcomes=\(n("outcomes")) predicts=\(n("predicts"))"
    }

    static func tableColumns(_ table: String) -> [String] {
        try! SQLiteWriter.shared.write { tx in
            try tx.query("PRAGMA table_info(\(table))", [])
        }.compactMap { $0["name"] as? String }
    }

    static func columnDefault(_ table: String, _ column: String) -> String? {
        let rows = try! SQLiteWriter.shared.write { tx in
            try tx.query("PRAGMA table_info(\(table))", [])
        }
        for r in rows where (r["name"] as? String) == column {
            if let s = r["dflt_value"] as? String { return s }
            return nil
        }
        return nil
    }
}
