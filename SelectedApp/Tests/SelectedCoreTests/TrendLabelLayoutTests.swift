import XCTest
@testable import SelectedCore

/// `TrendLabelLayout` 的落位与回落判据（折线末端直接标注 → 挤不下就回图例）。
///
/// 用例全部用**能手算的整数**：绘图区高 100、y 域 0...100 ⇒ 像素就是 `100 - 值`，
/// 任何一个数字都能拿笔在纸上复核 —— 这类判据一旦只能靠"看着截图差不多"来验，
/// 就等于没验（而且截图链路要真开一扇窗）。
///
/// ⚠ 这里钉的是"标签会不会叠字 / 会不会飘得太远"，不是好不好看；
///   真机上的观感（字号、留白、和线宽是否协调）只有他自己点进复盘页才判得了。
final class TrendLabelLayoutTests: XCTestCase {

    private let domain = 0.0...100.0
    private let height = 100.0
    private let inset = 6.0
    private let gap = 12.0
    private let drift = 18.0

    private func place(_ values: [(String, Double)],
                       plotHeight: Double? = nil,
                       minGap: Double? = nil,
                       maxDrift: Double? = nil,
                       inset: Double? = nil,
                       domain: ClosedRange<Double>? = nil) -> TrendLabelLayout.Outcome {
        TrendLabelLayout.place(anchors: values.map { TrendLabelLayout.Anchor(id: $0.0, value: $0.1) },
                               domain: domain ?? self.domain,
                               plotHeight: plotHeight ?? self.height,
                               minGap: minGap ?? self.gap,
                               maxDrift: maxDrift ?? self.drift,
                               inset: inset ?? self.inset)
    }

    /// 取出 `labels` 里的 (id, y, drift)，`crowded` 直接判失败（便于逐字段断言）
    private func laidOut(_ outcome: TrendLabelLayout.Outcome, file: StaticString = #filePath,
                         line: UInt = #line) -> [(id: String, y: Double, drift: Double)] {
        guard case .labels(let placed) = outcome else {
            XCTFail("期望 labels，实得 crowded", file: file, line: line)
            return []
        }
        return placed.map { ($0.id, $0.y, $0.drift) }
    }

    /// XCTest 没有「[Double] + accuracy」的重载，逐元素比
    private func assertYs(_ got: [(id: String, y: Double, drift: Double)], _ expect: [Double],
                          file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(got.count, expect.count, file: file, line: line)
        for (i, e) in expect.enumerated() where i < got.count {
            XCTAssertEqual(got[i].y, e, accuracy: 1e-9, "第 \(i) 条标签的 y", file: file, line: line)
        }
    }

    // MARK: - 分得开：不位移

    func testSpreadLinesGetZeroDrift() {
        let got = laidOut(place([("w", 80), ("c", 50), ("s", 20)]))
        XCTAssertEqual(got.count, 3)
        XCTAssertEqual(got.map(\.id), ["w", "c", "s"])          // 输入顺序，不是 y 顺序
        assertYs(got, [20, 50, 80])
        XCTAssertEqual(got.map(\.drift).reduce(0, +), 0, accuracy: 1e-9)  // 谁都不许动
    }

    // MARK: - 略挤：推开即可，不回落

    func testSlightOverlapIsPushedDownNotRejected() {
        // 50 → y=50，48 → y=52（只差 2px，标签会叠）⇒ 后者推到 62，位移 10 ≤ 18 ⇒ 可标
        let got = laidOut(place([("a", 50), ("b", 48)]))
        assertYs(got, [50, 62])
        XCTAssertEqual(got[0].drift, 0, accuracy: 1e-9)
        XCTAssertEqual(got[1].drift, 10, accuracy: 1e-9)
        // ⚠ drift 是相对"夹过边界的目标位"（52），不是相对原始 50：推开量 = 62-52 = 10 ⇒ 断 10。
        //   这里钉的是判据实际取值的那条链，改口径就得同步改注释。
    }

    // MARK: - 挤成一团：回落，且回落得干净

    func testThreeNearIdenticalEndpointsFallBackToLegend() {
        // 50/49/48 → 50/51/52 ⇒ 推开后 50/62/74，最后一条位移 22 > 18 ⇒ 整组 crowded
        //（只把第三条藏起来 = 图上剩两个标签说不清自己是谁，比没标签更糟）
        if case .labels(let p) = place([("a", 50), ("b", 49), ("c", 48)]) {
            XCTFail("位移 22 已超上限，不该出标签，实得 \(p)")
        }
    }

