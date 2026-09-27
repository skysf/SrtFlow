import Foundation
import SrtFlowMCPKit

// MARK: - App 这一头的通道：收 srtflow-mcp 转来的工具调用
//
// 管什么：App 启动时在自己的 Unix socket 上听（路径按 bundle id 算，见 `MCPBridge.socketPath`）；
// 每条连接读一行请求、交给主线程上的 `AIToolRouter`、把结果写回去。
// 不管什么：调用怎么分派（AIToolRouter）。
//
// **线程**：听和收发都是阻塞调用，放在自己开的 `Thread` 上 —— 不许进 Swift 并发的协作线程池
// （docs/architecture/blocking-media-reads.md 同一个道理）。那条线程用信号量等主线程做完，
// 它本来就是专门等这一件事的，等着不碍事。
// **安全**：socket 所在的目录只有这个用户能进、socket 本身 0600，连进来的再核一次用户号。

final class AIBridgeServer: @unchecked Sendable {
    static let shared = AIBridgeServer()

    private let lock = NSLock()
    private var socketPath: String?

    private init() {}

    /// App 启动时调一次（重复调是空操作）。
    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard socketPath == nil else { return }
        let bundleID = Bundle.main.bundleIdentifier ?? "com.srtflow.SrtFlow"
        let path = MCPBridge.socketPath(bundleIdentifier: bundleID)
        do {
            let fd = try MCPUnixSocket.listen(path: path)
            socketPath = path
            let thread = Thread { [weak self] in self?.acceptLoop(fd) }
            thread.name = "SrtFlow AI bridge"
            thread.start()
        } catch {
            // 听不起来（比如同一个 App 开了两份）：AI 连不上而已，App 其余功能照常。
            FileHandle.standardError.write(Data("SrtFlow AI bridge: \(error)\n".utf8))
        }
    }

    /// 退出时删掉 socket 文件（不删也不要紧：下次启动会先删旧的，小程序连不上会去拉起 App）。
    func stop() {
        lock.lock()
        defer { lock.unlock() }
        if let socketPath { unlink(socketPath) }
        socketPath = nil
    }

    private func acceptLoop(_ fd: Int32) {
        while let client = MCPUnixSocket.accept(fd) {
            guard MCPUnixSocket.peerIsSameUser(client) else {
                close(client)
                continue
            }
            let thread = Thread { [weak self] in self?.serve(client) }
            thread.name = "SrtFlow AI call"
            thread.start()
        }
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        MCPUnixSocket.setTimeouts(fd, seconds: 120)
        guard let line = try? MCPUnixSocket.readLine(fd) else { return }
        let response: MCPBridge.Response
        if let request = try? JSONDecoder().decode(MCPBridge.Request.self, from: line) {
            let result = waitForMainActor { await AIToolRouter.shared.handle(request) }
            response = MCPBridge.Response(id: request.id, result: result)
        } else {
            response = MCPBridge.Response(id: "", result: MCPBridge.textResult(
                "SrtFlow could not read the request from its AI helper. Ask the user to restart the AI app.",
                isError: true
            ))
        }
        guard let data = try? JSONEncoder().encode(response) else { return }
        try? MCPUnixSocket.writeLine(fd, data)
    }

    /// 在这条专用线程上等主线程把活做完。
    private func waitForMainActor(_ work: @escaping @MainActor () async -> JSONValue) -> JSONValue {
        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        Task { @MainActor in
            box.value = await work()
            done.signal()
        }
        done.wait()
        return box.value ?? MCPBridge.textResult("SrtFlow did not finish the call.", isError: true)
    }
}

private final class ResultBox: @unchecked Sendable {
    var value: JSONValue?
}
