import Foundation
@testable import SelectedCore

/// 审计修复的**回归自检**
///
/// 为什么需要这个文件：
/// 这类修复横跨 UI / Store / Scheduler / DataSources / DB 五层，而
/// `swift test` 只覆盖 SelectedCore 纯逻辑层 —— 其余改动仅经过
/// `swift build` 的类型检查。也就是说「现有测试仍通过」只能证明**没改坏**，
/// 证明不了**新行为真的生效**：例如没有任何测试能证明 `writeAsync` 不再死锁、
/// `persistOutcomes` 的 COALESCE 真的保住了标签、K 线缓存真的不缓存空结果。
///
/// 本文件把每条修复里**可判定**的部分钉成断言，接进 `run_all.sh`。
/// 只验证 Swift 侧的行为契约，不比对任何历史期望值。
///
/// 覆盖：
///   DataDirectory 空串过滤（`SELECTED_DATA_DIR=""` 不得拼出 `/selected.sqlite3`）
///   SQLiteWriter.writeAsync 不自队列嵌套死锁（带超时，卡住即失败）
///   persistOutcomes 的 NULL 不覆盖已有 L3 标签（COALESCE）
///   CompareStore.persist 清掉该日已消失的 signal_classes 幽灵行
///   PyRandom.sample 在 k>n 时返回空（不崩、不死循环）
///   applyDiff 中间节点非字典时保留原值（不静默抹掉子树）
///   volMult5d(n=0) 按 5 天算；IntradayFeaturesCalc.compute([], minBars:0) 返回 nil
///   JSONValue 下标语义（缺失键 / 非字典 → NSNull，且不得重建字典）
///   json 型"必须是对象"校验
@main
struct AuditFixesTest {

    static var failures: [String] = []
    static var checked = 0

    static func check(_ cond: Bool, _ label: String) {
        checked += 1
        if cond {
            print("   ✅ \(label)")
        } else {
            failures.append(label)
            print("   ❌ \(label)")
        }
    }

    static func main() {
        // 临时库由**驱动自己**走生产启动路径建（`DBBootstrap.ensureReady()`）。
        //   跑法：`SELECTED_DATA_DIR=<tmp> AuditFixesTest bootstrap`
        if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "bootstrap" {
            if let e = DBBootstrap.ensureReady() {
                print("❌ DBBootstrap.ensureReady 失败：\(e)")
                exit(2)
            }
            print("   schema 就绪（DBBootstrap.ensureReady，与真实 App 同构）")
            exit(0)
        }

        print("== 审计修复回归自检 ==")
        print("   SELECTED_DATA_DIR = \(ProcessInfo.processInfo.environment["SELECTED_DATA_DIR"] ?? "(未设置)")")

        // 临时库可能缺 Swift-only 列，而真实 App 启动时一定跑过 `ensureReady()`，
        //   所以这里必须补上同样的结构 ——
        //   否则 `persistOutcomes` 写 `sel_price` 会抛 "no column named sel_price"，
        //   而下面那几处 `try?` 会把它吞掉，于是标签保护的断言整片变红却看不出原因。
        DBBootstrap.ensureSwiftOnlySchemaOnDisk()

        testDataDirectory()
        testWriteAsync()
        testRandomBounds()
        testApplyDiff()
        testIndicators()
        testJSONValue()
        testJsonValidation()
        testPersistOutcomesCoalesce()
        testSignalClassesStaleRows()
        testPhaseFourTablesRoundTrip()

        print("")
        if failures.isEmpty {
            print("✅ 全部通过（\(checked) 项断言）")
            exit(0)
        }
        print("❌ 失败 \(failures.count)/\(checked) 项：")
        for f in failures { print("   · \(f)") }
        exit(1)
    }

    // MARK: - 数据目录解析

    static func testDataDirectory() {
        print("\n[P1-2] DataDirectory 空串过滤")
        let saved = ProcessInfo.processInfo.environment["SELECTED_DATA_DIR"]
        // 模拟"外部脚本误导出空变量"：不过滤空串的解析路径会把空串直接当目录
        //   → 拼出 `/selected.sqlite3`（根目录）
        setenv("SELECTED_DATA_DIR", "", 1)
        let path = DataDirectory.databasePath
        check(path != "/selected.sqlite3", "空串不拼出 /selected.sqlite3（实得 \(path)）")
        check(path.hasPrefix("/") && path.count > 20, "解析为绝对路径而非空串（实得 \(path)）")
        // 还原
        if let s = saved { setenv("SELECTED_DATA_DIR", s, 1) } else { unsetenv("SELECTED_DATA_DIR") }
        check(DataDirectory.resolve() == (saved ?? DataDirectory.resolve()),
              "还原后与启动时的目录一致")
    }

