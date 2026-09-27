import AppKit
import SwiftUI

// MARK: - 「看得见」：AI 改到哪，界面就跟到哪
//
// 管什么：开工前把剪辑页摆出来（切到剪辑页、窗口放到最前面但**不抢键盘** —— 用户可能正在
// 对话框里打字）；每一步之后选中改到的东西、播放头跳过去、时间线滚过去。
// 产品口径见 docs/plans/2026-09-27-mcp.md 第 7、8 条。
// 不管什么：改什么（AI*Tools）、这一轮的状态（AISession）。

@MainActor
enum AIEditorPresenter {
    /// 主窗口出现时存下来的「打开主窗口」动作。主窗口被用户关掉之后，只有它能把窗口开回来
    /// （`openWindow` 只在 SwiftUI 视图里拿得到）。
    static var openMainWindow: OpenWindowAction?

    /// 改工程之前调一次。
    static func prepareEditor(project: VideoEditProject) async throws {
        let windowState = MainWindowState.shared
        if windowState.section != .videoEdit { windowState.section = .videoEdit }
        if let window = mainWindow() {
            if window.isMiniaturized { window.deminiaturize(nil) }
            // 摆到最前面但不激活 App：键盘留在用户正在打字的地方。
            window.orderFrontRegardless()
        } else if let open = openMainWindow {
            open(id: WindowID.main)
        } else {
            throw AIToolError("SrtFlow's main window is closed. Ask the user to open it (Edit Video in the File menu, or Command-3).")
        }
        // 剪辑页出现时才把窗口的撤销管理器交给工程（VideoEditView.onAppear）；没有它，
        // AI 的改动进不了 ⌘Z。刚切过去的这一拍它还没出现，等一小会儿。
        for _ in 0..<40 where project.undoManager == nil {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    /// 装着剪辑页的那个窗口。SwiftUI 给 `Window(id:)` 的窗口起的标识符就是 id（有的系统版本后面
    /// 带编号）；认不出来时退回第一个能当主窗口、不是设置窗口的。
    static func mainWindow() -> NSWindow? {
        let candidates = NSApp.windows.filter { $0.canBecomeMain && $0.contentView != nil }
        if let match = candidates.first(where: {
            let id = $0.identifier?.rawValue ?? ""
            return id == WindowID.main || id.hasPrefix(WindowID.main + "-")
        }) {
            return match
        }
        return candidates.first { !($0.identifier?.rawValue ?? "").lowercased().contains("settings") }
    }

    /// 每一步之后给用户看的：选中哪些、播放头去哪。
    struct Reveal {
        var clips: Set<UUID> = []
        var texts: Set<UUID> = []
        var filters: Set<UUID> = []
        var cues: Set<UUID> = []
        var time: Double?
    }

    static func reveal(_ reveal: Reveal, project: VideoEditProject) {
        let selectsSomething = !reveal.clips.isEmpty || !reveal.texts.isEmpty
            || !reveal.filters.isEmpty || !reveal.cues.isEmpty
        if selectsSomething {
            project.applyBoxSelection(
                clips: reveal.clips, shapes: [], texts: reveal.texts, cues: reveal.cues, filters: reveal.filters
            )
        }
        guard let time = reveal.time else { return }
        if project.clock.isPlaying { project.clock.pause() }
        project.clock.seek(to: max(0, time))
        scrollTimeline(to: max(0, time), project: project)
    }

    /// 时间线横向滚到能看见这一刻（和播放跟随同一个判据：快出视野了才动，挪到偏左的位置）。
    private static func scrollTimeline(to time: Double, project: VideoEditProject) {
        guard let geometry = TimelineScrollGeometry.live else { return }
        let x = time * project.pixelsPerSecond
        let width = Double(geometry.viewportSize.width)
        let offset = geometry.offsetX
        guard width > 80, x < offset + 40 || x > offset + width - 80 else { return }
        geometry.scrollHorizontally(to: max(0, x - width * 0.15), animated: true)
    }
}
