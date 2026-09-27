import AppKit
import AVFoundation
import Foundation
import SrtFlowCore

// 语音生成字幕的任务状态机（docs/plans/…… 第 10 节）。
//
// 对齐 EncodeQueue 的纪律：@MainActor、刻意串行、全局单例防视图销毁中断。
// 阶段交界必查取消令牌（export-prerender 教训）；任务绑 documentGeneration，
// 切工程即作废；已 finalize 的词流随每个缺口落 sidecar，断点续跑只补缺口。

@available(macOS 26.0, *)
@MainActor
final class TranscriptionTask: ObservableObject {
    static let shared = TranscriptionTask()

    enum Stage: Equatable {
        case idle
        case detectingLanguage
        case preparingModels
        case readingAudio(String)
        case transcribing(String)
        case segmenting
        case translating
        case done(cueCount: Int)
        case failed(String)
        case cancelled
    }

    /// 源语言 Picker 里「自动检测」的哨兵值。
    static let autoDetectLocaleID = "auto"

    @Published private(set) var stage: Stage = .idle
    /// 总进度 0–1，单调不倒退（计划 10.2）。
    @Published private(set) var progress: Double = 0
    /// 转写中的灰字预览（volatile，只进 UI，不落任何持久层）。
    @Published private(set) var volatileText: String?
    /// 读不了的素材：跳过并明示，不中断整个任务（全失效才 failed）。
    @Published private(set) var skippedAssets: [String] = []
    /// 「生成后顺便翻译」被如实跳过的原因（例如字幕已是目标语言）。
    /// 不算失败，但也绝不伪装成翻译发生过 —— 单独一条通知展示。
    @Published private(set) var translationSkipNote: String?

    var isRunning: Bool {
        switch stage {
        case .idle, .done, .failed, .cancelled: return false
        default: return true
        }
    }

    private let service = SpeechTranscriptionService()
    private var token: ExportCancellationToken?
    private var runner: Task<Void, Never>?
    /// 首次模型下载的进度观察：折进总进度 0.02–0.1 段（评审 P2）。
    private var modelObservation: NSKeyValueObservation?
    /// 正在进行的模型下载：取消要能穿透它（Progress.cancel() 是 Apple
    /// 对下载类 Progress 的标准取消通道），否则切工程后旧任务会占着
    /// 串行槽等下载结束。
    private var installProgress: Progress?

