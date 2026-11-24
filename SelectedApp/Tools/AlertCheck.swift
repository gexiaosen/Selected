import Foundation
import SQLite3
@testable import SelectedCore

/// 自选提醒（用户自定义告警）**真实库自检** —— 建表 / 保存读回 / 触发与去重 /
/// 状态继承 / 降级迁移 / 脏行容错。
///
/// 跑之前必须把 `SELECTED_DATA_DIR` 指到**现造的库**（`alert_test.sh` 负责）。
/// **全程离线**：本驱动不调 `StockQuotes.fetch*`（那是网络）—— 行情用
///   `StockQuotes.parseBatch` 吃**真实抓取**的响应原文构造，走生产解析器，
///   不手工 memberwise 拼一个"形状可疑"的 quote。
///
/// ## 为什么必须在**真库**上（而不是 `swift test`）
/// · 「降级 → 迁移 → 幂等」要 `DROP TABLE` 再跑迁移，而 XCTest 里换数据目录会写错库
///   （`SQLiteWriter` / `AlertReader` 的句柄是**进程级缓存**的）；
/// · 最要紧的两条不变量（未变规则**继承**触发状态 / 改阈值**重新武装**）需要
///   "写 → 读回 → 再写 → 再读回"的完整往返，且中间要有一次 `markFired`。
///
/// ## 与 `swift test` 的分工
/// `AlertRulesTests`（35 项）覆盖**纯函数**：解析、判据、闭区间、窗口边界、去重语义。
/// 本驱动只覆盖**必须碰库**的部分：DDL 列序、REAL 精度往返、`carryOver` 的落库后果、
/// 全量替换、降级迁移、脏行（认不出的 kind / repeat_mode）。
@main
struct AlertCheck {
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

    /// 驱动里的**写操作一律不许 `try?`**：
    /// `try?` 把"写失败"变成静默的"没写进去"，于是后面所有断言都变成
    /// "读回是空的" —— 报出来的错指向错误的地方，比直接报红难查得多。
    /// 所有 `throws` 调用必须经过这里：失败时**记一条失败并继续**（不中断，
    /// 以便一次跑完拿到全部信息），返回值给 `?? -1` 之类兜底。
    @discardableResult
    static func must<T>(_ label: String, _ body: () throws -> T) -> T? {
        do {
            return try body()
        } catch {
            check(false, "\(label) 抛错：\(error)")
            return nil
        }
    }

    static func main() {
        print("== 自选提醒 自检 ==")
        stageBootstrap()
        stageSaveAndRead()
        stageWindow()
        stageReplaceAndClear()
        stageMultiCode()
        stageFiringAndDedup()
        stageOnceAndDownPct()
        stageCarryOver()
        stageAmountFamily()
        stageCorruptRows()
        stageDegradeMigrate()

        print("\n—— 检查 \(checks) 项，失败 \(failures.count) 项")
        if !failures.isEmpty {
            for f in failures { print("   ❌ \(f)") }
            exit(1)
        }
        exit(0)
    }

    // MARK: - [1] 建库 + Swift-only 建表

    static func stageBootstrap() {
        print("\n[1] 建库 + Swift-only 建表（列序逐字一致 / 无二级索引）")
        let dir = DataDirectory.resolve()
        check(!FileManager.default.fileExists(atPath: dir + "/selected.sqlite3"),
              "起点是空目录：\(dir)")
        let err = DBBootstrap.ensureReady()
        check(err == nil, "ensureReady 成功（\(err ?? "ok")）")
        DBBootstrap.ensureSwiftOnlySchemaOnDisk()

        eq(tableColumns(AlertStore.alertsTable),
           ["code", "kind", "threshold", "repeat_mode",
            "last_fired_at", "last_fired_day", "updated_at"],
           "⚠ watch_alerts 列序与 DDL 逐字一致（对账侧按顺序比，顺序错会红）")
        eq(tableColumns(AlertStore.settingsTable),
           ["code", "time_window", "updated_at"],
           "⚠ watch_alert_settings 列序与 DDL 逐字一致")

        // 断言"确实没建二级索引" —— 主键 `(code, kind, threshold)`
        //   的最左前缀就是 `code`，按 code 查已走主键索引，再补一个纯冗余。
        //   `sqlite_autoindex_*` 是 SQLite 为**非 INTEGER 主键**自动建的，不是我们建的。
        let aIdx = tableIndexes(AlertStore.alertsTable)
        let sIdx = tableIndexes(AlertStore.settingsTable)
        eq(aIdx.filter { !$0.hasPrefix("sqlite_autoindex_") }, [],
           "watch_alerts 没有二级索引（故 SWIFT_ONLY_INDEXES 不登记它）")
        eq(sIdx.filter { !$0.hasPrefix("sqlite_autoindex_") }, [],
           "watch_alert_settings 没有二级索引")
        // 反向：确认上面两条不是**空转**（表真的存在、主键自动索引真的建出来了）
        check(aIdx.contains { $0.hasPrefix("sqlite_autoindex_") },
              "watch_alerts 的主键自动索引存在（上面那条不是空转）")
        check(sIdx.contains { $0.hasPrefix("sqlite_autoindex_") },
              "watch_alert_settings 的主键自动索引存在")
    }

