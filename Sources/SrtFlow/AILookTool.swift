import AVFoundation
import CoreGraphics
import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - 工具：look（「看」）
//
// 管什么：两种看法 —— 不给 file 看**时间线**（成片在那一刻的样子：所有视频轨、裁切摆放、滤镜、形状、文字、字幕，
// AIFrameComposer 合成），给 file 看**素材文件**（挑镜头用，AIFrameSampler 抽帧）。几帧拼成一张（AIContactSheet），
// 每帧配一段文字描述（AIFrameDescription：Vision 认出来的东西、字、亮度、黑边）。看不了图的模型传 image=false，
// 只拿文字。方案第 31 条（2026-09-27 实测：AI 看不见画面，只好拿用户电脑上的 ffmpeg 抽帧）。
// 不管什么：合成 / 抽帧 / 描述 / 拼图本身（各自的文件）、说明文字（SrtFlowMCPKit/MCPSenseTools.swift）。
//
// 只读：不改工程、不动界面（不挪播放头、不摆窗口）。点名文件夹以外的文件照「动硬盘才问」的规矩先问。

@MainActor
enum AILookTool {
    static let maxFrames = 12

    static func look(_ args: AIToolArguments, _ project: VideoEditProject) async throws -> AIToolResult {
        let size = try args.choice("size", from: AIContactSheet.Size.allCases.map(\.rawValue))
            .flatMap(AIContactSheet.Size.init(rawValue:)) ?? .medium
        let wantsImage = try args.bool("image") ?? true
        if let count = try args.int("count"), !(1...maxFrames).contains(count) {
            throw AIToolError("count must be between 1 and \(maxFrames).")
        }
        if let path = try args.string("file") {
            return try await lookAtFile(path, args, project, size: size, wantsImage: wantsImage)
        }
        return try await lookAtTimeline(args, project, size: size, wantsImage: wantsImage)
    }

    // MARK: 时间线

    private static func lookAtTimeline(
        _ args: AIToolArguments, _ project: VideoEditProject, size: AIContactSheet.Size, wantsImage: Bool
    ) async throws -> AIToolResult {
        let state = project.state
        guard !state.isEmpty else { throw AIToolError("The timeline is empty. Add clips first, or pass file to look at a media file.") }
        let ids = AIShortIDs(state: state)
        var times = try requestedTimes(args)
        if times.isEmpty, let clipText = try args.string("clip_id") {
            let id = try ids.resolve(clipText)
            guard let clip = state.clip(with: id) else { throw AIToolError("\(clipText) is not a clip.") }
            times = AIFrameSampler.times(from: clip.timelineStart, to: clip.timelineEnd, count: try args.int("count") ?? 4)
        }
        if times.isEmpty { times = [project.clock.time] }
        let lastFrame = max(0, state.duration - 1 / Double(max(1, state.frameRate.fps)))
        if let beyond = times.first(where: { $0 > state.duration + 0.001 }) {
            throw AIToolError("The timeline is \(String(format: "%.2f", state.duration)) s long; \(beyond) s is past the end.")
        }
        times = times.map { min(max(0, $0), lastFrame) }
        let frames = await AIFrameComposer.frames(of: state, at: times, subtitleStyle: EncodeQueue.burnIn.burnInStyle)
        guard !frames.isEmpty else { throw AIToolError("SrtFlow could not render the timeline at those times.") }
        var described: [JSONValue] = []
        for frame in frames {
            var entry = await describe(frame).objectValue ?? [:]
            entry["on_screen"] = onScreen(state, at: frame.time, ids: ids)
            described.append(.object(entry))
        }
        let canvas = VideoEditCompositionBuilder.renderSize(for: state)
        var payload: [String: JSONValue] = [
            "looked_at": "timeline",
            "canvas": ["width": .number(Double(Int(canvas.width))), "height": .number(Double(Int(canvas.height)))],
            "frames": .array(described)
        ]
        return finish(&payload, frames: frames, size: size, wantsImage: wantsImage)
    }

    /// 这一刻画面上有谁：看得见的片段（哪条轨）、文字、字幕 —— 看不了图的模型靠它对上号。
    private static func onScreen(_ state: TimelineState, at time: Double, ids: AIShortIDs) -> JSONValue {
        var clips: [JSONValue] = []
        var lanes: [(TrackSlot, [EditClip], Bool)] = [(.main, state.mainClips, state.mainHidden)]
        for (index, lane) in state.overlayTracks.enumerated() { lanes.append((.overlay(index), lane.clips, lane.isHidden)) }
        for (slot, laneClips, hidden) in lanes where !hidden {
            for clip in ClipVisibility.visible(laneClips) where clip.contains(time: time) || abs(clip.timelineStart - time) < 0.001 {
                clips.append(.string("\(ids.short(clip.id)) \(clip.name) (\(AITrackName.name(of: slot)))"))
            }
        }
        var object: [String: JSONValue] = ["clips": .array(clips)]
        let texts = state.renderedTextOverlays.filter { $0.contains(time: time) }
        if !texts.isEmpty { object["texts"] = .array(texts.map { .string($0.number != nil ? $0.settledText : $0.text) }) }
        let subtitles = state.subtitleScreenBlocks().compactMap { $0.text(at: time) }
        if !subtitles.isEmpty { object["subtitles"] = .array(subtitles.map { .string($0) }) }
        return .object(object)
    }

