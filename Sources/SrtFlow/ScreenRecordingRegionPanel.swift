import AppKit
import Foundation
import SrtFlowCore

/// 自定义区域的选择 overlay（计划 §6.2）。
///
/// 每块 `NSScreen` 一个透明 borderless panel；第一次 mouse-down 锁定所在显示器，
/// 之后只在那块屏内 clamp（跨屏区域产品上不支持）。Return / 双击确认，Escape 取消。
///
/// **坐标换算一律走 `ScreenRecordingCoordinateMapper`**：
/// 翻转轴是主屏高度（不是屏幕并集顶边 —— 那个错误公式同样能自反往返，
/// 曾经骗过往返测试）；夹取在**这一层**做完，mapper 那边要求区域完整落屏、
/// 部分跨界返回 nil，绝不静默裁剪。
@available(macOS 15.0, *)
@MainActor
final class ScreenRecordingRegionPanel {

    struct Result {
        var displayID: CGDirectDisplayID
        /// 全局 CG 坐标（top-left 原点）下的区域，单位点。
        var rectInPoints: CGRect
    }

    private var panels: [RegionOverlayPanel] = []
    private var continuation: CheckedContinuation<Result?, Never>?
    private let ratio: RegionAspectRatio

    init(ratio: RegionAspectRatio) {
        self.ratio = ratio
    }

    /// 铺满所有屏幕等用户拖一个区域。返回 nil = 用户取消。
    func present() async -> Result? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            for screen in NSScreen.screens {
                let panel = RegionOverlayPanel(screen: screen, ratio: ratio) { [weak self] result in
                    self?.finish(result)
                }
                panel.orderFrontRegardless()
                panels.append(panel)
            }
            // overlay 要能收键盘（Escape / Return）
            NSApp.activate(ignoringOtherApps: true)
            panels.first?.makeKey()
        }
    }

    /// 外部强制取消（App 退出等）。幂等。
    func cancel() { finish(nil) }

    private func finish(_ result: Result?) {
        guard let continuation else { return }
        self.continuation = nil
        // **确认后所有 overlay 必须先销毁再往下走**（计划 §6.2-5）：
        // 它们是全屏透明窗，留着会进成片。
        for panel in panels { panel.orderOut(nil) }
        panels.removeAll()
        continuation.resume(returning: result)
    }
}

// MARK: - 单块屏上的 overlay

@available(macOS 15.0, *)
private final class RegionOverlayPanel: NSPanel {
    private let selectionView: RegionSelectionView

    init(
        screen: NSScreen,
        ratio: RegionAspectRatio,
        onFinish: @escaping (ScreenRecordingRegionPanel.Result?) -> Void
    ) {
        selectionView = RegionSelectionView(screen: screen, ratio: ratio, onFinish: onFinish)
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        ignoresMouseEvents = false
        hasShadow = false
        isReleasedWhenClosed = false
        contentView = selectionView
    }

    override var canBecomeKey: Bool { true }
}

@available(macOS 15.0, *)
private final class RegionSelectionView: NSView {
    private let screenRef: NSScreen
    private let ratio: RegionAspectRatio
    private let onFinish: (ScreenRecordingRegionPanel.Result?) -> Void

    /// 当前选区（视图内坐标，bottom-left 原点）。
    ///
    /// **一开始就有一个默认框**，不是空白等用户画。真机首测反馈：上来什么都没有、
    /// 也没有任何按钮，用户不知道下一步做什么。
    private var selection: NSRect = .zero

    /// 正在进行的拖拽。
    private enum Drag {
        /// 在空白处按下 → 画新框，`anchor` 是按下点。
        case drawing(anchor: CGPoint)
        /// 在框内按下 → 整体移动，`grabOffset` 是按下点相对左下角的偏移。
        case moving(grabOffset: CGSize)
        /// 抓住某个把手 → 缩放，`fixed` 是对角/对边上不动的那个点。
        case resizing(handle: Handle, fixed: CGPoint)
    }
    private var drag: Drag?

    /// 八个缩放把手。
    private enum Handle: CaseIterable {
        case bottomLeft, bottom, bottomRight, right, topRight, top, topLeft, left
    }
    private static let handleSide: CGFloat = 10

    private lazy var recordButton = makeButton(
        title: L10n("Record"), action: #selector(confirmTapped), isDefault: true
    )
    private lazy var cancelButton = makeButton(
        title: L10n("Cancel"), action: #selector(cancelTapped), isDefault: false
    )

    init(
        screen: NSScreen,
        ratio: RegionAspectRatio,
        onFinish: @escaping (ScreenRecordingRegionPanel.Result?) -> Void
    ) {
        self.screenRef = screen
        self.ratio = ratio
        self.onFinish = onFinish
        super.init(frame: screen.frame)
        addSubview(recordButton)
        addSubview(cancelButton)
        selection = ScreenRecordingCoordinateMapper.defaultRegion(in: bounds, ratio: ratio.value)
        layoutButtons()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var acceptsFirstResponder: Bool { true }

    // MARK: 按钮

    private func makeButton(title: String, action: Selector, isDefault: Bool) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .large
        if isDefault {
            button.keyEquivalent = "\r"
            button.bezelColor = .controlAccentColor
        }
        return button
    }

