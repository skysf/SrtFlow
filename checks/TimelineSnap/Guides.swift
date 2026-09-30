import Foundation
import SrtFlowCore

// 第 1c 组：对齐点与对齐线（2026-09-25 规格，2026-09-26 实施）。
//
// 1. 对齐点 = 所有轨上没在动的东西：剪辑、形状、文字、滤镜段之外，**字幕 cue（两条轨）和标记**也算；
//    在动的 cue 不算自己的参考点，在动的那段上的标记也不算；藏起来的照样算。
// 2. 多选拖动只看**整组最靠外的两条边**：最早的开头、最晚的结尾；中间那块的边碰上了不吸、不亮线。
// 3. 磁吸开着拖主轨也吸、也亮线（线跟手上的块走），但**插进哪条缝只看原始中心**，吸附挪的那几个点
//    不许改变插空的结果。

func checkAlignmentGuides() {
    checkTrimKeepsMarkersInPlace()
    // ---- 1. 对齐点 ----
    var state = TimelineState()
    var still = clip(start: 20, duration: 10)
    still.markers = [ClipMarker(sourceTime: 3)]   // 素材 3 秒 → 时间线 23 秒
    still.isHidden = true                            // 藏起来的也算
    var moving = clip(start: 40, duration: 10)
    moving.markers = [ClipMarker(sourceTime: 2)]     // 在动的那段上：42 秒不许出现
    state.mainClips = [still, moving]
    var stillText = TextOverlay(text: "t", timelineStart: 70, duration: 5)
    stillText.markers = [ClipMarker(sourceTime: 1)]       // 离起点 1 秒 → 71
    var movingText = TextOverlay(text: "m", timelineStart: 90, duration: 5)
    movingText.markers = [ClipMarker(sourceTime: 1)]      // 在动的那块上：91 不许出现
    state.textOverlays = [stillText, movingText]
    state.rulerMarkers = [ClipMarker(sourceTime: 80.5)]   // 标尺标记锚在时间线上：80.5
    let fixedCue = SubtitleCue(start: 31.5, end: 33.25, text: "a")
    let movingCue = SubtitleCue(start: 60, end: 61, text: "b")
    state.subtitle = SubtitleDocumentModel(cues: [fixedCue, movingCue])
    var companion = SubtitleCompanion()
    companion.translation = SubtitleDocumentModel(cues: [SubtitleCue(start: 35.75, end: 36.5, text: "c")])
    state.subtitleCompanion = companion
    let candidates = TimelineSnap.candidates(in: state, moving: [moving.id, movingCue.id, movingText.id], playhead: 0)
    for time in [20.0, 30, 23, 31.5, 33.25, 35.75, 36.5, 71, 80.5] {
        check(candidates.contains(time), "\(time) 应当是对齐点（剪辑 / 标记 / 原文 cue / 译文 cue / 文字块上的标记 / 标尺标记），实得 \(candidates)")
    }
    for time in [42.0, 60, 61, 40, 50, 91] {
        check(!candidates.contains(time), "\(time) 属于在动的东西，不许当自己的参考点")
    }

    // ---- 2. 多选只看整组最靠外的两条边 ----
    let a = UUID(), b = UUID()
    let plan = ClipDragPlan(
        draggedID: a, draggedSpan: TimelineSpan(start: 0, end: 2),
        members: [member(a, 0, 2), member(b, 5, 3)],   // 整组 [0, 8)
        candidates: [4.05, 10.1], magnet: nil
    )
    let outer = plan.resolve(desiredDelta: 2, pixelsPerSecond: pps)
    checkClose(outer.delta, 2.1, "整组的结尾 8+2=10 离 10.1 只差 0.1s：吸上去")
    check(outer.guides == [10.1], "亮的是整组结尾碰上的那条线，实得 \(outer.guides)")
    let middle = ClipDragPlan(
        draggedID: a, draggedSpan: TimelineSpan(start: 0, end: 2),
        members: [member(a, 0, 2), member(b, 5, 3)],
        candidates: [4.05], magnet: nil
    ).resolve(desiredDelta: 2, pixelsPerSecond: pps)
    checkClose(middle.delta, 2, "中间那块（A 的结尾 4）碰上 4.05 不吸：只看整组最靠外的边")
    check(middle.guides.isEmpty, "中间那块碰上了也不亮线，实得 \(middle.guides)")

    // ---- 3. 磁吸主轨：吸、亮线，但插空只看原始中心 ----
    let rest = [clip(start: 0, duration: 4), clip(start: 4, duration: 4)]
    let dragged = clip(start: 8, duration: 2)
    func magnetPlan(_ candidates: [Double]) -> ClipDragPlan {
        ClipDragPlan(
            draggedID: dragged.id, draggedSpan: TimelineSpan(start: 8, end: 10),
            members: [member(dragged.id, 8, 2)], candidates: candidates,
            magnet: ClipDragPlan.Magnet(rest: rest, moving: [dragged])
        )
    }
    // 拖到 -5.95：块 [2.05, 4.05)，中心 3.05 < 第一段中点 2？不，> 2 → 插在第一段之后（下标 1）。
    let snappedMagnet = magnetPlan([2]).resolve(desiredDelta: -5.95, pixelsPerSecond: pps)
    let rawMagnet = magnetPlan([]).resolve(desiredDelta: -5.95, pixelsPerSecond: pps)
    checkClose(snappedMagnet.delta, -6, "磁吸开着，浮着的块照样吸：开头 2.05 吸到 2")
    check(snappedMagnet.guides == [2], "磁吸开着也亮线（线跟手上的块走），实得 \(snappedMagnet.guides)")
    checkEqual(snappedMagnet.mainInsertion, rawMagnet.mainInsertion, "吸附不许改变插进哪条缝")
    check(rawMagnet.guides.isEmpty, "没有候选就不亮线（吸附关掉时调用方给的就是空候选）")
}

