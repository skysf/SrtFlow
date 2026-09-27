import Foundation

// MARK: - 工具清单：分析数据 + 智能剪（方案第 13 条、第 3 块）
//
// 管什么：transcribe（词级时间）的说明文字和参数。以后 cut_speech（按文字剪、删停顿和口头禅）、cut_to_beat（踩点）也放这一组。
// 静音段和鼓点在 listen 里（MCPSenseTools）。
// 不管什么：怎么转写、读哪份缓存（App 里的 AITranscribeTool）。

enum MCPSmartEditTools {
    static func definition(for name: MCPToolName) -> MCPToolDefinition {
        switch name {
        case .transcribe:
            return MCPToolDefinition(
                .transcribe, title: "Transcribe speech",
                description: """
                What is said where, with timings: sentences (start, end, text) and, with words=true, every word. For \
                clips on the timeline (default: every video-track clip with sound; audio-only clips such as music only \
                when named in clip_ids) times are timeline seconds; for a file they are seconds in the file. Media that \
                was never transcribed is transcribed on this Mac first: the result is then a job id — wait with get_job, \
                then call transcribe again with the same arguments (it reads the cache instantly; subtitles generated \
                in SrtFlow earlier count too). Long transcripts come in pieces: call again with from = next_from. Use it \
                to pick what to keep for a promo, or to find mistakes and filler words, then cut with cut_speech.
                """,
                input: MCPSchema.object([
                    "clip_ids": MCPSchema.array(of: MCPSchema.string("Clip id."), "Clips to transcribe (default: video-track clips with sound)."),
                    "file": MCPSchema.string("A media file instead of clips (absolute, or relative to the opened folder)."),
                    "source_in": MCPSchema.number("With file: start, seconds in the file.", minimum: 0),
                    "source_out": MCPSchema.number("With file: end, seconds in the file.", minimum: 0),
                    "language": MCPSchema.string("Spoken language, e.g. en, zh-Hans, ja; auto (default) detects it."),
                    "from": MCPSchema.number("Read from this time on (timeline seconds, or file seconds with file).", minimum: 0),
                    "to": MCPSchema.number("Read up to this time.", minimum: 0),
                    "words": MCPSchema.boolean("Also list every word with its start and end (for precise cuts)."),
                    "max_chars": MCPSchema.integer("Roughly how much text per call (default 12000).", minimum: 1000, maximum: 60000),
                    "confirm_token": MCPSchema.confirmToken
                ]),
                readOnly: true
            )
        default:
            preconditionFailure("\(name.rawValue) is described in another group")
        }
    }
}
