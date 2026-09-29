import Foundation

// MARK: - look 看一整个视频时看哪个：file，或者时间线上一段用到的那一截
//
// 管什么：shots=true（分镜头）和 text_scan=true（扫画面里的字）都是「一个视频文件的一截」：给了 file 就是那个文件
// （source_in / source_out 圈一截），给了 clip_id 就是那一段用到的那一截（时间换成时间线秒写回去）。点名文件夹以外的
// 文件照规矩问一次（AIWorkspace.confirmReading）。
// 不管什么：看了之后做什么（AILookShots、AILookText）。

@MainActor
struct AILookTarget {
    var url: URL
    /// 看文件的哪一截（源秒）；上限可能比文件长，调用方按文件长度再裁。
    var range: ClosedRange<Double>
    /// 看的是时间线上的一段：时间按时间线写，再附上源秒。
    var clip: EditClip?

    enum Resolution {
        case ask(AIToolResult)
        case target(AILookTarget)
    }

    /// `option` 是这种看法的参数名（报错时说）；`stillImage` 是给了一张图片时怎么说。
    static func resolve(
        _ args: AIToolArguments, _ project: VideoEditProject, option: String, stillImage: (String) -> String
    ) throws -> Resolution {
        if let path = try args.string("file") {
            let url = AIWorkspace.shared.resolve(path)
            guard FileManager.default.fileExists(atPath: url.path) else { throw AIToolError("\(path) does not exist.") }
            if let ask = try AIWorkspace.shared.confirmReading([url], verb: "look at", args: args, project: project) {
                return .ask(ask)
            }
            guard !MediaFileTypes.isImage(url) else { throw AIToolError(stillImage(url.lastPathComponent)) }
            let lower = max(0, try args.double("source_in") ?? 0)
            let upper = max(lower, try args.double("source_out") ?? .greatestFiniteMagnitude)
            return .target(AILookTarget(url: url, range: lower...upper, clip: nil))
        }
        guard let text = try args.string("clip_id") else { throw AIToolError("With \(option)=true pass file (a video) or clip_id.") }
        let state = project.state
        guard let clip = state.clip(with: try AIShortIDs(state: state).resolve(text)) else { throw AIToolError("\(text) is not a clip.") }
        guard !clip.isAudioOnly, !clip.isStillImage else { throw AIToolError(stillImage(clip.name)) }
        return .target(AILookTarget(url: clip.sourceURL, range: clip.sourceStart...(clip.sourceStart + clip.sourceDuration), clip: clip))
    }

    /// 回给 AI 的「看的是什么」。
    func label(_ project: VideoEditProject) -> String {
        clip.map { "clip \(AIShortIDs(state: project.state).short($0.id)) (\($0.name))" } ?? AIWorkspace.shared.display(url)
    }
}