    // MARK: - [2] 保存 + 读回（逐字段）

    static func stageSaveAndRead() {
        print("\n[2] 保存 + 读回（逐字段，含 REAL 精度）")
        wipe()

        let code = "600276"
        let n = must("save(600276)") {
            try AlertStore.save(code: code,
                                drafts: [draft(.upPrice, 12.34, .once),
                                         draft(.downPrice, 9.87, .daily),
                                         draft(.upPct, 5.5, .daily),
                                         draft(.downPct, 3.25, .daily)],
                                window: .tail, at: "2026-09-23 09:00:00")
        }
        eq(n ?? -1, 4, "save 写入 4 条")

        let back = AlertStore.rules(code: code)
        eq(back.count, 4, "读回 4 条")
        // 顺序是 kind 的**文本**升序（SQLite BINARY collation）：
        //   "down_pct" < "down_price"（第 7 位 c < r）< "up_pct" < "up_price"
        eq(back.map { $0.kind.rawValue },
           ["down_pct", "down_price", "up_pct", "up_price"],
           "按 kind 文本升序（稳定 → 可对账）")

        guard back.count == 4 else { return check(false, "条数不对，跳过逐字段断言") }
        eq(back[0].threshold, 3.25, "down_pct.threshold 往返")
        eq(back[0].repeatMode, .daily, "down_pct.repeat_mode 往返")
        eq(back[1].threshold, 9.87, "down_price.threshold 往返")
        eq(back[2].threshold, 5.5, "up_pct.threshold 往返")
        eq(back[3].threshold, 12.34, "up_price.threshold 往返")
        eq(back[3].repeatMode, .once, "up_price.repeat_mode 往返（单次）")
        for r in back {
            eq(r.lastFiredAt, "", "\(r.kind.rawValue).last_fired_at 初值 = 空串")
            eq(r.lastFiredDay, "", "\(r.kind.rawValue).last_fired_day 初值 = 空串")
        }

        // 时间窗与规则**分表**存：同一个量不许有第二份副本
        eq(AlertStore.window(code: code), .tail, "时间窗往返")
        eq(AlertStore.settingsCount(), 1, "settings 行数 = 配过的 code 数")

        // 长小数：12.3456789 不是二进制可精确表示的 → 证明 REAL 列按 IEEE754
        //   原样往返
        must("save(600000)") {
            try AlertStore.save(code: "600000",
                                drafts: [draft(.upPrice, 12.3456789, .once)],
                                window: .anytime, at: "2026-09-23 09:00:00")
        }
        eq(AlertStore.rules(code: "600000").first?.threshold, 12.3456789,
           "⚠ 长小数精确往返（REAL 不经过字符串）")
        eq(AlertStore.ruleCount(), 5, "ruleCount 报 5（4 + 1）")
        eq(AlertStore.settingsCount(), 2, "settingsCount 报 2")
    }

    // MARK: - [3] 时间窗

    static func stageWindow() {
        print("\n[3] 时间窗（默认 / 认不出的值 / 全表）")
        eq(AlertStore.window(code: "000001"), .anytime,
           "没配过 → .anytime（出厂默认，与 DDL 的 DEFAULT 同值）")

        // 认不出的值 → **放宽**成 .anytime。方向与 `rule(from:)` 的"跳过"**故意相反**：
        //   时间窗认不出只是"不知道限定在哪个子时段"，宁可多提醒也不能静默关掉。
        raw("INSERT OR REPLACE INTO watch_alert_settings(code, time_window, updated_at)"
                + " VALUES(?,?,?)", ["000001", "from_the_future", "t"])
        eq(AlertStore.window(code: "000001"), .anytime,
           "⚠ 认不出的值 → .anytime（放宽：宁可多提醒，不静默关掉）")

        let wins = AlertStore.windowsByCode()
        eq(wins["600276"], .tail, "windowsByCode 带上 600276 的 .tail")
        eq(wins["000001"], .anytime, "windowsByCode 对认不出的值也放宽")
        eq(AlertStore.settingsCount(), 3, "settingsCount 报 3（含脏行那条）")
    }

