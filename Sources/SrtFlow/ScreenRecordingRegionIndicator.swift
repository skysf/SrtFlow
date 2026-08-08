import AppKit
import Foundation
import SrtFlowCore

/// 录制**自定义区域**期间，在被录区域之外盖一层浅遮罩 + 描边。
///
/// 目的：录制过程中一眼看得出「哪里会进画面、哪里不会」。选区面板只在挑区域时
/// 存在，一旦开录就销毁了，之前录制期间没有任何提示。
///
/// 三条硬要求：
///
/// 1. **它自己绝不能被录进去。** 靠 `NSWindow.sharingType = .none`
///    （窗口服务器级别，不依赖任何授权），和录制控制窗用的是同一套机制。
///    这也是为什么以前做不了这个功能 —— 遮罩会连同画面一起被捕获。
/// 2. **绝不拦截鼠标。** `ignoresMouseEvents = true`：用户录制时还要正常操作
///    底下的应用，遮罩只是视觉提示。
/// 3. **只用于区域来源。** 整屏录制时全屏都会进画面，盖遮罩是错的；
///    窗口来源的窗口会移动，跟踪成本另说，这一版不做。
@available(macOS 15.0, *)
@MainActor
final class ScreenRecordingRegionIndicator {

    private let panel: NSPanel

    /// - Parameter regionInAppKit: 被录区域的 **AppKit 全局**坐标
    ///   （由 `ScreenRecordingCoordinateMapper.appKitRect(fromDisplayLocal:)` 换算）。
    /// - Parameter screen: 区域所在的那块屏。
    init?(regionInAppKit: CGRect, screen: NSScreen) {
        guard regionInAppKit.width > 0, regionInAppKit.height > 0 else { return nil }

        panel = NSPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // 浮在普通窗之上即可；不用 .screenSaver，免得盖住系统级 UI。
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        // 要求 2：不吃鼠标事件。
        panel.ignoresMouseEvents = true
        // 要求 1：把自己从任何屏幕捕获里摘出去，否则遮罩会被录进成片。
        panel.sharingType = .none

        // 视图内坐标 = 全局减去屏幕原点。
        let local = regionInAppKit.offsetBy(
            dx: -screen.frame.minX, dy: -screen.frame.minY
        )
        panel.contentView = RegionMaskView(frame: NSRect(origin: .zero, size: screen.frame.size),
                                           hole: local)
    }

    func show() { panel.orderFrontRegardless() }
    func close() { panel.orderOut(nil) }
}

@available(macOS 15.0, *)
private final class RegionMaskView: NSView {
    private let hole: NSRect

    init(frame: NSRect, hole: NSRect) {
        self.hole = hole
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func draw(_ dirtyRect: NSRect) {
        // **浅**遮罩：选区面板用 0.28（那时要突出正在画的框），录制期只是提示
        // 边界，压到 0.14，免得挡住用户正在演示的内容。
        NSColor.black.withAlphaComponent(0.14).setFill()
        bounds.fill()

        // 挖空被录区域。
        NSColor.clear.setFill()
        hole.fill(using: .copy)

        // 描一圈红边，与「正在录制」的语义一致。
        NSColor.systemRed.withAlphaComponent(0.9).setStroke()
        let border = NSBezierPath(rect: hole.insetBy(dx: -1, dy: -1))
        border.lineWidth = 2
        border.stroke()
    }
}