    @objc private func confirmTapped() { confirm() }
    @objc private func cancelTapped() { onFinish(nil) }

    /// 按钮跟着选区走：优先放在框下方，下方放不下就放框内底部。
    private func layoutButtons() {
        let usable = ScreenRecordingCoordinateMapper.isUsableRegion(selection)
        recordButton.isEnabled = usable
        recordButton.sizeToFit()
        cancelButton.sizeToFit()
        let spacing: CGFloat = 8
        let totalWidth = recordButton.frame.width + cancelButton.frame.width + spacing
        // 尺寸标签在框正下方，按钮再往下一层；空间不够就放到框内。
        let below = selection.minY - 34 - recordButton.frame.height
        let y = below > 8 ? below : selection.minY + 12
        var x = selection.midX - totalWidth / 2
        x = min(max(x, 8), bounds.maxX - totalWidth - 8)
        cancelButton.setFrameOrigin(NSPoint(x: x, y: y))
        recordButton.setFrameOrigin(
            NSPoint(x: x + cancelButton.frame.width + spacing, y: y)
        )
    }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.28).setFill()
        bounds.fill()
        guard ScreenRecordingCoordinateMapper.isUsableRegion(selection)
                || selection.width > 0 else { return }

        // 选区挖空
        NSColor.clear.setFill()
        selection.fill(using: .copy)
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(rect: selection)
        path.lineWidth = 2
        path.stroke()

        drawHandles()
        drawSizeLabel(for: selection)
    }

    /// 八个把手 —— 让「这个框可以调整」这件事**看得出来**。
    private func drawHandles() {
        NSColor.controlAccentColor.setFill()
        NSColor.white.setStroke()
        for handle in Handle.allCases {
            let rect = handleRect(handle)
            let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
            path.fill()
            path.lineWidth = 1
            path.stroke()
        }
    }

    private func handleRect(_ handle: Handle) -> NSRect {
        let side = Self.handleSide
        let center = handleCenter(handle)
        return NSRect(
            x: center.x - side / 2, y: center.y - side / 2, width: side, height: side
        )
    }

    private func handleCenter(_ handle: Handle) -> CGPoint {
        switch handle {
        case .bottomLeft:  return CGPoint(x: selection.minX, y: selection.minY)
        case .bottom:      return CGPoint(x: selection.midX, y: selection.minY)
        case .bottomRight: return CGPoint(x: selection.maxX, y: selection.minY)
        case .right:       return CGPoint(x: selection.maxX, y: selection.midY)
        case .topRight:    return CGPoint(x: selection.maxX, y: selection.maxY)
        case .top:         return CGPoint(x: selection.midX, y: selection.maxY)
        case .topLeft:     return CGPoint(x: selection.minX, y: selection.maxY)
        case .left:        return CGPoint(x: selection.minX, y: selection.midY)
        }
    }

    /// 缩放时保持不动的那个点（对角或对边中点）。
    private func fixedPoint(for handle: Handle) -> CGPoint {
        switch handle {
        case .bottomLeft:  return CGPoint(x: selection.maxX, y: selection.maxY)
        case .bottomRight: return CGPoint(x: selection.minX, y: selection.maxY)
        case .topRight:    return CGPoint(x: selection.minX, y: selection.minY)
        case .topLeft:     return CGPoint(x: selection.maxX, y: selection.minY)
        case .bottom:      return CGPoint(x: selection.minX, y: selection.maxY)
        case .top:         return CGPoint(x: selection.minX, y: selection.minY)
        case .left:        return CGPoint(x: selection.maxX, y: selection.minY)
        case .right:       return CGPoint(x: selection.minX, y: selection.minY)
        }
    }

    /// 实时显示逻辑尺寸与最终像素尺寸（计划 §6.2-4）。
    private func drawSizeLabel(for rect: NSRect) {
        let geometry = displayGeometry
        let pixels = ScreenRecordingCoordinateMapper.captureSize(
            forRegionInPoints: rect.size, display: geometry
        )
        let usable = ScreenRecordingCoordinateMapper.isUsableRegion(rect)
        let text = usable
            ? String(
                format: L10n("%d × %d pt  ·  %d × %d px"),
                Int(rect.width), Int(rect.height), Int(pixels.width), Int(pixels.height)
              )
            : String(
                format: L10n("Too small — at least %d × %d pt"),
                Int(ScreenRecordingCoordinateMapper.minimumRegionSide),
                Int(ScreenRecordingCoordinateMapper.minimumRegionSide)
              )
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: usable ? NSColor.white : NSColor.systemOrange,
        ]
        let size = text.size(withAttributes: attributes)
        let origin = NSPoint(
            x: rect.midX - size.width / 2,
            y: max(rect.minY - size.height - 6, 6)
        )
        let background = NSRect(origin: origin, size: size).insetBy(dx: -6, dy: -3)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: background, xRadius: 4, yRadius: 4).fill()
        text.draw(at: origin, withAttributes: attributes)
    }

    // MARK: 手势

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // 双击框内直接确认（计划 §6.2-5）。
        if event.clickCount >= 2, selection.contains(point) { confirm(); return }

        if let handle = Handle.allCases.first(where: {
            handleRect($0).insetBy(dx: -6, dy: -6).contains(point)
        }) {
            drag = .resizing(handle: handle, fixed: fixedPoint(for: handle))
        } else if selection.contains(point) {
            drag = .moving(grabOffset: CGSize(
                width: point.x - selection.minX, height: point.y - selection.minY
            ))
        } else {
            drag = .drawing(anchor: point)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch drag {
        case .drawing(let anchor):
            // 夹的是**拖动点**，锚点不动、比例天然保持（复审三 P2）。
            selection = ScreenRecordingCoordinateMapper.regionRect(
                anchor: anchor, current: point, ratio: ratio.value, bounds: bounds
            )
        case .moving(let grabOffset):
            // 整体平移，尺寸不变，推回屏内。
            let x = min(max(point.x - grabOffset.width, bounds.minX), bounds.maxX - selection.width)
            let y = min(max(point.y - grabOffset.height, bounds.minY), bounds.maxY - selection.height)
            selection.origin = CGPoint(x: x, y: y)
        case .resizing(let handle, let fixed):
            selection = resized(handle: handle, fixed: fixed, to: point)
        case nil:
            return
        }
        layoutButtons()
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        drag = nil
        layoutButtons()
        needsDisplay = true
    }

    /// 把手缩放。边把手只改一个方向；固定比例档一律走 `regionRect` 保持比例。
    private func resized(handle: Handle, fixed: CGPoint, to point: CGPoint) -> NSRect {
        var target = point
        switch handle {
        case .left, .right:
            // 只改宽：高度维持（自由档）；固定比例档由 regionRect 重算高度。
            if ratio.value == nil { target.y = fixed.y == selection.minY
                ? selection.maxY : selection.minY }
        case .top, .bottom:
            if ratio.value == nil { target.x = fixed.x == selection.minX
                ? selection.maxX : selection.minX }
        default:
            break
        }
        return ScreenRecordingCoordinateMapper.regionRect(
            anchor: fixed, current: target, ratio: ratio.value, bounds: bounds
        )
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onFinish(nil)          // Escape
        case 36, 76: confirm()          // Return / Enter
        default: super.keyDown(with: event)
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(selection, cursor: .openHand)
        for handle in Handle.allCases {
            addCursorRect(handleRect(handle).insetBy(dx: -6, dy: -6), cursor: .crosshair)
        }
    }

    // MARK: 计算

    private var displayGeometry: ScreenRecordingCoordinateMapper.DisplayGeometry {
        let id = displayID
        let mode = CGDisplayCopyDisplayMode(id)
        return .init(
            boundsInPoints: CGDisplayBounds(id),
            // 真实像素只有 pixelWidth 给（`CGDisplayPixelsWide` 返回的是点）——
            // 用点配置捕获会在 Retina 上录成半分辨率糊图（Phase 0 门槛 10）。
            pixelSize: CGSize(
                width: mode?.pixelWidth ?? CGDisplayPixelsWide(id),
                height: mode?.pixelHeight ?? CGDisplayPixelsHigh(id)
            )
        )
    }

    private var displayID: CGDirectDisplayID {
        (screenRef.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
            .uint32Value ?? CGMainDisplayID()
    }

    private func confirm() {
        let rect = selection
        guard ScreenRecordingCoordinateMapper.isUsableRegion(rect) else { return }
        // 视图坐标 → AppKit 全局 → display-local
        let globalAppKit = NSRect(
            x: screenRef.frame.minX + rect.minX,
            y: screenRef.frame.minY + rect.minY,
            width: rect.width, height: rect.height
        )
        let mainHeight = NSScreen.screens.first { $0.frame.origin == .zero }?.frame.height
            ?? NSScreen.main?.frame.height ?? 0
        // `SCStreamConfiguration.sourceRect` 要的是 **display-local** 点坐标。
        // 直接给全局 CG 坐标只在主屏（原点为零）看起来是对的，副屏会整体偏移
        // 甚至越界（复审 P1-6）。
        guard let local = ScreenRecordingCoordinateMapper.displayLocalRect(
            fromAppKit: globalAppKit,
            display: displayGeometry,
            mainDisplayHeightInPoints: mainHeight
        ) else { return }
        onFinish(.init(displayID: displayID, rectInPoints: local))
    }
}
