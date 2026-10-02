import Foundation
import SrtFlowMCPKit

// MARK: - 工具：cut_to_beat（音乐踩点，第 3 块的智能剪）
//
// 管什么：参数 → 哪一段音乐、V1 上哪一串片段、每段几拍 / 踩在拍上还是小节头上；`plan` 可以 await（找鼓点，AIBeats），
// `apply` 同步落到时间线上（`AIBeatCuts.apply`，路由包 `AIUndoGrouping.step`，同 cut_speech）。拍子不清楚（可信度低于
// `AudioBeatTracker.clearConfidence`）就不踩，照实告诉 AI。中途时间线变了就不落，请 AI 重来。
// 不管什么：怎么排（AIBeatCuts，纯值）、说明文字（SrtFlowMCPKit/MCPSmartEditTools.swift）。

@MainActor
enum AIBeatCutTool {
    struct Plan {
        var placed: [AIBeatCuts.Placed]
        var state: TimelineState
        var generation: Int
        var bpm: Double
        var on: String
    }

    static func plan(_ args: AIToolArguments, _ project: VideoEditProject) async throws -> Plan {
        let state = project.state
        let ids = AIShortIDs(state: state)
        let musicText = try args.requiredString("music_clip_id")
        guard let music = state.clip(with: try ids.resolve(musicText)), music.hasAudio else {
            throw AIToolError("\(musicText) is not a clip with sound.")
        }
        let chosen = try clips(args, ids, state, playingWith: music)
        let on = try args.choice("on", from: ["beats", "downbeats"]) ?? "beats"
        let perClip = try args.int("beats_per_clip").map { min(max($0, 1), 64) }
        let analysis = try await AIBeats.analysis(
            of: music.sourceURL, from: music.sourceStart, to: music.sourceStart + music.sourceDuration
        )
        guard let analysis, analysis.confidence >= AudioBeatTracker.clearConfidence else {
            throw AIToolError(
                "\(music.name) has no clear, steady beat, so cuts on it would not feel on time. Pick music with a clear "
                    + "beat (find_audio; listen with beats=true shows it) or cut by hand."
            )
        }
        let beats = AIBeatCuts.onFrames((on == "downbeats" ? analysis.downbeats : analysis.beats)
            .map { music.timelineTime(atSource: $0) }
            .filter { $0 >= music.timelineStart - 0.001 && $0 <= music.timelineEnd + 0.001 }, frame: state.frameRate.secondsPerFrame)
        let placed = AIBeatCuts.layout(chosen.map { clip in
            AIBeatCuts.Clip(
                id: clip.id, start: clip.timelineStart, duration: clip.timelineDuration,
                maxDuration: max(clip.timelineDuration, (clip.assetDuration - clip.sourceStart) / max(0.05, clip.speed))
            )
        }, beats: beats, beatsPerClip: perClip)
        return Plan(placed: placed, state: state, generation: project.documentGeneration, bpm: analysis.bpm * music.speed, on: on)
    }

    static func apply(_ plan: Plan, _ project: VideoEditProject) throws -> AIToolResult {
        guard project.isCurrentGeneration(plan.generation), project.state == plan.state else {
            throw AIToolError("The timeline changed while SrtFlow was finding the beats. Call cut_to_beat again.")
        }
        var next = plan.state
        AIBeatCuts.apply(plan.placed, in: &next)
        let linkage = project.perform { $0 = next }
        let ids = AIShortIDs(state: project.state)
        var result: [String: JSONValue] = [
            "tempo_bpm": .number((plan.bpm * 10).rounded() / 10),
            "on": .string(plan.on),
            "clips": .array(plan.placed.map { placed in
                var entry: [String: JSONValue] = [
                    "id": .string(ids.short(placed.id)),
                    "start": AIFormat.seconds(placed.start),
                    "end": AIFormat.seconds(placed.start + placed.duration)
                ]
                if let beats = placed.beats { entry["beats"] = .number(Double(beats)) } else { entry["on_beat"] = false }
                return .object(entry)
            }),
            "timeline_duration": AIFormat.seconds(project.state.duration)
        ]
        if let followed = AILinkageReport.json(linkage) { result["linkage"] = followed }
        let missed = plan.placed.filter { $0.beats == nil }.count
        if missed > 0 {
            result["note"] = .string(
                "\(missed) clip(s) kept their length: too short for a beat, or the music ended. The music itself did not move."
            )
        }
        AIEditorPresenter.reveal(.init(clips: Set(plan.placed.map(\.id)), time: plan.placed.first?.start), project: project)
        return .ok(.object(result), changed: true)
    }

    /// 给了 clip_ids 就是它们（必须都在 V1 上、一个挨一个）；没给就是 V1 上和音乐同时在放的那一串。
    private static func clips(
        _ args: AIToolArguments, _ ids: AIShortIDs, _ state: TimelineState, playingWith music: EditClip
    ) throws -> [EditClip] {
        let main = state.mainClips
        if let list = try args.stringArray("clip_ids") {
            let wanted = Set(try list.map { try ids.resolve($0) })
            let indices = main.indices.filter { wanted.contains(main[$0].id) }
            guard indices.count == wanted.count else {
                throw AIToolError("cut_to_beat re-times V1 clips; some of clip_ids are not on V1.")
            }
            guard let first = indices.first, let last = indices.last, indices == Array(first...last) else {
                throw AIToolError("clip_ids must follow each other on V1, with no other V1 clip between them.")
            }
            return indices.map { main[$0] }
        }
        let playing = main.filter { $0.timelineEnd > music.timelineStart + 0.01 && $0.timelineStart < music.timelineEnd - 0.01 }
        guard !playing.isEmpty else { throw AIToolError("No V1 clip plays while \(music.name) does.") }
        return playing
    }
}
