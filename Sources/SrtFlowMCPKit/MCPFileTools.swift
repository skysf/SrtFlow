import Foundation

// MARK: - 工具说明：文稿与文件（读文稿；整理文件在后面加）
//
// 管什么：这几样工具给 AI 看的说明文字和参数表。清单的总入口在 MCPToolCatalog.swift。

public enum MCPFileTools {
    static func definition(for name: MCPToolName) -> MCPToolDefinition {
        switch name {
        case .readDocument:
            return MCPToolDefinition(
                .readDocument, title: "Read a document",
                description: """
                Read the text of a document the user gave you: a script, an outline, notes, a list of selling \
                points. Works for PDF, Word (.doc, .docx), RTF, ODT, .txt and .md; not for Pages files (ask the user \
                to export PDF or Word) or scanned PDFs (pictures of text). Long documents come in pieces of \
                max_chars characters; call again with from_char = next_from_char for the rest. Files outside the \
                opened folder need the user's OK (the result asks).
                """,
                input: MCPSchema.object([
                    "file": MCPSchema.string("Path of the document (absolute, or relative to the opened folder)."),
                    "from_char": MCPSchema.integer("Start at this character (default 0).", minimum: 0),
                    "max_chars": MCPSchema.integer("At most this many characters (default 20000).", minimum: 500, maximum: 100000),
                    "confirm_token": MCPSchema.confirmToken
                ], required: ["file"]),
                readOnly: true
            )
        default:
            preconditionFailure("\(name.rawValue) is described in another group")
        }
    }
}
