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
        .executable(name: "SrtFlow", targets: ["SrtFlow"]),
        // 给 AI 客户端（Claude、Codex……）启动的 MCP 小程序，打包时放进
        // SrtFlow.app/Contents/Helpers/。它只传话，活都在 App 里做
        //（docs/architecture/ai-control-mcp.md）。
        .executable(name: "srtflow-mcp", targets: ["SrtFlowMCP"])
    ],
    targets: [
        .target(name: "SrtFlowCore"),
        // MCP 的消息格式、工具清单、和 App 之间的本机通道。小程序和 App 两边都用它，
        // 所以工具清单只有这一份。只依赖 Foundation。
        .target(name: "SrtFlowMCPKit"),
        // 本机配音用的 Kokoro-82M（CoreML）：注音、推理外壳，从 speech-swift（Apache 2.0）搬来改过，
        // 署名见 Sources/SrtFlow/Resources/THIRD-PARTY-NOTICES.md（随 App 分发）。只依赖系统框架；模型本身不在包里，App 从我们的 R2 下载
        //（docs/plans/2026-09-27-mcp.md 第 44、48、51 条）。
        .target(name: "SrtFlowKokoro"),
        .executableTarget(
            name: "SrtFlow",
            dependencies: ["SrtFlowCore", "SrtFlowMCPKit", "SrtFlowKokoro"],
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "SrtFlowMCP",
            dependencies: ["SrtFlowMCPKit"]
        ),
        .executableTarget(
            name: "SrtFlowCoreChecks",
            dependencies: ["SrtFlowCore"]
        )
    ]
)
