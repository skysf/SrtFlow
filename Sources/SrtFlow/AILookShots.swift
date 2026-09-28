import CoreGraphics
import Foundation
import SrtFlowMCPKit

// MARK: - look 的 shots=true：分镜头，每个镜头一段描述、一格缩略图
//
// 管什么：一个视频文件（或时间线上一段用到的那一截）按镜头切换点分开（AIShotScan），每个镜头取中间那一帧，
// 让 Vision 描述（和别的「看」同一份 AIFrameDescription），拼成一张每格一个镜头的图。第四块「本机识别画面」
// （方案第 11 条：镜头切换、标签、人脸；不能看图的模型也能按画面挑片段）。一页最多 `pageSize` 个，
// 多了用 from 往下翻。长视频第一次扫要一会儿：最多等 `waitSeconds`，没扫完就回任务号（扫完的结果进缓存，
// AI 等任务结束再调一次就是现成的）。
// 不管什么：怎么扫、怎么判断切点（AIShotScan、AIShotDetector）、描述和拼图（AILookTool 里共用的那两个）。
//
// 只读。点名文件夹以外的文件照规矩问一次（AIWorkspace.confirmReading）。

@MainActor
enum AILookShots {
    static let pageSize = 24
    static let waitSeconds = 20.0

    private struct Target {
        var url: URL
        /// 看文件的哪一截（源秒）；上限可能比文件长，扫完再裁。
        var range: ClosedRange<Double>
        /// 看的是时间线上的一段：时间按时间线写，再附上源秒。
        var clip: EditClip?
    }

    static func look(
        _ args: AIToolArguments, _ project: VideoEditProject, size: AIContactSheet.Size, wantsImage: Bool
    ) async throws -> AIToolResult {
        let target: Target
        switch try resolve(args, project) {
        case .ask(let question): return question
        case .target(let found): target = found
        }
        var scanned = try await AIShotScan.result(for: target.url, waiting: waitSeconds)
        if scanned == nil {
            if let job = AIShotScan.job(for: target.url) {
                return .ok([
                    "job_id": .string(job.id),
                    "status": "running",
                    "next_step": .string(
                        "SrtFlow is going through every frame of this video to find its shots; long videos take a while. "
                            + "Call get_job with this job_id and wait_seconds 30 until the status is done, then call look "
                            + "again with the same arguments (it answers at once then)."
                    )
                ])
            }
            scanned = AIShotScan.cached(target.url)
        }
        guard let scanned else { throw AIToolError("SrtFlow could not find the shots in \(target.url.lastPathComponent).") }

        let upper = min(target.range.upperBound, scanned.duration)
        let lower = min(target.range.lowerBound, upper)
        let shots = AIShotDetector.shots(scanned.shots, within: lower...upper)
        let from = try args.double("from").map { target.clip?.sourceTime(atTimeline: $0) ?? $0 }
        let page = AIShotDetector.page(shots, from: from, size: pageSize)
        guard !page.items.isEmpty else { throw AIToolError("There are no shots after \(from ?? 0) s.") }

        let middles = page.items.map { ($0.shot.start + $0.shot.end) / 2 }
        let frames = await AIFrameSampler.frames(ofVideo: target.url, at: middles, maxSide: 768, tolerance: 0.2)
        var described: [JSONValue] = []
        var labels: [String] = []
        for item in page.items {
            var entry: [String: JSONValue] = ["shot": .number(Double(item.number))]
            if let clip = target.clip {
                entry["start"] = AIFormat.seconds(clip.timelineTime(atSource: item.shot.start))
                entry["end"] = AIFormat.seconds(clip.timelineTime(atSource: item.shot.end))
                entry["source_in"] = AIFormat.seconds(item.shot.start)
                entry["source_out"] = AIFormat.seconds(item.shot.end)
            } else {
                entry["start"] = AIFormat.seconds(item.shot.start)
                entry["end"] = AIFormat.seconds(item.shot.end)
            }
            if let frame = frames.first(where: { abs($0.time - (item.shot.start + item.shot.end) / 2) < 0.001 }) {
                var seen = await AILookTool.describe(frame).objectValue ?? [:]
                seen["time"] = nil
                entry.merge(seen) { mine, _ in mine }
            }
            described.append(.object(entry))
            labels.append(String(format: "#%d %.1fs", item.number, entry["start"]?.doubleValue ?? item.shot.start))
        }
        var payload: [String: JSONValue] = [
            "looked_at": .string(target.clip.map { "clip \(AIShortIDs(state: project.state).short($0.id)) (\($0.name))" }
                ?? AIWorkspace.shared.display(target.url)),
            "shot_count": .number(Double(shots.count)),
            "shots": .array(described),
            "note": .string(
                "Each shot is described from its middle frame. Times are "
                    + (target.clip == nil ? "seconds in the file (use them as source_in / source_out in add_clips)."
                        : "timeline seconds (split_clip there to cut the clip into its shots); source_in / source_out are the file's.")
            )
        ]
        if let next = page.next {
            payload["next_from"] = AIFormat.seconds(target.clip?.timelineTime(atSource: next) ?? next)
        }
        let shown = frames.filter { frame in middles.contains { abs($0 - frame.time) < 0.001 } }
        let shownLabels = shown.map { frame in labels[middles.firstIndex { abs($0 - frame.time) < 0.001 } ?? 0] }
        return AILookTool.finish(&payload, frames: shown, labels: shownLabels, size: size, wantsImage: wantsImage)
    }

    private enum Resolution {
        case ask(AIToolResult)
        case target(Target)
    }

    private static func resolve(_ args: AIToolArguments, _ project: VideoEditProject) throws -> Resolution {
        if let path = try args.string("file") {
            let url = AIWorkspace.shared.resolve(path)
            guard FileManager.default.fileExists(atPath: url.path) else { throw AIToolError("\(path) does not exist.") }
            if let ask = try AIWorkspace.shared.confirmReading([url], verb: "look at", args: args, project: project) {
                return .ask(ask)
            }
            guard !MediaFileTypes.isImage(url) else {
                throw AIToolError("\(url.lastPathComponent) is a still picture, so it is one shot. Look at it without shots.")
            }
            let lower = max(0, try args.double("source_in") ?? 0)
            let upper = max(lower, try args.double("source_out") ?? .greatestFiniteMagnitude)
            return .target(Target(url: url, range: lower...upper, clip: nil))
        }
        guard let text = try args.string("clip_id") else { throw AIToolError("With shots=true pass file (a video) or clip_id.") }
        let state = project.state
        guard let clip = state.clip(with: try AIShortIDs(state: state).resolve(text)) else { throw AIToolError("\(text) is not a clip.") }
        guard !clip.isAudioOnly, !clip.isStillImage else {
            throw AIToolError("\(clip.name) has no moving picture to split into shots.")
        }
        return .target(Target(url: clip.sourceURL, range: clip.sourceStart...(clip.sourceStart + clip.sourceDuration), clip: clip))
    }
}
