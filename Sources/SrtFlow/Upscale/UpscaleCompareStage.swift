import AVFoundation
import AppKit
import SwiftUI

// MARK: - 对比窗口的画面：两层播放器图层，分割线或并排，缩放和平移
//
// 管什么：原片和 upscale 文件各一个 AVPlayerLayer，按同一个矩形摆（`videoGravity = .resize`，两边的画面逐像素对齐），
// 分割线模式用一个 `masksToBounds` 的容器只露出原片的左边一截（和 CoverHostView 同一招）、并排模式左右各一半；
// 缩放：适合 / 100% / 200%（按 upscale 文件的像素），滚轮平移；点哪儿分割线到哪儿、也能拖。
// 不管什么：播放和同步（UpscaleComparePlayback）、按钮（UpscaleCompareView）。

enum UpscaleCompareMode: Equatable {
    case wipe
    case sideBySide
}

enum UpscaleCompareZoom: Equatable, CaseIterable {
    case fit
    case x1
    case x2

    var label: String {
        switch self {
        case .fit: return "Fit"
        case .x1: return "100%"
        case .x2: return "200%"
        }
    }
}

final class UpscaleCompareStageView: NSView {
    private let originalLayer = AVPlayerLayer()
    private let upscaledLayer = AVPlayerLayer()
    private let originalClip = CALayer()
    private let secondPane = CALayer()
    private let divider = CALayer()
    private let handle = CALayer()

    var mode = UpscaleCompareMode.wipe { didSet { needsLayout = true } }
    var zoom = UpscaleCompareZoom.fit { didSet { pan = .zero; needsLayout = true } }
    var wipe: CGFloat = 0.5 { didSet { needsLayout = true } }
    /// upscale 文件的像素尺寸（100% 按它算）。
    var videoSize = CGSize(width: 1920, height: 1080) { didSet { needsLayout = true } }
    var onWipe: ((CGFloat) -> Void)?
    private var pan = CGPoint.zero

    init(original: AVPlayer, upscaled: AVPlayer) {
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        originalLayer.player = original
        upscaledLayer.player = upscaled
        for playerLayer in [originalLayer, upscaledLayer] { playerLayer.videoGravity = .resize }
        originalClip.masksToBounds = true
        secondPane.masksToBounds = true
        originalClip.addSublayer(originalLayer)
        secondPane.addSublayer(upscaledLayer)
        layer?.addSublayer(secondPane)
        layer?.addSublayer(originalClip)
        divider.backgroundColor = NSColor.white.cgColor
        handle.backgroundColor = NSColor.white.cgColor
        handle.cornerRadius = 14
        layer?.addSublayer(divider)
        layer?.addSublayer(handle)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let bounds = self.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        switch mode {
        case .wipe:
            let frame = contentFrame(in: bounds)
            secondPane.frame = bounds
            upscaledLayer.frame = frame
            originalClip.frame = CGRect(x: 0, y: 0, width: bounds.width * wipe, height: bounds.height)
            originalLayer.frame = frame
            divider.isHidden = false
            handle.isHidden = false
            divider.frame = CGRect(x: bounds.width * wipe - 1, y: 0, width: 2, height: bounds.height)
            handle.frame = CGRect(x: bounds.width * wipe - 14, y: bounds.midY - 14, width: 28, height: 28)
        case .sideBySide:
            let half = CGRect(x: 0, y: 0, width: bounds.width / 2 - 2, height: bounds.height)
            let frame = contentFrame(in: half)
            originalClip.frame = half
            originalLayer.frame = frame
            secondPane.frame = CGRect(x: bounds.width / 2 + 2, y: 0, width: bounds.width / 2 - 2, height: bounds.height)
            upscaledLayer.frame = frame
            divider.isHidden = true
            handle.isHidden = true
        }
    }

    /// 画面放多大、放哪：适合 = 等比铺进去；100% / 200% = 按 upscale 文件的像素，居中再加平移。
    private func contentFrame(in box: CGRect) -> CGRect {
        let scale: CGFloat
        switch zoom {
        case .fit: scale = min(box.width / videoSize.width, box.height / videoSize.height)
        case .x1: scale = 1 / (window?.backingScaleFactor ?? 2)
        case .x2: scale = 2 / (window?.backingScaleFactor ?? 2)
        }
        let size = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
        return CGRect(x: (box.width - size.width) / 2 + pan.x, y: (box.height - size.height) / 2 + pan.y, width: size.width, height: size.height)
    }

    override func mouseDown(with event: NSEvent) { moveWipe(to: event) }
    override func mouseDragged(with event: NSEvent) { moveWipe(to: event) }

    private func moveWipe(to event: NSEvent) {
        guard mode == .wipe, bounds.width > 0 else { return }
        let x = convert(event.locationInWindow, from: nil).x
        let next = min(1, max(0, x / bounds.width))
        wipe = next
        onWipe?(next)
    }

    override func scrollWheel(with event: NSEvent) {
        guard zoom != .fit else { return }
        pan.x += event.scrollingDeltaX
        pan.y += event.scrollingDeltaY
        needsLayout = true
    }
}

struct UpscaleCompareStage: NSViewRepresentable {
    let playback: UpscaleComparePlayback
    let mode: UpscaleCompareMode
    let zoom: UpscaleCompareZoom
    let videoSize: CGSize
    @Binding var wipe: CGFloat

    func makeNSView(context: Context) -> UpscaleCompareStageView {
        let _ = PerfCounters.body(Self.self)
        let view = UpscaleCompareStageView(original: playback.original, upscaled: playback.upscaled)
        view.onWipe = { wipe = $0 }
        return view
    }

    func updateNSView(_ view: UpscaleCompareStageView, context: Context) {
        PerfCounters.update(Self.self)
        let _ = PerfCounters.body(Self.self)
        if view.mode != mode { view.mode = mode }
        if view.zoom != zoom { view.zoom = zoom }
        if abs(view.wipe - wipe) > 0.0001 { view.wipe = wipe }
        if view.videoSize != videoSize { view.videoSize = videoSize }
        view.onWipe = { wipe = $0 }
    }
}
