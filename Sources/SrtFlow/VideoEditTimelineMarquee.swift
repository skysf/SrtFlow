import CoreGraphics
import Foundation

// MARK: - 鼠标框选的命中判定
//
// 纯值函数，不碰 AppKit / SwiftUI —— 和吸附一样编进自检
// （scripts/check-timeline-snap.sh）。别把它挪回 `VideoEditTimelineView.swift`：
// 那个文件拖着整个 App，一挪自检就编不动了。
//
// 长期约束见 docs/architecture/timeline-drag-gestures.md 的「框选」一节。

enum TimelineMarquee {

    /// 块画出来的最小宽度（视图点）。判定用的矩形必须和**画出来的**矩形一致：
    /// 一段 0.05 秒的素材在默认缩放下只有 1 个点宽，按真实时长判定的话，用户
    /// 明明把框拉过了那个可见的小方块，却什么都没选中。
    ///
    /// 这两个常量是「画」和「判」的共同事实来源 —— `ClipBlockView`、字幕行和
    /// 这里都读它，别在任何一边再写一个字面量。
    static let clipMinimumWidth: Double = 6
    static let shapeMinimumWidth: Double = 24
    static let cueMinimumWidth: Double = 2

    /// 框里能选中的三类东西。
    enum Kind: Equatable {
        case clip
        case shape
        case subtitleCue
    }

    /// 一行里的一个可选中元素。
    struct Item: Equatable {
        var id: UUID
        /// 时间线上的起止（秒）。
        var start: Double
        var end: Double
        var kind: Kind
        /// 这一类块画出来的最小宽度（视图点）。
        var minimumWidth: Double

        init(id: UUID, start: Double, end: Double, kind: Kind) {
            self.id = id
            self.start = start
            self.end = end
            self.kind = kind
            switch kind {
            case .clip: self.minimumWidth = TimelineMarquee.clipMinimumWidth
            case .shape: self.minimumWidth = TimelineMarquee.shapeMinimumWidth
            case .subtitleCue: self.minimumWidth = TimelineMarquee.cueMinimumWidth
            }
        }
    }

    /// 时间线上的一行。`minY/maxY` 是它在**滚动内容**里的纵向区间。
    struct Row: Equatable {
        var minY: Double
        var maxY: Double
        /// 整轨隐藏中：灰显、点不动，框选同样跳过它。轨道上看不见的东西被框走、
        /// 跟着一起被拖被删，是纯粹的惊吓。
        var isHidden: Bool
        var items: [Item]

        init(minY: Double, maxY: Double, isHidden: Bool = false, items: [Item]) {
            self.minY = minY
            self.maxY = maxY
            self.isHidden = isHidden
            self.items = items
        }
    }

    /// 一次框选的结果。
    struct Hit: Equatable {
        var clips: Set<UUID> = []
        var shapes: Set<UUID> = []
        var cues: Set<UUID> = []

        var isEmpty: Bool { clips.isEmpty && shapes.isEmpty && cues.isEmpty }

        /// 加选（⌘/⇧ 拖框）：在原有选择上并集。
        func union(_ other: Hit) -> Hit {
            Hit(
                clips: clips.union(other.clips),
                shapes: shapes.union(other.shapes),
                cues: cues.union(other.cues)
            )
        }
    }

    /// 拉框的一轮会话。
    ///
    /// 锚点存**滚动内容**的坐标（起手时的视口 x + 当时的滚动量），所以拖到视口
    /// 边缘自动滚动时，框会跟着内容一起长出去 —— 存视口坐标的话，内容在框底下
    /// 被抽走，框住的东西会莫名其妙地变。
    ///
    /// `hit` 是这一拍框中的东西（加选时已经并上起手前的选择）。整轮拖框只有它
    /// 在变，`VideoEditProject` 一个字都不写 —— 每一拍写选择会连带整个编辑器
    /// 视图树重建、重挂一次自动保存，框就跟不上光标了（和拖块同一条约束）。
    struct Session: Equatable {
        /// 内容坐标里的锚点。
        var anchor: CGPoint
        /// 内容坐标里的当前点。
        var current: CGPoint
        /// ⌘/⇧ 拖框 = 在原有选择上加选。起手时定死，中途松开修饰键不改语义。
        var additive: Bool
        /// 起手前已有的选择（加选才用得上）。
        var base: Hit
        /// 这一拍的选中结果。
        var hit: Hit

        init(anchor: CGPoint, additive: Bool, base: Hit) {
            self.anchor = anchor
            self.current = anchor
            self.additive = additive
            self.base = additive ? base : Hit()
            self.hit = self.base
        }

        var rect: CGRect {
            CGRect(
                x: min(anchor.x, current.x),
                y: min(anchor.y, current.y),
                width: abs(current.x - anchor.x),
                height: abs(current.y - anchor.y)
            )
        }

        mutating func update(current: CGPoint, rows: [Row], pixelsPerSecond: Double) {
            self.current = current
            let inside = TimelineMarquee.hits(rect: rect, rows: rows, pixelsPerSecond: pixelsPerSecond)
            hit = additive ? base.union(inside) : inside
        }
    }

    /// 框和元素**相交即选中**（Final Cut / Premiere / 访达都是这个语义）。
    ///
    /// 要求整个框住的话，时间线放大之后选一段长素材得把框拖出好几屏 —— 横着
    /// 扫一条细线就能选一排，才是这个手势该有的手感。
    ///
    /// `rect` 用**滚动内容**的坐标（左上原点，x 已经换算成点）。判定按闭区间：
    /// 边缘正好压上也算中，否则「框的右边缘贴着块的左边缘」这种像素级的边界
    /// 会让选中结果在同一个位置抖动。
    static func hits(rect: CGRect, rows: [Row], pixelsPerSecond: Double) -> Hit {
        var hit = Hit()
        let pps = max(pixelsPerSecond, 1)
        let minX = min(rect.minX, rect.maxX)
        let maxX = max(rect.minX, rect.maxX)
        let minY = min(rect.minY, rect.maxY)
        let maxY = max(rect.minY, rect.maxY)

        for row in rows where !row.isHidden {
            guard maxY >= row.minY, minY <= row.maxY else { continue }
            for item in row.items {
                let x0 = item.start * pps
                let x1 = max(item.end * pps, x0 + item.minimumWidth)
                guard maxX >= x0, minX <= x1 else { continue }
                switch item.kind {
                case .clip: hit.clips.insert(item.id)
                case .shape: hit.shapes.insert(item.id)
                case .subtitleCue: hit.cues.insert(item.id)
                }
            }
        }
        return hit
    }
}
