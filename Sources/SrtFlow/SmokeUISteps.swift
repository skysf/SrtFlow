import AppKit
import Combine
import SwiftUI

// MARK: - 冒烟驱动：往时间线上加东西、把面板摆出来、拍别的窗口
//
// 管什么：
// - `add`：直接调工程上「加文字 / 加形状 / 盖一块 / 加滤镜 / 设转场」的动作。工具栏的「添加」是菜单，
//   驱动点不开（gui-smoke-testing.md 第 14 条）；要看这些东西的检查器长什么样只能这么进。
// - `show`：把导出面板、字幕生成面板、录屏设置页、设置窗口摆出来，或切素材库的页、开字幕列表。
//   导出 / 字幕面板是 `VideoEditView` 的 `@State`，驱动够不着，所以由它订阅 `SmokeUIRequests`
//   （只在冒烟里发东西，正式包里这个 publisher 一辈子不响）。
// - `snapshot` 的 `target`：`sheet` 拍主窗口上挂着的 sheet，`other` 拍除主窗口和它的 sheet 之外
//   最前面那个可见窗口（设置窗口）。按窗口号截图只拍那一个窗口，sheet 是另一个窗口。
// 不管什么：步骤表的格式（SmokeScript）、执行（SmokeDriver）。
//
//   {"do": "add", "kind": "text" | "shape" | "blur" | "filter" | "transition"}
//   {"do": "show", "panel": "export" | "subtitles" | "record" | "settings" | "subtitleList"
//                          | "library:transitions" | "library:filters" | "library:audio" | "dismiss"
//                          | "section:compress" | "section:burnIn" | "section:batchConvert" | "section:videoEdit"}
//   {"do": "snapshot", "name": "export", "target": "sheet"}

@MainActor
final class SmokeUIRequests {
    static let shared = SmokeUIRequests()
    /// 只在冒烟脚本的 `show` 步骤里发：`export` / `subtitles` / `dismiss`。
    let panel = PassthroughSubject<String, Never>()
}

extension View {
    /// `VideoEditView` 挂上这一个修饰器，导出 / 字幕面板就能由冒烟脚本摆出来、收回去。
    func smokeUIRequests(export: Binding<Bool>, subtitles: Binding<Bool>) -> some View {
        modifier(SmokeUIRequestsModifier(export: export, subtitles: subtitles))
    }
}

private struct SmokeUIRequestsModifier: ViewModifier {
    let export: Binding<Bool>
    let subtitles: Binding<Bool>

    func body(content: Content) -> some View {
        let _ = PerfCounters.body(Self.self)
        content.onReceive(SmokeUIRequests.shared.panel) { request in
            switch request {
            case "export": export.wrappedValue = true
            case "subtitles": subtitles.wrappedValue = true
            case "dismiss": export.wrappedValue = false; subtitles.wrappedValue = false
            default: break
            }
        }
    }
}

@MainActor
enum SmokeUISteps {
    static func add(_ step: SmokeStep, project: VideoEditProject) throws -> String {
        switch step.kind {
        case "text": project.addTextOverlay(); return "加了文字，选中 \(project.selectedTextIDs.count) 条"
        case "shape": project.addShape(.rectangle); return "加了长方形"
        case "blur": project.addShape(.blur); return "加了盖一块（模糊）"
        case "filter": project.addFilter(.tealOrange); return "加了滤镜 Teal & Orange"
        case "transition":
            guard let first = project.state.mainClips.first else { throw SmokeScriptError("add transition：主轨上没有段") }
            project.setTransition(after: first.id, .crossFade)
            return "第一段后面设了叠化"
        default: throw SmokeScriptError("add 的 kind 要是 text / shape / blur / filter / transition")
        }
    }

    static func show(_ step: SmokeStep, project: VideoEditProject) throws -> String {
        switch step.panel {
        case "export", "subtitles", "dismiss":
            SmokeUIRequests.shared.panel.send(step.panel!)
            if step.panel == "dismiss" { ScreenRecordingCoordinator.shared.cancelConfiguring() }
        case "record": ScreenRecordingCoordinator.shared.begin()
        case "settings":
            // 直接发 `showSettingsWindow:` 在 macOS 26 上不开窗口；找应用菜单里 ⌘, 那一项，照它的 target / action 发。
            guard let item = NSApp.mainMenu?.items.first?.submenu?.items.first(where: { $0.keyEquivalent == "," }) else {
                throw SmokeScriptError("show settings：应用菜单里找不到 ⌘, 那一项")
            }
            NSApp.sendAction(item.action ?? Selector(("showSettingsWindow:")), to: item.target, from: item)
        case "subtitleList": project.showsSubtitleList = true
        case "section:compress", "section:burnIn", "section:videoEdit", "section:batchConvert":
            // 切主窗口的栏目（驱动只在剪辑页里起得来，别的页要看就切过去）。
            guard let section = ToolSection(rawValue: String(step.panel!.dropFirst("section:".count))) else {
                throw SmokeScriptError("show：栏目不认识 \(step.panel!)")
            }
            MainWindowState.shared.section = section
        case "library:transitions", "library:filters", "library:audio":
            // 素材库那一栏记在 @AppStorage("libraryColumnTab") 里，改 defaults 它就跟着换页。
            UserDefaults.standard.set(String(step.panel!.dropFirst("library:".count)), forKey: "libraryColumnTab")
        default: throw SmokeScriptError("show 的 panel 不认识：\(step.panel ?? "nil")")
        }
        return "摆出 \(step.panel!)"
    }

    /// `snapshot` 要拍哪个窗口。
    static func window(for step: SmokeStep, main: NSWindow) throws -> NSWindow {
        switch step.target {
        case nil, "main": return main
        case "sheet":
            guard let sheet = main.attachedSheet else { throw SmokeScriptError("snapshot target=sheet：主窗口上没挂着 sheet") }
            return sheet
        case "other":
            let others = NSApp.windows.filter { $0.isVisible && $0 !== main && $0 !== main.attachedSheet && $0.contentView != nil }
            guard let other = others.max(by: { $0.orderedIndex > $1.orderedIndex }) else {
                throw SmokeScriptError("snapshot target=other：除主窗口外没有别的可见窗口")
            }
            return other
        default: throw SmokeScriptError("snapshot 的 target 要是 main / sheet / other")
        }
    }
}
