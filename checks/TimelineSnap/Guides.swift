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
    // ---- 1. 对齐点 ----
    var state = TimelineState()
    var still = clip(start: 20, duration: 10)
    still.markers = [ClipMarker(sourceTime: 3)]   // 素材 3 秒 → 时间线 23 秒
    still.isHidden = true                            // 藏起来的也算
    var moving = clip(start: 40, duration: 10)
    moving.markers = [ClipMarker(sourceTime: 2)]     // 在动的那段上：42 秒不许出现
    state.mainClips = [still, moving]
    let fixedCue = SubtitleCue(start: 31.5, end: 33.25, text: "a")
    let movingCue = SubtitleCue(start: 60, end: 61, text: "b")
    state.subtitle = SubtitleDocumentModel(cues: [fixedCue, movingCue])
    var companion = SubtitleCompanion()
    companion.translation = SubtitleDocumentModel(cues: [SubtitleCue(start: 35.75, end: 36.5, text: "c")])
    state.subtitleCompanion = companion
    let candidates = TimelineSnap.candidates(in: state, moving: [moving.id, movingCue.id], playhead: 0)
    for time in [20.0, 30, 23, 31.5, 33.25, 35.75, 36.5] {
        check(candidates.contains(time), "\(time) 应当是对齐点（剪辑 / 标记 / 原文 cue / 译文 cue），实得 \(candidates)")
    }
    for time in [42.0, 60, 61, 40, 50] {
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
