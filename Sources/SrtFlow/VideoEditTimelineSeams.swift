import Foundation

// MARK: - 插入缝：在两条轨之间新开一条轨（纯值）
//
// 2026-09-24 产品决策（docs/plans/2026-09-24-track-insert-and-reorder.md）：拖着素材在
// 两条轨之间的缝上停一下，上下两边的轨拉开一条窄缝，松手就在这儿新开一条轨；不松手移开，
// 缝又合上。
//
// **为什么是纯值、为什么只能有一份**：缝在哪、指针算不算在缝上、缝拉开之后每一行挪到哪 ——
// 画落点框、命中判定、轨道头列三处都要用。各算一份的话，框画在缝里、素材落到别的轨上，
// 或者轨道头和轨道行错开一个缝宽。这个文件不 import SwiftUI / AppKit，自检编得动它
// （`scripts/check-timeline-snap.sh`）。视图侧的接线（停顿计时、拉开动画、缝里那条线）在
// `VideoEditTimelineInsertGap.swift`；长期约束见 docs/architecture/timeline-drag-gestures.md §5h。

/// 时间线行的纵向排布常量。轨道行（`VideoEditTimelineView.scrolledContent`）和轨道头列
/// （`TimelineHeaderColumn`）都按它排 —— 两边各写一份字面量，缝一拉开就对不齐。
enum TimelineRowMetrics {
    /// 行与行之间的缝（VStack 的 spacing）。
    static let spacing = 5.0
    /// 第一行上方留的边（VStack 的 `.padding(.vertical, …)`）。
    static let inset = 2.0
}

/// 一条插入缝：松手会在哪一类轨的第几个位置新开一条轨。
///
/// 编号 = 新轨插进去之后在数组里的下标（同 `TrackDropTarget.insertOverlay(at:)`）。
/// 上层视频轨的行是编号大的在上面，所以 `.overlay(k)` 这条缝夹在上层轨 k（上）和
/// k-1（下）之间；音频轨按编号往下排，`.audio(k)` 夹在音频轨 k-1（上）和 k（下）之间。
enum TimelineSeam: Hashable, Sendable {
    case overlay(Int)
    case audio(Int)

    var isAudio: Bool {
        if case .audio = self { return true }
        return false
    }

    /// 松手之后的落点。
    var target: TrackDropTarget {
        switch self {
        case .overlay(let index): return .insertOverlay(at: index)
        case .audio(let index): return .insertAudio(at: index)
        }
    }
}

enum TimelineSeams {

    /// 缝拉开时多出来的高度：5pt 的缝拉到 28pt，刚好放下 22pt 的缩略落点框（上下各留 3pt）。
    /// **窄缝**是用户选的（方案第二节）：下面的轨只挪二十来个点，不整条轨高地往下推。
    static let gapExtra = 23.0
    /// 缝里那个缩略落点框的高度（和原来「骑在插入线上」的新轨框同一个尺寸）。
    static let ghostHeight = 22.0
    /// 缝的判定区往上下两条轨里各伸进去多少。行的中间大部分仍然是「放进这条轨」。
    static let reach = 8.0
    /// 已经拉开的缝要再多离开这么远才合上：指针停在边上时不至于一开一合。
    static let openSlack = 4.0
    /// 在缝上停多久才拉开（用户拍板 0.2 秒：挪到隔壁轨时路过缝不该触发）。
    static let dwellMilliseconds = 200

    /// 拉开之后这条缝有多高。
    static var gapHeight: Double { TimelineRowMetrics.spacing + gapExtra }

    /// 排布用的一行。
    struct Row: Equatable, Sendable {
        var slot: TrackSlot?
        var height: Double
        /// 标尺和滤镜行：它们摆在所有轨道行的上面。一条上层轨都没有时，新的上层轨就长在
        /// 它们下面（`VideoEditTimelineView.rows` 的顺序）。
        var sitsAboveTracks: Bool = false

        init(slot: TrackSlot?, height: Double, sitsAboveTracks: Bool = false) {
            self.slot = slot
            self.height = height
            self.sitsAboveTracks = sitsAboveTracks
        }
    }

    /// 一行排出来的纵向范围（滚动内容坐标）。
    struct Span: Equatable, Sendable {
        var minY: Double
        var maxY: Double
        var midY: Double { (minY + maxY) / 2 }
    }

