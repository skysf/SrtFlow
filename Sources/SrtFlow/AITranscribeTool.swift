import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - 工具：transcribe（方案第 13 条：词级时间这份原始数据）
//
// 管什么：几段素材（时间线上的片段，或者一个文件）里说了什么、在哪儿说的。转写和生成字幕是同一套
// （`TranscriptHarvester`：定语言、备模型、按窗转写、落缓存），缓存也是同一份（按素材指纹存源时间的词流 + 分析过的区间）：
// 缓存已经覆盖要的区间就当场按句读出来（`SpeechTranscript` + `AITranscriptFormat`）；没覆盖就起一个任务
// （`TranscriptionTask.transcribeOnly`，和生成字幕共用串行槽），AI 用 get_job 等完再调一次来读 —— 那时是秒回。
// 不管什么：按句读出来之后怎么剪（cut_speech）；说明文字（SrtFlowMCPKit/MCPSmartEditTools.swift）。
//
// 语言：给了就用它的缓存；auto 时先认这次运行里检测过的，没有就看已装语言里哪份缓存覆盖了、可信度最高 ——
// 用户在面板上生成过字幕的素材，AI 不用再转一遍。

@available(macOS 26.0, *)
@MainActor
enum AITranscribeTool {
    struct Target {
        var sound: SubtitleAudibleClips.SoundClip
        var id: String?
        var track: String?

        var window: SubtitleClipWindow {
            SubtitleClipWindow(
                clipID: sound.clipID, assetFingerprint: sound.fingerprint, sourceStart: sound.sourceStart,
                sourceEnd: sound.sourceStart + sound.sourceDuration, timelineStart: sound.timelineStart,
                speed: sound.speed, laneRank: sound.laneRank
            )
        }
    }

    /// auto 转过之后检测出来的语言（按素材指纹）。只在这次运行里记着；重开 App 后靠已装语言的缓存再认出来。
    private static var detected: [String: String] = [:]

    static func transcribe(_ args: AIToolArguments, _ project: VideoEditProject) async throws -> AIToolResult {
        guard SpeechTranscriptionService.isAvailable else { throw AIToolError("Speech transcription is not available on this Mac.") }
        let language = try args.string("language") ?? "auto"
        // 给了文件：先问（点名文件夹以外的要用户点头），问过了才去读它。
        if let path = try args.string("file") {
            let url = AIWorkspace.shared.resolve(path)
            guard FileManager.default.fileExists(atPath: url.path) else { throw AIToolError("\(path) does not exist.") }
            if let ask = try AIWorkspace.shared.confirmReading([url], verb: "listen to", args: args, project: project) {
                return ask
            }
        }
        let targets = try await targets(args, project)
        if let cached = await cached(targets.map(\.sound), language: language) {
            let clips = targets.map { target in
                AITranscriptFormat.Clip(
                    id: target.id, track: target.track, name: target.sound.name,
                    start: target.window.timelineStart, end: target.window.timelineEnd,
                    sentences: SpeechTranscript.sentences(
                        words: cached.entries[target.sound.fingerprint]?.words ?? [], window: target.window
                    )
                )
            }
            let maxChars = min(max(try args.int("max_chars") ?? AITranscriptFormat.defaultMaxChars, 1_000), 60_000)
            return .ok(AITranscriptFormat.json(
                clips, language: cached.locale, from: try args.double("from"), to: try args.double("to"),
                words: try args.bool("words") ?? false, maxChars: maxChars
            ))
        }
        return try start(targets.map(\.sound), language: language)
    }

    // MARK: 转写任务

    private static func start(_ sounds: [SubtitleAudibleClips.SoundClip], language: String) throws -> AIToolResult {
        let task = TranscriptionTask.shared
        guard !task.isRunning else {
            throw AIToolError(
                "SrtFlow is already transcribing (generating subtitles or another transcript). Wait for that job with "
                    + "get_job, then call transcribe again."
            )
        }
        let sourceID = language.lowercased() == "auto" ? TranscriptionTask.autoDetectLocaleID : language
        // 任务自己的进度到 0.85 为止（后面那截是生成字幕的分段、写回），这里只转写，折成 0–1。
        let job = AIJobs.shared.start(.transcript, progress: { task.isRunning ? min(1, task.progress / 0.85) : nil },
                                      cancel: { task.cancel() })
        Task { @MainActor in
            do {
                let harvest = try await task.transcribeOnly(clips: sounds, sourceLocaleID: sourceID)
                for sound in sounds { detected[sound.fingerprint] = harvest.locale.identifier }
                var detail: [String: JSONValue] = [
                    "language": .string(harvest.locale.identifier),
                    "next_step": "Call transcribe again with the same clips (or file) to read the transcript."
                ]
                let skipped = sounds.filter { harvest.skippedFingerprints.contains($0.fingerprint) }.map(\.name)
                if !skipped.isEmpty { detail["could_not_read"] = .array(skipped.map { .string($0) }) }
                AIJobs.shared.finish(job, .done, detail: .object(detail))
            } catch is CancellationError {
                AIJobs.shared.finish(job, .cancelled)
            } catch {
                AIJobs.shared.finish(job, .failed, message: AIHarvestFailure.message(
                    for: error, fallback: error.localizedDescription, retry: "transcribe"
                ))
            }
        }
        return .ok([
            "job_id": .string(job.id),
            "status": "running",
            "next_step": .string(
                "Transcribing on this Mac. Call get_job with this job_id and wait_seconds 30 until the status is done, "
                    + "then call transcribe again with the same arguments to read it."
            )
        ])
    }

