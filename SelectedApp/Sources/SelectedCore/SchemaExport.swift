import Foundation

/// 两个**随包资源 JSON** 的生成入口。
///
/// | 文件 | 消费方 | 内容 |
/// |---|---|---|
/// | `engine/params/db_schema_export.json` | `DBBootstrap.swift`（建库/迁移） | 建表脚本 + 增量迁移 + 版本水位 |
/// | `engine/params/param_schema_export.json` | `ParamSchema.swift`（参数中心）/ `DataDirectory.swift`（打包模式哨兵） | 参数元数据 + 工厂默认 + 出厂版本表 |
///
/// **为什么要有这一层**：如果只留两个 JSON 而没有生成源，它们就成了**孤儿**：
/// App 照样跑，但没人能再改 schema（手改 JSON 会报红）。所以生成源在 Swift 侧。
///
/// ⚠ **数据在 `SchemaExportData.swift`**（自动生成，但生成之后它就是单一事实来源）。
/// ⚠ 一致性由 `SchemaExportTests` 钉住：断言"重新渲染的结果与仓内文件**逐字节**相同"。
public enum SchemaExport {

    /// `db_schema_export.json` 的完整文本（含末尾换行）
    public static func dbSchemaJSON() -> String {
        PyPrettyJSON.render(SchemaExportData.dbSchema)
    }

    /// `param_schema_export.json` 的完整文本（含末尾换行）
    public static func paramSchemaJSON() -> String {
        PyPrettyJSON.render(SchemaExportData.paramSchema)
    }

    /// 仓内两个 JSON 的**相对路径**（相对仓库根）
    public static let dbSchemaRelPath = "engine/params/db_schema_export.json"
    public static let paramSchemaRelPath = "engine/params/param_schema_export.json"

    /// 重新写出两个 JSON（`Tools/export_schema.swift` 用；`swift test` 只用上面的 render）
    @discardableResult
    public static func writeAll(repoRoot: String) throws -> [String] {
        var written: [String] = []
        for (rel, text) in [(dbSchemaRelPath, dbSchemaJSON()),
                            (paramSchemaRelPath, paramSchemaJSON())] {
            let path = repoRoot + "/" + rel
            try text.write(toFile: path, atomically: true, encoding: .utf8)
            written.append(path)
        }
        return written
    }
}
