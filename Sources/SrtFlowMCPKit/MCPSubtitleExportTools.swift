import Foundation

// MARK: - 工具说明：字幕、导出、长任务
//
// 管什么：这几样工具给 AI 看的说明文字和参数表。清单的总入口在 MCPToolCatalog.swift。
// 生成字幕、翻译、导出都要跑好一阵，一律先回任务号，AI 用 get_job 等结果 ——
// 客户端对一次工具调用大多只等一分钟左右。

public enum MCPSubtitleExportTools {
    static func definition(for name: MCPToolName) -> MCPToolDefinition {
        switch name {
        case .generateSubtitles:
            return MCPToolDefinition(
                .generateSubtitles, title: "Generate subtitles",
                description: """
                Transcribe the speech on the timeline into the subtitle track, on this Mac (needs macOS 26). \
                It replaces the current subtitles as one undoable step. Hidden clips are skipped. \
                Optionally translate right after (the same language download dialog as translate_subtitles can appear). \
                Returns a job id; wait for it with get_job.
                """,
                input: MCPSchema.object([
                    "language": MCPSchema.string("Spoken language: auto (default) or a locale such as en-US, zh-CN, ja-JP."),
                    "translate_to": MCPSchema.string("Also translate into this language, e.g. zh-Hans, en, ja."),
                    "clip_ids": MCPSchema.array(of: MCPSchema.string("Clip id."), "Only transcribe these clips (for example just the voice-over).")
                ])
            )
        case .translateSubtitles:
            return MCPToolDefinition(
                .translateSubtitles, title: "Translate subtitles",
                description: """
                Translate the original subtitle track into a second track in another language, on this Mac. \
                The original's language is read from its text (so rewriting the original first is fine). \
                scope all rebuilds every translated line (lines edited by hand are replaced); \
                missing only fills lines with no translation or whose original changed. Returns a job id. \
                If this Mac still has to download the languages, macOS shows a download dialog in SrtFlow that only \
                the user can click; the result and get_job then carry waiting_for_user, which you must pass on to the user.
                """,
                input: MCPSchema.object([
                    "target_language": MCPSchema.string("Language tag, e.g. zh-Hans, en, ja, ko, es."),
                    "source_language": MCPSchema.string("Language the original lines are written in. Default: detected from their text."),
                    "scope": MCPSchema.string("all (default) or missing.", oneOf: ["all", "missing"])
                ], required: ["target_language"])
            )
        case .getSubtitles:
            return MCPToolDefinition(
                .getSubtitles, title: "Read subtitles",
                description: """
                Subtitle lines with ids, start and end on the timeline and text, from the original track, \
                the translated track, or both; optionally only those inside a time range.
                """,
                input: MCPSchema.object([
                    "track": MCPSchema.string("Which track (default both).", oneOf: ["original", "translation", "both"]),
                    "start": MCPSchema.number("Only lines that end after this time.", minimum: 0),
                    "end": MCPSchema.number("Only lines that start before this time.", minimum: 0),
                    "limit": MCPSchema.integer("At most this many lines per track (default 300).", minimum: 1, maximum: 2000)
                ]),
                readOnly: true
            )
        case .editSubtitles:
            return editSubtitles
        case .exportVideo:
            return exportVideo
        case .getJob:
            return MCPToolDefinition(
                .getJob, title: "Job progress",
                description: """
                Progress and result of a long job (export, subtitle generation, translation). \
                wait_seconds (up to 30) waits for the job to finish before answering, so you do not have to poll fast.
                """,
                input: MCPSchema.object([
                    "job_id": MCPSchema.string("Job id."),
                    "wait_seconds": MCPSchema.number("Wait up to this long for the job to finish.", minimum: 0, maximum: 30)
                ], required: ["job_id"]),
                readOnly: true
            )
        case .cancelJob:
            return MCPToolDefinition(
                .cancelJob, title: "Cancel a job",
                description: "Stop a running export, subtitle generation or translation.",
                input: MCPSchema.object(["job_id": MCPSchema.string("Job id.")], required: ["job_id"])
            )
        default:
            preconditionFailure("\(name.rawValue) is described in another group")
        }
    }

    private static var editSubtitles: MCPToolDefinition {
        let change = MCPSchema.object([
            "id": MCPSchema.string("Line id from get_subtitles."),
            "text": MCPSchema.string("New text."),
            "start": MCPSchema.number("New start, timeline seconds.", minimum: 0),
            "end": MCPSchema.number("New end, timeline seconds.", minimum: 0)
        ], required: ["id"])
        let addition = MCPSchema.object([
            "track": MCPSchema.string("original (default) or translation.", oneOf: ["original", "translation"]),
            "start": MCPSchema.number("Timeline seconds.", minimum: 0),
            "end": MCPSchema.number("Timeline seconds.", minimum: 0),
            "text": MCPSchema.string("Text of the new line.")
        ], required: ["start", "end", "text"])
        return MCPToolDefinition(
            .editSubtitles, title: "Edit subtitles",
            description: """
            Change subtitle lines as one undoable step: edit text or times by id, add new lines, delete lines. \
            Creates the subtitle track if the project has none.
            """,
            input: MCPSchema.object([
                "changes": MCPSchema.array(of: change, "Lines to change."),
                "add": MCPSchema.array(of: addition, "Lines to add."),
                "delete": MCPSchema.array(of: MCPSchema.string("Line id."), "Lines to delete.")
            ])
        )
    }

    private static var exportVideo: MCPToolDefinition {
        MCPToolDefinition(
            .exportVideo, title: "Export the video",
            description: """
            Render the timeline to an .mp4 (a timeline with only audio becomes .m4a). By default the file is named \
            after the project and goes into SrtFlow/Exports inside the folder the user named (otherwise the \
            project's folder, or Downloads). Subtitles that are visible on \
            the timeline are burned in unless burn_subtitles is false. If the file already exists the result asks \
            for confirmation. Returns a job id; wait for it with get_job.
            """,
            input: MCPSchema.object([
                "path": MCPSchema.string("Full output path. Leave out to use name and the default folder."),
                "name": MCPSchema.string("File name without extension."),
                "resolution": MCPSchema.string(
                    "Cap on the short side (default original; never upscales).", oneOf: MCPVocabulary.resolutions
                ),
                "burn_subtitles": MCPSchema.boolean("Burn visible subtitles into the picture (default true)."),
                "confirm_token": MCPSchema.confirmToken
            ]),
            destructive: true
        )
    }
}
