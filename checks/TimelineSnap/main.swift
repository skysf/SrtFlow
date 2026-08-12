import CoreGraphics
import Foundation
import SrtFlowCore

// 时间线拖动的吸附 / 对齐线 / 主轨插入位置的自检。全是纯值变换，不碰
// AVFoundation / ffmpeg / 磁盘。编译方式见 scripts/check-timeline-snap.sh。
//
// 背景：docs/bugfixes/2026-08-09-timeline-clip-drag-lag-and-alignment.md

var failures = 0
var checks = 0

func check(_ condition: Bool, _ message: String, line: Int = #line) {
    checks += 1
    if !condition {
        failures += 1
        print("FAIL [line \(line)] \(message)")
    }
}

func checkEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String, line: Int = #line) {
    checks += 1
    if actual != expected {
        failures += 1
        print("FAIL [line \(line)] \(message): got \(actual), expected \(expected)")
    }
}

func checkClose(_ actual: Double, _ expected: Double, _ message: String, line: Int = #line) {
    checks += 1
    if abs(actual - expected) > 0.001 {
        failures += 1
        print("FAIL [line \(line)] \(message): got \(actual), expected \(expected)")
    }
}

let media = URL(fileURLWithPath: "/tmp/srtflow-snap-check/source.mp4")

func clip(start: Double, duration: Double) -> EditClip {
    EditClip(sourceURL: media, sourceDuration: duration, timelineStart: start)
}

/// 默认缩放（24 点/秒）下的吸附半径是 7/24 ≈ 0.2917 秒。
let pps = 24.0
let threshold = TimelineSnap.thresholdPixels / pps

// MARK: - 1. 起点吸附（老行为，别改坏）

do {
    let result = TimelineSnap.resolve(
        proposedStart: 9.9, duration: 5, candidates: [0, 10, 30], pixelsPerSecond: pps
    )
    checkClose(result.start, 10, "起点离候选 0.1s，应当吸上去")
    check(result.guides == [10], "吸上了就要亮那条线，得到 \(result.guides)")
}

do {
    let result = TimelineSnap.resolve(
        proposedStart: 9.0, duration: 5, candidates: [0, 10, 30], pixelsPerSecond: pps
    )
    checkClose(result.start, 9.0, "离候选 1s 远超阈值，不许吸")
    check(result.guides.isEmpty, "没吸上就不该亮线，得到 \(result.guides)")
}

// MARK: - 2. 终点也要参与（这一条守「右边缘贴左边缘没反应」的 bug）

do {
    // 块 [14.9, 19.9)，右边缘离 20 只差 0.1s —— 起点离任何候选都有 5s 开外。
    let result = TimelineSnap.resolve(
        proposedStart: 14.9, duration: 5, candidates: [0, 10, 20, 40], pixelsPerSecond: pps
    )
    checkClose(result.start, 15, "右边缘贴上 20，起点应被带到 15")
    check(result.guides == [20], "亮的是右边缘压住的那条线，得到 \(result.guides)")
}

do {
    // 反向：右边缘刚过了候选一点点，也要被拉回来。
    let result = TimelineSnap.resolve(
        proposedStart: 15.2, duration: 5, candidates: [20], pixelsPerSecond: pps
    )
    checkClose(result.start, 15, "右边缘越过候选 0.2s，同样吸回去")
}

do {
    // 四种配对里取位移最小的：块 [14.8, 19.8)，起点离 15 差 0.2、
    // 终点离 19.95 只差 0.15 → 该走终点那一对，起点顺势落到 14.95。
    let result = TimelineSnap.resolve(
        proposedStart: 14.8, duration: 5, candidates: [15, 19.95], pixelsPerSecond: pps
    )
    checkClose(result.start, 14.95, "该挑位移更小的那一种配对")
    check(result.guides == [19.95], "亮的是真正对上的那条，得到 \(result.guides)")
}

// MARK: - 3. 一次可以亮两条线（左右各贴一个邻居）

do {
    // 块长 5s，左边有段结束于 10、右边有段开始于 15：落在 10 时两条边同时对齐。
    let result = TimelineSnap.resolve(
        proposedStart: 10.05, duration: 5, candidates: [10, 15], pixelsPerSecond: pps
    )
    checkClose(result.start, 10, "吸到 10")
    check(result.guides == [10, 15], "两条边各压住一个候选，两条线都要亮，得到 \(result.guides)")
}

// MARK: - 4. 阈值随缩放走（缩得越小，同样的像素距离 = 更长的时间）

do {
    let farAtDefault = TimelineSnap.resolve(
        proposedStart: 9.5, duration: 5, candidates: [10], pixelsPerSecond: pps
    )
    checkClose(farAtDefault.start, 9.5, "0.5s > \(threshold)s 阈值，默认缩放下不吸")

    let nearWhenZoomedOut = TimelineSnap.resolve(
        proposedStart: 9.5, duration: 5, candidates: [10], pixelsPerSecond: 4
    )
    checkClose(nearWhenZoomedOut.start, 10, "缩到 4 点/秒时 0.5s 只有 2 个像素，该吸")
}

// MARK: - 5. 夹到最左之后再算参考线（线和块不能各画各的）

do {
    let result = TimelineSnap.resolve(
        proposedStart: -3, duration: 5, candidates: [0, 10], pixelsPerSecond: pps
    )
    checkClose(result.start, 0, "整组不能被推到负时间")
    check(result.guides == [0], "夹完停在 0，亮的就该是 0 那条，得到 \(result.guides)")
}

do {
    // 跟随块比被拖的块早 4 秒 → 被拖的这个最左只能到 4。
    let result = TimelineSnap.resolve(
        proposedStart: 1, duration: 5, candidates: [0, 4, 30], pixelsPerSecond: pps, minimumStart: 4
    )
    checkClose(result.start, 4, "被 minimumStart 夹住")
    check(result.guides == [4], "参考线按夹完的位置算，得到 \(result.guides)")
}

