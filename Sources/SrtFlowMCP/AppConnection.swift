import Foundation
import SrtFlowMCPKit

// MARK: - 找到 SrtFlow、把一次工具调用交给它
//
// 管什么：小程序在哪个 App 里（从自己的路径往上找 .app）、那个 App 的 socket 在哪、
// 没开就用 `open -g` 把它拉起来（不抢前台）、等它开始听、把请求交过去、把回答拿回来。
// 不管什么：MCP 协议（MCPServerCore）、工具怎么做（App）。
//
// 测试用的四个环境变量（不设就完全不生效）：
// - SRTFLOW_MCP_SOCKET：直接连这个 socket（自检里的假 App）；
// - SRTFLOW_MCP_NO_LAUNCH：连不上就报错，不去拉起 App；
// - SRTFLOW_MCP_APP：App 的路径（小程序不在 .app 里、从 .build 直接跑的时候）；
// - SRTFLOW_MCP_PROVIDERS：「配了哪些生成提供方」那个小文件的路径（自检里造一个临时的）。

struct AppConnection {
    let appURL: URL?
    let bundleIdentifier: String
    let socketPath: String
    /// 配好了哪些生成提供方（App 在 fal 的 Key 添加 / 删除时写的小文件，MCPProviderMarker）。
    let providersURL: URL
    let appVersion: String
    let mayLaunch: Bool

    /// 从小程序自己的位置找到它所在的 App：`X.app/Contents/Helpers/srtflow-mcp`。
    static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) -> AppConnection {
        let appURL = environment["SRTFLOW_MCP_APP"].map { URL(fileURLWithPath: $0) } ?? enclosingApp()
        let bundle = appURL.flatMap { Bundle(url: $0) }
        let bundleID = bundle?.bundleIdentifier ?? "com.srtflow.SrtFlow"
        let version = bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return AppConnection(
            appURL: appURL,
            bundleIdentifier: bundleID,
            socketPath: environment["SRTFLOW_MCP_SOCKET"] ?? MCPBridge.socketPath(bundleIdentifier: bundleID),
            providersURL: environment["SRTFLOW_MCP_PROVIDERS"].map { URL(fileURLWithPath: $0) }
                ?? MCPProviderMarker.url(bundleIdentifier: bundleID),
            appVersion: version,
            mayLaunch: environment["SRTFLOW_MCP_NO_LAUNCH"] == nil
        )
    }

    private static func enclosingApp() -> URL? {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
        var url = executable.deletingLastPathComponent()
        // 最多往上找四层：Helpers → Contents → X.app。
        for _ in 0..<4 {
            if url.pathExtension == "app" { return url }
            url = url.deletingLastPathComponent()
        }
        return nil
    }

    // MARK: 一次调用

    func call(tool: String, arguments: JSONValue, client: String?) -> JSONValue {
        let request = MCPBridge.Request(tool: tool, arguments: arguments, client: client)
        do {
            let payload = try JSONEncoder().encode(request)
            let fd = try connectOrLaunch()
            defer { close(fd) }
            MCPUnixSocket.setTimeouts(fd, seconds: 120)
            try MCPUnixSocket.writeLine(fd, payload)
            guard let line = try MCPUnixSocket.readLine(fd) else {
                return MCPBridge.textResult(
                    "SrtFlow closed the connection without answering (it may have quit). Try again.", isError: true
                )
            }
            return try JSONDecoder().decode(MCPBridge.Response.self, from: line).result
        } catch let failure as ConnectionFailure {
            return MCPBridge.textResult(failure.message, isError: true)
        } catch {
            return MCPBridge.textResult("Could not talk to SrtFlow: \(error)", isError: true)
        }
    }

    private struct ConnectionFailure: Error {
        let message: String
    }

    /// 连上正在跑的 SrtFlow；没开就拉起来再连。
    private func connectOrLaunch() throws -> Int32 {
        if let fd = try? MCPUnixSocket.connect(path: socketPath) { return fd }
        guard mayLaunch else {
            throw ConnectionFailure(message: "SrtFlow is not running. Ask the user to open SrtFlow.")
        }
        try launchApp()
        // 冷启动要把 SwiftUI 窗口和引擎都拉起来，给足时间；一般两三秒就开始听了。
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.3)
            if let fd = try? MCPUnixSocket.connect(path: socketPath) { return fd }
        }
        throw ConnectionFailure(message: """
            SrtFlow did not start answering within 45 seconds. If an older SrtFlow without AI support is open, \
            ask the user to quit it; otherwise ask them to open SrtFlow and try again.
            """)
    }

    /// `open -g`：在后台启动，不把用户正在打字的对话窗口挤下去。窗口由 App 自己在
    /// 开始剪的时候摆到前面来（不抢键盘，`AIEditorPresenter`）。
    private func launchApp() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        if let appURL {
            process.arguments = ["-g", "-a", appURL.path]
        } else {
            process.arguments = ["-g", "-b", bundleIdentifier]
        }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw ConnectionFailure(message: "Could not start SrtFlow: \(error.localizedDescription)")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ConnectionFailure(message: "Could not start SrtFlow (open exited with \(process.terminationStatus)).")
        }
    }
}
