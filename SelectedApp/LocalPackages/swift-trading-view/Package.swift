// swift-tools-version:6.2

import PackageDescription

let package = Package(
    name: "swift-trading-view",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v12),
        // ⚠⚠ 2026-10-12（CI 首跑红的修复）：原声明 `.v10_13` 是**假的** ——
        //   本包 SwiftUI 代码用 `Canvas` / `Grid`（均 macOS 13+）与 `Color`/`Font`（10.15+）。
        //   本机 Xcode 27 SDK 不报这些可用性错误，但 Swift 6.3.3（GitHub macos-26 runner）
        //   按 SDK 标注严格报错 ⇒ `swift build` 在 CI 上直接挂（run 38237071110：
        //   "'Color' is only available in macOS 10.15 or newer" × 几十处）。
        //   ⇒ 声明改成真实底档 13.0。其余平台保持原样（本仓只构建 macOS 产物）。
        .macOS(.v13),
        .watchOS(.v4),
        .tvOS(.v12),
        .visionOS(.v1)
    ],
    products: [
        .library(
            name: "SwiftTradingView",
            targets: ["SwiftTradingView"]
        ),
        .library(
            name: "SwiftTA",
            targets: ["SwiftTA"]
        ),
        .library(
            name: "TALib",
            targets: ["TALib"]
        )
    ],
    targets: [
        .target(
            name: "SwiftTradingView",
            dependencies: [
                "SwiftTA"
            ],
            path: "Sources/SwiftTradingView"
        ),
        .target(
            name: "SwiftTA",
            dependencies: [
                "TALib"
            ],
            path: "Sources/SwiftTA"
        ),
        .target(
            name: "TALib",
            path: "Sources/ta-lib",
            sources: [
                "src/ta_func/ta_stubs.c"
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include")
                // ⚠⚠ 2026-10-06（审计 P0-07）：原先这里有 5 个
                //   `TA_LIB_VERSION_{MAJOR,MINOR,BUILD,EXTRA,FULL}` define，
                //   声称本目录是「TA-Lib 0.6.0-dev」。**已删除**，原因有三：
                //   ① **零引用** —— 全仓（含 C 源码与 Swift）无任何代码读这些宏；
                //   ② **是伪造的** —— 本目录**不是** TA-Lib 上游源码，而是自实现的最小版本
                //      （7 个签名里只有 `TA_MA` 是真实现），版本号无从谈起；
                //   ③ **比没有更糟** —— 上游真实版本已到 0.6.4，声称「0.6.0-dev」会让
                //      后来人误判本目录的代码基线（而 `THIRD-PARTY-NOTICE.md` 写明了真相）。
                //   ⇒ 保留 `.headerSearchPath`（那是编译必需的），只删版本 define。
                //   真实出处与许可见 `Sources/ta-lib/THIRD-PARTY-NOTICE.md`。
            ]
        )
    ]
)