// MARK: - 6. 吸附关掉 = 空候选：原样返回、不亮线

do {
    let result = TimelineSnap.resolve(
        proposedStart: 9.99, duration: 5, candidates: [], pixelsPerSecond: pps
    )
    checkClose(result.start, 9.99, "没有候选就不该动落点")
    check(!result.isSnapped, "没有候选就不该报吸上了")
}

// MARK: - 7. 候选表：跟着一起动的块**不许**当参考点
//
// 这一条守的是「拖不动 / 粘手」：链接的音频、多选的伙伴上一拍刚被挪到手指底下，
// 留在候选里就会把块吸回上一帧的位置，鼠标一拍走不满 7 个像素就永远挣不脱。

do {
    var state = TimelineState()
    let dragged = clip(start: 10, duration: 5)
    let partner = clip(start: 10, duration: 5)   // 链接的音频，同起同终
    let bystander = clip(start: 30, duration: 5)
    state.mainClips = [dragged, bystander]
    state.audioTracks = [EditLane(clips: [partner])]

    let candidates = TimelineSnap.candidates(
        in: state, moving: [dragged.id, partner.id], playhead: 7
    )
    check(!candidates.contains(where: { abs($0 - 10) < 0.001 }), "被拖的块和它的伙伴不许当参考点")
    check(!candidates.contains(where: { abs($0 - 15) < 0.001 }), "伙伴的终点也不许")
    check(candidates.contains(where: { abs($0 - 30) < 0.001 }), "不动的块要在候选里")
    check(candidates.contains(where: { abs($0 - 35) < 0.001 }), "不动的块的终点也要在")
    check(candidates.contains(0), "0 点永远是参考")
    check(candidates.contains(where: { abs($0 - 7) < 0.001 }), "播放头是参考")
    check(candidates.contains(where: { abs($0 - 35) < 0.001 }), "时间线末尾是参考")
}

do {
    // 形状块也能当参考点。
    var state = TimelineState()
    state.mainClips = [clip(start: 0, duration: 10)]
    state.shapes = [ShapeAnnotation(kind: .square, timelineStart: 3, duration: 2)]
    let candidates = TimelineSnap.candidates(in: state, moving: [], playhead: 0)
    check(candidates.contains(where: { abs($0 - 3) < 0.001 }), "形状的起点是参考")
    check(candidates.contains(where: { abs($0 - 5) < 0.001 }), "形状的终点是参考")
}

// MARK: - 8. 主轨插入位置：指示线指哪儿，松手就落哪儿
//
// 拖动中主轨不再当场重排，落点全靠那条指示线交代 —— 它一旦和 packMain 的结果
// 分叉，用户看到的就是「明明指在这儿，松手跳去了别处」。

/// 把 `moving` 按 `mainInsertion` 的结果插回去再 packMain，返回它落在哪。
func landedStart(rest: [EditClip], moving: EditClip, center: Double) -> (indicator: Double, landed: Double) {
    let insertion = TimelineSnap.mainInsertion(among: rest, moving: [moving], draggedCenter: center)
    var state = TimelineState()
    var clips = rest
    clips.insert(moving, at: insertion.index)
    state.mainClips = clips
    state.packMain()
    return (insertion.time, state.clip(with: moving.id)?.timelineStart ?? -1)
}

do {
    let a = clip(start: 0, duration: 10)
    let b = clip(start: 20, duration: 10)   // 被拖的块摘掉后，剩下的会被打包到 0/10
    let moving = clip(start: 10, duration: 6)

    for center in [0.0, 3.0, 4.9, 5.1, 12.0, 14.9, 15.1, 100.0] {
        let result = landedStart(rest: [a, b], moving: moving, center: center)
        checkClose(result.landed, result.indicator, "中心 \(center)：指示线和落点必须是同一个数")
    }

    checkClose(landedStart(rest: [a, b], moving: moving, center: 3).indicator, 0, "落在第一段前面")
    checkClose(landedStart(rest: [a, b], moving: moving, center: 12).indicator, 10, "落在两段中间")
    checkClose(landedStart(rest: [a, b], moving: moving, center: 100).indicator, 20, "落在最后")
}

do {
    // 转场会把两段叠掉一部分，游标必须跟 packMain 用同一套公式。
    var a = clip(start: 0, duration: 10)
    a.transitionAfter = .crossFade
    a.transitionDuration = 2
    let b = clip(start: 0, duration: 10)
    let moving = clip(start: 0, duration: 6)

    let result = landedStart(rest: [a, b], moving: moving, center: 100)
    checkClose(result.indicator, 18, "10 + 10 减掉 2 秒叠化 = 18")
    checkClose(result.landed, result.indicator, "有转场时指示线也不许说谎")
}

do {
    // 空主轨：插到 0。
    let result = TimelineSnap.mainInsertion(among: [], moving: [clip(start: 0, duration: 3)], draggedCenter: 42)
    check(result.index == 0, "空主轨的插入下标是 0")
    checkClose(result.time, 0, "空主轨插到 0")
}

// MARK: - 9. 复审反例：短块插进带转场的接缝，指示线不许说谎
//
// A(10s，其后 2s 转场) + B(10s) 中间插一段 1s 的 M：拿 rest 的**原**相邻关系
// 算是 8s，但插进去之后 A→M 的叠化被收紧到 min(2, 4.5, 0.45) = 0.45，
// M 实际落在 9.55s。指示线必须在插入之后的最终数组上算。

