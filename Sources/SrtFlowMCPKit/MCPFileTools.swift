import Foundation

// MARK: - 工具说明：文稿与文件（读文稿、整理文件）
//
// 管什么：这几样工具给 AI 看的说明文字和参数表。清单的总入口在 MCPToolCatalog.swift。

public enum MCPFileTools {
    static func definition(for name: MCPToolName) -> MCPToolDefinition {
        switch name {
        case .readDocument:
            return MCPToolDefinition(
                .readDocument, title: "Read a document",
                description: """
                Read the text of a document the user gave you: a script, an outline, notes, selling points. PDF, Word (.doc, \
                .docx), RTF, ODT, .txt and .md; not Pages files (ask for PDF or Word) or scanned PDFs (pictures of text). Long \
                documents come in pieces of max_chars characters; call again with from_char = next_from_char for the rest. Files \
                outside the opened folder need the user's OK.
                """,
                input: MCPSchema.object([
                    "file": MCPSchema.string("Path of the document (absolute, or relative to the opened folder)."),
                    "from_char": MCPSchema.integer("Start at this character (default 0).", minimum: 0),
                    "max_chars": MCPSchema.integer("At most this many characters (default 20000).", minimum: 500, maximum: 100000),
                    "confirm_token": MCPSchema.confirmToken
                ], required: ["file"]),
                readOnly: true
            )
        case .manageFiles:
            return MCPToolDefinition(
                .manageFiles, title: "Organise files",
                description: """
                Move, rename, make folders or put files in the Trash, only inside folders the user named with open_folder, and \
                only when the user asked you to organise or clean up; never touch the originals on your own. Nothing is \
                overwritten: a taken name fails and you pick another. trash always asks first (needs_confirmation). Media used \
                in the open project follows its moved files. Command-Z and undo do not revert these, so tell the user what you \
                did.
                """,
                input: MCPSchema.object([
                    "action": MCPSchema.string("What to do.", oneOf: ["move", "rename", "make_folder", "trash"]),
                    "files": MCPSchema.array(of: MCPSchema.string("Path (absolute, or relative to the opened folder)."), "move / trash: the files or folders."),
                    "file": MCPSchema.string("rename: the file or folder to rename."),
                    "new_name": MCPSchema.string("rename: the new name, without folders (the extension is kept if you leave it out)."),
                    "to": MCPSchema.string("move: the destination folder (made if missing)."),
                    "path": MCPSchema.string("make_folder: the new folder."),
                    "confirm_token": MCPSchema.confirmToken
                ], required: ["action"]),
                destructive: true
            )
        default:
            preconditionFailure("\(name.rawValue) is described in another group")
        }
    }
}
