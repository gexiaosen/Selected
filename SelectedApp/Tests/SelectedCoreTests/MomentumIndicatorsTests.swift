import Testing
@testable import SelectedCore

/// `MomentumIndicators` 的黄金夹具测试 + RSI 口径交叉核对
@Suite(.serialized)
struct MomentumIndicatorsGoldenTests {

    @Test("rsiSeries(Wilder) 与 rsi.csv 逐点一致")
    func rsiAgainstFixture() throws {
        let csv = try IndicatorGoldenSupport.load("momentum", "rsi")
        let bars = IndicatorGoldenSupport.bars(csv)
        let got = MomentumIndicators.rsiSeries(bars, period: 14)
        IndicatorGoldenSupport.assertMatches(gotOpt: got, want: csv.column("Rsi"),
                                             label: "RSI(14) Wilder vs rsi.csv")
    }

    @Test("口径分裂锁死：Oscillators.rsi 是简单均值口径，与 Wilder 夹具**不同值**")
    func oscillatorsRsiCaliberDocumented() throws {
        let csv = try IndicatorGoldenSupport.load("momentum", "rsi")
        let bars = IndicatorGoldenSupport.bars(csv)
        let osc = Oscillators.rsi(bars, .init())
        let fixtureLast = csv.column("Rsi").last ?? 0
        // 简单均值口径 ≠ 夹具（Wilder）：末值差超过容差 → 证明两份实现口径确实分裂，
        // 谁改错了谁红（若有人把 Oscillators.rsi 悄悄换成 Wilder，本断言会失败）。
        #expect(abs(osc! - fixtureLast) > 0.005 + 1e-9,
                "Oscillators.rsi 与 Wilder 夹具末值相同 —— 简单均值口径疑似被改动")
    }

    @Test("Stochastic(14,3) 与 stochastic_oscillator.csv 的 K/D 列逐点一致")
    func stochasticAgainstFixture() throws {
        let csv = try IndicatorGoldenSupport.load("momentum", "stochastic_oscillator")
        let bars = IndicatorGoldenSupport.bars(csv)
        let got = MomentumIndicators.stochastic(bars)
        IndicatorGoldenSupport.assertMatches(gotOpt: got.k, want: csv.column("K"),
                                             label: "Stoch %K vs fixture")
        IndicatorGoldenSupport.assertMatches(gotOpt: got.d, want: csv.column("D"),
                                             label: "Stoch %D vs fixture")
    }

    @Test("StochRSI(14) 与 stochastic_rsi.csv 逐点一致（夹具 0–1 口径 ×100 后比对）")
    func stochasticRsiAgainstFixture() throws {
        let csv = try IndicatorGoldenSupport.load("momentum", "stochastic_rsi")
        let bars = IndicatorGoldenSupport.bars(csv)
        let got = MomentumIndicators.stochasticRsi(bars)
        // 夹具输出是 0–1 比例（want[27]=0.89），本项目对外统一 0–100（UI/筛选阈值口径）。
        // ×100 后夹具的 2 位小数舍入误差放大 100 倍 → 容差 0.5+ε。
        let want = csv.column("StochasticRsi").map { $0 * 100 }
        IndicatorGoldenSupport.assertMatches(gotOpt: got, want: want,
                                             label: "StochRSI(14) vs fixture×100",
                                             tol: 0.5 + 1e-9)
    }

    @Test("PPO(12,26,9) 与 ppo.csv 的 Ppo/Signal 列逐点一致，柱=线−信号")
    func ppoAgainstFixture() throws {
        let csv = try IndicatorGoldenSupport.load("momentum", "ppo")
        let bars = IndicatorGoldenSupport.bars(csv)
        let got = MomentumIndicators.ppo(bars)
        IndicatorGoldenSupport.assertMatches(gotOpt: got.line, want: csv.column("Ppo"),
                                             label: "PPO 线 vs fixture")
        IndicatorGoldenSupport.assertMatches(gotOpt: got.signal, want: csv.column("Signal"),
                                             label: "PPO 信号线 vs fixture")
        for (h, l, s) in zip3(got.histogram, got.line, got.signal) {
            if let l, let s {
                #expect(h != nil && abs(h! - (l - s)) < 1e-12, "histogram ≠ line − signal")
            } else {
                #expect(h == nil)
            }
        }
    }

    @Test("AO(5,34) 与 awesome_oscillator.csv 逐点一致")
    func awesomeOscillatorAgainstFixture() throws {
        let csv = try IndicatorGoldenSupport.load("momentum", "awesome_oscillator")
        let bars = IndicatorGoldenSupport.bars(csv)
        let got = MomentumIndicators.awesomeOscillator(bars)
        IndicatorGoldenSupport.assertMatches(gotOpt: got, want: csv.column("Ao"),
                                             label: "AO(5,34) vs fixture")
    }

    @Test("UO(7,14,28) 与 ultimate_oscillator.csv 逐点一致")
    func ultimateOscillatorAgainstFixture() throws {
        let csv = try IndicatorGoldenSupport.load("momentum", "ultimate_oscillator")
        let bars = IndicatorGoldenSupport.bars(csv)
        let got = MomentumIndicators.ultimateOscillator(bars)
        IndicatorGoldenSupport.assertMatches(gotOpt: got, want: csv.column("UO"),
                                             label: "UO(7,14,28) vs fixture")
    }

    @Test("一字板：HH==LL 时 Stochastic 取中性 50（与 KDJ RSV 同哲学）")
    func flatWindowIsNeutral() {
        let bars = (1...20).map { _ in
            IndicatorGoldenSupport.Bar(open: 10, high: 10, low: 10, close: 10, volume: 1)
        }
        let got = MomentumIndicators.stochastic(bars, period: 14, smooth: 1)
        for v in got.k where v != nil {
            #expect(abs(v! - 50) < 1e-12, "一字板 rawK 必须中性 50，实得 \(v!)")
        }
    }

    @Test("样本不足 → 全 nil")
    func insufficient() {
        let bars = (1...5).map { IndicatorGoldenSupport.Bar(open: 0, high: Double($0),
                                                            low: Double($0), close: Double($0),
                                                            volume: 1) }
        #expect(MomentumIndicators.rsiSeries(bars, period: 14).allSatisfy { $0 == nil })
        #expect(MomentumIndicators.stochastic(bars).k.allSatisfy { $0 == nil })
        #expect(MomentumIndicators.stochasticRsi(bars).allSatisfy { $0 == nil })
        #expect(MomentumIndicators.ultimateOscillator(bars).allSatisfy { $0 == nil })
    }
}

private func zip3<A, B, C>(_ a: [A], _ b: [B], _ c: [C]) -> [(A, B, C)] {
    zip(zip(a, b), c).map { ($0.0, $0.1, $1) }
}