do {
    var a = clip(start: 0, duration: 10)
    a.transitionAfter = .crossFade
    a.transitionDuration = 2
    let b = clip(start: 0, duration: 10)
    let short = clip(start: 0, duration: 1)

    let result = landedStart(rest: [a, b], moving: short, center: 10)
    checkClose(result.indicator, 9.55, "短块插进带转场的接缝：指示线要算收紧后的叠化")
    checkClose(result.landed, result.indicator, "指示线和 packMain 的落点必须是同一个数")
}

do {
    // 多选整组插同一条缝：三段各 10s，把中间那段和最后那段一起拖到最前面。
    let a = clip(start: 0, duration: 10)
    let m1 = clip(start: 10, duration: 4)
    let m2 = clip(start: 20, duration: 6)
    let insertion = TimelineSnap.mainInsertion(among: [a], moving: [m1, m2], draggedCenter: 1)
    check(insertion.index == 0, "整组插到第一段前面")
    checkClose(insertion.time, 0, "整组的落点是第一个成员的起点")

    var state = TimelineState()
    state.mainClips = [m1, m2, a]
    state.packMain()
    checkClose(state.clip(with: m1.id)?.timelineStart ?? -1, 0, "组内相对顺序保持")
    checkClose(state.clip(with: m2.id)?.timelineStart ?? -1, 4, "组内第二段紧跟第一段")
    checkClose(state.clip(with: a.id)?.timelineStart ?? -1, 10, "被让开的块排在整组之后")
}

// MARK: - 10. 复审反例：整组落地不许逐块夹取
//
// 同轨 A=[0,5]、B=[5,10] 一起多选，拖 A 到 4。老写法逐块跑 clampedStart：
// A 被**旧位置的 B** 顶回 0，整组一动不动。碰撞只能看不动的块。

func member(_ id: UUID, _ start: Double, _ duration: Double, obstacles: [TimelineSpan] = []) -> ClipDragPlan.Member {
    ClipDragPlan.Member(
        id: id,
        span: TimelineSpan(start: start, end: start + duration),
        obstacles: obstacles
    )
}

do {
    let aID = UUID(), bID = UUID()
    let plan = ClipDragPlan(
        draggedID: aID,
        draggedSpan: TimelineSpan(start: 0, end: 5),
        // A 和 B 都在动 → 彼此都不是障碍，这条轨上没有别的块。
        members: [member(aID, 0, 5), member(bID, 5, 5)],
        candidates: [],
        magnet: nil
    )
    let result = plan.resolve(desiredDelta: 4, pixelsPerSecond: pps)
    checkClose(result.delta, 4, "整组该整体右移 4s，不该被组内伙伴顶回去")
}

do {
    // 同样两块，但右边 12s 处杵着一个**不动的**块：整组停在接触面。
    let aID = UUID(), bID = UUID()
    let wall = TimelineSpan(start: 12, end: 20)
    let plan = ClipDragPlan(
        draggedID: aID,
        draggedSpan: TimelineSpan(start: 0, end: 5),
        members: [member(aID, 0, 5, obstacles: [wall]), member(bID, 5, 5, obstacles: [wall])],
        candidates: [],
        magnet: nil
    )
    let result = plan.resolve(desiredDelta: 8, pixelsPerSecond: pps)
    checkClose(result.delta, 2, "B 的终点顶到 12 就停：整组只能挪 2s")
}

do {
    // 整组左移不许把最早的那个推到负时间。
    let aID = UUID(), bID = UUID()
    let plan = ClipDragPlan(
        draggedID: bID,
        draggedSpan: TimelineSpan(start: 5, end: 10),
        members: [member(aID, 2, 3), member(bID, 5, 5)],
        candidates: [],
        magnet: nil
    )
    let result = plan.resolve(desiredDelta: -10, pixelsPerSecond: pps)
    checkClose(result.delta, -2, "最早的那个卡在 0，整组就到底了")
}

// MARK: - 11. 复审反例：自由轨不许有第二套落地算法
//
// A=[0,5]、B=[10,15]，把 A 拖到 9s 松手。老写法拖动中显示 9、commit 里再跑一遍
// clampedStart 把它推到 5 —— 用户看到的位置、参考线和真实落点三方分叉。
// 现在拖动中就已经解析成最终落点了。

do {
    let aID = UUID()
    let plan = ClipDragPlan(
        draggedID: aID,
        draggedSpan: TimelineSpan(start: 0, end: 5),
        members: [member(aID, 0, 5, obstacles: [TimelineSpan(start: 10, end: 15)])],
        candidates: [],
        magnet: nil
    )
    let result = plan.resolve(desiredDelta: 9, pixelsPerSecond: pps)
    checkClose(result.delta, 5, "停在障碍的接触面（A 落在 5..10），不是弹回 0")
    // 同一份 resolution 就是落地用的那份：再解析一次结果不变（幂等）。
    let again = plan.resolve(desiredDelta: result.delta, pixelsPerSecond: pps)
    checkClose(again.delta, result.delta, "解析必须幂等，否则松手又会跳一次")
}

do {
    // 一开始就重叠的异常态（老工程）：不许把整组锁死在原地。
    let aID = UUID()
    let plan = ClipDragPlan(
        draggedID: aID,
        draggedSpan: TimelineSpan(start: 0, end: 5),
        members: [member(aID, 0, 5, obstacles: [TimelineSpan(start: 2, end: 8)])],
        candidates: [],
        magnet: nil
    )
    let result = plan.resolve(desiredDelta: 3, pixelsPerSecond: pps)
    checkClose(result.delta, 3, "本来就压着的块不设限，否则块彻底拖不动")
}

// MARK: - 12. 弹性尾部只给自由落点的轨道

