import AppKit

// MARK: - 时间线缩放的入口（横向 + 纵向）
//
// 管什么：改比例（横向）/ 统一行高（纵向），**同一拍**把锚点拉回视口里原来的位置。
// 捏合、Ctrl + 滚轮、⌥ 捏合、⌥ + Ctrl + 滚轮、工具栏的放大缩小、⌘= ⌘-、缩放滑杆、⌘↑ ⌘↓ 全从这儿进。
// 不管什么：锚点的算术（`TimelineZoomAnchor`，纯值）、推滚动（`TimelineScrollGeometry.keepAnchored`）、
// 事件从哪来（捏合 / 滚轮在 `TimelineMagnificationBridge`，按键在 `VideoEditView.handleEvent`）。
//
// 2026-09-26 用户拍板（docs/plans/2026-09-26-timeline-clipboard-and-zoom.md）：
// - 捏合放大「往两边延伸，延伸的点就是鼠标停留的点」—— 指针底下那一刻不动；
// - 工具栏的放大缩小、⌘= ⌘-、滑杆 —— 播放头在视口里就钉住播放头，不在就钉住视口正中；
// - 纵向：按住 ⌥ 捏合（鼠标用 ⌥ + Ctrl + 滚轮，键盘 ⌘↓ 放大 / ⌘↑ 缩小，同 Logic），
//   视频轨和音频轨**全部统一成一个高度**（单独调过的作废），指针指着的那一处不动。

@MainActor
enum TimelineZoom {

    // MARK: 横向

    /// 横向缩放的锚点。
    enum HorizontalAnchor {
        /// 这一刻钉在视口的这个 x 上（捏合、Ctrl + 滚轮：指针底下那一刻）。
        case fixed(time: Double, viewportX: Double)
        /// 工具栏按钮、⌘= / ⌘-、滑杆：播放头在视口里钉播放头，不在就钉视口正中（`toolbarAnchor`）。
        case playheadOrCenter
    }

    /// 横向缩放到 `scale`（点/秒），锚点不动。写入只走 `setPixelsPerSecond`（夹进 `zoomRange`）。
    ///
    /// 时间线不在屏幕上（切去别的栏目了）时照样改比例，只是没有东西可滚。
    static func horizontal(
        _ project: VideoEditProject,
        to scale: Double,
        keeping anchor: HorizontalAnchor,
        geometry explicitGeometry: TimelineScrollGeometry? = nil
    ) {
        let geometry = explicitGeometry ?? TimelineScrollGeometry.live
        let before = project.pixelsPerSecond
        let pinned: (time: Double, viewportX: Double)?
        switch anchor {
        case .fixed(let time, let viewportX):
            pinned = (time, viewportX)
        case .playheadOrCenter:
            pinned = geometry.map {
                TimelineZoomAnchor.toolbarAnchor(
                    playhead: project.clock.time, offsetX: $0.offsetX,
                    viewportWidth: Double($0.viewportSize.width), pixelsPerSecond: before
                )
            }
        }
        project.setPixelsPerSecond(scale)
        let after = project.pixelsPerSecond
        guard after != before, let geometry, let pinned else { return }
        geometry.keepAnchored(
            x: TimelineZoomAnchor.offsetX(keeping: pinned.time, atViewportX: pinned.viewportX, pixelsPerSecond: after),
            y: nil
        )
    }

    /// 指针底下那一刻（捏合起手、Ctrl + 滚轮每一下）。指针不在时间线的可见视口里是 nil。
    static func pointerAnchor(
        atWindowPoint point: NSPoint, in window: NSWindow?,
        project: VideoEditProject, geometry: TimelineScrollGeometry?
    ) -> HorizontalAnchor? {
        guard let location = geometry?.location(ofWindowPoint: point, in: window) else { return nil }
        let time = max(0, Double(location.content.x)) / max(project.pixelsPerSecond, 1)
        return .fixed(time: time, viewportX: Double(location.viewport.x))
    }

