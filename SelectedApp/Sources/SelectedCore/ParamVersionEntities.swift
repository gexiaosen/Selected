import Foundation

// MARK: - 参数版本**库行**实体（`ParamStore.listVersions()` 的元素）
//
// ⚠ 这是**裁决后的行**（不是 `param_versions` 表的原始列）：`is_active` 与 `deletable`
// 由 `ParamStore` 算出，裁决只有一处实现（回归里 `param_source` 护栏钉死）。

/// 一个参数版本（≡ `ParamStore.listVersions()` 元素）
public struct ParamVersionRow: JSONEntity {
    public let json: JSONValue
    public init(_ json: JSONValue) { self.json = json }

    public static let declaredKeys: Set<String> = [
        "name", "is_builtin", "note", "created_at", "is_active", "deletable",
    ]

    public var name: String { json.str("name") }
    public var nameDash: String { json.strOrDash("name") }
    /// 出厂版本（随包）
    public var isBuiltin: Bool { json.flag("is_builtin") }
    /// 当前激活版本
    public var isActive: Bool { json.flag("is_active") }
    /// ⚠ 是否可删除 —— **不是**"非出厂即可删"：还要排除**当前激活**的版本，
    /// 以及被 `ParamStore.protectedVersions` 保护的版本。这份裁决必须只有一处实现。
    public var deletable: Bool { json.flag("deletable") }
    public var note: String { json.str("note") }
    public var noteDash: String { json.strOrDash("note") }
    /// 创建时间（Unix 时间戳；0 = 未知）
    public var createdAt: Int { json.integer("created_at") }
    /// 展示用：有创建时间才格式化
    public var hasCreatedAt: Bool { createdAt > 0 }
}
