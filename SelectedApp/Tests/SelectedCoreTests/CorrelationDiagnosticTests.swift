import XCTest
@testable import SelectedCore

/// 「加分项同源相关性诊断」的行为契约。
///
/// `CorrelationDiagnostic` 是**纯诊断**（不参与判定），判定类回归证明不了它对不对。
/// 而秩相关最容易出的两类错，恰好都会**静默给出看似合理的数**：
///   ① 并列值不取平均秩 → 0/1 型特征（`ma_pass` 等）的 ρ 被扭曲
///   ② 常量序列不判空 → 分母为 0，要么崩要么报出无意义的 ±1
final class CorrelationDiagnosticTests: XCTestCase {

    /// 把 (特征键, 值序列) 摊成样本表；短序列的样本自动缺该键（模拟真实池里的 null）
    private func samples(_ cols: [(String, [Double])]) -> [[String: Double]] {
        let n = cols.map(\.1.count).max() ?? 0
        var out: [[String: Double]] = []
        for i in 0..<n {
            var s: [String: Double] = [:]
            for (k, v) in cols where i < v.count { s[k] = v[i] }
            out.append(s)
        }
        return out
    }

    // MARK: - ① 平均秩（并列必须取均值）

    func testAverageRanksWithoutTies() {
        XCTAssertEqual(CorrelationDiagnostic.averageRanks([30, 10, 20]), [3, 1, 2])
    }

    func testAverageRanksWithTies() {
        // [5, 5, 9] → 两个 5 并列占第 1、2 名 → 各得 1.5；9 得 3
        XCTAssertEqual(CorrelationDiagnostic.averageRanks([5, 5, 9]), [1.5, 1.5, 3])
    }

    func testAverageRanksAllEqual() {
        XCTAssertEqual(CorrelationDiagnostic.averageRanks([7, 7, 7]), [2, 2, 2])
    }

    func testAverageRanksEmpty() {
        XCTAssertEqual(CorrelationDiagnostic.averageRanks([]), [])
    }

    // MARK: - ② Spearman

    func testPerfectMonotoneIncreasing() {
        XCTAssertEqual(CorrelationDiagnostic.spearman([1, 2, 3, 4, 5], [2, 4, 6, 8, 10])!, 1.0,
                       accuracy: 1e-12)
    }

    func testPerfectMonotoneDecreasing() {
        XCTAssertEqual(CorrelationDiagnostic.spearman([1, 2, 3, 4, 5], [50, 40, 30, 20, 10])!, -1.0,
                       accuracy: 1e-12)
    }

    /// 秩相关对**严格单调但非线性**的关系给 1.0 —— 这正是选它的理由：
    /// 皮尔逊对平方/立方这类关系会低于 1，秩相关只看次序
    func testNonlinearMonotoneStillOne() {
        let x = [1.0, 2, 3, 4, 5, 6, 7, 8]
        let cubic = x.map { $0 * $0 * $0 }
        XCTAssertEqual(CorrelationDiagnostic.spearman(x, cubic)!, 1.0, accuracy: 1e-12)
    }

    /// 但**有并列**的单调阶梯**不会**给 1.0：秩相关量的是次序，不是"是否单调"。
    /// 钉住这条是为了防止有人把 0.87 当成 bug 去"修" —— 它是对的。
    /// （本模块的判据是**特征之间**的相关，特征本身很少并列；这条只说明秩相关的性质。）
    func testMonotoneWithTiesIsBelowOne() {
        let x = [1.0, 2, 3, 4, 5, 6, 7, 8]
        let step = x.map { $0 < 5 ? 0.0 : 100.0 }   // 4 个 0、4 个 100 → 大量并列
        let rho = CorrelationDiagnostic.spearman(x, step)!
        XCTAssertLessThan(rho, 1.0)
        XCTAssertGreaterThan(rho, 0.8, "仍应是很强的正相关，只是不等于 1")
    }

    /// 手算校验：a=[1..5]、b=[1,2,3,5,4] → Σd²=2 → ρ = 1 − 6·2/(5·24) = 0.9
    func testKnownValueMatchesHandCalculation() {
        XCTAssertEqual(CorrelationDiagnostic.spearman([1, 2, 3, 4, 5], [1, 2, 3, 5, 4])!, 0.9,
                       accuracy: 1e-12)
    }

    /// 常量序列 → 秩方差为 0，相关**无定义**：必须给 nil，不能报 0 或 ±1
    func testConstantSeriesIsNilNotZero() {
        XCTAssertNil(CorrelationDiagnostic.spearman([5, 5, 5, 5], [1, 2, 3, 4]))
        XCTAssertNil(CorrelationDiagnostic.spearman([1, 2, 3, 4], [5, 5, 5, 5]))
    }

    func testTooFewSamplesIsNil() {
        XCTAssertNil(CorrelationDiagnostic.spearman([1, 2], [2, 1]))
        XCTAssertNil(CorrelationDiagnostic.spearman([], []))
    }

    // MARK: - ③ 逐对诊断

    func testFindsPerfectlyCorrelatedPairs() {
        let n = 40
        let asc = (0..<n).map(Double.init)
        let desc = asc.reversed().map { $0 }
        let items = samples([("dist_from_low", asc), ("cum_5d", asc), ("dist_from_high", desc)])
        let pairs = CorrelationDiagnostic.diagnose(samples: items, minSamples: 30)

        // 用**无序对**断言：key1/key2 的先后由 `features` 列表顺序决定，
        //   直接比字符串会在有人重排 features 时误红
        let keys = Set(pairs.map { [$0.key1, $0.key2].sorted().joined(separator: "|") })
        XCTAssertEqual(keys, ["cum_5d|dist_from_low", "dist_from_high|dist_from_low",
                              "cum_5d|dist_from_high"])
        for p in pairs {
            XCTAssertEqual(p.n, n)
            XCTAssertEqual(abs(p.rho), 1.0, accuracy: 1e-12)
        }
    }

