import Foundation
import SrtFlowCore

// 第 1d 组：裁切时的吸附与对齐线（`TrimSnapPlan` / `TimelineTrim.snapPlan`，2026-09-26）。
//
// 1. 看真正在动的那条边：裁结尾吸结尾、裁开头吸开头；一组一起裁看整组最靠外那条。
// 2. 吸到之后仍要按整组的范围夹（`trimGroup`），线按夹完的位置算：被素材尽头拦住、没到对齐点就不亮。
// 3. 磁吸开着裁主轨段的开头（FCP 式实时 ripple）：段头不动、段尾反着缩 → 吸的、亮线的是段尾；
//    后面跟着 ripple 的主轨段不当参考点。
// 4. 这一组自己、链接伙伴（在名单里）不当参考点。

func checkTrimSnap() {
    var state = TimelineState()
    // 整体从 1 秒起摆：时间线的 0 秒永远是对齐点，放在 0 上就测不出「自己的开头不算」。
    var first = clip(start: 1, duration: 4)
    first.info = MediaInfo(duration: 10, displaySize: CGSize(width: 320, height: 180), frameRate: 30,
                           videoCodec: "h264", audioCodec: nil, hasAudio: false, audioCanCopyToMP4: false, fileBytes: 1)
    let second = clip(start: 5, duration: 4)
    let upper = clip(start: 4, duration: 1)     // 上层轨上一段 [4, 5)：它的开头 4 是对齐点
    let shape = ShapeAnnotation(kind: .rectangle, timelineStart: 7.05, duration: 1)
    state.mainClips = [first, second]
    state.overlayTracks = [EditLane(clips: [upper])]
    state.shapes = [shape]
    let m = TimelineTrim.Member(id: first.id, kind: .clip)

    // ---- 1. 裁结尾：吸结尾 ----
    guard let tail = TimelineTrim.snapPlan(members: [m], leading: false, magnet: false, in: state, playhead: 100) else {
        return check(false, "裁结尾应当有吸附计划")
    }
    checkClose(tail.edge, 5, "裁结尾看的是结尾")
    check(!tail.candidates.contains(1), "这一段自己的开头不当参考点")
    checkClose(tail.snapped(2.0, pixelsPerSecond: pps), 2.05, "结尾 5+2=7 离形状开头 7.05 只差 0.05：吸上去")
    checkClose(tail.snapped(1.0, pixelsPerSecond: pps), 1.0, "离得远就原样（结尾 6，最近的对齐点都在阈值外）")
    check(tail.guides(after: 2.05, pixelsPerSecond: pps) == [7.05], "吸上了亮那条线")
    check(tail.guides(after: 1.0, pixelsPerSecond: pps).isEmpty, "没碰上不亮线")

    // ---- 2. 先夹再算线：素材只剩 6 秒余量时吸不到更远的点 ----
    var clamp = state
    clamp.trimGroup([m], leading: false, by: tail.snapped(2.0, pixelsPerSecond: pps))
    checkClose(clamp.clip(with: first.id)?.timelineEnd ?? -1, 7.05, "吸完照样走 trimGroup，落在对齐点上")
    let far = TrimSnapPlan(edge: 5, direction: 1, candidates: [11.05])
    var farState = state
    let applied = farState.trimGroup([m], leading: false, by: far.snapped(6.0, pixelsPerSecond: pps))
    checkClose(applied, 6, "素材 10 秒、已用 4 秒：结尾最多再拉 6 秒，吸附点 11.05 在外面")
    check(far.guides(after: applied, pixelsPerSecond: pps).isEmpty, "被素材尽头拦住、没到对齐点：不亮线（线和边对得上）")

    // ---- 1b. 裁开头：吸开头；一组看最靠外 ----
    guard let head = TimelineTrim.snapPlan(
        members: [m, TimelineTrim.Member(id: upper.id, kind: .clip)], leading: true, magnet: false, in: state, playhead: 100
    ) else { return check(false, "裁开头应当有吸附计划") }
    checkClose(head.edge, 1, "一组裁开头看最早的开头（1，不是上层那段的 4）")
    checkEqual(head.direction, 1, "不开磁吸：开头跟着手走")

    // ---- 3. 磁吸开着裁主轨段的开头：看段尾 ----
    guard let ripple = TimelineTrim.snapPlan(members: [m], leading: true, magnet: true, in: state, playhead: 100) else {
        return check(false, "磁吸开着也要有吸附计划")
    }
    checkClose(ripple.edge, 5, "段头不动、段尾在动：看段尾")
    checkEqual(ripple.direction, -1, "段尾反着走：往右裁开头 = 段尾往左缩")
    check(!ripple.candidates.contains(9), "后面跟着 ripple 的主轨段不当参考点（它的结尾 9）")
    check(ripple.candidates.contains(4), "别的轨上的边照样是参考点（上层那段的开头 4）")
    checkClose(ripple.snapped(0.98, pixelsPerSecond: pps), 1.0, "段尾 5-0.98=4.02 离 4 只差 0.02：吸上去")
    check(ripple.guides(after: 1.0, pixelsPerSecond: pps) == [4], "亮的是段尾碰上的那条线")
}
