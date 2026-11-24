import Testing
import Foundation
@testable import SelectedCore

/// `IndicatorPrimitives` 的黄金夹具 + 语义测试
///
/// 分工（口径见 `IndicatorGoldenSupport` 头注）：
///   · 黄金 CSV 管**数值与种子口径** —— EMA 种子=首值、RMA 种子=SMA、σ=总体口径，
///     全部在这里钉死；换口径必红。
///   · 手算小样例管**语义** —— 空输入、样本不足→nil、长度对齐、period=1。
@Suite(.serialized)
struct IndicatorPrimitivesGoldenTests {

    // MARK: - EMA（种子 = 前 n 项 SMA，夹具口径）

    @Test("emaSeries 与 envelope_ema.csv 的 Middle 列逐点一致（种子=SMA(n) 夹具口径）")
    func emaAgainstEnvelope() throws {
        let csv = try IndicatorGoldenSupport.load("trend", "envelope_ema")
        let closes = csv.column("Close")
        let got = IndicatorPrimitives.emaSeries(closes, 20)
        IndicatorGoldenSupport.assertMatches(gotOpt: got, want: csv.column("Middle"),
                                             label: "EMA(20) vs envelope_ema.Middle")
    }

    // MARK: - RMA（Wilder：种子 = 前 n 项 SMA）

    @Test("rmaSeries 与 rma.csv 逐点一致（夹具用 period=15）")
    func rmaAgainstFixture() throws {
        let csv = try IndicatorGoldenSupport.load("trend", "rma")
        let got = IndicatorPrimitives.rmaSeries(csv.column("Close"), 15)
        IndicatorGoldenSupport.assertMatches(gotOpt: got, want: csv.column("Rma"),
                                             label: "RMA(15) vs rma.csv")
    }

    // MARK: - SMA（借布林中线验证：Middle = SMA(Close,20)）

    @Test("smaSeries 与 bollinger_bands.csv 的 Middle 列逐点一致")
    func smaAgainstBollingerMiddle() throws {
        let csv = try IndicatorGoldenSupport.load("volatility", "bollinger_bands")
        let got = IndicatorPrimitives.smaSeries(csv.column("Close"), 20)
        IndicatorGoldenSupport.assertMatches(gotOpt: got, want: csv.column("Middle"),
                                             label: "SMA(20) vs bollinger_bands.Middle")
    }

    // MARK: - 总体标准差（借布林上轨反推：σ = (Upper − Middle) / 2）

    @Test("stddevSeries 是总体口径：与 bollinger_bands 反推的 σ 一致")
    func stddevAgainstBollinger() throws {
        let csv = try IndicatorGoldenSupport.load("volatility", "bollinger_bands")
        let sigma = IndicatorPrimitives.stddevSeries(csv.column("Close"), 20)
        let derived = zip(csv.column("Upper"), csv.column("Middle")).map { ($0 - $1) / 2 }
        IndicatorGoldenSupport.assertMatches(gotOpt: sigma, want: derived,
                                             label: "stddev(20) 总体口径 vs bollinger 反推")
    }

    // MARK: - TR（与 TechnicalIndicators.trueRanges 同口径，交叉防漂移）

    @Test("trueRanges 两个实现逐点一致（新原语 vs TechnicalIndicators）")
    func trueRangesCrossCheck() throws {
        let csv = try IndicatorGoldenSupport.load("volatility", "atr")
        let bars = IndicatorGoldenSupport.bars(csv)
        let a = IndicatorPrimitives.trueRanges(bars)
        let b = TechnicalIndicators.trueRanges(bars)
        #expect(a.count == b.count, "长度不齐")
        for (x, y) in zip(a, b) {
            #expect(abs(x - y) < 1e-12, "TR 两份实现漂移：\(x) vs \(y)")
        }
    }

    // MARK: - 语义（手算小样例）

    @Test("样本不足 → 全 nil，不返回 0")
    func insufficientSamplesAreNil() {
        #expect(IndicatorPrimitives.smaSeries([1, 2], 3).allSatisfy { $0 == nil })
        #expect(IndicatorPrimitives.wmaSeries([1, 2], 3).allSatisfy { $0 == nil })
        #expect(IndicatorPrimitives.rmaSeries([1, 2], 3).allSatisfy { $0 == nil })
        #expect(IndicatorPrimitives.rollingMax([1, 2], 3).allSatisfy { $0 == nil })
        #expect(IndicatorPrimitives.stddevSeries([1, 2], 3).allSatisfy { $0 == nil })
        #expect(IndicatorPrimitives.rocSeries([1, 2], 2).allSatisfy { $0 == nil })
    }

    @Test("period=1 的退化口径")
    func periodOne() {
        #expect(IndicatorPrimitives.smaSeries([3, 4], 1) == [3, 4])
        #expect(IndicatorPrimitives.wmaSeries([3, 4], 1) == [3, 4])
        #expect(IndicatorPrimitives.rmaSeries([3, 4], 1) == [3, 4])
        #expect(IndicatorPrimitives.stddevSeries([3, 4], 1) == [0, 0])
        #expect(IndicatorPrimitives.rocSeries([3, 6], 1) == [nil, 100])
    }

    @Test("手算：SMA/WMA/RMA 前三步")
    func handComputed() {
        let v: [Double] = [1.0, 2.0, 3.0, 4.0]
        #expect(IndicatorPrimitives.smaSeries(v, 2) == [nil, 1.5, 2.5, 3.5])
        // WMA(2)：(1·x_{i-1} + 2·x_i)/3
        let wmaWant: [Double?] = [nil, (1.0 + 4) / 3, (2.0 + 6) / 3, (3.0 + 8) / 3]
        #expect(IndicatorPrimitives.wmaSeries(v, 2) == wmaWant)
        // RMA(2)：种子 (1+2)/2=1.5 → (1.5+3)/2=2.25 → (2.25+4)/2=3.125
        #expect(IndicatorPrimitives.rmaSeries(v, 2) == [nil, 1.5, 2.25, 3.125])
        // EMA(2) 种子=SMA：(1+2)/2=1.5 → (2/3)·3+(1/3)·1.5=2.5 → (2/3)·4+(1/3)·2.5=3.5
        let emaWant: [Double?] = [nil, 1.5, 2.5, 3.5]
        #expect(IndicatorPrimitives.emaSeries(v, 2) == emaWant)
    }

    @Test("ROC 分母为 0 → 该位 nil（不制造 inf）")
    func rocZeroDenominator() {
        #expect(IndicatorPrimitives.rocSeries([0, 5], 1) == [nil, nil])
    }

    @Test("空输入 → 空序列")
    func emptyInput() {
        #expect(IndicatorPrimitives.smaSeries([], 5).isEmpty)
        #expect(IndicatorPrimitives.emaSeries([], 5).isEmpty)
        #expect(IndicatorPrimitives.trueRanges([] as [IndicatorGoldenSupport.Bar]).isEmpty)
    }

    @Test("add/subtract 长度不齐按交集对齐并保留尾部 nil 补齐")
    func arithmeticLengthAlignment() {
        #expect(IndicatorPrimitives.add([1, 2, 3], [10, 20]) == [11, 22, nil])
        #expect(IndicatorPrimitives.subtract([10, 20], [1, 2, 3]) == [9, 18, nil])
        #expect(IndicatorPrimitives.add([1, nil], [10, 20]) == [11, nil])
    }
}
