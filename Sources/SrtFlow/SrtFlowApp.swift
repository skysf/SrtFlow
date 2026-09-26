import AppKit
import SwiftUI
import SrtFlowCore

enum WindowID {
    /// 装着压缩、烧字幕、批量转换的那个主窗口。
    static let main = "main"
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    // MARK: - 剪切 / 拷贝 / 粘贴（剪辑页时间线上的东西，2026-09-26 起不止滤镜段）
    //
    // 动作本身在 `VideoEditTimelineClipboard.swift`（拿什么、落到哪、吸附、一步撤销）。
    //
    // **实现在 app delegate 上**，也就是响应链的最末端。两条理由：
    //
    // 一、**输入框优先，白捡的**。文本视图在响应链上排在前面，输入框里的 ⌘C
    //    还是复制文字，轮不到这里。自己监听按键的话，这件事得手写一遍。
    //
    // 二、**自己监听按键在 ⌘V 上直接不成立**（2026-09-21 实测）：⌘C 能收到，
    //    ⌘V 收不到 —— 系统「编辑」菜单里 Paste 是**亮**的（有别人响应
    //    `paste:`），键盘等价符在本地监听之前就被它吃掉了；Copy 是灰的所以漏了
    //    下来。一半通一半不通最难查，索性整件事交给响应链。
    //
    // 附带的好处：菜单项的亮灭由 `validateMenuItem` 说了算，不再是点了没反应。

    /// 这一刻这三个动作管不管用：只在剪辑页，而且剪辑页没在打字。
    ///
    /// 菜单动作和 `validateMenuItem` 都由 AppKit 在主线程上调，所以
    /// `assumeIsolated` 是成立的 —— 但这几个入口是 `@objc`，签名上不能带
    /// `@MainActor`，只能在里面声明。
    @MainActor
    private var pasteboardActionsApply: Bool {
        guard MainWindowState.shared.section == .videoEdit else { return false }
        // 正在输入框里打字时，第一响应者是文本视图，本来就轮不到 delegate；
        // 这条是双保险，也顺手把「字幕草稿开着」那种第一响应者会偶发丢掉的
        // 情况挡住（同 VideoEditView.handleEvent 的那条纪律）。
        if NSApp.keyWindow?.firstResponder is NSTextView { return false }
        return VideoEditProject.shared.subtitleDraft == nil
    }

    @objc func copy(_ sender: Any?) {
        MainActor.assumeIsolated {
            guard pasteboardActionsApply else { return }
            VideoEditProject.shared.copySelection()
        }
    }

    @objc func cut(_ sender: Any?) {
        MainActor.assumeIsolated {
            guard pasteboardActionsApply else { return }
            VideoEditProject.shared.cutSelection()
        }
    }

    /// ⌘V 认两种东西：剪贴板上的**一批时间线内容**（剪辑、文字、形状、滤镜、字幕句），和 Finder 复制的**文件**。
    /// 两种都落在鼠标那一处（鼠标在时间线的轨道区里），不在就落在播放头（2026-09-26 用户拍板）。
    ///
    /// 顺序是时间线内容优先 —— 它写的是自己的私有类型，只可能来自本 App 的 ⌘C，
    /// 意图比「剪贴板里恰好还躺着几个文件」明确。两者不会同时存在：
    /// `TimelineClipboard.write` 先 `clearContents()`。
    @objc func paste(_ sender: Any?) {
        MainActor.assumeIsolated {
            guard pasteboardActionsApply else { return }
            if TimelineClipboard.hasContent {
                VideoEditProject.shared.pasteTimelineItems(at: .keyboard)
                return
            }
            VideoEditProject.shared.pasteMediaFiles()
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        MainActor.assumeIsolated {
            switch menuItem.action {
            case #selector(copy(_:)), #selector(cut(_:)):
                return pasteboardActionsApply && VideoEditProject.shared.canCopySelection
            case #selector(paste(_:)):
                // 两种载荷任意一种都算 —— 菜单项的亮灭必须和 `paste(_:)` 认的
                // 东西一致，否则要么点了没反应，要么明明能粘却是灰的。
                // 这条判据必须是**同步**的（`validateMenuItem` 等不了异步），
                // 所以文件那半边读的是 `NSPasteboard` 而不是 `NSItemProvider`。
                return pasteboardActionsApply
                    && (TimelineClipboard.hasContent || !MediaFileDrag.pasteboardURLs().isEmpty)
            default:
                return true
            }
        }
    }

    /// 拖到 App 图标上、或者用「打开方式 → SrtFlow」进来的文件。
    ///
    /// 字幕文件（双击 .srt 也走这里）去烧录页的字幕列编辑；带字幕的视频去烧录，
    /// 光是视频就去压缩。
    ///
    /// 这里只把文件暂存进中转站，切栏目交给 MainWindowView：`openWindow` 只有在
    /// SwiftUI 视图里才拿得到。
    func application(_ application: NSApplication, open urls: [URL]) {
        // 双击 .srtflowproj 直接进剪辑页打开那条工程。
        if let projectFile = urls.first(where: {
            $0.pathExtension.lowercased() == VideoEditProjectFile.fileExtension
        }) {
            MainWindowState.shared.section = .videoEdit
            Task { await VideoEditProject.shared.openProject(at: projectFile) }
            return
        }

        let videos = urls.filter(MediaFileTypes.isVideo)
        let subtitles = urls.filter(MediaFileTypes.isSubtitle)
        if !subtitles.isEmpty {
            BurnInHandoff.shared.stage(videos: videos, subtitles: subtitles)
        } else if !videos.isEmpty {
            CompressHandoff.shared.stage(videos: videos)
        }
    }

    /// 退出前把改动落定 —— 自动保存有 2 秒防抖，正好卡在那两秒里按 ⌘Q 的话
    /// 不能把改动丢了。
    ///
    /// 必须在 shouldTerminate 这一步做而不是 willTerminate：那时已经拦不住
    /// 退出了，写盘失败（磁盘满、外接盘被拔）也只能眼睁睁丢数据。这里失败或
    /// 用户在「未命名工程要不要保存」上点了取消，就取消退出。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            // 有录制在跑时先停录、等 finalize 和导入决策 —— 那是异步的，
            // 所以返回 .terminateLater，由 coordinator 唯一一次 reply
            // （计划 §12.2；反复按 Quit 靠 finishTerminationWait 幂等）。
            if #available(macOS 15.0, *) {
                let coordinator = ScreenRecordingCoordinator.shared
                // 返回 false = 需要异步收尾，由 coordinator 唯一一次 reply，
                // 那条路径自己会走文档那一关。返回 true = 会话已撤销/本来就空闲，
                // **仍要继续往下走 prepareToCloseDocument()** —— 直接
                // `.terminateNow` 会跳过未命名工程的保存询问（复审 P1-1）。
                if coordinator.isBusy, !coordinator.prepareToTerminate() {
                    return .terminateLater
                }
            }
            return VideoEditProject.shared.prepareToCloseDocument() ? .terminateNow : .terminateCancel
        }
    }
}

