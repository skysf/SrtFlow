import Foundation

// MARK: - MCP 协议这一层（小程序里跑）
//
// 管什么：收到一条 JSON-RPC 消息，决定回什么 —— 握手、版本、工具清单都在这里当场回；
// 工具调用交给调用方（小程序）去问 App，问完再用 `toolCallResponse` 包成回答。
// 不管什么：stdin / stdout 怎么读写（小程序的 main.swift）、工具真正怎么做（App）。
//
// **两代客户端都要接**（docs/architecture/ai-control-mcp.md）：
// - 老一代（2025-11-25 及更早）：先发 `initialize` 握手，之后的请求不带版本。
// - 新一代（2026-07-28 起）：没有握手，每个请求在 `_meta` 里自带协议版本和客户端信息；
//   必须实现 `server/discover`；每个结果带 `resultType`，清单类结果带 `ttlMs` / `cacheScope`。
// 规范允许一个服务同时说两代（「dual-era」），按客户端怎么开口来选。

public final class MCPServerCore: @unchecked Sendable {
    /// 一次要转给 App 的工具调用。
    public struct ToolCall: Sendable {
        public var id: JSONValue
        public var name: MCPToolName
        public var arguments: JSONValue
        public var client: String?
        /// 请求自带了新一代的 `_meta` 版本：回答要带新一代的字段。
        public var modern: Bool
    }

    public enum Outcome: Sendable {
        /// 当场回这一条。
        case reply(JSONValue)
        /// 通知，或者不需要回的东西。
        case none
        /// 要去问 App；问完用 `toolCallResponse` 回。
        case callTool(ToolCall)
    }

    /// 老一代握手能谈成的版本，新的在前。
    public static let legacyVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    /// 新一代（每个请求自带版本）。
    public static let modernVersions = ["2026-07-28"]
    public static var supportedVersions: [String] { modernVersions + legacyVersions }

    public static let serverName = "srtflow"

    private let serverVersion: String
    private let lock = NSLock()
    /// 老一代客户端在 `initialize` 里报的名字（新一代每个请求自己带）。
    private var legacyClientName: String?

    public init(serverVersion: String) {
        self.serverVersion = serverVersion
    }

    private var serverInfo: JSONValue {
        ["name": .string(Self.serverName), "title": "SrtFlow", "version": .string(serverVersion)]
    }

    // MARK: 分派

    public func handle(_ message: JSONValue) -> Outcome {
        guard case .object(let object) = message else {
            return .reply(Self.error(id: .null, code: -32600, message: "Invalid Request"))
        }
        // 没有 method 的是客户端对我们请求的回答 —— 我们从不发请求，丢掉即可。
        guard let method = object["method"]?.stringValue else { return .none }
        // 没有 id 的是通知（initialized、cancelled……），规范不许回。
        guard let id = object["id"] else { return .none }
        let params = object["params"] ?? [:]
        let meta = params["_meta"]
        let requestedVersion = meta?["io.modelcontextprotocol/protocolVersion"]?.stringValue
        if let requestedVersion, !Self.supportedVersions.contains(requestedVersion) {
            return .reply(Self.error(
                id: id, code: -32022, message: "Unsupported protocol version",
                data: ["supported": .array(Self.supportedVersions.map { .string($0) }),
                       "requested": .string(requestedVersion)]
            ))
        }
        let modern = requestedVersion != nil

        switch method {
        case "initialize":
            return .reply(initialize(id: id, params: params))
        case "ping", "logging/setLevel":
            return .reply(Self.success(id: id, result: [:]))
        case "server/discover":
            return .reply(Self.success(id: id, result: decorate(discover, modern: true, cacheable: true)))
        case "tools/list":
            return .reply(Self.success(
                id: id, result: decorate(["tools": MCPToolName.listJSON], modern: modern, cacheable: true)
            ))
        case "resources/list":
            return .reply(Self.success(id: id, result: decorate(["resources": []], modern: modern, cacheable: true)))
        case "resources/templates/list":
            return .reply(Self.success(id: id, result: decorate(["resourceTemplates": []], modern: modern, cacheable: true)))
        case "prompts/list":
            return .reply(Self.success(id: id, result: decorate(["prompts": []], modern: modern, cacheable: true)))
        case "tools/call":
            return toolCall(id: id, params: params, meta: meta, modern: modern)
        default:
            return .reply(Self.error(id: id, code: -32601, message: "Method not found: \(method)"))
        }
    }

