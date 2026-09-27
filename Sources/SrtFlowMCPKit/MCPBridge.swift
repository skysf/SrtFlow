import Foundation

// MARK: - 小程序和 App 之间的通道
//
// 管什么：`srtflow-mcp`（AI 客户端启动的小程序）把一次工具调用交给正在运行的 SrtFlow 时，
// 两边说的话长什么样、在哪个 Unix socket 上说。
// 不管什么：socket 怎么收发（MCPUnixSocket）、MCP 协议本身（MCPServerCore）。
//
// 一次调用一条连接：小程序连上 → 写一行请求 → 读一行回答 → 断开。连接便宜，
// 这样 Claude 同时发几个调用也不用在一条连接上配对。

public enum MCPBridge {
    /// 通道格式的版本。两边对不上时 App 回一句人话（「请重启 AI 客户端」），
    /// 别让 AI 对着解码错误猜。
    public static let version = 1

    public struct Request: Codable, Sendable {
        public var bridge: Int
        public var id: String
        public var tool: String
        public var arguments: JSONValue
        /// 哪个 AI 客户端（`initialize` 或每次请求 `_meta` 里的 clientInfo.name）。横幅上显示它。
        public var client: String?

        public init(id: String = UUID().uuidString, tool: String, arguments: JSONValue, client: String?) {
            self.bridge = MCPBridge.version
            self.id = id
            self.tool = tool
            self.arguments = arguments
            self.client = client
        }
    }

    public struct Response: Codable, Sendable {
        public var bridge: Int
        public var id: String
        /// MCP 的 CallToolResult：`content` + `isError`。
        public var result: JSONValue

        public init(id: String, result: JSONValue) {
            self.bridge = MCPBridge.version
            self.id = id
            self.result = result
        }
    }

    /// 工具结果：一段文字。出错也走它（`isError: true`）—— MCP 规定工具自己的失败要让模型看得见，
    /// 不能变成协议层的错误。
    public static func textResult(_ text: String, isError: Bool = false) -> JSONValue {
        [
            "content": [["type": "text", "text": .string(text)]],
            "isError": .bool(isError)
        ]
    }

    // MARK: 在哪说

    /// App 监听的那个 socket。
    ///
    /// **按 bundle id 分开**：测试版（另一个 bundle id）和正式版同时开着时，各自的小程序只连
    /// 自己那个 App。放在「应用支持」下面而不是 /tmp：那个目录只有这个用户能进。
    /// Unix socket 的路径不能超过 103 个字节，太长（用户名特别长）就退到 /tmp 下按用户号区分。
    public static func socketPath(bundleIdentifier: String, home: String = realHomeDirectory()) -> String {
        let preferred = home + "/Library/Application Support/" + bundleIdentifier + "/mcp.sock"
        if preferred.utf8.count < 104 { return preferred }
        return "/tmp/srtflow-mcp-\(getuid())-\(stableHash(bundleIdentifier) % 100_000).sock"
    }

    /// 两个进程算出来必须一样的哈希（FNV-1a）。**不能用 `hashValue`**：Swift 每个进程的
    /// 哈希种子不同，小程序和 App 会算出两个不同的路径。
    static func stableHash(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    /// 真正的家目录（不看 `HOME` 环境变量：被沙盒化的客户端会把它指到自己的容器里，
    /// 那样小程序和 App 算出来的 socket 就不是同一个）。
    public static func realHomeDirectory() -> String {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return String(cString: dir)
        }
        return NSHomeDirectory()
    }
}
