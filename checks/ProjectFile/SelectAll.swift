import Foundation
import SrtFlowCore

// 第 33 组：⌘A 全选与滤镜多选（2026-09-25 用户拍板）。合同见
// docs/architecture/subtitle-track-visibility-and-layout.md「选择模型」。
//
// 1. 滤镜段进框选 / 全选：`selectBox(filters:)` 一次落定五类，标记和转场照样清掉；
// 2. 点选滤镜仍互斥（清掉其余各类）；⌘点加选只在滤镜之间并集；
// 3. `count` 算上滤镜，`soleFilterID` 只在恰好一段时有值（多选时检查器不认主角）；
// 4. 段没了就摘掉（pruneFilter 按集合过滤）；
// 5. 行头点滤镜行选中整层。

func checkSelectAll(root: URL) throws {
    let clip = UUID(), shape = UUID(), text = UUID(), cue = UUID()
    let f1 = UUID(), f2 = UUID()
    var s = EditSelection()
    s.selectMarker(ClipMarkerRef(clipID: clip, markerID: UUID()))
    s.selectBox(clips: [clip], shapes: [shape], texts: [text], cues: [cue], filters: [f1, f2])
    checkEqual(s.clipIDs, [clip], "全选：剪辑")
    checkEqual(s.filterIDs, [f1, f2], "全选：滤镜段也在")
    check(s.markerRef == nil, "全选把标记选择清掉（标记跟着段走）")
    checkEqual(s.count, 6, "count 算上滤镜")
    check(s.soleFilterID == nil && s.soleClipID == nil, "混选没有主角")
    check(!s.isEmpty, "非空")

    s.selectFilter(f1)
    checkEqual(s.filterIDs, [f1], "点选一段滤镜")
    check(s.clipIDs.isEmpty && s.textIDs.isEmpty && s.subtitleCueIDs.isEmpty && s.shapeIDs.isEmpty,
          "点选滤镜清掉其余各类（⌫ 只有一个入口）")
    checkEqual(s.soleFilterID, f1, "恰好一段时有主角")
    s.selectFilters([f1, f2])
    check(s.soleFilterID == nil, "两段时没有主角")
    checkEqual(s.count, 2, "两段滤镜")
    s.selectClips([clip])
    check(s.filterIDs.isEmpty, "点选剪辑清掉滤镜")
    s.selectFilters([])
    checkEqual(s.clipIDs, [clip], "清空滤镜选择不动别的（同其余各类的空集合语义）")

    s.selectBox(clips: [], shapes: [], texts: [], cues: [], filters: [f1, f2])
    s.pruneFilter { $0 == f2 }
    checkEqual(s.filterIDs, [f2], "段没了就摘掉那一段，别的留着")
    s.clear()
    check(s.isEmpty, "⌘⇧A：七类一起清")

    // ---- 行头点滤镜行 ----
    var state = TimelineState()
    let low = FilterClip(preset: FilterPreset.allCases[0], timelineStart: 0, duration: 3, layer: 0)
    let low2 = FilterClip(preset: FilterPreset.allCases[0], timelineStart: 5, duration: 3, layer: 0)
    let high = FilterClip(preset: FilterPreset.allCases[0], timelineStart: 1, duration: 3, layer: 1)
    state.filters = [low, high, low2]
    let row = TimelineRowSelection.ids(for: .filterLayer(0), in: state)
    check(row.category == .filters, "滤镜行只产出滤镜这一类")
    checkEqual(row.ids, [low.id, low2.id], "点第 0 层的行头选中这一层的两段")
    checkEqual(TimelineRowSelection.ids(for: .filterLayer(7), in: state).ids, [], "不存在的层是空")
    // 行头「滤镜行点得出选择」那一半在视图侧（RowSpec.selectionRow），由
    // scripts/check-project-file.sh 的接线守卫钉着（自检编不动那个文件）。
}
