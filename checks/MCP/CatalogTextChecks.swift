import Foundation
import SrtFlowMCPKit

// 给 AI 的文字（总说明 + 工具清单）按客户端怎么读来守（docs/architecture/ai-control-mcp.md 第一节第 6 条）：
// - Claude Code 只保留总说明和**每个工具说明**的前 2,048 个字符（JavaScript 的字符串长度 = UTF-16 单位），多出来的静默截掉；
//   2026-09-30 之前总说明 4,433 字、edit_clip 的说明 2,074 字，后半截它从来没读到过
//   （docs/bugfixes/2026-09-30-mcp-text-truncated-at-2048.md）；
// - Codex 要求总说明的前 512 个字符自成一体；
// - 总说明是一份目录：Claude Code 会话开始时只看得到工具名和它，清单里的每个工具都要在目录里出现；
// - 只用英文（2026-09-30 用户定）。
// 总说明量「没配提供方」和「每个提供方都配好」两种样子（配了 fal 多一行），工具说明量全份清单。

/// Claude Code 截断的上限：它的 MCP 客户端里写死的 2048，超过就截、末尾加「… [truncated]」。
let claudeCodeTextLimit = 2_048

func runCatalogTextChecks() {
    for providers in [Set<MCPProvider>(), Set(MCPProvider.allCases)] {
        let label = providers.isEmpty ? "no provider" : "all providers"
        let text = MCPInstructions.text(providers: providers)
        check(text.utf16.count <= claudeCodeTextLimit,
              "\(label): the instructions fit in Claude Code's \(claudeCodeTextLimit) characters (they are \(text.utf16.count))")
        let opening = String(decoding: Array(text.utf16.prefix(512)), as: UTF16.self)
        for core in ["open_folder", "get_timeline", "look", "export_video"] {
            check(mentions(opening, core), "\(label): the first 512 characters name \(core) (Codex wants them to stand on their own)")
        }
        for tool in MCPToolName.listed(providers: providers) {
            check(mentions(text, tool.rawValue), "\(label): the instructions' map names \(tool.rawValue)")
        }
        check(!containsChinese(text), "\(label): the instructions are English only")
    }
    for tool in MCPToolName.allCases {
        let description = tool.definition.description
        check(description.utf16.count <= claudeCodeTextLimit,
              "\(tool.rawValue): the description fits in Claude Code's \(claudeCodeTextLimit) characters (it is \(description.utf16.count))")
    }
    check(!containsChinese(MCPToolName.listJSON.encodedString()), "the tool list (names, descriptions, parameters, choices) is English only")
}

/// 名字作为一个整词出现：`look` 不算 `looks` 里的那个，`undo` 不算 `undoes`（下划线算词的一部分）。
private func mentions(_ text: String, _ name: String) -> Bool {
    text.range(of: "\\b\(name)\\b", options: .regularExpression) != nil
}

/// 汉字、中日文标点和全角符号。
private func containsChinese(_ text: String) -> Bool {
    text.unicodeScalars.contains { scalar in
        switch scalar.value {
        case 0x3000...0x303F, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF00...0xFFEF: return true
        default: return false
        }
    }
}
