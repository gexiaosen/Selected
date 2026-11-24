import Testing
@testable import SelectedCore

/// `VolumeIndicators` 的黄金夹具测试
@Suite(.serialized)
struct VolumeIndicatorsGoldenTests {

    @Test("MFM 与 mfm.csv 逐点一致（收盘版口径：C==H 首行给 1）")
    func mfmAgainstFixture() throws {
        let csv = try IndicatorGoldenSupport.load("volume", "mfm")
        let bars = IndicatorGoldenSupport.bars(csv)
        let got = VolumeIndicators.moneyFlowMultiplier(bars)
        IndicatorGoldenSupport.assertMatches(got: got, want: csv.column("Mfm"),
                                             label: "MFM vs mfm.csv")
    }

    @Test("MFV 与 mfv.csv 逐点一致")
    func mfvAgainstFixture() throws {
        let csv = try IndicatorGoldenSupport.load("volume", "mfv")
        let bars = IndicatorGoldenSupport.bars(csv)
        let got = VolumeIndicators.moneyFlowVolume(bars)
        IndicatorGoldenSupport.assertMatches(got: got, want: csv.column("Mfv"),
                                             label: "MFV vs mfv.csv")
    }

    @Test("CMF(20) 与 cmf.csv 逐点一致")
    func cmfAgainstFixture() throws {
        let csv = try IndicatorGoldenSupport.load("volume", "cmf")
        let bars = IndicatorGoldenSupport.bars(csv)
        let got = VolumeIndicators.cmf(bars)
        IndicatorGoldenSupport.assertMatches(gotOpt: got, want: csv.column("Cmf"),
                                             label: "CMF(20) vs cmf.csv")
    }

    @Test("VWAP(14) 与 vwap.csv 逐点一致（滚动窗口、TP=收盘口径）")
    func vwapAgainstFixture() throws {
        let csv = try IndicatorGoldenSupport.load("volume", "vwap")
        let bars = IndicatorGoldenSupport.bars(csv)
        let got = VolumeIndicators.vwap(bars)
        IndicatorGoldenSupport.assertMatches(gotOpt: got, want: csv.column("Vwap"),
                                             label: "VWAP(14) vs vwap.csv")
    }

    @Test("EMV(14) 与 emv.csv 逐点一致")
    func emvAgainstFixture() throws {
        let csv = try IndicatorGoldenSupport.load("volume", "emv")
        let bars = IndicatorGoldenSupport.bars(csv)
        let got = VolumeIndicators.emv(bars)
        IndicatorGoldenSupport.assertMatches(gotOpt: got, want: csv.column("Emv"),
                                             label: "EMV(14) vs emv.csv")
    }

    @Test("FI(13) 与 fi.csv 逐点一致（EMA 平滑口径）")
    func fiAgainstFixture() throws {
        let csv = try IndicatorGoldenSupport.load("volume", "fi")
        let bars = IndicatorGoldenSupport.bars(csv)
        let got = VolumeIndicators.forceIndex(bars)
        IndicatorGoldenSupport.assertMatches(gotOpt: got, want: csv.column("Fi"),
                                             label: "FI(13) vs fi.csv")
    }

    @Test("一字板 MFM=0；整窗停牌 ΣV=0 → CMF/VWAP 该位 nil")
    func edgeSemantics() {
        let flat = IndicatorGoldenSupport.Bar(open: 10, high: 10, low: 10, close: 10, volume: 500)
        #expect(VolumeIndicators.moneyFlowMultiplier([flat])[0] == 0)
        // 整窗（含首根）都无量：ΣV=0 → "算不出"，不是"资金流 0"
        let halted = IndicatorGoldenSupport.Bar(open: 10, high: 11, low: 9, close: 10, volume: 0)
        let bars = Array(repeating: halted, count: 25)
        #expect(VolumeIndicators.cmf(bars).allSatisfy { $0 == nil })
        #expect(VolumeIndicators.vwap(bars).allSatisfy { $0 == nil })
    }

    @Test("样本不足 → 全 nil")
    func insufficient() {
        let bars = (1...5).map { IndicatorGoldenSupport.Bar(open: 0, high: Double($0 + 1),
                                                            low: Double($0), close: Double($0),
                                                            volume: Double($0)) }
        #expect(VolumeIndicators.cmf(bars).allSatisfy { $0 == nil })
        #expect(VolumeIndicators.vwap(bars).allSatisfy { $0 == nil })
        #expect(VolumeIndicators.emv(bars).allSatisfy { $0 == nil })
        #expect(VolumeIndicators.forceIndex(bars).allSatisfy { $0 == nil })
    }
}
