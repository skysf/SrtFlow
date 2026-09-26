import AVFoundation
import SwiftUI
import SrtFlowCore

// 字幕生成/翻译面板（docs/plans/…… 第 12 节）。能力按系统分层（1.1）：
// macOS 14 全部置灰说明版本要求；15–25 只有「翻译当前字幕」；26+ 加语音生成。
// 源语言只做 metadata 预填 + 手选（V1 无自动检测，3.7）；已有原文轨时
// 从音频生成必须先确认替换（8 合同 0）。「从音频生成」那一块在 SubtitleTranscriptionSection.swift。

struct SubtitleGenPanel: View {
    let project: VideoEditProject
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        VStack(spacing: 0) {
            HStack {
                Text("Subtitles").font(.headline)
                Spacer()
                Button("Close") { dismiss() }
                .instantHelp("Close this panel")
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
    let project: VideoEditProject
    @ObservedObject private var translationService = SubtitleTranslationService.shared
    @ObservedObject private var coordinator = TranslationJobCoordinator.shared
    /// 「编辑字幕」要把这个弹窗关掉（编辑在常驻的字幕列里做）。
    @Environment(\.dismiss) private var dismiss

    @State private var targetLanguages: [SubtitleTranslationService.TargetLanguage] = []
    @State private var targetLanguageID = ""
    /// 目标语言是不是用户自己选的。源语言未知时 `targetLanguages(from:)` 把全部
    /// 语言标成 `.supported`，「已装在前」的排序退化成纯字母序，自动挑出来的
    /// 默认值多半不是已装语言；等源语言确定、候选表重排之后必须重挑一次。
    /// 用户手动选过就不能再动他的选择 —— 这个标志就是用来区分两者的。
    @State private var targetLanguageIsUserPicked = false
    /// 冒烟发现的缺口：翻译成功要有回执，不能静默回到空闲。
    @State private var lastTranslatedCount: Int?
    /// 「全部翻译」会清空译文轨整条重建；有手改过的译文时先问一声（2026-09-26 用户拍板）。
    @State private var confirmsRebuild = false

    private var hasSubtitle: Bool { project.state.subtitle != nil }
    private var hasTranslation: Bool {
        project.state.subtitleCompanion?.translation != nil
    }
    private var sourceLanguage: String? {
        project.state.subtitleCompanion?.sourceLanguage
    }

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        VStack(alignment: .leading, spacing: 12) {
            // 这里曾经有一个「Preview track（原文/译文/双语）」选择器。
            // 已删除（2026-08-09 用户拍板）：一个语言一条字幕轨，显示什么由
            // 时间线上那两只眼睛决定 —— 与主轨/上层轨/音频同一心智，
            // 不再需要一个只影响预览的额外模式。
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
                    // 编辑不在这个弹窗里做 —— 它是预览右边那一列常驻字幕表
                    // （另外两个入口：时间线双击 cue、预览双击字幕）。这里只
                    // 负责把那一列叫出来，然后自己让路。
                    Button {
                        project.showsSubtitleList = true
                        dismiss()
                    } label: {
                        Label("Edit Subtitles…", systemImage: "list.bullet.rectangle")
                    }
                    .instantHelp("Edit the text and timing of every line")
                    Spacer()
                }
            }
        }
        .padding(14)
        .task { await reloadTargets() }
        .onChange(of: sourceLanguage) { _, _ in
            Task { await reloadTargets() }
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
                        .instantHelp("Cancel the translation")
                        .controlSize(.small)
                }
            } else {
                HStack {
                    Button("Translate All") {
                        // 清空重建会把手改过的（改过字、挪过时间、拆合过、自己加的）一起冲掉。
                        if project.state.subtitleCompanion?.hasManualTranslationEdits == true {
                            confirmsRebuild = true
                        } else {
                            translate(scope: .all)
                        }
                    }
                    .disabled(targetLanguageID.isEmpty)
                    .instantHelp("Retranslate every line, replacing what is already there")
                    .alert("Retranslate every line?", isPresented: $confirmsRebuild) {
                        Button("Retranslate All", role: .destructive) { translate(scope: .all) }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("The translated track is rebuilt from scratch. Lines you edited, moved, split or added by hand are replaced.")
                    }
                    Button("Translate Missing & Stale") {
                        translate(scope: .missingAndStale)
                    }
                    .disabled(targetLanguageID.isEmpty)
                    .instantHelp("Only translate lines with no translation, or whose source text changed")
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

    private func translate(scope: SubtitleRetranslation.Scope) {
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
