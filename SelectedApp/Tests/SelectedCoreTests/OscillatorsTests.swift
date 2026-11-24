import XCTest
@testable import SelectedCore

/// 六条固定阈值超买超卖信号。
///
/// 这个文件的重点是**四件容易搞错的事**：
/// · **`skipped` ≠ "中性"** —— 日K不足 / `MD==0` / 分母为 0 时判据**根本没跑**
/// · **KDJ 的一字板取中性 50** —— 取 0 会读成"极度超卖"、取 100 读成"极度超买"，
///   两者都是在**没有位置信息**的地方硬造结论
/// · **RSI 的"严重超买 90"与"超买 80"是两个档**（`>90` 与 `>80` 的边界）
/// · **VR 是唯一的区间型判据**（160–450 / 40–70），区间外是**中性**不是反向
final class OscillatorsTests: XCTestCase {

    // MARK: - 夹具

    private func bar(_ close: Double, open: Double? = nil, high: Double? = nil,
                     low: Double? = nil, volume: Double = 100) -> KLineBar {
        let o = open ?? close
        return KLineBar(day: "", open: o, high: high ?? max(o, close),
                        low: low ?? min(o, close), close: close, volume: volume)
    }

    /// 只有收盘与量参与（VR / RSI 用）
    private func bars(closes: [Double], volumes: [Double]) -> [KLineBar] {
        zip(closes, volumes).map { bar($0, volume: $1) }
    }

    /// 9 根**逐根抬高**且 `收 == 高` 的日K → 末根 RSV = 100
    private func rising9() -> [KLineBar] {
        (0..<9).map { i in
            let lo = 10.0 + Double(i) * 0.1
            let hi = 11.0 + Double(i) * 0.1
            return bar(hi, open: lo, high: hi, low: lo, volume: 100)
        }
    }

    /// 40 根**有波动**的日K。不能用"全平"的夹具来测"六条都能出读数"：
    /// 全平时 `CCI` 的 `MD == 0` → **算不出**（那是设计如此，不是 bug）。
    /// 这里让收盘按 5 根周期起伏 → TP 逐根变化、且既有涨也有跌。
    private func oscillating40() -> [KLineBar] {
        (0..<40).map { i in
            let c = 10.0 + Double(i % 5) * 0.2
            return bar(c, open: 10.0, high: c + 0.1, low: 9.9, volume: 100)
        }
    }

    // MARK: - ① KDJ

    /// 手算：`K=D=50` 起步、末根 `RSV=100` → `K=(2·50+100)/3`、`D=(2·50+K)/3`、`J=3K−2D`
    func testKDJHandComputed() throws {
        let r = try XCTUnwrap(Oscillators.kdj(rising9(), Oscillators.Config()))
        XCTAssertEqual(r.k, 66.6667, accuracy: 0.01, "K = (2×50+100)/3")
        XCTAssertEqual(r.d, 55.5556, accuracy: 0.01, "D = (2×50+66.67)/3")
        XCTAssertEqual(r.j, 88.8889, accuracy: 0.01, "J = 3K − 2D")
    }

    /// **一字板（`H == L`）→ `RSV` 取中性 50**，不是 0 也不是 100。
    /// 取 0 会把一字板读成"极度超卖"，取 100 读成"极度超买" ——
    /// 那是在**没有位置信息**的地方硬造一个结论。
    func testKDJOneWordBoardIsNeutralNotExtreme() throws {
        let flat = (0..<12).map { _ in bar(10, open: 10, high: 10, low: 10, volume: 100) }
        let r = try XCTUnwrap(Oscillators.kdj(flat, Oscillators.Config()))
        XCTAssertEqual(r.k, 50, accuracy: 0.0001)
        XCTAssertEqual(r.d, 50, accuracy: 0.0001)
        XCTAssertEqual(r.j, 50, accuracy: 0.0001, "一字板不该被判成超买或超卖")
    }