    /// 一条缝在哪（关着时）。
    struct Spot: Equatable, Sendable {
        var seam: TimelineSeam
        /// 缝下面那一行的下标（`rows.count` = 缝在最后一行下面）。缝拉开 = 给这一行上面垫一段。
        var rowBelow: Int
        /// 缝的中线。
        var line: Double
        /// 判定区向上 / 向下没有边：最上面那条视频缝、最下面那条音频缝
        /// （拖素材块时，原来「拖出最上面 = 顶上新开一条」「拖出最下面 = 底下新开一条」）。
        var endsAbove: Bool
        var endsBelow: Bool
    }

    // MARK: - 排布

    /// 每一行排在哪。`gapBefore` = 在第几行上面拉开缝（`rows.count` = 在最后一行下面），
    /// nil = 没有缝。和 `VideoEditTimelineView` 里 VStack 的排法一一对应：第一行上方
    /// `inset`、行与行之间 `spacing`、缝下面那一行多垫 `gapExtra`。
    static func layout(_ rows: [Row], gapBefore: Int? = nil) -> [Span] {
        var y = TimelineRowMetrics.inset
        var spans: [Span] = []
        spans.reserveCapacity(rows.count)
        for (index, row) in rows.enumerated() {
            if index == gapBefore { y += gapExtra }
            spans.append(Span(minY: y, maxY: y + row.height))
            y += row.height + TimelineRowMetrics.spacing
        }
        return spans
    }

    /// 这条缝拉开时垫在第几行上面。缝不存在（轨已经变了）返回 nil。
    static func gapBefore(_ seam: TimelineSeam, in rows: [Row]) -> Int? {
        spots(audio: seam.isAudio, rows: rows).first { $0.seam == seam }?.rowBelow
    }

    /// 拉开的缝的上沿和下沿（滚动内容坐标）。缝上面那一行不动，所以上沿就是它的下沿。
    static func openGap(_ seam: TimelineSeam, rows: [Row]) -> (top: Double, bottom: Double)? {
        guard let below = gapBefore(seam, in: rows) else { return nil }
        let spans = layout(rows)
        let top = below > 0 ? spans[below - 1].maxY : 0
        return (top, top + gapHeight)
    }

    /// 缝里的缩略落点框画在哪（拉开的缝正中）。
    static func ghostY(gapTop: Double) -> Double {
        gapTop + (gapHeight - ghostHeight) / 2
    }

    // MARK: - 缝在哪

    /// 某一类轨的全部插入缝（关着时的位置），从上到下。
    ///
    /// - 视频：最上面那条上层轨的上方、上层轨之间、最下面那条上层轨的下方。**主轨下面
    ///   没有缝**（用户拍板：主轨永远是最底层画面）。文字 / 形状行夹在上层轨和主轨之间时，
    ///   「最低一层」那条缝开在它们上面 —— 新轨实际长在那儿。
    /// - 音频：第一条音频轨的上方、音频轨之间、最后一条的下方。
    static func spots(audio: Bool, rows: [Row]) -> [Spot] {
        let spans = layout(rows)
        let half = TimelineRowMetrics.spacing / 2
        /// 第 `row` 行上方那条缝的中线（`row == rows.count` = 最后一行下方）。
        func line(above row: Int) -> Double {
            if row < spans.count { return spans[row].minY - half }
            return (spans.last?.maxY ?? TimelineRowMetrics.inset) + half
        }

        if audio {
            let lanes = rows.indices
                .compactMap { index -> (lane: Int, row: Int)? in
                    if case .audio(let lane) = rows[index].slot { return (lane, index) }
                    return nil
                }
                .sorted { $0.lane < $1.lane }
            var result = lanes.enumerated().map { k, entry in
                Spot(seam: .audio(k), rowBelow: entry.row, line: line(above: entry.row),
                     endsAbove: false, endsBelow: false)
            }
            let end = lanes.last.map { $0.row + 1 } ?? rows.count
            result.append(Spot(seam: .audio(lanes.count), rowBelow: end, line: line(above: end),
                               endsAbove: false, endsBelow: true))
            return result
        }

        let lanes = rows.indices
            .compactMap { index -> (lane: Int, row: Int)? in
                if case .overlay(let lane) = rows[index].slot { return (lane, index) }
                return nil
            }
            .sorted { $0.lane < $1.lane }
        guard let top = lanes.last else {
            // 一条上层轨都没有：新轨长在标尺 / 滤镜行下面。
            let below = rows.firstIndex { !$0.sitsAboveTracks } ?? rows.count
            return [Spot(seam: .overlay(0), rowBelow: below, line: line(above: below),
                         endsAbove: true, endsBelow: false)]
        }
        var result = [Spot(seam: .overlay(lanes.count), rowBelow: top.row, line: line(above: top.row),
                           endsAbove: true, endsBelow: false)]
        // 从上往下：上层轨 k 的下方就是 `.overlay(k)` 这条缝。
        for entry in lanes.reversed() {
            let below = entry.row + 1
            result.append(Spot(seam: .overlay(entry.lane), rowBelow: below, line: line(above: below),
                               endsAbove: false, endsBelow: false))
        }
        return result
    }

