import Foundation

// MARK: - 往 AI 客户端的配置文件里写一行「srtflow」（纯值）
//
// 管什么：Claude 桌面版的 JSON、Codex 的 TOML 里加上 / 去掉 / 读出 SrtFlow 那一项；连上的同时放行 SrtFlow 的工具、
// 不用每个工具都点一次「允许」（方案第 35 条）：Claude Code 在 ~/.claude/settings.json 的 permissions.allow 里加一条
// `mcp__srtflow`，Codex 在那张表里写 `default_tools_approval_mode = "approve"`。Claude 桌面版没有能写的地方。
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

    // MARK: Claude Code 的权限（~/.claude/settings.json）

    /// 放行 SrtFlow 全部工具的那条规则：Claude Code 里 `mcp__<服务器名>` 匹配这个服务器的每一个工具。
    static let claudeCodeAllowRule = "mcp__\(serverName)"

    static func jsonAllows(rule: String, in data: Data?) -> Bool {
        guard let data, !data.isEmpty,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let allow = (root["permissions"] as? [String: Any])?["allow"] as? [String] else { return false }
        return allow.contains(rule)
    }

    /// 加上这条规则（已经有就不重复）；permissions / allow 不是该有的样子就报错、不写。
    static func jsonAllowing(rule: String, in data: Data?) throws -> Data {
        try editingAllowList(data) { allow in
            if !allow.contains(rule) { allow.append(rule) }
        }
    }

    static func jsonDisallowing(rule: String, in data: Data?) throws -> Data {
        try editingAllowList(data) { allow in allow.removeAll { $0 == rule } }
    }

    private static func editingAllowList(_ data: Data?, _ edit: (inout [String]) -> Void) throws -> Data {
        var root = try jsonRoot(data)
        let permissionsValue = root["permissions"] ?? [String: Any]()
        guard var permissions = permissionsValue as? [String: Any] else {
            throw FormatError(message: "\"permissions\" in the settings file is not an object, so SrtFlow left it alone.")
        }
        let allowValue = permissions["allow"] ?? [String]()
        guard var allow = allowValue as? [String] else {
            throw FormatError(message: "\"permissions.allow\" in the settings file is not a list, so SrtFlow left it alone.")
        }
        edit(&allow)
        permissions["allow"] = allow
        root["permissions"] = permissions
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

    /// `[mcp_servers.srtflow]` 这张表里的行（去掉首尾空白，到下一张表为止）。没有这张表就是空的。
    private static func tomlTable(in text: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { tomlHeaders.contains($0.trimmingCharacters(in: .whitespaces)) }) else {
            return []
        }
        var table: [String] = []
        for line in lines[(start + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { break }
            table.append(trimmed)
        }
        return table
    }

    static func tomlCommand(in text: String) -> String? {
        for trimmed in tomlTable(in: text) {
            guard trimmed.hasPrefix("command"), let equals = trimmed.firstIndex(of: "=") else { continue }
            let value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return nil }
            return String(value.dropFirst().dropLast())
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        return nil
    }

    /// Codex 里不问就放行这个服务器全部工具的写法（`[mcp_servers.<名字>]` 下面这一行）。
    static let codexApprovalLine = "default_tools_approval_mode = \"approve\""

    static func tomlAdding(command: String, to text: String) -> String {
        var body = tomlRemoving(from: text)
        while body.hasSuffix("\n\n") { body.removeLast() }
        if !body.isEmpty, !body.hasSuffix("\n") { body += "\n" }
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let separator = body.isEmpty ? "" : "\n"
        return body + separator + "[mcp_servers.\(serverName)]\ncommand = \"\(escaped)\"\n\(codexApprovalLine)\n"
    }

    /// SrtFlow 那张表里写没写「不问就放行」。
    static func tomlApproves(in text: String) -> Bool {
        let wanted = codexApprovalLine.replacingOccurrences(of: " ", with: "")
        return tomlTable(in: text).contains { $0.replacingOccurrences(of: " ", with: "") == wanted }
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