    /// 清单的 `K>80/D>70/J>90` 读作**合取** —— 三项全满足才算超买
    func testKDJZoneRequiresAllThree() {
        let c = Oscillators.Config()
        // K/D 很高但 J 不够 → 不算超买
        XCTAssertEqual(Oscillators.kdjZone((k: 85, d: 75, j: 80), c), .neutral)
        XCTAssertEqual(Oscillators.kdjZone((k: 85, d: 75, j: 95), c), .overbought)
        // 超卖清单只给了 K/D 两项
        XCTAssertEqual(Oscillators.kdjZone((k: 15, d: 25, j: 5), c), .oversold)
        XCTAssertEqual(Oscillators.kdjZone((k: 15, d: 35, j: 5), c), .neutral)
    }

    // MARK: - ② RSI

    /// 6 涨 0 跌 → 100；3 涨 3 跌等幅 → 50
    func testRSIBoundaries() throws {
        let allUp = (0..<7).map { bar(10.0 + Double($0)) }
        XCTAssertEqual(try XCTUnwrap(Oscillators.rsi(allUp, Oscillators.Config())), 100,
                       accuracy: 0.0001)
        let balanced = [10.0, 11, 12, 13, 12, 11, 10].map { bar($0) }
        XCTAssertEqual(try XCTUnwrap(Oscillators.rsi(balanced, Oscillators.Config())), 50,
                       accuracy: 0.0001)
    }

    /// **`>90` 严重超买 与 `>80` 超买 是两个档**。
    /// 恰好 90 落在"超买"（`>90` 为假）—— 边界方向必须有测试钉住。
    func testRSIZoneSevereVsNormalBoundary() throws {
        let c = Oscillators.Config()
        // 涨 9 跌 1 → RSI = 90 恰好
        let nine = [10.0, 12, 14, 16, 18, 19, 18].map { bar($0) }
        XCTAssertEqual(try XCTUnwrap(Oscillators.rsi(nine, c)), 90, accuracy: 0.0001)
        XCTAssertEqual(Oscillators.rsiZone(90, c), .overbought, "90 是「超买」，不是「严重超买」")
        XCTAssertEqual(Oscillators.rsiZone(90.01, c), .severeOverbought)
        XCTAssertEqual(Oscillators.rsiZone(10, c), .oversold, "10 是「超卖」，不是「严重超卖」")
        XCTAssertEqual(Oscillators.rsiZone(9.99, c), .severeOversold)
        XCTAssertEqual(Oscillators.rsiZone(50, c), .neutral)
    }

    // MARK: - ③ CCI

    /// 手算：`TP = 0,1,…,13` → `MA=6.5`、`MD=3.5` → `CCI=(13−6.5)/(0.015×3.5)`
    func testCCIHandComputed() throws {
        let ramp = (0..<14).map { i in
            bar(Double(i), open: Double(i), high: Double(i) + 1,
                low: Double(i) - 1, volume: 100)
        }
        let v = try XCTUnwrap(Oscillators.cci(ramp, Oscillators.Config()))
        XCTAssertEqual(v, 123.8095, accuracy: 0.01, "CCI = 6.5 / (0.015×3.5)")
    }

    /// **`MD == 0`（无波动）→ 算不出**，不是"中性"。
    func testCCIReturnsNilWhenNoDispersion() {
        let flat = (0..<20).map { _ in bar(10, open: 10, high: 10, low: 10, volume: 100) }
        XCTAssertNil(Oscillators.cci(flat, Oscillators.Config()), "无波动时 CCI 无定义")
        let out = Oscillators.evaluate(flat, config: Oscillators.Config())
        XCTAssertFalse(out.readings.contains { $0.kind == .cci }, "不该出现在读数里")
        let why = out.skipped[.cci] ?? ""
        XCTAssertTrue(why.contains("无波动"), "必须说清是「算不出」而不是「中性」：\(why)")
    }

    // MARK: - ④ CR

    /// 所有 bar 相同 → `H−中价 == 中价−L` → CR = 100（中性）
    func testCRIdenticalBarsIsHundred() throws {
        let same = (0..<27).map { _ in bar(10, open: 10, high: 11, low: 9, volume: 100) }
        let v = try XCTUnwrap(Oscillators.cr(same, Oscillators.Config()))
        XCTAssertEqual(v, 100, accuracy: 0.0001)
        XCTAssertEqual(Oscillators.crZone(100, Oscillators.Config()), .neutral)
    }

