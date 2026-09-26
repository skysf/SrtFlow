import AppKit
import SwiftUI
import os

// MARK: - 触控板捏合缩放时间线（外加右键按在哪）
//
// 从 `VideoEditTimelineView.swift` 拆出来（拆分前 2101 行，远超仓库约 800 行的
// 警戒线）。走 local event monitor 而不是视图命中，理由见下面那段注释和
// docs/architecture/timeline-pinch-zoom.md。
// 接线守卫 `checks/timeline-drag-wiring.sh` 按文件扫描，挪动这里的东西要同步改它。
//
// 这个监视器顺手记下**右键（或 ⌃ 点）按在时间线的哪儿**（`TimelineContextClick`）：右键菜单里的
// 「粘贴」要落在按下去的那一处，而菜单弹出来之后指针已经挪到菜单项上了。事件原样放行。

/// 触控板捏合缩放时间线。
///
/// 不能走视图命中：两指刚落上触控板时系统先发 scrollWheel(mayBegin) 决定这一轮
/// 手势序列的接收者，此后同序列的 magnify 事件不再重新 hitTest —— 时间线的
/// NSScrollView 把序列锁走，盖在上面的捕获层永远等不到捏合。所以这里用
/// local event monitor：事件进窗口分发**之前**就先看一眼，是捏合且光标在
/// 时间线视口内就缩放并吞掉；其余事件原样放行，点选、拖动、滚动零干扰。
/// 视图本身只当几何参照（hitTest 永远返回 nil）。
///
/// 缩放本身（改比例 / 行高、把指针底下那一处拉回原位）在 `TimelineZoom`；滚动视图从时间线自己的
/// `TimelineScrollGeometry` 拿。**别再按坐标 hitTest 去找滚动视图**：2026-09-26 之前就是那样找的，
/// 传进去的是翻转过的根视图坐标，找的是窗口里上下对称的那一处（预览区），一直找不到时间线 ——
/// 锚点那一步从来没生效（docs/bugfixes/2026-09-26-pinch-zoom-anchor-never-applied.md）。
struct TimelineMagnificationBridge: NSViewRepresentable {
    let project: VideoEditProject
    /// 时间线的滚动几何（持有不订阅）：锚点从它量、滚动由它推。
    let geometry: TimelineScrollGeometry

    func makeCoordinator() -> Coordinator {
        Coordinator(project: project, geometry: geometry)
    }

    func makeNSView(context: Context) -> TimelineZoomReferenceView {
        let view = TimelineZoomReferenceView()
        context.coordinator.referenceView = view
        context.coordinator.installMonitorIfNeeded()
        return view
    }

    func updateNSView(_ nsView: TimelineZoomReferenceView, context: Context) {
        PerfCounters.update(Self.self)
        context.coordinator.project = project
        context.coordinator.geometry = geometry
        context.coordinator.referenceView = nsView
    }

    static func dismantleNSView(_ nsView: TimelineZoomReferenceView, coordinator: Coordinator) {
        coordinator.tearDown()
    }

    @MainActor
    final class Coordinator: NSObject {
        var project: VideoEditProject
        var geometry: TimelineScrollGeometry
        weak var referenceView: TimelineZoomReferenceView?
        private var monitor: Any?
        /// 一轮捏合正在进行（从 began 到 ended）。
        private var isZooming = false
        /// 这一轮捏合是纵向的（起手时按着 ⌥）。**一轮里不换轴**：捏到一半松开 ⌥ 不会突然改成横向。
        private var zoomsVertically = false
        /// 这一轮捏合的锚点，起手时定死（指针在捏合中不动，定死也不会漂）。
        private var horizontalAnchor: TimelineZoom.HorizontalAnchor?
        private var verticalAnchor: TimelineZoom.VerticalAnchor?
        /// 诊断日志：`log stream --predicate 'category == "timeline-zoom"'`
        /// 能直接回答「捏合事件到底进没进 App」（ad-hoc 签名的拷贝 `log show` 查不到，只能 stream）。
        private static let log = Logger(subsystem: "com.srtflow.SrtFlow", category: "timeline-zoom")

