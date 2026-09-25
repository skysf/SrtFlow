import AppKit

// MARK: - 冒烟驱动的合成事件
//
// 管什么：把「点这儿 / 从这儿拖到那儿 / 在这儿滚 / 按这个键」变成 NSEvent 交给 App
// 自己的窗口。真光标不动，别的 App 也收不到。
// 不管什么：步骤表（SmokeScript）、什么时候做（SmokeDriver）。
//
// 鼠标事件直接 `window.sendEvent`（按下之前先 `allowFirstMouse`，见下）；键盘事件投进
// 事件队列（`NSApp.postEvent`）—— 编辑器的本地按键监听只在 `NSApp.sendEvent` 那一关
// 看得见事件。已知的限制：点选时判 ⌘ / ⇧ 加选读的是 `NSApp.currentEvent`，直接交给
// 窗口的鼠标事件不会成为「当前事件」，所以「⌘ 点加选」这条驱不动，用框选或 ⌘A 代替。
//
// 坐标：**窗口的点、左上原点**（按窗口 ID 截图的像素除以 2）。换算到 AppKit 的窗口坐标
// （左下原点）只在这一处做。

@MainActor
struct SmokeEvents {
    let window: NSWindow

    /// 每两拍之间留的时间：让 SwiftUI 把上一拍处理完（手势是异步落地的）。
    static let beat = Duration.milliseconds(16)