    // MARK: - [4] 全量替换 + 清空

    static func stageReplaceAndClear() {
        print("\n[4] 全量替换 + 清空（不是追加）")
        let code = "600276"

        // 换成 1 条 → 旧的 3 条必须消失（否则留下"幽灵提醒"）
        must("save(600276) 换 1 条") {
            try AlertStore.save(code: code, drafts: [draft(.upPct, 7.0, .daily)],
                                window: .open, at: "2026-09-23 10:00:00")
        }
        eq(AlertStore.rules(code: code).map { $0.kind.rawValue }, ["up_pct"],
           "换成 1 条后只剩这 1 条（旧的被清掉）")
        eq(AlertStore.window(code: code), .open, "时间窗跟着更新")
        eq(AlertStore.ruleCount(), 2, "ruleCount = 2（600276 的 1 条 + 600000 的 1 条）")

        // 空 drafts = 取消该票全部提醒 → **连时间窗一起删**
        // （没有规则时时间窗没有意义，留着会让"配了东西吗"读不准）
        let n = must("save(600276) 空 drafts") {
            try AlertStore.save(code: code, drafts: [], window: .anytime, at: "t3")
        }
        eq(n ?? -1, 0, "空 drafts 返回 0")
        eq(AlertStore.rules(code: code).count, 0, "规则清空")
        eq(AlertStore.window(code: code), .anytime,
           "⚠ 时间窗记录也删了（不是留一条 .anytime 的残留）")
        check(!AlertStore.configuredCodes().contains(code),
              "configuredCodes 不再包含它 → 铃铛变回「斜杠」")

        // 空 code 不发写（避免往库里塞一条 code = "" 的规则）
        let n2 = must("save(空 code)") {
            try AlertStore.save(code: "   ", drafts: [draft(.upPct, 1, .daily)],
                                window: .anytime, at: "t")
        }
        eq(n2 ?? -1, 0, "空 / 全空白 code → 0（不发写）")

        // 复位（后面各 stage 自带 wipe，这里顺手把 [2][3] 的夹具清掉）
        wipe()
        eq(AlertStore.ruleCount(), 0, "wipe 后规则表空")
        eq(AlertStore.settingsCount(), 0, "wipe 后设置表空")
    }

    // MARK: - [5] 多只票互不影响

    static func stageMultiCode() {
        print("\n[5] 多只票互不影响")
        wipe()
        must("save(600276)") {
            try AlertStore.save(code: "600276", drafts: [draft(.upPrice, 10, .once)],
                                window: .open, at: "t")
        }
        must("save(000001)") {
            try AlertStore.save(code: "000001", drafts: [draft(.downPct, 5, .daily)],
                                window: .tail, at: "t")
        }
        eq(AlertStore.ruleCount(), 2, "两张票各 1 条")
        eq(AlertStore.configuredCodes(), ["600276", "000001"], "configuredCodes 两只都在")

        let byCode = AlertStore.rulesByCode()
        eq(byCode["600276"]?.first?.kind, .upPrice, "rulesByCode 取到 600276 的 up_price")
        eq(byCode["000001"]?.first?.kind, .downPct, "rulesByCode 取到 000001 的 down_pct")
        eq(byCode.count, 2, "rulesByCode 归出 2 组")
        eq(AlertStore.window(code: "600276"), .open, "600276 的窗口")
        eq(AlertStore.window(code: "000001"), .tail, "000001 的窗口")

        let removed = must("removeAll(600276)") { try AlertStore.removeAll(code: "600276") }
        eq(removed ?? -1, 1, "removeAll 删掉 1 条")
        eq(AlertStore.ruleCount(), 1, "只剩 000001 的 1 条")
        eq(AlertStore.window(code: "600276"), .anytime, "removeAll 连时间窗一起删")
        eq(AlertStore.window(code: "000001"), .tail, "没被删的那只不受影响")
    }

    // MARK: - [6] 触发 → 落库 → 同日幂等 → 跨日重新武装

