import Foundation
import SrtFlowMCPKit

// MARK: - srtflow-mcp：AI 客户端启动的那个小程序
//
// Claude、Codex 这些客户端按配置把它当子进程启动，从它的 stdin 写 MCP 消息、从 stdout 读回答
// （一行一条 JSON）。它自己几乎什么都不做：握手和工具清单当场回，工具调用转给正在运行的
// SrtFlow（没开就拉起来）。架构见 docs/architecture/ai-control-mcp.md。
//
// **stdout 只许写 MCP 消息**：任何调试输出都会被客户端当成坏消息。要打日志写 stderr。

signal(SIGPIPE, SIG_IGN)

let connection = AppConnection.locate()
let providersURL = connection.providersURL
// 清单每回一次都重读那个小文件：用户中途添加 / 删掉 fal 的 Key，下一次就跟着变（方案第 36 条：没配就不列出来）。
let core = MCPServerCore(serverVersion: connection.appVersion, providers: { MCPProviderMarker.read(at: providersURL) })
let outputLock = NSLock()
let inFlight = DispatchGroup()
let callQueue = DispatchQueue(label: "srtflow-mcp.calls", attributes: .concurrent)

/// 写一条消息到 stdout。多条工具调用同时回来时要排队写，一行不许被另一行插进来。
func send(_ message: JSONValue) {
    guard var data = try? message.encodedData() else { return }
    data.append(0x0A)
    outputLock.lock()
    FileHandle.standardOutput.write(data)
    outputLock.unlock()
}

/// 配好的提供方变了：握过手的（老一代）客户端主动告诉它清单变了，它会重新要一遍；
/// 新一代客户端没有会话，靠清单上的缓存时间（`MCPServerCore.toolListTTLms`）。
Thread.detachNewThread {
    var last = MCPProviderMarker.read(at: providersURL)
    while true {
        Thread.sleep(forTimeInterval: 2)
        let now = MCPProviderMarker.read(at: providersURL)
        guard now != last else { continue }
        last = now
        if core.hasLegacySession { send(MCPServerCore.toolListChangedNotification) }
    }
}

/// 处理一条消息；工具调用放到后台去问 App，别的当场回。返回当场能给的回答（批量请求要攒起来）。
func process(_ message: JSONValue, waitForTools: Bool) -> JSONValue? {
    switch core.handle(message) {
    case .reply(let reply):
        return reply
    case .none:
        return nil
    case .callTool(let call):
        if waitForTools {
            let result = connection.call(tool: call.name.rawValue, arguments: call.arguments, client: call.client)
            return core.toolCallResponse(for: call, result: result)
        }
        inFlight.enter()
        callQueue.async {
            let result = connection.call(tool: call.name.rawValue, arguments: call.arguments, client: call.client)
            send(core.toolCallResponse(for: call, result: result))
            inFlight.leave()
        }
        return nil
    }
}

while let line = readLine(strippingNewline: true) {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { continue }
    guard let data = trimmed.data(using: .utf8), let message = try? JSONValue.decode(data) else {
        send(MCPServerCore.error(id: .null, code: -32700, message: "Parse error"))
        continue
    }
    if case .array(let batch) = message {
        // 老版本协议允许一次发一批。少见，按顺序一条条做完再一起回。
        let replies = batch.compactMap { process($0, waitForTools: true) }
        if !replies.isEmpty { send(.array(replies)) }
    } else if let reply = process(message, waitForTools: false) {
        send(reply)
    }
}

// 客户端关了 stdin：把还在路上的调用做完再退，免得 App 做完了、回答却没人收。
_ = inFlight.wait(timeout: .now() + 120)
