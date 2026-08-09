import AppKit
import SwiftUI
import SrtFlowCore

// 导出矩阵的字幕部分（docs/plans/2026-08-06-native-subtitle-generation.md 第 13 节）：
// 「要不要烧字幕」开关 + 独立字幕文件多选导出。
// **烧哪几条不在这里选** —— 一个语言一条轨，看得见的就是会被烧进去的
// （合同见 docs/architecture/subtitle-track-visibility-and-layout.md）。
// 独立导出不依赖视频导出，可单独执行；写盘走 SubtitleExportPlanner
// （临时名 → 回读校验 → 原子替换，失败不碰用户文件）。

struct SubtitleExportOptions {

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

    /// 要不要把字幕烧进画面。**烧哪几条不在这里选** —— 一个语言一条轨，
    /// 看得见的就是会被烧进去的（2026-08-09 用户拍板）。
    /// 这里曾经是「无/原文/译文/双语」四选一，与时间线上的眼睛两套并存，
    /// 用户得自己解释「为什么预览的和烧出来的不一样」。
    var burnIn = true
    var files: Set<FileItem> = []

    /// 烧录进滤镜图的文档：**与预览同一份合同**（两只眼睛推导），
    /// 关掉总开关或两只眼睛都关就是 nil。
    func burnDocument(state: TimelineState) -> SubtitleDocumentModel? {
        guard burnIn else { return nil }
        return state.visibleSubtitleDocument()
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
                Toggle("Burn subtitles into the video", isOn: $options.burnIn)
                if options.burnIn {
                    if exportState.visibleSubtitleChoice == nil {
                        // 两只眼睛都关着：烧录合同会得到 nil，把「为什么没烧」
                        // 说出来，不许静默烧出无字幕的成片让用户猜。
                        Label(
                            "Every subtitle track is hidden — nothing will be burned.",
                            systemImage: "eye.slash"
                        )
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    } else {
                        // 烧哪几条完全由眼睛决定，这里如实报出当前会烧什么。
                        Label(L10n(burnScopeTitle), systemImage: "captions.bubble")
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

    /// 当前眼睛状态下会烧什么 —— 固定键，**不许运行时拼**（拼出来的字符串
    /// 在 strings 表里查不到，中文界面会漏成英文）。
    private var burnScopeTitle: String {
        switch exportState.visibleSubtitleChoice {
        case .bilingual: return "Burning both subtitle tracks, with the Burn In tool's style."
        case .translation: return "Burning the translated track, with the Burn In tool's style."
        default: return "Burning the original track, with the Burn In tool's style."
        }
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
