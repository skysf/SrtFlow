import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - 工具：配旁白（add_voiceover，方案第 42、43 条）
//
// 管什么：AI 写好的几句旁白，用这台 Mac 的声音一句一个文件读出来（`<起点>/SrtFlow/配音`，撞名加编号），放上音频轨；
// 要字幕的话按词的时间切成字幕加进原文轨（AIVoiceoverSubtitles）。
// 分两步（同 edit_clip）：`plan` 可以 await（合成、读文件），`apply` 同步提交、路由包在 `AIUndoGrouping.step` 里 ——
// 放素材和加字幕在同一次 perform 里，一个工具 = 一步撤销。
// 放上时间线走 add_clips 那一套（`AITimelineEdits.place`：撞上往上抬一轨；这一批都放进第一句新开的那条轨）。
// 声音分三档（第 42、48 条）：用户接了 fal 就用 fal 的声音（`AIFalVoice`：有 Key、没超每日上限、Key 读得出来；不行就退到下一档并在结果里说为什么），
// 其次下载了 SrtFlow 自己的声音（本机的 Kokoro），没下载 / 它读不了的语言用这台 Mac 的；
// `download_voices=true` 开始下载、回任务号（第 50 条：AI 也能直接下，下的时候告诉用户）。
// `clone_from`（第 52 条）：用一段素材里的声音当参考、让 fal 的克隆模型读 —— 只有 fal 能克隆，用不了就报错、不退档。
// 不管什么：挑声音（AIVoiceChoice）、怎么合成（AIFalVoice / KokoroVoiceSpeech / AISpeechSynthesis）、下载（KokoroVoicePack）。

@MainActor
enum AIVoiceoverTool {
    struct Line {
        var text: String
        var start: Double?
    }

    struct Spoken {
        var line: Line
        var output: AISpeechSynthesis.Output
        var clip: EditClip
    }

    struct Plan {
        var spoken: [Spoken]
        var starts: [Double]
        var target: TrackDropTarget
        var choice: AIVoiceChoice
        var language: String
        var subtitles: Bool
        var generation: Int
    }

    /// `download_voices=true`：开始下载 SrtFlow 自己的声音（已经装好就直接说），回任务号；这一次不配音、不改工程。
    static func startDownloadIfAsked(_ args: AIToolArguments) async throws -> AIToolResult? {
        guard try args.bool("download_voices") == true else { return nil }
        let pack = KokoroVoicePack.shared
        if pack.isInstalled {
            return .ok(["status": "installed", "next_step": "SrtFlow's voices are ready: call add_voiceover with your lines."])
        }
        let job = AIJobs.shared.start(.voices, progress: { pack.fraction }, cancel: { pack.cancel() })
        Task { @MainActor in
            do {
                try await pack.install()
                AIJobs.shared.finish(job, .done, message: "SrtFlow's voices are downloaded. Call add_voiceover with your lines.")
            } catch {
                let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
                AIJobs.shared.finish(job, cancelled ? .cancelled : .failed,
                                     message: cancelled ? "The download was stopped." : error.localizedDescription)
            }
        }
        return .ok([
            "status": "downloading", "job_id": .string(job.id), "size": .string(KokoroVoicePack.approximateSize),
            "next_step": .string("Tell the user SrtFlow is downloading its own voices (about \(KokoroVoicePack.approximateSize); "
                + "progress also shows in Settings → AI). Wait with get_job, then call add_voiceover again without download_voices.")
        ])
    }

    /// 克隆用的素材在点名的文件夹以外：要发给 fal.ai，先问用户一次（同读别处的文件）。要问就回 needs_confirmation。
    static func confirmations(_ args: AIToolArguments, _ project: VideoEditProject) throws -> AIToolResult? {
        guard let clone = try cloneSource(args) else { return nil }
        return try AIWorkspace.shared.confirmReading([clone.url], verb: "send to fal.ai", args: args, project: project)
    }

    private static func cloneSource(_ args: AIToolArguments) throws -> (url: URL, start: Double, seconds: Double)? {
        guard let path = try args.string("clone_from"), !path.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let url = AIWorkspace.shared.resolve(path)
        guard FileManager.default.fileExists(atPath: url.path) else { throw AIToolError("There is no file at \(path).") }
        return (url, max(0, try args.double("clone_start") ?? 0), min(max(try args.double("clone_seconds") ?? 10, 5), 30))
    }

