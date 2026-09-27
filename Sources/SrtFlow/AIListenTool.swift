import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - 工具：listen（「听」）
//
// 管什么：AI 听不见，就把声音量给它：一段片段在成片里听到的（段音量 / 曲线、渐入渐出、轨道推子都算上）、一个素材文件、
// 或者整条时间线上每一段有声音的片段 —— 电平（有声音部分的 RMS）、峰值、静音段、最响的地方、一条粗的响度曲线。
// 数据是画波形那一份（WaveformStore：一个文件读一遍，峰值 + 均方），不另读。方案第 31 条（2026-09-27 实测：
// AI 拿用户电脑上的 ffmpeg 量响度）。
// 不管什么：怎么算（AIAudioLevels）、波形怎么读（WaveformStore）、说明文字（SrtFlowMCPKit/MCPSenseTools.swift）。
//
// 只读：不改工程、不动界面。点名文件夹以外的文件照「动硬盘才问」的规矩先问。

@MainActor
enum AIListenTool {
    /// 一次调用最多等波形读多久（客户端对一次调用大多只等一分钟）。没读完就把读到的先给出去，说一声再调一次。
    nonisolated static let waitSeconds = 40.0
    /// 整条时间线一次最多列多少段。
    static let maxClips = 80

    static func listen(_ args: AIToolArguments, _ project: VideoEditProject) async throws -> AIToolResult {
        let silenceDB = min(max(try args.double("silence_db") ?? -45, -80), -10)
        let minSilence = min(max(try args.double("min_silence") ?? 0.5, 0.1), 10)
        let settings = Settings(silenceDB: silenceDB, minSilence: minSilence)
        if let path = try args.string("file") {
            return try await listenToFile(path, args, project, settings)
        }
        let state = project.state
        let ids = AIShortIDs(state: state)
        if let clipText = try args.string("clip_id") {
            let id = try ids.resolve(clipText)
            guard let clip = state.clip(with: id) else { throw AIToolError("\(clipText) is not a clip.") }
            return .ok(.object(await listenToClip(clip, state, ids, settings, detailed: true)))
        }
        return .ok(try await listenToTimeline(state, ids, settings))
    }

    private struct Settings {
        var silenceDB: Double
        var minSilence: Double
    }

    // MARK: 片段

    private static func listenToClip(
        _ clip: EditClip, _ state: TimelineState, _ ids: AIShortIDs, _ settings: Settings, detailed: Bool,
        deadline: Date = Date().addingTimeInterval(waitSeconds)
    ) async -> [String: JSONValue] {
        var object: [String: JSONValue] = [
            "id": .string(ids.short(clip.id)), "name": .string(clip.name),
            "start": AIFormat.seconds(clip.timelineStart), "end": AIFormat.seconds(clip.timelineEnd)
        ]
        if let location = state.location(of: clip.id) { object["track"] = .string(AITrackName.name(of: location.track)) }
        guard clip.hasAudio else {
            object["sound"] = "none: this clip has no audio"
            return object
        }
        // 成片里听不到的：不量（量出来的数会让 AI 以为它在响）。
        if clip.isMuted || clip.isHidden || trackIsHidden(of: clip.id, in: state) {
            object["sound"] = clip.isMuted ? "muted" : "hidden: not in the video"
            return object
        }
        let from = clip.sourceStart
        let to = clip.sourceStart + clip.sourceDuration
        guard let peaks = await waveform(of: clip.sourceURL, until: deadline) else {
            object["sound"] = "unreadable: SrtFlow could not read this clip's audio"
            return object
        }
        guard peaks.isComplete || peaks.duration >= to - 0.01 else {
            object["sound"] = "still reading: SrtFlow is reading this file's audio, call listen again in a moment"
            return object
        }
        let trackGain = state.trackVolume(containingClip: clip.id)
        let heard = AIAudioLevels.heard(AIAudioLevels.windows(peaks, from: from, to: to), clip: clip, trackGain: trackGain)
        let report = AIAudioLevels.report(heard, silenceDB: settings.silenceDB, minSilence: settings.minSilence)
        for (key, value) in AIAudioLevels.json(report, curve: AIAudioLevels.curve(heard), detailed: detailed) {
            object[key] = value
        }
        return object
    }