    static func stageFiringAndDedup() {
        print("\n[6] 评估 → 落库 → 同日幂等 → 跨日重新武装")
        wipe()
        let code = "600276"
        must("save") {
            try AlertStore.save(code: code, drafts: [draft(.upPrice, 10.0, .daily)],
                                window: .anytime, at: "t")
        }

        // 未到价
        eq(AlertEval.evaluate([subject(code, "恒瑞医药", price: 9.99, pct: 1.0)],
                              at: clock("2026-09-23")).count, 0,
           "9.99 < 10.00 → 不触发")

        // 到价（**闭区间**：恰好等于也触发）
        let f1 = AlertEval.evaluate([subject(code, "恒瑞医药", price: 10.00, pct: 1.0)],
                                    at: clock("2026-09-23"))
        eq(f1.count, 1, "恰好等于阈值也触发（闭区间）")
        eq(f1.first?.threshold, 10.0, "firing.threshold 往返")
        eq(f1.first?.title, "到价提醒", "通知标题")
        eq(f1.first?.body, "恒瑞医药 涨到 10.00（现价 10.00）", "通知正文")
        eq(f1.first?.identifier, "selected.alert.600276.up_price.10.0000",
           "通知 identifier 稳定（Notifier 靠它去重替换，不是堆叠）")
        eq(f1.first?.dedupKey, "600276|up_price|10.0000|2026-09-23",
           "会话去重键带日期后缀（daily）")

        // 落库
        let n = must("markFired") { try AlertStore.markFired(f1) }
        eq(n ?? -1, 1, "markFired 更新 1 行")
        let r1 = AlertStore.rules(code: code).first
        eq(r1?.lastFiredDay, "2026-09-23", "last_fired_day 落库")
        eq(r1?.lastFiredAt, "2026-09-23 10:00:00", "last_fired_at 落库")

        // 同日重跑必须幂等 —— 这是「每日重复」的全部意义（否则每 5 秒弹一次）
        eq(AlertEval.evaluate([subject(code, "恒瑞医药", price: 10.5, pct: 1.0)],
                              at: clock("2026-09-23")).count, 0,
           "⚠ 同日再评估 → 0（daily 已响过）")

        // 跨日重新武装
        eq(AlertEval.evaluate([subject(code, "恒瑞医药", price: 10.5, pct: 1.0)],
                              at: clock("2026-09-24")).count, 1,
           "次日重新武装 → 触发")

        // 第一道闸门：非交易日一律不评估（否则周末拿周五收盘价再弹一次）
        eq(AlertEval.evaluate([subject(code, "恒瑞医药", price: 10.5, pct: 1.0)],
                              at: clock("2026-09-26", trading: false)).count, 0,
           "⚠ 非交易日 → 0")
        // 空 day（编程错误）：两种失效方向里"不响"比"每 5 秒响"安全
        eq(AlertEval.evaluate([subject(code, "恒瑞医药", price: 10.5, pct: 1.0)],
                              at: AlertClock(day: "", minuteOfDay: 600,
                                             isTradingDay: true, stamp: "x")).count, 0,
           "⚠ 空 day → 0（不响，而不是每 5 秒响一次）")

        // 时间窗闸门（窗口口径来自 `AlertWindow.sessionRanges`，全项目唯一一份）
        eq(AlertEval.evaluate([subject(code, "恒瑞医药", price: 10.5, pct: 1.0)],
                              at: clock("2026-09-25", 700)).count, 0,
           "700 分 = 11:40 在午休 → 0")
        eq(AlertEval.evaluate([subject(code, "恒瑞医药", price: 10.5, pct: 1.0)],
                              at: clock("2026-09-25", 780)).count, 1,
           "780 分 = 13:00 下午开盘 → 触发")

        // 无行情（price == 0）→ 必须不评估。
        //   不拦的话 `down_price` 的判据 `price <= threshold` **恒真**
        //   → 一次行情抖动就能把所有"跌破"规则全弹一遍。
        must("save(000002 down_price)") {
            try AlertStore.save(code: "000002", drafts: [draft(.downPrice, 100.0, .daily)],
                                window: .anytime, at: "t")
        }
        eq(AlertEval.evaluate([subject("000002", "样本", price: 0, pct: 0)],
                              at: clock("2026-09-30")).count, 0,
           "⚠⚠ price == 0 时跌破类规则**不触发**（0 <= 100 恒真 → 否则会全弹）")
        eq(AlertEval.evaluate([subject("000002", "样本", price: Double.nan, pct: 0)],
                              at: clock("2026-09-30")).count, 0,
           "NaN 现价 → 不触发")
        eq(AlertEval.evaluate([AlertSubject(code: "", name: "", price: 10,
                                            changeAmount: 0, changePercent: 1, rules: [],
                                            window: .anytime)],
                              at: clock("2026-09-30")).count, 0,
           "空 code 的 subject → 跳过")
    }

    // MARK: - [7] 单次提醒永久哑火 + 跌幅类

