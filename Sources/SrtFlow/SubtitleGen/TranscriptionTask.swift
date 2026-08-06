import AppKit
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
        case preparingModels
        case readingAudio(String)
        case transcribing(String)
        case segmenting
        case translating
        case done(cueCount: Int)
        case failed(String)
        case cancelled
    }

    @Published private(set) var stage: Stage = .idle
    /// 总进度 0–1，单调不倒退（计划 10.2）。
    @Published private(set) var progress: Double = 0
    /// 转写中的灰字预览（volatile，只进 UI，不落任何持久层）。
    @Published private(set) var volatileText: String?
    /// 读不了的素材：跳过并明示，不中断整个任务（全失效才 failed）。
    @Published private(set) var skippedAssets: [String] = []

    var isRunning: Bool {
        switch stage {
        case .idle, .done, .failed, .cancelled: return false
        default: return true
        }
    }

    /// 断点续跑的窗口粒度：每 ≤2 分钟音频转写完就落一次 sidecar。
    static let windowSeconds = 120.0

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
    func start(
        project: VideoEditProject,
        sourceLocaleID: String,
        targetLanguageID: String?,
        config: SubtitleSegmentationConfig = SubtitleSegmentationConfig()
    ) {
        guard !isRunning else { return }
        let token = ExportCancellationToken()
        self.token = token
        progress = 0
        volatileText = nil
        skippedAssets = []
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
                    state: state, sourceLocaleID: sourceLocaleID, token: token
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
                let result = try self.finalize(
                    project: project, harvest: harvest, config: config
                )
                guard project.isCurrentGeneration(generation) else {
                    self.stage = .cancelled
                    return
                }
                self.setProgress(0.9)
                project.replaceSubtitleForGeneration(
                    result.document,
                    sourceLanguage: Locale(identifier: sourceLocaleID)
                        .language.minimalIdentifier,
                    generation: GenerationSnapshot(
                        module: SpeechTranscriptionService.transcriberKind,
                        segmentationConfigVersion: SubtitleSegmentationConfig.version,
                        generatedAt: Date()
                    ),
                    cueMeta: result.meta
                )

                if let targetLanguageID, #available(macOS 15.0, *) {
                    self.stage = .translating
                    let outcome = await SubtitleTranslationService.shared.translateCurrentSubtitle(
                        project: project,
                        scope: .all,
                        sourceLanguage: Locale(identifier: sourceLocaleID)
                            .language.minimalIdentifier,
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

    struct SoundClip {
        var clipID: UUID
        var name: String
        var url: URL
        var fingerprint: String
        /// 探测到的素材总时长；纯音频 clip 可能拿不到（info == nil）。
        var knownAssetDuration: Double?
        var sourceStart: Double
        var sourceDuration: Double
        var timelineStart: Double
        var speed: Double
        var laneRank: Int
    }

    private struct GenerationResult {
        var document: SubtitleDocumentModel
        var meta: [UUID: CueMeta]
    }

    private struct TaskError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// 转写阶段的收成：词流账本 + 跳过的素材。分段永远基于**写回时**的时间线。
    private struct Harvest {
        var locale: Locale
        var entries: [String: TranscriptCacheEntry]
        var skippedFingerprints: Set<String>
    }

    private func transcribe(
        state: TimelineState,
        sourceLocaleID: String,
        token: ExportCancellationToken
    ) async throws -> Harvest {
        guard SpeechTranscriptionService.isAvailable else {
            throw TaskError(message: L10n(
                "Speech transcription isn't available on this Mac."
            ))
        }
        guard let locale = await SpeechTranscriptionService.matchedLocale(for: sourceLocaleID) else {
            throw TaskError(message: String(
                format: L10n("Speech transcription doesn't support “%@” on this Mac."),
                sourceLocaleID
            ))
        }
        let clips = Self.soundClips(in: state)
        guard !clips.isEmpty else {
            throw TaskError(message: L10n("No audible clips to transcribe."))
        }

        // ① 模型。下载进度折进总进度 0.02–0.1 段，不再完成前一直停 0；
        // 下载期间取消（切工程/Stop）经 Progress.cancel + 任务取消传播生效，
        // 下载抛出的取消类错误统一归一成 CancellationError。
        stage = .preparingModels
        if token.isCancelled { throw CancellationError() }
        // 进度回调按 token 验明正身再写状态（评审 P2）：回调是异步 hop 过来
        // 的，可能在旧任务取消/清理甚至新任务启动后才到 —— self.token 已换代
        // 就丢弃，旧 Progress/KVO 不许复活到新任务头上。
        do {
            try await service.ensureModel(locale: locale) { [weak self, token] progress in
                Task { @MainActor in
                    guard let self, self.token === token else { return }
                    self.installProgress = progress
                    self.modelObservation = progress.observe(
                        \.fractionCompleted, options: [.initial]
                    ) { progress, _ in
                        Task { @MainActor [weak self] in
                            guard let self, self.token === token else { return }
                            self.setProgress(0.02 + 0.08 * progress.fractionCompleted)
                        }
                    }
                }
            }
        } catch {
            if token.isCancelled || Task.isCancelled { throw CancellationError() }
            throw error
        }
        // 从这里起持有一份租约计数（ensureModel 成功 = 持有；失败已自清）。
        // 所有出口都 **await 归还后才离开** —— 终态前清理完毕，下一个任务
        // 启动时不会与迟到的释放竞速；计数账本（SpeechModelLeases）再兜一层
        // 跨任务共享（评审 P1）。
        do {
            let harvest = try await collectWindows(
                clips: clips, locale: locale, token: token
            )
            await service.releaseModel(locale: locale)
            return harvest
        } catch {
            await service.releaseModel(locale: locale)
            throw error
        }
    }

    /// 持有租约期间的主体：账本查缺 → 逐窗抽音频/转写/落盘。
    private func collectWindows(
        clips: [SoundClip], locale: Locale, token: ExportCancellationToken
    ) async throws -> Harvest {
        modelObservation = nil
        installProgress = nil
        if token.isCancelled { throw CancellationError() }
        setProgress(0.1)

        // ② 逐素材：账本查缺 → 抽音频 → 转写 → 合并落 sidecar。
        Self.sweepTempResidue()
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SrtFlow-ASR-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let grouped = Dictionary(grouping: clips, by: \.fingerprint)
        var entries: [String: TranscriptCacheEntry] = [:]

        // 进度分母：所有缺口的音频时长（命中缓存的部分零成本，进度如实反映）。
        // 缺口再切成 ≤windowSeconds 的固定窗口：每个窗口转写完立即入账落盘，
        // 长素材中途取消/崩溃最多丢一个窗口，且进度按窗口平滑推进。
        var plans: [(fingerprint: String, url: URL, name: String, windows: [SourceRange])] = []
        var totalWindowDuration = 0.0
        for (fingerprint, group) in grouped.sorted(by: { $0.key < $1.key }) {
            guard let sample = group.first else { continue }
            let entry = TranscriptSidecarStore.load(
                fingerprint: fingerprint,
                localeIdentifier: locale.identifier,
                transcriber: SpeechTranscriptionService.transcriberKind,
                configVersion: 1
            ) ?? TranscriptCacheEntry(
                fingerprint: fingerprint,
                localeIdentifier: locale.identifier,
                transcriber: SpeechTranscriptionService.transcriberKind,
                configVersion: 1
            )
            entries[fingerprint] = entry
            let desired = group.map {
                SourceRange(start: $0.sourceStart, end: $0.sourceStart + $0.sourceDuration)
            }
            // 素材边界取整组已知时长的最大值；info 全缺时退到用到的最远区间
            // （不能拿 group.first 的短切片当边界，会截掉远处切片的 padding）。
            let assetEnd = group.compactMap(\.knownAssetDuration).max()
                ?? desired.map(\.end).max() ?? 0
            let gaps = TranscriptLedger.padded(
                TranscriptLedger.gaps(desired: desired, covered: entry.covered),
                padding: 0.5,
                within: SourceRange(start: 0, end: assetEnd)
            )
            let windows = TranscriptLedger.windows(gaps, maxDuration: Self.windowSeconds)
            totalWindowDuration += windows.reduce(0) { $0 + $1.duration }
            plans.append((fingerprint, sample.url, sample.name, windows))
        }

        var doneDuration = 0.0
        var skippedFingerprints: Set<String> = []
        var skippedNames: [String] = []
        planLoop: for plan in plans {
            if token.isCancelled { throw CancellationError() }
            // 只有「这个素材读不了」才跳过（缺文件、缺音轨、解码失败）；
            // 转写/模型/临时目录这类系统性错误保留原始原因直接失败 ——
            // 不许把 Speech 故障伪装成「素材不可读」（评审 P2）。
            guard FileManager.default.fileExists(atPath: plan.url.path) else {
                skippedFingerprints.insert(plan.fingerprint)
                skippedNames.append(plan.name)
                continue
            }
            for window in plan.windows {
                if token.isCancelled { throw CancellationError() }
                stage = .readingAudio(plan.name)
                // 抽取窗口两侧各多带 0.5s 上下文（超出素材末尾由 reader
                // 自然截断）；入账时只认词中点落在本窗口内的结果 ——
                // 与 5.3 边界合同同一中点规则，相邻窗口不重复不遗漏。
                let extended = SourceRange(
                    start: max(0, window.start - 0.5), end: window.end + 0.5
                )
                let audioFile: URL
                do {
                    audioFile = try await AudioWindowReader.extract(
                        assetURL: plan.url, range: extended, into: tempDirectory,
                        isCancelled: { token.isCancelled }
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as AudioWindowReader.InfrastructureError {
                    throw error
                } catch {
                    skippedFingerprints.insert(plan.fingerprint)
                    skippedNames.append(plan.name)
                    continue planLoop
                }
                defer { try? FileManager.default.removeItem(at: audioFile) }

                if token.isCancelled { throw CancellationError() }
                stage = .transcribing(plan.name)
                let words = try await service.transcribe(
                    fileURL: audioFile, locale: locale, sourceOffset: extended.start
                ) { [weak self] text in
                    Task { @MainActor in self?.volatileText = text }
                }
                if token.isCancelled { throw CancellationError() }

                let owned = words.filter { word in
                    let mid = (word.start + word.end) / 2
                    return mid >= window.start && mid < window.end
                }
                // 空结果也记账（分析过、无语音），避免反复重扫；随窗落盘。
                entries[plan.fingerprint]?.merge(words: owned, analyzed: window)
                if let entry = entries[plan.fingerprint] {
                    TranscriptSidecarStore.save(entry)
                }
                doneDuration += window.duration
                if totalWindowDuration > 0 {
                    setProgress(0.1 + 0.75 * (doneDuration / totalWindowDuration))
                }
            }
        }
        volatileText = nil
        skippedAssets = skippedNames
        // 全部音源都读不了才算失败（方案 10.1）。
        let usable = plans.contains { !skippedFingerprints.contains($0.fingerprint) }
        guard usable || plans.isEmpty else {
            throw TaskError(message: L10n(
                "None of the audio sources could be read. Relink the missing media and try again."
            ))
        }
        return Harvest(
            locale: locale, entries: entries, skippedFingerprints: skippedFingerprints
        )

    }

    /// 分段与装配 —— 永远基于**当前**时间线（转写期间的裁切/移动/变速都被
    /// 尊重）。当前需要的区间必须已被账本覆盖：新裁进未转写段落时如实报
    /// 「时间线已变」，重跑只补新缺口。
    private func finalize(
        project: VideoEditProject,
        harvest: Harvest,
        config: SubtitleSegmentationConfig
    ) throws -> GenerationResult {
        let clips = Self.soundClips(in: project.state)
            .filter { !harvest.skippedFingerprints.contains($0.fingerprint) }
        guard !clips.isEmpty else {
            throw TaskError(message: L10n("No audible clips to transcribe."))
        }
        let timelineChanged = TaskError(message: L10n(
            "The timeline changed while generating. Generate again — cached transcription makes rerunning fast."
        ))
        var parts: [SegmentedSubtitles] = []
        for clip in clips {
            let entry = harvest.entries[clip.fingerprint] ?? TranscriptSidecarStore.load(
                fingerprint: clip.fingerprint,
                localeIdentifier: harvest.locale.identifier,
                transcriber: SpeechTranscriptionService.transcriberKind,
                configVersion: 1
            )
            guard let entry else { throw timelineChanged }
            let desired = SourceRange(
                start: clip.sourceStart, end: clip.sourceStart + clip.sourceDuration
            )
            guard TranscriptLedger.gaps(desired: [desired], covered: entry.covered).isEmpty else {
                throw timelineChanged
            }
            let window = SubtitleClipWindow(
                clipID: clip.clipID,
                assetFingerprint: clip.fingerprint,
                sourceStart: clip.sourceStart,
                sourceEnd: clip.sourceStart + clip.sourceDuration,
                timelineStart: clip.timelineStart,
                speed: clip.speed,
                laneRank: clip.laneRank
            )
            parts.append(SubtitleSegmenter.segment(
                words: entry.words, window: window, config: config
            ))
        }
        let ranks: [UUID: Int] = Dictionary(
            uniqueKeysWithValues: clips.map { ($0.clipID, $0.laneRank) }
        )
        let assembled = SubtitleSegmenter.assemble(parts) { clipID in
            clipID.flatMap { ranks[$0] } ?? -1
        }
        guard !assembled.document.cues.isEmpty else {
            throw TaskError(message: L10n(
                "No speech was recognized. Try another source language."
            ))
        }
        return GenerationResult(document: assembled.document, meta: assembled.meta)
    }

    // MARK: 工具

    private func setProgress(_ value: Double) {
        progress = max(progress, min(value, 1))
    }

    /// 出声 clip 清单 —— 与预览/导出同一份「实际可听」合同
    /// （VideoEditCompositionBuilder 先例）：mainHidden 跳过整个主轨、
    /// isHidden 的 lane 当不存在、静音或音量为 0 的 clip 不算出声。
    static func soundClips(in state: TimelineState) -> [SoundClip] {
        var result: [SoundClip] = []
        func add(_ clip: EditClip, laneRank: Int) {
            guard !clip.isMuted, clip.volume > 0, clip.stillImageURL == nil else { return }
            if let info = clip.info, !info.hasAudio { return }
            result.append(SoundClip(
                clipID: clip.id,
                name: clip.name,
                url: clip.sourceURL,
                // 纯音频 clip 的 info 可能是 nil，指纹回退到磁盘大小/mtime，
                // 避免「同路径换了文件还命中旧缓存」。
                fingerprint: TranscriptSidecarStore.fingerprint(
                    forFileAt: clip.sourceURL,
                    knownBytes: clip.info?.fileBytes,
                    knownDuration: clip.info?.duration
                ),
                knownAssetDuration: clip.info?.duration,
                sourceStart: clip.sourceStart,
                sourceDuration: clip.sourceDuration,
                timelineStart: clip.timelineStart,
                speed: clip.speed,
                laneRank: laneRank
            ))
        }
        if !state.mainHidden {
            for clip in state.mainClips { add(clip, laneRank: 0) }
        }
        for (index, lane) in state.overlayTracks.enumerated() where !lane.isHidden {
            for clip in lane.clips { add(clip, laneRank: 1 + index) }
        }
        for (index, lane) in state.audioTracks.enumerated() where !lane.isHidden {
            for clip in lane.clips {
                add(clip, laneRank: 1 + state.overlayTracks.count + index)
            }
        }
        return result
    }

    /// 启动残留清理：上次崩溃/强退留下的 SrtFlow-ASR-* 目录。
    static func sweepTempResidue() {
        let manager = FileManager.default
        let temp = URL(fileURLWithPath: NSTemporaryDirectory())
        guard let items = try? manager.contentsOfDirectory(
            at: temp, includingPropertiesForKeys: nil
        ) else { return }
        for item in items where item.lastPathComponent.hasPrefix("SrtFlow-ASR-") {
            try? manager.removeItem(at: item)
        }
    }
}
