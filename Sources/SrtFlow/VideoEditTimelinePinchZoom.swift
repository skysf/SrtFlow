import AppKit
import SwiftUI
import os

// MARK: - 触控板捏合缩放时间线
//
// 从 `VideoEditTimelineView.swift` 拆出来（拆分前 2101 行，远超仓库约 800 行的
// 警戒线）。走 local event monitor 而不是视图命中，理由见下面那段注释和
// docs/architecture/timeline-pinch-zoom.md。
// 接线守卫 `checks/timeline-drag-wiring.sh` 按文件扫描，挪动这里的东西要同步改它。

/// 触控板捏合缩放时间线。
///
/// 不能走视图命中：两指刚落上触控板时系统先发 scrollWheel(mayBegin) 决定这一轮
/// 手势序列的接收者，此后同序列的 magnify 事件不再重新 hitTest —— 时间线的
/// NSScrollView 把序列锁走，盖在上面的捕获层永远等不到捏合。所以这里用
/// local event monitor：事件进窗口分发**之前**就先看一眼，是捏合且光标在
/// 时间线视口内就缩放并吞掉；其余事件原样放行，点选、拖动、滚动零干扰。
/// 视图本身只当几何参照（hitTest 永远返回 nil）。
struct TimelineMagnificationBridge: NSViewRepresentable {
    @Binding var pixelsPerSecond: Double

    func makeCoordinator() -> Coordinator {
        Coordinator(pixelsPerSecond: $pixelsPerSecond)
    }

    func makeNSView(context: Context) -> TimelineZoomReferenceView {
        let view = TimelineZoomReferenceView()
        context.coordinator.referenceView = view
        context.coordinator.installMonitorIfNeeded()
        return view
    }

    func updateNSView(_ nsView: TimelineZoomReferenceView, context: Context) {
        context.coordinator.pixelsPerSecond = $pixelsPerSecond
        context.coordinator.referenceView = nsView
    }

    static func dismantleNSView(_ nsView: TimelineZoomReferenceView, coordinator: Coordinator) {
        coordinator.tearDown()
    }

    @MainActor
    final class Coordinator: NSObject {
        var pixelsPerSecond: Binding<Double>
        weak var referenceView: TimelineZoomReferenceView?
        private var monitor: Any?
        private weak var timelineScrollView: NSScrollView?
        private var isZooming = false
        private var anchorTime: Double = 0
        private var anchorViewportX: Double = 0
        private var scrollCorrectionGeneration = 0
        /// 诊断日志：`log show --predicate 'subsystem == "com.srtflow.SrtFlow"'`
        /// 能直接回答「捏合事件到底进没进 App」。
        private static let log = Logger(subsystem: "com.srtflow.SrtFlow", category: "timeline-zoom")

        init(pixelsPerSecond: Binding<Double>) {
            self.pixelsPerSecond = pixelsPerSecond
        }

