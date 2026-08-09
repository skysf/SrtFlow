import AVFoundation
import SwiftUI
import SrtFlowCore

// 字幕生成/翻译面板（docs/plans/…… 第 12 节）。能力按系统分层（1.1）：
// macOS 14 全部置灰说明版本要求；15–25 只有「翻译当前字幕」；26+ 加语音生成。
// 源语言只做 metadata 预填 + 手选（V1 无自动检测，3.7）；已有原文轨时
// 从音频生成必须先确认替换（8 合同 0）。

struct SubtitleGenPanel: View {
    @ObservedObject var project: VideoEditProject
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Subtitles").font(.headline)
                Spacer()
                Button("Close") { dismiss() }
            }
            .padding(14)
            Divider()
            if #available(macOS 15.0, *) {
                SubtitleGenPanelContent(project: project)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "captions.bubble")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("Subtitle translation needs macOS 15 or later; speech transcription needs macOS 26 or later.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
            }
        }
        .frame(width: 430)
    }
}

@available(macOS 15.0, *)
private struct SubtitleGenPanelContent: View {
    @ObservedObject var project: VideoEditProject
    @ObservedObject private var translationService = SubtitleTranslationService.shared
    @ObservedObject private var coordinator = TranslationJobCoordinator.shared

    @State private var targetLanguages: [SubtitleTranslationService.TargetLanguage] = []
    @State private var targetLanguageID = ""
    /// 目标语言是不是用户自己选的。源语言未知时 `targetLanguages(from:)` 把全部
    /// 语言标成 `.supported`，「已装在前」的排序退化成纯字母序，自动挑出来的
    /// 默认值多半不是已装语言；等源语言确定、候选表重排之后必须重挑一次。
    /// 用户手动选过就不能再动他的选择 —— 这个标志就是用来区分两者的。
    @State private var targetLanguageIsUserPicked = false
    @State private var showsEditor = false
    /// 冒烟发现的缺口：翻译成功要有回执，不能静默回到空闲。
    @State private var lastTranslatedCount: Int?

