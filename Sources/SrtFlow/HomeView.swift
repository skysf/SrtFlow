import SwiftUI
import SrtFlowCore

/// 启动后的第一屏：四个入口，外加把文件直接拖进来。
///
/// 以前打开 App 就是一个文档窗口，等着你选字幕文件；但增加压缩和烧字幕之后，
/// 很多时候进来只是想把一个视频变小，不该先被要求打开字幕。
struct HomeView: View {
    @Environment(\.openWindow) private var openWindow
    @StateObject private var toolchain = MediaToolchain.shared
    @StateObject private var compressHandoff = CompressHandoff.shared
    @StateObject private var burnInHandoff = BurnInHandoff.shared
    // 这个视图在代码里拼字符串（L10n(...)），不是纯 LocalizedStringKey，
    // 光靠环境 locale 变化不会重新求值 body，所以要显式观察语言选择。
    @ObservedObject private var languageStore = AppLanguageStore.shared

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    cards
                }
                .padding(28)
            }
            Divider()
            statusBar
        }
        .frame(minWidth: 640, minHeight: 460)
        .onAppear {
            toolchain.resolveIfNeeded()
            // 启动时就是被文件唤起的，这时中转站里已经有东西了。
            routeStagedFiles()
        }
        .onDropOfFiles { urls in handleDrop(urls) }
        // AppDelegate 只能把文件放进中转站，开窗口得由视图来做。
        .onChange(of: compressHandoff.pendingVideos) { _, _ in routeStagedFiles() }
        .onChange(of: burnInHandoff.pendingVideos) { _, _ in routeStagedFiles() }
    }

    // MARK: - 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SrtFlow")
                .font(.system(size: 30, weight: .semibold))
            Text("Subtitles and video, all on your Mac.")
                .foregroundStyle(.secondary)
            Text("Drop a video or a subtitle file anywhere in this window.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - 入口卡片

    private var cards: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 320), spacing: 16)],
            spacing: 16
        ) {
            HomeCard(
                icon: "arrow.down.circle",
                title: "Compress Video",
                subtitle: "Make files much smaller without visible quality loss.",
                detail: "H.264 CRF or the M-series hardware encoder."
            ) {
                openWindow(id: WindowID.compress)
            }

            HomeCard(
                icon: "text.below.photo",
                title: "Burn In Subtitles",
                subtitle: "Render subtitles permanently into the picture.",
                detail: "Adjustable font, colour and position, with presets."
            ) {
                openWindow(id: WindowID.burnIn)
            }

            HomeCard(
                icon: "square.and.pencil",
                title: "Edit Subtitles",
                subtitle: "Open a subtitle file to edit timing and text.",
                detail: "Text, SRT, VTT, ASS and SSA."
            ) {
                openSubtitleDocument()
            }

            HomeCard(
                icon: "square.stack.3d.down.right",
                title: "Batch Convert",
                subtitle: "Convert many subtitle files at once.",
                detail: "Any supported format to any other."
            ) {
                openWindow(id: WindowID.batchConvert)
            }
        }
    }

    // MARK: - 底部状态条

    private var statusBar: some View {
        HStack(spacing: 8) {
            if toolchain.isResolving {
                ProgressView().controlSize(.small)
                Text("Checking the video engine…").foregroundStyle(.secondary)
            } else if let warning = toolchain.warning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(warning)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    // 提示里可能带一条要粘到终端的命令，得能选中复制。
                    .textSelection(.enabled)
            } else if let runtime = toolchain.runtime {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Text(engineSummary(runtime))
                    .foregroundStyle(.secondary)
            }
            Spacer()

            // 语言切换放在这儿，中英用户都能一眼找到。
            AppLanguagePicker(showsLabel: false)
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 130)
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.35))
    }

    private func engineSummary(_ runtime: FFmpegRuntime) -> String {
        let version = runtime.versionLine
            .replacingOccurrences(of: "ffmpeg version ", with: "")
            .split(separator: " ").first.map(String.init) ?? "?"
        return String(
            format: L10n("Video engine ready — ffmpeg %@ (%@, native Apple silicon)"),
            version,
            runtime.sourceDescription
        )
    }

    // MARK: - 动作

    private func openSubtitleDocument() {
        let urls = FilePicker.chooseFiles(
            types: SubtitleDocument.readableContentTypes,
            allowsMultiple: false
        )
        guard let url = urls.first else { return }
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
    }

    /// 中转站里有文件就把对应的窗口开出来。窗口已经开着的话就是把它拉到前面。
    private func routeStagedFiles() {
        if !burnInHandoff.pendingVideos.isEmpty {
            openWindow(id: WindowID.burnIn)
        }
        if !compressHandoff.pendingVideos.isEmpty {
            openWindow(id: WindowID.compress)
        }
    }

    /// 拖进来的东西按类型分流：视频去压缩，字幕直接打开编辑。
    private func handleDrop(_ urls: [URL]) {
        let videos = urls.filter(MediaFileTypes.isVideo)
        let subtitles = urls.filter(MediaFileTypes.isSubtitle)

        if !videos.isEmpty {
            // 同时拖进视频和字幕，显然是想烧字幕。
            if !subtitles.isEmpty {
                BurnInHandoff.shared.stage(videos: videos, subtitles: subtitles)
                openWindow(id: WindowID.burnIn)
            } else {
                CompressHandoff.shared.stage(videos: videos)
                openWindow(id: WindowID.compress)
            }
            return
        }

        for url in subtitles {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
        }
    }
}

private struct HomeCard: View {
    let icon: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let detail: LocalizedStringKey
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 26))
                    .foregroundStyle(.tint)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isHovering ? Color.primary.opacity(0.08) : Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.separator, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// 首页把文件交给别的窗口时用的中转站。
///
/// SwiftUI 的 `openWindow(id:)` 不能带参数，所以先把 URL 放这儿，
/// 目标窗口出现时自己来取。
@MainActor
final class CompressHandoff: ObservableObject {
    static let shared = CompressHandoff()
    @Published var pendingVideos: [URL] = []

    private init() {}

    func stage(videos: [URL]) {
        pendingVideos.append(contentsOf: videos)
    }

    func take() -> [URL] {
        let result = pendingVideos
        pendingVideos.removeAll()
        return result
    }
}

@MainActor
final class BurnInHandoff: ObservableObject {
    static let shared = BurnInHandoff()
    @Published var pendingVideos: [URL] = []
    @Published var pendingSubtitles: [URL] = []

    private init() {}

    func stage(videos: [URL], subtitles: [URL]) {
        pendingVideos.append(contentsOf: videos)
        pendingSubtitles.append(contentsOf: subtitles)
    }

    func take() -> (videos: [URL], subtitles: [URL]) {
        let result = (pendingVideos, pendingSubtitles)
        pendingVideos.removeAll()
        pendingSubtitles.removeAll()
        return result
    }
}