do {
    let aID = UUID()
    let free = ClipDragPlan(
        draggedID: aID, draggedSpan: TimelineSpan(start: 0, end: 5),
        members: [member(aID, 0, 5)], candidates: [], magnet: nil
    )
    check(free.allowsFreeLanding, "画中画/音频/形状可以拖到内容之外")

    let magnet = ClipDragPlan(
        draggedID: aID, draggedSpan: TimelineSpan(start: 0, end: 5),
        members: [member(aID, 0, 5)], candidates: [],
        magnet: ClipDragPlan.Magnet(rest: [], moving: [])
    )
    check(!magnet.allowsFreeLanding, "磁吸主轨只能插进现有故事线，不给弹性尾部")
    check(magnet.resolve(desiredDelta: 3, pixelsPerSecond: pps).guides.isEmpty,
          "磁吸主轨不亮对齐线（落点由插空决定，亮了就是骗人）")
}

// MARK: - 13. 端到端落地：拖动中看到的 = 松手落到的
//
// 用真正的生产路径：ClipDragPlan.make → plan.resolve → TimelineState.applyDrag。
// 这三步就是 App 里跑的那三步（commitDrag 只是把第三步包进一次 perform）。

/// 跑一遍完整的拖动：返回落地后的状态。
///
/// **必须连 `perform` 那一步的磁吸重排一起跑**：`VideoEditProject.perform` 对
/// 任何改动都会在磁吸开着时再 `packMain()` 一次，只调 `applyDrag` 的话，被那次
/// 重排推翻的落点在自检里根本看不见（复审指出的假绿）。`magnetEnabled` 默认
/// 跟随 `magnetMain`，但拖的是非主轨块、磁吸却开着的场景要单独传 —— 那正是
/// 会踩坑的场景。
func performDrag(
    _ state: TimelineState,
    dragged: UUID,
    moving: Set<UUID>,
    desiredDelta: Double,
    magnetMain: Bool = false,
    magnetEnabled: Bool? = nil,
    crossTrack: TrackDropTarget? = nil,
    snapping: Bool = false
) -> (state: TimelineState, resolution: DragResolution) {
    let magnet = magnetEnabled ?? magnetMain
    let candidates = snapping
        ? TimelineSnap.candidates(in: state, moving: moving, playhead: 0)
        : []
    guard let plan = ClipDragPlan.make(
        in: state, draggedID: dragged, movingIDs: moving,
        candidates: candidates, magnetMain: magnetMain
    ) else {
        return (state, DragResolution(delta: 0, guides: [], mainInsertion: nil))
    }
    let resolution = plan.resolve(desiredDelta: desiredDelta, pixelsPerSecond: pps)
    var next = state
    next.applyDrag(plan, resolution: resolution, crossTrack: crossTrack, magnet: magnet)
    // 这就是 `perform` 的那一步。applyDrag 里已经排过一次，所以它必须是幂等的
    //（不幂等 = 松手之后位置还会再变一次，用户看到块自己跳一下）。
    if magnet { next.packMain() }
    return (next, resolution)
}

do {
    // 复审场景 1：同轨 A=[0,5]、B=[5,10] 一起多选，拖 A 到 4。
    // 老写法逐块 clampedStart → A 被旧位置的 B 顶回 0，整组一动不动。
    var state = TimelineState()
    let a = clip(start: 0, duration: 5)
    let b = clip(start: 5, duration: 5)
    state.overlayTracks = [EditLane(clips: [a, b])]

    let run = performDrag(state, dragged: a.id, moving: [a.id, b.id], desiredDelta: 4)
    checkClose(run.resolution.delta, 4, "整组该整体右移 4s")
    checkClose(run.state.clip(with: a.id)?.timelineStart ?? -1, 4, "A 落在 4")
    checkClose(run.state.clip(with: b.id)?.timelineStart ?? -1, 9, "B 保持相对错位落在 9")
}

do {
    // 复审场景 2：视频在主轨、链接音频在音轨，视频横向移动并**换轨**。
    // 老写法只 relocate 被拖的那个 → 音频留在旧时刻 = A/V 错位。
    var state = TimelineState()
    var video = clip(start: 4, duration: 5)
    var audio = clip(start: 4, duration: 5)
    video.linkGroup = UUID()
    audio.linkGroup = video.linkGroup
    state.mainClips = [video]
    state.audioTracks = [EditLane(clips: [audio])]

    let run = performDrag(
        state, dragged: video.id, moving: [video.id, audio.id],
        desiredDelta: 6, crossTrack: .newOverlayTop
    )
    let movedVideo = run.state.clip(with: video.id)
    let movedAudio = run.state.clip(with: audio.id)
    checkClose(movedVideo?.timelineStart ?? -1, 10, "视频跟着位移换到画中画轨")
    checkClose(movedAudio?.timelineStart ?? -1, 10, "链接音频必须跟到同一时刻，不许留在旧位置")
    check(run.state.overlayTracks.count == 1, "开了一条新的画中画轨")
    check(run.state.mainClips.isEmpty, "视频已经从主轨摘走")
    check(run.state.audioTracks.first?.clips.first?.id == audio.id, "音频留在自己的音轨上")
}

do {
    // 磁吸主轨 + 链接音频：音频按被拖块**实际**落点平移，不各夹各的。
    var state = TimelineState()
    var v1 = clip(start: 0, duration: 10)
    var a1 = clip(start: 0, duration: 10)
    v1.linkGroup = UUID()
    a1.linkGroup = v1.linkGroup
    let v2 = clip(start: 10, duration: 10)
    state.mainClips = [v1, v2]
    state.audioTracks = [EditLane(clips: [a1])]

    // 把第一段拖到最后面（中心越过 v2 的中点）。
    let run = performDrag(
        state, dragged: v1.id, moving: [v1.id, a1.id], desiredDelta: 15, magnetMain: true
    )
    checkClose(run.state.clip(with: v1.id)?.timelineStart ?? -1, 10, "磁吸把它插到第二段之后")
    checkClose(run.resolution.mainInsertion?.time ?? -1, 10, "指示线指的也是 10")
    checkClose(run.state.clip(with: a1.id)?.timelineStart ?? -1, 10, "链接音频跟到磁吸算出来的实际落点")
    check(run.state.mainClips.map(\.id) == [v2.id, v1.id], "主轨数组顺序 = 时间顺序")
}

