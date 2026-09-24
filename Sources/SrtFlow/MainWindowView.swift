import AppKit
import SwiftUI
import SrtFlowCore

/// 主窗口侧边栏里的一栏。
///
/// 「编辑字幕」不再单列：字幕表就在烧录那一栏的预览旁边，改完立刻能看到
/// 烧出来的样子，也能存回原文件。
enum ToolSection: String, CaseIterable, Identifiable {
    case compress
    case burnIn
    case videoEdit
    case batchConvert

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compress: return "Compress Video"
        case .burnIn: return "Burn In Subtitles"
        case .videoEdit: return "Edit Video"
        case .batchConvert: return "Batch Convert"
        }
    }

    var icon: String {
        switch self {
        case .compress: return "arrow.down.circle"
        case .burnIn: return "text.below.photo"
        case .videoEdit: return "film.stack"
        case .batchConvert: return "square.stack.3d.down.right"
        }
    }

    /// 鼠标停上去的说明。侧边栏只放一行标题，解释的话放这儿。
    var blurb: String {
        switch self {
        case .compress: return "Make files much smaller without visible quality loss."
        case .burnIn: return "Render subtitles permanently into the picture."
        case .videoEdit: return "Cut, arrange, and retime clips on a timeline."
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
        let _ = PerfCounters.body(Self.self)
        NavigationSplitView(columnVisibility: $state.sidebarVisibility) {
            sidebar
        } detail: {
            detail
        }
        // **标题栏不放应用名和栏目名**（2026-09-21 用户拍板：「SrtFlow / 视频剪辑
        // 这几个字很多余」）。空标题是有意的：应用名 Dock 和菜单栏已经说了一遍，
        // 栏目名左边的侧栏正高亮着，写在这儿只是把工具栏挤窄。
        //
        // 给空串而不是整个不写：不写的话 AppKit 会拿 CFBundleName 兜底，应用名
        // 又回来了。
        .navigationTitle("")
        // Translation Host：常驻零尺寸视图，字幕翻译的 session 只能活在它的
        // translationTask 闭包里（SubtitleGen/TranslationHost.swift）。
        .background {
            if #available(macOS 15.0, *) { TranslationHostView() }
        }
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
        .onChange(of: burnInHandoff.pendingSubtitles) { _, _ in routeStagedFiles() }
    }

    // MARK: - 侧边栏

    /// 侧边栏**默认只显示图标**，点一下展开成带文字的（2026-09-22 用户拍板要
    /// 「默认窄、可拉宽」）。
    ///
    /// **为什么是「点一下展开」而不是直接拉窄了让用户拉**：macOS 的
    /// `NavigationSplitView` 没有原生的图标条模式，而
    /// `.navigationSplitViewColumnWidth(min:ideal:max:)` 的 **`ideal` 在 sidebar 上
    /// 根本不生效**（2026-09-22 实测：ideal 写 64、max 留 280，列宽是 222；
    /// 把 max 也压到 64，列宽立刻变成 72 —— 也就是列宽取的是内容固有宽度再夹紧到
    /// `[min, max]`，`ideal` 不参与）。想让它一开始就窄，只能把 `max` 压小；
    /// 而 `max` 压小之后又拉不开了。
    ///
    /// 所以改成两档，由 `@AppStorage` 记住：窄档 `[60, 72]` 只放得下图标，
    /// 宽档 `[196, 280]` 里用户照样能拖着调。切换按钮在栏底。
    ///
    /// 宽档内拖出来的具体宽度仍由 AppKit autosave 记着，这是有意的 ——
    /// 想一直看文字的人不该每次重新拉。
    private var sidebar: some View {
        List(selection: sectionSelection) {
            Section {
                ForEach(ToolSection.allCases) { section in
                    SidebarToolRow(
                        section: section,
                        activity: activity(for: section),
                        isCompact: isSidebarCompact
                    )
                    .tag(section)
                }
            }
        }
        .listStyle(.sidebar)
        .background {
            GeometryReader { geo in
                Color.clear.preference(key: SidebarWidthKey.self, value: geo.size.width)
            }
        }
        .onPreferenceChange(SidebarWidthKey.self) { width in
            // 阈值取 132：最长的那条中文标签（「压缩视频」四个字 ≈ 56pt）加上
            // 图标、间距和进度徽章还能排开。低于它就只剩图标。
            //
            // **按实测宽度切，不按 `sidebarExpanded` 切**：宽档里用户还能继续往
            // 窄了拖，拖到放不下文字时该自己变回图标。
            isSidebarCompact = width < 132
        }
        .navigationSplitViewColumnWidth(
            min: sidebarExpanded ? 196 : 60,
            ideal: sidebarExpanded ? 214 : 64,
            max: sidebarExpanded ? 280 : 72
        )
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
    }

    @State private var isSidebarCompact = true
    /// 侧边栏是展开的（带文字）还是收起的（只有图标）。默认收起。
    @AppStorage("sidebarExpanded") private var sidebarExpanded = false

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
        case .videoEdit, .batchConvert: return nil
        }
    }

    // MARK: - 侧边栏底部：引擎状态 + 语言

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            // 窄成图标条时引擎状态整条藏起来：那几行字最短也要一行半，
            // 60pt 宽里只会挤成一坨看不懂的碎词。压缩和烧字幕两屏的底部各自
            // 完整显示着同一条提示，信息不会丢。
            if !isSidebarCompact { engineStatus }
            HStack(spacing: 4) {
                if !isSidebarCompact {
                    AppLanguagePicker(showsLabel: false)
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .controlSize(.small)
                }
                Spacer(minLength: 0)
                expandToggle
            }
        }
        .padding(.horizontal, isSidebarCompact ? 4 : 10)
        .padding(.bottom, 8)
    }

    /// 展开 / 收起侧边栏。窄档里语言选择器也藏起来（菜单式 Picker 有固有宽度，
    /// 60pt 里放不下），所以那时这个按钮是栏底唯一的控件。
    private var expandToggle: some View {
        Button {
            sidebarExpanded.toggle()
        } label: {
            Image(systemName: sidebarExpanded
                  ? "chevron.backward.2" : "chevron.forward.2")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .instantHelp(sidebarExpanded ? "Collapse the sidebar" : "Expand the sidebar")
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
            .instantHelp("What is wrong with the video engine, and how to fix it")
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
                            .instantHelp("Open Privacy & Security so the engine can be allowed to run")
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(command, forType: .string)
                            } label: {
                                Label("Copy command", systemImage: "doc.on.doc")
                            }
                            .instantHelp("Copy the un-quarantine command to the clipboard")
                        }
                        .controlSize(.small)
                    }
                }
                .padding(14)
                .frame(width: 330)
                .appLanguage()
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
            .instantHelp(verbatim: engineSummary(runtime))
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
        case .videoEdit: VideoEditView()
        case .batchConvert: BatchConvertView()
        }
    }

    // MARK: - 动作

    /// 中转站里有文件就切到对应的栏目，工具自己会去取。
    private func routeStagedFiles() {
        if !burnInHandoff.pendingVideos.isEmpty || !burnInHandoff.pendingSubtitles.isEmpty {
            show(.burnIn)
        }
        if !compressHandoff.pendingVideos.isEmpty { show(.compress) }
    }

    /// 切栏目，并把主窗口拉到前面 —— 文件可能是从 Dock 图标或某个字幕窗口那边来的。
    private func show(_ section: ToolSection) {
        state.section = section
        openWindow(id: WindowID.main)
    }

    /// 拖进来的东西按类型分流：视频去压缩，视频加字幕去烧字幕，光是字幕就去
    /// 烧录页的字幕列里编辑。
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

        if !subtitles.isEmpty {
            BurnInHandoff.shared.stage(videos: [], subtitles: subtitles)
            show(.burnIn)
        }
    }
}

// MARK: - 侧边栏的行

private struct SidebarToolRow: View {
    let section: ToolSection
    let activity: SidebarActivity?
    /// 栏窄到只放得下图标。
    let isCompact: Bool

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        HStack(spacing: 6) {
            // SwiftUI 没有 `AnyLabelStyle`，样式擦不了类型，只能分两支写。
            if isCompact {
                Label(LocalizedStringKey(section.title), systemImage: section.icon)
                    .labelStyle(.iconOnly)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                Label(LocalizedStringKey(section.title), systemImage: section.icon)
                    .labelStyle(.titleAndIcon)
                Spacer(minLength: 4)
                badge
            }
        }
        // 只剩图标时这条提示就是唯一的认路方式，所以**名字要在最前面** ——
        // 现在的 blurb 是功能描述，窄态下先把栏目名说出来。
        .instantHelp(
            isCompact ? LocalizedStringKey(section.title) : LocalizedStringKey(section.blurb)
        )
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


/// 侧边栏当前有多宽。用来决定显不显示文字标签。
private struct SidebarWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