    static func plan(_ args: AIToolArguments, _ project: VideoEditProject) async throws -> Plan {
        let lines = try parseLines(args)
        let speed = min(max(try args.double("speed") ?? 1, 0.5), 2)
        let language = AITextLanguage.dominant(in: lines.map(\.text)).map(AIVoiceChoice.baseLanguage) ?? "en"
        let kokoroVoices = KokoroVoicePack.shared.isInstalled ? KokoroVoiceSpeech.voiceNames(in: KokoroVoicePack.directory) : nil
        let characters = lines.reduce(0) { $0 + $1.text.count }
        // fal 那一档：克隆只有 fal 能做（用不了就报错）；普通配音用不了就退到下一档，原因写进 voice.note。
        var offer: AIFalVoice.Offer?
        var reference: String?
        var falNote: String?
        var choice: AIVoiceChoice
        if let clone = try cloneSource(args) {
            let result = await AIFalVoice.offer(kind: .voiceClone, characters: characters)
            guard let made = result.offer else {
                throw AIToolError(result.note ?? "Cloning a voice needs a fal.ai key: ask the user to add one in SrtFlow → Settings → AI.")
            }
            offer = made
            reference = try await AIFalVoice.referenceSample(from: clone.url, start: clone.start, seconds: clone.seconds)
            choice = AIVoiceChoice(engine: .fal(voice: "cloned voice"), note: "The voice is cloned from \(clone.url.lastPathComponent).")
        } else {
            let result = await AIFalVoice.offer(kind: .voice, characters: characters)
            offer = result.offer
            falNote = result.note
            choice = try AIVoiceChoice.choose(try args.string("voice"), textLanguage: language, kokoroVoices: kokoroVoices,
                                              installed: AISpeechSynthesis.installedVoices(), falAvailable: offer != nil)
        }
        if case .fal = choice.engine, args.has("speed"), speed != 1 {
            falNote = [falNote, "The fal.ai voice speaks at its own pace; speed was ignored (SrtFlow's or a Mac voice can change it)."]
                .compactMap { $0 }.joined(separator: " ")
        }
        if let falNote { choice.note = [choice.note, falNote].compactMap { $0 }.joined(separator: " ") }
        let target = try args.string("track").map { try AITrackName.target($0, in: project.state) } ?? .newAudioBottom
        switch target {
        case .audio, .newAudioBottom: break
        default: throw AIToolError("A voiceover goes on an audio track (A1, A2… or new_audio).")
        }
        let generation = project.documentGeneration
        let folder = AIWorkspace.shared.outputFolder(.voiceovers, project: project)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var spoken: [Spoken] = []
        for (index, line) in lines.enumerated() {
            let stem = ExportFileName.stem(from: AIVoiceoverPlacement.fileStem(line.text), droppingExtension: "m4a", fallback: "Voiceover")
            let url = ExportFileName.unoccupied(in: folder, stem: stem, pathExtension: "m4a") {
                FileManager.default.fileExists(atPath: $0.path)
            }
            let output: AISpeechSynthesis.Output
            switch choice.engine {
            case .fal(let voice):
                guard let offer else { throw AIToolError("The fal.ai voice is not available.") }
                output = try await AIFalVoice.speak(
                    line.text, voice: voice, language: language, wantsWords: try args.bool("subtitles") ?? false,
                    reference: reference, offer: offer, to: url
                )
            case .kokoro(let voice, let voiceLanguage):
                output = try await KokoroVoiceSpeech.shared.speak(line.text, language: voiceLanguage, voice: voice, speed: speed, to: url)
            case .system:
                output = try await AISpeechSynthesis.speak(line.text, choice: choice, speed: speed, to: url)
            }
            guard let media = await project.probeImports([url]).first else {
                throw AIToolError("lines[\(index)]: SrtFlow could not read back the voiceover file \(url.lastPathComponent).")
            }
            spoken.append(Spoken(line: line, output: output, clip: project.clip(for: media)))
        }
        guard project.isCurrentGeneration(generation) else {
            throw AIToolError("The project changed while the voiceover was being made. Try again.")
        }
        return Plan(spoken: spoken, starts: starts(for: spoken, playhead: project.clock.time), target: target, choice: choice,
                    language: language, subtitles: try args.bool("subtitles") ?? false, generation: generation)
    }