    func testMaxDriftBoundaryIsExclusive() {
        // 同一组数据，上限放到 22 ⇒ 刚好收下；收到 21.9 ⇒ 回落（钉死 `>` 而不是 `>=`）
        if case .crowded = place([("a", 50), ("b", 49), ("c", 48)], maxDrift: 22) {
            XCTFail("位移 22 == 上限，应判可标")
        }
        if case .labels = place([("a", 50), ("b", 49), ("c", 48)], maxDrift: 21.9) {
            XCTFail("位移 22 > 上限 21.9，应回落图例")
        }
    }

    // MARK: - 贴下边界：改成从下往上压

    func testBottomOverflowPushesUpwardKeepingOrder() {
        // 8 → y=92，6 → y=94：往下推会顶出 94（plotHeight-inset）⇒ 最底贴 94、上面压到 82
        let got = laidOut(place([("a", 8), ("b", 6)]))
        assertYs(got, [82, 94])
        XCTAssertEqual(got[0].drift, 10, accuracy: 1e-9)
        XCTAssertEqual(got[1].drift, 0, accuracy: 1e-9)
        XCTAssertEqual(got.map(\.id), ["a", "b"])               // 压位不改输出顺序
    }

    func testTopClampKeepsLabelsInsideInset() {
        // 100 / 99 都夹到 inset=6 ⇒ 第二条推到 18，两条都在带内、不回落
        let got = laidOut(place([("a", 100), ("b", 99)]))
        assertYs(got, [6, 18])
        XCTAssertLessThanOrEqual(got[1].drift, 18)
    }

    func testNoRoomAtAllFallsBack() {
        // 绘图区高 30、inset 6 ⇒ 可用带 [6,24] 只有 18px，minGap 12 摆不下 3 条
        if case .labels(let p) = place([("a", 50), ("b", 50), ("c", 50)], plotHeight: 30) {
            XCTFail("18px 的带装不下 3×12 间距，不该出标签，实得 \(p)")
        }
    }

    // MARK: - 退化输入

    func testEmptyAndSingleNeverCrowd() {
        XCTAssertEqual(place([]), .labels([]))
        XCTAssertEqual(place([("only", 50)]),
                       .labels([TrendLabelLayout.Placed(id: "only", y: 50, drift: 0)]))
    }

    func testDegenerateGeometryCrowds() {
        // 高度 0 / 域上下界相等 ⇒ 落位无从计算，判回落（视图会老实画回图例，不会画出 0 高标签）
        if case .labels = place([("a", 50), ("b", 40)], plotHeight: 0) {
            XCTFail("plotHeight=0 应判 crowded")
        }
        if case .labels = place([("a", 50), ("b", 40)], domain: 50...50) {
            XCTFail("domain 退化应判 crowded")
        }
    }

    // MARK: - 真实档位：图高 200 减去坐标轴带 ≈ 174

    func testRealChartHeightMatchesChosenGap() {
        // ⚠ 视图用的 minGap=13 / maxDrift=20 / inset=8（约一行 10pt 文字高）：
        //   四层胜率里最容易撞的是"窗口可用 vs 收盘持有"（常年差 3~6 个百分点）。
        //   174px 高 ⇒ 1 个百分点 ≈ 1.74px ⇒ 差 4 个点 = 7px < 13 ⇒ 必须推开（位移 6px，收下）；
        //   差 1 个点 ⇒ 推开需要 ~12px，仍 ≤ 20 ⇒ 收下；差 0 个点（真相等）⇒ 三条起才会回落。
        let h = 174.0
        let got = laidOut(place([("window", 55), ("close", 51)], plotHeight: h, minGap: 13, maxDrift: 20, inset: 8))
        XCTAssertEqual(got[0].y, h * 0.45, accuracy: 1e-6)        // 55% ⇒ 距顶 45%
        XCTAssertGreaterThanOrEqual(got[1].y - got[0].y, 13 - 1e-9)
        XCTAssertLessThanOrEqual(got[1].drift, 20)
    }

    func testRealChartHeightFourEqualLayersCrowd() {
        // 四层胜率完全相等（回测里真会出现：都是 100% 或都是 0%）⇒ 标签排不开 ⇒ 回图例
        if case .labels(let p) = place([("window", 100), ("close", 100), ("snapshot", 100), ("ceiling", 100)],
                                       plotHeight: 174, minGap: 13, maxDrift: 20, inset: 8) {
            XCTFail("四层同值应回落图例，实得 \(p)")
        }
    }
}
