import SwiftUI
import SrtFlowCore

// MARK: - 块拖动的接线（四类块共用同一套会话）
//
// 从 `VideoEditTimelineView.swift` 拆出来（拆分前 2101 行，远超仓库约 800 行的
// 警戒线）。落点算法在 `VideoEditTimelineSnap.swift` / `VideoEditProject`，会话在
// `VideoEditTimelineDrag.swift`；这里只负责把手势接到它们身上：起手冻结、
// 每一拍重算渲染偏移、松手落一次。**拖动过程中一个字都不写 `TimelineState`**
// （docs/architecture/timeline-drag-gestures.md 第 0 节）。会话本身放在 `dragBox`
// （`VideoEditTimelineDragBox.swift`）里：时间线持有、不订阅，每一拍只有正在动的块和
// `TimelineDragOverlay` 重算（§0b）。
// 接线守卫 `checks/timeline-drag-wiring.sh` 按文件扫描，挪动这里的东西要同步改它。

extension VideoEditTimelineView {

    // MARK: - 剪辑拖动

    func beginClipDrag(_ clip: EditClip, slot: TrackSlot) {
        // 开始拖动就收掉悬停预览，画面回播放头 —— 拖动过程里 hover 回调被
        // ClipBlockView 的 guard 挡住，不会再把 peek 顶回来。
        project.clock.endPeek()
        // 拖一个没选中的块 = 单选它；拖已选中的块 = 整组一起动。
        if !project.selectedClipIDs.contains(clip.id) {
            project.select(clip.id, additive: false)
        }
        guard let plan = project.dragPlan(draggedID: clip.id, slot: slot) else { return }
        startDrag(ClipDragSession(
            subject: .clip(slot: slot),
            plan: plan,
            originScrollOffset: scrollGeometry.offsetX
        ))
    }

    func beginShapeDrag(_ shape: ShapeAnnotation) {
        project.clock.endPeek()
        // 和剪辑对称：拖一个没选中的形状 = 单选它；拖已选中的 = 整组一起动。
        if !project.selectedShapeIDs.contains(shape.id) {
            project.selectShape(shape.id, additive: false)
        }
        guard let plan = project.shapeDragPlan(shapeID: shape.id) else { return }
        startDrag(ClipDragSession(
            subject: .shape,
            plan: plan,
            originScrollOffset: scrollGeometry.offsetX
        ))
    }

    func beginTextDrag(_ overlay: TextOverlay) {
        project.clock.endPeek()
        // 和剪辑/形状对称：拖一个没选中的 = 单选它；拖已选中的 = 整组一起动。
        if !project.selectedTextIDs.contains(overlay.id) {
            project.selectText(overlay.id, additive: false)
        }
        guard let plan = project.textDragPlan(textID: overlay.id) else { return }
        startDrag(ClipDragSession(
            subject: .text,
            plan: plan,
            originScrollOffset: scrollGeometry.offsetX
        ))
    }

    /// 滤镜段起手的拖动。与形状/文字同构 —— 差别只在它的障碍是**同一层上**的
    /// 其他滤镜段（见 `filterDragPlan`）：叠加靠分层，同一行里叠在一起只会
    /// 互相盖住。
    func beginFilterDrag(_ filter: FilterClip) {
        project.clock.endPeek()
        if !project.selectedFilterIDs.contains(filter.id) {
            project.selectFilter(filter.id)
        }
        guard let plan = project.filterDragPlan(filterID: filter.id) else { return }
        startDrag(ClipDragSession(
            subject: .filter,
            plan: plan,
            originScrollOffset: scrollGeometry.offsetX
        ))
    }

