import SwiftUI
import SrtFlowCore

// 字幕面板里「从音频生成」那一块（macOS 26+）。2026-09-26 从 SubtitleGenPanel.swift 拆出来。
//
// 管什么：源语言（默认自动检测）、生成后顺便翻译、「只用选中的片段」、生成 / 停止、进度与结果文案。
// 不管什么：转写本身（`TranscriptionTask`）、翻译区（`SubtitleGenPanel`）、断句和显示时间的规则
// （SrtFlowCore，docs/architecture/subtitle-generation-style.md）。

@available(macOS 26.0, *)
struct TranscriptionSection: View {
    let project: VideoEditProject
    var targetLanguages: [SubtitleTranslationService.TargetLanguage]
    @Binding var targetLanguageID: String

    @ObservedObject private var task = TranscriptionTask.shared
    @State private var sourceLocaleID = TranscriptionTask.autoDetectLocaleID
    @State private var supportedLocales: [Locale] = []
    @State private var translateAfter = false
    @State private var showsReplaceConfirm = false
    /// 「只用选中的片段」。默认不勾：随手点过一段不该让生成只转写那一段。
    @State private var onlySelected = false

    var body: some View {
        let _ = PerfCounters.body(Self.self)
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

                OnlySelectedClipsToggle(count: selectedSoundClipIDs.count, isOn: $onlySelected)

                if task.isRunning {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            ProgressView(value: task.progress)
                            Button("Stop") { task.cancel() }
                        .instantHelp("Cancel subtitle generation")
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
                    .instantHelp("Transcribe the audio on the timeline into a subtitle track")
                    // 门槛 = 有实际可听的 clip（与转写任务同一份合同）——
                    // 纯音频工程也能生成，不看有没有主视频。源语言不再是
                    // 门槛：默认的「自动检测」永远是合法选择。
                    .disabled(SubtitleAudibleClips.soundClips(in: project.state, only: generationScope).isEmpty)
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
                ? targetLanguageID : nil,
            // 按当前字幕样式和画面宽度算一行放得下多少（竖屏更短），生成的每条都不折行。
            lineFitEms: SubtitleLineFit.ems(
                style: EncodeQueue.burnIn.burnInStyle,
                layout: project.state.subtitleLayout,
                renderSize: project.renderSize
            ),
            onlyClipIDs: generationScope
        )
    }

    /// 选中的片段里听得见的（链接开着时连带链接组）。
    private var selectedSoundClipIDs: Set<UUID> {
        SubtitleAudibleClips.selectedSoundClipIDs(
            in: project.state, selected: project.selection.clipIDs, includingLinked: project.linkageEnabled
        )
    }

    /// 这次转写哪几段：勾了「只用选中的片段」、而且选中的里有听得见的，就只转写它们；否则全部（nil）。
    private var generationScope: Set<UUID>? {
        guard onlySelected else { return nil }
        let selected = selectedSoundClipIDs
        return selected.isEmpty ? nil : selected
    }

    /// 语言列表全部来自运行时查询；素材元数据不再预填 Picker（迁去当
    /// 自动检测的最高优先级候选，TranscriptionTask.metadataLanguageTag）。
    private func loadLocales() async {
        supportedLocales = await SpeechTranscriptionService.supportedLocales()
            .sorted { $0.identifier < $1.identifier }
    }
}

/// 「只用选中的片段（N 段）」：选中的片段里有听得见的才出现（2026-09-26）。
///
/// 主流剪辑软件排除某个声音靠「只选某些片段」（Final Cut Pro 只转写选中的、剪映右键「识别字幕」）：
/// 想跳过录屏原声、背景歌时，只选旁白那几段再生成。整条字幕照旧整体替换（替换前照样先问）。
@available(macOS 26.0, *)
private struct OnlySelectedClipsToggle: View {
    let count: Int
    @Binding var isOn: Bool

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        if count > 0 {
            Toggle(String(format: L10n("Only the selected clips (%d)"), count), isOn: $isOn)
                .toggleStyle(.checkbox)
                .font(.caption)
                .instantHelp("Transcribe only the selected clips, for example just the voiceover, leaving out a screen recording's own sound or background music")
        }
    }
}
