import Foundation

// MARK: - 工具说明：状态、文件夹、工程、撤销、播放头
//
// 管什么：这几样工具给 AI 看的说明文字和参数表。清单的总入口在 MCPToolCatalog.swift。

public enum MCPProjectTools {
    static func definition(for name: MCPToolName) -> MCPToolDefinition {
        switch name {
        case .getStatus:
            return MCPToolDefinition(
                .getStatus, title: "SrtFlow status",
                description: """
                What SrtFlow is doing right now: the open project (name, path, length, unsaved changes), \
                the folders you may use, running jobs, whether the user pressed Stop, and the view mode (set_view). \
                Cheap; call it first in a new conversation.
                """,
                readOnly: true
            )
        case .setView:
            return MCPToolDefinition(
                .setView, title: "Watch or work in the background",
                description: """
                visible (the default): SrtFlow comes forward when a round of edits starts and each edit is selected \
                and shown in the preview. background: SrtFlow stays where it is and does not follow the edits; they \
                still go into the project and can be undone. Ask the user once per conversation which they want, \
                unless they already said. Lasts until SrtFlow quits.
                """,
                input: MCPSchema.object([
                    "mode": MCPSchema.string("How the user follows your edits.", oneOf: ["visible", "background"])
                ], required: ["mode"])
            )
        case .openFolder:
            return MCPToolDefinition(
                .openFolder, title: "Open a media folder",
                description: """
                Use a folder the user named as the workspace for this edit and list the media inside it, \
                including every subfolder: videos, images, audio and subtitle files with their duration and size. \
                Files in this folder can be imported without asking again. New files SrtFlow makes \
                (exports, projects) go into its "SrtFlow" subfolder. Paths in the result are relative to the folder. \
                Only pass a folder the user gave you. When the user says to use what they selected in Finder, pass \
                from_finder=true instead of path: the selected files are listed (their folder becomes the workspace), \
                or the selected folder, or the folder open in the front Finder window. macOS asks the user once to let \
                SrtFlow see Finder.
                """,
                input: MCPSchema.object([
                    "path": MCPSchema.string("Absolute path of the folder. ~ means the user's home folder."),
                    "from_finder": MCPSchema.boolean("Use what the user selected in Finder instead of path."),
                    "max_files": MCPSchema.integer("Stop listing after this many files (default 400).", minimum: 1, maximum: 2000)
                ]),
                readOnly: true
            )
        case .openProject:
            return MCPToolDefinition(
                .openProject, title: "Open a project",
                description: """
                Open an existing SrtFlow project file (.srtflowproj) in the editor. \
                If the open project was never saved and has edits, SrtFlow saves it first (into SrtFlow/Projects) \
                and the result says where (previous_project_saved_to).
                """,
                input: MCPSchema.object([
                    "path": MCPSchema.string("Absolute path of the .srtflowproj file.")
                ], required: ["path"])
            )
        case .newProject:
            return MCPToolDefinition(
                .newProject, title: "New project",
                description: """
                Start a new, empty project and save it at once as <name>.srtflowproj, so every later edit autosaves. \
                It goes into the folder you pass, otherwise into SrtFlow/Projects inside the folder the user named \
                (open_folder), the open project's folder, or Downloads when there is neither. \
                A name that is taken gets a number (the result has the real path). If the open project was never saved \
                and has edits, SrtFlow saves it first and the result says where (previous_project_saved_to).
                """,
                input: MCPSchema.object([
                    "name": MCPSchema.string("Project name without extension. Default: the workspace folder's name."),
                    "folder": MCPSchema.string("Folder to save the project in, when there is no workspace yet.")
                ])
            )
        case .saveProject:
            return MCPToolDefinition(
                .saveProject, title: "Save the project",
                description: """
                Save the open project now. SrtFlow already autosaves a saved project two seconds after every edit, \
                and saves a never-saved one by itself after your first change, so this is mainly for saving under \
                another path. Without a path a never-saved project goes into SrtFlow/Projects inside the folder the \
                user named (Downloads when there is none). Never replaces another file: a name that is taken gets a number.
                """,
                input: MCPSchema.object([
                    "path": MCPSchema.string("Where to save (.srtflowproj). Leave out to keep the current location.")
                ])
            )
        case .undo:
            return MCPToolDefinition(
                .undo, title: "Undo",
                description: """
                Undo the latest edits in SrtFlow, like pressing Command-Z. \
                round=true instead puts the project back to how it was before this round of AI edits started \
                (that is itself one undoable step).
                """,
                input: MCPSchema.object([
                    "steps": MCPSchema.integer("How many edits to undo (default 1).", minimum: 1, maximum: 50),
                    "round": MCPSchema.boolean("Undo everything done since this round of AI edits began.")
                ]),
                destructive: true
            )
        case .seek:
            return MCPToolDefinition(
                .seek, title: "Show a moment",
                description: "Move SrtFlow's playhead to a time on the timeline, so the user sees that frame in the preview.",
                input: MCPSchema.object([
                    "time": MCPSchema.number("Timeline time in seconds.", minimum: 0)
                ], required: ["time"]),
                readOnly: true
            )
        default:
            preconditionFailure("\(name.rawValue) is described in another group")
        }
    }
}