    /// 拖这一段时哪几条缝等于「原地换一条新轨」：它的轨上只有它自己时，紧挨着这条轨的
    /// 上下两条缝。落进去的结果是轨的顺序一点没变，却换了一条新轨 —— 调过的行高没了，
    /// 颜色也可能变。所以这两条缝不开（方案第二节）。主轨永远不会被清掉，不受这条限制。
    static func noOpSeams(draggingClip id: UUID, in state: TimelineState) -> Set<TimelineSeam> {
        guard let location = state.location(of: id) else { return [] }
        switch location.track {
        case .overlay(let lane):
            guard state.overlayTracks.indices.contains(lane),
                  state.overlayTracks[lane].clips.count == 1 else { return [] }
            return [.overlay(lane), .overlay(lane + 1)]
        case .audio(let lane):
            guard state.audioTracks.indices.contains(lane),
                  state.audioTracks[lane].clips.count == 1 else { return [] }
            return [.audio(lane), .audio(lane + 1)]
        case .main:
            return []
        }
    }

    // MARK: - 指针在哪

    /// 指针压在哪。
    enum Aim: Equatable, Sendable {
        /// 在已经拉开的那条缝里：松手就在这儿新开一条轨。
        case inOpenGap(TimelineSeam)
        /// 不在拉开的缝里。关联值是它此刻压着哪条（关着的）缝的判定区 —— 停够时间就拉开；
        /// nil = 不在任何缝上。
        case near(TimelineSeam?)
    }

    /// 指针此刻压在哪条缝上。
    ///
    /// - `y`：指针的滚动内容 y，按**此刻画出来的**排布（缝开着就是拉开之后的）。
    /// - `open`：此刻拉开的那条缝。
    /// - `candidates`：这一轮认哪些缝（素材的类型；拖素材块时还要排除原地的那两条）。
    /// - `openEnds`：最上 / 最下那两条缝的判定区要不要一直延伸出去。拖素材块要（原来
    ///   就是「拖出最上面 = 顶上新开一条」）；拖文件 / 音频库不要（标尺和滤镜行上仍按
    ///   默认轨落，不借这次改掉原来的落点）。
    ///
    /// 不在拉开的缝里时按**关着时**的排布判：指针的内容 y 没变，变的是它底下的行 ——
    /// 缝一合上，缝下面的行往上挪回来，这里算的就是「合上之后指针压在哪」。
    static func aim(
        y: Double,
        rows: [Row],
        open: TimelineSeam?,
        candidates: [TimelineSeam],
        openEnds: Bool
    ) -> Aim {
        let allowed = (spots(audio: false, rows: rows) + spots(audio: true, rows: rows))
            .filter { candidates.contains($0.seam) }
        if let open, let spot = allowed.first(where: { $0.seam == open }),
           let gap = openGap(open, rows: rows) {
            let low = openEnds && spot.endsAbove ? -Double.infinity : gap.top - reach - openSlack
            let high = openEnds && spot.endsBelow ? Double.infinity : gap.bottom + reach + openSlack
            if y >= low, y <= high { return .inOpenGap(open) }
        }
        let half = TimelineRowMetrics.spacing / 2
        for spot in allowed {
            let low = openEnds && spot.endsAbove ? -Double.infinity : spot.line - half - reach
            let high = openEnds && spot.endsBelow ? Double.infinity : spot.line + half + reach
            if y >= low, y <= high { return .near(spot.seam) }
        }
        return .near(nil)
    }

    /// 离指针最近的同类轨（按中线，关着缝时的排布）。返回行的下标；一条同类轨都没有返回 nil。
    ///
    /// 这是缝还没拉开时的落点：和原来的跨轨拖动同一条规则（同类行里挑离指尖最近的）。
    static func nearestTrackRow(y: Double, rows: [Row], audio: Bool) -> Int? {
        let spans = layout(rows)
        return rows.indices
            .filter { index in
                switch rows[index].slot {
                case .audio: return audio
                case .main, .overlay: return !audio
                case nil: return false
                }
            }
            .min { abs(spans[$0].midY - y) < abs(spans[$1].midY - y) }
    }
}
