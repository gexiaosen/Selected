import Testing
import Foundation
import SQLite3
@testable import SelectedCore

/// `IndicatorParamSpec` / `IndicatorParamStore` 测试
///
/// 与 `IndicatorSnapshotStoreTests` 同套件纪律：**碰库用例集中一处 `.serialized`**，
/// 纯契约用例（spec 一致性）不碰库、可并行。
struct IndicatorParamSpecTests {

    @Test("spec 自校验：键唯一、区间合法、默认在区间内")
    func specValidates() {
        #expect(IndicatorParamSpec.validate().isEmpty)
    }

    @Test("screen.* 默认 == Rule.defaultThreshold（撤出 A 域后 B 域是唯一来源）")
    func screenDefaultsMatchRules() {
        for r in IndicatorScreener.rules {
            guard let key = r.thresholdKey else { continue }
            #expect(IndicatorParamSpec.entry(key: key)?.defaultValue == r.defaultThreshold,
                    "\(key)：spec 默认与规则默认漂移")
        }
    }

    @Test("spec 周期默认与注册表 defaultPeriods **逐位**一致（按参数名映射）")
    func periodDefaultsMatchRegistry() {
        // 注册表 defaultPeriods 是**位置**数组；这里钉死"位置 → spec 参数名"的对应，
        // 任何一边偷偷换顺序/改默认都会红。
        let order: [String: [String]] = [
            "ema": ["period"], "macd": ["fast", "slow", "signal"], "hma": ["period"],
            "kama": ["er", "fast", "slow"], "rsiWilder": ["period"],
            "stochastic": ["period", "smooth"], "stochasticRsi": ["period"],
            "ppo": ["fast", "slow", "signal"], "awesomeOscillator": ["short", "long"],
            "ultimateOscillator": ["short", "medium", "long"], "atrSma": ["period"],
            "bollingerBands": ["period"], "donchianChannel": ["period"],
            "keltnerChannel": ["period"], "superTrend": ["period"], "ulcerIndex": ["period"],
            "vwap": ["period"], "cmf": ["period"], "emv": ["period"], "forceIndex": ["period"],
        ]
        for m in IndicatorRegistry.all {
            guard let names = order[m.id] else {
                #expect(m.defaultPeriods.isEmpty, "\(m.id)：注册表有周期但测试映射表没登记")
                continue
            }
            #expect(names.count == m.defaultPeriods.count,
                    "\(m.id)：映射表参数数(\(names)) ≠ 注册表(\(m.defaultPeriods))")
            for (i, name) in names.enumerated() {
                let entry = IndicatorParamSpec.entry(key: "period.\(m.id).\(name)")
                #expect(entry?.defaultValue == Double(m.defaultPeriods[i]),
                        "\(m.id).\(name)：spec 默认(\(String(describing: entry?.defaultValue))) ≠ 注册表 \(m.defaultPeriods[i])")
            }
        }
    }

    @Test("osc.* 默认 == Oscillators.Config 出厂值（六指标关键线全查）")
    func oscDefaultsMatchConfig() {
        let c = Oscillators.Config()
        func d(_ k: String) -> Double { IndicatorParamSpec.entry(key: k)?.defaultValue ?? -1 }
        #expect(d("osc.kdj.obK") == c.kdjObK && d("osc.kdj.osK") == c.kdjOsK)
        #expect(d("osc.kdj.period") == Double(c.kdjPeriod))
        #expect(d("osc.rsi.ob") == c.rsiOb && d("osc.rsi.severeOs") == c.rsiSevereOs)
        #expect(d("osc.cci.ob") == c.cciOb && d("osc.cci.os") == c.cciOs)
        #expect(d("osc.cr.sell") == c.crSell && d("osc.cr.buy") == c.crBuy)
        #expect(d("osc.wr.ob") == c.wrOb && d("osc.wr.os") == c.wrOs)
        #expect(d("osc.vr.sellHigh") == c.vrSellHigh && d("osc.vr.buyLow") == c.vrBuyLow)
    }
}