    static func stageOnceAndDownPct() {
        print("\n[7] 单次提醒永久哑火（跨日也不重新武装）+ 跌幅类")
        wipe()

        // 单次
        must("save(600519 once)") {
            try AlertStore.save(code: "600519", drafts: [draft(.upPct, 3.0, .once)],
                                window: .anytime, at: "t")
        }
        let f = AlertEval.evaluate([subject("600519", "贵州茅台", price: 1500, pct: 3.5)],
                                   at: clock("2026-09-23"))
        eq(f.count, 1, "涨幅 3.5% ≥ 3.0 → 触发")
        eq(f.first?.body, "贵州茅台 涨幅达 3.00%（现涨 3.50%）", "百分比类通知正文")
        eq(f.first?.dedupKey, "600519|up_pct|3.0000",
           "⚠ 单次提醒的去重键**不带日期后缀**（跨日不重新武装）")
        eq(must("markFired") { try AlertStore.markFired(f) } ?? -1, 1, "落库")
        eq(AlertEval.evaluate([subject("600519", "贵州茅台", price: 1500, pct: 3.5)],
                              at: clock("2026-09-23")).count, 0, "同日不重复")
        eq(AlertEval.evaluate([subject("600519", "贵州茅台", price: 1500, pct: 3.5)],
                              at: clock("2026-09-24")).count, 0,
           "⚠⚠ 次日也不重复（单次 ≠ 每日重复；跨日清 `sessionFired` 也救不回来）")

        // 跌幅类：阈值在库里存**正数**，比较时才取负
        must("save(000001 down_pct)") {
            try AlertStore.save(code: "000001", drafts: [draft(.downPct, 3.0, .daily)],
                                window: .anytime, at: "t")
        }
        eq(AlertStore.rules(code: "000001").first?.threshold, 3.0,
           "⚠ 跌幅阈值在库里是**正数** 3.0（存负数会让校验范围与比较值分叉）")
        let fd = AlertEval.evaluate([subject("000001", "平安银行", price: 10, pct: -3.0)],
                                    at: clock("2026-09-23"))
        eq(fd.count, 1, "跌幅恰好 -3.00% → 触发（闭区间）")
        eq(fd.first?.body, "平安银行 跌幅达 3.00%（现跌 3.00%）", "跌幅类通知正文")
        eq(AlertEval.evaluate([subject("000001", "平安银行", price: 10, pct: -2.99)],
                              at: clock("2026-09-24")).count, 0,
           "-2.99% 未达 3.00% → 不触发")
    }

    // MARK: - [8] 状态继承 vs 重新武装（本模块最容易静默出错的一处）

    static func stageCarryOver() {
        print("\n[8] ⚠⚠ 保存时未变规则继承触发状态 / 改了语义重新武装")
        wipe()
        let code = "600276"
        let day = "2026-09-23"

        must("save 两条") {
            try AlertStore.save(code: code,
                                drafts: [draft(.upPrice, 10.0, .daily),
                                         draft(.upPct, 5.0, .daily)],
                                window: .anytime, at: "t1")
        }
        // 让两条都响一次并落库
        let f = AlertEval.evaluate([subject(code, "恒瑞医药", price: 10.5, pct: 5.5)],
                                   at: clock(day))
        eq(f.count, 2, "两条都触发（up_price 与 up_pct）")
        eq(must("markFired 两条") { try AlertStore.markFired(f) } ?? -1, 2, "两条都落库")
        eq(AlertStore.rules(code: code).filter { $0.lastFiredDay == day }.count, 2,
           "两条都记上了 last_fired_day")

        // ① 原样重存（用户在弹窗里点了确认但一个字没改）→ **必须继承**
        must("save 原样重存") {
            try AlertStore.save(code: code,
                                drafts: [draft(.upPrice, 10.0, .daily),
                                         draft(.upPct, 5.0, .daily)],
                                window: .anytime, at: "t2")
        }
        let kept = AlertStore.rules(code: code)
        eq(kept.count, 2, "还是两条")
        eq(kept.filter { $0.lastFiredDay == day }.count, 2,
           "⚠⚠ 未变规则**继承**了 last_fired_day"
               + "（漏了它不会报错/不会崩/界面全对，只是每日重复退化成「每次保存后再响一次」）")
        eq(kept.filter { $0.lastFiredAt == "\(day) 10:00:00" }.count, 2,
           "last_fired_at 也继承")
        eq(AlertEval.evaluate([subject(code, "恒瑞医药", price: 10.5, pct: 5.5)],
                              at: clock(day)).count, 0,
           "重存后同日仍不重复（继承的可观测后果 —— 这一条才是用户能感知的）")

        // ② 改阈值 → 语义变了 → **重新武装**
        must("save 改 up_price 阈值") {
            try AlertStore.save(code: code,
                                drafts: [draft(.upPrice, 11.0, .daily),
                                         draft(.upPct, 5.0, .daily)],
                                window: .anytime, at: "t3")
        }
        let changed = AlertStore.rules(code: code)
        eq(changed.first { $0.kind == .upPrice }?.lastFiredDay, "",
           "⚠ 改了阈值 → 重新武装（last_fired_day 清空）")
        eq(changed.first { $0.kind == .upPct }?.lastFiredDay, day,
           "没改的那条仍继承")
        let refired = AlertEval.evaluate([subject(code, "恒瑞医药", price: 11.5, pct: 5.5)],
                                        at: clock(day))
        eq(refired.count, 1, "改后按新阈值重新触发（只有一条）")
        eq(refired.first?.kind, .upPrice, "重新触发的是 up_price（upPct 仍哑火）")

        // ③ 改重复方式 → 也算语义变了 → 重新武装
        must("save 改 repeat_mode") {
            try AlertStore.save(code: code, drafts: [draft(.upPct, 5.0, .once)],
                                window: .anytime, at: "t4")
        }
        let modeChanged = AlertStore.rules(code: code)
        eq(modeChanged.count, 1, "只留 1 条（全量替换：up_price 那条被删了）")
        eq(modeChanged.first?.lastFiredDay, "",
           "⚠ 改了 repeat_mode（daily → once）→ 重新武装")
        eq(modeChanged.first?.lastFiredAt, "", "last_fired_at 也清空")
    }