    // MARK: 纵向

    /// 纵向缩放的锚点：排布里的哪一处（`RowPoint`，按行认、不按 y 认）+ 它该待在视口的哪个 y。
    struct VerticalAnchor {
        var point: TimelineZoomAnchor.RowPoint
        var viewportY: Double
    }

    /// 纵向锚点：指针在时间线的可见视口里就是指针那一处，不在（或者没给指针）就是视口正中。
    static func verticalAnchor(
        pointerAt point: NSPoint?, in window: NSWindow?,
        project: VideoEditProject, geometry: TimelineScrollGeometry?
    ) -> VerticalAnchor? {
        guard let geometry else { return nil }
        let rows = spans(project)
        if let point, let location = geometry.location(ofWindowPoint: point, in: window),
           let rowPoint = TimelineZoomAnchor.rowPoint(at: Double(location.content.y), in: rows) {
            return VerticalAnchor(point: rowPoint, viewportY: Double(location.viewport.y))
        }
        let viewportY = Double(geometry.viewportSize.height) / 2
        guard let rowPoint = TimelineZoomAnchor.rowPoint(at: geometry.offsetY + viewportY, in: rows) else {
            return nil
        }
        return VerticalAnchor(point: rowPoint, viewportY: viewportY)
    }

    /// ⌘↓ ⌘↑ 用：鼠标此刻在时间线上就钉鼠标那一处，不在就钉视口正中。
    static func verticalAnchorAtMouse(
        project: VideoEditProject, geometry explicitGeometry: TimelineScrollGeometry? = nil
    ) -> VerticalAnchor? {
        let geometry = explicitGeometry ?? TimelineScrollGeometry.live
        let window = geometry?.window
        let point = window.map { $0.convertPoint(fromScreen: NSEvent.mouseLocation) }
        return verticalAnchor(pointerAt: point, in: window, project: project, geometry: geometry)
    }

    /// 纵向缩放：视频轨和音频轨统一成「锚点那一行现在的高度 × `factor`」（锚点不在视频 / 音频轨上就从
    /// 主轨的高度起算），单独调过的全部作废（`TimelineRowHeights.setUniform`）。锚点那一处不动。
    /// 字幕、文字、形状、滤镜那几条细行不变（它们的行高和块高是写死的一对，框选的命中靠那个差）。
    static func vertical(
        _ project: VideoEditProject,
        by factor: Double,
        around anchor: VerticalAnchor?,
        geometry explicitGeometry: TimelineScrollGeometry? = nil
    ) {
        let geometry = explicitGeometry ?? TimelineScrollGeometry.live
        guard factor.isFinite, factor > 0 else { return }
        let rows = TimelineRowList.rows(for: project)
        let adjustable = rows.filter { $0.heightKey != nil }
        let base = adjustable.first { $0.id == anchor?.point.rowID }?.height
            ?? adjustable.first { $0.slot == .main }?.height
            ?? adjustable.first?.height
        guard let base else { return }
        project.updateRowHeights { $0.setUniform(base * factor) }
        guard let geometry, let anchor,
              let y = TimelineZoomAnchor.contentY(of: anchor.point, in: spans(project)) else { return }
        geometry.keepAnchored(x: nil, y: y - anchor.viewportY)
    }

    /// ⌘↓ / ⌘↑ 一下乘除多少：从默认的视频轨高度（54）到上限 200 大约六下。
    static let verticalStep = 1.25

    /// 此刻的行排布（缝一律当关着：缩放和拖动不会同时发生）。
    private static func spans(_ project: VideoEditProject) -> [TimelineZoomAnchor.RowSpan] {
        VideoEditTimelineView.layouts(of: TimelineRowList.rows(for: project), open: nil).map {
            TimelineZoomAnchor.RowSpan(id: $0.spec.id, minY: $0.minY, maxY: $0.maxY)
        }
    }
}
