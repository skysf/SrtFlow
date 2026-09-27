import Foundation
import SrtFlowMCPKit

// 小程序（srtflow-mcp）说的 MCP 对不对：真的把它当子进程起起来，从 stdin 喂消息、读 stdout，
// 旁边起一个假 App 在临时 socket 上听，看工具调用有没有原样转过去、回答有没有原样回来。
// 两代客户端都要验：老的先 initialize，新的（2026-07-28）每个请求自带 _meta 版本。

/// 「看」回的图有几百 KB：通道一行就是一条消息，大图要原样穿过去（socket 一次只读 64KB，小程序的 stdout 一行写完）。
let bigPicture = Data((0..<450_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }).base64EncodedString()

/// 假 App：收到什么工具就回「echo:工具名」（look 另外带一张大图），并记下每次调用报的客户端名字。
final class FakeApp: @unchecked Sendable {
    let path: String
    private let lock = NSLock()
    private var seen: [MCPBridge.Request] = []

    init() throws {
        path = NSTemporaryDirectory() + "srtflow-mcp-check-\(getpid()).sock"
        let fd = try MCPUnixSocket.listen(path: path)
        Thread { [weak self] in
            while let client = MCPUnixSocket.accept(fd) {
                guard let line = try? MCPUnixSocket.readLine(client),
                      let request = try? JSONDecoder().decode(MCPBridge.Request.self, from: line) else {
                    close(client)
                    continue
                }
                self?.record(request)
                var result = MCPBridge.textResult("echo:\(request.tool)")
                if request.tool == "look" {
                    result = ["content": [["type": "text", "text": "looked"],
                                          ["type": "image", "data": .string(bigPicture), "mimeType": "image/jpeg"]],
                              "isError": false]
                }
                let response = MCPBridge.Response(id: request.id, result: result)
                if let data = try? JSONEncoder().encode(response) { try? MCPUnixSocket.writeLine(client, data) }
                close(client)
            }
        }.start()
    }

    private func record(_ request: MCPBridge.Request) {
        lock.lock()
        seen.append(request)
        lock.unlock()
    }

    var requests: [MCPBridge.Request] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }
}

/// 起一次小程序，喂这几行，读回所有回答（按行）。原始文本也一并返回（验 id 的写法）。
func talkToHelper(_ lines: [String], socket: String) -> (messages: [JSONValue], raw: String) {
    guard let helper = ProcessInfo.processInfo.environment["SRTFLOW_MCP_HELPER"] else {
        check(false, "SRTFLOW_MCP_HELPER is not set (scripts/check-mcp.sh sets it)")
        return ([], "")
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: helper)
    var environment = ProcessInfo.processInfo.environment
    environment["SRTFLOW_MCP_SOCKET"] = socket
    environment["SRTFLOW_MCP_NO_LAUNCH"] = "1"
    process.environment = environment
    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    do {
        try process.run()
    } catch {
        check(false, "could not start the helper: \(error)")
        return ([], "")
    }
    input.fileHandleForWriting.write(Data((lines.joined(separator: "\n") + "\n").utf8))
    try? input.fileHandleForWriting.close()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let raw = String(data: data, encoding: .utf8) ?? ""
    let messages = raw.split(separator: "\n").compactMap { try? JSONValue.decode(Data($0.utf8)) }
    return (messages, raw)
}

func reply(_ messages: [JSONValue], id: JSONValue) -> JSONValue? {
    messages.first { $0["id"] == id }
}