    // MARK: - writeAsync 死锁

    static func testWriteAsync() {
        print("\n[P0-1] writeAsync 不自队列嵌套死锁")
        // 若在 `queue.async` 内调 `write`（其首行是 `queue.sync`）
        // → 对同一串行队列嵌套同步，libdispatch 必然 trap / 挂死。
        // 用信号量 + 超时判定：卡住即失败（而不是让整个测试挂死）。
        let sem = DispatchSemaphore(value: 0)
        let box = ResultBox()
        Task {
            do {
                let n = try await SQLiteWriter.shared.writeAsync { tx -> Int in
                    try tx.execute("CREATE TABLE IF NOT EXISTS _audit_fix(id INTEGER PRIMARY KEY, v TEXT)")
                    return try tx.execute("INSERT OR REPLACE INTO _audit_fix(id, v) VALUES(1, 'ok')")
                }
                box.value = n
            } catch {
                box.error = String(describing: error)
            }
            sem.signal()
        }
        if sem.wait(timeout: .now() + 10) == .timedOut {
            check(false, "writeAsync 未在 10s 内返回（疑似自死锁）")
            return
        }
        check(box.error == nil, "writeAsync 无错误（error=\(box.error ?? "nil")）")
        check(box.value == 1, "writeAsync 正常返回受影响行数（实得 \(box.value.map(String.init) ?? "nil")）")
        // 同步 write 仍可用（回归保护）
        let ok = (try? SQLiteWriter.shared.write { tx in
            try tx.execute("INSERT OR REPLACE INTO _audit_fix(id, v) VALUES(2, 'sync')")
        }) != nil
        check(ok, "同步 write 仍正常")
    }

    /// 跨隔离域回传结果（`@unchecked Sendable`，同项目既有风格）
    final class ResultBox: @unchecked Sendable {
        var value: Int?
        var error: String?
    }

    // MARK: - PyRandom 边界

    static func testRandomBounds() {
        print("\n[P0-6] PyRandom 边界")
        let rng = PyRandom(seed: 20260920)
        // k > n：`n <= setsize` 分支会负下标崩、`n > setsize` 分支会死循环
        check(rng.sample([1, 2, 3], 5).isEmpty, "sample(k>n) 返回空（不崩不死循环）")
        check(rng.sample([1, 2, 3], 3).count == 3, "sample(k==n) 正常返回 3 个")
        check(rng.sample([1, 2, 3], 0).isEmpty, "sample(k=0) 返回空")
        // 大 n + 大 k：走集合拒绝分支，验证不会死循环
        let big = Array(1...50)
        check(rng.sample(big, 50).count == 50, "sample(n=50,k=50) 正常（集合分支不死循环）")
        // 同 seed 同序列（可复现性不变量）
        let a = PyRandom(seed: 7).sample(big, 10)
        let b = PyRandom(seed: 7).sample(big, 10)
        check(a == b, "同 seed 同序列（可复现）")
    }

    // MARK: - applyDiff

    static func testApplyDiff() {
        print("\n[P1-14] applyDiff 不静默抹掉子树")
        let schema = ParamSchema.shared
        // 正常路径：深合并
        let merged = schema.applyDiff(base: ["a": ["b": 1]], diff: ["a.c": 2])
        let a = merged["a"] as? [String: Any]
        check(a?["b"] as? Int == 1 && a?["c"] as? Int == 2, "正常深合并保留同级键")
        // 畸形路径：中间节点是**标量**
        // 若把它替换成空字典 → 原有子树被整块抹掉
        let malformed = schema.applyDiff(base: ["scoring": ["tiers": 65]],
                                        diff: ["scoring.tiers.tier1_min": 85])
        let sc = malformed["scoring"] as? [String: Any]
        check(sc?["tiers"] as? Int == 65, "中间节点为标量时**保留原值**（实得 \(String(describing: sc?["tiers"]))）")
        // 顶层新键仍能正常写入
        let fresh = schema.applyDiff(base: [:], diff: ["x.y.z": 1])
        check(((fresh["x"] as? [String: Any])?["y"] as? [String: Any])?["z"] as? Int == 1,
              "全新路径正常创建嵌套")
    }

