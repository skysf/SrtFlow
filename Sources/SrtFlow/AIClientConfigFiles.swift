import Foundation

// MARK: - 往 AI 客户端的配置文件里写一行「srtflow」（纯值）
//
// 管什么：Claude 桌面版的 JSON、Codex 的 TOML 里加上 / 去掉 / 读出 SrtFlow 那一项。
// 只动 `srtflow` 这一项，别的原样留着；文件格式不对就报错、一个字节都不写。
// 自检够得着（scripts/check-mcp.sh）。
// 不管什么：文件在哪、要不要备份、Claude Code 走命令行（AIClientSetup）。

enum AIClientConfigFiles {
    /// 在客户端配置里的名字（工具在 Claude 里显示成 srtflow 下面的那一串）。
    static let serverName = "srtflow"

    struct FormatError: Error {
        let message: String
    }

    // MARK: JSON（Claude 桌面版、Claude Code 的 ~/.claude.json 都是 mcpServers 这一套）

    static func jsonCommand(in data: Data?) -> String? {
        guard let data, !data.isEmpty,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any],
              let entry = servers[serverName] as? [String: Any] else { return nil }
        return entry["command"] as? String
    }

    static func jsonAdding(command: String, to data: Data?) throws -> Data {
        var root = try jsonRoot(data)
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers[serverName] = ["command": command, "args": [String]()]
        root["mcpServers"] = servers
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    static func jsonRemoving(from data: Data?) throws -> Data {
        var root = try jsonRoot(data)
        if var servers = root["mcpServers"] as? [String: Any] {
            servers.removeValue(forKey: serverName)
            root["mcpServers"] = servers
        }
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private static func jsonRoot(_ data: Data?) throws -> [String: Any] {
        guard let data, !data.isEmpty else { return [:] }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FormatError(message: "The configuration file is not valid JSON, so SrtFlow left it alone.")
        }
        return root
    }

    // MARK: TOML（Codex 的 ~/.codex/config.toml）

    private static let tomlHeaders = ["[mcp_servers.\(serverName)]", "[mcp_servers.\"\(serverName)\"]"]

    static func tomlCommand(in text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { tomlHeaders.contains($0.trimmingCharacters(in: .whitespaces)) }) else {
            return nil
        }
        for line in lines[(start + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { break }
            guard trimmed.hasPrefix("command"), let equals = trimmed.firstIndex(of: "=") else { continue }
            let value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return nil }
            return String(value.dropFirst().dropLast())
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        return nil
    }

    static func tomlAdding(command: String, to text: String) -> String {
        var body = tomlRemoving(from: text)
        while body.hasSuffix("\n\n") { body.removeLast() }
        if !body.isEmpty, !body.hasSuffix("\n") { body += "\n" }
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let separator = body.isEmpty ? "" : "\n"
        return body + separator + "[mcp_servers.\(serverName)]\ncommand = \"\(escaped)\"\n"
    }

    /// 去掉 `[mcp_servers.srtflow]` 那张表（连同它的子表，比如 `[mcp_servers.srtflow.env]`）。
    static func tomlRemoving(from text: String) -> String {
        var kept: [String] = []
        var skipping = false
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                let ours = tomlHeaders.contains(trimmed)
                    || trimmed.hasPrefix("[mcp_servers.\(serverName).")
                    || trimmed.hasPrefix("[mcp_servers.\"\(serverName)\".")
                skipping = ours
            }
            if !skipping { kept.append(line) }
        }
        return kept.joined(separator: "\n")
    }
}
