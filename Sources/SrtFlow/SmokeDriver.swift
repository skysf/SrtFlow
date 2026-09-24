import AppKit
import Combine
import SwiftUI

// MARK: - 进程内的 GUI 冒烟驱动：不接管鼠标、不抢焦点
//
// 环境变量：
//   SRTFLOW_SMOKE_SCRIPT=<json>   步骤表（格式见 SmokeScript.swift）。设了才跑，也才记性能计数。
//   SRTFLOW_SMOKE_OUT=<json>      结果：每一步的日志、`perf` 的计数快照、`state` 的工程样子。
//                                 不设就写在脚本旁边（同名 .out.json）。
// 驱动它的脚本：scripts/gui-smoke/in-process/run.sh（装 SrtFlowDev.app、起进程、替它拍截图）。
//
// ## 为什么要它
//
// 人在用这台机器时，CGEvent 注入会抢走真鼠标、激活 App 会抢走键盘（docs/testing/
// gui-smoke-testing.md）。这里把合成事件直接交给自己的窗口，指针一下不动、App 不到前台。
// 窗口不是 key 时 AppKit 只把「第一下」交给肯收的视图（`acceptsFirstMouse`），所以
// 按下之前把指针下那个视图的类改成肯收（`SmokeEvents.allowFirstMouse`，只在这个进程里）。
//
// 2026-09-24 实测：不这么做，非 key 窗口上一个手势都收不到（假装 `isKeyWindow`、直接调
// `mouseDown`、根视图挂 `.allowsWindowActivationEvents(true)` 都不行 —— 编辑器的几块面板
// 各是一个 AppKit 视图，挂在根上够不着）；改了之后窗口始终不是 key，前台一直是用户那个
// App。键盘事件投进事件队列，编辑器的本地监听（⌫、M、⌘A）收得到。
//
// ## 截图
//
// App 自己拍不了（没有录屏权限）。`snapshot` 这一步在输出目录里写一个
// `<名字>.request`（内容是窗口号），等外面拍好 `<名字>.png` 再往下走 —— 终端有权限，
// run.sh 在旁边盯着这些请求。最多等 15 秒，等不到记一笔接着跑。

@MainActor
enum SmokeDriver {
    static let outputKey = "SRTFLOW_SMOKE_OUT"

    /// 冒烟脚本开着没有。键放在 `PerfCounters` 里（它要据此决定记不记账）。
    static let isRequested = ProcessInfo.processInfo.environment[PerfCounters.smokeScriptKey] != nil

    private static var started = false
    private static var log: [String] = []
    private static var perf: [String: [String: Int]] = [:]
    private static var cpu: [String: Double] = [:]
    private static var states: [String: Any] = [:]
    private static var perfStartedAt = 0.0
    /// 工程发了几次「要变了」（`objectWillChange`）：订阅整个工程的视图每一次都要重算，
    /// 所以这个数往往比 body 次数更能说明「谁在白白叫醒大家」。`perf` 快照里记成
    /// `event:project.willChange`。
    private static var projectChanges = 0
    private static var projectChangeWatch: AnyCancellable?

    /// 编辑器出现时调（`DevHooks.editorAppeared`）。没设脚本就什么都不做。
    static func startIfRequested(project: VideoEditProject) {
        guard isRequested, !started else { return }
        started = true
        let env = ProcessInfo.processInfo.environment
        let script = URL(fileURLWithPath: env[PerfCounters.smokeScriptKey] ?? "")
        let output = env[outputKey].map { URL(fileURLWithPath: $0) }
            ?? script.deletingPathExtension().appendingPathExtension("out.json")
        // 看门狗在别的线程上：主线程卡死也叫得醒，别让外面的 run.sh 干等。
        DispatchQueue.global().asyncAfter(deadline: .now() + 900) {
            FileHandle.standardError.write(Data("SmokeDriver: 900 秒还没跑完，退出\n".utf8))
            exit(3)
        }
        Task {
            do {
                let steps = try SmokeStep.load(from: script)
                guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else {
                    throw SmokeScriptError("没有可见的窗口")
                }
                note("窗口号 \(window.windowNumber)")
                // 真鼠标从这个窗口上穿过去：人还在用这台机器，指针扫过这个窗口的话，悬停扫帧、
                // 提示这些都会被真事件叫醒，量出来的数就不是脚本的了（2026-09-24 一次拖动多出
                // 两千多次重算，就是这么来的）。合成事件是直接交给窗口的，不受影响。
                window.ignoresMouseEvents = true
                projectChangeWatch = project.objectWillChange.sink { _ in projectChanges += 1 }
                for (index, step) in steps.enumerated() {
                    note("第 \(index + 1) 步：\(step.action.rawValue)")
                    if try await run(step, project: project, window: window, output: output) { break }
                }
                write(to: output, error: nil)
                exit(0)
            } catch {
                write(to: output, error: String(describing: error))
                exit(1)
            }
        }
    }

    // MARK: - 一步