    static func apply(_ plan: Plan, _ project: VideoEditProject) throws -> AIToolResult {
        guard project.isCurrentGeneration(plan.generation) else {
            throw AIToolError("The project changed while the voiceover was being made. Try again.")
        }
        let placed = zip(plan.spoken, plan.starts).map { spoken, start in
            AITimelineEdits.PlannedClip(clip: spoken.clip, isAudio: true, target: plan.target, start: start)
        }
        let config = SubtitleSegmentationConfig.generation(
            languageCode: plan.language, frameDuration: project.state.frameRate.secondsPerFrame,
            maxLineEms: SubtitleLineFit.ems(for: project.state, appWide: EncodeQueue.burnIn.burnInStyle,
                                            renderSize: project.renderSize)
        )
        var subtitles = AIVoiceoverSubtitles.Outcome()
        let linkage = project.linkageEnabled
        project.perform { state in
            AITimelineEdits.place(placed, insert: false, linkage: linkage, in: &state)
            guard plan.subtitles else { return }
            let pieces = plan.spoken.compactMap { spoken -> AIVoiceoverSubtitles.Piece? in
                guard let clip = state.clip(with: spoken.clip.id), let location = state.location(of: clip.id) else { return nil }
                let rank: Int
                if case .audio(let index) = location.track { rank = 1 + index } else { rank = 1 }
                return .init(clipID: clip.id, timelineStart: clip.timelineStart, duration: spoken.output.duration,
                             laneRank: rank, words: spoken.output.words)
            }
            subtitles = AIVoiceoverSubtitles.add(pieces, language: plan.language, config: config, to: &state)
        }
        return result(plan, subtitles: subtitles, project: project)
    }

    // MARK: 参数与结果

    private static func parseLines(_ args: AIToolArguments) throws -> [Line] {
        guard let items = try args.array("lines"), !items.isEmpty else { throw AIToolError("lines is required.") }
        guard items.count <= 50 else { throw AIToolError("Give at most 50 lines per call.") }
        return try items.enumerated().map { index, item in
            let entry = AIToolArguments(item)
            let text = try entry.requiredString("text").trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count <= 1_000 else { throw AIToolError("lines[\(index)]: keep one line under 1000 characters.") }
            return Line(text: text, start: try entry.double("start").map { max(0, $0) })
        }
    }

    static func starts(for spoken: [Spoken], playhead: Double) -> [Double] {
        AIVoiceoverPlacement.starts(given: spoken.map(\.line.start), durations: spoken.map(\.clip.timelineDuration),
                                    playhead: playhead)
    }

    private static func result(_ plan: Plan, subtitles: AIVoiceoverSubtitles.Outcome, project: VideoEditProject) -> AIToolResult {
        let state = project.state
        let ids = AIShortIDs(state: state)
        let added: [JSONValue] = plan.spoken.compactMap { spoken in
            guard let clip = state.clip(with: spoken.clip.id), let location = state.location(of: clip.id) else { return nil }
            return [
                "id": .string(ids.short(clip.id)),
                "track": .string(AITrackName.name(of: location.track)),
                "start": AIFormat.seconds(clip.timelineStart),
                "end": AIFormat.seconds(clip.timelineEnd),
                "file": .string(AIWorkspace.shared.display(spoken.output.url)),
                "text": .string(spoken.line.text)
            ]
        }
        var voice: [String: JSONValue] = [
            "name": .string(plan.choice.name), "quality": .string(plan.choice.qualityName)
        ]
        if let note = plan.choice.note { voice["note"] = .string(note) }
        var result: [String: JSONValue] = ["added": .array(added), "voice": .object(voice),
                                           "timeline_duration": AIFormat.seconds(state.duration)]
        if plan.subtitles {
            var summary: [String: JSONValue] = ["added": .number(Double(subtitles.added.count))]
            if subtitles.skipped > 0 {
                summary["skipped"] = .string("\(subtitles.skipped) lines overlap subtitles that were already there and were not added.")
            }
            if let refusal = subtitles.refusal { summary["note"] = .string(refusal) }
            // fal 没报词时间（或报的读不出来）：那几句就没有字幕，别让 AI 以为加上了。
            if case .fal = plan.choice.engine, plan.spoken.contains(where: { $0.output.words.isEmpty }) {
                let note = "fal.ai did not say when each word is spoken for some lines, so those lines have no subtitles. "
                    + "Run generate_subtitles on the voiceover clips, or use SrtFlow's own voice."
                summary["note"] = .string([summary["note"]?.stringValue, note].compactMap { $0 }.joined(separator: " "))
            }
            result["subtitles"] = .object(summary)
        }
        let first = plan.spoken.compactMap { state.clip(with: $0.clip.id)?.timelineStart }.min()
        AIEditorPresenter.reveal(.init(clips: Set(plan.spoken.map(\.clip.id)), time: first), project: project)
        return .ok(.object(result), changed: true)
    }
}
