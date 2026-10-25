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
        .executableTarget(name: "NowbeamApp", dependencies: ["NowbeamCore", "NowbeamCapture"], exclude: ["AGENTS.md"]),
        .testTarget(name: "NowbeamCoreTests", dependencies: ["NowbeamCore"], exclude: ["AGENTS.md"]),
        .testTarget(name: "NowbeamCaptureTests", dependencies: ["NowbeamCapture", "NowbeamCore"], exclude: ["AGENTS.md"]),
    ],
    swiftLanguageModes: [.v6]
)
