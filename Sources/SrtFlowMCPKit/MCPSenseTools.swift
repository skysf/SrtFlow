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
        case .listen:
            return listen
        default:
            preconditionFailure("\(name.rawValue) is described in another group")
        }
    }

    private static var listen: MCPToolDefinition {
        MCPToolDefinition(
            .listen, title: "Measure the sound",
            description: """
            Hear the sound as numbers instead of guessing. With clip_id: that clip as it plays in the video \
            (its volume, fades and track fader included), times on the timeline. With file: a media file, times in \
            seconds of the file (source_in/source_out narrow it). With neither: every clip with sound on the timeline, \
            one line each. You get level_db (RMS of the parts that are not silent), peak_db, silences (stretches \
            quieter than silence_db for at least min_silence seconds), loudest_at, and for one clip or file a coarse \
            curve of the level (one value per step seconds). dB are dBFS; -60 means silent or quieter. Use it to set \
            volumes (speech usually sits around -20 to -14 dB level, background music about 12-20 dB under the voice) \
            and to find pauses to cut. With beats=true (one clip or file, usually music) you also get tempo_bpm, \
            beats (every beat) and downbeats (the likely first beat of each bar) — cut on them, or let cut_to_beat \
            do it. Files outside the opened folder need the user's OK (the result asks).
            """,
            input: MCPSchema.object([
                "clip_id": MCPSchema.string("A clip on the timeline."),
                "file": MCPSchema.string("A media file instead (absolute, or relative to the opened folder)."),
                "source_in": MCPSchema.number("With file: start, seconds in the file.", minimum: 0),
                "source_out": MCPSchema.number("With file: end, seconds in the file.", minimum: 0),
                "silence_db": MCPSchema.number("Quieter than this counts as silence (default -45).", minimum: -80, maximum: -10),
                "min_silence": MCPSchema.number("Shortest silence to report, seconds (default 0.5).", minimum: 0.1, maximum: 10),
                "beats": MCPSchema.boolean("Also find the tempo and every beat (one clip or file)."),
                "confirm_token": MCPSchema.confirmToken
            ]),
            readOnly: true
        )
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
            labelled with its time. Every frame also gets a short description from macOS Vision: what it shows (rough \
            guesses that are often wrong for unusual footage: trust the picture), \
            faces [x, y, w, h], people, the main subject, words on screen with their boxes, brightness 0–1 and black \
            bars; on the \
            timeline also which clips, texts and subtitles are on screen. If you cannot see images, pass image=false \
            and use the descriptions. Files outside the opened folder need the user's OK (the result asks). \
            To choose footage: files looks at several media files at once (one frame from the middle of each, up to 24); \
            shots=true with file (a video) or clip_id splits it into shots: each shot's start and end and what its middle \
            frame shows, one thumbnail per shot, 24 per call (pass next_from as from for more). A long video is scanned \
            once: the first call may return a job id; wait for it with get_job, then call look again. \
            text_scan=true with file (a video) or clip_id reads the words in a frame every 2 seconds and reports text \
            that stays: a burned-in subtitle band, watermarks, and slides or screens full of text, with where they are.
            """,
            input: MCPSchema.object([
                "time": MCPSchema.number("One moment, seconds (timeline, or in the file with file).", minimum: 0),
                "times": MCPSchema.array(of: MCPSchema.number("Seconds."), "Several moments (up to 12)."),
                "clip_id": MCPSchema.string("Timeline: spread the frames over this clip's part of the timeline."),
                "file": MCPSchema.string("Look at this media file instead of the timeline (absolute, or relative to the opened folder)."),
                "source_in": MCPSchema.number("With file and no times: where to start spreading the frames, seconds.", minimum: 0),
                "source_out": MCPSchema.number("With file and no times: where to stop, seconds.", minimum: 0),
                "count": MCPSchema.integer("How many frames to spread (1–12).", minimum: 1, maximum: 12),
                "files": MCPSchema.array(of: MCPSchema.string("A media file."), "Several media files at once (up to 24)."),
                "shots": MCPSchema.boolean("Split file (a video) or clip_id into shots."),
                "text_scan": MCPSchema.boolean("Scan file (a video) or clip_id for text that stays on screen."),
                "from": MCPSchema.number("With shots: list shots from this time on (next_from of the last call).", minimum: 0),
                "size": MCPSchema.string("Picture size (default medium).", oneOf: ["small", "medium", "large"]),
                "image": MCPSchema.boolean("false: only the text descriptions, no picture (for models that cannot see images)."),
                "confirm_token": MCPSchema.confirmToken
            ]),
            readOnly: true
        )
    }
}
