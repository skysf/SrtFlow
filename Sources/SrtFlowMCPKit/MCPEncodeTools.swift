import Foundation

// MARK: - 工具清单：压缩、烧录字幕文件、转字幕格式（不经过时间线的那三页）
//
// 管什么：compress_videos / burn_subtitles / convert_subtitles 的说明文字和参数。
// 不管什么：怎么排队、怎么换算、放哪（App 里的 AIEncodeTools / AIEncodeOptions）。

enum MCPEncodeTools {
    static func definition(for name: MCPToolName) -> MCPToolDefinition {
        switch name {
        case .compressVideos:
            return MCPToolDefinition(
                .compressVideos, title: "Compress videos",
                description: """
                Make video files smaller, one output per file (H.264 MP4, named <name>_compressed.mp4 in SrtFlow/Exports \
                inside the opened folder; never overwrites). Without options it uses the settings the user keeps on \
                SrtFlow's Compress Video page; the options below apply to this batch only. Resolution and frame rate \
                are only ever lowered. The videos show up in the Compress Video page's queue. Returns a job id: wait \
                with get_job, whose result lists each output with its size.
                """,
                input: MCPSchema.object(encodeOptions.merging([
                    "files": MCPSchema.array(of: MCPSchema.string("Path of a video file."), "Videos to compress.", minItems: 1),
                    "confirm_token": MCPSchema.confirmToken
                ]) { current, _ in current }, required: ["files"])
            )
        case .burnSubtitles:
            let item = MCPSchema.object([
                "video": MCPSchema.string("Path of the video file."),
                "subtitles": MCPSchema.string("Path of its subtitle file (.srt, .vtt, .ass, .ssa, .txt).")
            ], required: ["video", "subtitles"])
            return MCPToolDefinition(
                .burnSubtitles, title: "Burn subtitle files into videos",
                description: """
                Draw a subtitle file permanently into a video, for videos that are not in the project (to burn the \
                project's own subtitles, use export_video). One output per video (<name>_sub.mp4 in SrtFlow/Exports \
                inside the opened folder; never overwrites). The subtitles look the way the user set them up on \
                SrtFlow's Burn In Subtitles page; style and the encoding options change this batch only (highlight \
                does not apply: subtitle files have no word times). Returns a job id: wait with get_job.
                """,
                input: MCPSchema.object(encodeOptions.merging([
                    "items": MCPSchema.array(of: item, "Each video with its subtitle file.", minItems: 1),
                    "style": MCPSubtitleExportTools.subtitleStyle,
                    "confirm_token": MCPSchema.confirmToken
                ]) { current, _ in current }, required: ["items"])
            )
        case .convertSubtitles:
            return MCPToolDefinition(
                .convertSubtitles, title: "Convert subtitle files",
                description: """
                Convert subtitle files to another format (SRT, WebVTT, ASS, SSA or plain text), one output per file \
                in SrtFlow/Exports inside the opened folder (never overwrites). Done at once; returns where each \
                file went, and which ones could not be read.
                """,
                input: MCPSchema.object([
                    "files": MCPSchema.array(of: MCPSchema.string("Path of a subtitle file."), "Files to convert.", minItems: 1),
                    "to": MCPSchema.string("Format to convert to.", oneOf: MCPVocabulary.subtitleFormats),
                    "confirm_token": MCPSchema.confirmToken
                ], required: ["files", "to"])
            )
        default:
            preconditionFailure("\(name.rawValue) is described in another group")
        }
    }

    /// 压缩和烧录共用的编码参数。
    private static let encodeOptions: [String: JSONValue] = [
        "quality": MCPSchema.string(
            "small (smaller file, slightly softer), balanced (looks the same as the original), high (bigger file).",
            oneOf: MCPVocabulary.encodeQualities
        ),
        "fast": MCPSchema.boolean("true: use the Mac's hardware encoder, about ten times faster but a bigger file at the same quality."),
        "resolution": MCPSchema.string("Largest size by the short side, e.g. 1080p; original keeps it.", oneOf: MCPVocabulary.resolutions),
        "frame_rate": MCPSchema.string("Highest frame rate; original keeps it.", oneOf: MCPVocabulary.frameRateLimits)
    ]
}
