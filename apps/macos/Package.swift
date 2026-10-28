// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Nowbeam",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "NowbeamCore", targets: ["NowbeamCore"]),
        .library(name: "NowbeamCapture", targets: ["NowbeamCapture"]),
        .executable(name: "Nowbeam", targets: ["NowbeamApp"]),
    ],
    targets: [
        .target(name: "NowbeamCore", exclude: ["AGENTS.md"]),
        .target(name: "NowbeamCapture", dependencies: ["NowbeamCore"], exclude: ["AGENTS.md"]),
        // 部署目标仍是 macOS 15，但 SwiftPM 会把 LC_BUILD_VERSION 的 sdk 一并写成 15.0；系统只给“链接到 macOS 26 SDK”
        // 的应用套用 Liquid Glass 窗口外壳（悬浮侧栏、工具栏玻璃），所以这里如实声明用 26 SDK 构建。
        // 本目标使用 glassEffect 等 26 SDK API，能编译即意味着 SDK 不低于 26。
        .executableTarget(
            name: "NowbeamApp", dependencies: ["NowbeamCore", "NowbeamCapture"], exclude: ["AGENTS.md"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-platform_version", "-Xlinker", "macos", "-Xlinker", "15.0", "-Xlinker", "26.0"])]
        ),
        .testTarget(name: "NowbeamCoreTests", dependencies: ["NowbeamCore"], exclude: ["AGENTS.md"]),
        .testTarget(name: "NowbeamCaptureTests", dependencies: ["NowbeamCapture", "NowbeamCore"], exclude: ["AGENTS.md"]),
    ],
    swiftLanguageModes: [.v6]
)