    private init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { TranscriptionTask.shared.cancel() }
        }
    }

    // MARK: 入口

    /// 面板确认过替换后调用。串行：在跑就忽略。
    /// - Parameter lineFitEms: 一行在画面上放得下几个字号宽（`SubtitleLineFit`），生成时按它封顶。
    /// - Parameter onlyClipIDs: 「只用选中的片段」那几段（`SubtitleAudibleClips.selectedSoundClipIDs`）；nil = 全部。
    func start(
        project: VideoEditProject,
        sourceLocaleID: String,
        targetLanguageID: String?,
        lineFitEms: Double = .infinity,
        onlyClipIDs: Set<UUID>? = nil
    ) {
        guard !isRunning else { return }
        let token = ExportCancellationToken()
        self.token = token
        progress = 0
        volatileText = nil
        skippedAssets = []
        translationSkipNote = nil
        let generation = project.documentGeneration
        let state = project.state

        runner = Task { [weak self] in
            guard let self else { return }
            defer {
                self.volatileText = nil
                self.token = nil
                self.modelObservation = nil
                self.installProgress = nil
            }
            do {
                let harvest = try await self.transcribe(
                    state: state, onlyClipIDs: onlyClipIDs, sourceLocaleID: sourceLocaleID, token: token
                )
                guard project.isCurrentGeneration(generation) else {
                    self.stage = .cancelled
                    return
                }
                // 时间线可能在转写期间被改（裁切/移动/变速不改 generation）。
                // 一律以**当前** state 重取音源映射做分段；当前需要的区间若
                // 超出账本覆盖（新裁进了没转写过的段落），如实报「时间线已变」
                // 让用户重跑 —— 账本保证重跑只补新缺口，秒级。（评审 P1）
                self.stage = .segmenting
                self.setProgress(0.85)
                // 分段与合成永远基于**当前**时间线（SubtitleGenerationAssembly）；按转写实际用的语言
                // 选每行字数和阅读速度，两条之间的空按工程帧率（docs/architecture/subtitle-generation-style.md）。
                let result = try SubtitleGenerationAssembly.build(
                    state: project.state,
                    entries: harvest.entries,
                    skippedFingerprints: harvest.skippedFingerprints,
                    onlyClipIDs: onlyClipIDs,
                    localeIdentifier: harvest.locale.identifier,
                    config: .generation(
                        languageCode: harvest.locale.language.languageCode?.identifier,
                        frameDuration: project.state.frameRate.secondsPerFrame,
                        maxLineEms: lineFitEms
                    )
                )
                guard project.isCurrentGeneration(generation) else {
                    self.stage = .cancelled
                    return
                }
                self.setProgress(0.9)
                // 源语言一律取转写实际用的 locale（自动检测时 sourceLocaleID
                // 只是 "auto" 哨兵，真语言在 harvest 里）。
                let resolvedSource = harvest.locale.language.minimalIdentifier
                // 异步落账不是用户事件：自己成一步，不然 App 在后台时之后的改动全并进来（AIUndoGrouping 文件头）。
                AIUndoGrouping.step(project.effectiveUndoManager) {
                    project.replaceSubtitleForGeneration(
                        result.document,
                        sourceLanguage: resolvedSource,
                        generation: GenerationSnapshot(
                            module: SpeechTranscriptionService.transcriberKind,
                            segmentationConfigVersion: SubtitleSegmentationConfig.version,
                            generatedAt: Date()
                        ),
                        cueMeta: result.meta
                    )
                }

                if let targetLanguageID, #available(macOS 15.0, *),
                   TranslationPreflight.isSameTranslationLanguage(
                       harvest.locale.language,
                       Locale.Language(identifier: targetLanguageID)
                   ) {
                    // 字幕已经是目标语言（2026-08-09 案例的核心场景）：如实
                    // 跳过并说明，不算失败，也不把 en→en 交给系统去爆
                    // 「Unable to Translate」。
                    self.translationSkipNote = String(
                        format: L10n("Subtitles are already in %@ — translation skipped."),
                        TranslationPreflight.displayName(of: harvest.locale.language)
                    )
                } else if let targetLanguageID, #available(macOS 15.0, *) {
                    self.stage = .translating
                    let outcome = await SubtitleTranslationService.shared.translateCurrentSubtitle(
                        project: project,
                        scope: .all,
                        sourceLanguage: resolvedSource,
                        targetLanguage: targetLanguageID
                    )
                    // 翻译没成不许伪装成功：字幕已生成并保留，但结局要如实报。
                    switch outcome {
                    case .failed(let message):
                        self.setProgress(1)
                        self.stage = .failed(String(
                            format: L10n("Subtitles were generated, but translation failed: %@"),
                            message
                        ))
                        return
                    case .cancelled, .discarded:
                        self.setProgress(1)
                        self.stage = .cancelled
                        return
                    case .translated, .nothingToDo:
                        break
                    }
                }
                self.setProgress(1)
                self.stage = .done(cueCount: result.document.cues.count)
            } catch is CancellationError {
                self.stage = .cancelled
            } catch {
                self.stage = .failed(error.localizedDescription)
            }
        }
    }

    /// AI 的 transcribe：只把这几段转成词流进缓存（调用方从缓存读），不生成字幕、不碰工程。
    /// 和生成字幕共用这一个串行槽：在跑就报忙 —— 两边同时跑会互相删临时目录（`sweepTempResidue`）、抢同一份缓存。
    /// 跑的时候面板上照样看得见阶段和进度；结束（成、败、取消）阶段都回 idle，面板上不会冒出「生成了 0 句」。
    func transcribeOnly(
        clips: [SubtitleAudibleClips.SoundClip], sourceLocaleID: String
    ) async throws -> TranscriptHarvester.Harvest {
        guard !isRunning else {
            throw TaskError(message: "SrtFlow is already transcribing (generating subtitles or another transcript).")
        }
        guard SpeechTranscriptionService.isAvailable else {
            throw TaskError(message: L10n("Speech transcription isn't available on this Mac."))
        }
        let token = ExportCancellationToken()
        self.token = token
        // 第一个 await 之前就占住槽（isRunning 看的是阶段）。
        stage = .preparingModels
        progress = 0
        volatileText = nil
        skippedAssets = []
        translationSkipNote = nil
        defer {
            volatileText = nil
            modelObservation = nil
            installProgress = nil
            if self.token === token { self.token = nil }
            stage = .idle
            progress = 0
        }
        return try await harvester(token: token).harvest(clips: clips, sourceLocaleID: sourceLocaleID)
    }

    func cancel() {
        token?.cancel()
        // 各阶段各有取消通道：模型下载靠 Progress.cancel + 任务取消传播，
        // 转写靠 analyzer.cancelAndFinishNow，翻译靠 coordinator。
        runner?.cancel()
        installProgress?.cancel()
        if #available(macOS 15.0, *) { TranslationJobCoordinator.shared.cancel() }
        service.cancelCurrent()
    }

    // MARK: 主流程

    private struct TaskError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// 转写阶段交给 `TranscriptHarvester`（生成字幕和 AI 的 transcribe 共用）；这里只管有没有能转写的，
    /// 以及把阶段、进度、灰字、跳过名单、模型下载接回面板。
    private func transcribe(
        state: TimelineState,
        onlyClipIDs: Set<UUID>?,
        sourceLocaleID: String,
        token: ExportCancellationToken
    ) async throws -> TranscriptHarvester.Harvest {
        guard SpeechTranscriptionService.isAvailable else {
            throw TaskError(message: L10n(
                "Speech transcription isn't available on this Mac."
            ))
        }
        let clips = SubtitleAudibleClips.soundClips(in: state, only: onlyClipIDs)
        guard !clips.isEmpty else {
            throw TaskError(message: L10n("No audible clips to transcribe."))
        }
        return try await harvester(token: token).harvest(clips: clips, sourceLocaleID: sourceLocaleID)
    }

    /// 模型下载那两样按 token 验明正身之后才动：回调是异步 hop 过来的，可能在旧任务取消、新任务启动之后才到 ——
    /// 旧 Progress / KVO 不许复活到新任务头上（评审 P2）。
    private func harvester(token: ExportCancellationToken) -> TranscriptHarvester {
        TranscriptHarvester(service: service, token: token, hooks: .init(
            stage: { [weak self] in self?.stage = $0 },
            progress: { [weak self] in self?.setProgress($0) },
            volatileText: { [weak self] in self?.volatileText = $0 },
            skipped: { [weak self] in self?.skippedAssets = $0 },
            installing: { [weak self, token] progress in
                guard let self, self.token === token else { return }
                guard let progress else {
                    self.modelObservation = nil
                    self.installProgress = nil
                    return
                }
                self.installProgress = progress
                self.modelObservation = progress.observe(\.fractionCompleted, options: [.initial]) { progress, _ in
                    Task { @MainActor [weak self] in
                        guard let self, self.token === token else { return }
                        self.setProgress(0.02 + 0.08 * progress.fractionCompleted)
                    }
                }
            }
        ))
    }

    // MARK: 工具

    private func setProgress(_ value: Double) {
        progress = max(progress, min(value, 1))
    }
}
