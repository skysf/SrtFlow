import AppKit
import SwiftUI
import SrtFlowCore

/// 主窗口侧边栏里的一栏。
///
/// 「编辑字幕」不在这里：它是 `DocumentGroup`，SwiftUI 规定文档场景各开自己的
/// 窗口，塞不进侧边栏的右侧面板。这么分也说得通 —— 压缩、烧字幕、批量转换都是
/// 「做一批活儿」的工具，一个窗口够了；改字幕是编辑文档，一个文件一个窗口，
/// ⌘S、版本历史、同时开好几个文件这些原生行为都得留着。
enum ToolSection: String, CaseIterable, Identifiable {
    case compress
    case burnIn
    case batchConvert

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compress: return "Compress Video"
        case .burnIn: return "Burn In Subtitles"
        case .batchConvert: return "Batch Convert"
        }
    }

    var icon: String {
        switch self {
        case .compress: return "arrow.down.circle"
        case .burnIn: return "text.below.photo"
        case .batchConvert: return "square.stack.3d.down.right"
        }
    }

    /// 鼠标停上去的说明。侧边栏只放一行标题，解释的话放这儿。
    var blurb: String {
        switch self {
        case .compress: return "Make files much smaller without visible quality loss."
        case .burnIn: return "Render subtitles permanently into the picture."
        case .batchConvert: return "Convert many subtitle files at once."
        }
    }
}

/// 主窗口当前在哪一栏。
///
/// 单独拎出来是因为菜单和 Dock 拖放都要能切栏目，它们拿不到视图里的 `@State`。
@MainActor
final class MainWindowState: ObservableObject {
    static let shared = MainWindowState()

    private static let sectionKey = "mainWindowSection"

    /// 记住上次用的那一栏，下次打开直接进去。
    @Published var section: ToolSection {
        didSet { UserDefaults.standard.set(section.rawValue, forKey: Self.sectionKey) }
    }

    /// 侧边栏显示状态。放在这里是因为放大预览时要临时把它收起来 ——
    /// 那时候整个窗口都该让给画面。
    @Published var sidebarVisibility: NavigationSplitViewVisibility = .all

    private init() {
        let stored = UserDefaults.standard.string(forKey: Self.sectionKey)
        section = stored.flatMap(ToolSection.init(rawValue:)) ?? .compress
    }
}

/// 一个窗口装下所有工具：左边侧边栏切换，右边是当前工具。
///
/// 以前压缩、烧字幕、批量转换各是一个独立窗口，来回切要在窗口之间找。合成一个
/// 之后还顺手解决了一件事：三个工具的状态都提到了全局（`EncodeQueue.compress`
/// 等），所以压缩可以在后台一直跑，同时去另一栏调字幕样式。
struct MainWindowView: View {
    @Environment(\.openWindow) private var openWindow

    @ObservedObject private var state = MainWindowState.shared
    @ObservedObject private var toolchain = MediaToolchain.shared
    @ObservedObject private var compressQueue = EncodeQueue.compress
    @ObservedObject private var burnInQueue = EncodeQueue.burnIn
    @ObservedObject private var compressHandoff = CompressHandoff.shared
    @ObservedObject private var burnInHandoff = BurnInHandoff.shared
    // 这个视图在代码里拼字符串（L10n(...)），不是纯 LocalizedStringKey，
    // 光靠环境 locale 变化不会重新求值 body，所以要显式观察语言选择。
    @ObservedObject private var languageStore = AppLanguageStore.shared

    var body: some View {
        NavigationSplitView(columnVisibility: $state.sidebarVisibility) {
            sidebar
        } detail: {
            detail
        }
        .navigationTitle("SrtFlow")
        // 标题栏的副标题要自己查表：它是桥到 AppKit 窗口上的，不走 SwiftUI 的
        // 环境 locale，交给 LocalizedStringKey 的话中文界面下会漏成英文。
        .navigationSubtitle(L10n(state.section.title))
        .onAppear {
            toolchain.resolveIfNeeded()
            // 启动时就是被文件唤起的，这时中转站里已经有东西了。
            routeStagedFiles()
        }
        // 拖到侧边栏或窗口空白处的文件按类型分流。拖到某个工具的列表上则由那个
        // 工具自己接（子视图的 onDrop 优先），直接进它的队列。
        .onDropOfFiles { urls in handleDrop(urls) }
        // AppDelegate 只能把文件放进中转站，切栏目得由视图来做。
        .onChange(of: compressHandoff.pendingVideos) { _, _ in routeStagedFiles() }
        .onChange(of: burnInHandoff.pendingVideos) { _, _ in routeStagedFiles() }
    }

    // MARK: - 侧边栏