    func testBelowMinSamplesIsExcluded() {
        let n = 40
        let asc = (0..<n).map(Double.init)
        // cum_5d 只在前 20 个样本里有值 → 与它的成对样本 = 20 < 30 → 该配对必须被排除
        let items = samples([("dist_from_low", asc), ("cum_5d", Array(asc.prefix(20))),
                             ("dist_from_high", asc)])
        let pairs = CorrelationDiagnostic.diagnose(samples: items, minSamples: 30)
        XCTAssertFalse(pairs.contains { $0.key1 == "cum_5d" || $0.key2 == "cum_5d" },
                       "成对样本不足时不得出结论")
        // 另两对仍有 40 个样本 → 必须还在（证明排除的是"样本不足"而不是"整体放弃"）
        XCTAssertTrue(pairs.contains { $0.key1 == "dist_from_low" && $0.key2 == "dist_from_high" })
    }

    func testBelowThresholdIsExcluded() {
        // 构造一对几乎无关的序列：0..39 与「锯齿」—— 秩相关接近 0
        let n = 40
        let a = (0..<n).map(Double.init)
        let b = (0..<n).map { Double($0 % 2) }
        let items = samples([("dist_from_low", a), ("cum_5d", b)])
        XCTAssertTrue(CorrelationDiagnostic.diagnose(samples: items, minSamples: 30).isEmpty)
    }

    /// 缺键 = 该样本不参与这一对（成对完整观测），**不是补 0**
    func testMissingKeyExcludesSampleFromThatPairOnly() {
        let n = 40
        let asc = (0..<n).map(Double.init)
        // 前 10 个样本缺 cum_5d
        let items = samples([("dist_from_low", asc), ("cum_5d", Array(asc.dropFirst(10))),
                             ("dist_from_high", asc)])
        let pairs = CorrelationDiagnostic.diagnose(samples: items, minSamples: 30)
        let p1 = pairs.first { $0.key1 == "dist_from_low" && $0.key2 == "cum_5d" }
        XCTAssertEqual(p1?.n, 30, "成对样本数应是 30（40 − 缺键的 10），补 0 会得到 40")
        let p2 = pairs.first { $0.key1 == "dist_from_low" && $0.key2 == "dist_from_high" }
        XCTAssertEqual(p2?.n, 40, "不受另一对缺键影响")
    }

    /// 常量特征（如全池 `ma_pass` 都是 true）→ 秩方差 0 → 该配对不出结论
    func testConstantFeatureProducesNoPair() {
        let n = 40
        let asc = (0..<n).map(Double.init)
        let items = samples([("dist_from_low", asc), ("ma_pass", [Double](repeating: 1, count: n))])
        XCTAssertTrue(CorrelationDiagnostic.diagnose(samples: items, minSamples: 30).isEmpty,
                      "常量特征的相关无定义，不得报成 ±1")
    }

    func testSortedByAbsoluteRhoDescending() {
        let n = 40
        let asc = (0..<n).map(Double.init)
        // 与 asc 完全同序（|ρ|=1）vs 与 asc 反向（|ρ|=1）—— 用一个近似序列制造更小的 |ρ|
        var near = asc
        near.swapAt(0, 1); near.swapAt(10, 11)   // 轻微打乱 → |ρ| 略小于 1
        let items = samples([("dist_from_low", asc), ("cum_5d", asc),
                             ("dist_from_high", near)])
        let pairs = CorrelationDiagnostic.diagnose(samples: items, minSamples: 30)
        let rhos = pairs.map { abs($0.rho) }
        XCTAssertEqual(rhos, rhos.sorted(by: >), "必须按 |ρ| 降序")
    }

    // MARK: - ④ 阈值：必须低到能在真实数据上触发

    /// 阈值若高于**实测的最高相关对**，本诊断在真实数据上**从不触发** ——
    /// 那比误报更糟：用户以为"查过了，没问题"。
    ///
    /// 实测（生产库调优池 135 个去重样本、45 个成对 ≥30 的配对）：
    /// 最高为「连涨天数 ↔ 前日涨幅」ρ=0.68，没有任何一对达到 0.7 —— 故阈值必须钉在
    /// 能在真实数据上触发的位置。
    func testDefaultThresholdIsBelowObservedMaximum() {
        XCTAssertLessThanOrEqual(CorrelationDiagnostic.defaultThreshold, 0.68,
                                 "阈值高于实测最高相关对 → 诊断永不触发，功能等于不存在")
    }

    // MARK: - ⑤ 落库形态

    func testJSONShape() {
        let n = 40
        let asc = (0..<n).map(Double.init)
        let items = samples([("dist_from_low", asc), ("cum_5d", asc)])
        let pairs = CorrelationDiagnostic.diagnose(samples: items, minSamples: 30)
        let j = CorrelationDiagnostic.json(pairs: pairs, samples: items.count, threshold: 0.7)

        XCTAssertEqual(Set(j.keys), ["threshold", "samples", "pairs", "note"])
        XCTAssertEqual(j["samples"] as? Int, 40)
        XCTAssertEqual(j["threshold"] as? Double, 0.7)
        let first = (j["pairs"] as? [[String: Any]])?.first
        XCTAssertEqual(Set(first?.keys ?? [:].keys), ["a", "a_label", "b", "b_label", "rho", "n"],
                       "配对键集必须与 SettingsView 的读取口径一致")
        // note 必须写明"量的是特征不是得分"，否则会被误读成"这两项一定重复"
        XCTAssertTrue((j["note"] as? String)?.contains("特征") == true)
    }
}
