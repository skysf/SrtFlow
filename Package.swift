// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SrtFlow",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
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
