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
// 四类改的字段不同（剪辑/形状/文字改 timelineStart，cue 要两轨同步），但**位移
// 只有一个**。谁自己算一份，谁就会在磁吸那条分支上和别人分叉。

do {
    var state = TimelineState()
    let c = clip(start: 0, duration: 5)
    state.mainClips = [c]
    var shape = ShapeAnnotation(kind: .rectangle, timelineStart: 1, width: 0.3, height: 0.2)
    shape.duration = 2
    state.shapes = [shape]
    let textOverlay = TextOverlay(text: "hi", timelineStart: 1, duration: 2)
    state.textOverlays = [textOverlay]
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
        texts: [(id: textOverlay.id, span: TimelineSpan(start: 1, end: 3))],
        cues: [(id: cueID, span: TimelineSpan(start: 1, end: 3))]
    )
    let resolution = plan.resolve(desiredDelta: 4, pixelsPerSecond: pps)
    var next = state
    next.applyDrag(plan, resolution: resolution, crossTrack: nil, magnet: false)

    checkClose(next.clip(with: c.id)?.timelineStart ?? -1, 4, "剪辑挪了 4 秒")
    checkClose(next.shapes.first?.timelineStart ?? -1, 5, "形状跟着挪同一个 delta")
    checkClose(next.textOverlays.first?.timelineStart ?? -1, 5, "文字跟着挪同一个 delta")
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
        texts: [],
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

// MARK: - 22. 二轮复审：从主轨跨轨时，被排走的主轨块要带上自己的链接音频

do {
    // 主轨 A、B 都选中，B 有分离出来的音频；把 A 拖到画中画轨（**磁吸开着**，
    // 那才是 App 的默认）。磁吸会让主轨合拢、B 被排到 0，B 的音频若还按整组的
    // delta 走就停在 5 —— 声画错开一整段。声画同步高于「整组同一位移」。
    var state = TimelineState()
    let a = clip(start: 0, duration: 5)
    var b = clip(start: 5, duration: 5)
    var bAudio = clip(start: 5, duration: 5)
    b.linkGroup = UUID()
    bAudio.linkGroup = b.linkGroup
    state.mainClips = [a, b]
    state.audioTracks = [EditLane(clips: [bAudio])]

    let run = performDrag(
        state, dragged: a.id, moving: [a.id, b.id, bAudio.id],
        desiredDelta: 0, magnetMain: true, crossTrack: .newOverlayTop
    )
    check(run.state.mainClips.map(\.id) == [b.id], "A 已经搬去画中画轨，主轨只剩 B")
    checkClose(run.state.clip(with: b.id)?.timelineStart ?? -1, 0, "磁吸把 B 合拢到 0")
    checkClose(run.state.clip(with: bAudio.id)?.timelineStart ?? -1, 0,
               "B 的链接音频必须跟着 B 走到 0，不许停在 5")
}

// MARK: - 23. 二轮复审：跨轨向左让位不许突破整组下界

