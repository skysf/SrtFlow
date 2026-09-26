import Foundation

// MARK: - 缩放时哪一点不动（纯值）
//
// 管什么：缩放之后把「锚点」拉回视口里原来的位置要滚到哪 ——
// 横向：锚点那一刻回到视口里原来那个 x；工具栏缩放（按钮 / ⌘= ⌘- / 滑杆）的锚点是播放头，
// 播放头不在视口里就是视口正中那一刻；
// 纵向：锚点落在哪一行的哪一处，行高变了之后那一处回到视口里原来那个 y。
// 不管什么：改比例 / 行高、真的去推滚动（`TimelineZoom`、`TimelineScrollGeometry.keepAnchored`）。
//
// 2026-09-26 用户拍板：捏合放大「往两边延伸，延伸的点就是鼠标停留的点」；纵向另有一个整体缩放；
// 工具栏的放大缩小也不许一按画面就跳。纯值、不 import AppKit，自检编得动
// （`scripts/check-timeline-zoom.sh`）。长期约束见 docs/architecture/timeline-pinch-zoom.md。

enum TimelineZoomAnchor {

    // MARK: 横向

    /// 缩放之后，要让 `time` 这一刻仍在视口的 `viewportX` 处，横向滚动量该是多少。
    /// 不夹：夹进可滚范围是滚动几何的事（贴着 0 秒缩小时锚不住，只能贴左 —— 左边没有更早的时间）。
    static func offsetX(keeping time: Double, atViewportX viewportX: Double, pixelsPerSecond: Double) -> Double {
        time * pixelsPerSecond - viewportX
    }

    /// 视口里 `viewportX` 这一处此刻是第几秒。
    static func time(atViewportX viewportX: Double, offsetX: Double, pixelsPerSecond: Double) -> Double {
        max(0, (offsetX + viewportX) / max(pixelsPerSecond, 1))
    }

    /// 工具栏缩放的锚点：播放头在视口里（含两条边）就钉住播放头，不在就钉住视口正中那一刻。
    ///
    /// 不用鼠标：点按钮、拖滑杆时鼠标在工具栏上，和时间线上的哪一刻都没关系；按 ⌘= 时鼠标可能
    /// 碰巧停在时间线上，但用户看的是播放头 —— 和 FCP / Premiere 的键盘缩放同一个口径。
    static func toolbarAnchor(
        playhead: Double, offsetX: Double, viewportWidth: Double, pixelsPerSecond: Double
    ) -> (time: Double, viewportX: Double) {
        let x = playhead * pixelsPerSecond - offsetX
        if x >= 0, x <= viewportWidth { return (playhead, x) }
        let center = viewportWidth / 2
        return (time(atViewportX: center, offsetX: offsetX, pixelsPerSecond: pixelsPerSecond), center)
    }

    // MARK: 纵向

    /// 一行在滚动内容里的上下沿（`TimelineRowLayout` 的纯值版，按行的 id 对上号）。
    struct RowSpan: Equatable {
        var id: String
        var minY: Double
        var maxY: Double
    }

    /// 锚点在排布里的「身份」：哪一行、在行里的第几成（行高变了按比例跟着走），或者在这一行下沿
    /// 往下多远（行和行之间的缝、最后一行下面的空白，缝不跟着行高缩放）。
    struct RowPoint: Equatable {
        var rowID: String
        var fraction: Double?
        var belowBottom: Double
    }

    /// 内容 y 落在排布的哪儿：在某一行里 → 行内的比例；在两行之间或最后一行下面 → 上面那一行
    /// 下沿往下多远；比第一行还高（顶上那点留白）→ 算第一行的负比例。空排布是 nil。
    static func rowPoint(at y: Double, in rows: [RowSpan]) -> RowPoint? {
        guard let first = rows.first else { return nil }
        guard let row = rows.last(where: { $0.minY <= y }) else {
            let height = first.maxY - first.minY
            return RowPoint(rowID: first.id, fraction: height > 0 ? (y - first.minY) / height : 0, belowBottom: 0)
        }
        let height = row.maxY - row.minY
        if y <= row.maxY, height > 0 {
            return RowPoint(rowID: row.id, fraction: (y - row.minY) / height, belowBottom: 0)
        }
        return RowPoint(rowID: row.id, fraction: nil, belowBottom: y - row.maxY)
    }

    /// 同一个锚点在另一份排布里的内容 y。锚点那一行不在了（极少：缩放途中轨被删）就是 nil。
    static func contentY(of point: RowPoint, in rows: [RowSpan]) -> Double? {
        guard let row = rows.first(where: { $0.id == point.rowID }) else { return nil }
        if let fraction = point.fraction {
            return row.minY + fraction * (row.maxY - row.minY)
        }
        return row.maxY + point.belowBottom
    }
}
