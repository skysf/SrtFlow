import Foundation
import SrtFlowMCPKit

// MARK: - AI 工具的进与出
//
// 管什么：把 AI 传来的参数读成类型（读错了给一句 AI 看得懂的话）、把结果写成 MCP 的
// CallToolResult、「需要用户点头」的那种结果长什么样。
// 不管什么：哪个工具做什么（AI*Tools.swift）、分派和会话（AIToolRouter / AISession）。
//
// 参数读得**宽一点**：模型偶尔把数字写成 "3.5"、把布尔写成 "true"，照收；
// 但类型真不对（给了个数组）就报错，别悄悄当成没传。

/// 工具没做成，原因写给 AI 看（英文，AI 会用用户的语言转述）。
struct AIToolError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

struct AIToolArguments {
    let raw: JSONValue

    init(_ raw: JSONValue) { self.raw = raw }

    func has(_ key: String) -> Bool {
        guard let value = raw[key] else { return false }
        return !value.isNull
    }

    func string(_ key: String) throws -> String? {
        guard let value = raw[key], !value.isNull else { return nil }
        switch value {
        case .string(let text): return text
        case .number(let number): return number.rounded() == number ? String(Int(number)) : String(number)
        default: throw AIToolError("\(key) must be a string.")
        }
    }

    func requiredString(_ key: String) throws -> String {
        guard let text = try string(key), !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw AIToolError("\(key) is required.")
        }
        return text
    }

    func double(_ key: String) throws -> Double? {
        guard let value = raw[key], !value.isNull else { return nil }
        switch value {
        case .number(let number) where number.isFinite: return number
        case .string(let text):
            if let number = Double(text.trimmingCharacters(in: .whitespaces)), number.isFinite { return number }
        default: break
        }
        throw AIToolError("\(key) must be a number.")
    }

    func requiredDouble(_ key: String) throws -> Double {
        guard let number = try double(key) else { throw AIToolError("\(key) is required.") }
        return number
    }

    func int(_ key: String) throws -> Int? {
        guard let number = try double(key) else { return nil }
        guard number.rounded() == number, abs(number) < 1e9 else { throw AIToolError("\(key) must be a whole number.") }
        return Int(number)
    }

    func bool(_ key: String) throws -> Bool? {
        guard let value = raw[key], !value.isNull else { return nil }
        switch value {
        case .bool(let flag): return flag
        case .string(let text) where ["true", "false"].contains(text.lowercased()): return text.lowercased() == "true"
        case .number(let number) where number == 0 || number == 1: return number == 1
        default: throw AIToolError("\(key) must be true or false.")
        }
    }

    func array(_ key: String) throws -> [JSONValue]? {
        guard let value = raw[key], !value.isNull else { return nil }
        guard case .array(let items) = value else { throw AIToolError("\(key) must be a list.") }
        return items
    }

    func stringArray(_ key: String) throws -> [String]? {
        try array(key).map { items in
            try items.map { item in
                guard let text = item.stringValue else { throw AIToolError("Every entry of \(key) must be a string.") }
                return text
            }
        }
    }

    /// 取值并确认它在给定的几个选项里（大小写不敏感，回的是表里的写法）。
    func choice(_ key: String, from options: [String]) throws -> String? {
        guard let text = try string(key) else { return nil }
        if let match = options.first(where: { $0.caseInsensitiveCompare(text) == .orderedSame }) { return match }
        throw AIToolError("\(key) must be one of: \(options.joined(separator: ", ")).")
    }
}

/// 一个工具的结果。
struct AIToolResult {
    var payload: JSONValue
    var isError = false
    /// 工程被改了（算进这一轮的改动数）。
    var changedProject = false

    static func ok(_ payload: JSONValue, changed: Bool = false) -> AIToolResult {
        AIToolResult(payload: payload, changedProject: changed)
    }

    /// 要用户点头才能继续的事（覆盖文件、丢掉没存的工程、读工程以外的文件）。
    /// AI 必须把问题转述给用户，用户同意之后带着令牌再调一次。
    static func needsConfirmation(question: String, token: String) -> AIToolResult {
        .ok([
            "status": "needs_confirmation",
            "question": .string(question),
            "confirm_token": .string(token),
            "next_step": "Ask the user this question. Only if they agree, call the same tool again with the same arguments plus this confirm_token."
        ])
    }

    /// MCP 的 CallToolResult：结果写成一段 JSON 文字（所有客户端都认文字）。
    var json: JSONValue {
        MCPBridge.textResult(payload.encodedString(), isError: isError)
    }
}

// MARK: - 时间、路径的写法

enum AIFormat {
    /// 秒数保留三位小数：够精确到帧，又不让 0.30000000000000004 这种噪声出现在结果里。
    static func seconds(_ value: Double) -> JSONValue {
        .number((value * 1000).rounded() / 1000)
    }

    /// 把 AI 给的路径变成 URL：`~` 展开；相对路径按「打开的文件夹」解析。
    static func url(fromPath path: String, relativeTo base: URL?) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded).standardizedFileURL }
        let root = base ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return root.appendingPathComponent(expanded).standardizedFileURL
    }

    /// 给 AI 看的路径：在文件夹里就写相对路径（短，也是 add_clips 收的写法），否则写全路径。
    static func path(_ url: URL, relativeTo base: URL?) -> String {
        let full = url.standardizedFileURL.path
        guard let base else { return full }
        let root = base.standardizedFileURL.path
        guard full.hasPrefix(root + "/") else { return full }
        return String(full.dropFirst(root.count + 1))
    }
}
