import AppKit
import SwiftUI
import SrtFlowCore

enum WindowID {
    static let home = "home"
    static let compress = "compress"
    static let burnIn = "burn-in"
    static let batchConvert = "batch-convert"
}

/// 拦掉「启动就新建/要求打开文档」的默认行为。
///
/// 只要场景里有 DocumentGroup，AppKit 的文档控制器就会在启动时自己开一个无标题
/// 文档（或弹出打开面板）。但现在的入口是首页 —— 很多时候打开这个 App 只是想压
/// 缩一个视频，不该先被要求选字幕文件。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    /// 拖到 App 图标上、或者用「打开方式 → SrtFlow」进来的**视频**。
    ///
    /// 字幕文件不会走到这里：DocumentGroup 认得那些类型，会自己开成文档窗口。
    /// 所以这条路只管视频，一律送去压缩 —— 想烧字幕就把视频和字幕一起拖到
    /// 窗口里，那条路能同时拿到两种文件。
    ///
    /// 这里只把文件暂存进中转站，真正开窗口交给 HomeView：`openWindow` 只有在
    /// SwiftUI 视图里才拿得到。
    func application(_ application: NSApplication, open urls: [URL]) {
        let videos = urls.filter(MediaFileTypes.isVideo)
        guard !videos.isEmpty else { return }
        CompressHandoff.shared.stage(videos: videos)
    }
}

@main
struct SrtFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // 首页放在最前面，它就是启动时出现的窗口。
        // 每个场景都套一层 .appLanguage()：把应用内选的语言注入环境，
        // Text 的本地化查表会立刻跟着切换，不用重启。
        Window("SrtFlow", id: WindowID.home) {
            HomeView().appLanguage()
        }
        .defaultSize(width: 780, height: 560)
        .commands {
            CommandGroup(after: .newItem) {
                Divider()
                OpenWindowButton(title: "Compress Video…", id: WindowID.compress)
                    .keyboardShortcut("k", modifiers: [.command])
                OpenWindowButton(title: "Burn In Subtitles…", id: WindowID.burnIn)
                    .keyboardShortcut("j", modifiers: [.command])
                OpenWindowButton(title: "Batch Convert…", id: WindowID.batchConvert)
                    .keyboardShortcut("b", modifiers: [.command])
                Divider()
                OpenWindowButton(title: "SrtFlow Home", id: WindowID.home)
                    .keyboardShortcut("0", modifiers: [.command])
            }
        }

        Window("Compress Video", id: WindowID.compress) {
            CompressView().appLanguage()
        }
        .defaultSize(width: 960, height: 640)

        Window("Burn In Subtitles", id: WindowID.burnIn) {
            BurnInView().appLanguage()
        }
        .defaultSize(width: 1180, height: 760)

        Window("Batch Convert", id: WindowID.batchConvert) {
            BatchConvertView().appLanguage()
        }
        .defaultSize(width: 600, height: 440)

        DocumentGroup(newDocument: { SubtitleDocument() }) { file in
            ContentView(document: file.document).appLanguage()
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

/// 菜单项：打开指定窗口。
private struct OpenWindowButton: View {
    let title: LocalizedStringKey
    let id: String

    @Environment(\.openWindow) private var openWindow

    init(title: String, id: String) {
        self.title = LocalizedStringKey(title)
        self.id = id
    }

    var body: some View {
        Button(title) { openWindow(id: id) }
    }
}