    // MARK: - [9] 脏行容错（认不出的 kind / repeat_mode）

    static func stageCorruptRows() {
        print("\n[10] 脏行：认不出的 kind / repeat_mode → **跳过**，不猜")
        wipe()

        // 方向与 `window(code:)` 的放宽**故意相反**：
        //   一条认不出类型的规则，我们既不知道它该在什么条件下触发、也不知道该报什么文案 ——
        //   硬套一个默认类型会**凭空造出一条用户没设过的提醒**。
        raw("INSERT INTO watch_alerts(code, kind, threshold, repeat_mode,"
                + " last_fired_at, last_fired_day, updated_at) VALUES(?,?,?,?,?,?,?)",
            ["600276", "kind_from_the_future", 10.0, "daily", "", "", "t"])
        raw("INSERT INTO watch_alerts(code, kind, threshold, repeat_mode,"
                + " last_fired_at, last_fired_day, updated_at) VALUES(?,?,?,?,?,?,?)",
            ["600276", "up_price", 11.0, "repeat_from_the_future", "", "", "t"])

        eq(AlertStore.ruleCount(), 2, "ruleCount 数的是**行**（2 行脏数据）")
        eq(AlertStore.rules(code: "600276").count, 0, "⚠ 两行都认不出 → 读出来是空")
        check(!AlertStore.configuredCodes().contains("600276"),
              "⚠ configuredCodes 不含它 → 铃铛显示「未设置」（而不是「设了但永远不响」）")
        eq(AlertStore.rulesByCode(), [:], "rulesByCode 也跳过（不产生半条规则）")

        // 混一条正常的：只有它读得出来
        must("save(600276 正常一条)") {
            try AlertStore.save(code: "600276", drafts: [draft(.upPrice, 12.0, .daily)],
                                window: .anytime, at: "t")
        }
        eq(AlertStore.rules(code: "600276").map { $0.threshold }, [12.0],
           "全量替换后只剩那条正常的（脏行被一起清掉）")
    }

    // MARK: - [10] 降级 → 迁移 → 幂等

