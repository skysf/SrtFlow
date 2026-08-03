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
        let videos = urls.filter(MediaFileTypes.isVideo)
        let subtitles = urls.filter(MediaFileTypes.isSubtitle)
        if !subtitles.isEmpty {
            BurnInHandoff.shared.stage(videos: videos, subtitles: subtitles)
        } else if !videos.isEmpty {
            CompressHandoff.shared.stage(videos: videos)
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

