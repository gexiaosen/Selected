import Testing
@testable import SelectedCore

/// `VolatilityIndicators` 的黄金夹具测试 + ATR 口径交叉核对
@Suite(.serialized)
struct VolatilityIndicatorsGoldenTests {

    @Test("Bollinger(20,2) 与 bollinger_bands.csv 的上/中/下轨逐点一致")
    func bollingerAgainstFixture() throws {
        let csv = try IndicatorGoldenSupport.load("volatility", "bollinger_bands")
        let bars = IndicatorGoldenSupport.bars(csv)
        let got = VolatilityIndicators.bollingerBands(bars)
        IndicatorGoldenSupport.assertMatches(gotOpt: got.upper, want: csv.column("Upper"),
                                             label: "BBANDS 上轨")
        IndicatorGoldenSupport.assertMatches(gotOpt: got.middle, want: csv.column("Middle"),
                                             label: "BBANDS 中线")
        IndicatorGoldenSupport.assertMatches(gotOpt: got.lower, want: csv.column("Lower"),
                                             label: "BBANDS 下轨")
    }

    @Test("带宽(20) 与 bollinger_band_width.csv 逐点一致（夹具 0–1 比例 ×100 后比对）")
    func bandwidthAgainstFixture() throws {
        let csv = try IndicatorGoldenSupport.load("volatility", "bollinger_band_width")
        let bars = IndicatorGoldenSupport.bars(csv)
        let got = VolatilityIndicators.bollingerBands(bars).bandwidth
        // 夹具口径 = (上−下)/中（比例，want[19]=0.07）；本项目对外统一百分数 ×100。
        let want = csv.column("Width").map { $0 * 100 }
        IndicatorGoldenSupport.assertMatches(gotOpt: got, want: want,
                                             label: "BBW(20) vs fixture×100",
                                             tol: 0.5 + 1e-9)
    }

    @Test("%B(20) 与 percent_b.csv 逐点一致")
    func percentBAgainstFixture() throws {
        let csv = try IndicatorGoldenSupport.load("volatility", "percent_b")
        let bars = IndicatorGoldenSupport.bars(csv)
        let got = VolatilityIndicators.bollingerBands(bars).percentB
        // %B 落在 [0,1]，夹具 2 位小数舍入 → 默认容差 0.005 已含舍入余量
        IndicatorGoldenSupport.assertMatches(gotOpt: got, want: csv.column("PercentB"),
                                             label: "%B(20)")
    }

    @Test("Donchian(20) 与 donchian_channel.csv 的上/中/下轨逐点一致")
    func donchianAgainstFixture() throws {
        let csv = try IndicatorGoldenSupport.load("volatility", "donchian_channel")
        let bars = IndicatorGoldenSupport.bars(csv)
        let got = VolatilityIndicators.donchianChannel(bars)
        IndicatorGoldenSupport.assertMatches(gotOpt: got.upper, want: csv.column("Upper"),
                                             label: "DC 上轨")
        IndicatorGoldenSupport.assertMatches(gotOpt: got.middle, want: csv.column("Middle"),
                                             label: "DC 中线")
        IndicatorGoldenSupport.assertMatches(gotOpt: got.lower, want: csv.column("Lower"),
                                             label: "DC 下轨")
    }

    @Test("Keltner(20) 与 keltner_channel.csv 逐点一致（中=EMA、轨=±2×ATR_SMA）")
    func keltnerAgainstFixture() throws {
        let csv = try IndicatorGoldenSupport.load("volatility", "keltner_channel")
        let bars = IndicatorGoldenSupport.bars(csv)
        let got = VolatilityIndicators.keltnerChannel(bars)
        IndicatorGoldenSupport.assertMatches(gotOpt: got.middle, want: csv.column("Middle"),
                                             label: "KC 中线")
        IndicatorGoldenSupport.assertMatches(gotOpt: got.upper, want: csv.column("Upper"),
                                             label: "KC 上轨")
        IndicatorGoldenSupport.assertMatches(gotOpt: got.lower, want: csv.column("Lower"),
                                             label: "KC 下轨")
    }

    @Test("SuperTrend(HMA14, 2.5) 与 super_trend.csv 逐点一致")
    func superTrendAgainstFixture() throws {
        let csv = try IndicatorGoldenSupport.load("volatility", "super_trend")
        let bars = IndicatorGoldenSupport.bars(csv)
        let got = VolatilityIndicators.superTrend(bars)
        IndicatorGoldenSupport.assertMatches(gotOpt: got.line, want: csv.column("SuperTrend"),
                                             label: "SuperTrend 线")
    }

    @Test("UlcerIndex(14) 与 ulcer_index.csv 逐点一致")
    func ulcerAgainstFixture() throws {
        let csv = try IndicatorGoldenSupport.load("volatility", "ulcer_index")
        let bars = IndicatorGoldenSupport.bars(csv)
        let got = VolatilityIndicators.ulcerIndex(bars)
        IndicatorGoldenSupport.assertMatches(gotOpt: got, want: csv.column("UlcerIndex"),
                                             label: "UI(14)")
    }

    @Test("atrSmaSeries 与 atr.csv 逐点一致（SMA of TR 口径，夹具用 period=50）")
    func atrSmaAgainstFixture() throws {
        let csv = try IndicatorGoldenSupport.load("volatility", "atr")
        let bars = IndicatorGoldenSupport.bars(csv)
        // 夹具由 `NewAtrWithPeriod(50)` 生成（上游 atr_test 实测），不是默认 14。
        let got = VolatilityIndicators.atrSmaSeries(bars, period: 50)
        IndicatorGoldenSupport.assertMatches(gotOpt: got, want: csv.column("Atr"),
                                             label: "ATR_SMA(50) vs atr.csv")
    }
}

/// ATR 口径分裂的显式记录（防"顺手统一"）
@Suite(.serialized)
struct VolatilityIndicatorsCrossTests {

    @Test("TechnicalIndicators.atr(Wilder) 与夹具(SMA of TR)末值**不同** —— 两份口径并存")
    func atrCaliberSplitDocumented() throws {
        let csv = try IndicatorGoldenSupport.load("volatility", "atr")
        let bars = IndicatorGoldenSupport.bars(csv)
        let wilder = TechnicalIndicators.atr(bars, period: 14)
        let fixtureLast = csv.column("Atr").last ?? 0
        // 该数据段跳空/波动足够，两种平滑末值必然可分；若哪天有人把任一口径改掉
        // 使两者重合或让夹具口径漂移，本断言会红，逼作者回来写清理由。
        #expect(wilder != nil)
        #expect(abs(wilder! - fixtureLast) > 0.005 + 1e-9,
                "Wilder ATR 与 SMA ATR 末值相同 —— 疑似某一份口径被悄悄改动")
    }
}