    static func stageDegradeMigrate() {
        print("\n[11] 降级 → 迁移 → 幂等（老库拿不到新表的防复发）")

        // 为什么要单独测：`CREATE TABLE IF NOT EXISTS` 对**已存在**的表什么都不做，
        //   所以"全新库"路径**永远测不到**建表语句有没有真的被执行到 ——
        //   而且 `createWatchAlerts` 失败只 `NSLog`（不改 `ensureReady` 的返回值）
        //   → **老库会静默地永远没有这两张表**，界面上只是"铃铛一直显示未设置"。
        //   手法：先把表 drop 掉（模拟老库），再跑公开入口 `ensureSwiftOnlySchemaOnDisk`。
        raw("DROP TABLE IF EXISTS watch_alerts")
        raw("DROP TABLE IF EXISTS watch_alert_settings")
        eq(tableColumns(AlertStore.alertsTable), [], "降级成功：watch_alerts 不存在")
        eq(tableColumns(AlertStore.settingsTable), [], "降级成功：watch_alert_settings 不存在")

        DBBootstrap.ensureSwiftOnlySchemaOnDisk()
        let a = tableColumns(AlertStore.alertsTable)
        let s = tableColumns(AlertStore.settingsTable)
        eq(a, ["code", "kind", "threshold", "repeat_mode",
               "last_fired_at", "last_fired_day", "updated_at"],
           "⚠ 迁移后 watch_alerts 回来了，且列序与 DDL 逐字一致")
        eq(s, ["code", "time_window", "updated_at"], "⚠ 迁移后 watch_alert_settings 回来了")

        // 幂等：再跑一遍不该报错、列也不变（`IF NOT EXISTS` 天然幂等）
        DBBootstrap.ensureSwiftOnlySchemaOnDisk()
        eq(tableColumns(AlertStore.alertsTable), a, "迁移幂等（重复执行列不变）")
        eq(tableColumns(AlertStore.settingsTable), s, "迁移幂等（设置表）")

        // 迁移后真的能用（不只是"表在"，而是"读写通"）
        let n = must("迁移后 save") {
            try AlertStore.save(code: "600276", drafts: [draft(.upPrice, 9.9, .once)],
                                window: .tail, at: "t")
        }
        eq(n ?? -1, 1, "迁移后 save 通")
        eq(AlertStore.rules(code: "600276").first?.threshold, 9.9, "迁移后读回通")
        eq(AlertStore.window(code: "600276"), .tail, "迁移后时间窗读回通")
    }

    // MARK: - 库工具

    /// 只读连接经 `SQLiteWriter`（写连接）读 —— 驱动里刻意不复用 `AlertStore` 的私有 reader，
    /// 免得"用被测对象读被测对象的元数据"。
    // MARK: - [11] 涨跌额族

    /// 覆盖：落库往返 / 判据（闭区间 + 方向 + 平盘含负零）/ 与涨幅族**互不顶掉** /
    ///       判据读的是 `changeAmount` 而不是价格 / 通知文案带「元」
    static func stageAmountFamily() {
        print("\n[12] 涨跌额族（up_amount / down_amount）")
        wipe()
        let code = "002623"   // 亚玛顿（老板题面里那只）
        let day = "2026-09-23"

        must("save(002623 涨额+跌额)") {
            try AlertStore.save(code: code,
                                drafts: [draft(.upAmount, 1.00, .daily),
                                         draft(.downAmount, 0.50, .daily)],
                                window: .anytime, at: "2026-09-23 09:00:00")
        }
        let back = AlertStore.rules(code: code)
        eq(back.count, 2, "读回 2 条")
        eq(back.map { $0.kind.rawValue }, ["down_amount", "up_amount"],
           "按 kind 文本升序（down_amount < up_amount）")
        eq(back.first { $0.kind == .upAmount }?.threshold, 1.00, "涨额阈值往返")
        eq(back.first { $0.kind == .upAmount }?.repeatMode, .daily, "涨额重复方式往返")
        eq(back.first { $0.kind == .downAmount }?.threshold, 0.50, "跌额阈值往返")

        // 涨跌额**显式传**（默认 0 会让下面的反向断言假绿）
        let hit = subject(code, "亚玛顿", price: 21.50, amt: 1.05, pct: 5.13)
        let out = AlertEval.evaluate([hit], at: clock(day))
        eq(out.count, 1, "涨 1.05 元 → 只触发「涨额达 1.00」这一条")
        eq(out.first?.kind, .upAmount, "触发的是 up_amount")
        eq(out.first?.identifier, "selected.alert.002623.up_amount.1.0000",
           "通知标识按规则稳定")
        eq(out.first?.body, "亚玛顿 涨额达 1.00 元（现涨 1.05 元）", "通知正文带「元」")

        // 反向：没到阈值不响
        let miss = subject(code, "亚玛顿", price: 21.50, amt: 0.99, pct: 5.13)
        eq(AlertEval.evaluate([miss], at: clock(day)).count, 0, "涨 0.99 元 → 不触发")

        // 跌额方向
        let downHit = subject(code, "亚玛顿", price: 19.40, amt: -0.62, pct: -3.10)
        let dOut = AlertEval.evaluate([downHit], at: clock(day))
        eq(dOut.count, 1, "跌 0.62 元 → 触发「跌额达 0.50」")
        eq(dOut.first?.kind, .downAmount, "触发的是 down_amount")

        // 平盘两边都不触发 —— 含接口给的**负零**（`-0.00`，见设计 §13.2 实测）
        let flat = subject(code, "亚玛顿", price: 20.02, amt: -0.0, pct: 0)
        eq(AlertEval.evaluate([flat], at: clock(day)).count, 0, "平盘（-0.00）两边都不触发")

        // 与涨幅族**互不顶掉**：同一只票同时设「涨 1 元」与「涨 5%」，
        //   在 amt=1.05 / pct=5.13 时**两条都要响**（各一条通知）
        wipe()
        must("save(002623 涨额+涨幅)") {
            try AlertStore.save(code: code,
                                drafts: [draft(.upAmount, 1.00, .daily),
                                         draft(.upPct, 5.00, .daily)],
                                window: .anytime, at: "2026-09-23 09:00:00")
        }
        let both = subject(code, "亚玛顿", price: 21.50, amt: 1.05, pct: 5.13)
        let bothOut = AlertEval.evaluate([both], at: clock(day))
        eq(bothOut.count, 2, "涨额与涨幅各响一条（同源但不同族别，不许互相顶掉）")
        eq(Set(bothOut.map(\.kind)), Set([AlertKind.upAmount, AlertKind.upPct]), "两条 kind 不同")
        eq(Set(bothOut.map(\.identifier)).count, 2, "两条 identifier 不同（否则通知会被替换掉一条）")
        eq(Set(bothOut.map(\.dedupKey)).count, 2, "两条 dedupKey 不同（否则会话内去重会顶掉一条）")

        // 判据读的是 `changeAmount` 而**不是价格**：价格 21.50 远高于阈值 1.00，
        //   但涨跌额为 0 时不该触发 —— 若哪天有人把判据写成 `price >= threshold`，只有这条会红
        let onlyPrice = subject(code, "亚玛顿", price: 21.50, amt: 0, pct: 0)
        eq(AlertEval.evaluate([onlyPrice], at: clock(day)).count, 0,
           "⚠ 涨跌额为 0 而价格远高于阈值 → 不许触发（证明判据读的是涨跌额）")
    }