    private var hasSubtitle: Bool { project.state.subtitle != nil }
    private var hasTranslation: Bool {
        project.state.subtitleCompanion?.translation != nil
    }
    private var sourceLanguage: String? {
        project.state.subtitleCompanion?.sourceLanguage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 预览轨道选择（消费者清单 8.9 之一）。
            // 只在真有译文时才出现：segmented 样式下 SwiftUI 不认逐项 .disabled
            // （已知怪癖），没译文却留着「译文/双语」两段，点下去
            // subtitleDocument(for:) 返回 nil，预览字幕会整个消失且毫无提示。
            // 没有译文时本来也无从选择，与其摆一个点了会出事的控件不如不显示。
            if hasSubtitle && hasTranslation {
                // 键不能用 "Original"：strings 表里那条是编码设置的「保持原样」。
                Picker("Preview track", selection: $project.subtitlePreviewTrack) {
                    Text("Original text").tag(SubtitleTrackChoice.original)
                    Text("Translated text").tag(SubtitleTrackChoice.translation)
                    Text("Bilingual").tag(SubtitleTrackChoice.bilingual)
                }
                .pickerStyle(.segmented)
            }

            // 生成区在前（2026-08-09 案例）：面板的第一入口是「从音频生成」，
            // 翻译区在没有字幕轨之前整个不出现 —— 不摆一个无从选择的目标
            // 语言，更不允许一个没露过面的自动预选值驱动任何翻译。
            generationSection

            if hasSubtitle {
                Divider()
                translationSection
            }

            if hasSubtitle {
                Divider()
                HStack {
                    Button {
                        showsEditor = true
                    } label: {
                        Label("Edit Subtitles…", systemImage: "list.bullet.rectangle")
                    }
                    Spacer()
                }
            }
        }
        .padding(14)
        .task { await reloadTargets() }
        .onChange(of: sourceLanguage) { _, _ in
            Task { await reloadTargets() }
        }
        .sheet(isPresented: $showsEditor) {
            LinkedSubtitleEditor(project: project)
        }
    }

    // MARK: 翻译（macOS 15+）

    /// 只在真有字幕轨时渲染（body 侧 hasSubtitle 门控）。
    @ViewBuilder private var translationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Translate").font(.subheadline).bold()
            Picker("Target language", selection: Binding(
                get: { targetLanguageID },
                set: { targetLanguageID = $0; targetLanguageIsUserPicked = true }
            )) {
                ForEach(targetLanguages) { target in
                    Text(target.needsDownload
                        ? String(format: L10n("%@ (needs download)"), target.displayName)
                        : target.displayName
                    ).tag(target.id)
                }
            }

            if case .running(let completed, let total) = coordinator.phase {
                HStack(spacing: 8) {
                    ProgressView(value: Double(completed), total: Double(max(total, 1)))
                    Text("\(completed)/\(total)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Button("Stop") { coordinator.cancel() }
                        .controlSize(.small)
                }
            } else {
                HStack {
                    Button("Translate All") {
                        translate(scope: .all)
                    }
                    .disabled(targetLanguageID.isEmpty)
                    Button("Translate Missing & Stale") {
                        translate(scope: .staleOrMissing)
                    }
                    .disabled(targetLanguageID.isEmpty)
                }
                Text("Translation runs entirely on this Mac. The system may download language models first.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if let count = lastTranslatedCount {
                Label(String(format: L10n("Translated %d cues."), count), systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = translationService.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
        }
    }

    private func translate(scope: SubtitleTranslationService.Scope) {
        let target = targetLanguageID
        let source = sourceLanguage
        lastTranslatedCount = nil
        Task {
            let outcome = await translationService.translateCurrentSubtitle(
                project: project, scope: scope,
                sourceLanguage: source, targetLanguage: target
            )
            // 只有真翻上了才给回执；失败文案由 service.lastError 展示，
            // 取消/作废保持沉默（用户自己触发或工程已切走）。
            if case .translated(let count) = outcome {
                lastTranslatedCount = count
            }
        }
    }

    private func reloadTargets() async {
        targetLanguages = await translationService.targetLanguages(from: sourceLanguage)
        // 候选表重排后，只有「用户自己选过且仍然有效」的值才保留原样；自动挑的
        // 默认值必须跟着重排走，否则源语言未知时按字母序挑中的那个会一直粘着，
        // 等源语言确定、已装语言排到最前面了也不会被换掉（见
        // targetLanguageIsUserPicked 的说明）。
        let stillValid = !targetLanguageID.isEmpty
            && targetLanguages.contains { $0.id == targetLanguageID }
        guard !stillValid || !targetLanguageIsUserPicked else { return }
        targetLanguageID = project.state.subtitleCompanion?.targetLanguage
            .flatMap { tag in targetLanguages.first { $0.id.hasPrefix(tag) }?.id }
            ?? targetLanguages.first?.id ?? ""
    }

    // MARK: 生成（macOS 26+）

    @ViewBuilder private var generationSection: some View {
        if #available(macOS 26.0, *) {
            TranscriptionSection(
                project: project,
                targetLanguages: targetLanguages,
                targetLanguageID: Binding(
                    get: { targetLanguageID },
                    set: { targetLanguageID = $0; targetLanguageIsUserPicked = true }
                )
            )
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("Generate from audio").font(.subheadline).bold()
                Text("Speech transcription needs macOS 26 or later.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - 语音生成区（macOS 26+）

@available(macOS 26.0, *)
private struct TranscriptionSection: View {
    @ObservedObject var project: VideoEditProject
    var targetLanguages: [SubtitleTranslationService.TargetLanguage]
    @Binding var targetLanguageID: String

    @ObservedObject private var task = TranscriptionTask.shared
    @State private var sourceLocaleID = TranscriptionTask.autoDetectLocaleID
    @State private var supportedLocales: [Locale] = []
    @State private var translateAfter = false
    @State private var showsReplaceConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Generate from audio").font(.subheadline).bold()

            if !SpeechTranscriptionService.isAvailable {
                Text("Speech transcription isn't available on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                // 默认自动检测（两段式：探针转写 + 置信度裁决，TranscriptionTask）。
                // 素材元数据不再预填 Picker，而是作为检测的最高优先级候选。
                Picker("Source language", selection: $sourceLocaleID) {
                    Text("Auto-detect").tag(TranscriptionTask.autoDetectLocaleID)
                    ForEach(supportedLocales, id: \.identifier) { locale in
                        Text(Locale.current.localizedString(forIdentifier: locale.identifier)
                            ?? locale.identifier
                        ).tag(locale.identifier)
                    }
                }
                Toggle("Translate after generating", isOn: $translateAfter)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .disabled(targetLanguages.isEmpty)
                if translateAfter {
                    // 目标语言必须当着用户的面选定（2026-08-09 案例）：一个
                    // 没露过面的自动预选值曾把英文字幕拿去翻成英语，爆出系统
                    // 的泛化「Unable to Translate」。
                    Picker("Target language", selection: $targetLanguageID) {
                        ForEach(targetLanguages) { target in
                            Text(target.needsDownload
                                ? String(format: L10n("%@ (needs download)"), target.displayName)
                                : target.displayName
                            ).tag(target.id)
                        }
                    }
                }

                if task.isRunning {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            ProgressView(value: task.progress)
                            Button("Stop") { task.cancel() }
                                .controlSize(.small)
                        }
                        Text(stageText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let volatile = task.volatileText, !volatile.isEmpty {
                            Text(volatile)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(2)
                        }
                    }
                } else {
                    Button {
                        if project.state.subtitle != nil {
                            showsReplaceConfirm = true
                        } else {
                            start()
                        }
                    } label: {
                        Label("Generate Subtitles", systemImage: "waveform.and.mic")
                    }
                    // 门槛 = 有实际可听的 clip（与转写任务同一份合同）——
                    // 纯音频工程也能生成，不看有没有主视频。源语言不再是
                    // 门槛：默认的「自动检测」永远是合法选择。
                    .disabled(SubtitleAudibleClips.soundClips(in: project.state).isEmpty)
                    stageResultText
                }
            }
        }
        .task { await loadLocales() }
        .confirmationDialog(
            "Replace the current subtitle track?",
            isPresented: $showsReplaceConfirm
        ) {
            Button("Replace", role: .destructive) { start() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Generating replaces the current subtitles and clears their translation. This is one undo step.")
        }
    }

    private var stageText: String {
        switch task.stage {
        case .idle: return ""
        case .detectingLanguage: return L10n("Detecting spoken language…")
        case .preparingModels: return L10n("Preparing speech model…")
        case .readingAudio(let name): return String(format: L10n("Reading audio of “%@”…"), name)
        case .transcribing(let name): return String(format: L10n("Transcribing “%@”…"), name)
        case .segmenting: return L10n("Building subtitle cues…")
        case .translating: return L10n("Translating…")
        case .done, .failed, .cancelled: return ""
        }
    }

    @ViewBuilder private var stageResultText: some View {
        if let note = task.translationSkipNote {
            // 翻译被如实跳过（字幕已是目标语言）：通知，不是错误。
            Label(note, systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        if !task.skippedAssets.isEmpty {
            Label(
                String(
                    format: L10n("Skipped unreadable sources: %@"),
                    task.skippedAssets.joined(separator: ", ")
                ),
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(.orange)
            .lineLimit(2)
        }
        switch task.stage {
        case .done(let count):
            Label(String(format: L10n("Generated %d cues."), count), systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(3)
        case .cancelled:
            Text("Cancelled.")
                .font(.caption)
                .foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }

    private func start() {
        TranscriptionTask.shared.start(
            project: project,
            sourceLocaleID: sourceLocaleID,
            targetLanguageID: translateAfter && !targetLanguageID.isEmpty
                ? targetLanguageID : nil
        )
    }

    /// 语言列表全部来自运行时查询；素材元数据不再预填 Picker（迁去当
    /// 自动检测的最高优先级候选，TranscriptionTask.metadataLanguageTag）。
    private func loadLocales() async {
        supportedLocales = await SpeechTranscriptionService.supportedLocales()
            .sorted { $0.identifier < $1.identifier }
    }
}