    // MARK: 缓存

    /// 缓存覆盖了这几段要的区间：返回语言和每个素材的那条缓存；有一段没覆盖就是 nil（要起任务）。
    /// 几种语言都覆盖了（auto）时挑词的平均可信度最高的那份。
    static func cached(
        _ sounds: [SubtitleAudibleClips.SoundClip], language: String
    ) async -> (locale: String, entries: [String: TranscriptCacheEntry])? {
        var candidates: [String] = []
        if language.lowercased() == "auto" {
            candidates = Array(Set(sounds.compactMap { detected[$0.fingerprint] })).sorted()
            if candidates.isEmpty { candidates = await SpeechTranscriptionService.installedLocales().map(\.identifier).sorted() }
        } else if let matched = await SpeechTranscriptionService.matchedLocale(for: language) {
            candidates = [matched.identifier]
        }
        var best: (locale: String, entries: [String: TranscriptCacheEntry], confidence: Double)?
        for locale in candidates {
            guard let entries = covering(sounds, locale: locale) else { continue }
            let scores = entries.values.flatMap(\.words).compactMap(\.confidence)
            let confidence = scores.isEmpty ? 0 : scores.reduce(0, +) / Double(scores.count)
            if best == nil || confidence > best!.confidence { best = (locale, entries, confidence) }
        }
        return best.map { ($0.locale, $0.entries) }
    }

    private static func covering(
        _ sounds: [SubtitleAudibleClips.SoundClip], locale: String
    ) -> [String: TranscriptCacheEntry]? {
        var entries: [String: TranscriptCacheEntry] = [:]
        for sound in sounds {
            guard let entry = entries[sound.fingerprint] ?? TranscriptSidecarStore.load(
                fingerprint: sound.fingerprint, localeIdentifier: locale,
                transcriber: SpeechTranscriptionService.transcriberKind, configVersion: TranscriptSidecarStore.configVersion
            ) else { return nil }
            let wanted = SourceRange(start: sound.sourceStart, end: sound.sourceStart + sound.sourceDuration)
            guard TranscriptLedger.gaps(desired: [wanted], covered: entry.covered).isEmpty else { return nil }
            entries[sound.fingerprint] = entry
        }
        return entries
    }

    // MARK: 取哪几段

    /// clip_ids 给了就是它们；给了 file 就是那个文件（source_in / source_out 这一截）；都没给是视频轨上所有带声音的画面段
    /// （配乐、音效这类纯声音的段不转 —— 要转就点名）。
    static func targets(_ args: AIToolArguments, _ project: VideoEditProject) async throws -> [Target] {
        if let path = try args.string("file") {
            let url = AIWorkspace.shared.resolve(path)
            guard let media = await project.probeImports([url]).first, media.kind != .image else {
                throw AIToolError("\(url.lastPathComponent) has no sound SrtFlow can read.")
            }
            let from = max(0, try args.double("source_in") ?? 0)
            let to = min(media.duration, try args.double("source_out") ?? media.duration)
            guard to - from >= 0.5 else { throw AIToolError("source_in / source_out leave less than half a second of \(url.lastPathComponent).") }
            let sound = SubtitleAudibleClips.SoundClip(
                clipID: UUID(), name: url.deletingPathExtension().lastPathComponent, url: url,
                // 和时间线上同一个文件的片段同一个指纹（同一个算法、同样的探测信息），缓存才共用得上。
                fingerprint: TranscriptSidecarStore.fingerprint(
                    forFileAt: url, knownBytes: media.info?.fileBytes, knownDuration: media.info?.duration
                ),
                knownAssetDuration: media.info?.duration ?? media.duration,
                sourceStart: from, sourceDuration: to - from, timelineStart: from, speed: 1, laneRank: 0
            )
            return [Target(sound: sound, id: nil, track: nil)]
        }
        let state = project.state
        let ids = AIShortIDs(state: state)
        let requested: [UUID]
        if let list = try args.stringArray("clip_ids") {
            requested = try list.map { try ids.resolve($0) }
        } else {
            requested = (state.mainClips + state.overlayTracks.flatMap(\.clips)).filter { !$0.isAudioOnly }.map(\.id)
        }
        let sounds = SubtitleAudibleClips.soundClips(in: state, only: Set(requested))
        let heard = Set(sounds.map(\.clipID))
        let silent = requested.filter { !heard.contains($0) }
        if try args.stringArray("clip_ids") != nil, !silent.isEmpty {
            throw AIToolError(
                "No sound to transcribe in \(silent.map(ids.short).joined(separator: ", ")) (muted, hidden, silent or an image)."
            )
        }
        guard !sounds.isEmpty else {
            throw AIToolError("No clip with sound on the video tracks. Pass clip_ids (for example a voice-over on A1) or file.")
        }
        return sounds.map { sound in
            Target(
                sound: sound, id: ids.short(sound.clipID),
                track: state.location(of: sound.clipID).map { AITrackName.name(of: $0.track) }
            )
        }
    }
}
