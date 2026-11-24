import Foundation

/// 数值转换的**唯一实现** —— 别再各写一份私有 `num` / `intOf` helper。
///
/// ## 语义约定（三条公开口径）
///
/// | 函数 | 返回 | 缺失/非法 | 非有限值（`inf` / `nan`） |
/// |---|---|---|---|
/// | ``doubleOrZero(_:)`` | `Double` | **0** | 折 **0** |
/// | ``doubleOrNil(_:)`` | `Double?` | `nil` | 折 **nil** |
/// | ``intOrNil(_:)`` | `Int?` | `nil` | 折 **nil** |
///
/// 另有**一条规则层遗留口径** ``doubleOrNilKeepingNonFinite(_:)``（`internal`，**保留** `inf`）——
/// 只给遗留调用点用，新代码不要用（见该函数注释）。
///
/// ⚠ **折 `nil` 还是折 `0` 不是风格问题**：本项目里 `0` 是**有意义的值**
///   （「资产负债率 0%」= 无负债，与"没数据"是**完全不同的结论**）。
///   所以「缺省 0」只用在**已知该字段必有值**的场景（DB 行解码）；
///   外部数据一律用 ``doubleOrNil(_:)``，由调用方显式决定怎么回落。
///
/// ⚠ **`Int(<Double>)` 必须带 `isFinite` 守卫**：`Int(Double.infinity)` / `Int(.nan)`
///   是 **Swift trap，不可 catch** —— 不是"返回个奇怪的值"，是整个 App 崩。
///   `Double("inf")` / `Double("1e400")` 都能得到 `inf`，而外部数据里什么都可能有。
public enum Num {

    /// DB 行 / JSON 值 → `Double`，**缺省 0**；非有限值折 **0**。
    ///
    /// 用于「已知该列/该字段必有值」的**行解码**场景（读自己写进去的库）。
    /// ⚠ 外部数据**不要**用它 —— 那会把"源没给"变成"值是 0"（见类型注释）。
    public static func doubleOrZero(_ v: Any?) -> Double {
        let d: Double
        if let x = v as? Double { d = x }
        else if let i = v as? Int { d = Double(i) }
        else if let n = v as? NSNumber { d = n.doubleValue }
        else if let s = v as? String { d = Double(s) ?? 0 }
        else { d = 0 }
        // 非有限值折 0：本函数有 `Int(num(...))` 的调用点（如龙虎榜 `tradeId`），
        // 而 `Int(inf)` 直接 trap。
        return d.isFinite ? d : 0
    }

    /// JSON / DB 值 → `Double?`；缺失 / 非法 / **非有限值**一律 `nil`。
    ///
    /// ⚠ 折 `nil` 而**不是** `0`：`0` 是有意义的值（见类型注释）。
    /// ⚠ 顺序：先 `Double`/`Int`，再 `NSNumber`，最后 `String` —— 与 `String → Double`
    ///   相比，前三者对**长小数**（`NSDecimalNumber`）走的是各自的正确路径。
    public static func doubleOrNil(_ v: Any?) -> Double? {
        let d: Double?
        if let x = v as? Double { d = x }
        else if let i = v as? Int { d = Double(i) }
        else if let n = v as? NSNumber { d = n.doubleValue }
        else if let s = v as? String { d = Double(s) }
        else { d = nil }
        return d.flatMap { $0.isFinite ? $0 : nil }
    }

    /// → `Int?`；缺失 / 非法 / **非有限或越界**一律 `nil`。
    ///
    /// ⚠ 守卫必须走 ``intSafe(_:)``：`isFinite` **单独不够**（`Int(1e30)` 是可 trap 的，
    ///   而 1e30 是有限的），详见 ``intSafe(_:)`` 的实测说明。
    /// ⚠ 原先走 `n.intValue`（**Int32**）：成交额级别的 10 位整数会**静默回绕**成错误值
    ///   而不是报错 —— 这比崩更难发现，故一并改成 int64 + 浮点分型判定。
    public static func intOrNil(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let d = v as? Double { return intSafe(d) }
        if let n = v as? NSNumber {
            let type = String(cString: n.objCType)
            if type == "d" || type == "f" { return intSafe(n.doubleValue) }
            return Int(exactly: n.int64Value)
        }
        return nil
    }

    /// 规则层遗留口径：`Bool` → 1/0、`String` 可解析、**保留** `inf` / `nan`。
    ///
    /// ⚠ `internal` —— **只给**遗留实现（`PredictRules.num` / `ScanRunner.num`）委托，
    ///   **新代码一律用 ``doubleOrNil(_:)``**：保留 `inf` 会让非有限值流到下游（`Int(inf)` 是 trap）。
    /// ⚠ 本口径不折 `nil`：40+ 调用点在打分/预判/迭代路径上，边界行为变更属独立决策，不要夹带。
    ///
    /// 其余 `Any? → Double?` 变体的分工（**都别合并、别再各写一份**）：
    /// - ``doubleOrNil(_:)``：外部数据标准口径
    /// - `Screener.numPy`：`Bool` **不算数**
    /// - `PhaseTune.numOrNil`：**不认** `String`（参数 JSON 里数字就是数字）
    /// - `FundamentalStore.num`：`Double` 优先（读取层给的就是 `Double`）
    /// - `FundamentalSource.num`：`NSDecimalNumber` 优先 + `isFinite` 守卫（长小数正确舍入）
    internal static func doubleOrNilKeepingNonFinite(_ v: Any?) -> Double? {
        guard let v else { return nil }
        if let n = v as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? 1 : 0 }
            return n.doubleValue
        }
        if let s = v as? String { return Double(s) }
        return nil
    }

    /// `Double → Int` 的**唯一安全出口**（缺失 / 非有限 / 越界一律 `nil`）。
    ///
    /// ⚠⚠ 只查 `isFinite` 是**不够**的（2026-10-16 审查 B2）：
    ///   `Int(1e30)` 里的 `1e30` 完全有限，但 `Int(<Double>)` 一旦结果超出 `Int64` 范围
    ///   就是**不可 catch 的运行时 trap** —— 实测 `Fatal error: Double value cannot be
    ///   converted to Int because the result would be greater than Int.max`、退出码 133，
    ///   整个 App 当场崩。而 `Double("1e30")` 在外部行情源返回里是可能出现的
    ///   （异常大值 / 溢出哨兵值 / 科学计数法串）。
    ///   上界取 `9.2e18`（`Int64.max ≈ 9.223e18`，留出截断余量）。
    ///
    /// 所有 `Int(<来自外部数据或 DB 的 Double>)` 都必须走这里，不要各写一份守卫。
    public static func intSafe(_ d: Double) -> Int? {
        guard d.isFinite, abs(d) < 9.2e18 else { return nil }
        return Int(d)
    }
}
