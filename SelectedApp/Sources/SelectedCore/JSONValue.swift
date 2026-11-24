import Foundation

// MARK: - JSON 动态访问 Helper

/// 引擎返回 JSON 的动态包装，避免为全部结构写 Codable
/// （内容为 JSON 反序列化产物，不可变值树，标记 unchecked Sendable）
///
/// ⚠ **纯数据包装**，与"怎么取到这份 JSON"无关；覆盖「原生计算结果 → 视图/落库」整条链路。
public struct JSONValue: @unchecked Sendable {
    public let raw: Any

    public init(_ any: Any?) { self.raw = any ?? NSNull() }

    public var isNull: Bool { raw is NSNull }

    public var string: String? {
        if let s = raw as? String { return s }
        if let n = raw as? NSNumber { return n.stringValue }
        return nil
    }
    public var double: Double? {
        if let n = raw as? NSNumber { return n.doubleValue }
        if let s = raw as? String { return Double(s) }
        return nil
    }
    /// ⚠ 必须走 `Num.intSafe`：`double.map(Int.init)` 对 `1e30` 这类**有限但越界**的值
    ///   是不可 catch 的运行时 trap（`isFinite` 挡不住，见 `Num.intSafe` 说明）。
    public var int: Int? { double.flatMap(Num.intSafe) }

    public var bool: Bool? {
        if let b = raw as? Bool { return b }
        if let n = raw as? NSNumber { return n.boolValue }
        return nil
    }
    public var array: [JSONValue] { (raw as? [Any] ?? []).map(JSONValue.init) }
    public var dict: [String: JSONValue] {
        (raw as? [String: Any] ?? [:]).mapValues(JSONValue.init)
    }
    /// ⚠ **不要**写成 `JSONValue(dict[key]?.raw)`：
    /// `dict` 是计算属性，每访问一次就把**整个字典**重新包一层 `JSONValue`。
    /// 而 `subscript` 是最高频的取值入口（`item["code"]`、`item["name"]`…），
    /// 自选页一行就取 8 个字段 → 每行 8 次全字段分配；30 行 × 5s 轮询下每秒数百次。
    /// 直接对原始字典取一次键，语义完全等价（键缺失/非字典都返回 NSNull）。
    public subscript(key: String) -> JSONValue { JSONValue((raw as? [String: Any])?[key]) }
    public subscript(index: Int) -> JSONValue { array.indices.contains(index) ? array[index] : JSONValue(nil) }

    public var stringOrDash: String { string ?? "-" }
    public var doubleOrZero: Double { double ?? 0 }
    public var intOrZero: Int { int ?? 0 }

    /// dict 形式的值（用于向落库层传参）
    public var dictAny: [String: Any] { dict.mapValues { $0.raw } }

    /// 非 NSNull 时返回自身，否则 nil（用于可选子对象判断）
    public var nilIfNull: JSONValue? { isNull ? nil : self }

    // MARK: - ForEach 身份键
    //
    // 为什么需要：SwiftUI 的 `ForEach(_:id:)` **只有 KeyPath 重载、没有闭包重载**，
    // 而 `JSONValue` 是动态包装（没有静态字段）→ 视图里只能写 `id: \.self`，
    // 于是身份判定退化成 `JSONValue.hash` = 整个字典的序列化文本：
    //   · 自选页每 5s 轮询刷新，分数一变就判定为"新行" → 整行销毁重建，悬停/过渡动画丢失；
    //   · 参数编辑器的 group 字典**含全部子项**（100+ 项），每次身份判定都全量序列化。
    // 这里集中放几个业务主键，各视图用 `id: \.codeKey` 之类即可。
    // 取不到时返回空串/1：`ForEach` 会打一条重复 id 的运行期告警，但不会崩。
    public var codeKey: String { self["code"].string ?? "" }                          // 证券 / 自选 / 个股覆盖
    public var nameKey: String { self["name"].string ?? "" }                          // 参数版本
    public var groupIdKey: Int { self["id"].int ?? 1 }                                // 自选分组
    public var paramGroupKey: String { self["group"].string ?? self["title"].string ?? "" }  // 参数分组
    public var paramItemKey: String { self["key"].string ?? "" }                      // 参数项
    public var slotKey: Int { self["slot"].int ?? 0 }                                 // 轮次
    public var dateStringKey: String { self["date"].string ?? self["sel_date"].string ?? "" }  // 日期行
    public var sourceKey: String { self["source"].string ?? "" }                      // 数据源自检行
}

extension JSONValue: Hashable {
    public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        canonicalText(lhs.raw) == canonicalText(rhs.raw)
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(canonicalText(raw))
    }
}

/// 规范化文本（Hashable 的相等与哈希的**唯一**依据）：字典**按键排序**递归展开，数组保序，
/// 标量走 `String(describing:)`（保留 `110` 与 `110.0` 的形态差异 —— 该语义被既有测试钉住）。
///
/// ⚠ 不能直接用 `String(describing: raw)`：字典的 `description` 顺序**不是规范形** ——
///   受每进程随机种子影响（同内容不同进程顺序不同），同进程内两份相同字典也可能顺序不同。
///   于是「内容相同 ⇒ 文本相同」不成立：
///   · `==` 会把两份相等字典判为**不相等**（违背 Swift `Dictionary` 自身 order-independent 的 `==`）；
///   · `hash(into:)` 同样不稳定 ⇒ **违反 Hashable 铁律**（a == b 必须 ⇒ hash(a) == hash(b)）；
///   · 消费方是 `ForEach(id:)` / `Set` / 字典键的身份判定 ⇒ 偶发"每帧都判定为新行"。
///   键加引号：防键内自带 `,` `:` 造成 `("a,b":1)` 与 `("a":…)` 的歧义。
private func canonicalText(_ v: Any) -> String {
    switch v {
    case let d as [String: Any]:
        return "{" + d.keys.sorted().map { k in
            let val = d[k] ?? NSNull()
            return "\"\(k)\":" + canonicalText(val)
        }.joined(separator: ",") + "}"
    case let a as [Any]:
        return "[" + a.map(canonicalText).joined(separator: ",") + "]"
    default:
        return String(describing: v)
    }
}