    private var sidebar: some View {
        List(selection: sectionSelection) {
            Section {
                ForEach(ToolSection.allCases) { section in
                    SidebarToolRow(section: section, activity: activity(for: section))
                        .tag(section)
                }
            }
            Section {
                SidebarActionRow(
                    title: "Edit Subtitles",
                    icon: "square.and.pencil",
                    help: "Opens a subtitle file in its own editor window.",
                    action: openSubtitleDocument
                )
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 196, ideal: 214, max: 280)
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
    }

    /// 侧边栏的选中项。点空白处 List 会把它清成 nil，那时保持原样 —— 右边不能空着。
    private var sectionSelection: Binding<ToolSection?> {
        Binding(
            get: { state.section },
            set: { if let new = $0 { state.section = new } }
        )
    }

    private func activity(for section: ToolSection) -> SidebarActivity? {
        switch section {
        case .compress: return compressQueue.sidebarActivity
        case .burnIn: return burnInQueue.sidebarActivity
        case .batchConvert: return nil
        }
    }

    // MARK: - 侧边栏底部：引擎状态 + 语言

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            engineStatus
            AppLanguagePicker(showsLabel: false)
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    @State private var showsEngineDetail = false

    @ViewBuilder
    private var engineStatus: some View {
        if toolchain.isResolving {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking the video engine…").foregroundStyle(.secondary)
            }
            .font(.caption)
        } else if let warning = toolchain.warning {
            // 提示本身可能长到几行（解隔离那条还带一整行命令），侧边栏塞不下，
            // 点开看。压缩和烧字幕那两屏的底部也各自完整显示着同一条提示。
            Button { showsEngineDetail = true } label: {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Video engine needs attention")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .font(.caption)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showsEngineDetail, arrowEdge: .trailing) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if let command = toolchain.quarantineFixCommand {
                        HStack(spacing: 8) {
                            // 不用碰终端的那条路，直接把设置面板打开。
                            Button {
                                toolchain.openPrivacySettings()
                            } label: {
                                Label("Open System Settings", systemImage: "gearshape")
                            }
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(command, forType: .string)
                            } label: {
                                Label("Copy command", systemImage: "doc.on.doc")
                            }
                        }
                        .controlSize(.small)
                    }
                }
                .padding(14)
                .frame(width: 330)
            }
        } else if let runtime = toolchain.runtime {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Text(shortEngineSummary(runtime))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .font(.caption)
            // 完整的一句（版本、来自哪里、是不是原生）留在提示里。
            .help(engineSummary(runtime))
        }
    }

    private func ffmpegVersion(_ runtime: FFmpegRuntime) -> String {
        runtime.versionLine
            .replacingOccurrences(of: "ffmpeg version ", with: "")
            .split(separator: " ").first.map(String.init) ?? "?"
    }

    private func shortEngineSummary(_ runtime: FFmpegRuntime) -> String {
        String(format: L10n("Engine ready · ffmpeg %@"), ffmpegVersion(runtime))
    }

    private func engineSummary(_ runtime: FFmpegRuntime) -> String {
        String(
            format: L10n("Video engine ready — ffmpeg %@ (%@, native Apple silicon)"),
            ffmpegVersion(runtime),
            runtime.sourceDescription
        )
    }

    // MARK: - 右侧

    @ViewBuilder
    private var detail: some View {
        switch state.section {
        case .compress: CompressView()
        case .burnIn: BurnInView()
        case .batchConvert: BatchConvertView()
        }
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

    /// 中转站里有文件就切到对应的栏目，工具自己会去取。
    private func routeStagedFiles() {
        if !burnInHandoff.pendingVideos.isEmpty { show(.burnIn) }
        if !compressHandoff.pendingVideos.isEmpty { show(.compress) }
    }

    /// 切栏目，并把主窗口拉到前面 —— 文件可能是从 Dock 图标或某个字幕窗口那边来的。
    private func show(_ section: ToolSection) {
        state.section = section
        openWindow(id: WindowID.main)
    }

    /// 拖进来的东西按类型分流：视频去压缩，视频加字幕去烧字幕，光是字幕就打开编辑。
    private func handleDrop(_ urls: [URL]) {
        let videos = urls.filter(MediaFileTypes.isVideo)
        let subtitles = urls.filter(MediaFileTypes.isSubtitle)

        if !videos.isEmpty {
            // 同时拖进视频和字幕，显然是想烧字幕。
            if !subtitles.isEmpty {
                BurnInHandoff.shared.stage(videos: videos, subtitles: subtitles)
                show(.burnIn)
            } else {
                CompressHandoff.shared.stage(videos: videos)
                show(.compress)
            }
            return
        }

        for url in subtitles {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
        }
    }
}

// MARK: - 侧边栏的行

private struct SidebarToolRow: View {
    let section: ToolSection
    let activity: SidebarActivity?

    var body: some View {
        HStack(spacing: 6) {
            Label(LocalizedStringKey(section.title), systemImage: section.icon)
            Spacer(minLength: 4)
            badge
        }
        .help(LocalizedStringKey(section.blurb))
    }

    /// 切走了也能看见这一栏还在忙。
    @ViewBuilder
    private var badge: some View {
        switch activity {
        case .running(let fraction):
            Text(MediaFormatting.percent(fraction))
                .font(.caption2)
                .monospacedDigit()
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.tint.opacity(0.22), in: Capsule())
        case .finished(let count):
            HStack(spacing: 2) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                if count > 1 { Text("\(count)") }
            }
            .font(.caption2)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.red)
        case nil:
            EmptyView()
        }
    }
}

/// 侧边栏里点了会另开窗口的那一行。
///
/// 它不是选中项（选中了右边却不会变，那样很怪），所以自己画悬停高亮，
/// 尺寸和圆角对着旁边真正的侧边栏项来。
private struct SidebarActionRow: View {
    let title: String
    let icon: String
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Label(LocalizedStringKey(title), systemImage: icon)
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.forward.app")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovering ? Color.primary.opacity(0.08) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
        .onHover { isHovering = $0 }
        .help(LocalizedStringKey(help))
    }
}

// MARK: - 文件中转站

/// 从 AppDelegate 或别的栏目把文件交给某个工具时用的中转站。
///
/// 工具视图只在自己那一栏显示时才存在，文件先放这儿，它出现时自己来取。
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
