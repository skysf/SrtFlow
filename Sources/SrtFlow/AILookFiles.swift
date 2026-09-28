import Foundation
import SrtFlowMCPKit

// MARK: - look 的 files：一次看好几个文件
//
// 管什么：几个素材文件（最多 `maxFiles` 个）各取一帧 —— 视频取正中那一帧、图片就是它 —— 让 Vision 描述，拼成一张
// 每格一个文件的图。挑素材用：素材A那种几十个小文件，AI 不用一个一个地调 look（第四块，方案第 11 条：不能看图的
// 模型也能按画面挑片段）。一个文件里有几个镜头，用 shots=true 再细看。
// 不管什么：描述和拼图（AILookTool 里共用的那两个）、分镜头（AILookShots）。
//
// 只读。点名文件夹以外的文件照规矩问一次（一次问这一批，AIWorkspace.confirmReading）。

@MainActor
enum AILookFiles {
    static let maxFiles = 24

    static func look(
        _ paths: [String], _ args: AIToolArguments, _ project: VideoEditProject, size: AIContactSheet.Size, wantsImage: Bool
    ) async throws -> AIToolResult {
        guard !paths.isEmpty else { throw AIToolError("files is empty.") }
        guard paths.count <= maxFiles else {
            throw AIToolError("Look at most \(maxFiles) files per call, then call again for the rest.")
        }
        let urls = paths.map { AIWorkspace.shared.resolve($0) }
        if let missing = zip(paths, urls).first(where: { !FileManager.default.fileExists(atPath: $0.1.path) }) {
            throw AIToolError("\(missing.0) does not exist.")
        }
        if let ask = try AIWorkspace.shared.confirmReading(urls, verb: "look at", args: args, project: project) {
            return ask
        }
        var entries: [JSONValue] = []
        var frames: [AIFrameSampler.Frame] = []
        var labels: [String] = []
        for url in urls {
            var entry: [String: JSONValue] = ["file": .string(AIWorkspace.shared.display(url))]
            var frame: AIFrameSampler.Frame?
            if MediaFileTypes.isImage(url) {
                frame = AIFrameSampler.image(at: url, maxSide: 768).map { AIFrameSampler.Frame(time: 0, image: $0) }
            } else {
                let asset = MediaAssetCache.asset(for: url).asset
                let duration = (try? await asset.load(.duration).seconds) ?? 0
                let pictures = (try? await asset.loadTracks(withMediaType: .video)) ?? []
                if pictures.isEmpty {
                    entry["note"] = "sound only: measure it with listen"
                } else {
                    entry["duration"] = AIFormat.seconds(duration)
                    frame = await AIFrameSampler.frames(ofVideo: url, at: [duration / 2], maxSide: 768, tolerance: 0.5).first
                }
            }
            if let frame {
                var seen = await AILookTool.describe(frame).objectValue ?? [:]
                if MediaFileTypes.isImage(url) { seen["time"] = nil }
                entry.merge(seen) { mine, _ in mine }
                frames.append(frame)
                labels.append(label(for: url))
            } else if entry["note"] == nil {
                entry["note"] = "SrtFlow could not read a picture from it"
            }
            entries.append(.object(entry))
        }
        var payload: [String: JSONValue] = [
            "looked_at": "files",
            "files": .array(entries),
            "note": .string(
                "One frame from the middle of each video (time is its second in the file). A video can hold several shots: "
                    + "look at it with shots=true to split it."
            )
        ]
        return AILookTool.finish(&payload, frames: frames, labels: labels, size: size, wantsImage: wantsImage)
    }

    /// 格子里标的名字：太长的留头留尾。
    private static func label(for url: URL) -> String {
        let name = url.lastPathComponent
        guard name.count > 28 else { return name }
        return String(name.prefix(16)) + "…" + String(name.suffix(10))
    }
}
