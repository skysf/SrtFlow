import Foundation

// MARK: - 工具清单：素材从哪来（音乐库）
//
// 管什么：find_audio、add_voiceover 的说明文字和参数。以后「生成素材」（fal.ai，方案第六块）也放这一组。
// 不管什么：怎么搜、怎么下载（App 里的 AIAudioLibraryTools.swift）；把一首放上时间线是 add_clips 的 library_id；
// 配音怎么做（App 里的 AIVoiceoverTool / AISpeechSynthesis）。

enum MCPMediaTools {
    static func definition(for name: MCPToolName) -> MCPToolDefinition {
        switch name {
        case .findAudio:
            return MCPToolDefinition(
                .findAudio, title: "Find music",
                description: """
                Search SrtFlow's built-in music library (every track may be used in videos: CC-BY or CC0). query matches titles, \
                artists and tags in English or Chinese; all words must match; an empty query lists everything. Each track comes \
                with its length, tags (mood, genre, use), intensity 1–5, vocals, loudness and credit line. Put one on the \
                timeline with add_clips {library_id}. CC-BY music must be credited: when the video is done, give the user the \
                credit lines (get_timeline lists them as music_credits) for the video's description. Sound effects (whoosh, \
                riser, impact, pop…) come from add_clips sound_effect, made on this Mac; never download music or sound effects \
                from the internet.
                """,
                input: MCPSchema.object([
                    "query": MCPSchema.string("Words to search for, e.g. \"calm piano\" or \"epic\" (Chinese words work too)."),
                    "max_results": MCPSchema.integer("How many tracks to return (default 10).", minimum: 1, maximum: 50)
                ]),
                readOnly: true
            )
        case .addVoiceover:
            return MCPToolDefinition(
                .addVoiceover, title: "Add a voiceover",
                description: """
                Speak narration and put each line on an audio track as its own clip (a new audio track unless track is given; \
                all lines of one call go on the same track). Voices, best first: fal.ai's (when the user connected fal.ai and \
                today's cost limit allows it; a role maps to a matching voice, or name one such as Rachel or Brian; the result's \
                voice note says when it was not used), then SrtFlow's own voices (English, Chinese, Japanese, Spanish, French, \
                Italian, Portuguese, Hindi) when downloaded, otherwise this Mac's voices, which sound much worse; \
                download_voices=true downloads SrtFlow's voices (a job, about 333 MB; tell the user). voice is a role — \
                zh_female_lively, zh_female_warm, zh_male, en_female_lively, en_female_warm, en_male, en_female_british, \
                en_male_british — one of SrtFlow's voices by name (af_heart, zf_xiaoxiao…), or a Mac voice's name; without it, a \
                warm female voice in the text's language. clone_from clones a voice with fal.ai from a file (audio or video) of \
                one person speaking clearly. The files go into SrtFlow/Voiceovers in the user's folder. subtitles=true also \
                writes the words as subtitles, timed to the voice (lines over existing subtitles are left out). Pass on the \
                result's voice note to the user.
                """,
                input: MCPSchema.object([
                    "lines": MCPSchema.array(of: MCPSchema.object([
                        "text": MCPSchema.string("What to say."),
                        "start": MCPSchema.number("Timeline seconds (default: right after the previous line; the first at the playhead).", minimum: 0)
                    ], required: ["text"]), "The lines of narration, in order (not needed with download_voices).", minItems: 1),
                    "voice": MCPSchema.string("A role or an installed voice's name."),
                    "speed": MCPSchema.number("1 = normal (default). Not used by fal.ai's voice.", minimum: 0.5, maximum: 2),
                    "clone_from": MCPSchema.string("A file of one person speaking; the lines are spoken in that voice (fal.ai only)."),
                    "clone_start": MCPSchema.number("Seconds into clone_from where the sample starts (default 0).", minimum: 0),
                    "clone_seconds": MCPSchema.number("Length of the sample (default 10).", minimum: 5, maximum: 30),
                    "track": MCPSchema.string(MCPSchema.trackDescription),
                    "subtitles": MCPSchema.boolean("Also add the words as subtitles, timed to the voice."),
                    "download_voices": MCPSchema.boolean("Only download SrtFlow's own voices (returns a job); lines are ignored.")
                ])
            )
        default:
            preconditionFailure("\(name) is not a media tool")
        }
    }
}