do {
    // 被拖块在 10s、混选的 cue 在 0s，目标轨 [12,17] 有占位，纯纵向换轨。
    // 往左让会把整组推到 -3：cue 被单独夹在 0，相对错位当场压扁。
    // 正确做法是改往右侧躲，整组仍然共用一个位移。
    var state = TimelineState()
    let dragged = clip(start: 10, duration: 5)
    let blocker = clip(start: 12, duration: 5)
    state.mainClips = [dragged]
    state.overlayTracks = [EditLane(clips: [blocker])]
    var doc = SubtitleDocumentModel()
    let cueID = UUID()
    doc.cues = [SubtitleCue(id: cueID, index: 1, start: 0, end: 2, text: "hi")]
    state.subtitle = doc

    guard let base = ClipDragPlan.make(
        in: state, draggedID: dragged.id, movingIDs: [dragged.id],
        candidates: [], magnetMain: false
    ) else {
        print("FAIL 造不出计划"); exit(1)
    }
    let plan = base.adding(
        shapes: [], texts: [], cues: [(id: cueID, span: TimelineSpan(start: 0, end: 2))]
    )
    checkClose(plan.groupLowerDelta, 0, "整组下界由起点最小的成员（cue 在 0s）决定")

    let resolution = plan.resolve(desiredDelta: 0, pixelsPerSecond: pps)
    var next = state
    next.applyDrag(plan, resolution: resolution, crossTrack: .overlay(0), magnet: false)

    let landed = next.clip(with: dragged.id)?.timelineStart ?? -1
    let cueStart = next.subtitle?.cues.first?.start ?? -1
    checkClose(landed, 17, "越界的左侧不能用，改从占位右边落下")
    checkClose(cueStart, landed - 10, "cue 与被拖块仍然是同一个位移")
    check(cueStart >= 0, "cue 没有被单独夹在 0 上")
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

// MARK: - 24. 同轨越过障碍：指针过了障碍就落到另一侧（2026-08-23 起）
//
// 以前障碍是墙（把块拖到主轨中间的间隙必须先挪去画中画再挪回来）。现在
// `fittedDelta` 按「最近的合法间隙」解析：指针没越过障碍时仍停在这一侧的
// 接触面（老手感），越过了就直接落到另一侧 —— 块画在哪儿就落在哪儿。

do {
    let aID = UUID()
    let plan = ClipDragPlan(
        draggedID: aID,
        draggedSpan: TimelineSpan(start: 0, end: 5),
        members: [member(aID, 0, 5, obstacles: [TimelineSpan(start: 10, end: 15)])],
        candidates: [],
        magnet: nil
    )
    checkClose(plan.resolve(desiredDelta: 9, pixelsPerSecond: pps).delta, 5,
               "指针在障碍近侧：仍停在这一侧的接触面（老行为不变）")
    checkClose(plan.resolve(desiredDelta: 12, pixelsPerSecond: pps).delta, 15,
               "指针过了障碍远侧：落到另一侧的接触面（B 的终点）")
    checkClose(plan.resolve(desiredDelta: 30, pixelsPerSecond: pps).delta, 30,
               "彻底越过之后是自由落点")
    checkClose(plan.resolve(desiredDelta: 15, pixelsPerSecond: pps).delta, 15,
               "落点再解析一次不变（幂等，松手不跳）")
}

do {
    // 装不下的间隙 = 塞进去 + 右侧让位（详见 §27）：5 秒的块对准 B=[10,12] 和
    // C=[15,20] 之间那 3 秒的缝，落在缝的起点 12，让位 5-3=2 秒。
    let aID = UUID()
    let tight = ClipDragPlan(
        draggedID: aID,
        draggedSpan: TimelineSpan(start: 0, end: 5),
        members: [member(aID, 0, 5, obstacles: [
            TimelineSpan(start: 10, end: 12), TimelineSpan(start: 15, end: 20)
        ])],
        candidates: [],
        magnet: nil
    )
    let squeezed = tight.resolve(desiredDelta: 11, pixelsPerSecond: pps)
    checkClose(squeezed.delta, 12, "落在装不下的间隙起点")
    checkClose(squeezed.sameTrackPush?.at ?? -1, 12, "让位从间隙起点开始")
    checkClose(squeezed.sameTrackPush?.amount ?? -1, 2, "腾出差的那 2 秒")

    // 正好 5 秒的间隙能精确嵌进去（两段禁区只在端点相接，接点是合法落点）。
    let exact = ClipDragPlan(
        draggedID: aID,
        draggedSpan: TimelineSpan(start: 0, end: 5),
        members: [member(aID, 0, 5, obstacles: [
            TimelineSpan(start: 10, end: 13), TimelineSpan(start: 18, end: 20)
        ])],
        candidates: [],
        magnet: nil
    )
    checkClose(exact.resolve(desiredDelta: 13.5, pixelsPerSecond: pps).delta, 13,
               "5 秒的块正好嵌进 5 秒的间隙")
}

do {
    // 端到端：磁吸关掉的主轨，把末尾的块直接拖进前面两块之间的间隙 ——
    // 这正是「以前必须先挪去画中画再挪回来」的那个场景。
    var state = TimelineState()
    let a = clip(start: 0, duration: 5)
    let b = clip(start: 12, duration: 5)
    let tail = clip(start: 20, duration: 6)
    state.mainClips = [a, b, tail]

    let run = performDrag(state, dragged: tail.id, moving: [tail.id], desiredDelta: -14)
    checkClose(run.state.clip(with: tail.id)?.timelineStart ?? -1, 6,
               "末尾的块直接落进中间的间隙（6 秒块落在 [5,12] 间隙的就近接触面）")
    check(run.state.mainClips.map(\.id) == [a.id, tail.id, b.id],
          "主轨数组顺序跟着时间顺序走")
}

// MARK: - 25. 磁吸插空的占位框：起点和宽度都来自最终数组

do {
    let a = clip(start: 0, duration: 10)
    let b = clip(start: 20, duration: 10)
    let moving = clip(start: 40, duration: 6)
    let insertion = TimelineSnap.mainInsertion(among: [a, b], moving: [moving], draggedCenter: 12)
    checkClose(insertion.time, 10, "插在两段中间")
    checkClose(insertion.duration, 6, "占位框和素材等长")

    let m2 = clip(start: 50, duration: 4)
    let group = TimelineSnap.mainInsertion(among: [a, b], moving: [moving, m2], draggedCenter: 12)
    checkClose(group.duration, 10, "多选整组：占位框 = 组内各段之和（无转场时）")

    let empty = TimelineSnap.mainInsertion(among: [a], moving: [], draggedCenter: 0)
    checkClose(empty.duration, 0, "没有主轨成员在动：宽度为 0，不画框")
}

// MARK: - 26. 跨轨占位框不许说谎：预览的落点 = 松手后的落点
//
// 预览（crossTrackLandingSpan）和落地（relocateClip）共用 avoidingOverlap /
// mainInsertion 这两份核心。这里端到端对表：框指哪儿，松手就落哪儿。

do {
    // 自由落点：目标画中画轨 [6,11] 有占位，预览和落地都该让到 11。
    var state = TimelineState()
    let dragged = clip(start: 0, duration: 5)
    let blocker = clip(start: 6, duration: 5)
    state.mainClips = [dragged]
    state.overlayTracks = [EditLane(clips: [blocker])]

    guard let plan = ClipDragPlan.make(
        in: state, draggedID: dragged.id, movingIDs: [dragged.id],
        candidates: [], magnetMain: false
    ) else { print("FAIL 造不出计划"); exit(1) }
    let resolution = plan.resolve(desiredDelta: 6, pixelsPerSecond: pps)
    let ghost = state.crossTrackLandingSpan(
        plan: plan, delta: resolution.delta, target: .overlay(0), magnet: false
    )
    var next = state
    next.applyDrag(plan, resolution: resolution, crossTrack: .overlay(0), magnet: false)
    checkClose(ghost.start, next.clip(with: dragged.id)?.timelineStart ?? -1,
               "占位框指哪儿，松手就落哪儿")
    checkClose(ghost.duration, 5, "占位框和素材等长")
}

do {
    // 磁吸主轨：从画中画拖回主轨，占位框 = mainInsertion 的缝（含宽度）。
    var state = TimelineState()
    let a = clip(start: 0, duration: 10)
    let b = clip(start: 10, duration: 10)
    let dragged = clip(start: 2, duration: 6)
    state.mainClips = [a, b]
    state.overlayTracks = [EditLane(clips: [dragged])]

    guard let plan = ClipDragPlan.make(
        in: state, draggedID: dragged.id, movingIDs: [dragged.id],
        candidates: [], magnetMain: false
    ) else { print("FAIL 造不出计划"); exit(1) }
    let resolution = plan.resolve(desiredDelta: 10, pixelsPerSecond: pps)
    let ghost = state.crossTrackLandingSpan(
        plan: plan, delta: resolution.delta, target: .main, magnet: true
    )
    var next = state
    next.applyDrag(plan, resolution: resolution, crossTrack: .main, magnet: true)
    next.packMain()   // perform 之后那一次重排（幂等）
    checkClose(ghost.start, next.clip(with: dragged.id)?.timelineStart ?? -1,
               "磁吸主轨的占位框也不许说谎")
    checkClose(ghost.duration, 6, "宽度 = 素材时长")
}

do {
    // 开新轨（没有障碍）：占位框就是「起点 + delta」夹在下界上。
    var state = TimelineState()
    let dragged = clip(start: 3, duration: 4)
    state.mainClips = [dragged]

    guard let plan = ClipDragPlan.make(
        in: state, draggedID: dragged.id, movingIDs: [dragged.id],
        candidates: [], magnetMain: false
    ) else { print("FAIL 造不出计划"); exit(1) }
    let resolution = plan.resolve(desiredDelta: 5, pixelsPerSecond: pps)
    let ghost = state.crossTrackLandingSpan(
        plan: plan, delta: resolution.delta, target: .newOverlayTop, magnet: false
    )
    var next = state
    next.applyDrag(plan, resolution: resolution, crossTrack: .newOverlayTop, magnet: false)
    checkClose(ghost.start, next.clip(with: dragged.id)?.timelineStart ?? -1,
               "开新轨的占位框 = 落地位置")
}

// MARK: - 27. 塞进装不下的间隙：落在间隙起点，右侧让位（2026-08-23，用户反馈）
//
// 场景：主轨排满、只有一块比素材短的间隙，磁吸关着。老逻辑「装不下不给进」
// 让块彻底动弹不得，用户只能借道画中画（还会落成重叠）。现在指针中心悬在
// 这种间隙上就落在间隙起点，右侧内容自动右移腾出差的那截 —— 只推本轨，
// 与定格插入同款范围。

do {
    // L=[0,10]、间隙 [10,15]（5s）、R=[15,25]、被拖的 D=[25,31]（6s，装不下）。
    var state = TimelineState()
    let l = clip(start: 0, duration: 10)
    let r = clip(start: 15, duration: 10)
    let d = clip(start: 25, duration: 6)
    state.mainClips = [l, r, d]

    // 中心对准间隙（12.5s）：desired = 12.5 - (25 + 3) = -15.5。
    let run = performDrag(state, dragged: d.id, moving: [d.id], desiredDelta: -15.5)
    checkClose(run.resolution.delta, -15, "落点 = 间隙起点 10（delta -15）")
    checkClose(run.resolution.sameTrackPush?.amount ?? -1, 1, "要腾 6-5=1 秒")
    checkClose(run.state.clip(with: d.id)?.timelineStart ?? -1, 10, "D 落在间隙起点")
    checkClose(run.state.clip(with: r.id)?.timelineStart ?? -1, 16, "R 让位 1 秒")
    checkClose(run.state.clip(with: l.id)?.timelineStart ?? -1, 0, "间隙左边的不动")
    check(run.state.mainClips.map(\.id) == [l.id, d.id, r.id], "数组顺序 = 时间顺序")
}

do {
    // 排满 + 小间隙的「彻底拖不动」场景：D 被夹在中间也一样塞得进。
    var state = TimelineState()
    let a = clip(start: 0, duration: 8)
    let gapAfterA = 4.0   // 间隙 [8,12]，4 秒
    let b = clip(start: 12, duration: 8)
    let d = clip(start: 20, duration: 6)   // 紧贴 B，6 秒 > 4 秒
    let e = clip(start: 26, duration: 8)   // 紧贴 D
    state.mainClips = [a, b, d, e]
    _ = gapAfterA

    // 中心对准间隙（10s）：desired = 10 - 23 = -13。
    let run = performDrag(state, dragged: d.id, moving: [d.id], desiredDelta: -13)
    checkClose(run.state.clip(with: d.id)?.timelineStart ?? -1, 8, "被夹住的块也能塞进间隙")
    checkClose(run.state.clip(with: b.id)?.timelineStart ?? -1, 14, "B 让位 2 秒")
    checkClose(run.state.clip(with: e.id)?.timelineStart ?? -1, 28, "D 右边的 E 也顺推 2 秒")
    checkClose(run.state.clip(with: a.id)?.timelineStart ?? -1, 0, "间隙左边的 A 不动")
}

do {
    // 间隙装得下（≥ 素材）就走普通间隙落点，不触发让位。
    var state = TimelineState()
    let l = clip(start: 0, duration: 10)
    let r = clip(start: 18, duration: 10)   // 间隙 [10,18] = 8s
    let d = clip(start: 28, duration: 6)
    state.mainClips = [l, r, d]

    let run = performDrag(state, dragged: d.id, moving: [d.id], desiredDelta: -17)
    check(run.resolution.sameTrackPush == nil, "装得下的间隙不用腾位置")
    checkClose(run.state.clip(with: r.id)?.timelineStart ?? -1, 18, "邻居一动不动")
    let landed = run.state.clip(with: d.id)?.timelineStart ?? -1
    check(landed >= 10 - 0.001 && landed <= 12 + 0.001, "块落在间隙里，实得 \(landed)")
}

do {
    // 跨轨落地时忽略让位：块去了别的轨，本轨不许平白多出一个洞。
    var state = TimelineState()
    let l = clip(start: 0, duration: 10)
    let r = clip(start: 15, duration: 10)
    let d = clip(start: 25, duration: 6)
    state.mainClips = [l, r, d]

    let run = performDrag(
        state, dragged: d.id, moving: [d.id], desiredDelta: -15.5,
        crossTrack: .newOverlayTop
    )
    checkClose(run.state.clip(with: r.id)?.timelineStart ?? -1, 15,
               "跨轨走了就不推本轨的邻居")
    check(run.state.overlayTracks.count == 1, "块落在新画中画轨上")
}

do {
    // 音频轨同样适用（规则挂在自由落点模式上，不挑轨道类型）。
    var state = TimelineState()
    let l = EditClip(sourceURL: media, isAudioOnly: true, sourceDuration: 10, timelineStart: 0)
    let r = EditClip(sourceURL: media, isAudioOnly: true, sourceDuration: 10, timelineStart: 14)
    let d = EditClip(sourceURL: media, isAudioOnly: true, sourceDuration: 6, timelineStart: 24)
    state.audioTracks = [EditLane(clips: [l, r, d])]

    let run = performDrag(state, dragged: d.id, moving: [d.id], desiredDelta: -15)
    checkClose(run.state.clip(with: d.id)?.timelineStart ?? -1, 10, "音频块塞进音轨的间隙")
    checkClose(run.state.clip(with: r.id)?.timelineStart ?? -1, 16, "右边的音频让位 2 秒")
}

// MARK: - 28. 从转场库拖卡片到接缝：落点算法
//
// 口径（2026-09-20 用户拍板）：
//   · 只认主轨；距最近接缝 **40pt 以内**才接，闭区间。
//   · 40pt 是**屏幕 pt**，不换算成秒 —— 放大时间线时同样的 40pt 覆盖更少的秒数，
//     越放大落点越精确。
//   · 做不出来的缝（有间隙 / 余料不够）不接，判据复用 `transitionCapacity`，
//     和两条渲染管线、库面板逐张卡片的可用判定**同一份**。
//   · 容量与种类有关，所以必须按**正在拖的那张卡**算，不是缝上当前那种。

/// 两头各留 `spare` 秒余料的主轨片段（`assetDuration` 比取用的范围长出两头）。
/// 不带 `info` 的 `clip(start:duration:)` 则是**零余料**的那一版。
func seamClip(start: Double, duration: Double, spare: Double = 0.5) -> EditClip {
    EditClip(
        sourceURL: media,
        sourceStart: spare,
        sourceDuration: duration,
        timelineStart: start,
        info: MediaInfo(
            duration: spare + duration + spare,
            displaySize: CGSize(width: 1920, height: 1080), frameRate: 30,
            videoCodec: "h264", audioCodec: nil, hasAudio: false,
            audioCanCopyToMP4: false, fileBytes: 1
        )
    )
}

func dropTarget(
    _ x: Double, _ clips: [EditClip], _ kind: ClipTransition,
    pps zoom: Double = pps, maxDistance: Double = 40
) -> Int? {
    TimelineState.transitionDropTarget(
        atX: x, pps: zoom, mainClips: clips, kind: kind, maxDistance: maxDistance
    )
}

// 28a. 正对缝心 + 40pt 边界的闭合性
do {
    // 缝在 t=2 → x = 2 × 24 = 48pt
    let clips = [seamClip(start: 0, duration: 2), seamClip(start: 2, duration: 3)]
    checkEqual(dropTarget(48, clips, .crossFade), 0, "正对缝心落在这条缝上")
    checkEqual(dropTarget(87.9, clips, .crossFade), 0, "右边 39.9pt 收")
    checkEqual(dropTarget(88, clips, .crossFade), 0, "边界闭区间：正好 40pt 也收")
    checkEqual(dropTarget(88.1, clips, .crossFade), nil, "右边 40.1pt 不收")
    checkEqual(dropTarget(8.1, clips, .crossFade), 0, "左边 39.9pt 收")
    checkEqual(dropTarget(7.9, clips, .crossFade), nil, "左边 40.1pt 不收")
    checkEqual(dropTarget(108, clips, .crossFade, maxDistance: 80), 0, "半径由参数说了算")
}

// 28b. 两条缝等距时取哪条 —— 必须定死，不然同一个像素位置看遍历顺序
do {
    // 缝 0 在 48pt、缝 1 在 120pt，正中间 84pt 两边各 36pt
    let clips = [
        seamClip(start: 0, duration: 2), seamClip(start: 2, duration: 3), seamClip(start: 5, duration: 2),
    ]
    checkEqual(dropTarget(84, clips, .crossFade), 0, "等距取下标小的那条（左边）")
    checkEqual(dropTarget(85, clips, .crossFade), 1, "偏右一点就该换成右边那条")
}

// 28c. 中间有空隙的不是一条缝 —— 空隙是用户有意留的，不替他合拢
do {
    let clips = [seamClip(start: 0, duration: 2), seamClip(start: 2.5, duration: 3)]
    checkEqual(dropTarget(48, clips, .crossFade), nil, "有空隙 → 不接")
    checkEqual(dropTarget(48, clips, .blackFade), nil, "有空隙时压黑也不接 —— 那不是种类的问题")
}

// 28d. 零余料：压黑落得下、叠化落不下（容量**与种类有关**，#41 那一刀的成果）
do {
    let clips = [clip(start: 0, duration: 2), clip(start: 2, duration: 2)]
    check(clips[0].trailingHandle == 0 && clips[1].leadingHandle == 0, "这一版里两边确实都没有余料")
    checkEqual(dropTarget(48, clips, .crossFade), nil, "零余料的缝上叠化落不下去")
    checkEqual(dropTarget(48, clips, .pushLeft), nil, "推移同样要两段同时在画面上")
    checkEqual(dropTarget(48, clips, .blackFade), 0, "压黑走原地斜坡，零余料照样能落")
}

// 28e. 按**正在拖的那张卡**算容量，不是缝上当前设的那种
do {
    var first = clip(start: 0, duration: 2)
    // 缝上现在设着压黑 —— 零余料的缝上它是成立的。拿它去判叠化就会放行一个
    // 渲染管线做不出来的落点。
    first.transitionAfter = .blackFade
    let clips = [first, clip(start: 2, duration: 2)]
    checkEqual(dropTarget(48, clips, .crossFade), nil, "拖叠化就按叠化算，不因为缝上是压黑而放行")
    checkEqual(dropTarget(48, clips, .blackFade), 0, "拖压黑上去仍然成立")
}

// 28f. 已相叠的缝（磁吸排的）走 45% 那条路，不需要余料
do {
    let clips = [clip(start: 0, duration: 2), clip(start: 1.5, duration: 2)]
    checkEqual(dropTarget(48, clips, .crossFade), 0, "已相叠的缝照样接")
}

// 28g. 近处那条做不出来、40pt 内还有一条做得出来 → 落在做得出来的那条
do {
    // 缝 0（a|b）两边都没有余料；缝 1（b|c）借得到。两条缝只隔 24pt。
    let a = clip(start: 0, duration: 2)
    let b = EditClip(
        sourceURL: media, sourceStart: 0, sourceDuration: 1, timelineStart: 2,
        info: MediaInfo(
            duration: 1.5, displaySize: CGSize(width: 1920, height: 1080), frameRate: 30,
            videoCodec: "h264", audioCodec: nil, hasAudio: false, audioCanCopyToMP4: false, fileBytes: 1
        )
    )
    let c = seamClip(start: 3, duration: 2)
    let clips = [a, b, c]
    check(a.trailingHandle == 0 && b.leadingHandle == 0, "缝 0 两边确实都没有余料")
    check(b.trailingHandle > 0 && c.leadingHandle > 0, "缝 1 两边确实借得到")
    // 指针在 55pt：离缝 0 只有 7pt、离缝 1 有 17pt，但缝 0 做不出叠化。
    checkEqual(dropTarget(55, clips, .crossFade), 1, "近处做不出来时落到做得出来的那条")
    checkEqual(dropTarget(55, clips, .blackFade), 0, "换压黑：近处那条本来就做得出来，落它")
}

// 28h. 越界与主轨不足两段
do {
    let clips = [seamClip(start: 0, duration: 2), seamClip(start: 2, duration: 3)]
    checkEqual(dropTarget(500, clips, .crossFade), nil, "离任何缝都超过 40pt")
    checkEqual(dropTarget(-100, clips, .crossFade), nil, "左边界外同样不接")
    checkEqual(dropTarget(48, [seamClip(start: 0, duration: 2)], .crossFade), nil, "只有一段就没有缝")
    checkEqual(dropTarget(48, [], .crossFade), nil, "空主轨没有缝")
}

// 28i. 半径是**屏幕 pt**，不是秒 —— 放大之后同样的秒数就出界了
do {
    let clips = [seamClip(start: 0, duration: 2), seamClip(start: 2, duration: 3)]
    // 指针停在缝右边 1.6 秒处，只改缩放：
    checkEqual(dropTarget(48 + 1.6 * 24, clips, .crossFade), 0, "pps=24 时 1.6s = 38.4pt，在半径内")
    checkEqual(
        dropTarget(2 * 48 + 1.6 * 48, clips, .crossFade, pps: 48), nil,
        "放大一倍后同样的 1.6s = 76.8pt，出了半径 —— 越放大落点越精确"
    )
}

// 28j. 「无」拖不上去。库里已经不出这张卡，这条钉的是「将来加回去也拖不上」
do {
    let clips = [seamClip(start: 0, duration: 2), seamClip(start: 2, duration: 3)]
    checkEqual(dropTarget(48, clips, ClipTransition.none), nil, "「无」不是一种转场，拖它没有语义")
}

// MARK: - 29. 遮罩画不画得出来 —— 转场选中态的存活判据
//
// `hasVisibleTransition(afterOutgoing:)` 和 `TransitionMaskView` 的绘制条件是
// **同一个** `transitionWindow`。转场选中态钉在它上面：遮罩不画了，选中就该
// 摘掉，否则时间线上没有任何东西高亮，⌫ 却还会去清一条看不见的缝 ——
// 用户只会看到「按了删除键，什么都没发生」（`pruneMarker` 踩过同一个坑）。

do {
    var first = seamClip(start: 0, duration: 2)
    first.transitionAfter = .crossFade
    first.transitionDuration = 0.4
    let second = seamClip(start: 2, duration: 3)
    var state = TimelineState()
    state.mainClips = [first, second]

    check(state.hasVisibleTransition(afterOutgoing: first.id), "设了转场、缝也成立 → 遮罩在")
    check(!state.hasVisibleTransition(afterOutgoing: second.id), "最后一段后面没有缝")
    check(!state.hasVisibleTransition(afterOutgoing: UUID()), "不存在的段没有遮罩")

    // ⌫ 或撤销把转场清掉：遮罩当场就不画了
    var cleared = state
    cleared.mainClips[0].transitionAfter = .none
    check(!cleared.hasVisibleTransition(afterOutgoing: first.id), "转场清成 .none → 遮罩没了")

    // 出场段被删
    var removed = state
    removed.mainClips.removeFirst()
    check(!removed.hasVisibleTransition(afterOutgoing: first.id), "出场段被删 → 遮罩没了")

    // 缝被拖出间隙 —— 那不是一条缝了
    var gapped = state
    gapped.mainClips[1].timelineStart = 2.5
    check(!gapped.hasVisibleTransition(afterOutgoing: first.id), "拖出间隙 → 遮罩没了")

    // 余料被裁没了：叠化做不出来，容量判死，遮罩也就不画
    var noSpare = TimelineState()
    var bare = clip(start: 0, duration: 2)
    bare.transitionAfter = .crossFade
    bare.transitionDuration = 0.4
    noSpare.mainClips = [bare, clip(start: 2, duration: 3)]
    check(!noSpare.hasVisibleTransition(afterOutgoing: bare.id), "余料裁没了 → 叠化做不出来，遮罩没了")
    // 同一条缝换成压黑就画得出来 —— 判据跟着种类走，和容量模型同一份
    noSpare.mainClips[0].transitionAfter = .blackFade
    check(noSpare.hasVisibleTransition(afterOutgoing: bare.id), "零余料的缝上压黑照样有遮罩")
}

// MARK: - 30. 落点框：几何必须和松手后的真遮罩一模一样
//
// 框和遮罩各算一遍的话，松手那一下框会「跳」一下 —— 用户看到的就是「明明放在
// 这儿，怎么跑偏了」。这一节把两者端到端比一遍：算出落点框 → 按落地规则真的
// 改一份 state → 用**遮罩自己那条路**（transitionWindow + transitionMaskRect）
// 算一次矩形 → 两个矩形必须逐字相等。

/// 模拟松手：照 `setTransition(after:_:duration:)` 的口径改一份 state。
func landed(_ clips: [EditClip], seam: Int, kind: ClipTransition) -> TimelineState {
    var next = clips
    next[seam].transitionAfter = kind
    if let d = TimelineState.transitionDropDuration(existing: clips[seam]) {
        next[seam].transitionDuration = min(max(d, 0.1), 3)
    }
    var state = TimelineState()
    state.mainClips = next
    return state
}

/// 落点框 vs 松手后的遮罩，逐字比。
func checkPreviewMatchesMask(
    _ clips: [EditClip], seam: Int, kind: ClipTransition, atX x: Double,
    _ label: String, line: Int = #line
) {
    guard let preview = TimelineState.transitionDropPreview(
        atX: x, pps: pps, mainClips: clips, kind: kind
    ) else {
        check(false, "\(label)：落点框没算出来", line: line)
        return
    }
    checkEqual(preview.seamIndex, seam, "\(label)：落在第 \(seam) 条缝上", line: line)
    let state = landed(clips, seam: seam, kind: kind)
    guard let window = state.transitionWindow(afterMainIndex: seam) else {
        check(false, "\(label)：松手后遮罩反而画不出来", line: line)
        return
    }
    let mask = TimelineState.transitionMaskRect(window: window, pps: pps, minWidth: 18)
    checkClose(preview.x, mask.x, "\(label)：框的左边界 = 遮罩的左边界", line: line)
    checkClose(preview.width, mask.width, "\(label)：框的宽度 = 遮罩的宽度", line: line)
}

// 30a. 空缝：给默认的 0.5s，框和遮罩同源
do {
    let clips = [seamClip(start: 0, duration: 2), seamClip(start: 2, duration: 3)]
    let preview = TimelineState.transitionDropPreview(
        atX: 48, pps: pps, mainClips: clips, kind: .crossFade
    )
    checkClose(preview?.duration ?? -1, 0.5, "空缝落地取默认的 0.5s")
    checkPreviewMatchesMask(clips, seam: 0, kind: .crossFade, atX: 48, "空缝 + 叠化")
    checkPreviewMatchesMask(clips, seam: 0, kind: .blackFade, atX: 48, "空缝 + 压黑")
}

// 30b. 已有转场的缝：**只换种类、不改时长**
do {
    var first = seamClip(start: 0, duration: 2)
    first.transitionAfter = .crossFade
    first.transitionDuration = 1.2
    let clips = [first, seamClip(start: 2, duration: 3)]
    let preview = TimelineState.transitionDropPreview(
        atX: 48, pps: pps, mainClips: clips, kind: .pushLeft
    )
    checkClose(preview?.duration ?? -1, 0.8, "已有转场的缝保留用户调过的秒数（这里被容量 0.8 夹住）")
    checkEqual(TimelineState.transitionDropDuration(existing: first), nil, "已有转场 → 落地不传时长")
    checkPreviewMatchesMask(clips, seam: 0, kind: .pushLeft, atX: 48, "已有转场 + 换种类")
}

// 30c. 容量夹紧：余料不够 0.5s 时按容量来，框跟着变窄
do {
    // 两头各 0.12s 余料 → borrowable 0.24，byLength*0.4 = 0.32 → 容量 0.24
    let clips = [
        seamClip(start: 0, duration: 2, spare: 0.12), seamClip(start: 2, duration: 3, spare: 0.12),
    ]
    let preview = TimelineState.transitionDropPreview(
        atX: 48, pps: pps, mainClips: clips, kind: .crossFade
    )
    checkClose(preview?.duration ?? -1, 0.24, "0.5s 放不下时夹到容量上限")
    checkPreviewMatchesMask(clips, seam: 0, kind: .crossFade, atX: 48, "容量夹紧")
}

// 30d. 窄转场：宽度有下限，位置必须按**窗口中心**补偿（#43 那一刀的成果）
do {
    let clips = [
        seamClip(start: 0, duration: 2, spare: 0.12), seamClip(start: 2, duration: 3, spare: 0.12),
    ]
    let preview = TimelineState.transitionDropPreview(
        atX: 48, pps: pps, mainClips: clips, kind: .crossFade
    )!
    // 0.24s × 24pps = 5.76pt < 下限 18
    checkClose(preview.width, 18, "窄到贴下限时框宽取下限")
    checkClose(preview.x + preview.width / 2, 48, "下限多出来的宽度两边均摊，框心仍对准缝")
}

// 30e. 已相叠的缝（磁吸排的）：窗口 = 重叠区，和落地时长无关
do {
    // 重叠 1.2s = 28.8pt，**特意大过 18pt 的宽度下限** —— 不然框宽会被下限夹成
    // 18，这一条就验不出「宽度来自重叠区而不是落地时长」了。
    let clips = [clip(start: 0, duration: 2), clip(start: 0.8, duration: 2)]
    let preview = TimelineState.transitionDropPreview(
        atX: 48, pps: pps, mainClips: clips, kind: .crossFade
    )!
    checkClose(preview.duration, 0.5, "落地时长仍然是默认的 0.5s")
    checkClose(preview.width, 1.2 * pps, "但框宽 = 重叠量 1.2s，不是那 0.5s")
    checkClose(preview.x, 0.8 * pps, "框从重叠区的起点画起")
    checkPreviewMatchesMask(clips, seam: 0, kind: .crossFade, atX: 48, "已相叠")
}

// 30f. 接不了的缝一律没有框 —— 和 transitionDropTarget 同一份判据
do {
    let gapped = [seamClip(start: 0, duration: 2), seamClip(start: 2.5, duration: 3)]
    check(TimelineState.transitionDropPreview(atX: 48, pps: pps, mainClips: gapped, kind: .crossFade) == nil,
          "有间隙 → 没有落点框")
    let bare = [clip(start: 0, duration: 2), clip(start: 2, duration: 2)]
    check(TimelineState.transitionDropPreview(atX: 48, pps: pps, mainClips: bare, kind: .crossFade) == nil,
          "零余料 + 叠化 → 没有落点框")
    check(TimelineState.transitionDropPreview(atX: 48, pps: pps, mainClips: bare, kind: .blackFade) != nil,
          "同一条缝 + 压黑 → 有框")
    let far = [seamClip(start: 0, duration: 2), seamClip(start: 2, duration: 3)]
    check(TimelineState.transitionDropPreview(atX: 500, pps: pps, mainClips: far, kind: .crossFade) == nil,
          "离任何缝都超过 40pt → 没有框")
    check(TimelineState.transitionDropPreview(atX: 48, pps: pps, mainClips: far, kind: ClipTransition.none) == nil,
          "「无」拖不上去 → 没有框")
}

// MARK: - 收尾

print("TimelineSnap checks: \(checks) 项，失败 \(failures) 项")
if failures > 0 {
    exit(1)
}
print("OK")