do {
    // 非连续多选整组插同一条缝：A B C D，选 A 和 C，拖到最后。
    var state = TimelineState()
    let a = clip(start: 0, duration: 4)
    let b = clip(start: 4, duration: 4)
    let c = clip(start: 8, duration: 4)
    let d = clip(start: 12, duration: 4)
    state.mainClips = [a, b, c, d]

    let run = performDrag(
        state, dragged: c.id, moving: [a.id, c.id], desiredDelta: 20, magnetMain: true
    )
    check(run.state.mainClips.map(\.id) == [b.id, d.id, a.id, c.id],
          "整组挪到末尾并保持组内相对顺序（A 仍在 C 前）")
    checkClose(run.state.clip(with: a.id)?.timelineStart ?? -1, 8, "整组连续排在剩下两段之后")
    checkClose(run.state.clip(with: c.id)?.timelineStart ?? -1, 12, "组内第二块紧跟第一块，不留空隙")
}

do {
    // 拖组里的**第一块**和拖**最后一块**，落点应当一致（插的是同一条缝）。
    var state = TimelineState()
    let a = clip(start: 0, duration: 4)
    let m1 = clip(start: 4, duration: 4)
    let m2 = clip(start: 8, duration: 4)
    state.mainClips = [a, m1, m2]

    // 往左拖到底：块顶到时间线左端后位置就不动了，插空判定必须继续跟着手势走，
    // 否则怎么拖都插不到第一段前面（中心恰好压在 a 的中点上）。
    let byFirst = performDrag(state, dragged: m1.id, moving: [m1.id, m2.id], desiredDelta: -6, magnetMain: true)
    let byLast = performDrag(state, dragged: m2.id, moving: [m1.id, m2.id], desiredDelta: -10, magnetMain: true)
    check(byFirst.state.mainClips.map(\.id) == [m1.id, m2.id, a.id], "拖组内第一块：整组挪到最前")
    check(byLast.state.mainClips.map(\.id) == [m1.id, m2.id, a.id], "拖组内最后一块：结果相同")
    checkClose(byFirst.resolution.delta, -4, "渲染位移仍然夹在 0 以上（m1 起点 4）")
}

do {
    // 自由轨落地不许再跑第二套算法：拖到 9s（前方 10s 有块）→ 停在接触面 5s，
    // 而且**渲染时的落点**和**落地后的位置**必须是同一个数。
    var state = TimelineState()
    let a = clip(start: 0, duration: 5)
    let b = clip(start: 10, duration: 5)
    state.overlayTracks = [EditLane(clips: [a, b])]

    let run = performDrag(state, dragged: a.id, moving: [a.id], desiredDelta: 9)
    checkClose(run.resolution.delta, 5, "停在接触面")
    checkClose(run.state.clip(with: a.id)?.timelineStart ?? -1, 5, "落地位置 = 拖动中显示的位置")
}

do {
    // 障碍不含跟着动的伙伴（P1 的根因）。
    var state = TimelineState()
    let a = clip(start: 0, duration: 5)
    let b = clip(start: 5, duration: 5)
    state.overlayTracks = [EditLane(clips: [a, b])]
    guard let plan = ClipDragPlan.make(
        in: state, draggedID: a.id, movingIDs: [a.id, b.id], candidates: [], magnetMain: false
    ) else {
        check(false, "造不出 plan")
        exit(1)
    }
    let all = plan.members.flatMap(\.obstacles)
    check(all.isEmpty, "两块都在动 → 这条轨上没有障碍，得到 \(all)")

    guard let solo = ClipDragPlan.make(
        in: state, draggedID: a.id, movingIDs: [a.id], candidates: [], magnetMain: false
    ) else {
        check(false, "造不出 plan")
        exit(1)
    }
    check(solo.members.first?.obstacles == [TimelineSpan(start: 5, end: 10)], "只拖 A 时 B 是障碍")
}

// MARK: - 14. 跟随块只按实际 delta 平移，落地不许再「挤开」它
//
// 这一条专门让「commit 里再跑一遍 clampedStart」这种第二套算法露馅：磁吸把
// 视频挤到 10s，链接音频就必须跟到 10s —— 哪怕它自己那条音轨的 10s 处正杵着
// 别的块。A/V 同步比「顺手避开重叠」重要得多，逐块夹取只会让声画对不上。

do {
    var state = TimelineState()
    var v1 = clip(start: 0, duration: 10)
    var a1 = clip(start: 0, duration: 10)
    v1.linkGroup = UUID()
    a1.linkGroup = v1.linkGroup
    let v2 = clip(start: 10, duration: 10)
    let squatter = clip(start: 12, duration: 4)   // 音轨上占着位子的另一段
    state.mainClips = [v1, v2]
    state.audioTracks = [EditLane(clips: [a1, squatter])]

    let run = performDrag(
        state, dragged: v1.id, moving: [v1.id, a1.id], desiredDelta: 15, magnetMain: true
    )
    checkClose(run.state.clip(with: v1.id)?.timelineStart ?? -1, 10, "磁吸把视频插到第二段之后")
    checkClose(run.state.clip(with: a1.id)?.timelineStart ?? -1, 10,
               "链接音频跟到同一时刻 —— 被占着也不许挤开，那会当场毁掉声画同步")
    checkClose(run.state.clip(with: squatter.id)?.timelineStart ?? -1, 12, "占位的那段自己不动")
}

