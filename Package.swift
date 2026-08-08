// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SrtFlow",
    defaultLocalization: "en",
    platforms: [
        // 录屏用 ScreenCaptureKit，最低系统提升到 macOS 15。
        // 写字符串 "15.0" 而不是 .v15：PackageDescription 5.9 还没有 .v15 枚举，
        // 用它会把包描述连带升到 tools 6.0，白白扩大编译迁移面。
        .macOS("15.0")
    ],
    products: [
        .library(name: "SrtFlowCore", targets: ["SrtFlowCore"]),
        .executable(name: "SrtFlow", targets: ["SrtFlow"])
    ],
    targets: [
        .target(name: "SrtFlowCore"),
        .executableTarget(
            name: "SrtFlow",
            dependencies: ["SrtFlowCore"],
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "SrtFlowCoreChecks",
            dependencies: ["SrtFlowCore"]
        )
    ]
)