    // MARK: - 假值兜底

    static func testIndicators() {
        print("\n[P2-15] 假值兜底（or N 语义）")
        // 构造能让 n=5 与 n=1 结果不同的数据：窗口末尾一根特别大
        let vols = [1.0, 1, 1, 1, 100, 10]
        let withZero = EngineIndicators.volMult5d(vols, 0)
        let withFive = EngineIndicators.volMult5d(vols, 5)
        let withOne = EngineIndicators.volMult5d(vols, 1)
        check(withZero == withFive, "volMult5d(n=0) 等价于 n=5（实得 \(withZero) vs \(withFive)）")
        check(withZero != withOne, "且不等价于 n=1（旧 bug 会退化成 1 日均量）")
        // 空分时 + minBars=0：若绕过闸门，`tb[tb.count - 1]` 会直接越界崩溃
        let ic = IntradayFeaturesCalc.compute([], today: "2026-09-20",
                                              quote: EngineQuote(), minBars: 0)
        check(ic == nil, "空分时 + minBars=0 返回 nil（不越界崩溃）")
    }

    // MARK: - JSONValue 下标语义

    static func testJSONValue() {
        print("\n[P1-11] JSONValue 下标语义")
        let v = JSONValue(["a": 1, "d": ["b": 2], "n": NSNull()])
        check(v["a"].int == 1, "取到数值")
        check(v["d"]["b"].int == 2, "嵌套字典可下钻")
        check(v["missing"].isNull, "缺失键 → NSNull")
        check(v["n"].isNull, "显式 null → NSNull")
        check(JSONValue("字符串")["x"].isNull, "非字典上取键 → NSNull（不崩）")
        check(JSONValue(nil)["x"].isNull, "nil 包装上取键 → NSNull")
        // 直接取值不得重建字典（性能契约）—— 用大字典的取值耗时做**粗粒度**探针：
        // 若退化为 mapValues 全量重建，1 万次取值会慢一个数量级。这里只做"能跑完"的健全性检查。
        var big: [String: Any] = [:]
        for i in 0..<200 { big["k\(i)"] = i }
        let bigV = JSONValue(big)
        var sum = 0
        for _ in 0..<2000 { sum += bigV["k7"].int ?? 0 }
        check(sum == 7 * 2000, "大字典上 2000 次取值结果正确")
    }

    // MARK: - json 型校验

    static func testJsonValidation() {
        print("\n[P2-8] 参数校验（json 型必须是对象）")
        guard var params = ParamStore.shared.activeParams() else {
            check(false, "activeParams() 不可读（临时库未就绪？）")
            return
        }
        let schema = ParamSchema.shared
        // 基线应当合法
        check(schema.validate(params).isEmpty, "出厂激活参数通过校验")

        // json 型被塞成数组 → 若校验完全放行，随后 buildStrategy 静默返回残缺字典
        if var pr = params["predict_rules"] as? [String: Any] {
            pr["strategies"] = [1, 2, 3]
            params["predict_rules"] = pr
            let errs = schema.validate(params)
            check(errs.contains { $0.contains("应为对象") },
                  "json 型非字典被拦下（errors=\(errs.prefix(2))）")
        } else {
            check(false, "predict_rules 结构异常，无法构造用例")
        }

        // 还原后再测"缺少必填子键"仍被拦（回归保护）。
        // 必填子键的口径见 `required_json_keys`：`predict_rules.strategies` 要求
        //    up_consensus / up_pulse / down_consensus / down_pulse / crash 五个策略名齐全
        //    （不是策略内部的 target_pct）。
        if var params2 = ParamStore.shared.activeParams(),
           var pr = params2["predict_rules"] as? [String: Any],
           var st = pr["strategies"] as? [String: Any], st.count >= 2 {
            st.removeValue(forKey: "up_pulse")
            pr["strategies"] = st
            params2["predict_rules"] = pr
            let errs = schema.validate(params2)
            check(errs.contains { $0.contains("缺少子键") },
                  "缺少必填子键被拦下（errors=\(errs.prefix(2))）")
        } else {
            check(false, "strategies 结构异常，无法构造用例")
        }

        // 另一条必填键规则（iterate.thresholds）也验一遍，避免只覆盖到一条路径
        if var params3 = ParamStore.shared.activeParams(),
           var it = params3["iterate"] as? [String: Any],
           var th = it["thresholds"] as? [String: Any] {
            th.removeValue(forKey: "discipline_window")
            it["thresholds"] = th
            params3["iterate"] = it
            let errs = schema.validate(params3)
            check(errs.contains { $0.contains("discipline_window") },
                  "iterate.thresholds 缺子键被拦下（errors=\(errs.prefix(2))）")
        }
    }

