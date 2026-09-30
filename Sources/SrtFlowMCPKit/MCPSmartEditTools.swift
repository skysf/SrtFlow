import Foundation

// MARK: - 工具清单：分析数据 + 智能剪（方案第 13 条、第 3 块）
//
// 管什么：transcribe（词级时间）、cut_speech（按文字剪、删停顿和口头禅）、cut_to_beat（踩点）的说明文字和参数。
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
        case .cutSpeech:
            let range = MCPSchema.object([
                "start": MCPSchema.number("Timeline seconds.", minimum: 0),
                "end": MCPSchema.number("Timeline seconds.", minimum: 0)
            ], required: ["start", "end"])
            return MCPToolDefinition(
                .cutSpeech, title: "Cut speech",
                description: """
                Tighten a talking clip on V1 in one step: cut out ranges (by text — pass sentence or word times from \
                transcribe), or keep only some ranges; shorten pauses; remove filler words (um, uh and Chinese ones) and words \
                said twice in a row. Cuts land in the gaps between words, never inside one. The clip becomes pieces \
                placed back to back and later V1 clips move left; the clip's linked sound is cut with it even when \
                linking is off. Music, texts and subtitles on other tracks do not move — regenerate subtitles \
                afterwards (the transcript is cached, so it is quick). Filler words and repeats need transcribe first. \
                One undo step. Returns what was removed (times before the cut) and the new pieces.
                """,
                input: MCPSchema.object([
                    "clip_id": MCPSchema.string("The talking clip on V1."),
                    "remove": MCPSchema.array(of: range, "Ranges to cut out."),
                    "keep": MCPSchema.array(of: range, "Keep only these ranges of the clip; the rest of it is cut."),
                    "remove_pauses": MCPSchema.number("Shorten pauses longer than this many seconds (e.g. 0.6).", minimum: 0.2),
                    "pause_left": MCPSchema.number("Seconds of each shortened pause to leave (default 0.25).", minimum: 0, maximum: 2),
                    "remove_fillers": MCPSchema.boolean("Cut filler words (needs transcribe first)."),
                    "remove_repeats": MCPSchema.boolean("Cut words said twice in a row, like \"I I\" (needs transcribe first)."),
                    "silence_db": MCPSchema.number("Quieter than this counts as a pause (default: measured from the clip).", minimum: -80, maximum: -10),
                    "language": MCPSchema.string("Language of the transcript to use (default auto).")
                ], required: ["clip_id"])
            )
        case .cutToBeat:
            return MCPToolDefinition(
                .cutToBeat, title: "Cut to the beat",
                description: """
                Re-time a run of V1 clips so every cut lands on a beat of a music clip. The first clip keeps its start; \
                each clip keeps its in point and gets a new out point on a beat — the beat nearest to where it ends now, \
                or exactly beats_per_clip beats (fewer when the media is too short). on=downbeats cuts only on the first \
                beat of each bar. Clips stay at least 0.4 s long; a clip that cannot reach a beat keeps its length. Later \
                V1 clips move with the change and the clips' linked sound follows; the music does not move. Needs music \
                with a steady beat (listen with beats=true shows it). One undo step.
                """,
                input: MCPSchema.object([
                    "music_clip_id": MCPSchema.string("The music clip whose beats to cut on."),
                    "clip_ids": MCPSchema.array(of: MCPSchema.string("Clip id."), "V1 clips next to each other (default: the V1 clips playing while the music does)."),
                    "beats_per_clip": MCPSchema.integer("Every clip lasts exactly this many beats.", minimum: 1, maximum: 64),
                    "on": MCPSchema.string("Cut on every beat (default) or only on the first beat of each bar.", oneOf: ["beats", "downbeats"])
                ], required: ["music_clip_id"])
            )
        default:
            preconditionFailure("\(name.rawValue) is described in another group")
        }
    }
}
