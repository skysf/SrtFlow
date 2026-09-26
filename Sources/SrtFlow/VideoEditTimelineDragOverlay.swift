import SwiftUI

// MARK: - 拖动中画在轨道行之上的几张覆盖层
//
// 管什么：一轮拖动 / 拉框进行中要画的东西 —— 对齐线、磁吸插空的占位框、跨轨的占位框、
// 目标轨的描边、文字换行的指示、框选的矩形。它 `@ObservedObject` 着 `TimelineDragBox`，拖动
// 每一拍只有它（和正在动的块）重算，时间线本体一个字都不读那个盒子（§0b）。
// 不管什么：这些东西的位置怎么算 —— 占位框的时刻和宽度来自 `ClipDragSession` /
// `TimelineState.crossTrackLandingSpan`（和落地同一份算法），行的位置来自传进来的
// `layouts`（`TimelineSeams.layout`，缝开着就是拉开之后的）。
//
// 输入里除了盒子全是值：时间线本体重算时（缝开合、工程变了）它跟着算一次，便宜。

struct TimelineDragOverlay: View {
    @ObservedObject var drag: TimelineDragBox
    /// 此刻画出来的排布（缝开着就是拉开之后的），和轨道行、命中判定同一份。
    let layouts: [TimelineRowLayout]
    /// 拉开的缝的上沿（内容坐标）；nil = 没有缝。落进缝里的占位框骑在它上面。
    let gapTop: Double?
    let contentWidth: Double
    let pps: Double
    let magnet: Bool
    /// 三套拖放（滤镜 / 音频库 / 文件）各自的对齐线：它们不走这个盒子，由时间线传进来。
    let fallbackGuides: [Double]
    /// 只拿来算跨轨落点（`state.crossTrackLandingSpan`），不订阅 —— 拖动中工程不会变（§0）。
    let project: VideoEditProject

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        // 对齐参考线：块的两条边各自去够参考点，对上了就亮一条通高的线，
        // 所以跨轨对齐（上面上层轨的边缘对上下面主轨的边缘）一眼能看见。
        TimelineAlignmentGuides(times: drag.clipDrag?.guides ?? fallbackGuides, pixelsPerSecond: pps)
        // 拉把手裁切时的线（2026-09-26）：工程在 liveTrim 里写、endLiveEdit 收，只有这个小视图订阅。
        TimelineTrimGuides(state: project.trimGuides, pixelsPerSecond: pps)

        // 主轨磁吸开着时松手会插进的位置：和被拖素材**等长**的占位框，
        // 一眼看出这 6 秒会占到哪里（时刻和宽度由 TimelineSnap.mainInsertion
        // 算，落地同一个函数 —— 框指哪儿、有多长，落地就是哪儿、就那么长）。
        if let span = mainInsertionSpan,
           let layout = layouts.first(where: { $0.spec.slot == .main }) {
            TimelineDropPlaceholder(span: span, pps: pps, y: layout.minY, height: layout.spec.height)
        }

        // 跨轨拖动：目标行上画出松手后的真实落点（等长占位框，位置与
        // relocateClip 共用同一份挤开算法 —— 框不说谎）。
        if let ghost = crossTrackGhost {
            TimelineDropPlaceholder(span: ghost.span, pps: pps, y: ghost.y, height: ghost.height)
        }

        // 垂直拖动的目标行高亮：现有行描边。落进缝里的不描边 —— 缝里那条插入线和缩略框
        // 已经说清楚了。
        if let target = drag.dragTargetRow, target.target.insertion == nil,
           let layout = layouts.first(where: { $0.spec.id == target.id }) {
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Color.teal, lineWidth: 2)
                .frame(width: contentWidth, height: layout.spec.height)
                .offset(y: layout.minY)
                .allowsHitTesting(false)
        }
        // 文字换行的目标（§5j）。
        TextRowDropIndicator(row: drag.textDropRow, layouts: layouts, width: contentWidth)

        // 正在拉的选择框。画在播放头之下、块之上，不拦事件。
        if let marquee = drag.marquee, marquee.rect.width > 0 || marquee.rect.height > 0 {
            Rectangle()
                .fill(Color.teal.opacity(0.12))
                .overlay(Rectangle().strokeBorder(Color.teal.opacity(0.9), lineWidth: 1))
                .frame(width: marquee.rect.width, height: marquee.rect.height)
                .offset(x: marquee.rect.minX, y: marquee.rect.minY)
                .allowsHitTesting(false)
        }
    }

    /// 主轨磁吸开着时，松手会插进的时间段。只在块留在自己轨上时给
    /// —— 跨轨落地走 `relocate`，那边的占位框由 `crossTrackGhost` 画。
    private var mainInsertionSpan: TimelineSpan? {
        guard drag.dragTargetRow == nil else { return nil }
        return drag.clipDrag?.mainInsertionSpan
    }

    /// 跨轨拖动中，目标行上的占位框：松手后被拖块会占据的时间段。
    /// 落点由 `TimelineState.crossTrackLandingSpan` 给 —— 和落地那步的
    /// `relocateClip` 共用同一份核心算法，框指哪儿、松手就落哪儿。
    private var crossTrackGhost: (span: TimelineSpan, y: Double, height: Double)? {
        guard let session = drag.clipDrag, case .clip = session.subject,
              let target = drag.dragTargetRow else { return nil }
        let span = project.state.crossTrackLandingSpan(
            plan: session.plan,
            delta: session.offset,
            target: target.target,
            magnet: magnet
        )
        if target.target.insertion != nil {
            // 落进缝里：行还不存在，缩略框骑在缝正中那条插入线上。缝只有 28pt
            // （用户选的窄缝），放不下整条轨高的框。几何只有 `TimelineSeams` 一份。
            guard let top = gapTop else { return nil }
            return (span, TimelineSeams.ghostY(gapTop: top), TimelineSeams.ghostHeight)
        }
        guard let layout = layouts.first(where: { $0.spec.id == target.id }) else { return nil }
        return (span, layout.minY, layout.spec.height)
    }
}
