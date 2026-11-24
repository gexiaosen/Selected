import XCTest
@testable import SelectedCore

/// 分层约束：`SelectedCore` **不得**依赖 UI 框架。
///
/// `Package.swift` 只能保证「Core 不依赖 App」这个方向（target 依赖图是单向的），
/// **保证不了「Core 里不许 import SwiftUI」** —— 在 macOS 上 `import SwiftUI`
/// 完全合法，编译不会报任何错。而一旦 Core 里出现 `View` / `Color` / `@State`：
///   · `Tools/*.sh` 的自检驱动链接 Core 时会拖进整个 UI 栈（编译变慢、依赖 AppKit 运行时）
///   · "引擎层可以脱离 UI 单独跑" 这条前提失效
///
/// 所以这里在**源码层**再钉一道。路径由 `#filePath` 推出，测试在源码树里跑即可定位。
final class CoreLayeringTests: XCTestCase {

    /// 包根目录（`Tests/SelectedCoreTests/X.swift` 上溯 3 层）
    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)          // .../SelectedApp/Tests/SelectedCoreTests/CoreLayeringTests.swift
            .deletingLastPathComponent()         // .../Tests/SelectedCoreTests
            .deletingLastPathComponent()         // .../Tests
            .deletingLastPathComponent()         // .../SelectedApp
    }

    /// Core 允许的 import 只有 `Foundation` / `SQLite3`（外加各文件的空行）。
    /// `Observation` 也在禁列：`@Observable` 是**界面状态**用的宏，Core 里出现它
    /// 通常意味着某个 UI 配置类放错了层。
    ///
    /// `Combine` / `Network` 也在禁列：两者在 Core 里都**当前 0 处使用**
    ///   （实测 import 清单只有 Foundation / SQLite3），而它们各自意味着一种明确的
    ///   越界形态 —— `Combine` 是被 Swift 并发取代的旧通路，
    ///   `Network` 意味着绕过 `HTTPFetch` 直连（限速/失败上报/状态码校验全都会丢）。
    ///   **刻意不列** `os` / `CryptoKit`：它们是"日志分级"与"哈希"这两件**非 UI 事**的
    ///   合理选项（本项目现在用 NSLog + 级别前缀，将来若要迁 `os.Logger` 不该被这条挡住）——
    ///   禁列的判据是"越界形态明确"，不是"用不到就禁"。
    private let bannedImports = ["SwiftUI", "AppKit", "Cocoa", "Observation", "Charts", "UserNotifications",
                                 "Combine", "Network"]

    /// `@MainActor` 白名单，精确到「**文件:符号**」。
    ///
    /// ## 为什么需要
    /// `SelectedCore` **没有** `defaultIsolation`（那是 UI target 的设置）⇒ Core 里的
    /// `@MainActor` 全部是**手写的刻意标注**，它们就是「`SQLiteReader.shared` 只能在主线程用」
    /// 这条契约的编译期载体（6 处注释依赖它）。但**误加**一个同样编译合法：
    /// 在 Core 里给某个类型/函数标上 `@MainActor` 不会报错，只在运行时才炸
    /// （后台任务碰它 → 隔离契约失效）。⇒ 白名单 + 集合相等断言：
    /// **任何新增都必须同时改这里**，而改这里就得先回答"它真的必须在主线程吗"。
    ///
    /// 用「文件:符号」不用行号（行号会漂）。
    private let mainActorAllowlist: Set<String> = [
        // 主线程专用共享连接 —— `@MainActor` 就是这条契约本身
        "SQLiteReader.swift:let shared",
        // 整段收口：读方法全走 SQLiteReader.shared
        "IndexMembersStore.swift:extension IndexMembersStore",
        // 类级收口：诊断页的读全部在主线程（Store 层持有）
        "DataSourceLogStore.swift:class DataSourceLogStore",
        // 逐个方法标注（该文件注释里写明了"新加读方法时记得自己带上 @MainActor"）
        "FundamentalStore.swift:func fundamentals",
        "FundamentalStore.swift:func total",
        "FundamentalStore.swift:func withDataCount",
        "FundamentalStore.swift:func lastFetched",
    ]

    /// 从 `@MainActor` 后面的声明抽"符号指纹"：
    /// `extension X` / `class X` / `struct X` / `enum X` / `func name` / `let name` / `var name`
    private static func symbolFingerprint(from decl: String) -> String {
        let modifiers: Set<String> = ["public", "private", "internal", "fileprivate", "open", "final", "static"]
        let tokens = decl.split(separator: " ").map(String.init)
        guard let kw = tokens.first(where: { !modifiers.contains($0) }) else { return decl }
        let name: String? = {
            guard let i = tokens.firstIndex(of: kw), i + 1 < tokens.count else { return nil }
            let raw = tokens[i + 1]
            if kw == "func" { return raw.split(separator: "(").first.map(String.init) }
            return raw.replacingOccurrences(of: "{", with: "")
        }()
        switch kw {
        case "extension", "class", "struct", "enum", "actor", "protocol": return name.map { "\(kw) \($0)" } ?? kw
        case "func": return name.map { "func \($0)" } ?? kw
        case "let", "var": return name.map { "\(kw) \($0)" } ?? kw
        default: return kw
        }
    }

    func testCoreMainActorUsageIsExplicitlyAllowlisted() throws {
        let dir = packageRoot.appendingPathComponent("Sources/SelectedCore")
        let files = try swiftFiles(in: dir)
        XCTAssertGreaterThan(files.count, 20, "SelectedCore 源码文件数异常（\(files.count)）—— 路径可能不对")

        var found: Set<String> = []
        for f in files {
            let lines = ((try? String(contentsOf: f, encoding: .utf8)) ?? "")
                .split(separator: "\n", omittingEmptySubsequences: false)
            for (i, raw) in lines.enumerated() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                // 只认**注解本身**：注释里提到 `@MainActor`（本项目有 20 多处）不算
                guard line.hasPrefix("@MainActor") else { continue }
                var decl = line.replacingOccurrences(of: "@MainActor", with: "")
                    .trimmingCharacters(in: .whitespaces)
                if decl.isEmpty {
                    // 独立成行的注解 → 取后续第一个非空、非注释行
                    var j = i + 1
                    while j < lines.count {
                        let t = lines[j].trimmingCharacters(in: .whitespaces)
                        if t.isEmpty || t.hasPrefix("//") { j += 1; continue }
                        decl = t
                        break
                    }
                }
                found.insert("\(f.lastPathComponent):\(Self.symbolFingerprint(from: decl))")
            }
        }

        let unexpected = found.subtracting(mainActorAllowlist)
        let missing = mainActorAllowlist.subtracting(found)
        XCTAssertTrue(unexpected.isEmpty && missing.isEmpty,
                      """
                      SelectedCore 的 @MainActor 用法与白名单不一致 ——
                      ⚠ 新增的（先回答"它真的必须在主线程吗"，是则加进白名单并写明理由）：
                      \(unexpected.sorted().map { "  + \($0)" }.joined(separator: "\n"))
                      ⚠ 白名单里已失效的（删掉对应条目，别留着）：
                      \(missing.sorted().map { "  - \($0)" }.joined(separator: "\n"))
                      """)
    }

    private func swiftFiles(in dir: URL) throws -> [URL] {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        return e.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    func testDirectoryLayout() throws {
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: packageRoot.appendingPathComponent("Package.swift").path),
                      "定位到的包根不对：\(packageRoot.path)")
        for sub in ["Sources/SelectedCore", "Sources/SelectedApp/Views", "Tests/SelectedCoreTests"] {
            var isDir: ObjCBool = false
            let p = packageRoot.appendingPathComponent(sub).path
            XCTAssertTrue(fm.fileExists(atPath: p, isDirectory: &isDir) && isDir.boolValue,
                          "缺目录 \(sub)")
        }
        // 旧目录不许复活（复活 = 有人把文件加回被 SPM 忽略的路径，编译不到但也不报错）
        XCTAssertFalse(fm.fileExists(atPath: packageRoot.appendingPathComponent("Sources/Selected").path),
                       "Sources/Selected 已废弃（C1 拆分），文件请放 SelectedCore / SelectedApp")
    }

    func testCoreHasNoUIFrameworkImports() throws {
        let dir = packageRoot.appendingPathComponent("Sources/SelectedCore")
        let files = try swiftFiles(in: dir)
        XCTAssertGreaterThan(files.count, 20, "SelectedCore 源码文件数异常（\(files.count)）—— 路径可能不对")

        var offenders: [String] = []
        for f in files {
            let text = (try? String(contentsOf: f, encoding: .utf8)) ?? ""
            for line in text.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix("import ") else { continue }
                let module = t.dropFirst("import ".count).trimmingCharacters(in: .whitespaces)
                if bannedImports.contains(module) {
                    offenders.append("\(f.lastPathComponent): \(t)")
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty,
                      "SelectedCore 不允许依赖 UI 框架，实得：\n" + offenders.joined(separator: "\n"))
    }

    /// 反向：UI 层必须真的在 `SelectedApp`（而不是把视图藏进 Core）
    func testUIFrameworkImportsLiveInAppLayer() throws {
        let files = try swiftFiles(in: packageRoot.appendingPathComponent("Sources/SelectedApp"))
        XCTAssertGreaterThan(files.count, 10, "SelectedApp 源码文件数异常（\(files.count)）")
        let hasSwiftUI = files.contains { f in
            ((try? String(contentsOf: f, encoding: .utf8)) ?? "").contains("import SwiftUI")
        }
        XCTAssertTrue(hasSwiftUI, "SelectedApp 里一个 import SwiftUI 都没有 —— 分层可能被搞反了")
    }
}