    // MARK: - stock_outcomes 标签保护

    static func testPersistOutcomesCoalesce() {
        print("\n[P0-3] persistOutcomes 的 NULL 不覆盖已有 L3 标签")
        let store = PhaseStore.shared
        let day = "2099-01-02"      // 用远期日期避免与任何真实数据冲突
        _ = try? SQLiteWriter.shared.write { tx in
            try tx.execute("DELETE FROM stock_outcomes WHERE sel_date=?", [day])
        }
        // 这里**不能**用 `try?`：若驱动库缺 `sel_price` 列，`persistOutcomes` 抛错会被
        //   `try?` 吞掉 → 下面 6 条断言全部变红，
        //   而失败原因（"no column named sel_price"）一个字都看不到。
        func persist(_ rows: [[String: Any]]) {
            do {
                try store.persistOutcomes(selDate: day, rows: rows)
            } catch {
                check(false, "persistOutcomes 抛错：\(error)")
            }
        }
        // 第一遍：T+1 当日算出了完整的 L3 标签
        persist([[
            "code": "600000", "name": "浦发银行", "tier": 1,
            "disc_profit": 1.5, "disc_win": 1, "disc_hit": 1, "disc_hit_time": "10:05",
            "window_profit": 2.0, "close_profit": 0.8, "open_pct": 0.3,
            "target_pct": 1.5, "window_start": "09:30", "window_end": "11:30",
        ]])
        // 第二遍：模拟 replay 重跑（目标日 ≠ 运行日 → 拿不到分时 → disc_* 全为 NULL）
        persist([[
            "code": "600000", "name": "浦发银行", "tier": 1,
            "disc_profit": NSNull(), "disc_win": NSNull(), "disc_hit": NSNull(),
            "disc_hit_time": NSNull(), "window_profit": NSNull(),
            "close_profit": 0.8, "open_pct": 0.3,
            "target_pct": NSNull(), "window_start": NSNull(), "window_end": NSNull(),
        ]])
        let row = store.query("SELECT disc_profit, disc_win, disc_hit, disc_hit_time, window_profit, target_pct"
                              + " FROM stock_outcomes WHERE sel_date=? AND code=?", [day, "600000"]).first
        check(row?["disc_profit"] as? Double == 1.5, "disc_profit 未被 NULL 覆盖（实得 \(String(describing: row?["disc_profit"]))）")
        check(row?["disc_win"] as? Int == 1, "disc_win 未被 NULL 覆盖")
        check(row?["disc_hit"] as? Int == 1, "disc_hit 未被 NULL 覆盖")
        check(row?["disc_hit_time"] as? String == "10:05", "disc_hit_time 未被 NULL 覆盖")
        check(row?["window_profit"] as? Double == 2.0, "window_profit 未被 NULL 覆盖")
        check(row?["target_pct"] as? Double == 1.5, "target_pct 未被 NULL 覆盖")
        // 有值时仍应正常更新（不是"永远不覆盖"）
        persist([[
            "code": "600000", "name": "浦发银行", "tier": 1,
            "disc_profit": 3.3, "close_profit": 0.9,
        ]])
        let row2 = store.query("SELECT disc_profit FROM stock_outcomes WHERE sel_date=? AND code=?",
                               [day, "600000"]).first
        check(row2?["disc_profit"] as? Double == 3.3, "本次有值时正常更新（实得 \(String(describing: row2?["disc_profit"]))）")
        // 基准价也要落库，否则 T+3/T+5 两天后算不出来
        persist([["code": "600000", "name": "浦发银行", "tier": 1, "sel_price": 12.34]])
        let row3 = store.query("SELECT sel_price FROM stock_outcomes WHERE sel_date=? AND code=?",
                               [day, "600000"]).first
        check(row3?["sel_price"] as? Double == 12.34,
              "sel_price 落库（实得 \(String(describing: row3?["sel_price"]))）")
        // 反向：本次为 NULL 时不得把已有基准价抹掉（多观察窗全靠它）
        persist([["code": "600000", "name": "浦发银行", "tier": 1, "sel_price": NSNull()]])
        let row4 = store.query("SELECT sel_price FROM stock_outcomes WHERE sel_date=? AND code=?",
                               [day, "600000"]).first
        check(row4?["sel_price"] as? Double == 12.34, "sel_price 未被 NULL 覆盖")
        _ = try? SQLiteWriter.shared.write { tx in
            try tx.execute("DELETE FROM stock_outcomes WHERE sel_date=?", [day])
        }
    }