    // MARK: 素材文件

    private static func lookAtFile(
        _ path: String, _ args: AIToolArguments, _ project: VideoEditProject, size: AIContactSheet.Size, wantsImage: Bool
    ) async throws -> AIToolResult {
        let url = AIWorkspace.shared.resolve(path)
        guard FileManager.default.fileExists(atPath: url.path) else { throw AIToolError("\(path) does not exist.") }
        if let ask = try AIWorkspace.shared.confirmReading([url], verb: "look at", args: args, project: project) {
            return ask
        }
        var frames: [AIFrameSampler.Frame]
        if MediaFileTypes.isImage(url) {
            frames = AIFrameSampler.image(at: url, maxSide: 1600).map { [AIFrameSampler.Frame(time: 0, image: $0)] } ?? []
        } else {
            let asset = MediaAssetCache.asset(for: url).asset
            guard let tracks = try? await asset.loadTracks(withMediaType: .video), !tracks.isEmpty else {
                throw AIToolError("\(url.lastPathComponent) has no picture. Use listen to measure its sound.")
            }
            let duration = (try? await asset.load(.duration).seconds) ?? 0
            var times = try requestedTimes(args)
            if times.isEmpty {
                let from = min(max(0, try args.double("source_in") ?? 0), duration)
                let to = min(max(from, try args.double("source_out") ?? duration), duration)
                times = AIFrameSampler.times(from: from, to: to, count: try args.int("count") ?? 6)
            }
            times = times.map { min(max(0, $0), max(0, duration - 0.05)) }
            frames = await AIFrameSampler.frames(ofVideo: url, at: times, maxSide: 1280, tolerance: 0.1)
        }
        guard !frames.isEmpty else { throw AIToolError("SrtFlow could not read pictures from \(url.lastPathComponent).") }
        var described: [JSONValue] = []
        for frame in frames { described.append(await describe(frame)) }
        var payload: [String: JSONValue] = [
            "looked_at": .string(AIWorkspace.shared.display(url)),
            "frames": .array(described)
        ]
        if let first = frames.first?.image {
            payload["picture_size"] = ["width": .number(Double(first.width)), "height": .number(Double(first.height))]
        }
        return finish(&payload, frames: frames, size: size, wantsImage: wantsImage)
    }

    // MARK: 共用

    /// `time` 或 `times`（最多 12 个）。
    private static func requestedTimes(_ args: AIToolArguments) throws -> [Double] {
        var times: [Double] = []
        if let time = try args.double("time") { times.append(time) }
        if let list = try args.array("times") {
            for item in list {
                guard case .number(let value) = item, value.isFinite else { throw AIToolError("Every entry of times must be a number.") }
                times.append(value)
            }
        }
        guard times.count <= maxFrames else { throw AIToolError("Look at most \(maxFrames) moments per call.") }
        return times
    }

    /// 一帧的文字描述：Vision 认一遍（缩小到 768 再认，够用又快）。
    private static func describe(_ frame: AIFrameSampler.Frame) async -> JSONValue {
        let small = AIContactSheet.scaled(frame.image, maxSide: 768) ?? frame.image
        let vision = await AIVision.analyze(small, [.subject, .labels, .text])
        return AIFrameDescription.describe(.init(time: frame.time, luma: AIBlackBars.luma(of: small), vision: vision))
    }

    /// 拼图、写上「图怎么读」，装进结果。
    private static func finish(
        _ payload: inout [String: JSONValue], frames: [AIFrameSampler.Frame], size: AIContactSheet.Size, wantsImage: Bool
    ) -> AIToolResult {
        var result = AIToolResult.ok(.object(payload))
        guard wantsImage else { return result }
        let labelled = frames.map { (label: String(format: "%.2fs", $0.time), image: $0.image) }
        guard let sheet = AIContactSheet.draw(labelled, size: size), let jpeg = AIContactSheet.jpeg(sheet) else {
            payload["image"] = "SrtFlow could not draw the picture; the descriptions above are all there is."
            return .ok(.object(payload))
        }
        if frames.count > 1 {
            let aspect = Double(frames[0].image.width) / Double(max(1, frames[0].image.height))
            let grid = AIContactSheet.grid(count: frames.count, aspect: aspect)
            payload["image"] = .string(
                "One picture: \(grid.columns) columns × \(grid.rows) rows, read left to right, top to bottom; "
                + "each frame is labelled with its time."
            )
        }
        result = .ok(.object(payload))
        result.images = [jpeg]
        return result
    }
}