    /// **分母为 0**（价格从未低于昨中价，即只向上跳）→ 算不出
    func testCRReturnsNilWhenDenominatorZero() {
        let gapUp = (0..<27).map { i in
            bar(10.5 + Double(i), open: 10 + Double(i),
                high: 11 + Double(i), low: 10 + Double(i), volume: 100)
        }
        XCTAssertNil(Oscillators.cr(gapUp, Oscillators.Config()))
    }

    func testCRZoneThresholds() {
        let c = Oscillators.Config()
        XCTAssertEqual(Oscillators.crZone(161, c), .overbought, ">160 获利了结")
        XCTAssertEqual(Oscillators.crZone(160, c), .neutral, "恰好 160 不算（`>`）")
        XCTAssertEqual(Oscillators.crZone(39, c), .oversold, "<40 建仓")
        XCTAssertEqual(Oscillators.crZone(40, c), .neutral)
    }

    // MARK: - ⑤ WR

    /// `WR = (Hn − C)/(Hn − Ln)×100`：收在区间高点 → 0（超买）；低点 → 100（超卖）；中点 → 50
    func testWRPositionMapping() throws {
        func w(_ lastClose: Double) throws -> Double {
            let base = (0..<13).map { _ in bar(10.5, open: 10, high: 11, low: 10, volume: 100) }
            return try XCTUnwrap(Oscillators.wr(base + [bar(lastClose, open: 10, high: 11, low: 10,
                                                            volume: 100)],
                                                 Oscillators.Config()))
        }
        XCTAssertEqual(try w(11), 0, accuracy: 0.0001, "收在最高 → WR=0")
        XCTAssertEqual(try w(10), 100, accuracy: 0.0001, "收在最低 → WR=100")
        XCTAssertEqual(try w(10.5), 50, accuracy: 0.0001)
        let c = Oscillators.Config()
        XCTAssertEqual(Oscillators.wrZone(0, c), .overbought, "<20 超买（价在高位）")
        XCTAssertEqual(Oscillators.wrZone(100, c), .oversold, ">80 超卖（价在低位）")
    }

    /// `H == L`（无位置可言）→ 算不出
    func testWRReturnsNilWhenHighEqualsLow() {
        let flat = (0..<20).map { _ in bar(10, open: 10, high: 10, low: 10, volume: 100) }
        XCTAssertNil(Oscillators.wr(flat, Oscillators.Config()))
    }

    // MARK: - ⑥ VR

    /// 25 根涨（各 8 手）+ 1 根跌（100 手）→ `VR = 200/100×100 = 200` → 落在 160–450
    func testVRHandComputedSellZone() throws {
        let closes = (0...25).map { 10.0 + Double($0) * 0.1 } + [12.4]
        let vols = [Double](repeating: 8, count: 26) + [100]
        let v = try XCTUnwrap(Oscillators.vr(bars(closes: closes, volumes: vols),
                                             Oscillators.Config()))
        XCTAssertEqual(v, 200, accuracy: 0.0001)
        XCTAssertEqual(Oscillators.vrZone(v, Oscillators.Config()), .overbought, "160–450 获利了结")
    }

    /// 25 根跌（各 8 手）+ 1 根涨（100 手）→ `VR = 100/200×100 = 50` → 落在 40–70
    func testVRHandComputedBuyZone() throws {
        let closes = (0...25).map { 12.5 - Double($0) * 0.1 } + [10.1]
        let vols = [Double](repeating: 8, count: 26) + [100]
        let v = try XCTUnwrap(Oscillators.vr(bars(closes: closes, volumes: vols),
                                             Oscillators.Config()))
        XCTAssertEqual(v, 50, accuracy: 0.0001)
        XCTAssertEqual(Oscillators.vrZone(v, Oscillators.Config()), .oversold, "40–70 买进")
    }