// 裁头不挪标记（2026-09-30）：叠层类的块（文字 / 形状 / 滤镜段）裁起点端，标记要留在时间线上的
// 同一刻（和素材段「贴在同一帧画面」同一个语义）；裁过头了藏不删，拉回来再画。`TimelineState.trim`
// 只在这个自检里编，所以钉在这儿（纯值那半边在 checks/ProjectFile/Markers.swift）。
func checkTrimKeepsMarkersInPlace() {
    var state = TimelineState()
    var text = TextOverlay(text: "t", timelineStart: 10, duration: 6)
    text.markers = [ClipMarker(sourceTime: 2)]   // 时间线 12 秒
    var shape = ShapeAnnotation(kind: .rectangle, timelineStart: 10, duration: 6)
    shape.markers = [ClipMarker(sourceTime: 2)]
    var filter = FilterClip(preset: .coldIron, timelineStart: 10, duration: 6)
    filter.markers = [ClipMarker(sourceTime: 2)]
    state.textOverlays = [text]; state.shapes = [shape]; state.filters = [filter]
    let members = [
        TimelineTrim.Member(id: text.id, kind: .text), TimelineTrim.Member(id: shape.id, kind: .shape),
        TimelineTrim.Member(id: filter.id, kind: .filter),
    ]
    for member in members { state.trim(member, leading: true, by: 1) }
    func hosts(_ state: TimelineState) -> [(String, any MarkerHost)] {
        [("文字", state.textOverlays[0]), ("形状", state.shapes[0]), ("滤镜", state.filters[0])]
    }
    for (name, host) in hosts(state) {
        check(abs(host.timelineStart - 11) < 1e-9, "\(name)裁头 1 秒后从 11 秒起")
        check(abs((host.markers.first?.sourceTime ?? -1) - 1) < 1e-9, "\(name)的标记离起点 1 秒")
        check(host.visibleMarkers.count == 1 && abs(host.timelineTime(of: host.visibleMarkers[0]) - 12) < 1e-9,
              "\(name)的标记还在时间线 12 秒（裁头不挪标记）")
    }
    for member in members { state.trim(member, leading: true, by: 2) }
    for (name, host) in hosts(state) {
        check(host.visibleMarkers.isEmpty && host.markers.count == 1, "\(name)裁过头：标记藏起来、不删")
    }
    for member in members { state.trim(member, leading: true, by: -2) }
    for (name, host) in hosts(state) {
        check(host.visibleMarkers.count == 1 && abs(host.timelineTime(of: host.visibleMarkers[0]) - 12) < 1e-9,
              "\(name)拉回来：标记又在 12 秒画出来")
    }
    for member in members { state.trim(member, leading: false, by: -3) }
    for (name, host) in hosts(state) {
        check(abs((host.markers.first?.sourceTime ?? -1) - 1) < 1e-9, "\(name)裁尾不动标记")
    }
}
