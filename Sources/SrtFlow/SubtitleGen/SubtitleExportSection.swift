import AppKit
import SwiftUI
import SrtFlowCore

// 导出矩阵的字幕部分（docs/plans/2026-08-06-native-subtitle-generation.md 第 13 节）：
// 烧录轨道选择（无/原文/译文/双语）+ 独立字幕文件多选导出。
// 独立导出不依赖视频导出，可单独执行；写盘走 SubtitleExportPlanner
// （临时名 → 回读校验 → 原子替换，失败不碰用户文件）。

struct SubtitleExportOptions {
    enum Burn: String, CaseIterable {
        case none, original, translation, bilingual

        // 注意：键不能用光秃秃的 "Original"/"Translation" —— 前者在
        // Localizable.strings 里已被编码设置的「保持原样」占用。
        var title: String {
            switch self {
            case .none: return "No subtitles"
            case .original: return "Original text"
            case .translation: return "Translated text"
            case .bilingual: return "Bilingual"
            }
        }

        var trackChoice: SubtitleTrackChoice? {
            switch self {
            case .none: return nil
            case .original: return .original
            case .translation: return .translation
            case .bilingual: return .bilingual
            }
        }
    }

    struct FileItem: Hashable, Identifiable {
        var track: SubtitleTrackChoice
        var format: SubtitleFormat
        var id: String { "\(track.rawValue).\(format.rawValue)" }

        /// 独立文件矩阵只有原文/译文 ×  SRT/VTT（双语只用于烧录）。
        static let all: [FileItem] = [
            FileItem(track: .original, format: .srt),
            FileItem(track: .original, format: .vtt),
            FileItem(track: .translation, format: .srt),
            FileItem(track: .translation, format: .vtt)
        ]

        /// 固定键，**不许运行时拼**：拼出来的字符串在 strings 表里查不到，
        /// 中文界面会漏成英文。
        var title: String {
            switch (track, format) {
            case (.translation, .vtt): return "Translated VTT"
            case (.translation, _): return "Translated SRT"
            case (_, .vtt): return "Original VTT"
            default: return "Original SRT"
            }
        }
    }

    var burn: Burn = .original
    var files: Set<FileItem> = []

    /// 烧录进滤镜图的文档（选择的轨道合成 + 合同排序），选 none 得 nil。
    /// 走 visible 变体：字幕轨隐藏（眼睛）时不烧录，与预览同一份合同。
    func burnDocument(state: TimelineState) -> SubtitleDocumentModel? {
        guard let choice = burn.trackChoice else { return nil }
        return state.visibleSubtitleDocument(for: choice)
    }
}

struct SubtitleExportSection: View {
    @ObservedObject var project: VideoEditProject
    @Binding var options: SubtitleExportOptions
    /// 实际导出的时间线（选中导出时字幕本来就不随行，这里跟着一致）。
    var exportState: TimelineState

    @State private var writtenFiles: [String] = []
    @State private var writeError: String?

    private var hasTranslation: Bool {
        exportState.subtitleCompanion?.translation != nil
    }

    var body: some View {
        if exportState.subtitle != nil {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Burn in", selection: $options.burn) {
                    ForEach(SubtitleExportOptions.Burn.allCases, id: \.self) { choice in
                        Text(L10n(choice.title)).tag(choice)
                            .disabled(needsTranslation(choice) && !hasTranslation)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: hasTranslation) { _, has in
                    if !has, needsTranslation(options.burn) { options.burn = .original }
                }
                if options.burn != .none {
                    if exportState.subtitleHidden {
                        // 轨道头的眼睛关着：烧录合同会得到 nil（burnDocument
                        // 走 visible 变体），这里把「为什么没烧」说出来。
                        Label("Subtitle track is hidden — nothing will be burned.", systemImage: "eye.slash")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    } else {
                        Label("Burned with the Burn In tool's current style.", systemImage: "captions.bubble")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                Divider()

                Text("Subtitle files")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    ForEach(SubtitleExportOptions.FileItem.all) { item in
                        Toggle(L10n(item.title), isOn: fileBinding(item))
                            .toggleStyle(.checkbox)
                            .font(.caption)
                            .disabled(item.track == .translation && !hasTranslation)
                    }
                }
                HStack {
                    Button("Export Subtitle Files…") { exportFiles() }
                        .controlSize(.small)
                        .disabled(options.files.isEmpty)
                    if !writtenFiles.isEmpty {
                        Label(writtenFiles.joined(separator: ", "), systemImage: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                if let writeError {
                    Text(writeError)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
        }
    }

    private func needsTranslation(_ burn: SubtitleExportOptions.Burn) -> Bool {
        burn == .translation || burn == .bilingual
    }

    private func fileBinding(_ item: SubtitleExportOptions.FileItem) -> Binding<Bool> {
        Binding(
            get: { options.files.contains(item) },
            set: { on in
                if on { options.files.insert(item) } else { options.files.remove(item) }
            }
        )
    }

    /// 独立字幕文件导出：选目录 → 逐个「命名 → 冲突避让 → 校验写盘」。
    private func exportFiles() {
        writtenFiles = []
        writeError = nil
        let state = exportState
        guard state.subtitle != nil else { return }
        guard let directory = FilePicker.chooseDirectory() else { return }

        let base = state.mainClips.first?.name
            ?? state.audioTracks.first?.clips.first?.name
            ?? "Timeline"
        let companion = state.subtitleCompanion
        var written: [String] = []
        do {
            for item in options.files.sorted(by: { $0.id < $1.id }) {
                guard let document = state.subtitleDocument(for: item.track) else { continue }
                let name = SubtitleExportPlanner.fileName(
                    base: (base as NSString).deletingPathExtension,
                    choice: item.track,
                    sourceLanguage: companion?.sourceLanguage,
                    targetLanguage: companion?.targetLanguage,
                    format: item.format
                )
                let url = SubtitleExportPlanner.availableURL(directory: directory, fileName: name)
                try SubtitleExportPlanner.writeValidated(document, format: item.format, to: url)
                written.append(url.lastPathComponent)
            }
            writtenFiles = written
        } catch {
            writtenFiles = written
            writeError = error.localizedDescription
        }
    }
}