func runProtocolChecks() {
    let app: FakeApp
    do { app = try FakeApp() } catch {
        check(false, "fake app could not listen: \(error)")
        return
    }
    let legacy = [
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"check-client","version":"1"}}}"#,
        #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
        #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
        #"{"jsonrpc":"2.0","id":"abc","method":"tools/call","params":{"name":"get_status","arguments":{}}}"#,
        #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"no_such_tool","arguments":{}}}"#,
        #"{"jsonrpc":"2.0","id":5,"method":"no/such/method"}"#,
        #"not json"#,
        #"{"jsonrpc":"2.0","id":7,"method":"ping"}"#
    ]
    let (messages, raw) = talkToHelper(legacy, socket: app.path)

    // 1. 握手：照回客户端要的版本、带服务名和总说明。
    let initialize = reply(messages, id: 1)?["result"]
    checkEqual(initialize?["protocolVersion"]?.stringValue, "2025-06-18", "initialize echoes a known legacy version")
    checkEqual(initialize?["serverInfo"]?["name"]?.stringValue, "srtflow", "serverInfo.name")
    check(initialize?["capabilities"]?["tools"] != nil, "initialize advertises tools")
    check((initialize?["instructions"]?.stringValue ?? "").contains("get_timeline"), "instructions mention the workflow")

    // 2. 工具清单：和 MCPToolName 一一对应、顺序一致、每个都有说明和对象型的参数表。
    let tools = reply(messages, id: 2)?["result"]?["tools"]?.arrayValue ?? []
    checkEqual(tools.compactMap { $0["name"]?.stringValue }, MCPToolName.allCases.map(\.rawValue), "tools/list order and names")
    for tool in tools {
        let name = tool["name"]?.stringValue ?? "?"
        check(!(tool["description"]?.stringValue ?? "").isEmpty, "\(name) has a description")
        checkEqual(tool["inputSchema"]?["type"]?.stringValue, "object", "\(name) input schema is an object")
        let properties = tool["inputSchema"]?["properties"]?.objectValue ?? [:]
        for required in tool["inputSchema"]?["required"]?.arrayValue ?? [] {
            check(properties[required.stringValue ?? ""] != nil, "\(name): required \(required) is a property")
        }
    }
    check(tools.count <= 40, "the catalog stays at or under 40 tools (the plan's budget)")

    // 3. 工具调用原样转给 App，客户端名字是 initialize 里报的那个；字符串 id 原样回。
    checkEqual(reply(messages, id: "abc")?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue,
               "echo:get_status", "tools/call is forwarded and the app's answer comes back")
    checkEqual(app.requests.first?.client, "check-client", "the legacy client name reaches the app")
    checkEqual(reply(messages, id: 4)?["error"]?["code"]?.intValue, -32602, "unknown tool is invalid params")
    checkEqual(reply(messages, id: 5)?["error"]?["code"]?.intValue, -32601, "unknown method")
    check(messages.contains { $0["error"]?["code"]?.intValue == -32700 }, "a line that is not JSON gets a parse error")
    check(raw.contains(#""id":7"#), "integer ids are written back as integers, not 7.0")
    check(!messages.contains { $0["method"] != nil }, "the helper never writes requests or notifications of its own")
    checkEqual(messages.count, 7, "one answer per request, none for the notification")

    runModernChecks(app)
    runAppMissingCheck()
}

/// 新一代（2026-07-28）：没有握手，每个请求在 _meta 里自带版本和客户端信息。
private func runModernChecks(_ app: FakeApp) {
    let meta = #""_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"modern-client","version":"2"}}"#
    let lines = [
        #"{"jsonrpc":"2.0","id":10,"method":"server/discover","params":{\#(meta)}}"#,
        #"{"jsonrpc":"2.0","id":11,"method":"tools/list","params":{\#(meta)}}"#,
        #"{"jsonrpc":"2.0","id":12,"method":"tools/call","params":{\#(meta),"name":"get_timeline","arguments":{}}}"#,
        #"{"jsonrpc":"2.0","id":13,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"1900-01-01"}}}"#,
        #"{"jsonrpc":"2.0","id":14,"method":"tools/call","params":{\#(meta),"name":"look","arguments":{"time":1}}}"#
    ]
    let (messages, _) = talkToHelper(lines, socket: app.path)
    let discover = reply(messages, id: 10)?["result"]
    let versions = discover?["supportedVersions"]?.arrayValue?.compactMap(\.stringValue) ?? []
    check(versions.contains("2026-07-28") && versions.contains("2025-11-25"), "discover lists both eras")
    checkEqual(discover?["resultType"]?.stringValue, "complete", "discover carries resultType")
    checkEqual(discover?["_meta"]?["io.modelcontextprotocol/serverInfo"]?["name"]?.stringValue, "srtflow", "discover serverInfo")
    check(discover?["ttlMs"]?.intValue != nil && discover?["cacheScope"]?.stringValue == "private", "discover is cacheable")
    let list = reply(messages, id: 11)?["result"]
    checkEqual(list?["resultType"]?.stringValue, "complete", "modern tools/list carries resultType")
    check(list?["ttlMs"] != nil, "modern tools/list carries ttlMs")
    let call = reply(messages, id: 12)?["result"]
    checkEqual(call?["resultType"]?.stringValue, "complete", "modern tools/call carries resultType")
    check(app.requests.contains { $0.tool == "get_timeline" && $0.client == "modern-client" },
          "the modern client name (from _meta) reaches the app")
    let picture = reply(messages, id: 14)?["result"]?["content"]?.arrayValue?.last
    checkEqual(picture?["type"]?.stringValue, "image", "a picture from the app comes back as MCP image content")
    check(picture?["data"]?.stringValue == bigPicture, "a picture of several hundred KB crosses the channel unchanged")
    let unsupported = reply(messages, id: 13)?["error"]
    checkEqual(unsupported?["code"]?.intValue, -32022, "an unknown version is UnsupportedProtocolVersionError")
    check((unsupported?["data"]?["supported"]?.arrayValue ?? []).contains("2026-07-28"), "the error lists supported versions")
}

/// App 没开、又不许拉起来：工具调用要回一句能转述给用户的话（isError），不是协议错误。
private func runAppMissingCheck() {
    let lines = [#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_status","arguments":{}}}"#]
    let (messages, _) = talkToHelper(lines, socket: NSTemporaryDirectory() + "srtflow-mcp-nobody-\(getpid()).sock")
    let result = reply(messages, id: 1)?["result"]
    checkEqual(result?["isError"]?.boolValue, true, "no app: the call fails as a tool error")
    check((result?["content"]?.arrayValue?.first?["text"]?.stringValue ?? "").contains("not running"),
          "no app: the message says SrtFlow is not running")
}
