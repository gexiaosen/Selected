// swift-tools-version:6.0
import PackageDescription

/// ThinkingOrbs —— 上游源码的**本地 vendor 拷贝**（来源见 README.md）。
///
/// 为什么不是远程依赖：本项目定位「运行期零外部依赖」，第三方代码只以本地包形式存在
/// （另一处先例是 `../swift-trading-view`）。决策记录见
/// `docs/specs/README.md`。
///
/// 与上游 `Package.swift` 的差异：**去掉了 testTarget** —— 上游测试依赖 611KB 的
/// `orbs-golden.json` 与截图工具，本项目不需要（也不改动上游几何）。
let package = Package(
    name: "ThinkingOrbs",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ThinkingOrbs", targets: ["ThinkingOrbs"]),
    ],
    targets: [
        .target(name: "ThinkingOrbs"),
    ]
)