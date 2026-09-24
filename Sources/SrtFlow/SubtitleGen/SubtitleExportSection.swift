import AppKit
import SwiftUI
import SrtFlowCore

// 导出矩阵的字幕部分（docs/plans/2026-08-06-native-subtitle-generation.md 第 13 节）：
// 「要不要烧字幕」开关（导出面板主区）+ 独立字幕文件多选导出（「高级」里）。
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

/// 「要不要烧字幕」开关 + 这次会烧什么。导出面板的主区里，工程有字幕才出现：
/// 烧不烧会直接改变成片画面，是每次导出都该看一眼的决定。
struct SubtitleBurnInToggle: View {
    @Binding var options: SubtitleExportOptions
    /// 实际导出的时间线（选中导出时字幕本来就不随行，这里跟着一致）。
    var exportState: TimelineState

    var body: some View {
        if exportState.subtitle != nil {
            Toggle("Burn subtitles into the video", isOn: $options.burnIn)
            if options.burnIn {
                if exportState.visibleSubtitleChoice == nil {
                    // 两只眼睛都关着：烧录合同会得到 nil，把「为什么没烧」
                    // 说出来，不许静默烧出无字幕的成片让用户猜。
                    Label(
                        "Every subtitle track is hidden — nothing will be burned.",
                        systemImage: "eye.slash"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                } else {
                    // 烧哪几条完全由眼睛决定，这里如实报出当前会烧什么。
                    Label(L10n(burnScopeTitle), systemImage: "captions.bubble")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
}

/// 独立字幕文件（导出面板「高级」里）。不依赖视频导出，可以单独写。
///
/// 写进面板上的「导出至」，文件名跟着标题走（`<标题>.<lang>.srt`），和视频同名
/// 放在一起，IINA / VLC 这类播放器会自动挂上。**撞名和视频同一条规则：先提示、
/// 再确认替换**（以前是追加 -2/-3，重导几次就堆出一串，也和视频配不上对）。
/// 约束见 docs/architecture/export-settings.md。
struct SubtitleFilesExport: View {
    @Binding var options: SubtitleExportOptions
    var exportState: TimelineState
    /// 面板上的导出位置，和已经清理成能当文件名的标题主干。
    var folder: URL
    var stem: String

    @State private var writtenFiles: [URL] = []
    @State private var writeError: String?
    @State private var confirmsReplace = false

    private var hasTranslation: Bool {
        exportState.subtitleCompanion?.translation != nil
    }

    /// 勾上的每一份要写到哪。没有对应文档的（比如还没翻译）跳过。
    private var targets: [(item: SubtitleExportOptions.FileItem, url: URL)] {
        let companion = exportState.subtitleCompanion
        return options.files.sorted { $0.id < $1.id }.compactMap { item in
            if item.track == .translation, !hasTranslation { return nil }
            let name = SubtitleExportPlanner.fileName(
                base: stem,
                choice: item.track,
                sourceLanguage: companion?.sourceLanguage,
                targetLanguage: companion?.targetLanguage,
                format: item.format
            )
            return (item, folder.appendingPathComponent(name))
        }
    }

    /// 会被替换的已有文件（点按钮时据此确认，和视频导出同一条规则）。
    private var existing: [URL] {
        targets.map(\.url).filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// 提示条只报「别人的」文件：刚从这里写出去的那几份不算，不然一写完就冒出
    /// 「已存在」。真要再写一次，点按钮时照样会问。
    private var existingHint: [URL] {
        existing.filter { !writtenFiles.contains($0) }
    }

    var body: some View {
        if exportState.subtitle != nil {
            // 一行一条轨（原文 / 译文），一列一种格式：四个挤一行在 420 宽的面板里会折行。
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                ForEach([SubtitleTrackChoice.original, .translation], id: \.self) { track in
                    GridRow {
                        ForEach(SubtitleExportOptions.FileItem.all.filter { $0.track == track }) { item in
                            Toggle(L10n(item.title), isOn: fileBinding(item))
                                .toggleStyle(.checkbox)
                                .disabled(item.track == .translation && !hasTranslation)
                        }
                    }
                }
            }
            Text("Saved into the export folder above, named after the title.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !existingHint.isEmpty {
                Label(replaceHint, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                Button("Export Subtitle Files") { requestWrite() }
                    .instantHelp("Write the checked subtitle files into the export folder")
                    .controlSize(.small)
                    .disabled(targets.isEmpty)
                if !writtenFiles.isEmpty {
                    Label(
                        writtenFiles.map(\.lastPathComponent).joined(separator: ", "),
                        systemImage: "checkmark.circle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                }
            }
            // 挂在按钮这一行上：确认的是「这几份字幕」，和视频的那个确认互不相干。
            .alert(Text(verbatim: replaceTitle), isPresented: $confirmsReplace) {
                Button("Replace", role: .destructive) { write() }
                Button("Cancel", role: .cancel) {}
            } message: {
                // 一份就说清楚会发生什么（和视频的确认同一句）；几份就把名字列出来。
                Text(verbatim: existing.count == 1
                    ? String(
                        format: L10n("A file with this name is already in “%@”. Replacing it overwrites its contents."),
                        folder.lastPathComponent
                    )
                    : existing.map(\.lastPathComponent).joined(separator: "\n"))
            }
            if let writeError {
                Text(writeError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
    }

    private var replaceHint: String {
        existingHint.count == 1
            ? String(format: L10n("“%@” is already in this folder. Exporting will replace it."), existingHint[0].lastPathComponent)
            : String(format: L10n("%d of these files are already in this folder. Exporting will replace them."), existingHint.count)
    }

    private var replaceTitle: String {
        existing.count == 1
            ? String(format: L10n("Replace “%@”?"), existing.first?.lastPathComponent ?? "")
            : String(format: L10n("Replace %d subtitle files?"), existing.count)
    }

    private func fileBinding(_ item: SubtitleExportOptions.FileItem) -> Binding<Bool> {
        Binding(
            get: { options.files.contains(item) },
            set: { on in
                if on { options.files.insert(item) } else { options.files.remove(item) }
            }
        )
    }

    private func requestWrite() {
        if existing.isEmpty { write() } else { confirmsReplace = true }
    }

    /// 逐份「序列化 → 临时名 → 回读校验 → 原子替换」（SubtitleExportPlanner），
    /// 任何一份失败都不碰它原来的文件；已经写好的照样报出来。
    private func write() {
        writeError = nil
        var written: [URL] = []
        do {
            for target in targets {
                guard let document = exportState.subtitleDocument(for: target.item.track) else { continue }
                try SubtitleExportPlanner.writeValidated(document, format: target.item.format, to: target.url)
                written.append(target.url)
            }
        } catch {
            writeError = error.localizedDescription
        }
        writtenFiles = written
    }
}