        init(project: VideoEditProject, geometry: TimelineScrollGeometry) {
            self.project = project
            self.geometry = geometry
        }

        func installMonitorIfNeeded() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.magnify, .scrollWheel, .rightMouseDown, .leftMouseDown]
            ) { [weak self] event in
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
                return handleScrollWheel(event)
            case .rightMouseDown:
                if cursorInsideTimeline(event) { TimelineContextClick.note(event) }
                return event
            case .leftMouseDown:
                // ⌃ 点也会弹右键菜单。
                if event.modifierFlags.contains(.control), cursorInsideTimeline(event) {
                    TimelineContextClick.note(event)
                }
                return event
            default:
                return event
            }
        }

        /// Ctrl + 滚轮 = 横向缩放、⌥ + Ctrl + 滚轮 = 纵向缩放（没有触控板时的替代，也是自动化回归
        /// 唯一能注入的路径）。普通滚动原样放行。每一下都按此刻的指针取锚点。
        private func handleScrollWheel(_ event: NSEvent) -> NSEvent? {
            guard event.modifierFlags.contains(.control), cursorInsideTimeline(event) else { return event }
            let factor = exp(-Double(event.scrollingDeltaY) * 0.025)
            if event.modifierFlags.contains(.option) {
                let anchor = TimelineZoom.verticalAnchor(
                    pointerAt: event.locationInWindow, in: event.window, project: project, geometry: geometry
                )
                TimelineZoom.vertical(project, by: factor, around: anchor, geometry: geometry)
            } else {
                let anchor = TimelineZoom.pointerAnchor(
                    atWindowPoint: event.locationInWindow, in: event.window, project: project, geometry: geometry
                ) ?? .playheadOrCenter
                TimelineZoom.horizontal(project, to: project.pixelsPerSecond * factor, keeping: anchor, geometry: geometry)
            }
            return nil
        }

        private func handleMagnify(_ event: NSEvent) -> NSEvent? {
            // began 永远开新的一轮：上一轮的 ended 万一没来，也不会拿着上一轮的锚点接着缩。
            if !isZooming || event.phase == .began {
                let inside = cursorInsideTimeline(event)
                if event.phase == .began {
                    Self.log.log("magnify began, insideTimeline=\(inside), vertical=\(event.modifierFlags.contains(.option))")
                }
                guard inside else {
                    endZoom()
                    return event
                }
                beginZoom(event)
            }
            if event.phase == .ended || event.phase == .cancelled {
                Self.log.log("magnify ended at scale \(self.project.pixelsPerSecond)")
                endZoom()
                return nil
            }
            // NSEvent.magnification 是这一帧的增量，逐帧乘到当前比例 / 行高上才会平滑。
            let factor = 1 + Double(event.magnification)
            guard factor > 0 else { return nil }
            if zoomsVertically {
                TimelineZoom.vertical(project, by: factor, around: verticalAnchor, geometry: geometry)
            } else {
                TimelineZoom.horizontal(
                    project, to: project.pixelsPerSecond * factor,
                    keeping: horizontalAnchor ?? .playheadOrCenter, geometry: geometry
                )
            }
            return nil
        }

        /// 一轮捏合起手：定轴（按着 ⌥ = 纵向），记下指针底下那一处。
        private func beginZoom(_ event: NSEvent) {
            isZooming = true
            zoomsVertically = event.modifierFlags.contains(.option)
            horizontalAnchor = TimelineZoom.pointerAnchor(
                atWindowPoint: event.locationInWindow, in: event.window, project: project, geometry: geometry
            )
            verticalAnchor = TimelineZoom.verticalAnchor(
                pointerAt: event.locationInWindow, in: event.window, project: project, geometry: geometry
            )
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
            horizontalAnchor = nil
            verticalAnchor = nil
        }
    }
}

/// 只用来把「时间线视口」这块区域标定在 AppKit 坐标系里，事件一概不碰。
@MainActor
final class TimelineZoomReferenceView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