    // MARK: - signal_classes 幽灵行

    static func testSignalClassesStaleRows() {
        print("\n[P2-4] signal_classes 幽灵行清理")
        let store = PhaseStore.shared
        let day = "2099-01-03"
        _ = try? SQLiteWriter.shared.write { tx in
            try tx.execute("DELETE FROM signal_classes WHERE date=?", [day])
            try tx.execute("DELETE FROM compare_reports WHERE date=?", [day])
        }
        func signal(_ name: String, _ type: String) -> [String: Any] {
            ["name": name, "signal_type": type, "scores": ["1": 80, "2": 78], "trend": "test"]
        }
        // 第一遍：A、B 两只
        let r1: [String: Any] = ["date": day, "status": "ok",
                                 "signals": ["600000": signal("甲", "pulse"),
                                             "600001": signal("乙", "pulse")]]
        _ = try? CompareStore.shared.persist(date: day, report: r1)
        let n1 = count(store, "SELECT COUNT(*) AS n FROM signal_classes WHERE date=?", day)
        check(n1 == 2, "首轮落库 2 条（实得 \(n1)）")
        // 第二遍：B 消失（例如改参数后重算）
        let r2: [String: Any] = ["date": day, "status": "ok",
                                 "signals": ["600000": signal("甲", "pulse")]]
        _ = try? CompareStore.shared.persist(date: day, report: r2)
        let n2 = count(store, "SELECT COUNT(*) AS n FROM signal_classes WHERE date=?", day)
        check(n2 == 1, "重跑后幽灵行已清除（实得 \(n2)，旧行为会是 2）")
        let gone = count(store, "SELECT COUNT(*) AS n FROM signal_classes WHERE date=? AND code=?",
                         day, "600001")
        check(gone == 0, "消失的代码确实被删掉")
        _ = try? SQLiteWriter.shared.write { tx in
            try tx.execute("DELETE FROM signal_classes WHERE date=?", [day])
            try tx.execute("DELETE FROM compare_reports WHERE date=?", [day])
        }
    }

    // MARK: - PhaseStore 四阶段落库表往返

