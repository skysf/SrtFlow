import Foundation

// MARK: - 整条轨换位置（纯值）
//
// 2026-09-24 产品决策（docs/plans/2026-09-24-track-insert-and-reorder.md）：按住轨道头
// 上下拖，整条轨跟着指针走，其余轨实时滑开让位，松手就换到那个位置（学 Logic）。
// 上层视频轨只在上层视频轨之间挪，音频轨只在音频轨之间挪；主轨固定在最底下。
//
// 这个文件是纯值（不 import SwiftUI / AppKit），自检编得动它（`scripts/check-timeline-snap.sh`）：
// 「落到第几个位置、其余每一行让多少」拖动中画出来和松手落地必须是同一份算法 ——
// 各算一份的话，画面上看着排在第二、松手却落到第三。手势接线在
// `VideoEditTimelineLaneReorder.swift`，长期约束见 docs/architecture/timeline-drag-gestures.md §5i。

/// 能整条换位置的一类轨。
enum TimelineLaneGroup: Hashable, Sendable {
    /// 上层视频轨：行是编号大的在上面（行的上下顺序就是画面的叠放顺序）。
    case overlay
    /// 音频轨：行按编号往下排。
    case audio

    /// 这一行属于哪一组；主轨和非轨道行返回 nil（主轨永远是最底层画面，不参与换位）。
    init?(_ slot: TrackSlot?) {
        switch slot {
        case .overlay: self = .overlay
        case .audio: self = .audio
        case .main, nil: return nil
        }
    }

    /// 显示顺序（从上往下第几行）↔ 数组下标。上层轨的行是倒着排的。
    func arrayIndex(displayIndex: Int, count: Int) -> Int {
        switch self {
        case .overlay: return count - 1 - displayIndex
        case .audio: return displayIndex
        }
    }
}

extension TimelineState {

    /// 把一条轨挪到这一组的第 `to` 个位置（数组下标，挪完之后的）。
    ///
    /// 挪的是整条 `EditLane`：颜色、推子、隐藏状态都在它身上，行高按它的身份记
    /// （`TimelineRowHeights`）—— 全都跟着轨走，一个都不用另外搬。
    /// 上层轨的数组顺序就是叠放顺序，所以挪完画面的叠放立刻变（调用方的 `perform`
    /// 会重建预览）；音频轨只是排列变了，混音是加法，声音不变。
    mutating func moveLane(_ group: TimelineLaneGroup, from: Int, to: Int) {
        switch group {
        case .overlay: overlayTracks = Self.moving(overlayTracks, from: from, to: to)
        case .audio: audioTracks = Self.moving(audioTracks, from: from, to: to)
        }
    }

    private static func moving(_ lanes: [EditLane], from: Int, to: Int) -> [EditLane] {
        guard lanes.indices.contains(from) else { return lanes }
        var lanes = lanes
        let lane = lanes.remove(at: from)
        lanes.insert(lane, at: min(max(0, to), lanes.count))
        return lanes
    }
}

/// 拖着一条轨上下走时：它落到这一组的第几个位置、其余每一行让多少。
enum TimelineLaneReorder {

    struct Resolution: Equatable, Sendable {
        /// 松手之后被拖的那一行在这一组里的显示下标（从上往下）。
        var destination: Int
        /// 被拖那一行的位移：跟着指针，夹在这一组的上下沿之间。
        var draggedOffset: Double
        /// 每一行的位移（显示顺序）。被拖那一行在这里是 0 —— 它的位移看 `draggedOffset`。
        var offsets: [Double]
    }

    /// - `heights`：这一组每一行的高度，显示顺序（从上往下），行与行之间隔 `TimelineRowMetrics.spacing`。
    /// - `dragged`：被拖的是第几行。
    /// - `offset`：指针带着它走了多远（内容坐标，含纵向自动滚动推走的那段）。
    ///
    /// 规则：被拖那一行的中线越过邻居的中线就和它换位；越过去的那些行整体让开「被拖那一行
    /// 的高度 + 行距」，于是让出来的空位正好是被拖那一行的大小（各行高度不同也成立）。
    /// 被拖的那一行夹在这一组的上下沿之间：不会盖到主轨、字幕、标尺这些不属于这一组的行上。
    static func resolve(heights: [Double], dragged: Int, offset: Double) -> Resolution {
        guard heights.indices.contains(dragged) else {
            return Resolution(destination: max(0, dragged), draggedOffset: 0, offsets: heights.map { _ in 0 })
        }
        let spacing = TimelineRowMetrics.spacing
        var tops: [Double] = []
        var y = 0.0
        for height in heights {
            tops.append(y)
            y += height + spacing
        }
        let bottom = (tops.last ?? 0) + (heights.last ?? 0)
        let clamped = min(max(offset, -tops[dragged]), bottom - tops[dragged] - heights[dragged])
        let center = tops[dragged] + heights[dragged] / 2 + clamped
        // 原来在上面的行：中线在被拖那一行中线**之上**才算还在上面；原来在下面的行：中线
        // 被追平就算已经被越过。两边各让一个等号，拖到最顶 / 最底时（夹紧之后两条中线正好
        // 重合）才不会差一格。
        let destination = heights.indices.filter { index in
            guard index != dragged else { return false }
            let middle = tops[index] + heights[index] / 2
            return index < dragged ? middle < center : middle <= center
        }.count
        let shift = heights[dragged] + spacing
        let offsets = heights.indices.map { index -> Double in
            if index == dragged { return 0 }
            if dragged < index, index <= destination { return -shift }
            if destination <= index, index < dragged { return shift }
            return 0
        }
        return Resolution(destination: destination, draggedOffset: clamped, offsets: offsets)
    }
}
