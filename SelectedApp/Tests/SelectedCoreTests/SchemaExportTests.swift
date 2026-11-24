import Foundation
import XCTest
@testable import SelectedCore

/// 两个随包资源 JSON 与 Swift 生成源**逐字节**一致
///
/// 语义即"文件 == 生成结果"，**跑在 `swift test` 里**、不依赖解释器。
///
/// 为什么必须逐字节而不是"解析后语义相等"：
///   这两个 JSON 是**随包资源**，`build_app.sh` 会把它们 rsync 进 `.app`，
///   而 `DataDirectory.swift:30` 还拿 `param_schema_export.json` 的存在当**打包模式哨兵**。
///   若允许"语义相等"，格式漂移（缩进/键序/浮点写法）就会在**每次生成**时产生无谓 diff，
///   让人分不清"元数据真变了"与"只是重新序列化"。
///
/// 失败时的修法：**改 `SchemaExportData.swift`**（那才是单一事实来源），
///   然后跑 `SelectedApp/Tools/export_schema.swift` 重新生成 —— **不要手改 JSON**。
final class SchemaExportTests: XCTestCase {

    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()      // Tests/SelectedCoreTests
        .deletingLastPathComponent()      // Tests
        .deletingLastPathComponent()      // SelectedApp
        .deletingLastPathComponent()      // 仓库根

    private func onDisk(_ rel: String) throws -> String {
        let url = Self.repoRoot.appendingPathComponent(rel)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw EntityTestSupport.FixtureMissing(path: rel)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testDbSchemaExportIsByteIdentical() throws {
        let want = try onDisk(SchemaExport.dbSchemaRelPath)
        let got = SchemaExport.dbSchemaJSON()
        if want != got {
            XCTFail(diffSummary(label: SchemaExport.dbSchemaRelPath, want: want, got: got))
        }
    }

    func testParamSchemaExportIsByteIdentical() throws {
        let want = try onDisk(SchemaExport.paramSchemaRelPath)
        let got = SchemaExport.paramSchemaJSON()
        if want != got {
            XCTFail(diffSummary(label: SchemaExport.paramSchemaRelPath, want: want, got: got))
        }
    }

    /// 定位第一处差异行并给出可读的提示（不要只报"字符串不相等"——那要人自己去 diff）
    private func diffSummary(label: String, want: String, got: String) -> String {
        let w = want.split(separator: "\n", omittingEmptySubsequences: false)
        let g = got.split(separator: "\n", omittingEmptySubsequences: false)
        for i in 0..<min(w.count, g.count) where w[i] != g[i] {
            return """
            ❌ \(label) 与 Swift 生成源不一致（首个差异在第 \(i + 1) 行）
               文件: \(w[i].prefix(140))
               生成: \(g[i].prefix(140))
               ⇒ 改 SchemaExportData.swift 后跑 SelectedApp/Tools/export_schema.swift 重新生成
            """
        }
        return "❌ \(label) 行数不一致：文件 \(w.count) 行 / 生成 \(g.count) 行"
    }
}