    static func testPhaseFourTablesRoundTrip() {
        print("\n[PhaseStore] 四表落库与读回往返（predicts / verifies / reviews+scan_mode / iterate_reports）")
        let store = PhaseStore.shared
        let reader = SQLiteReader.makeIndependent()
        let selDay = "2099-01-04"
        let predDay1 = "2099-01-05"
        let predDay2 = "2099-01-06"

        _ = try? SQLiteWriter.shared.write { tx in
            try tx.execute("DELETE FROM predicts WHERE sel_date=?", [selDay])
            try tx.execute("DELETE FROM verifies WHERE sel_date=?", [selDay])
            try tx.execute("DELETE FROM reviews WHERE sel_date=?", [selDay])
            try tx.execute("DELETE FROM iterate_reports WHERE trigger_date=?", [selDay])
        }

        do {
            try store.persistPredict(
                date: predDay1, selDate: selDay, predictTime: "09:30",
                marketEnv: ["regime": "BULL_TREND"],
                stocks: [["code": "600000", "strategy_key": "up_consensus"]],
                isEmptyDay: false, overall: ["偏多"]
            )
            try store.persistPredict(
                date: predDay2, selDate: selDay, predictTime: "09:31",
                marketEnv: ["regime": "SIDEWAYS"],
                stocks: [["code": "600036", "strategy_key": "down_pulse"]],
                isEmptyDay: false, overall: ["重算"]
            )
        } catch {
            check(false, "persistPredict 抛错：\(error)")
        }
        let predStore = store.predictRow(selDate: selDay)
        let predReader = reader.predictBySelDate(selDay)
        check(predStore?["date"] as? String == predDay2,
              "PhaseStore.predictRow 取最新 date（ORDER BY date DESC）")
        check(predReader?["predict_date"].string == predDay2
              && predReader?["stocks"][0]["code"].string == "600036",
              "SQLiteReader.predictBySelDate 往返与最新版本一致")

        do {
            try store.persistVerify(
                selDate: selDay, verifyTime: "10:00",
                stats: [
                    "total": ["verified": 2, "wins": 1, "losses": 1, "winrate": 50.0],
                    "consensus": ["verified": 1, "wins": 1, "losses": 0, "winrate": 100.0],
                    "pulse": ["verified": 1, "wins": 0, "losses": 1, "winrate": 0.0],
                ],
                detail: [["code": "600036", "name": "招商银行", "outcome": "盈利", "intraday_pct": 1.8]],
                deviations: [["code": "600036", "name": "招商银行", "predicted": "偏多", "actual_pct": 1.8]],
                warnings: ["轻微放量"],
                isEmptyDay: false
            )
        } catch {
            check(false, "persistVerify 抛错：\(error)")
        }
        let verReader = reader.verifyBySelDate(selDay)
        let verEntity = verReader.map(VerifyResult.init)
        check(verReader?["verify_time"].string == "10:00"
              && verEntity?.stats.total.winrate == 50.0
              && verEntity?.detail.first?.code == "600036"
              && verEntity?.deviations.count == 1
              && verReader?["warnings"][0].string == "轻微放量"
              && verEntity?.isEmptyDay == false,
              "verifies 写读往返与 VerifyResult 实体字段完整（无 JSONValue 二次包装）")

        do {
            try store.persistReview(
                selDate: selDay, reviewTime: "15:05",
                fourLayer: ["layer1": 0.75],
                accuracy: ["hit": 1, "total": 2],
                stocks: [["code": "600036", "close_profit": 1.2]],
                isEmptyDay: false,
                insights: ["纪律窗胜率稳定"],
                reference: ["bench": "sh000001"]
            )
        } catch {
            check(false, "persistReview 抛错：\(error)")
        }
        check(store.reviewScanMode(selDate: selDay) == "live",
              "reviews.scan_mode 默认值必须为 live")
        do {
            _ = try store.markReviewScanMode(selDate: selDay, mode: "replay_close")
        } catch {
            check(false, "markReviewScanMode 抛错：\(error)")
        }
        check(store.reviewScanMode(selDate: selDay) == "replay_close",
              "markReviewScanMode 更新 replay_close 成功")
        let revReader = reader.reviewBySelDate(selDay)
        check(revReader?["review_time"].string == "15:05"
              && revReader?["four_layer_winrate"]["layer1"].double == 0.75
              && revReader?["reference"]["bench"].string == "sh000001",
              "reviews 写读往返字段完整")

        do {
            try store.persistIterate(
                triggerDate: selDay, isEmptyDayReport: false, counter: 3,
                insights: ["三日统计达标"], emptyTrend: ["recent_3": 0],
                fourLayerAvg: ["layer1": 0.68]
            )
        } catch {
            check(false, "persistIterate 抛错：\(error)")
        }
        let iterStore = store.iterateReport(triggerDate: selDay)
        let iterReader = reader.iterateByDate(selDay)
        check(iterStore?.counter == 3
              && (iterStore?.insightsJSON?.contains("三日统计达标") ?? false),
              "PhaseStore.iterateReport 读回一致")
        check(iterReader?["counter"].int == 3
              && iterReader?["empty_trend"]["recent_3"].int == 0
              && iterReader?["four_layer_avg"]["layer1"].double == 0.68,
              "SQLiteReader.iterateByDate 往返字段完整")

        _ = try? SQLiteWriter.shared.write { tx in
            try tx.execute("DELETE FROM predicts WHERE sel_date=?", [selDay])
            try tx.execute("DELETE FROM verifies WHERE sel_date=?", [selDay])
            try tx.execute("DELETE FROM reviews WHERE sel_date=?", [selDay])
            try tx.execute("DELETE FROM iterate_reports WHERE trigger_date=?", [selDay])
        }
    }

    static func count(_ store: PhaseStore, _ sql: String, _ params: Any?...) -> Int {
        let row = store.query(sql, params.map { $0 }).first
        return (row?["n"] as? NSNumber)?.intValue ?? (row?["n"] as? Int ?? -1)
    }
}
