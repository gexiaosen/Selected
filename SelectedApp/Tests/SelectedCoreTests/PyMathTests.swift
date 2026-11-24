import Testing
@testable import SelectedCore

/// `PyMath` —— 与 Python 逐位一致的那几个数值口径。
///
/// 为什么值得单独钉：这是全项目**共享度最高**的数值入口（评分、deep_info、指标都用），
/// 而它存在的全部理由就是"看起来等价、其实不等价"：
///   · Swift 的 `(x*100).rounded()/100` 是 half-away-from-zero，Python 的 `round(x,2)` 是半偶
///   · Swift 的 `reduce(0,+)` 是朴素累加，CPython 3.12+ 的 `sum()` 是 Neumaier 补偿求和
/// 这两条只要回退一次，deep_info 的一批字段就会系统性偏移 0.01，进而影响评分与档位 ——
/// 而其他自动化不覆盖边界样本，所以要在单元层钉死。
///
/// 期望值全部来自 Python 3.12 的 `round` / `sum` 语义实测。
///
/// 注意：Swift Testing **默认并行**执行，依赖单例或夹具状态的用例要处理共享状态后再迁，
/// 否则会互相干扰。
@Suite("PyMath 数值口径（与 CPython 3.12 逐位一致）")
struct PyMathTests {

    // MARK: - round：银行家舍入 + 作用在 double 精确值上

    /// 每条都是"直觉会算错"的经典值。注释里给出 double 的真值，说明为什么是这个结果。
    @Test func roundMatchesPythonHalfEvenOnExactDoubleValue() {
        // 3.845 的 double 真值 = 3.845000000000000195…（> 3.845）→ 进位
        #expect(PyMath.round(3.845, 2) == 3.85)
        // 2.675 的 double 真值 = 2.674999999999999822…（< 2.675）→ 舍去
        #expect(PyMath.round(2.675, 2) == 2.67)
        // 1.875 恰好是二进制可表示值 → 真正的半偶：1.87 是奇、1.88 是偶 → 取 1.88
        #expect(PyMath.round(1.875, 2) == 1.88)
        // 0.125 精确可表示 → 半偶：0.12
        #expect(PyMath.round(0.125, 2) == 0.12)
        // 2.345 的 double 真值 = 2.345000000000000195…→ 进位（与 Decimal 路径的结果相反）
        #expect(PyMath.round(2.345, 2) == 2.35)
    }

    /// 半偶在**负数**上同样是"取偶数"，不是"远离零"。
    @Test func roundIntIsHalfEvenNotHalfAwayFromZero() {
        #expect(PyMath.roundInt(0.5) == 0)
        #expect(PyMath.roundInt(1.5) == 2)
        #expect(PyMath.roundInt(2.5) == 2)     // ← half-away 会给 3
        #expect(PyMath.roundInt(-0.5) == 0)
        #expect(PyMath.roundInt(-2.5) == -2)   // ← half-away 会给 -3
    }

    /// `round(x, 0)` 与 `roundInt(x)` 必须同口径（两条实现路径不许漂）。
    ///
    /// 参数化：每个值**独立报告**，哪一个挂了输出里直接指名，
    /// 且各用例并行 —— 这是循环式断言拿不到的信息。
    @Test(arguments: [0.5, 1.5, 2.5, -0.5, -2.5, 2.675, 3.845, 123.456])
    func roundZeroDigitsAgreesWithRoundInt(_ x: Double) {
        #expect(PyMath.round(x, 0) == PyMath.roundInt(x))
    }

    @Test func roundLeavesNonFiniteUntouched() {
        #expect(PyMath.round(.nan, 2).isNaN)
        #expect(PyMath.round(.infinity, 2) == .infinity)
        #expect(PyMath.round(-.infinity, 2) == -.infinity)
        #expect(PyMath.roundInt(.nan).isNaN)
    }

    // MARK: - sum：Neumaier 补偿求和

    /// 反例：`reduce(0,+)` 会把 1.0 整个丢掉（大数吃掉小数），`PyMath.sum` 不会。
    /// 这条断言同时是"为什么禁用 `reduce(0,+)`"的可执行证据。
    @Test func sumKeepsSmallTermThatNaiveAdditionLoses() {
        let values: [Double] = [1e100, 1.0, -1e100]
        #expect(PyMath.sum(values) == 1.0)                       // ≡ Python 3.12
        #expect(values.reduce(0, +) == 0.0,
                "朴素累加确实会丢 —— 若这条变了说明 Swift 运行时换了语义")
    }

    /// 0.1 累加 10 次：Python 3.12 `sum()` = 1.0，朴素累加 = 0.9999999999999999。
    @Test func sumOnRepeatedTenthsMatchesPython312() {
        #expect(PyMath.sum([Double](repeating: 0.1, count: 10)) == 1.0)
        #expect([Double](repeating: 0.1, count: 10).reduce(0, +) != 1.0)
    }

    @Test func sumEmptyIsZero() {
        #expect(PyMath.sum([Double]()) == 0.0)
    }

    /// 补偿求和**不改变**精确可表示序列的结果（避免"改过头"）
    @Test func sumIsExactOnExactlyRepresentableValues() {
        #expect(PyMath.sum([0.5, 0.25, 0.125]) == 0.875)
        #expect(PyMath.sum([1, 2, 3, 4]) == 10)
    }

    // MARK: - 其余口径

    @Test func intTruncTowardZero() {
        #expect(PyMath.intTrunc(2.9) == 2)
        #expect(PyMath.intTrunc(-2.9) == -2)   // ← 向零，不是 floor(-3)
        #expect(PyMath.intTrunc(0) == 0)
        #expect(PyMath.intTrunc(.nan) == 0, "非有限值兜 0，不崩")
        #expect(PyMath.intTrunc(.infinity) == 0)
    }

    @Test func closeHandlesNaNAndTolerance() {
        #expect(PyMath.close(1.0, 1.0))
        #expect(PyMath.close(1.0, 1.0 + 1e-12))
        #expect(!PyMath.close(1.0, 1.01))
        #expect(!PyMath.close(.nan, .nan), "NaN 与自身不算接近（否则对账会静默放过 NaN）")
        #expect(!PyMath.close(1.0, .nan))
    }

    @Test func roundEqualsUsesRoundedComparison() {
        #expect(PyMath.roundEquals(3.8451, 3.85, digits: 2))
        #expect(PyMath.roundEquals(2.6749, 2.67, digits: 2))
        #expect(!PyMath.roundEquals(2.6749, 2.68, digits: 2))
    }
}