    static func flags(_ names: [String]?) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        for name in names ?? [] {
            switch name {
            case "cmd": flags.insert(.command)
            case "shift": flags.insert(.shift)
            case "option", "alt": flags.insert(.option)
            case "ctrl", "control": flags.insert(.control)
            default: break
            }
        }
        return flags
    }

    func click(_ point: CGPoint, count: Int, flags: NSEvent.ModifierFlags) async throws {
        for index in 1...max(1, count) {
            post(.leftMouseDown, at: point, clickCount: index, flags: flags)
            try await Task.sleep(for: Self.beat)
            post(.leftMouseUp, at: point, clickCount: index, flags: flags)
            try await Task.sleep(for: Self.beat)
        }
        // 单击要等过系统的双击间隔：同一个视图上还挂着双击手势时，SwiftUI 要先排除
        // 「这是双击的第一下」才落单击 —— 等少了，读到的是点之前的状态。
        let settle = count > 1 ? 0.05 : NSEvent.doubleClickInterval + 0.15
        try await Task.sleep(for: .seconds(settle))
    }

    /// 按下 → 一路小步拖过去 → 停一会儿（插入缝要停 0.2 秒才拉开）→ 松手。
    func drag(from start: CGPoint, to end: CGPoint, steps: Int, hold: Double,
              flags: NSEvent.ModifierFlags) async throws {
        post(.leftMouseDown, at: start, flags: flags)
        try await Task.sleep(for: .milliseconds(30))
        let count = max(1, steps)
        for step in 1...count {
            let t = Double(step) / Double(count)
            let point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            post(.leftMouseDragged, at: point, flags: flags)
            try await Task.sleep(for: Self.beat)
        }
        if hold > 0 {
            // 停着的时候也要有心跳：只停不发事件，SwiftUI 那边就当什么都没发生。
            let deadline = Date().addingTimeInterval(hold)
            while Date() < deadline {
                post(.leftMouseDragged, at: end, flags: flags)
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        post(.leftMouseUp, at: end, flags: flags)
        try await Task.sleep(for: .milliseconds(120))
    }

    /// 滚轮（触控板的像素滚动）。交给指针下面那个视图：滚轮事件没有「窗口不是 key 就不收」
    /// 那一关，但走队列要按屏幕位置找窗口 —— 用户的窗口正好盖在上面时就送错了人。
    func scroll(at point: CGPoint, dx: Double, dy: Double, steps: Int) async throws {
        let location = windowLocation(point)
        guard let content = window.contentView,
              let target = content.hitTest(content.convert(location, from: nil)) else {
            throw SmokeScriptError("scroll：(\(point.x), \(point.y)) 下面没有视图")
        }
        let count = max(1, steps)
        for _ in 0..<count {
            guard let cgEvent = CGEvent(
                scrollWheelEvent2Source: CGEventSource(stateID: .hidSystemState), units: .pixel,
                wheelCount: 2, wheel1: Int32(dy / Double(count)), wheel2: Int32(dx / Double(count)), wheel3: 0
            ) else { continue }
            cgEvent.location = screenLocation(location)
            if let event = NSEvent(cgEvent: cgEvent) { target.scrollWheel(with: event) }
            try await Task.sleep(for: Self.beat)
        }
        try await Task.sleep(for: .milliseconds(120))
    }

    func key(code: UInt16, chars: String, flags: NSEvent.ModifierFlags) async throws {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: chars, charactersIgnoringModifiers: chars,
                isARepeat: false, keyCode: code
            ) else { continue }
            NSApp.postEvent(event, atStart: false)
            try await Task.sleep(for: .milliseconds(30))
        }
        try await Task.sleep(for: .milliseconds(120))
    }

    /// 这一点命中的是哪个 NSView（一路往上的类名）、它收不收「窗口不是 key 时的第一下」。
    func describeHit(at point: CGPoint) -> String {
        let location = windowLocation(point)
        guard let frameView = window.contentView?.superview ?? window.contentView,
              let hit = frameView.hitTest(frameView.convert(location, from: nil)) else {
            return "(\(point.x), \(point.y)) 什么都没命中"
        }
        let probe = NSEvent.mouseEvent(
            with: .leftMouseDown, location: location, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )
        var chain: [String] = []
        var view: NSView? = hit
        while let current = view, chain.count < 6 {
            chain.append(String(describing: type(of: current)).prefix(60).description)
            view = current.superview
        }
        return "(\(point.x), \(point.y)) → \(chain.joined(separator: " ← "))，acceptsFirstMouse=\(hit.acceptsFirstMouse(for: probe))"
    }

    // MARK: - 私有

    private func post(_ type: NSEvent.EventType, at point: CGPoint, clickCount: Int = 1,
                      flags: NSEvent.ModifierFlags = []) {
        if type == .leftMouseDown { allowFirstMouse(at: point) }
        guard let event = NSEvent.mouseEvent(
            with: type, location: windowLocation(point), modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1
        ) else { return }
        window.sendEvent(event)
    }

    /// 让指针下那个视图肯收「窗口不是 key 时的第一下」：把它**这个类**的
    /// `acceptsFirstMouse(for:)` 换成恒 true。只在冒烟进程里做，每个类只换一次。
    ///
    /// 编辑器的几块面板（导航分栏的每一栏、时间线的滚动区）各是一个 AppKit 视图，
    /// 都不收第一下 —— 不换的话，非 key 窗口上的点击和拖动全被 AppKit 当成「激活窗口」吞掉。
    private func allowFirstMouse(at point: CGPoint) {
        guard let frameView = window.contentView?.superview ?? window.contentView,
              let hit = frameView.hitTest(frameView.convert(windowLocation(point), from: nil)),
              let viewClass = object_getClass(hit) else { return }
        let id = ObjectIdentifier(viewClass)
        guard !Self.firstMousePatched.contains(id) else { return }
        Self.firstMousePatched.insert(id)
        let yes: @convention(block) (AnyObject, NSEvent?) -> Bool = { _, _ in true }
        class_replaceMethod(viewClass, #selector(NSView.acceptsFirstMouse(for:)),
                            imp_implementationWithBlock(yes), "c@:@")
    }

    private static var firstMousePatched: Set<ObjectIdentifier> = []

    /// 左上原点的窗口点 → AppKit 窗口坐标（左下原点）。
    private func windowLocation(_ point: CGPoint) -> NSPoint {
        NSPoint(x: point.x, y: window.frame.height - point.y)
    }

    /// 窗口坐标 → 屏幕坐标（CGEvent 的原点在主屏左上角）。
    private func screenLocation(_ location: NSPoint) -> CGPoint {
        let onScreen = window.convertPoint(toScreen: location)
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: onScreen.x, y: mainHeight - onScreen.y)
    }
}