// MARK: - 15. 框选：相交即选中、跳过隐藏轨、最小宽度和画出来的一致
//
// 长期约束见 docs/architecture/timeline-drag-gestures.md 的「框选」一节。

do {
    let a = UUID(), b = UUID(), tiny = UUID(), shape = UUID(), cue = UUID(), hidden = UUID()
    // 24 点/秒：A=[0,5]→[0,120]，B=[10,15]→[240,360]，tiny 是 0.05 秒的碎块。
    let rows = [
        TimelineMarquee.Row(minY: 0, maxY: 40, items: [
            TimelineMarquee.Item(id: a, start: 0, end: 5, kind: .clip),
            TimelineMarquee.Item(id: b, start: 10, end: 15, kind: .clip),
            TimelineMarquee.Item(id: tiny, start: 20, end: 20.05, kind: .clip),
        ]),
        TimelineMarquee.Row(minY: 46, maxY: 66, items: [
            TimelineMarquee.Item(id: shape, start: 3, end: 4, kind: .shape),
        ]),
        TimelineMarquee.Row(minY: 72, maxY: 86, items: [
            TimelineMarquee.Item(id: cue, start: 1, end: 2, kind: .subtitleCue),
        ]),
        TimelineMarquee.Row(minY: 92, maxY: 132, isHidden: true, items: [
            TimelineMarquee.Item(id: hidden, start: 0, end: 5, kind: .clip),
        ]),
    ]

    // 相交即选中：框只压住 A 右边一丁点，也算中。要求「整个框住」的话，
    // 放大之后选一段长素材得把框拖出好几屏。
    var hit = TimelineMarquee.hits(
        rect: CGRect(x: 118, y: 10, width: 4, height: 4), rows: rows, pixelsPerSecond: 24
    )
    checkEqual(hit.clips, [a], "框碰到块的边就算选中（相交即选）")

    // 横着扫一条零高度的细线：一整排都该中。
    hit = TimelineMarquee.hits(
        rect: CGRect(x: 0, y: 20, width: 400, height: 0), rows: rows, pixelsPerSecond: 24
    )
    checkEqual(hit.clips, [a, b], "横扫一条细线选中一整排")
    check(hit.shapes.isEmpty && hit.cues.isEmpty, "细线只在自己那一行里选，不许穿到别的行")

    // 三类一次框中。
    hit = TimelineMarquee.hits(
        rect: CGRect(x: 0, y: 0, width: 400, height: 90), rows: rows, pixelsPerSecond: 24
    )
    checkEqual(hit.clips, [a, b], "整片框：剪辑")
    checkEqual(hit.shapes, [shape], "整片框：形状")
    checkEqual(hit.cues, [cue], "整片框：字幕 cue")

    // 隐藏轨整轨跳过：看不见的东西被框走、跟着一起被拖被删是纯粹的惊吓。
    hit = TimelineMarquee.hits(
        rect: CGRect(x: 0, y: 0, width: 400, height: 200), rows: rows, pixelsPerSecond: 24
    )
    check(!hit.clips.contains(hidden), "隐藏轨上的块不许被框中")

    // 最小宽度：0.05 秒的碎块按真实时长只有 1.2 点宽，用户明明框过了那个可见的
    // 小方块却什么都没选中 —— 判定必须和**画出来的**宽度一致。
    let tinyX = 20 * 24.0
    hit = TimelineMarquee.hits(
        rect: CGRect(x: tinyX + 3, y: 10, width: 1, height: 4), rows: rows, pixelsPerSecond: 24
    )
    checkEqual(hit.clips, [tiny], "碎块按画出来的最小宽度判定（\(TimelineMarquee.clipMinimumWidth) 点）")

    // 空框（点一下空白）什么都不选。
    hit = TimelineMarquee.hits(
        rect: CGRect(x: 200, y: 10, width: 0, height: 0), rows: rows, pixelsPerSecond: 24
    )
    check(hit.isEmpty, "空白处的空框什么都不选")

    // 会话：加选在原有选择上并集，不加选则整个替换。
    var session = TimelineMarquee.Session(
        anchor: CGPoint(x: 0, y: 10), additive: true,
        base: TimelineMarquee.Hit(clips: [b], shapes: [], cues: [])
    )
    session.update(current: CGPoint(x: 120, y: 30), rows: rows, pixelsPerSecond: 24)
    checkEqual(session.hit.clips, [a, b], "⌘/⇧ 拖框 = 在原有选择上加选")

    session = TimelineMarquee.Session(
        anchor: CGPoint(x: 0, y: 10), additive: false,
        base: TimelineMarquee.Hit(clips: [b], shapes: [], cues: [])
    )
    session.update(current: CGPoint(x: 120, y: 30), rows: rows, pixelsPerSecond: 24)
    checkEqual(session.hit.clips, [a], "空手拖框 = 丢掉旧选择")

    // 往左上方向拉的框（current 在 anchor 左边）同样要成立。
    session = TimelineMarquee.Session(anchor: CGPoint(x: 400, y: 60), additive: false, base: .init())
    session.update(current: CGPoint(x: 0, y: 0), rows: rows, pixelsPerSecond: 24)
    // x 只到 400 点（≈16.7 秒），20 秒处的碎块够不着。
    checkEqual(session.hit.clips, [a, b], "反向拉框一样算")
    checkEqual(session.hit.shapes, [shape], "反向拉框跨行一样算")
}

// MARK: - 16. 框选之后整组一起移动：剪辑 + 形状 + 字幕 cue 同一个 delta
//
// 三类改的字段不同（剪辑/形状改 timelineStart，cue 要两轨同步），但**位移只有
// 一个**。谁自己算一份，谁就会在磁吸那条分支上和别人分叉。

