import Foundation

// MARK: - 工具清单：素材从哪来（音乐库）
//
// 管什么：find_audio 的说明文字和参数。以后「生成素材」（fal.ai，方案第六块）也放这一组。
// 不管什么：怎么搜、怎么下载（App 里的 AIAudioLibraryTools.swift）；把一首放上时间线是 add_clips 的 library_id。

enum MCPMediaTools {
    static func definition(for name: MCPToolName) -> MCPToolDefinition {
        switch name {
        case .findAudio:
            return MCPToolDefinition(
                .findAudio, title: "Find music",
                description: """
                Search SrtFlow's built-in music library. Every track may be used in videos (CC-BY or CC0). query \
                matches titles, artists and tags in English or Chinese; all words must match; an empty query lists \
                everything. Each track comes with its length, tags (mood, genre, use), intensity 1–5, vocals, \
                loudness and credit line. Put one on the timeline with add_clips {library_id}. CC-BY music must be \
                credited: when the video is done, give the user the credit lines (get_timeline lists them as \
                music_credits) for the video's description. There is no sound-effect library yet; never download \
                music or sound effects from the internet instead.
                """,
                input: MCPSchema.object([
                    "query": MCPSchema.string("Words to search for, e.g. \"calm piano\", \"epic\" or \"悲伤\"."),
                    "max_results": MCPSchema.integer("How many tracks to return (default 10).", minimum: 1, maximum: 50)
                ]),
                readOnly: true
            )
        default:
            preconditionFailure("\(name) is not a media tool")
        }
    }
}
