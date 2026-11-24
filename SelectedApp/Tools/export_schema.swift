import Foundation
@testable import SelectedCore

/// 重新生成两个**随包资源 JSON**
///
/// 用法（项目根目录）：
///   swiftc -O -parse-as-library -I <core-module> -enable-testing \
///       SelectedApp/Tools/export_schema.swift <SelectedCore.o> -o /tmp/export_schema
///   /tmp/export_schema
///
/// 生成源是 `SelectedApp/Sources/SelectedCore/SchemaExportData.swift` ——
///   **改元数据改那里**，然后跑本工具；**不要手改 JSON**。
/// 生成完**必须**跑一次 `swift test`：`SchemaExportTests` 会断言"文件 == 生成结果"。
@main
struct ExportSchemaCLI {
    static func main() {
        // 仓库根 = 本文件上溯 2 层（SelectedApp/Tools → SelectedApp → 仓库根）
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // Tools
            .deletingLastPathComponent()      // SelectedApp
            .deletingLastPathComponent()      // 仓库根
            .path
        do {
            for p in try SchemaExport.writeAll(repoRoot: root) {
                let text = (try? String(contentsOfFile: p, encoding: .utf8)) ?? ""
                print("已写出 \(p)（\(text.count) 字符 / \(text.split(separator: "\n").count) 行）")
            }
            print("⚠ 接着跑一次 `swift test` 确认 SchemaExportTests 通过（文件与生成源逐字节一致）")
        } catch {
            print("❌ 写出失败：\(error)")
            exit(1)
        }
    }
}
