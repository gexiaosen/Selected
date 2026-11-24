// swift-tools-version:6.2
import PackageDescription

/// 分层（2026-09-21，后续计划 C1）
///
/// 为什么要拆：
///   1. **消掉"源码子集清单"陷阱** —— 原先 `Tools/*.sh` 要为每个测试手工列出要编译哪几个
///      `.swift`，新增共享文件漏补就会让十几个套件同时编译失败（审计中踩过两次），
///      且子集内的文件必须零依赖。拆成 library 后 `swift test` 直接 `@testable import`，
///      清单消失。
///   2. **拿到 testTarget** —— 纯 Swift 自检不再需要 `.sh` + `swiftc` 手写清单。
///   3. **编译期分层约束** —— `SelectedCore` 不可能反向依赖 UI。
///
/// 边界：
///   · `SelectedCore` = 引擎 + 数据层（不含任何 SwiftUI / AppKit 视图）
///   · `Selected`     = SwiftUI 应用（Views + Store + Scheduler + App 入口）
///   · `Store` / `Scheduler` 留在 App 层：`Scheduler` 需要读 `Store.shared.hasBusyWriteCommand`
///     （跨层反向依赖），且两者都被 Views 直接使用 —— 放进 Core 会让它们的所有成员
///     都要 `public`，收益不抵成本
let package = Package(
    name: "Selected",
    // ⚠⚠ 最低版本 = **macOS 26**（2026-09-24 决策，见 docs/specs/README.md）。
    //
    // 为什么提到 26（放弃老系统兼容）：
    //   ① 卡片表面可以**无条件**走 Liquid Glass —— 原先 `Views/Components.swift` 里
    //      有一条 `#available(macOS 26.0, *)` 回退分支（`.background.secondary.opacity(…)`
    //      + `strokeBorder`），现在整条删掉；
    //   ② 后续界面改造可以直接用 26+ API（`ToolbarSpacer` / `@Animatable` /
    //      `presentationSizing` …），不必再写降级分支。
    //
    // ⚠ 代价（**不可逆**）：放弃 macOS 15 及以下**全部装机量** —— 已作为一笔债登记在
    //   `docs/specs/README.md` 的「分发前」清单里。
    // ⚠ 配套：`Resources/Info.plist` 的 `LSMinimumSystemVersion` 必须同步为 26.0
    //   —— 漏改的后果不是崩溃，而是老系统上系统**直接拒绝启动**（"此 App 需要 macOS 26"）。
    // ⚠ 依赖包声明更低平台是**合法**的（`ThinkingOrbs` = .v14 / `swift-trading-view` = .v13；
    //    它 2026-10-12 前谎报 .v10_13，实际代码用 Canvas/Grid ⇒ Swift 6.3.3 的 CI 直接编译失败，已修为真实底档 13.0），
    //   不需要跟着改；只有"依赖要求高于主包"才是错误。
    // ⚠ `.macOS(.v26)` 需要 **`swift-tools-version:6.2`** —— `MacOSVersion.v26` 标着
    //   `@available(_PackageDescription 6.2)`，tools 6.0 下编译 manifest 会直接报
    //   `error: 'v26' is unavailable`（2026-09-24 实测）。这就是本文件首行从 6.0 升到 6.2
    //   的**第一个原因**（第二个是 `defaultIsolation`，见 `Selected` target 的 `swiftSettings`）。
    //   工具链需 **Xcode 26+**（本机 Xcode 27.0 / Swift 6.4 实测可用）。
    platforms: [.macOS(.v26)],
    dependencies: [
        // 本地金融图表库（K线/分时图，从 StockWatch 项目引入，无网络依赖）
        .package(path: "LocalPackages/swift-trading-view"),
        // 本地 vendor 的点阵加载指示库（长任务等待期的动效，无网络依赖）
        // ⚠ 只给 `Selected`（UI 层）用：`SelectedCore` 不许依赖它 —— 由静态护栏钉死
        //   （engine/tests/run_all.sh 的 `orb_layering`）
        .package(path: "LocalPackages/ThinkingOrbs"),
        // 自动更新框架。Sparkle 2 对无 Apple Developer ID 的分发是官方支持的：
        // 更新包经 EdDSA 通道校验即可安装，所以 ad-hoc / Apple Development 签名的包
        // 也能正常自动更新（详见 `docs/功能说明.md` 的「自动更新」一节）。
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1")
    ],
    targets: [
        // 引擎 + 数据层（无 UI 依赖）
        .target(
            name: "SelectedCore",
            path: "Sources/SelectedCore"
        ),
        // SwiftUI macOS 应用
        //
        // ⚠ `defaultIsolation(MainActor.self)`（2026-09-24，需 tools 6.2）：
        //   让**整个 UI target 默认 MainActor 隔离** ⇒「忘了标 `@MainActor`」这一类风险
        //   从"靠 68 处手写标注维持"变成**默认安全**（漏标不再可能）。
        //   ⚠ **只给 UI 层加**：`SelectedCore` 是纯计算层，必须能在后台跑。
        //   ⚠ 代价：故意要跑在后台的类型/函数必须**显式 `nonisolated`** —— 本 target
        //     目前只有 2 处（`Notifier` 的 notification delegate / `Components` 的
        //     PreferenceKey `defaultValue`），已显式标注。
        //   ⚠ 后台任务走 `Task.detached`（27 处）—— detached **不继承** actor 隔离，
        //     所以它们的闭包体不受本设置影响。
        //   见 docs/specs/README.md。
        .executableTarget(
            name: "Selected",
            dependencies: [
                "SelectedCore",
                .product(name: "SwiftTradingView", package: "swift-trading-view"),
                .product(name: "ThinkingOrbs", package: "ThinkingOrbs"),
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/SelectedApp",
            swiftSettings: [.defaultIsolation(MainActor.self)],
            // Sparkle.framework 进 .app 时放在 `Contents/Frameworks/`（由 build_app.sh 拷贝），
            // 主二进制默认只带 `@loader_path`（MacOS/）⇒ 补这条才能在组装好的 .app 里找到 framework。
            // ⚠ `unsafeFlags` 会限制本包不能被下游依赖 —— 终态应用无妨。
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@loader_path/../Frameworks"]),
            ]
        ),
        // 纯 Swift 侧自检（只依赖 Core，不需要 Python）
        .testTarget(
            name: "SelectedCoreTests",
            dependencies: [
                "SelectedCore",
                .product(name: "SwiftTradingView", package: "swift-trading-view")
            ],
            path: "Tests/SelectedCoreTests",
            // 夹具是**数据文件**不是资源：测试用 `#filePath` 从源码树读（与 `EntityTestSupport` 一致），
            // 不打进 bundle。不显式排除的话 SPM 会警告 "unhandled file"。
            exclude: ["Fixtures"]
        ),
        // App 层状态与视图纯逻辑回归（覆盖 ParamEditorState、IndicatorScreenerView 格式化等）
        .testTarget(
            name: "SelectedAppTests",
            dependencies: [
                "Selected",
                "SelectedCore",
                .product(name: "SwiftTradingView", package: "swift-trading-view"),
                .product(name: "ThinkingOrbs", package: "ThinkingOrbs")
            ],
            path: "Tests/SelectedAppTests"
        )
    ]
)
