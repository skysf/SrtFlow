import Foundation

// 选择的两个跨类型入口：⌘A 全选 / ⌘⇧A 取消，以及「拖一个选中的东西时谁跟着走」。
//
// 2026-09-25 用户拍板：⌘A 选中时间线上的一切 —— 剪辑（含隐藏轨上的）、形状、文字、数字、
// 字幕 cue、滤镜段；标记和转场跟着各自的段走（它们长在段上，段动 / 段删它们就动 / 删）；
// 磁吸开着时拖这一片，主轨不动（`draggingClipIDs` 的 magnetPinsMainTrack）。
// 快捷键接在 `VideoEditView.handleEvent`（本地按键监听，带 ⌘ 的组合里只放行这两个）。
// 选择模型的合同见 docs/architecture/subtitle-track-visibility-and-layout.md。
@MainActor
extension VideoEditProject {

    /// ⌘A：时间线上的一切。走框选那一个混选入口（`applyBoxSelection`），所以标记和转场的
    /// 选择照样被清掉 —— 它们跟着段走，不单独选。
    func selectAllOnTimeline() {
        applyBoxSelection(
            clips: Set(state.allClips.map(\.id)),
            shapes: Set(state.shapes.map(\.id)),
            texts: Set(state.textOverlays.map(\.id)),
            cues: Set(state.allSubtitleCues.map(\.id)),
            filters: Set(state.filters.map(\.id))
        )
    }

    /// 跟着一起动的非剪辑伙伴：框选 / ⌘A 一起选中的形状、文字、字幕 cue 和滤镜段。
    ///
    /// 只在**被拖的那个本来就在选中集合里**时才有伙伴 —— 拖一个没选中的东西
    /// 是「单选它再拖」，那时候整片选择已经被换掉了，不该再拉着旧的一片走。
    func movingCompanions(
        draggedID: UUID,
        movingClipIDs: Set<UUID>
    ) -> (
        shapes: [(id: UUID, span: TimelineSpan)],
        texts: [(id: UUID, span: TimelineSpan)],
        cues: [(id: UUID, span: TimelineSpan)],
        filters: [(id: UUID, span: TimelineSpan)],
        ids: Set<UUID>
    ) {
        let engaged = movingClipIDs.contains(draggedID)
            || selectedShapeIDs.contains(draggedID)
            || selectedTextIDs.contains(draggedID)
            || selectedSubtitleCueIDs.contains(draggedID)
            || selectedFilterIDs.contains(draggedID)
        guard engaged else { return ([], [], [], [], []) }
        let shapes = state.shapes
            .filter { selectedShapeIDs.contains($0.id) }
            .map { (id: $0.id, span: TimelineSpan(start: $0.timelineStart, end: $0.timelineEnd)) }
        let texts = state.textOverlays
            .filter { selectedTextIDs.contains($0.id) }
            .map { (id: $0.id, span: TimelineSpan(start: $0.timelineStart, end: $0.timelineEnd)) }
        let cues = state.allSubtitleCues
            .filter { selectedSubtitleCueIDs.contains($0.id) }
            .map { (id: $0.id, span: TimelineSpan(start: $0.start, end: $0.end)) }
        let filters = state.filters
            .filter { selectedFilterIDs.contains($0.id) }
            .map { (id: $0.id, span: TimelineSpan(start: $0.timelineStart, end: $0.timelineEnd)) }
        let ids = Set(shapes.map(\.id)).union(texts.map(\.id)).union(cues.map(\.id)).union(filters.map(\.id))
        return (shapes, texts, cues, filters, ids)
    }
}
