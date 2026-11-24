import Testing
@testable import SelectedCore

/// `TrendIndicators` 的黄金夹具测试
///
/// 比对口径见 `IndicatorGoldenSupport` 头注（2 位小数舍入 + 首个非 0 行起算）。
/// 种子口径（EMA=SMA(n)、KAMA=索引 erPeriod 的收盘价）由这些测试锁死。
@Suite(.serialized)
struct TrendIndicatorsGoldenTests {

    @Test("MACD(12,26,9) 与 macd.csv 的 Macd/Signal 列逐点一致")
    func macdAgainstFixture() throws {
        let csv = try IndicatorGoldenSupport.load("trend", "macd")
        let bars = IndicatorGoldenSupport.bars(csv)
        let got = TrendIndicators.macd(bars)
        IndicatorGoldenSupport.assertMatches(gotOpt: got.line, want: csv.column("Macd"),
                                             label: "MACD 线 vs macd.csv")
        IndicatorGoldenSupport.assertMatches(gotOpt: got.signal, want: csv.column("Signal"),
                                             label: "MACD 信号线 vs macd.csv")
        // 柱 = 线 − 信号（夹具无此列，自洽断言）
        for (h, l, s) in zip3(got.histogram, got.line, got.signal) {
            if let l, let s {
                #expect(h != nil && abs(h! - (l - s)) < 1e-12, "histogram ≠ line − signal")
            } else {
                #expect(h == nil, "线/信号未定义时柱必须 nil")
            }
        }
    }

    @Test("HMA(3) 与 hma.csv 逐点一致（夹具用 period=3，见上游 TestHma）")
    func hmaAgainstFixture() throws {
        let csv = try IndicatorGoldenSupport.load("trend", "hma")
        let bars = IndicatorGoldenSupport.bars(csv)
        let got = TrendIndicators.hma(bars, period: 3)
        IndicatorGoldenSupport.assertMatches(gotOpt: got, want: csv.column("Hma"),
                                             label: "HMA(3) vs hma.csv")
    }

    @Test("KAMA(10,2,30) 与 kama.csv 逐点一致（种子=索引 er−1 收盘价）")
    func kamaAgainstFixture() throws {
        let csv = try IndicatorGoldenSupport.load("trend", "kama")
        let bars = IndicatorGoldenSupport.bars(csv)
        let got = TrendIndicators.kama(bars)
        IndicatorGoldenSupport.assertMatches(gotOpt: got, want: csv.column("Kama"),
                                             label: "KAMA vs kama.csv")
    }

    @Test("lastEma 与 ema 序列末值一致；空输入 → nil")
    func scalarWrappers() throws {
        let csv = try IndicatorGoldenSupport.load("trend", "envelope_ema")
        let bars = IndicatorGoldenSupport.bars(csv)
        let series = TrendIndicators.ema(bars, period: 20)
        #expect(TrendIndicators.lastEma(bars, period: 20) == series.last ?? nil)
        #expect(TrendIndicators.lastEma([] as [IndicatorGoldenSupport.Bar], period: 20) == nil)
    }

    @Test("参数非法 → 全 nil，不 trap")
    func invalidParams() {
        let bars = (1...40).map { IndicatorGoldenSupport.Bar(open: 0, high: Double($0),
                                                             low: Double($0), close: Double($0),
                                                             volume: 1) }
        #expect(TrendIndicators.kama(bars, erPeriod: 0).allSatisfy { $0 == nil })
        #expect(TrendIndicators.kama(bars, erPeriod: 10, fast: 30, slow: 2).allSatisfy { $0 == nil })
    }
}

/// 三元 zip（Swift 标准库只到二元；只在测试里用，不进 Core）。
private func zip3<A, B, C>(_ a: [A], _ b: [B], _ c: [C]) -> [(A, B, C)] {
    zip(zip(a, b), c).map { ($0.0, $0.1, $1) }
}