do {
    var state = TimelineState()
    let c = clip(start: 0, duration: 5)
    state.mainClips = [c]
    var shape = ShapeAnnotation(kind: .rectangle, timelineStart: 1, width: 0.3, height: 0.2)
    shape.duration = 2
    state.shapes = [shape]
    var doc = SubtitleDocumentModel()
    let cueID = UUID()
    doc.cues = [SubtitleCue(id: cueID, index: 1, start: 1, end: 3, text: "hi")]
    state.subtitle = doc
    var companion = SubtitleCompanion()
    var translation = SubtitleDocumentModel()
    translation.cues = [SubtitleCue(id: cueID, index: 1, start: 1, end: 3, text: "你好")]
    companion.translation = translation
    state.subtitleCompanion = companion

    guard let base = ClipDragPlan.make(
        in: state, draggedID: c.id, movingIDs: [c.id], candidates: [], magnetMain: false
    ) else {
        check(false, "造不出 plan")
        exit(1)
    }
    let plan = base.adding(
        shapes: [(id: shape.id, span: TimelineSpan(start: 1, end: 3))],
        cues: [(id: cueID, span: TimelineSpan(start: 1, end: 3))]
    )
    let resolution = plan.resolve(desiredDelta: 4, pixelsPerSecond: pps)
    var next = state
    next.applyDrag(plan, resolution: resolution, crossTrack: nil, magnet: false)

    checkClose(next.clip(with: c.id)?.timelineStart ?? -1, 4, "剪辑挪了 4 秒")
    checkClose(next.shapes.first?.timelineStart ?? -1, 5, "形状跟着挪同一个 delta")
    checkClose(next.subtitle?.cues.first?.start ?? -1, 5, "原文 cue 跟着挪")
    checkClose(next.subtitle?.cues.first?.end ?? -1, 7, "cue 时长不变")
    checkClose(next.subtitleCompanion?.translation?.cues.first?.start ?? -1, 5,
               "译文轨同 ID 同时间（两轨必须同步，否则烧录时译文对不上口型）")

    // 下界是**整组**的：最早的成员顶到 0 就整组停下，不许各夹各的
    //（各夹各的会把选中项之间的相对错位当场压扁）。
    let back = plan.resolve(desiredDelta: -100, pixelsPerSecond: pps)
    var pulled = state
    pulled.applyDrag(plan, resolution: back, crossTrack: nil, magnet: false)
    checkClose(pulled.clip(with: c.id)?.timelineStart ?? -1, 0, "剪辑顶到 0")
    checkClose(pulled.shapes.first?.timelineStart ?? -1, 1, "形状保持原来的相对错位")
    checkClose(pulled.subtitle?.cues.first?.start ?? -1, 1, "cue 保持原来的相对错位")
}

// MARK: - 17. 磁吸主轨插空时，跟随的形状/cue 按**实际**落点走
//
// 和第 14 节同一个道理，只是跟随的不是链接音频而是框选来的形状与字幕：
// 位移在这条分支上会被 packMain 改写，第二次平移必须是幂等的绝对落点，
// 不是在已经挪过的值上再叠一次（叠加式接口在这里就是双倍位移）。

do {
    var state = TimelineState()
    let a = clip(start: 0, duration: 10)
    let b = clip(start: 10, duration: 10)
    state.mainClips = [a, b]
    var shape = ShapeAnnotation(kind: .rectangle, timelineStart: 0, width: 0.3, height: 0.2)
    shape.duration = 2
    state.shapes = [shape]
    var doc = SubtitleDocumentModel()
    let cueID = UUID()
    doc.cues = [SubtitleCue(id: cueID, index: 1, start: 0, end: 2, text: "hi")]
    state.subtitle = doc

    guard let base = ClipDragPlan.make(
        in: state, draggedID: a.id, movingIDs: [a.id], candidates: [], magnetMain: true
    ) else {
        check(false, "造不出 plan")
        exit(1)
    }
    let plan = base.adding(
        shapes: [(id: shape.id, span: TimelineSpan(start: 0, end: 2))],
        cues: [(id: cueID, span: TimelineSpan(start: 0, end: 2))]
    )
    let resolution = plan.resolve(desiredDelta: 15, pixelsPerSecond: pps)
    var next = state
    next.applyDrag(plan, resolution: resolution, crossTrack: nil, magnet: true)

    checkClose(next.clip(with: a.id)?.timelineStart ?? -1, 10, "磁吸把 A 插到 B 之后")
    checkClose(next.shapes.first?.timelineStart ?? -1, 10,
               "形状按实际落点跟过去，不是按手势想要的 15")
    checkClose(next.subtitle?.cues.first?.start ?? -1, 10,
               "cue 同理 —— 写第二次必须幂等，否则是双倍位移")
    checkClose(next.subtitle?.cues.first?.end ?? -1, 12, "cue 时长仍然不变")
}

// MARK: - 18. 复审：跨轨到岸被「挤开」时，伙伴要跟着实际落点走

do {
    // 视频 + 链接音频一起拖进**已经有占位**的画中画轨：到岸后 clampedStart 会把
    // 视频让开占位，音频必须跟到同一个实际落点。老写法只让开被拖的那个，音频
    // 停在第 1 步的位置上 —— 当场 A/V 错位（复审第 1 条）。
    var state = TimelineState()
    var video = clip(start: 0, duration: 5)
    var audio = clip(start: 0, duration: 5)
    video.linkGroup = UUID()
    audio.linkGroup = video.linkGroup
    let blocker = clip(start: 6, duration: 5)
    state.mainClips = [video]
    state.overlayTracks = [EditLane(clips: [blocker])]
    state.audioTracks = [EditLane(clips: [audio])]

    // 想落到 6（正压在占位上）→ 让到占位之后 = 11。
    let run = performDrag(
        state, dragged: video.id, moving: [video.id, audio.id],
        desiredDelta: 6, crossTrack: .overlay(0)
    )
    let landedVideo = run.state.clip(with: video.id)?.timelineStart ?? -1
    let landedAudio = run.state.clip(with: audio.id)?.timelineStart ?? -1
    checkClose(landedVideo, 11, "视频让开目标轨上的占位，落在它后面")
    checkClose(landedAudio, landedVideo, "链接音频跟到**实际**落点，不是停在 6")
    check(run.state.overlayTracks.first?.clips.count == 2, "两段都在这条画中画轨上")
}

