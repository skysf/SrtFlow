import SwiftUI
import SrtFlowCore

// MARK: - 块拖动的接线（四类块共用同一套会话）
//
// 从 `VideoEditTimelineView.swift` 拆出来（拆分前 2101 行，远超仓库约 800 行的
// 警戒线）。落点算法在 `VideoEditTimelineSnap.swift` / `VideoEditProject`，会话在
// `VideoEditTimelineDrag.swift`；这里只负责把手势接到它们身上：起手冻结、
// 每一拍重算渲染偏移、松手落一次。**拖动过程中一个字都不写 `TimelineState`**
// （docs/architecture/timeline-drag-gestures.md 第 0 节）。
// 接线守卫 `checks/timeline-drag-wiring.sh` 按文件扫描，挪动这里的东西要同步改它。

extension VideoEditTimelineView {

    // MARK: - 剪辑拖动

    /// 这个块此刻的渲染位移（秒）。nil = 没在被拖，按模型里的位置画。
    /// 整组共用**同一个**位移 —— 逐块各算各的会把相对错位弄坏。
    func dragOffset(for clip: EditClip) -> Double? {
        dragOffset(movingID: clip.id)
    }

    /// 同上，按 id 查。三类块（剪辑 / 形状 / 字幕 cue）共用这一个 —— 名单来自
    /// 同一份计划，谁在这一组里谁就画同一个位移。
    func dragOffset(movingID id: UUID) -> Double? {
        guard let drag = clipDrag, drag.movingIDs.contains(id) else { return nil }
        return drag.offset
    }

    func beginClipDrag(_ clip: EditClip, slot: TrackSlot) {
        // 开始拖动就收掉悬停预览，画面回播放头 —— 拖动过程里 hover 回调被
        // ClipBlockView 的 guard 挡住，不会再把 peek 顶回来。
        project.clock.endPeek()
        // 拖一个没选中的块 = 单选它；拖已选中的块 = 整组一起动。
        if !project.selectedClipIDs.contains(clip.id) {
            project.select(clip.id, additive: false)
        }
        guard let plan = project.dragPlan(draggedID: clip.id, slot: slot) else { return }
        clipDrag = ClipDragSession(
            subject: .clip(slot: slot),
            plan: plan,
            originScrollOffset: scrollGeometry.offsetX
        )
    }

    func beginShapeDrag(_ shape: ShapeAnnotation) {
        project.clock.endPeek()
        // 和剪辑对称：拖一个没选中的形状 = 单选它；拖已选中的 = 整组一起动。
        if !project.selectedShapeIDs.contains(shape.id) {
            project.selectShape(shape.id, additive: false)
        }
        guard let plan = project.shapeDragPlan(shapeID: shape.id) else { return }
        clipDrag = ClipDragSession(subject: .shape, plan: plan, originScrollOffset: scrollGeometry.offsetX)
    }

    func beginTextDrag(_ overlay: TextOverlay) {
        project.clock.endPeek()
        // 和剪辑/形状对称：拖一个没选中的 = 单选它；拖已选中的 = 整组一起动。
        if !project.selectedTextIDs.contains(overlay.id) {
            project.selectText(overlay.id, additive: false)
        }
        guard let plan = project.textDragPlan(textID: overlay.id) else { return }
        clipDrag = ClipDragSession(subject: .text, plan: plan, originScrollOffset: scrollGeometry.offsetX)
    }

    /// 字幕 cue 起手的拖动。与剪辑/形状三处严格对称，包括「拖一个没选中的
    /// = 单选它再拖」这条语义。
    func beginCueDrag(_ cue: SubtitleCue) {
        project.clock.endPeek()
        if !project.selectedSubtitleCueIDs.contains(cue.id) {
            project.selectSubtitleCue(cue.id, additive: false)
        }
        guard let plan = project.cueDragPlan(cueID: cue.id) else { return }
        clipDrag = ClipDragSession(subject: .subtitleCue, plan: plan, originScrollOffset: scrollGeometry.offsetX)
    }

    /// `pointerViewportX` 是指针在滚动视口里的 x（手势坐标系就钉在视口上）。
    func updateClipDrag(translation: CGSize, pointerViewportX: Double) {
        guard var drag = clipDrag else { return }
        drag.update(translation: translation, scrollOffset: scrollGeometry.offsetX, pixelsPerSecond: pps)
        clipDrag = drag
        dragTargetRow = verticalTarget(for: drag, dy: translation.height)
        autoScroller.update(
            pointerX: pointerViewportX,
            viewportWidth: viewportWidth
        ) {
            // 自动滚动那一拍指针没动，位移还是上一次那个，只有滚动量变了 ——
            // 新的滚动量同样现读，别让心跳再传一份数进来。
            guard var drag = clipDrag else { return }
            drag.update(
                translation: drag.translation,
                scrollOffset: scrollGeometry.offsetX,
                pixelsPerSecond: pps
            )
            clipDrag = drag
        }
    }

