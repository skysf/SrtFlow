import AppKit

// MARK: - 指针落在时间线的哪一刻、哪一行
//
// 管什么：粘贴（⌘V、编辑菜单、右键菜单）要落在哪 —— 指针此刻（或右键按下的那一刻）在时间线的
// 轨道区里，就是指针底下那一刻、那一行；不在（在预览、检查器、菜单栏上，或者在标尺、轨道头那一列上）
// 就是 nil，由调用方退回播放头。
// 不管什么：落下去之后放在哪条轨、撞上了怎么办（`TimelinePaste`，纯值）。
//
// 2026-09-26 用户拍板：「粘贴的位置优先是鼠标停留的位置，如果没有鼠标在轨道上，就按照预览线停留的
// 位置」。「在轨道上」= 时间线滚动区里标尺以下的部分（含右边、下边撑出来的空白）；标尺和轨道头
// 那一列不算。和 FCP 的「有 skimmer 粘在 skimmer，没有粘在播放头」同一个意思。

/// 指针落在时间线的一刻、一行。
struct TimelinePointerHit {
    /// 指针底下那一刻（没夹到工程长度：粘到片尾后面的空白里就是那儿）。
    var time: Double
    /// 指针底下那一行；nil = 轨道区里的空白（行与行之间、最后一行下面）。
    var row: TimelineRowSpec?
}

@MainActor
enum TimelinePointer {
    /// 取哪一刻的指针。
    enum Source {
        /// 此刻（⌘V、编辑菜单）。点编辑菜单时指针在菜单栏上，自然就退回播放头。
        case now
        /// 右键 / ⌃ 点按下的那一刻（右键菜单里的「粘贴」：菜单弹出来后指针已经在菜单项上了）。
        case contextClick
    }

    static func hit(_ source: Source, project: VideoEditProject) -> TimelinePointerHit? {
        guard let geometry = TimelineScrollGeometry.live else { return nil }
        let window: NSWindow?
        let point: NSPoint
        switch source {
        case .now:
            guard let editor = geometry.window else { return nil }
            window = editor
            point = editor.convertPoint(fromScreen: NSEvent.mouseLocation)
        case .contextClick:
            guard let click = TimelineContextClick.last else { return nil }
            window = click.window
            point = click.point
        }
        guard let location = geometry.location(ofWindowPoint: point, in: window) else { return nil }
        let layouts = VideoEditTimelineView.layouts(of: TimelineRowList.rows(for: project), open: nil)
        // 标尺钉在视口顶上（它的排布就是视口里的位置）：落在它上面不算「在轨道上」。
        if let ruler = layouts.first(where: { $0.spec.isRuler }), Double(location.viewport.y) < ruler.maxY {
            return nil
        }
        let y = Double(location.content.y)
        let row = layouts.first { !$0.spec.isRuler && y >= $0.minY && y < $0.maxY }?.spec
        let time = max(0, Double(location.content.x)) / max(project.pixelsPerSecond, 1)
        return TimelinePointerHit(time: time, row: row)
    }
}

/// 右键（或 ⌃ 点）按在时间线的哪儿。由时间线的事件监视器（`TimelineMagnificationBridge`）记，
/// 右键菜单里的「粘贴」读。只记落在时间线视口里的那几下；落在别处的不覆盖它，但也用不上 ——
/// 右键菜单只长在时间线上。
@MainActor
enum TimelineContextClick {
    private static weak var window: NSWindow?
    private static var point = NSPoint.zero

    static var last: (window: NSWindow, point: NSPoint)? {
        window.map { ($0, point) }
    }

    static func note(_ event: NSEvent) {
        window = event.window
        point = event.locationInWindow
    }
}