    static func tableColumns(_ table: String) -> [String] {
        let rows = must("PRAGMA table_info(\(table))") {
            try SQLiteWriter.shared.write { tx in
                try tx.query("PRAGMA table_info(\(table))", [])
            }
        }
        return (rows ?? []).compactMap { $0["name"] as? String }
    }

    static func tableIndexes(_ table: String) -> [String] {
        let rows = must("PRAGMA index_list(\(table))") {
            try SQLiteWriter.shared.write { tx in
                try tx.query("PRAGMA index_list(\(table))", [])
            }
        }
        return (rows ?? []).compactMap { $0["name"] as? String }
    }

    /// 夹具复位 / 造脏行用的裸 SQL（**只在本驱动里**用；App 侧一律走 `AlertStore`）
    static func raw(_ sql: String, _ params: [Any?] = []) {
        must("执行裸 SQL：\(sql.prefix(48))…") {
            try SQLiteWriter.shared.write { tx in try tx.execute(sql, params) }
        }
    }

    static func wipe() {
        raw("DELETE FROM watch_alerts")
        raw("DELETE FROM watch_alert_settings")
    }

    // MARK: - 夹具

    static func draft(_ kind: AlertKind, _ t: Double,
                      _ r: AlertRepeat = .daily) -> AlertDraft {
        AlertDraft(kind: kind, threshold: t, repeatMode: r)
    }

    static func clock(_ day: String, _ minute: Int = 600, trading: Bool = true) -> AlertClock {
        AlertClock(day: day, minuteOfDay: minute, isTradingDay: trading,
                   stamp: "\(day) " + String(format: "%02d:%02d:00", minute / 60, minute % 60))
    }

    /// 构造 subject 时**从库里读规则**（与 `AlertMonitor` 同路径），
    /// 而不是把规则写在夹具里 —— 否则"落库 → 读回 → 评估"这条链断了也看不出来。
    ///
    /// `amt`（当日涨跌额，元）默认 `0`。
    /// **凡涉及 `upAmount` / `downAmount` 的阶段必须显式传** —— 默认 0 会让
    ///   "不该触发"这类反向断言因为输入进不了判据而**假绿**。
    static func subject(_ code: String, _ name: String,
                        price: Double, amt: Double = 0, pct: Double) -> AlertSubject {
        AlertSubject(code: code, name: name, price: price,
                     changeAmount: amt, changePercent: pct,
                     rules: AlertStore.rules(code: code),
                     window: AlertStore.window(code: code))
    }
}
