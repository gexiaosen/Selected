import Testing
import Foundation
import SQLite3
@testable import SelectedCore

/// `IndicatorScreener` 规则表契约测试
///
/// 只含**不碰库**的契约用例；筛选的**执行**测试在
/// `IndicatorSnapshotStoreTests`（库级用例必须收进**同一个** `.serialized`
/// 套件 —— 两个套件并发 `setenv` + 共享写连接单例会互踩，
/// 产生 "database is locked / no such table"）。
struct IndicatorScreenerTests {

    // MARK: - 规则表契约（不碰库）

    @Test("注册表 22 指标 ↔ 规则表一一对应（漏配/多配都红）")
    func rulesCoverRegistry() {
        let ids = IndicatorRegistry.all.map(\.id)
        let ruleIds = IndicatorScreener.rules.map(\.indicatorId)
        #expect(Set(ruleIds).count == ruleIds.count, "规则表内 indicatorId 重复")
        let missing = ids.filter { !ruleIds.contains($0) }
        let extra = ruleIds.filter { !ids.contains($0) }
        #expect(missing.isEmpty, "指标没有筛选规则：\(missing)")
        #expect(extra.isEmpty, "规则指向不存在的指标：\(extra)")
    }

    @Test("规则的 SQL 片段只引用白名单列（t./p. 前缀逐一反查）")
    func ruleSQLReferencesOnlyWhitelistedColumns() throws {
        let allowed = Set(IndicatorSnapshotStore.columns)
        let re = try NSRegularExpression(pattern: #"\b([tp])\.([a-z0-9_]+)"#)
        for r in IndicatorScreener.rules {
            for sql in [r.whereSQL, r.valueSQL] {
                let range = NSRange(sql.startIndex..., in: sql)
                for m in re.matches(in: sql, range: range) {
                    guard let colRange = Range(m.range(at: 2), in: sql) else { continue }
                    let col = String(sql[colRange])
                    #expect(allowed.contains(col),
                            "\(r.indicatorId)：SQL 引用非白名单列 \(col)")
                    // p. 前缀只允许出现在需要前一日的规则里
                    if sql.contains("p.") {
                        #expect(r.needsPreviousDay, "\(r.indicatorId)：用了 p. 却没声明需要前一日")
                    }
                }
            }
            #expect(!r.title.isEmpty && !r.valueLabel.isEmpty)
        }
    }

    // MARK: - 阈值参数化契约

    @Test("thresholdKey ⟺ whereSQL 恰含一个 token；键在 B 域 spec 存在且默认值一致")
    func thresholdKeysMatchSpec() {
        let token = IndicatorScreener.thresholdToken
        for r in IndicatorScreener.rules {
            let count = r.whereSQL.components(separatedBy: token).count - 1
            if let key = r.thresholdKey {
                #expect(count == 1, "\(r.indicatorId)：带 thresholdKey 但 token 数=\(count)")
                #expect(r.title.contains(token), "\(r.indicatorId)：标题未参数化（应含 token）")
                guard let entry = IndicatorParamSpec.entry(key: key) else {
                    Issue.record("\(r.indicatorId)：thresholdKey \(key) 不在 IndicatorParamSpec")
                    continue
                }
                #expect(entry.defaultValue == r.defaultThreshold,
                        "\(r.indicatorId)：规则默认 \(r.defaultThreshold) ≠ spec 默认 \(entry.defaultValue)")
            } else {
                #expect(count == 0, "\(r.indicatorId)：无 thresholdKey 却含 token")
            }
        }
    }

    @Test("默认阈值渲染的标题逐字复现参数化前的旧文案")
    func defaultTitlesUnchanged() {
        let empty: [String: Double] = [:]   // 缺省回落路径
        #expect(IndicatorScreener.rule(for: "rsiWilder")?.title(thresholds: empty)
                == "RSI 超卖（<30，最低在前）")
        #expect(IndicatorScreener.rule(for: "stochasticRsi")?.title(thresholds: empty)
                == "StochRSI 超卖（<20，最低在前）")
        #expect(IndicatorScreener.rule(for: "cmf")?.title(thresholds: empty)
                == "蔡金资金流入（CMF>0.1）")
        #expect(IndicatorScreener.rule(for: "moneyFlowMultiplier")?.title(thresholds: empty)
                == "收盘贴近日高（MFM>0.5）")
        // 覆盖值路径
        #expect(IndicatorScreener.rule(for: "rsiWilder")?
                .title(thresholds: ["screen.rsi_oversold": 25]) == "RSI 超卖（<25，最低在前）")
        // 无阈值规则原样返回
        #expect(IndicatorScreener.rule(for: "macd")?.title(thresholds: empty) == "MACD 金叉（线昨弱今强）")
    }

    @Test("defaultThresholds 表 = 4 个 screen.* 键（与补键迁移同源）")
    func defaultThresholdsTable() {
        let d = IndicatorScreener.defaultThresholds
        #expect(Set(d.keys) == ["screen.rsi_oversold", "screen.stochrsi_oversold",
                                "screen.cmf_inflow", "screen.mfm_strong"])
        #expect(d["screen.rsi_oversold"] == 30 && d["screen.cmf_inflow"] == 0.1)
    }
}
