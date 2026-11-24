import Testing
@testable import SelectedCore

/// `IndicatorSnapshotJob` 纯函数面测试
///
/// 分工：闸门/合成 bar/末值键集都是纯函数，不需要网络与库；
/// 落库与查询由 `IndicatorSnapshotStoreTests` 覆盖。
struct IndicatorSnapshotJobTests {

    // MARK: - 末值键集 ↔ 白名单双向一致（防"算得出列名对不上"）

    @Test("snapshotValues 的键集与 Store 白名单**完全一致**")
    func valueKeysMatchColumns() {
        // 250 根合成 K 线：足够让全部指标出数（键集完整性与值无关）
        let bars = (0..<250).map { i -> HistoryBar in
            let p = 10 + Double(i % 37) * 0.1
            return HistoryBar(code: "600000", day: String(format: "2025-%02d-%02d", i / 28 % 12 + 1, i % 28 + 1),
                              open: p, close: p + 0.05, high: p + 0.2, low: p - 0.15,
                              volume: 12_000, amount: 1e7, amplitude: 3, changePct: 0.5, turnover: 1.2)
        }
        let v = IndicatorSnapshotJob.snapshotValues(bars: bars)
        let cols = IndicatorSnapshotStore.columns
        let missing = cols.filter { v[$0] == nil }
        let extra = v.keys.filter { !cols.contains($0) }
        #expect(missing.isEmpty, "白名单列没有对应末值：\(missing.sorted())")
        #expect(extra.isEmpty, "算出了非白名单键：\(extra.sorted())")
        // 250 根下全部指标都应出数（值非 nil）
        let stillNil = cols.filter { v[$0].flatMap { $0 } == nil }
        #expect(stillNil.isEmpty, "250 根预热后仍无值：\(stillNil.sorted())")
    }

    @Test("预热不足 → 对应列为 nil（不是 0）")
    func warmupGapsAreNil() {
        let bars = (0..<10).map { i in
            HistoryBar(code: "600000", day: "2025-01-0\(i + 1)", open: 10, close: 10 + Double(i),
                       high: 11 + Double(i), low: 9, volume: 1000, amount: 1e6,
                       amplitude: 5, changePct: 1, turnover: 1)
        }
        let v = IndicatorSnapshotJob.snapshotValues(bars: bars)
        // 双层 Optional：`v[k] == nil` 判的是"键缺失"；值 nil 要 `flatMap`
        #expect(v["macd_signal"].flatMap { $0 } == nil)
        #expect(v["ppo_line"].flatMap { $0 } == nil)
        // MFM 首根即有值
        #expect(v["money_flow_multiplier_value"].flatMap { $0 } != nil)
    }

    // MARK: - 今日 bar 合成（单位与有效性）

    @Test("合成 bar 的 volume = quote.volume（**手**，不 ×100）")
    func todayBarKeepsLotsUnit() {
        var q = EngineQuote()
        q.code = "600000"; q.open = 10; q.high = 10.5; q.low = 9.8
        q.price = 10.2; q.preClose = 10; q.volume = 8_888
        let bar = IndicatorSnapshotJob.makeTodayBar(quote: q, code: "600000", day: "2026-10-14")
        #expect(bar?.volume == 8_888, "volume 必须保持手单位，实得 \(bar?.volume ?? -1)")
        #expect(bar?.close == 10.2)
    }

    @Test("脏报价 → nil（停牌/零价/高低矛盾整行不写）")
    func dirtyQuotesRejected() {
        var q = EngineQuote()
        q.open = 10; q.high = 10.5; q.low = 9.8; q.price = 0   // 停牌价 0
        #expect(IndicatorSnapshotJob.makeTodayBar(quote: q, code: "600000", day: "2026-10-14") == nil)
        q.price = 10.2; q.high = 9.9                            // 高 < 收，自相矛盾
        #expect(IndicatorSnapshotJob.makeTodayBar(quote: q, code: "600000", day: "2026-10-14") == nil)
        q.high = 10.5; q.low = 11                                // 低 > 开
        #expect(IndicatorSnapshotJob.makeTodayBar(quote: q, code: "600000", day: "2026-10-14") == nil)
    }

    // MARK: - 防双计 / 缺口判定

    @Test("缓存末根已含今日 → 不追加；早于今日 → 追加")
    func appendGuard() {
        #expect(!IndicatorSnapshotJob.shouldAppendToday(lastCachedDay: "2026-10-14", today: "2026-10-14"))
        #expect(IndicatorSnapshotJob.shouldAppendToday(lastCachedDay: "2026-10-13", today: "2026-10-14"))
        // 回放库意外含"未来日"（脏数据）→ 也不追加（宁缺毋滥）
        #expect(!IndicatorSnapshotJob.shouldAppendToday(lastCachedDay: "2026-10-15", today: "2026-10-14"))
    }

    @Test("缺口 = 日历里开区间 (lastCached, today) 的天数")
    func gapCounting() {
        let cal = TradingCalendar(days: ["2026-10-08", "2026-10-09", "2026-10-12",
                                         "2026-10-13", "2026-10-14"])
        // 缓存到 10-13（昨日）→ 缺口 0
        #expect(IndicatorSnapshotJob.gapDays(calendar: cal, lastCached: "2026-10-13",
                                             today: "2026-10-14") == 0)
        // 缓存到 10-12 → 缺 10-13 一天
        #expect(IndicatorSnapshotJob.gapDays(calendar: cal, lastCached: "2026-10-12",
                                             today: "2026-10-14") == 1)
        // 缓存到 10-09 → 缺 10-12、10-13 两天 → 闸门应红
        #expect(IndicatorSnapshotJob.gapDays(calendar: cal, lastCached: "2026-10-09",
                                             today: "2026-10-14") == 2)
        // 指数日历为空（没回放过指数）→ 0（交给"库空"闸门兜底，不误报）
        #expect(IndicatorSnapshotJob.gapDays(calendar: TradingCalendar(days: []),
                                             lastCached: "2026-01-01", today: "2026-10-14") == 0)
    }

    // MARK: - 失败文案（纪律：指向用户动作，不写"稍后重试"）

    @Test("历史库类失败文案指向『设置 › 历史回放』，不含『稍后重试』")
    func failureWording() {
        for msg in [IndicatorSnapshotJob.Failure.historyEmpty.errorDescription ?? "",
                    IndicatorSnapshotJob.Failure.historyStale(latest: "2026-10-01", today: "2026-10-14",
                                                              gapDays: 3).errorDescription ?? ""] {
            #expect(msg.contains("历史回放"), "文案应指向回放动作：\(msg)")
            #expect(!msg.contains("稍后重试"), "需要用户动作的失败不许写『稍后重试』：\(msg)")
        }
    }
}