        func installMonitorIfNeeded() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.magnify, .scrollWheel]) { [weak self] event in
                guard let self else { return event }
                return MainActor.assumeIsolated { self.handle(event) }
            }
        }

        func tearDown() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            referenceView = nil
            endZoom()
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            switch event.type {
            case .magnify:
                return handleMagnify(event)
            case .scrollWheel:
                // Ctrl + 滚轮也缩放（无触控板时的替代），普通滚动原样放行。
                guard event.modifierFlags.contains(.control),
                      cursorInsideTimeline(event) else { return event }
                captureAnchor(atWindowPoint: event.locationInWindow)
                let factor = exp(-Double(event.scrollingDeltaY) * 0.025)
                setScale(pixelsPerSecond.wrappedValue * factor)
                timelineScrollView = nil
                return nil
            default:
                return event
            }
        }

        private func handleMagnify(_ event: NSEvent) -> NSEvent? {
            if !isZooming {
                let inside = cursorInsideTimeline(event)
                if event.phase == .began {
                    Self.log.log("magnify began, insideTimeline=\(inside)")
                }
                guard inside else { return event }
                isZooming = true
                captureAnchor(atWindowPoint: event.locationInWindow)
            }
            if event.phase == .ended || event.phase == .cancelled {
                Self.log.log("magnify ended at scale \(self.pixelsPerSecond.wrappedValue)")
                endZoom()
                return nil
            }
            // NSEvent.magnification 是这一帧的增量，逐帧乘到当前比例上才会平滑。
            let factor = 1 + Double(event.magnification)
            if factor > 0 {
                setScale(pixelsPerSecond.wrappedValue * factor)
            }
            return nil
        }

        /// 事件落在时间线的可见视口里吗？参照视图正好铺满那个视口。
        private func cursorInsideTimeline(_ event: NSEvent) -> Bool {
            guard let view = referenceView,
                  let window = view.window,
                  event.window === window else { return false }
            let point = view.convert(event.locationInWindow, from: nil)
            return view.bounds.contains(point)
        }

        func endZoom() {
            isZooming = false
            timelineScrollView = nil
        }

        /// 记住鼠标下的时刻和它在可见视口中的 x；每次缩放后把这个
        /// 时刻滚回同一个 x，就是录屏里 CapCut 的「指针下缩放」。
        private func captureAnchor(atWindowPoint pointInWindow: NSPoint) {
            guard let window = referenceView?.window,
                  let rootView = window.contentView else {
                timelineScrollView = nil
                return
            }
            let pointInRoot = rootView.convert(pointInWindow, from: nil)
            guard let scrollView = enclosingScrollView(at: pointInRoot, in: rootView),
                  let documentView = scrollView.documentView else {
                timelineScrollView = nil
                return
            }
            let clipView = scrollView.contentView
            let pointInClip = clipView.convert(pointInWindow, from: nil)
            let pointInDocument = documentView.convert(pointInWindow, from: nil)
            timelineScrollView = scrollView
            anchorViewportX = pointInClip.x - clipView.bounds.minX
            anchorTime = max(0, pointInDocument.x) / max(pixelsPerSecond.wrappedValue, 1)
        }

        private func enclosingScrollView(at point: NSPoint, in hostView: NSView) -> NSScrollView? {
            var view = hostView.hitTest(point)
            while let current = view {
                if let scrollView = current as? NSScrollView { return scrollView }
                view = current.superview
            }
            return nil
        }

        private func setScale(_ scale: Double) {
            guard scale.isFinite else { return }
            // 夹进和工具栏同一份区间：捏合以前只查 finite，能一路缩到 1 以下，
            // 那时块的位移换算被 max(pps, 1) 兜底，1:1 跟手就坏了。
            let clamped = min(
                max(scale, VideoEditProject.zoomRange.lowerBound),
                VideoEditProject.zoomRange.upperBound
            )
            guard clamped != pixelsPerSecond.wrappedValue else { return }
            pixelsPerSecond.wrappedValue = clamped
            keepAnchorFixed(atScale: clamped)
        }

        private func keepAnchorFixed(atScale scale: Double) {
            guard let scrollView = timelineScrollView else { return }
            scrollCorrectionGeneration += 1
            let generation = scrollCorrectionGeneration
            let time = anchorTime
            let viewportX = anchorViewportX

            // @Published 先让 SwiftUI 重排内容宽度，下一轮 main loop 再校正滚动量。
            DispatchQueue.main.async { [weak self, weak scrollView] in
                guard let self,
                      generation == self.scrollCorrectionGeneration,
                      let scrollView,
                      let documentView = scrollView.documentView else { return }
                let clipView = scrollView.contentView
                let minX = documentView.bounds.minX
                let maxX = max(minX, documentView.bounds.maxX - clipView.bounds.width)
                let proposed = time * scale - viewportX
                let x = min(max(proposed, minX), maxX)
                clipView.scroll(to: NSPoint(x: x, y: clipView.bounds.origin.y))
                scrollView.reflectScrolledClipView(clipView)
            }
        }

    }
}

/// 只用来把「时间线视口」这块区域标定在 AppKit 坐标系里，事件一概不碰。
@MainActor
final class TimelineZoomReferenceView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