    /// 返回 true = 脚本要求就此收工。
    private static func run(
        _ step: SmokeStep, project: VideoEditProject, window: NSWindow, output: URL
    ) async throws -> Bool {
        let events = SmokeEvents(window: window)
        switch step.action {
        case .wait:
            try await Task.sleep(for: .seconds(step.seconds ?? 1))
        case .settle:
            try await PreviewBench.settle(project, quietFor: step.quiet ?? 0.6, timeout: step.timeout ?? 30)
        case .window:
            // 摆在**主屏**（有菜单栏的那块）：多显示器时窗口可能落在小屏上被夹窄，
            // 布局一变，脚本里写死的坐标就全偏了。摆完把实际大小写进日志。
            let visible = (NSScreen.screens.first ?? window.screen)?.visibleFrame ?? window.frame
            let size = CGSize(width: step.width ?? window.frame.width, height: step.height ?? window.frame.height)
            window.setFrame(NSRect(origin: visible.origin, size: size), display: true)
            try await Task.sleep(for: .milliseconds(300))
            note("窗口 \(Int(window.frame.width))×\(Int(window.frame.height))，主屏可用 \(Int(visible.width))×\(Int(visible.height))")
        case .seek:
            project.clock.seek(to: step.time ?? 0, precise: true)
        case .click:
            try await events.click(SmokeStep.point(step.at, "click.at"), count: step.count ?? 1,
                                   flags: SmokeEvents.flags(step.flags))
        case .drag:
            try await events.drag(
                from: SmokeStep.point(step.from, "drag.from"), to: SmokeStep.point(step.to, "drag.to"),
                steps: step.steps ?? 20, hold: step.hold ?? 0, flags: SmokeEvents.flags(step.flags)
            )
        case .scroll:
            try await events.scroll(at: SmokeStep.point(step.at, "scroll.at"),
                                    dx: step.dx ?? 0, dy: step.dy ?? 0, steps: step.steps ?? 1)
        case .key:
            try await events.key(code: step.code ?? 0, chars: step.chars ?? "", flags: SmokeEvents.flags(step.flags))
        case .hit:
            note(events.describeHit(at: try SmokeStep.point(step.at, "hit.at")))
        case .toggles:
            // 三个开关不进工程文件（docs/architecture/timeline-drag-gestures.md 4.5），脚本里直接拨。
            if let magnet = step.magnet { project.magnetEnabled = magnet }
            if let snapping = step.snapping { project.snappingEnabled = snapping }
            if let linkage = step.linkage { project.linkageEnabled = linkage }
            note("开关：磁吸 \(project.magnetEnabled) 吸附 \(project.snappingEnabled) 链接 \(project.linkageEnabled)")
        case .focus:
            // 排查「⌫ 被谁吃了」：编辑器的按键监听在第一响应者是 NSTextView 时让路。
            let keyWindow = NSApp.keyWindow.map { "\(type(of: $0)) #\($0.windowNumber)" } ?? "nil"
            let responder = NSApp.keyWindow?.firstResponder.map { "\(type(of: $0))" } ?? "nil"
            let windows = NSApp.windows.filter(\.isVisible).map { "\(type(of: $0)) #\($0.windowNumber)" }
            note("keyWindow=\(keyWindow) firstResponder=\(responder) 可见窗口=\(windows)")
        case .perfReset:
            PerfCounters.reset()
            perfStartedAt = PreviewBench.cpuTimeMs()
            projectChanges = 0
        case .perf:
            let label = step.label ?? "perf\(perf.count + 1)"
            var counts = PerfCounters.snapshot()
            counts["event:project.willChange"] = projectChanges
            perf[label] = counts
            cpu[label] = (PreviewBench.cpuTimeMs() - perfStartedAt).rounded()
        case .state:
            states[step.label ?? "state\(states.count + 1)"] = SmokeStateDump.make(project)
        case .snapshot:
            try await requestSnapshot(step.name ?? "snapshot", window: window, output: output)
        case .quit:
            return true
        }
        return false
    }

    /// 请外面（run.sh）按窗口号拍一张，拍好了再往下走。
    private static func requestSnapshot(_ name: String, window: NSWindow, output: URL) async throws {
        let folder = output.deletingLastPathComponent()
        let picture = folder.appendingPathComponent("\(name).png")
        try? FileManager.default.removeItem(at: picture)
        try Data("\(window.windowNumber)".utf8).write(to: folder.appendingPathComponent("\(name).request"))
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: picture.path) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        note("截图 \(name) 等了 15 秒没等到，跳过")
    }

    // MARK: - 结果

    private static func note(_ line: String) {
        log.append(line)
        FileHandle.standardError.write(Data("SmokeDriver: \(line)\n".utf8))
    }

    private static func write(to output: URL, error: String?) {
        var body: [String: Any] = ["log": log, "perf": perf, "cpuMs": cpu, "state": states]
        if let error { body["error"] = error }
        if let data = try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: output)
        }
    }
}
