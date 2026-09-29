import AVFoundation
import Foundation
import SrtFlowMCPKit

// MARK: - look 的 text_scan=true：扫一遍画面里的字
//
// 管什么：一个视频文件（或时间线上一段用到的那一截）每隔约 2 秒认一帧字（AIVision 的 accurate，带框），最多
// `maxFrames` 帧（长的就摊开），交给 AITextRegions 叠起来统计：烧进去的字幕带、固定的字（水印、台标）、满屏的字。
// 方案第 55 条（2026-09-28 用户转来的 AI 反馈：look 只回字不回位置，只好一帧帧抽出来猜）。只回文字，不拼图 ——
// 要看哪一帧照常调 look。
// 不管什么：怎么统计（AITextRegions）、看哪个（AILookTarget）。
//
// 只读。点名文件夹以外的文件照规矩问一次。

@MainActor
enum AILookText {
    static let spacing = 2.0
    static let maxFrames = 24

    static func look(_ args: AIToolArguments, _ project: VideoEditProject) async throws -> AIToolResult {
        let target: AILookTarget
        switch try AILookTarget.resolve(args, project, option: "text_scan", stillImage: {
            "\($0) has no moving picture to scan; look at it without text_scan (the description lists its words and where they are)."
        }) {
        case .ask(let question): return question
        case .target(let found): target = found
        }
        let duration = (try? await MediaAssetCache.asset(for: target.url).asset.load(.duration).seconds) ?? 0
        let upper = min(target.range.upperBound, duration)
        let lower = min(target.range.lowerBound, upper)
        guard upper - lower > 0.2 else { throw AIToolError("There is nothing to scan between \(lower) and \(upper) s.") }
        let count = min(maxFrames, max(3, Int(((upper - lower) / spacing).rounded(.up))))
        let frames = await AIFrameSampler.frames(
            ofVideo: target.url, at: AIFrameSampler.times(from: lower, to: upper, count: count), maxSide: 1280, tolerance: 0.5
        )
        guard !frames.isEmpty else { throw AIToolError("SrtFlow could not read pictures from \(target.url.lastPathComponent).") }
        var scanned: [AITextRegions.Frame] = []
        for frame in frames {
            scanned.append(.init(time: frame.time, texts: await AIVision.analyze(frame.image, .text).texts))
        }
        let report = AITextRegions.report(scanned)
        let timeline: (Double) -> Double = { target.clip?.timelineTime(atSource: $0) ?? $0 }
        var payload = AITextRegions.json(report, timeline: timeline)
        // 看的是时间线上的一段：再给出盖住它的 set_shape 参数（源画面上的框换成画布上的；方案第 56 条）。
        if let clip = target.clip {
            AICoverBox.annotate(&payload, report: report, clip: clip, canvas: VideoEditCompositionBuilder.renderSize(for: project.state), timeline: timeline)
        }
        payload["looked_at"] = .string(target.label(project))
        payload["scanned_frames"] = .number(Double(scanned.count))
        payload["every_seconds"] = AIFormat.seconds((upper - lower) / Double(count))
        payload["note"] = .string(
            "Boxes are [x, y, width, height] as fractions of the source picture from its top left; in_frames is the share of "
                + "scanned frames that show it. Times are " + (target.clip == nil ? "seconds in the file." : "timeline seconds.")
        )
        return .ok(.object(payload))
    }
}