    /// 字幕 cue 起手的拖动。与剪辑/形状三处严格对称，包括「拖一个没选中的
    /// = 单选它再拖」这条语义。
    func beginCueDrag(_ cue: SubtitleCue) {
        project.clock.endPeek()
        if !project.selectedSubtitleCueIDs.contains(cue.id) {
            project.selectSubtitleCue(cue.id, additive: false)
        }
        guard let plan = project.cueDragPlan(cueID: cue.id) else { return }
        startDrag(ClipDragSession(
            subject: .subtitleCue,
            plan: plan,
            originScrollOffset: scrollGeometry.offsetX
        ))
    }

    /// 起手：会话进盒子，成员名单进时间线的 `@State`（一轮只写这一次，松手清一次）——
    /// 成员的块才订阅位移，其余块拿永远不发的发布者（§0b）。
    private func startDrag(_ session: ClipDragSession) {
        dragBox.begin(session)
        dragMembers = session.movingIDs
    }

    /// `pointerViewport` 是指针在滚动视口里的位置（手势坐标系就钉在视口上）。
    ///
    /// 每一拍只写 `dragBox`（块和覆盖层各订阅自己那份）和「弹性尾部」那个很少变的档位；
    /// 时间线本体的 `@State` 一个字都不碰，它的 body 在拖动中就不重算（§0b）。
    func updateClipDrag(translation: CGSize, pointerViewport: CGPoint) {
        guard var drag = dragBox.clipDrag else { return }
        drag.update(translation: translation, scrollOffset: scrollGeometry.offsetX, pixelsPerSecond: pps)
        drag.pointerViewport = pointerViewport
        dragBox.update(drag)
        aimVertically(drag)
        growTail(for: drag)
        autoScroller.update(
            pointer: pointerViewport,
            viewport: CGSize(width: viewportWidth, height: viewportHeight)
        ) {
            // 自动滚动那一拍指针没动，位移还是上一次那个，只有滚动量变了 ——
            // 新的滚动量同样现读，别让心跳再传一份数进来。
            guard var drag = dragBox.clipDrag else { return }
            drag.update(
                translation: drag.translation,
                scrollOffset: scrollGeometry.offsetX,
                pixelsPerSecond: pps
            )
            dragBox.update(drag)
            // 纵向滚动时内容在不动的指针底下走：目标行 / 缝也得跟着重判，
            // 不然纵向滚出来的轨要等鼠标再动一下才选得中。
            aimVertically(drag)
            growTail(for: drag)
        }
    }

    /// 弹性尾部：块的投影终点快够到内容末尾了，就把内容宽度往上抬一档（半个视口）。
    /// 一档一档地跳而不是跟着终点走：它是时间线的 `@State`，每写一次整条时间线重算一次。
    /// 磁吸主轨不给（它只能插进现有故事线的某条缝）。
    private func growTail(for drag: ClipDragSession) {
        guard drag.allowsFreeLanding else { return }
        let step = max(320, viewportWidth * 0.5)
        let needed = drag.end * pps + step - contentBaseWidth
        guard needed > dragTailWidth else { return }
        dragTailWidth = (needed / step).rounded(.up) * step
    }

    /// 按这一拍的指针定纵向目标：高亮哪条轨、压在哪条缝上（停够 0.2 秒拉开）、
    /// 开着的缝该不该合上（§5h）。只写视图状态，一个字都不写 `TimelineState`（§0）。
    func aimVertically(_ drag: ClipDragSession) {
        // 文字块只在文字行之间上下换行（§5j），不进缝、不换轨。
        if drag.subject == .text {
            dragBox.aim(textRow: textRowTarget(for: drag))
            return
        }
        let aim = verticalAim(for: drag, dy: drag.translation.height)
        if !aim.inOpenGap, openSeam != nil {
            withAnimation(TimelineSeamDwell.animation) { openSeam = nil }
        }
        dragBox.aim(row: aim.row)
        seamDwell.hover(aim.dwell) { seam in
            // 停够了：拉开这条缝，落点改成「在这儿新开一条轨」。
            guard dragBox.clipDrag != nil else { return }
            withAnimation(TimelineSeamDwell.animation) { openSeam = seam }
            dragBox.aim(row: DragRowTarget(id: "seam", target: seam.target))
        }
    }