// MARK: - Codable
//
// 存在的理由：让「引擎输出实体」（`JSONEntity`）能零成本拿到 `Codable` ——
// 实体内部就是一份 `JSONValue`，编码即原样输出，**不做任何类型转换**，
// 于是"实体 → JSON"这一步不可能丢字段或改类型。
//
// ⚠ 数字的三态必须靠 `objCType` 判，**不能**用 `as? Int` / `as? Double` 试探：
// `Bool` 会桥接成 `NSNumber`，而 `NSNumber(value: 110.0) as? Int` 也**成功**（截断成 110）
// —— 顺序或方法写错，`110.0` 会静默变成 `110`，落库时表现为"形态漂移"。
//
// ⚠ 已知局限：`init(from:)` 的 Int-先于-Double 会把 `110.0` 解成 `Int(110)`。**无法修** ——
// `110.0` 与 `110` 经 `JSONDecoder` 都先命中 `Int`，而 `Decimal` 也不保留尾零，
// 即**形态在 Codable 层不可还原**；若改成 Double-优先，则 `110` 反过来变 `110.0`（更糟）。
// ⇒ 生产代码 **0 处**使用 `JSONDecoder`（只测试往返用；引擎侧读值走 `objCType`，
//   见 `PyJSON` / `ScanEntities`），且 JSON 本身不区分 110 与 110.0 ⇒ 维持现状。
extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self.init(nil)
        } else if let b = try? c.decode(Bool.self) {
            self.init(b)
        } else if let s = try? c.decode(String.self) {
            self.init(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self.init(a.map(\.raw))
        } else if let d = try? c.decode([String: JSONValue].self) {
            self.init(d.mapValues(\.raw))
        } else if let i = try? c.decode(Int.self) {
            self.init(i)
        } else if let n = try? c.decode(Double.self) {
            self.init(n)
        } else {
            throw DecodingError.dataCorruptedError(
                in: c, debugDescription: "JSONValue 无法识别的 JSON 值")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        // ⚠ 分支顺序是**正确性的一部分**，不是风格问题：
        //
        // `NSNumber` 会桥接到 `Bool` —— `(1 as NSNumber) as? Bool` **成功**。
        // 若把 `case let b as Bool` 写在 `case let n as NSNumber` 之前，
        // 引擎输出的整数 `1`（如 `consec_up`）会被编码成 `true`，
        // 落库时表现为"字段类型漂移"，而**没有任何报错**。
        // 所以：先判 String / 容器，再用 `NSNumber` 一次性收掉所有数字与布尔，
        // 靠 `CFGetTypeID == CFBooleanGetTypeID()` 区分真布尔。
        switch raw {
        case is NSNull:
            try c.encodeNil()
        case let s as String:
            try c.encode(s)
        case let a as [Any]:
            try c.encode(a.map(JSONValue.init))
        case let d as [String: Any]:
            try c.encode(d.mapValues(JSONValue.init))
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                try c.encode(n.boolValue)
            } else if let dec = n as? NSDecimalNumber {
                // ⚠ 这个分支必须**先于** `isFloatingNumber` 判：`NSDecimalNumber` 的
                // `objCType` 也是 `'d'`，会被误当成普通 double。
                //
                // `JSONSerialization` 把**长小数**解析成 `NSDecimalNumber`（保持十进制精确），
                // 而它的 `doubleValue` **不是正确舍入的**（可差 1 ULP）——
                // 走 `doubleValue` 就会"编码一次就变值"，违反本类型"编码即原样输出、
                // 不做任何类型转换"的契约。按 `Decimal` 编码可精确往返。
                try c.encode(dec.decimalValue)
            } else if Self.isFloatingNumber(n) {
                try c.encode(n.doubleValue)
            } else {
                try c.encode(n.int64Value)
            }
        default:
            // 非 JSON 可表示的值（例如被误塞进来的 Date）→ 显式报错而不是静默变 null
            throw EncodingError.invalidValue(
                raw, .init(codingPath: c.codingPath,
                           debugDescription: "JSONValue 里出现了非 JSON 可表示的值：\(type(of: raw))"))
        }
    }

    /// 该 `NSNumber` 是浮点还是整型（`JSONSerialization` 产出：整型 'q'，小数 'd'）
    static func isFloatingNumber(_ n: NSNumber) -> Bool {
        let t = n.objCType.pointee
        return t == 0x64 || t == 0x66      // 'd' (double) / 'f' (float)
    }
}

extension JSONValue: ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral, ExpressibleByStringLiteral {
    public init(dictionaryLiteral elements: (String, Any)...) {
        self.raw = Dictionary(elements) { a, _ in a }
    }
    public init(arrayLiteral elements: Any...) { self.raw = elements }
    public init(stringLiteral value: String) { self.raw = value }
}