    func endClipDrag() {
        autoScroller.stop()
        defer {
            clipDrag = nil
            dragTargetRow = nil
        }
        guard let drag = clipDrag else { return }
        switch drag.subject {
        case .shape, .text, .subtitleCue:
            // 这三类自己不跨轨、不插空，但同一组里可能挂着剪辑 —— 落地仍走
            // 和剪辑同一个 applyDrag（`commitFreeDrag`），位移只有一份。
            project.commitFreeDrag(drag.plan, resolution: drag.resolution)
        case .clip:
            // 水平平移、跨轨搬运、磁吸插空都在 commitDrag 的**同一次 perform**
            // 里，所以是一步撤销，也不会出现「视频换了轨、链接音频留在旧时刻」。
            project.commitDrag(
                drag.plan,
                resolution: drag.resolution,
                crossTrack: dragTargetRow?.target
            )
        }
    }

    /// 主轨磁吸开着时，松手会插进的时间段。只在块留在自己轨上时给
    /// —— 跨轨落地走 `relocate`，那边的占位框由 `crossTrackGhost` 画。
    var mainInsertionSpan: TimelineSpan? {
        guard dragTargetRow == nil else { return nil }
        return clipDrag?.mainInsertionSpan
    }

    /// 跨轨拖动中，目标行上的占位框：松手后被拖块会占据的时间段。
    /// 落点由 `TimelineState.crossTrackLandingSpan` 给 —— 和落地那步的
    /// `relocateClip` 共用同一份核心算法，框指哪儿、松手就落哪儿。
    var crossTrackGhost: (span: TimelineSpan, y: Double, height: Double)? {
        guard let drag = clipDrag, case .clip = drag.subject,
              let target = dragTargetRow else { return nil }
        let span = project.state.crossTrackLandingSpan(
            plan: drag.plan,
            delta: drag.offset,
            target: target.target,
            magnet: project.magnetEnabled
        )
        let layouts = rowLayouts()
        if let layout = layouts.first(where: { $0.spec.id == target.id }) {
            return (span, layout.minY, layout.spec.height)
        }
        // 开新轨：行还不存在，占位框骑在那条插入线上，高度给个缩略值。
        let height = 22.0
        let y: Double = target.id == "new-top"
            ? (layouts.first { $0.spec.slot != nil }?.minY ?? 30) - 4 - height / 2
            : (layouts.last?.maxY ?? 30) + 4 - height / 2
        return (span, y, height)
    }

    /// 占位框本体：半透明填充 + 虚线描边，和被拖素材落地后等长。不拦事件。
    func dropPlaceholder(span: TimelineSpan, y: Double, height: Double) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.teal.opacity(0.18))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.teal, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
            )
            .frame(width: max(4, span.duration * pps), height: height)
            .offset(x: span.start * pps, y: y)
            .allowsHitTesting(false)
    }

    /// 垂直拖出 18pt 之后开始找目标行：同类行里挑离指尖最近的；
    /// 拖出最上面（视频）/最下面（音频）就是开新轨。
    func verticalTarget(
        for drag: ClipDragSession,
        dy: Double
    ) -> (id: String, target: VideoEditProject.RowTarget)? {
        guard abs(dy) > 18 else { return nil }
        // 形状只在自己那一行里横向移动，没有跨轨这回事。
        guard let slot = drag.clipSlot,
              let clip = project.state.clip(with: drag.draggedID) else { return nil }
        let layouts = rowLayouts()
        guard let source = layouts.first(where: { $0.spec.slot == slot }) else { return nil }
        let pointY = source.midY + dy

        var candidates: [(id: String, midY: Double, target: VideoEditProject.RowTarget)] = []
        if clip.isAudioOnly {
            for layout in layouts {
                if case .audio(let index) = layout.spec.slot {
                    candidates.append((layout.spec.id, layout.midY, .audio(index)))
                }
            }
            if let bottom = layouts.last {
                candidates.append(("new-bottom", bottom.maxY + 16, .newAudioBottom))
            }
        } else {
            for layout in layouts {
                switch layout.spec.slot {
                case .main:
                    candidates.append((layout.spec.id, layout.midY, .main))
                case .overlay(let index):
                    candidates.append((layout.spec.id, layout.midY, .overlay(index)))
                default:
                    break
                }
            }
            if let firstContent = layouts.first(where: { $0.spec.slot != nil }) {
                candidates.append(("new-top", firstContent.minY - 16, .newOverlayTop))
            }
        }

        guard let best = candidates.min(by: { abs($0.midY - pointY) < abs($1.midY - pointY) }) else {
            return nil
        }
        if best.id == source.spec.id { return nil }
        return (best.id, best.target)
    }

}