    func endClipDrag() {
        autoScroller.stop()
        seamDwell.cancel()
        defer {
            // 会话、目标行、文字行、cue 记号一起收；弹性尾部归零，内容宽度交回 duration。
            dragBox.end()
            if dragTailWidth != 0 { dragTailWidth = 0 }
            if !dragMembers.isEmpty { dragMembers = [] }
            // 缝跟着这一轮一起收：落进了缝，新开的那条轨就长在缝的位置上；没落进去就合上。
            openSeam = nil
        }
        guard let drag = dragBox.clipDrag else { return }
        switch drag.subject {
        case .shape, .text, .subtitleCue, .filter:
            // 这四类自己不跨轨、不插空，但同一组里可能挂着剪辑 —— 落地仍走
            // 和剪辑同一个 applyDrag（`commitFreeDrag`），位移只有一份。
            // （滤镜段 2026-09-25 起也进框选 / ⌘A，伙伴规则和别的块一样。）
            // 文字块还带上目标行（§5j）：换行和横向位移在同一次 perform 里，一步撤销。
            project.commitFreeDrag(drag.plan, resolution: drag.resolution, textRow: dragBox.textDropRow)
        case .clip:
            // 水平平移、跨轨搬运、磁吸插空都在 commitDrag 的**同一次 perform**
            // 里，所以是一步撤销，也不会出现「视频换了轨、链接音频留在旧时刻」。
            project.commitDrag(
                drag.plan,
                resolution: drag.resolution,
                crossTrack: dragBox.dragTargetRow?.target
            )
        }
    }

    /// 占位框本体：半透明填充 + 虚线描边，和被拖素材落地后等长。不拦事件。
    func dropPlaceholder(span: TimelineSpan, y: Double, height: Double) -> some View {
        TimelineDropPlaceholder(span: span, pps: pps, y: y, height: height)
    }

    /// 一拍的纵向判定结果。
    struct VerticalAim {
        /// 松手落到哪（nil = 留在自己这条轨上）。
        var row: DragRowTarget?
        /// 指针压着哪条关着的缝：停够时间就拉开它。
        var dwell: TimelineSeam?
        /// 指针在已经拉开的那条缝里（缝保持开着）。
        var inOpenGap = false
    }

    /// 垂直拖出 18pt 之后开始找目标：缝拉开了就落进缝（新开一条轨）；没拉开就落进同类行里
    /// 离指针最近的那条，同时看指针压没压在某条缝上（停够 0.2 秒拉开它）。
    ///
    /// 最上面那条视频缝以上、最下面那条音频缝以下都算那条缝 —— 原来「拖出最上面 = 顶上
    /// 新开一条」「拖出最下面 = 底下新开一条」的老手感，现在也要先停一下、缝拉开了才落。
    /// 拖文字块时指针落在哪一行（§5j）。判定是纯值的（`TextRows.dropTarget`），这里只把
    /// **画出来的**文字行（含现读的纵向滚动量，§5c）喂进去。18pt 门槛同 `verticalAim`。
    func textRowTarget(for drag: ClipDragSession) -> Int? {
        guard abs(drag.translation.height) > 18,
              let overlay = project.state.textOverlays.first(where: { $0.id == drag.draggedID }) else {
            return nil
        }
        let y = drag.pointerViewport.y + scrollGeometry.offsetY
        let textRows = rowLayouts(open: nil).compactMap { layout -> (row: Int, minY: Double, maxY: Double)? in
            guard let row = layout.spec.textRow else { return nil }
            return (row, layout.minY, layout.maxY)
        }
        return TextRows.dropTarget(
            y: y, rows: textRows, rowCount: project.state.textRowCount, current: overlay.row
        )
    }