    /// 整条轨藏起来了（眼睛关着）：上面的段不进成片。
    private static func trackIsHidden(of id: UUID, in state: TimelineState) -> Bool {
        switch state.location(of: id)?.track {
        case .main?: return state.mainHidden
        case .overlay(let index)?: return state.overlayTracks.indices.contains(index) && state.overlayTracks[index].isHidden
        case .audio(let index)?: return state.audioTracks.indices.contains(index) && state.audioTracks[index].isHidden
        case nil: return false
        }
    }

    // MARK: 整条时间线

    private static func listenToTimeline(_ state: TimelineState, _ ids: AIShortIDs, _ settings: Settings) async throws -> JSONValue {
        var clips: [EditClip] = state.mainClips.filter(\.hasAudio)
        for lane in state.overlayTracks { clips += lane.clips.filter(\.hasAudio) }
        for lane in state.audioTracks { clips += lane.clips }
        guard !clips.isEmpty else { throw AIToolError("Nothing on the timeline has sound.") }
        let deadline = Date().addingTimeInterval(waitSeconds)
        var listed: [JSONValue] = []
        for clip in clips.prefix(maxClips) {
            listed.append(.object(await listenToClip(clip, state, ids, settings, detailed: false, deadline: deadline)))
        }
        var result: [String: JSONValue] = [
            "clips": .array(listed),
            "note": "Levels are what the video plays (each clip's volume, fades and track fader included). Call listen with clip_id for one clip's silences and curve."
        ]
        if clips.count > maxClips { result["more_clips"] = .number(Double(clips.count - maxClips)) }
        return .object(result)
    }

    // MARK: 素材文件

    private static func listenToFile(
        _ path: String, _ args: AIToolArguments, _ project: VideoEditProject, _ settings: Settings
    ) async throws -> AIToolResult {
        let url = AIWorkspace.shared.resolve(path)
        guard FileManager.default.fileExists(atPath: url.path) else { throw AIToolError("\(path) does not exist.") }
        if let ask = try AIWorkspace.shared.confirmReading([url], verb: "listen to", args: args, project: project) {
            return ask
        }
        guard let peaks = await waveform(of: url, until: Date().addingTimeInterval(waitSeconds)) else {
            throw AIToolError("\(url.lastPathComponent) has no sound SrtFlow can read.")
        }
        let from = max(0, try args.double("source_in") ?? 0)
        let to = min(try args.double("source_out") ?? peaks.duration, peaks.duration)
        guard to > from else { throw AIToolError("source_out must be after source_in (the file has \(String(format: "%.2f", peaks.duration)) s read).") }
        let windows = AIAudioLevels.windows(peaks, from: from, to: to)
        let report = AIAudioLevels.report(windows, silenceDB: settings.silenceDB, minSilence: settings.minSilence)
        var object: [String: JSONValue] = [
            "listened_to": .string(AIWorkspace.shared.display(url)),
            "from": AIFormat.seconds(from), "to": AIFormat.seconds(to)
        ]
        for (key, value) in AIAudioLevels.json(report, curve: AIAudioLevels.curve(windows), detailed: true) {
            object[key] = value
        }
        if !peaks.isComplete {
            object["note"] = .string(
                "SrtFlow has read the first \(String(format: "%.1f", peaks.duration)) s so far; call listen again for the rest."
            )
        }
        return .ok(.object(object))
    }

    // MARK: 波形

    /// 一个文件的波形（画时间线用的那一份，同一个文件只读一遍）。等到读完或者到点；到点时给出已经读到的部分。
    /// 读不了（没有音轨）返回 nil。
    private static func waveform(of url: URL, until deadline: Date) async -> WaveformPeaks? {
        let reader = Task { () -> WaveformPeaks? in
            var latest: WaveformPeaks?
            for await snapshot in await WaveformStore.shared.peaks(for: url) { latest = snapshot }
            return latest
        }
        let wait = max(0, deadline.timeIntervalSinceNow)
        let timer = Task {
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            reader.cancel()
        }
        let result = await reader.value
        timer.cancel()
        return result
    }
}
