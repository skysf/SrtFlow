import SwiftUI
import SrtFlowCore

// 双轨字幕编辑器（docs/plans/…… 第 8/12 节）：原文 + 译文并排编辑。
// 全部操作走 VideoEditProjectSubtitleLink 的合同入口（一次 perform =
// 一步撤销；stale/置信度/meta 联动由合同保证，这里不碰规则本体）。

struct LinkedSubtitleEditor: View {
    @ObservedObject var project: VideoEditProject
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<UUID> = []

    private var original: SubtitleDocumentModel? { project.state.subtitle }
    private var companion: SubtitleCompanion? { project.state.subtitleCompanion }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Subtitle Tracks").font(.headline)
                Spacer()
                Button {
                    mergeSelected()
                } label: {
                    Label("Merge", systemImage: "arrow.triangle.merge")
                }
                .disabled(selection.count < 2)
                Button {
                    splitSelected()
                } label: {
                    Label("Split", systemImage: "square.split.2x1")
                }
                .disabled(selection.count != 1)
                Button(role: .destructive) {
                    project.linkedRemoveCues(ids: selection)
                    selection = []
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(selection.isEmpty)
                Button("Close") { dismiss() }
            }
            .padding(12)
            Divider()

            if let original {
                List(selection: $selection) {
                    ForEach(original.cues) { cue in
                        LinkedCueRow(
                            project: project,
                            cue: cue,
                            translationText: companion?.translation?.cues
                                .first { $0.id == cue.id }?.text,
                            meta: companion?.cueMeta[cue.id]
                        )
                        .tag(cue.id)
                        // 文本/时间变了要重建行内编辑状态。
                        .id(rowIdentity(cue))
                    }
                }
                .listStyle(.inset)
            } else {
                Text("No subtitle track.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 640, height: 460)
    }

    private func rowIdentity(_ cue: SubtitleCue) -> String {
        let translation = companion?.translation?.cues.first { $0.id == cue.id }?.text ?? ""
        return "\(cue.id)|\(cue.start)|\(cue.end)|\(cue.text)|\(translation)"
    }

    private func splitSelected() {
        guard let id = selection.first,
              let cue = original?.cues.first(where: { $0.id == id }) else { return }
        // 无更好的拆分点信息时取中点；文本留前半（合同 8.5）。
        project.linkedSplitCue(id: id, at: (cue.start + cue.end) / 2)
    }

    private func mergeSelected() {
        project.linkedMergeCues(ids: selection)
        selection = []
    }
}

/// 一行：时间 + 原文 + 译文 + 状态标记。行内编辑，提交时走合同入口。
private struct LinkedCueRow: View {
    @ObservedObject var project: VideoEditProject
    let cue: SubtitleCue
    let translationText: String?
    let meta: CueMeta?

    @State private var startText: String
    @State private var endText: String
    @State private var originalText: String
    @State private var translationDraft: String
    // 回车、Tab 走人、点别的行、直接关面板 —— 哪条路都不许丢编辑：
    // 失焦即提交，行消失（含关面板）再兜底提交一次。
    //
    // 但兜底提交只许提交**真正脏**的字段，且提交前要过 CAS 基线检查：
    // 重译/外部改动写回后行 identity 变化会触发旧行的 onDisappear，
    // 旧草稿绝不能把刚写回的新值又盖回去（评审 P1）。
    @FocusState private var timeFocused: Bool
    @FocusState private var originalFocused: Bool
    @FocusState private var translationFocused: Bool

    /// 行创建时的基线：dirty 判定和 CAS 检查都以它为准。
    private let baselineStart: Double
    private let baselineEnd: Double
    private let baselineOriginal: String
    private let baselineTranslation: String?

    init(project: VideoEditProject, cue: SubtitleCue, translationText: String?, meta: CueMeta?) {
        self.project = project
        self.cue = cue
        self.translationText = translationText
        self.meta = meta
        baselineStart = cue.start
        baselineEnd = cue.end
        baselineOriginal = cue.text
        baselineTranslation = translationText
        _startText = State(initialValue: Timecode.formatMillis(cue.start, separator: ","))
        _endText = State(initialValue: Timecode.formatMillis(cue.end, separator: ","))
        _originalText = State(initialValue: cue.text)
        _translationDraft = State(initialValue: translationText ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("#\(cue.index)")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .frame(width: 34, alignment: .leading)
                TextField("", text: $startText)
                    .font(.caption.monospacedDigit())
                    .frame(width: 96)
                    .focused($timeFocused)
                    .onSubmit(commitTime)
                Text("→").font(.caption2).foregroundStyle(.tertiary)
                TextField("", text: $endText)
                    .font(.caption.monospacedDigit())
                    .frame(width: 96)
                    .focused($timeFocused)
                    .onSubmit(commitTime)
                Spacer()
                badges
            }
            TextField("Original text", text: $originalText, axis: .vertical)
                .lineLimit(1...3)
                .focused($originalFocused)
                .onSubmit(commitOriginal)
            if translationText != nil {
                TextField("Translated text", text: $translationDraft, axis: .vertical)
                    .lineLimit(1...3)
                    .foregroundStyle(.secondary)
                    .focused($translationFocused)
                    .onSubmit(commitTranslation)
            }
        }
        .padding(.vertical, 2)
        .textFieldStyle(.roundedBorder)
        .onChange(of: timeFocused) { _, focused in if !focused { commitTime() } }
        .onChange(of: originalFocused) { _, focused in if !focused { commitOriginal() } }
        .onChange(of: translationFocused) { _, focused in if !focused { commitTranslation() } }
        .onDisappear {
            commitTime()
            commitOriginal()
            commitTranslation()
        }
    }

    @ViewBuilder private var badges: some View {
        HStack(spacing: 4) {
            if meta?.translationStale == true {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.orange)
                    .help(L10n("Translation is out of date — retranslate this cue."))
            }
            if meta?.readingSpeedWarning == true {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.yellow)
                    .help(L10n("Too fast to read at this clip speed."))
            }
            if let confidence = meta?.recognitionConfidence, confidence < 0.5 {
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(.red)
                    .help(L10n("Low recognition confidence — double-check this cue."))
            }
        }
        .font(.caption)
    }

    private var currentOriginalCue: SubtitleCue? {
        project.state.subtitle?.cues.first { $0.id == cue.id }
    }

    private func commitTime() {
        guard let start = Timecode.parse(startText),
              let end = Timecode.parse(endText), end > start else { return }
        // dirty：草稿得和基线不同；CAS：模型仍等于基线（外部改过就放弃草稿）。
        guard abs(start - baselineStart) > 0.0005 || abs(end - baselineEnd) > 0.0005 else { return }
        guard let current = currentOriginalCue,
              abs(current.start - baselineStart) <= 0.0005,
              abs(current.end - baselineEnd) <= 0.0005 else { return }
        project.linkedSetCueTime(id: cue.id, start: start, end: end)
    }

    private func commitOriginal() {
        guard originalText != baselineOriginal else { return }
        guard let current = currentOriginalCue, current.text == baselineOriginal else { return }
        project.linkedSetOriginalText(id: cue.id, text: originalText)
    }

    private func commitTranslation() {
        guard let baselineTranslation else { return }
        guard translationDraft != baselineTranslation else { return }
        let current = project.state.subtitleCompanion?.translation?.cues
            .first { $0.id == cue.id }?.text
        // 重译刚写回新值（current ≠ 基线）时，旧草稿放弃 —— 新结果优先。
        guard current == baselineTranslation else { return }
        project.linkedSetTranslationText(id: cue.id, text: translationDraft)
    }
}