    func verticalAim(for drag: ClipDragSession, dy: Double) -> VerticalAim {
        guard abs(dy) > 18 else { return VerticalAim() }
        // 形状只在自己那一行里横向移动，没有跨轨这回事。
        guard let slot = drag.clipSlot,
              let clip = project.state.clip(with: drag.draggedID) else { return VerticalAim() }
        let specs = rows
        let seamRows = specs.map(\.seamRow)
        guard let source = specs.firstIndex(where: { $0.slot == slot }) else { return VerticalAim() }
        // 指针的内容 y = 视口 y + **现读**的纵向滚动量（§5c）。不能再按「起手那一行的中线
        // + dy + 滚过的量」推算：缝一拉开，指针底下的行就被推走了，按起手的行去推会差一个
        // 缝宽（§5h）。纵向自动滚动那一拍指针没动、内容在滚，差的也正是这一项。
        let y = drag.pointerViewport.y + scrollGeometry.offsetY
        let audio = clip.isAudioOnly
        let noOp = TimelineSeams.noOpSeams(draggingClip: clip.id, in: project.state)
        let candidates = TimelineSeams.spots(audio: audio, rows: seamRows)
            .map(\.seam)
            .filter { !noOp.contains($0) }
        switch TimelineSeams.aim(y: y, rows: seamRows, open: openSeam, candidates: candidates, openEnds: true) {
        case .inOpenGap(let seam):
            return VerticalAim(row: DragRowTarget(id: "seam", target: seam.target), dwell: nil, inOpenGap: true)
        case .near(let seam):
            // 缝没拉开（或者这一拍就合上）：按关着时的排布挑最近的同类轨。
            guard let nearest = TimelineSeams.nearestTrackRow(y: y, rows: seamRows, audio: audio),
                  nearest != source, let target = specs[nearest].slot else {
                return VerticalAim(row: nil, dwell: seam)
            }
            return VerticalAim(row: DragRowTarget(id: specs[nearest].id, target: TrackDropTarget(target)), dwell: seam)
        }
    }

}

/// 时间线上的落点占位框：半透明填充 + 虚线描边，和被拖素材落地后等长，不拦事件。
///
/// **所有落点共用这一个外观**：磁吸插空、跨轨到岸、音频库拖素材、从 Finder 拖文件
/// 进轨道，落下去都是一个普通的块，没道理让用户学第二种落点语言。抽成独立视图是
/// 因为最后那一个画在自己的文件里（`MediaFileDropIndicator`），够不着
/// `VideoEditTimelineView` 上的那个方法 —— 复制一份外观常量就等于两份账。
struct TimelineDropPlaceholder: View {
    let span: TimelineSpan
    let pps: Double
    let y: Double
    let height: Double

    /// 开新轨时占位框的缩略高度。那儿只有几个点的缝（标尺到 28、最上面那条轨行
    /// 从 33 起），按真实行高去画，框会整个跑到视口外面 —— 所以缩一缩、**骑在**
    /// 插入线上，上下各露出来一半。和拉开的缝里那个框同一个尺寸（`TimelineSeams`）。
    static let newLaneHeight = TimelineSeams.ghostHeight
    /// 缩略框的中心离相邻那条轨有多远。
    static let newLaneGap = 4.0

    /// 新轨的缩略框画在哪：骑在「最上面那条轨行之上」那条插入线上。
    static func newLaneY(above top: Double) -> Double {
        top - newLaneGap - newLaneHeight / 2
    }

    /// 同上，「最下面那一行之下」。
    static func newLaneY(below bottom: Double) -> Double {
        bottom + newLaneGap - newLaneHeight / 2
    }

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.teal.opacity(0.18))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.teal, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
            )
            // 0.05 秒的碎块按真实时长只有 1 个点宽，框得有个下限才看得见。
            .frame(width: max(4, span.duration * pps), height: height)
            .offset(x: span.start * pps, y: y)
            .allowsHitTesting(false)
    }
}
