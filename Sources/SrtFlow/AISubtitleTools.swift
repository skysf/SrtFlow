import Combine
import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - 工具：生成、翻译、读、改字幕
//
// 管什么：四个字幕工具在 App 里怎么做。生成和翻译走面板上那同一个任务（`TranscriptionTask`、
// `SubtitleTranslationService`），不另写一套；它们要跑好一阵，起了就回任务号（AIJobs）。
// 改字幕走 `SubtitleTrackEditing` 那份两轨合同，整批一次 perform = 一步撤销。
// 不管什么：说明文字（SrtFlowMCPKit/MCPSubtitleExportTools.swift）。

@MainActor
enum AISubtitleTools {
    /// 生成任务的完成回调挂在任务的 `stage` 上；任务号 → 订阅，结束就放掉。
    private static var subscriptions: [String: AnyCancellable] = [:]

    // MARK: generate_subtitles

    static func generate(_ args: AIToolArguments, _ project: VideoEditProject) async throws -> AIToolResult {
        guard #available(macOS 26.0, *) else {
            throw AIToolError("Generating subtitles from speech needs macOS 26 or later on this Mac.")
        }
        guard SpeechTranscriptionService.isAvailable else {
            throw AIToolError("Speech transcription is not available on this Mac.")
        }
        let task = TranscriptionTask.shared
        guard !task.isRunning else { throw AIToolError("Subtitles are already being generated. Wait for that job first.") }
        let language = try args.string("language") ?? "auto"
        let sourceID = language.lowercased() == "auto" ? TranscriptionTask.autoDetectLocaleID : language
        let targetID = try await (try args.string("translate_to")).asyncMap { try await translationTarget($0, source: nil) }
        let ids = AIShortIDs(state: project.state)
        let only = try args.stringArray("clip_ids").map { list in Set(try list.map { try ids.resolve($0) }) }
        guard !SubtitleAudibleClips.soundClips(in: project.state, only: only).isEmpty else {
            throw AIToolError("There is no audible clip to transcribe (hidden and muted clips are skipped).")
        }
        task.start(
            project: project,
            sourceLocaleID: sourceID,
            targetLanguageID: targetID,
            // 和面板同一个算法：按当前字幕样式和画面宽度算一行放得下多少（竖屏更短）。
            lineFitEms: SubtitleLineFit.ems(
                for: project.state, appWide: EncodeQueue.burnIn.burnInStyle, renderSize: project.renderSize
            ),
            onlyClipIDs: only
        )
        let waiting = WaitingNote()
        let job = AIJobs.shared.start(.subtitles, progress: { task.progress }, waitingForUser: {
            task.stage == .translating && !AITranslationReadiness.isProducingTranslations ? waiting.watch?.note : nil
        }, cancel: { task.cancel() })
        // `stage` 只在主线程上写（TranscriptionTask 是 @MainActor），回调就在主线程上。
        // dropFirst：订阅那一刻发的是**上一次**任务留下的结局（比如上次的 done），不是这一次的。
        subscriptions[job.id] = task.$stage.dropFirst().sink { stage in
            MainActor.assumeIsolated {
                if stage == .translating, let targetID {
                    // 生成完接着翻：到这一步才知道原文是什么语言，这时再查要不要下载（同 translate 那一路）。
                    Task { @MainActor in await guideDownloadIfNeeded(project, target: targetID, into: waiting) }
                    return
                }
                switch stage {
                case .done(let count):
                    waiting.watch?.stop()
                    AIJobs.shared.finish(job, .done, detail: ["lines": .number(Double(count))])
                case .failed(let message):
                    waiting.watch?.stop()
                    AIJobs.shared.finish(job, .failed, message: AIHarvestFailure.message(
                        for: task.failure, fallback: message, retry: "generate_subtitles"
                    ))
                case .cancelled:
                    waiting.watch?.stop()
                    AIJobs.shared.finish(job, .cancelled)
                default:
                    return
                }
                subscriptions[job.id] = nil
            }
        }
        return .ok(started(job), changed: true)
    }

    /// 生成之后接着翻的那一步：这一对语言没装就把 SrtFlow 摆到前面、提示条和任务进度里都说清楚。
    /// 这里**可以先信工程里记的语言**，和 translate 那一路相反：切到 translating 之前，
    /// `replaceSubtitleForGeneration` 刚把转写实际用的语言写进去，翻译用的也正是它。
    @available(macOS 26.0, *)
    private static func guideDownloadIfNeeded(_ project: VideoEditProject, target: String, into waiting: WaitingNote) async {
        let texts = project.state.subtitleCues(of: .original).map(\.text)
        guard let source = project.state.subtitleCompanion?.sourceLanguage ?? AITextLanguage.dominant(in: texts),
              await AITranslationReadiness.needsDownload(from: source, to: target) else { return }
        let watch = AIDownloadWatch(source: source, target: target)
        waiting.watch = watch
        let task = TranscriptionTask.shared
        watch.start(isOver: { task.stage != .translating || AITranslationReadiness.isProducingTranslations })
    }

    // MARK: translate_subtitles

    static func translate(_ args: AIToolArguments, _ project: VideoEditProject) async throws -> AIToolResult {
        guard #available(macOS 15.0, *) else { throw AIToolError("Translating subtitles needs macOS 15 or later.") }
        guard project.state.subtitle != nil else {
            throw AIToolError("The project has no subtitles yet. Generate them (generate_subtitles) or add lines first.")
        }
        let coordinator = TranslationJobCoordinator.shared
        if case .running = coordinator.phase { throw AIToolError("A translation is already running. Wait for that job first.") }
        let source = try translationSource(args, project)
        let targetID = try await translationTarget(try args.requiredString("target_language"), source: source)
        if TranslationPreflight.isSameTranslationLanguage(
            Locale.Language(identifier: source), Locale.Language(identifier: targetID)
        ) {
            throw AIToolError("The subtitles are already in that language (\(source)).")
        }
        let scope: SubtitleRetranslation.Scope = try args.choice("scope", from: ["all", "missing"]) == "missing"
            ? .missingAndStale : .all
        // 这一对语言没装：macOS 会弹下载框，而且只能由用户点。摆到前面、提示条和进度里都说清楚（AIDownloadWatch）。
        let watch = await AITranslationReadiness.needsDownload(from: source, to: targetID)
            ? AIDownloadWatch(source: source, target: targetID) : nil
        let translating = { AITranslationReadiness.isProducingTranslations }
        let job = AIJobs.shared.start(.translation, progress: {
            if case .running(let completed, let total) = coordinator.phase { return Double(completed) / Double(max(total, 1)) }
            return nil
        }, waitingForUser: { translating() ? nil : watch?.note }, cancel: { coordinator.cancel() })
        watch?.start(isOver: { translating() || job.status != .running })
        Task { @MainActor in
            let outcome = await SubtitleTranslationService.shared.translateCurrentSubtitle(
                project: project, scope: scope, sourceLanguage: source, targetLanguage: targetID
            )
            watch?.stop()
            switch outcome {
            case .translated(let count): AIJobs.shared.finish(job, .done, detail: ["lines": .number(Double(count))])
            case .nothingToDo: AIJobs.shared.finish(job, .done, message: "Every line already had an up-to-date translation.")
            case .cancelled, .discarded: AIJobs.shared.finish(job, .cancelled)
            case .failed(let message): AIJobs.shared.finish(job, .failed, message: message)
            }
        }
        var result = started(job).objectValue ?? [:]
        if let watch { result["waiting_for_user"] = .string(watch.note) }
        return .ok(.object(result), changed: true)
    }

    /// 原文是什么语言：AI 说了就用它；否则**按字判断**（AI 可能刚把原文整轨改写成别的语言，工程里记的
    /// 还是旧的，docs/bugfixes/2026-09-27-ai-translation-stale-source-language.md）；判不出来才用记的。
    private static func translationSource(_ args: AIToolArguments, _ project: VideoEditProject) throws -> String {
        if let stated = try args.string("source_language") { return stated }
        let texts = project.state.subtitleCues(of: .original).map(\.text)
        if let detected = AITextLanguage.dominant(in: texts) { return detected }
        if let stored = project.state.subtitleCompanion?.sourceLanguage { return stored }
        throw AIToolError("SrtFlow cannot tell which language the subtitles are in. Pass source_language.")
    }

    /// AI 写的语言（zh-Hans、en、ja…）→ 系统翻译认的那一项。先认全名，再按语言 + 文字对。
    @available(macOS 15.0, *)
    private static func translationTarget(_ tag: String, source: String?) async throws -> String {
        let options = await SubtitleTranslationService.shared.targetLanguages(from: source)
        let wanted = Locale.Language(identifier: tag)
        if let exact = options.first(where: {
            $0.id.caseInsensitiveCompare(tag) == .orderedSame || $0.language.minimalIdentifier == wanted.minimalIdentifier
        }) {
            return exact.id
        }
        if let close = options.first(where: {
            $0.language.languageCode == wanted.languageCode && (wanted.script == nil || $0.language.script == wanted.script)
        }) {
            return close.id
        }
        let known = options.prefix(40).map(\.language.minimalIdentifier).joined(separator: ", ")
        throw AIToolError("This Mac cannot translate into \(tag). Languages it can use: \(known).")
    }

    private static func started(_ job: AIJobs.Job) -> JSONValue {
        [
            "job_id": .string(job.id),
            "status": "running",
            "next_step": "Call get_job with this job_id and wait_seconds 30 until the status is done."
        ]
    }

    // MARK: get_subtitles

    static func read(_ args: AIToolArguments, _ project: VideoEditProject) throws -> AIToolResult {
        let which = try args.choice("track", from: ["original", "translation", "both"]) ?? "both"
        let from = try args.double("start") ?? 0
        let to = try args.double("end") ?? .infinity
        let limit = min(max(try args.int("limit") ?? 300, 1), 2000)
        let state = project.state
        let ids = AIShortIDs(state: state)
        func lines(_ track: SubtitleTrack) -> JSONValue {
            let cues = state.subtitleCues(of: track).filter { $0.end > from && $0.start < to }
            var object: [String: JSONValue] = [
                "lines": .array(cues.prefix(limit).map { cue in
                    var line: [String: JSONValue] = [
                        "id": .string(ids.short(cue.id)),
                        "start": AIFormat.seconds(cue.start),
                        "end": AIFormat.seconds(cue.end),
                        "text": .string(cue.text)
                    ]
                    if state.isSubtitleCueHidden(cue.id) { line["hidden"] = true }
                    return .object(line)
                }),
                "total": .number(Double(cues.count))
            ]
            if cues.count > limit { object["truncated"] = true }
            return .object(object)
        }
        var result: [String: JSONValue] = [:]
        if which != "translation" { result["original"] = lines(.original) }
        if which != "original" { result["translation"] = lines(.translation) }
        result["style"] = AISubtitleStyleChange.describe(state, appWide: EncodeQueue.burnIn.burnInStyle)
        // 逐词高亮只亮知道词时间的句子（SrtFlow 自己从语音、配音做的）。
        result["lines_with_word_times"] = .number(Double(state.allSubtitleCues.filter { $0.words != nil }.count))
        return .ok(.object(result))
    }

    // MARK: edit_subtitles

    /// edit_subtitles 的 style 先读好：给了字体要等字体表（await），所以在提交之前单独做（同 edit_clip 先看画面）。
    static func style(_ args: AIToolArguments) async throws -> AISubtitleStyleChange? {
        guard let change = try AISubtitleStyleChange(args) else { return nil }
        guard change.font != nil else { return change }
        return try change.resolvingFont(in: await FontCatalogStore.shared.loadedFonts().map(\.familyName))
    }

    static func edit(_ args: AIToolArguments, style: AISubtitleStyleChange?, _ project: VideoEditProject) throws -> AIToolResult {
        let state = project.state
        let ids = AIShortIDs(state: state)
        let edits = try AISubtitleEdits.parse(args, ids: ids, in: state)
        guard !edits.isEmpty || style != nil else { throw AIToolError("Pass changes, add, delete or style.") }
        var next = state
        let created = edits.apply(to: &next)
        // 只改这个工程自己的样式（方案第 54 条），烧录页记住的那套不动。
        style?.apply(to: &next, appWide: EncodeQueue.burnIn.burnInStyle)
        project.perform(rebuildsPreview: false) { $0 = next }
        let fresh = AIShortIDs(state: project.state)
        let firstTime = (edits.changes.compactMap { project.state.subtitleCue($0.id)?.start }
            + created.compactMap { project.state.subtitleCue($0)?.start }).min()
        AIEditorPresenter.reveal(.init(cues: Set(created + edits.changes.map(\.id)), time: firstTime), project: project)
        var result: [String: JSONValue] = [
            "changed": .number(Double(edits.changes.count)),
            "added": .array(created.map { .string(fresh.short($0)) }),
            "deleted": .number(Double(edits.deletions.count))
        ]
        if style != nil { result["style"] = AISubtitleStyleChange.describe(project.state, appWide: EncodeQueue.burnIn.burnInStyle) }
        return .ok(.object(result), changed: true)
    }
}

/// 生成任务「在等用户下载翻译语言」的那一份：到翻译那一步才知道要不要。
@MainActor
private final class WaitingNote {
    var watch: AIDownloadWatch?
}

private extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
        guard let value = self else { return nil }
        return try await transform(value)
    }
}