    /// App 回来的工具结果（CallToolResult）包成 JSON-RPC 的回答。
    public func toolCallResponse(for call: ToolCall, result: JSONValue) -> JSONValue {
        Self.success(id: call.id, result: decorate(result, modern: call.modern, cacheable: false))
    }

    // MARK: 各个方法

    private func initialize(id: JSONValue, params: JSONValue) -> JSONValue {
        let requested = params["protocolVersion"]?.stringValue ?? ""
        // 客户端要的版本我们认得就照回；不认得（更新的老一代版本）回我们最新的，由客户端决定要不要继续。
        let negotiated = Self.legacyVersions.contains(requested) ? requested : Self.legacyVersions[0]
        lock.lock()
        legacyClientName = params["clientInfo"]?["name"]?.stringValue
        lock.unlock()
        return Self.success(id: id, result: [
            "protocolVersion": .string(negotiated),
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": serverInfo,
            "instructions": .string(MCPInstructions.text)
        ])
    }

    private var discover: JSONValue {
        [
            "supportedVersions": .array(Self.supportedVersions.map { .string($0) }),
            "capabilities": ["tools": [:]],
            "instructions": .string(MCPInstructions.text)
        ]
    }

    private func toolCall(id: JSONValue, params: JSONValue, meta: JSONValue?, modern: Bool) -> Outcome {
        guard let rawName = params["name"]?.stringValue else {
            return .reply(Self.error(id: id, code: -32602, message: "tools/call needs a tool name"))
        }
        guard let name = MCPToolName(rawValue: rawName) else {
            return .reply(Self.error(id: id, code: -32602, message: "Unknown tool: \(rawName)"))
        }
        let client: String?
        if modern {
            client = meta?["io.modelcontextprotocol/clientInfo"]?["name"]?.stringValue
        } else {
            lock.lock()
            client = legacyClientName
            lock.unlock()
        }
        let arguments = params["arguments"].flatMap { $0.isNull ? nil : $0 } ?? [:]
        return .callTool(ToolCall(id: id, name: name, arguments: arguments, client: client, modern: modern))
    }

    /// 新一代的结果要带 `resultType`、`_meta` 里的服务信息；清单类结果还要带缓存提示。
    /// 老一代客户端不认这些字段也不碍事，但照规范只给新一代加。
    private func decorate(_ result: JSONValue, modern: Bool, cacheable: Bool) -> JSONValue {
        guard modern, case .object(var object) = result else { return result }
        object["resultType"] = "complete"
        var meta = object["_meta"]?.objectValue ?? [:]
        meta["io.modelcontextprotocol/serverInfo"] = serverInfo
        object["_meta"] = .object(meta)
        if cacheable {
            // 清单跟着 App 的版本走，一个小时内不会变；是这个用户自己的东西，不给共享缓存。
            object["ttlMs"] = 3_600_000
            object["cacheScope"] = "private"
        }
        return .object(object)
    }

    // MARK: 信封

    public static func success(id: JSONValue, result: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    public static func error(id: JSONValue, code: Int, message: String, data: JSONValue? = nil) -> JSONValue {
        var body: [String: JSONValue] = ["code": .number(Double(code)), "message": .string(message)]
        if let data { body["data"] = data }
        return ["jsonrpc": "2.0", "id": id, "error": .object(body)]
    }
}
