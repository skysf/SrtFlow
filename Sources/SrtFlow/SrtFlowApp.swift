import AppKit
import SwiftUI
import SrtFlowCore

enum WindowID {
    /// 装着压缩、烧字幕、批量转换的那个主窗口。
    static let main = "main"
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

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
    @ObservedObject private var project = VideoEditProject.shared

    @Environment(\.openWindow) private var openWindow

    /// ⌘S 只在剪辑页有意义 —— 在压缩页按它不该悄悄存一份剪辑工程。
    private var isEditing: Bool { windowState.section == .videoEdit }

    var body: some View {
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
        Button(title) {
            MainWindowState.shared.section = section
            openWindow(id: WindowID.main)
        }
    }
}

