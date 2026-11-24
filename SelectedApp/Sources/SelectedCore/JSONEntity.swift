import Foundation

// MARK: - 引擎输出实体的共同约定
//
// ## 为什么是"包着 `JSONValue` 的实体"，而不是"纯字段的 Codable struct"
//
// 1. **引擎 JSON 是宽松的，Swift 的 `Codable` 是严格的**
//    同一个字段在不同版本/分支可能是 `110` 也可能是 `110.0`、可能是 `null` 也可能缺键。
//    `Codable` 直接解 `Int` 遇到 `110.0` 会**抛错**，而 `JSONValue.int` 是容错的
//    （`double.map(Int.init)`）。改成严格解码就是一次**静默行为变更**。
// 2. **无损** —— 原始 JSON 原样保留，"实体 → JSON"这一步**不可能**丢字段或改类型。
//    引擎加了新字段而实体还没跟上时，落库拿到的仍是完整 JSON。
// 3. **`Codable` 照样有** —— 实体内部就是一份 `JSONValue`，编码即原样输出
//    （见 `JSONValue: Codable`）。
// 4. **可机械验证** —— `declaredKeys` 声明了实体覆盖的键，测试拿真实引擎输出比对：
//    漏键、拼错键都会红。这是证明"实体与生产者一致"的手段。
//
// ⚠ **新代码一律用类型化属性**（`result.stats.tier1Count`）—— 键名拼错是**编译错误**，
//   引擎改键名由 `declaredKeys` 覆盖测试拦住；旧写法 `json["x"].intOrZero` 拿到默认值
//   时**没有任何信号**。实体保留 `json`，旧写法仍可用。

/// 引擎输出的一个 JSON 对象实体。
public protocol JSONEntity: Codable, Hashable, Sendable {
    /// 原始 JSON（无损：未声明/未消费的键也在这里）
    var json: JSONValue { get }
    init(_ json: JSONValue)

    /// 实体**声明覆盖**的键。测试会拿真实引擎输出比对，漏键/拼错键都会失败。
    static var declaredKeys: Set<String> { get }
    /// **路径相关键**：不是每条产出路径都会带的键（测试里从"多余键"里扣除，避免误报）。
    ///
    /// ⚠ **同一个逻辑实体在不同路径上键集并不相同**。例：
    /// · `VerifyResult` —— 阶段产出（`PhaseVerify`）11 键；库读取（`SQLiteReader.verifyRow`）
    ///   8 键（少 `data_mode`/`groups`/`persisted`/`verify_date`，多 `is_empty_day`）
    /// · `IterateResult` —— 阶段产出 10 键；`SQLiteReader.iterateRow` 6 键
    ///
    /// 所以 `declaredKeys` 是**各路径的并集**，`conditionalKeys` 是"并非每条路径都有"的那些。
    /// 测试对**两条路径各跑一遍**，保证任一路径上的消费方都不会踩空。
    static var conditionalKeys: Set<String> { get }
}

public extension JSONEntity {
    // Codable 走 JSONValue 原样往返：不做任何类型转换，故不可能变形
    init(from decoder: Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(JSONValue.self))
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(json)
    }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.json == rhs.json }
    func hash(into hasher: inout Hasher) { hasher.combine(json) }

    /// 该实体是否为"空对象"（引擎在早退分支可能返回 `{}` 或 null）
    var isEmptyObject: Bool { json.dict.isEmpty }

    static var conditionalKeys: Set<String> { [] }
}

/// 实体字段的**取值口径**
///
/// 各字段的缺省值集中到这里，"某个字段的缺省是什么"只有一处答案。
extension JSONValue {
    /// 字符串；缺失 / null / 类型不符 → `def`
    func str(_ key: String, _ def: String = "") -> String { self[key].string ?? def }
    /// 展示用字符串：缺失 / 类型不符 → `dash`（等价旧的 `stringOrDash`）
    func strOrDash(_ key: String, _ dash: String = "-") -> String { self[key].string ?? dash }
    /// 数值；缺失 / null / 类型不符 → `def`
    func num(_ key: String, _ def: Double = 0) -> Double { self[key].double ?? def }
    /// 整数；缺失 / null / 类型不符 → `def`
    func integer(_ key: String, _ def: Int = 0) -> Int { self[key].int ?? def }
    /// 布尔；缺失 / null / 类型不符 → `def`
    ///
    /// 口径 = **宽松**（等价视图里的 `json["x"].bool == true` / `json["x"].bool ?? def`）。
    /// 引擎对这些字段一律输出 JSON 布尔，宽松与严格口径在正常数据下无差别。
    func flag(_ key: String, _ def: Bool = false) -> Bool { self[key].bool ?? def }
    /// 可空数值（**保留 null 与 0 的区别**：`0` 是真实值，`null` 是"没有"）
    func numOrNil(_ key: String) -> Double? { self[key].isNull ? nil : self[key].double }
    /// 可空整数（同上）
    func intOrNil(_ key: String) -> Int? { self[key].isNull ? nil : self[key].int }
    /// 字符串数组（元素按字符串读，非字符串元素丢弃）
    func strings(_ key: String) -> [String] { self[key].array.compactMap { $0.string } }
    /// 原样数组（缺失 → 空数组，与旧代码 `?? [Any]()` 一致；**保留元素原始形态**，供落库编码）
    func rawArray(_ key: String) -> [Any] { (self[key].raw as? [Any]) ?? [] }
    /// 对象数组
    func objects(_ key: String) -> [JSONValue] { self[key].array }
    /// 子对象（缺失 → 空对象，不返回 nil，与旧代码 `?? [:]` 一致）
    func object(_ key: String) -> JSONValue { self[key] }
    /// **以轮次号为键**的字典：键是 `"1"`/`"2"`/`"3"`，值经 `transform` 转换。
    ///
    /// ⚠ "逐轮数据"有两种形态，**长得像但类型不同**，混用会静默拿到空、**不报错**：
    /// · **数组**：`slots_available` / `slots_expected` / `missing_slots` / `slots`
    /// · **按轮次键的对象**：`tiers` / `scores` / `prices` / `changes` / `reasons`
    ///   （`{"1": 110, "2": 110, "3": 110}`）
    func bySlot<T>(_ key: String, _ transform: (JSONValue) -> T?) -> [Int: T] {
        var out: [Int: T] = [:]
        for (k, v) in self[key].dict {
            guard let slot = Int(k), let value = transform(v) else { continue }
            out[slot] = value
        }
        return out
    }
}