    /// **VR 是唯一的区间型判据**：区间**之外**是中性，不是"反向信号"。
    /// `100` 既不在 160–450 也不在 40–70 → 中性（**不是**"超卖"）。
    func testVRZoneIsIntervalBasedNotThreshold() {
        let c = Oscillators.Config()
        XCTAssertEqual(Oscillators.vrZone(100, c), .neutral, "100 落在两个区间之外")
        XCTAssertEqual(Oscillators.vrZone(159.9, c), .neutral)
        XCTAssertEqual(Oscillators.vrZone(160, c), .overbought, "区间**含端点**")
        XCTAssertEqual(Oscillators.vrZone(450, c), .overbought)
        XCTAssertEqual(Oscillators.vrZone(450.1, c), .neutral, "超出上界即中性")
        XCTAssertEqual(Oscillators.vrZone(70, c), .oversold)
        XCTAssertEqual(Oscillators.vrZone(71, c), .neutral)
    }

    /// 全涨 → 无下跌也无平盘 → 分母为 0 → 算不出
    func testVRReturnsNilWhenNoDownVolume() {
        let closes = (0...26).map { 10.0 + Double($0) }
        let vols = [Double](repeating: 100, count: 27)
        XCTAssertNil(Oscillators.vr(bars(closes: closes, volumes: vols),
                                    Oscillators.Config()))
    }

    // MARK: - skipped 语义（与"中性"必须可区分）

    /// 日K不足 → 六条**全部**进 `skipped`，而不是显示成"中性"
    func testAllSkippedWhenBarsInsufficient() {
        let few = (0..<5).map { _ in bar(10, open: 10, high: 10.1, low: 9.9, volume: 100) }
        let out = Oscillators.evaluate(few, config: Oscillators.Config())
        XCTAssertTrue(out.readings.isEmpty, "5 根日K一条都算不出")
        XCTAssertEqual(out.skipped.count, 6, "六条都要报出原因：\(out.skipped)")
        for (_, why) in out.skipped {
            XCTAssertTrue(why.contains("日K不足"), "原因要具体：\(why)")
        }
    }

    /// 判别性：**同一组 bar，补足根数后结论翻转**（证明"没评估"与"中性"是两回事）
    func testSkippedFlipsToReadingWhenBarsAdded() {
        let short = (0..<5).map { _ in bar(10, open: 10, high: 10.1, low: 9.9, volume: 100) }
        XCTAssertEqual(Oscillators.evaluate(short, config: Oscillators.Config()).skipped.count, 6)
        let out = Oscillators.evaluate(oscillating40(), config: Oscillators.Config())
        XCTAssertEqual(out.readings.count, 6, "40 根有波动 → 六条都该有读数：\(out.skipped)")
        XCTAssertTrue(out.skipped.isEmpty)
    }

    // MARK: - 集合完整性

    func testSixKindsAndZoneTitles() {
        XCTAssertEqual(Oscillators.Kind.allCases.count, 6)
        for k in Oscillators.Kind.allCases { XCTAssertFalse(k.title.isEmpty) }
        for z in [Oscillators.Zone.severeOverbought, .overbought, .oversold,
                  .severeOversold, .neutral] {
            XCTAssertFalse(z.title.isEmpty)
        }
    }

    /// 正常序列上六条都能出读数，且**每条都带依据**（不是只给一个"超买"）
    func testEveryReadingCarriesEvidence() {
        let out = Oscillators.evaluate(oscillating40(), config: Oscillators.Config())
        XCTAssertEqual(out.readings.count, 6)
        for r in out.readings {
            XCTAssertFalse(r.note.isEmpty, "\(r.kind.rawValue) 缺依据")
            XCTAssertFalse(r.values.isEmpty, "\(r.kind.rawValue) 缺数值")
            XCTAssertTrue(r.note.contains("阈值") || r.note.contains("｜"),
                          "\(r.kind.rawValue) 的依据里要含阈值，便于核对：\(r.note)")
        }
        // KDJ 是唯一带三个数值的一条
        let kdj = out.readings.first { $0.kind == .kdj }
        XCTAssertEqual(kdj?.values.count, 3, "KDJ 有 K/D/J 三个数")
    }
}
