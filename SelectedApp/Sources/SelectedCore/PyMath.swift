import Foundation

/// 数值口径辅助 —— 与 Python 逐位一致的舍入/求和语义。
///
/// "算法一样"不等于"结果一样"，最容易踩的是**舍入语义**：
///   · Python `round(x, 2)` 是**银行家舍入**（round-half-even），且作用在 double 的
///     *精确十进制值* 上 —— `round(2.675, 2) == 2.67`（因为 2.675 实际是 2.67499…）
///   · Swift 的 `(x * 100).rounded() / 100` 是 half-away-from-zero，且先乘后除会再引入误差
/// 直接写后者会让 deep_info 的一堆 `round(..., 2)` 字段在边界值上系统性偏移，
/// 进而影响评分与档位。故统一走本文件的 `round` / `sum`。
public enum PyMath {

    /// 等价于 Python 的 `round(x, digits)`：**基于 double 精确值的正确舍入**（半偶）。
    ///
    /// ⚠ 不能用 `Decimal(x)` + `NSDecimalRound`：`Decimal(Double)` 拿到的是**十进制
    /// 字面量近似**，会丢掉二进制表示误差，于是与 Python 反向出错
    /// （如 `round(3.845, 2)`：Decimal → 3.84，Python 真值 3.845000000000000195… → 3.85）。
    /// 改用 `printf` 系（C 库对 double 做正确舍入、默认半偶），与 Python 同源。
    public static func round(_ x: Double, _ digits: Int) -> Double {
        guard x.isFinite else { return x }
        let s = String(format: "%.\(max(0, digits))f", x)
        return Double(s) ?? x
    }

    /// 等价于 Python 的 `round(x)`（无 digits → 整数，仍为半偶舍入）
    public static func roundInt(_ x: Double) -> Double {
        guard x.isFinite else { return x }
        let s = String(format: "%.0f", x)
        return Double(s) ?? x
    }

    /// 等价于 Python 3.12+ 的 `sum(浮点序列)`。
    ///
    /// ⚠ 这不是普通累加：CPython 3.12 起 `sum()` 对 float 用 **Neumaier 补偿求和**。
    /// 朴素累加会在末位漂移（如 3.8450000000000002 vs 3.8449999999999998），
    /// `round(..., 2)` 后差 0.01 → deep_info 的 ma5/ma10/ma20 系统性偏移，
    /// 进而影响 ma_pass 与评分。所有对浮点序列求和的地方都必须走这里，
    /// 不能用 `reduce(0, +)`。
    public static func sum<S: Sequence>(_ values: S) -> Double where S.Element == Double {
        var s = 0.0
        var c = 0.0                      // 补偿项
        for x in values {
            let t = s + x
            if abs(s) >= abs(x) {
                c += (s - t) + x
            } else {
                c += (x - t) + s
            }
            s = t
        }
        return s + c
    }

    /// 等价于 Python 的 `int(x)`：向零截断（正数即向下取整）
    ///
    /// ⚠ 非有限值折 0（保持本项目既有口径）；**越界也必须折 0** ——
    ///   `Int(1e30)` 是 trap（1e30 有限，但超出 Int64），守卫必须走 `Num.intSafe`。
    public static func intTrunc(_ x: Double) -> Int {
        Num.intSafe(x) ?? 0
    }

    /// 近似相等比较（避免 1e-15 级浮点噪声误报）
    public static func close(_ a: Double, _ b: Double, tolerance: Double = 1e-9) -> Bool {
        if a == b { return true }
        if a.isNaN || b.isNaN { return false }
        return abs(a - b) <= tolerance * max(1, max(abs(a), abs(b)))
    }

    /// 等价于 Python 的 `round(x, n)` 后与目标比较（测试比对用）
    public static func roundEquals(_ value: Double, _ expected: Double, digits: Int) -> Bool {
        let r = round(value, digits)
        // Python 的 round 结果在极端情况下仍可能有 1 ulp 差异，故用极小容差
        return abs(r - expected) <= 1e-9
    }
}