// MARK: - 19. 复审：磁吸开着时主轨块不参与整组平移

do {
    // 主轨块的位置在磁吸下只由 packMain 决定。拖一个音频块、而主轨块也在选中
    // 集合里时，主轨块既不该跟着画、也不该被平移 —— 平了也会被 perform 那次
    // 重排排回去，等于拖动中骗了用户一路（复审第 1 条的后半段）。
    var state = TimelineState()
    let v = clip(start: 0, duration: 10)
    let a = clip(start: 0, duration: 5)
    state.mainClips = [v]
    state.audioTracks = [EditLane(clips: [a])]

    let ids = state.draggingClipIDs(
        seed: [a.id, v.id], linkage: false, magnetPinsMainTrack: true
    )
    check(ids == [a.id], "磁吸下拖非主轨块：主轨成员被剔除，只剩音频")
    check(
        state.draggingClipIDs(seed: [a.id, v.id], linkage: false, magnetPinsMainTrack: false)
            == [a.id, v.id],
        "磁吸关掉（或拖的就是主轨块）时一个都不剔"
    )

    // 端到端：整条路径跑完（含 perform 那次重排），主轨块必须一动没动。
    let run = performDrag(
        state, dragged: a.id, moving: ids, desiredDelta: 4, magnetEnabled: true
    )
    checkClose(run.state.clip(with: a.id)?.timelineStart ?? -1, 4, "音频落在 4")
    checkClose(run.state.clip(with: v.id)?.timelineStart ?? -1, 0,
               "主轨块留在 packMain 给的位置，不会先动一下再被排回去")
}

// MARK: - 20. 复审：多选时每一个成员的链接组都要展开

do {
    // 框选 A、B 两段，各自都有分离出来的音频。拖 A 时只展开 A 的链接组的话，
    // B 会动、B 的音频不动 —— 直接 A/V 错位（复审第 2 条）。
    var state = TimelineState()
    var a = clip(start: 0, duration: 4)
    var aAudio = clip(start: 0, duration: 4)
    var b = clip(start: 10, duration: 4)
    var bAudio = clip(start: 10, duration: 4)
    a.linkGroup = UUID()
    aAudio.linkGroup = a.linkGroup
    b.linkGroup = UUID()
    bAudio.linkGroup = b.linkGroup
    state.overlayTracks = [EditLane(clips: [a, b])]
    state.audioTracks = [EditLane(clips: [aAudio, bAudio])]

    let ids = state.draggingClipIDs(
        seed: [a.id, b.id], linkage: true, magnetPinsMainTrack: false
    )
    check(ids == [a.id, b.id, aAudio.id, bAudio.id],
          "两段的链接音频都要在名单里（实得 \(ids.count) 个）")

    let run = performDrag(state, dragged: a.id, moving: ids, desiredDelta: 3)
    checkClose(run.state.clip(with: b.id)?.timelineStart ?? -1, 13, "B 跟着走")
    checkClose(run.state.clip(with: bAudio.id)?.timelineStart ?? -1, 13,
               "B 的链接音频也必须跟着走，不许留在 10")
    check(
        state.draggingClipIDs(seed: [a.id, b.id], linkage: false, magnetPinsMainTrack: false)
            == [a.id, b.id],
        "关掉链接开关时一个伙伴都不带"
    )
}

// MARK: - 21. 复审：框选纵向只认画出来的块，不认整行的留白

do {
    // 字幕行高 22，cue 块只有 14、上下各留 4。框从留白里扫过、一个像素都没碰到
    // 块时不许选中（复审第 4 条）。行模型由视图按同一批常量喂进来，这里直接
    // 按那批常量造。
    let cueID = UUID()
    let rowTop = 100.0
    let band = TimelineMarquee.Row(
        minY: rowTop + TimelineMarquee.cueTopInset,
        maxY: rowTop + TimelineMarquee.cueTopInset + TimelineMarquee.cueHeight,
        items: [TimelineMarquee.Item(id: cueID, start: 0, end: 2, kind: .subtitleCue)]
    )
    // 只扫过顶部那 4pt 留白（100…103）。
    let missTop = TimelineMarquee.hits(
        rect: CGRect(x: 0, y: rowTop, width: 200, height: 3), rows: [band], pixelsPerSecond: 10
    )
    check(missTop.cues.isEmpty, "只碰到行顶留白：不选中")
    // 扫过块底之下的留白（118…122）。
    let missBottom = TimelineMarquee.hits(
        rect: CGRect(x: 0, y: rowTop + 18.5, width: 200, height: 3), rows: [band], pixelsPerSecond: 10
    )
    check(missBottom.cues.isEmpty, "只碰到行底留白：不选中")
    // 真碰到块。
    let hit = TimelineMarquee.hits(
        rect: CGRect(x: 0, y: rowTop + 10, width: 200, height: 2), rows: [band], pixelsPerSecond: 10
    )
    check(hit.cues == [cueID], "碰到块本体：选中")
}

// MARK: - 收尾

print("TimelineSnap checks: \(checks) 项，失败 \(failures) 项")
if failures > 0 {
    exit(1)
}
print("OK")