@main
struct SrtFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // 主窗口放在最前面，它就是启动时出现的窗口。压缩、烧字幕、批量转换都在
        // 里面，靠左侧边栏切换。
        // 每个场景都套一层 .appLanguage()：把应用内选的语言注入环境，
        // Text 的本地化查表会立刻跟着切换，不用重启。
        Window("SrtFlow", id: WindowID.main) {
            MainWindowView().appLanguage()
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(after: .newItem) {
                ProjectCommands()
                Divider()
                SectionButton(title: "Compress Video", section: .compress)
                    .keyboardShortcut("1", modifiers: [.command])
                SectionButton(title: "Burn In Subtitles", section: .burnIn)
                    .keyboardShortcut("2", modifiers: [.command])
                SectionButton(title: "Edit Video", section: .videoEdit)
                    .keyboardShortcut("3", modifiers: [.command])
                SectionButton(title: "Batch Convert", section: .batchConvert)
                    .keyboardShortcut("4", modifiers: [.command])
            }
        }

        Settings {
            SettingsView().appLanguage()
        }
    }
}

/// 「设置…」(⌘,)。目前只有语言一项。
private struct SettingsView: View {
    @ObservedObject private var languageStore = AppLanguageStore.shared

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        Form {
            Section("Appearance") {
                AppLanguagePicker()
                if languageStore.needsRestartForMenus {
                    Text("The app’s own text switches right away. The menu bar and system dialogs follow after you quit and reopen SrtFlow.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .padding(.vertical, 8)
    }
}

/// 文件菜单里的剪辑工程那几项。
///
/// 「最近打开」读的是系统那份最近文件列表（`NSDocumentController`），跟 Dock
/// 图标右键看到的是同一份，不用自己存一套。
private struct ProjectCommands: View {
    @ObservedObject private var windowState = MainWindowState.shared
    private let project = VideoEditProject.shared

    @Environment(\.openWindow) private var openWindow

    /// ⌘S 只在剪辑页有意义 —— 在压缩页按它不该悄悄存一份剪辑工程。
    private var isEditing: Bool { windowState.section == .videoEdit }

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        // 「最近打开」那份系统列表在开 / 存工程时变，而那正是 `documentURL` 变的时候。工程是
        // `@Observable`：body 不读它就不会被叫醒，菜单就停在旧的列表上（以前订阅整个工程，是顺带刷新的）。
        let _ = project.documentURL
        Button("New Project") {
            showEditor()
            project.newProject()
        }
        .keyboardShortcut("n", modifiers: .command)

        Button("Open Project…") {
            showEditor()
            project.promptOpenProject()
        }
        .keyboardShortcut("o", modifiers: .command)

        Menu("Open Recent") {
            let recents = RecentProjects.existing()
            if recents.isEmpty {
                Text("No Recent Projects")
            } else {
                ForEach(recents, id: \.self) { url in
                    Button(url.deletingPathExtension().lastPathComponent) {
                        showEditor()
                        Task { await project.openProject(at: url) }
                    }
                }
            }
        }

        Divider()

        Button("Save") { project.saveDocument() }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!isEditing)

        Button("Save As…") { project.saveDocumentAs() }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(!isEditing)
    }

    private func showEditor() {
        windowState.section = .videoEdit
        openWindow(id: WindowID.main)
    }
}

/// 菜单项：切到主窗口的某一栏，并把窗口带到前面（可能正focus在字幕文档窗口上）。
private struct SectionButton: View {
    let title: LocalizedStringKey
    let section: ToolSection

    @Environment(\.openWindow) private var openWindow

    init(title: String, section: ToolSection) {
        self.title = LocalizedStringKey(title)
        self.section = section
    }

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        Button(title) {
            MainWindowState.shared.section = section
            openWindow(id: WindowID.main)
        }
    }
}

