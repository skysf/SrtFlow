import Foundation

// MARK: - 工具说明：看、听（AI 的眼睛和耳朵）
//
// 管什么：look / listen 给 AI 看的说明文字和参数表。清单的总入口在 MCPToolCatalog.swift。
// 为什么有这两个：AI 看不见画面、听不见声音，2026-09-27 实测时只好拿用户电脑上的 ffmpeg 抽帧、量响度
// （方案第 31 条）。聊天型客户端连终端都没有，只能靠 SrtFlow 自己的工具。

public enum MCPSenseTools {
    static func definition(for name: MCPToolName) -> MCPToolDefinition {
        switch name {
        case .look:
            return look
        default:
            preconditionFailure("\(name.rawValue) is described in another group")
        }
    }

    private static var look: MCPToolDefinition {
        MCPToolDefinition(
            .look, title: "Look at the picture",
            description: """
            See frames instead of guessing. Without file: the video as it will come out (all video tracks, crop and \
            placement, filters, shapes, texts and subtitles) at time, at each of times, or at count moments spread \
            over clip_id (default: the playhead). With file: frames of a media file, times in seconds of the file; \
            without times, count frames (default 6) spread over the file or between source_in and source_out. Use it \
            to choose shots before adding them and to check your edits. Several frames come as one picture, each \
            labelled with its time. Every frame also gets a short description from macOS Vision: what it shows, \
            faces [x, y, w, h], people, the main subject, words on screen, brightness 0–1 and black bars; on the \
            timeline also which clips, texts and subtitles are on screen. If you cannot see images, pass image=false \
            and use the descriptions. Files outside the opened folder need the user's OK (the result asks).
            """,
            input: MCPSchema.object([
                "time": MCPSchema.number("One moment, seconds (timeline, or in the file with file).", minimum: 0),
                "times": MCPSchema.array(of: MCPSchema.number("Seconds."), "Several moments (up to 12)."),
                "clip_id": MCPSchema.string("Timeline: spread the frames over this clip's part of the timeline."),
                "file": MCPSchema.string("Look at this media file instead of the timeline (absolute, or relative to the opened folder)."),
                "source_in": MCPSchema.number("With file and no times: where to start spreading the frames, seconds.", minimum: 0),
                "source_out": MCPSchema.number("With file and no times: where to stop, seconds.", minimum: 0),
                "count": MCPSchema.integer("How many frames to spread (1–12).", minimum: 1, maximum: 12),
                "size": MCPSchema.string("Picture size (default medium).", oneOf: ["small", "medium", "large"]),
                "image": MCPSchema.boolean("false: only the text descriptions, no picture (for models that cannot see images)."),
                "confirm_token": MCPSchema.confirmToken
            ]),
            readOnly: true
        )
    }
}
