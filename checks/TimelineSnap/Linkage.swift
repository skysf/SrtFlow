import Foundation
import SrtFlowCore

// 第 1f 组：联动（`TimelineLinkage` / `TimelineLinkageLanding`，2026-10-02）。
//
// 压在主轨块上的东西跟着它的**画面**走（docs/architecture/timeline-linkage.md）：
// 1. 完全落在一段里的：删它就删、挪它就挪（磁吸合拢、换位、变速、裁头之后画面前移）。
// 2. 跨两段的：底下的画面全部挪同一个量才跟，否则不动；画面全没了才删（配乐铺整片永远不被顺手删掉）。
// 3. 画面没了只在真删（`deletesContent`）时连带删；裁切让画面没了的留在原地。
// 4. 分割 / cut_speech / 定格切出来的新 id 照样认（同素材、接着的源时间）；同 id 永远优先（粘出来的同素材新段不算）。
// 5. 这次操作自己动过的东西不再碰；撞上了让开（段换轨、文字换行、滤镜换层）。
// 6. 拖动计划要的名单（`attachments`）：底下压着的主轨块全在名单里才算。
// 用例就是方案里那张表（docs/plans/2026-10-02-timeline-linkage.md 第三节）。

private let assetA = URL(fileURLWithPath: "/tmp/srtflow-snap-check/a.mp4")
private let assetB = URL(fileURLWithPath: "/tmp/srtflow-snap-check/b.mp4")
private let assetC = URL(fileURLWithPath: "/tmp/srtflow-snap-check/c.mp4")
private let assetMusic = URL(fileURLWithPath: "/tmp/srtflow-snap-check/music.m4a")

private func video(_ url: URL, at start: Double, duration: Double, sourceStart: Double = 0) -> EditClip {
    var clip = EditClip(sourceURL: url, sourceDuration: duration, timelineStart: start)
    clip.sourceStart = sourceStart
    return clip
}

private func sound(_ url: URL, at start: Double, duration: Double) -> EditClip {
    EditClip(sourceURL: url, isAudioOnly: true, sourceDuration: duration, timelineStart: start)
}

/// 三段主轨 A [0,10) B [10,20) C [20,30) + 各种压在上面的东西。
private struct Fixture {
    var state = TimelineState()
    let a = video(assetA, at: 0, duration: 10)
    let b = video(assetB, at: 10, duration: 10)
    let c = video(assetC, at: 20, duration: 10)
    let broll = video(assetC, at: 5, duration: 3)          // V2，A 里
    let sfx = sound(assetMusic, at: 3, duration: 1)         // A1，A 里
    let music = sound(assetMusic, at: 0, duration: 30)      // A2，铺整片
    let cueInA = SubtitleCue(start: 2, end: 4, text: "in A")
    let cueAB = SubtitleCue(start: 9, end: 12, text: "across A|B")    // 译文轨
    let cueBC = SubtitleCue(start: 19, end: 21, text: "across B|C")
    let cueInC = SubtitleCue(start: 22, end: 25, text: "in C")
    let text = TextOverlay(text: "in B", timelineStart: 11, duration: 2)
    let shape = ShapeAnnotation(kind: .rectangle, timelineStart: 21, duration: 2)   // C 里
    let filter = FilterClip(preset: .tealOrange, timelineStart: 12, duration: 2)   // B 里

    init() {
        state.mainClips = [a, b, c]
        state.overlayTracks = [EditLane(clips: [broll])]
        state.audioTracks = [EditLane(clips: [sfx]), EditLane(clips: [music])]
        var original = SubtitleDocumentModel(format: .srt)
        original.cues = [cueInA, cueBC, cueInC]
        state.subtitle = original
        var translation = SubtitleDocumentModel(format: .srt)
        translation.cues = [cueAB]
        var companion = SubtitleCompanion(origin: .imported)
        companion.translation = translation
        state.subtitleCompanion = companion
        state.textOverlays = [text]
        state.shapes = [shape]
        state.filters = [filter]
    }
}

/// 切两刀之后主轨有几段（给下标前的保险用）。
private func trimmedLikePieces(_ before: TimelineState) -> Int {
    var probe = before
    guard let a = probe.mainClips.first else { return 0 }
    LinkRegrouping.split([a.id], at: 6, in: &probe)
    LinkRegrouping.split([a.id], at: 4, in: &probe)
    return probe.mainClips.count
}

/// 删掉主轨上的一段、后面的主轨块往前补它的长度（cut_speech 落账的那一套：`AITimelineEdits.delete` 带 ripple）。
private func rippleDelete(_ id: UUID, in state: inout TimelineState) {
    guard let clip = state.clip(with: id) else { return }
    state.remove(id)
    for other in state.mainClips where other.timelineStart > clip.timelineStart {
        state.update(other.id) { $0.timelineStart -= clip.timelineDuration }
    }
    state.sortMainClipsByStart()
}

private func start(_ state: TimelineState, clip id: UUID) -> Double? { state.clip(with: id)?.timelineStart }
private func start(_ state: TimelineState, cue id: UUID) -> Double? { state.subtitleCue(id)?.start }
private func start(_ state: TimelineState, text id: UUID) -> Double? { state.textOverlays.first { $0.id == id }?.timelineStart }
private func start(_ state: TimelineState, shape id: UUID) -> Double? { state.shapes.first { $0.id == id }?.timelineStart }
private func start(_ state: TimelineState, filter id: UUID) -> Double? { state.filters.first { $0.id == id }?.timelineStart }

func checkLinkage() {
    checkLinkageDelete()
    checkLinkageMoveAndEdits()
    checkLinkageCutsTrimsAndSpeed()
    checkLinkageLanding()
    checkLinkageAttachments()
}

// MARK: - 删（磁吸开着后面合拢）

private func checkLinkageDelete() {
    // ---- 删中间那段 B ----
    let f = Fixture()
    var after = f.state
    after.remove(f.b.id)
    after.packMain()   // A [0,10) C [10,20)
    let report = TimelineLinkage.follow(from: f.state, to: &after, deletesContent: true)
    checkEqual(start(after, cue: f.cueInA.id), 2, "A 里的字幕：A 没动，不动")
    checkEqual(start(after, cue: f.cueInC.id), 12, "C 里的字幕跟着 C 前移 10 秒")
    checkEqual(start(after, shape: f.shape.id), 11, "C 里的形状跟着 C 前移")
    checkEqual(start(after, text: f.text.id), nil, "B 里的文字跟着 B 一起删")
    checkEqual(start(after, filter: f.filter.id), nil, "B 里的滤镜段跟着 B 一起删")
    checkEqual(start(after, cue: f.cueAB.id), 9, "跨 A|B 的字幕：A 还在、没动 → 不动、不删")
    checkEqual(start(after, cue: f.cueBC.id), 9, "跨 B|C 的字幕：B 没了、剩下的画面只有 C 的、C 前移 10 → 跟着 C（不删）")
    checkEqual(start(after, clip: f.music.id), 0, "铺整片的配乐：A 没动、C 动了，不是同一个量 → 不动")
    check(after.clip(with: f.music.id) != nil, "铺整片的配乐不删")
    checkEqual(start(after, clip: f.sfx.id), 3, "A 里的音效不动")
    checkEqual(start(after, clip: f.broll.id), 5, "A 里的 B-roll 不动")
    checkEqual(report, TimelineLinkage.Report(moved: 3, deleted: 2), "报出来：挪了 3 样（C 的字幕、形状、跨 B|C 的字幕），删了 2 样")

    // ---- 删第一段 A：后面整体前移 ----
    var afterA = f.state
    afterA.remove(f.a.id)
    afterA.packMain()   // B [0,10) C [10,20)
    TimelineLinkage.follow(from: f.state, to: &afterA, deletesContent: true)
    checkEqual(start(afterA, cue: f.cueInA.id), nil, "A 里的字幕跟着 A 删")
    checkEqual(start(afterA, clip: f.sfx.id), nil, "A 里的音效跟着 A 删")
    checkEqual(start(afterA, clip: f.broll.id), nil, "A 里的 B-roll 跟着 A 删")
    checkEqual(start(afterA, cue: f.cueAB.id), 0, "跨 A|B 的字幕：A 没了、B 前移 10 → 跟着 B（夹在 0）")
    checkEqual(start(afterA, cue: f.cueBC.id), 9, "跨 B|C 的字幕：B、C 都前移 10 → 跟着挪")
    checkEqual(start(afterA, text: f.text.id), 1, "B 里的文字跟着 B 前移")
    checkEqual(start(afterA, filter: f.filter.id), 2, "B 里的滤镜跟着 B 前移")
    checkEqual(start(afterA, cue: f.cueInC.id), 12, "C 里的字幕跟着 C 前移")
    checkEqual(start(afterA, clip: f.music.id), 0, "配乐：剩下的 B、C 都前移 10 → 跟着挪，夹在 0；不删")
    checkEqual(after.overlayTracks.count, 1, "删 B 之后上层轨还在")
    checkEqual(afterA.overlayTracks.count, 0, "A 的 B-roll 删掉之后空出来的上层轨收掉")

    // ---- 磁吸关着删 B：留着缝，只删压在 B 上的 ----
    var gap = f.state
    gap.remove(f.b.id)
    TimelineLinkage.follow(from: f.state, to: &gap, deletesContent: true)
    checkEqual(start(gap, cue: f.cueInC.id), 22, "磁吸关着：C 没动，C 里的字幕不动")
    checkEqual(start(gap, text: f.text.id), nil, "磁吸关着：B 里的文字照样跟着 B 删")

    // ---- 不是真删（裁切那一类）时画面没了的留在原地 ----
    var kept = f.state
    kept.remove(f.b.id)
    kept.packMain()
    TimelineLinkage.follow(from: f.state, to: &kept, deletesContent: false)
    checkEqual(start(kept, text: f.text.id), 11, "deletesContent=false：画面没了的东西留在原地、不删")

    // ---- 主轨没动就什么都不碰 ----
    var same = f.state
    same.textOverlays[0].text = "changed"
    let nothing = TimelineLinkage.follow(from: f.state, to: &same, deletesContent: true)
    check(nothing.isEmpty, "主轨的画面没挪：报空")
    checkEqual(same.textOverlays[0].text, "changed", "主轨没挪时别的改动原样留着")
}

// MARK: - 挪（换位、这次操作自己动过的不再碰）

private func checkLinkageMoveAndEdits() {
    let f = Fixture()
    // ---- 把 B 拖到最前面：B [0,10) A [10,20) C [20,30) ----
    var after = f.state
    after.mainClips = [f.b, f.a, f.c]
    after.packMain()
    let report = TimelineLinkage.follow(from: f.state, to: &after, deletesContent: false)
    checkEqual(start(after, cue: f.cueInA.id), 12, "A 里的字幕跟着 A 后移 10")
    checkEqual(start(after, clip: f.broll.id), 15, "A 里的 B-roll 跟着 A 后移")
    checkEqual(start(after, clip: f.sfx.id), 13, "A 里的音效跟着 A 后移")
    checkEqual(start(after, text: f.text.id), 1, "B 里的文字跟着 B 到最前面")
    checkEqual(start(after, filter: f.filter.id), 2, "B 里的滤镜跟着 B 到最前面")
    checkEqual(start(after, cue: f.cueAB.id), 9, "跨 A|B 的字幕：A、B 各挪各的 → 不动")
    checkEqual(start(after, cue: f.cueInC.id), 22, "C 没动，C 里的字幕不动")
    checkEqual(start(after, clip: f.music.id), 0, "配乐不动：第 1 段去了别处、不是同一个量")
    checkEqual(report.deleted, 0, "换位不删东西")

    // ---- 这次操作自己动过的东西不再碰（拖动的成员已经按实际落点平过了） ----
    var touched = f.state
    touched.mainClips = [f.b, f.a, f.c]
    touched.packMain()
    touched.updateTextOverlay(f.text.id) { $0.timelineStart = 40 }   // 操作自己把它挪走了
    TimelineLinkage.follow(from: f.state, to: &touched, deletesContent: false)
    checkEqual(start(touched, text: f.text.id), 40, "操作自己动过的文字不再按联动挪一次")

    // ---- 主轨块拖去上层轨：同 id 不在主轨上了也认，压在它上面的跟着去 ----
    var relocated = f.state
    relocated.relocateClip(f.b.id, to: .newOverlayTop, magnet: true)   // B 离开主轨
    relocated.packMain()                                                   // 磁吸：A C 合拢（applyDrag 落地时做的）
    checkEqual(start(relocated, clip: f.b.id), 10, "B 搬去上层轨还在 10 秒")
    TimelineLinkage.follow(from: f.state, to: &relocated, deletesContent: false)
    checkEqual(start(relocated, text: f.text.id), 11, "B 还在（上层轨、没挪）：B 里的文字原地不动")
    checkEqual(start(relocated, cue: f.cueInC.id), 12, "C 合拢前移 10：C 里的字幕跟着")

    // ---- 分割本身什么都不挪 ----
    var split = f.state
    split.split(clipID: f.a.id, at: 4)
    let afterSplit = TimelineLinkage.follow(from: f.state, to: &split, deletesContent: true)
    check(afterSplit.isEmpty, "分割本身：画面没挪，什么都不动、不删")
    checkEqual(start(split, cue: f.cueInA.id), 2, "切开之后 A 里的字幕原地")
}

// MARK: - 切（cut_speech）、裁、变速、定格：按画面认，新 id 照样认

private func checkLinkageCutsTrimsAndSpeed() {
    var fx = Fixture()
    let cueRight = SubtitleCue(start: 7, end: 9, text: "A right")      // A 的 [6,10) 那一截里
    let sfxMiddle = sound(assetMusic, at: 4.5, duration: 1)            // 要被剪掉的 [4,6) 里
    fx.state.subtitle?.cues.append(cueRight)
    fx.state.audioTracks[0].clips.append(sfxMiddle)
    let before = fx.state

    // ---- cut_speech：切开 A 的 [4,6) 并删掉、带波纹 ----
    var cut = before
    LinkRegrouping.split([fx.a.id], at: 6, in: &cut)
    LinkRegrouping.split([fx.a.id], at: 4, in: &cut)
    guard cut.mainClips.count == 5, trimmedLikePieces(before) == 5 else { return check(false, "切两刀之后主轨该是 5 段（A 三截 + B + C）") }
    rippleDelete(cut.mainClips[1].id, in: &cut)
    checkEqual(cut.mainClips.map(\.timelineStart), [0, 4, 8, 18], "切掉 2 秒：A 左 [0,4)、A 右 [4,8)、B [8,18)、C [18,28)")
    let report = TimelineLinkage.follow(from: before, to: &cut, deletesContent: true)
    checkEqual(start(cut, cue: fx.cueInA.id), 2, "A 左半里的字幕不动")
    checkEqual(start(cut, cue: cueRight.id), 5, "A 右半是新 id：压在它上面的字幕按画面前移 2 秒")
    checkEqual(start(cut, clip: sfxMiddle.id), nil, "剪掉那一截上的音效跟着删")
    checkEqual(start(cut, cue: fx.cueAB.id), 7, "跨 A|B 的字幕：A 右半和 B 都前移 2 → 跟着挪")
    checkEqual(start(cut, text: fx.text.id), 9, "B 里的文字前移 2")
    checkEqual(start(cut, cue: fx.cueInC.id), 20, "C 里的字幕前移 2")
    checkEqual(start(cut, clip: fx.sfx.id), 3, "A 左半里的音效不动")
    checkEqual(report.deleted, 1, "只删了那一个音效")
    var trimmedLike = before
    LinkRegrouping.split([fx.a.id], at: 6, in: &trimmedLike)
    LinkRegrouping.split([fx.a.id], at: 4, in: &trimmedLike)
    rippleDelete(trimmedLike.mainClips[1].id, in: &trimmedLike)   // 上面已经确认切两刀是 4 段
    TimelineLinkage.follow(from: before, to: &trimmedLike, deletesContent: false)
    checkEqual(start(trimmedLike, clip: sfxMiddle.id), 4.5, "不是真删时：画面没了的音效留在原地")

    // ---- 裁掉 A 的头 2 秒（磁吸开着：A 的起点不动、画面前移） ----
    var trimmed = before
    trimmed.trim(TimelineTrim.Member(id: fx.a.id, kind: .clip), leading: true, by: 2)
    trimmed.packMain()
    checkEqual(trimmed.mainClips.map(\.timelineStart), [0, 8, 18], "裁头之后 A [0,8) B [8,18) C [18,28)")
    TimelineLinkage.follow(from: before, to: &trimmed, deletesContent: false)
    checkEqual(start(trimmed, cue: fx.cueInA.id), 0, "A 里 [2,4) 的字幕跟着画面前移 2 秒")
    checkEqual(start(trimmed, clip: fx.sfx.id), 1, "A 里的音效跟着画面前移")
    checkEqual(start(trimmed, cue: cueRight.id), 5, "A 后半的字幕也前移 2")
    checkEqual(start(trimmed, text: fx.text.id), 9, "B 跟着合拢，B 里的文字前移 2")
    var headCue = before
    let onHead = SubtitleCue(start: 0, end: 1, text: "on the trimmed head")
    headCue.subtitle?.cues.insert(onHead, at: 0)
    var headTrimmed = headCue
    headTrimmed.trim(TimelineTrim.Member(id: fx.a.id, kind: .clip), leading: true, by: 2)
    headTrimmed.packMain()
    TimelineLinkage.follow(from: headCue, to: &headTrimmed, deletesContent: false)
    checkEqual(start(headTrimmed, cue: onHead.id), 0, "被裁掉那 2 秒上的字幕留在原地（裁切不删）")

    // ---- 变速：A 两倍速，A 里的东西按画面挪到一半处 ----
    var faster = before
    faster.update(fx.a.id) { $0.speed = 2 }
    faster.packMain()
    checkEqual(faster.mainClips.map(\.timelineStart), [0, 5, 15], "两倍速之后 A [0,5) B [5,15) C [15,25)")
    TimelineLinkage.follow(from: before, to: &faster, deletesContent: false)
    checkEqual(start(faster, cue: fx.cueInA.id), 1, "A 里 2 秒处的字幕跟着那一帧到 1 秒")
    checkEqual(start(faster, clip: fx.broll.id), 2.5, "A 里 5 秒处的 B-roll 到 2.5 秒")
    checkEqual(start(faster, text: fx.text.id), 6, "B 前移 5，B 里的文字跟着")
    checkEqual(fx.state.subtitleCue(fx.cueInA.id)?.end, 4, "改的是副本：原来的状态没动")

    // ---- 定格插入：A 在 6 秒切开、插 2 秒静帧，右半是新 id ----
    var frozen = before
    let still = EditClip(
        sourceURL: URL(fileURLWithPath: "/tmp/srtflow-snap-check/still.mp4"), sourceDuration: 2, timelineStart: 6,
        stillImageURL: URL(fileURLWithPath: "/tmp/srtflow-snap-check/still.png")
    )
    frozen.insertFreeze(still, splitting: fx.a.id, at: 6)
    frozen.packMain()
    checkEqual(frozen.mainClips.map(\.timelineStart), [0, 6, 8, 12, 22], "定格之后 A 左 [0,6) 静帧 [6,8) A 右 [8,12) B [12,22) C [22,32)")
    TimelineLinkage.follow(from: before, to: &frozen, deletesContent: false)
    checkEqual(start(frozen, cue: cueRight.id), 9, "A 右半（新 id）上的字幕跟着后移 2")
    checkEqual(start(frozen, cue: fx.cueInA.id), 2, "A 左半的字幕不动")
    checkEqual(start(frozen, text: fx.text.id), 13, "B 后移 2，B 里的文字跟着")
    checkEqual(start(frozen, clip: fx.music.id), 0, "配乐：A 左半没动、后面动了 → 不动")

    // ---- 粘贴出来的同素材新段不算画面挪过去了：同 id 优先 ----
    var pasted = before
    var copy = fx.a
    copy = EditClip(sourceURL: assetA, sourceDuration: 10, timelineStart: 30)   // 同素材、同源时间，接在最后
    pasted.mainClips.append(copy)
    pasted.remove(fx.b.id)   // 顺带删 B 让主轨真的挪过
    pasted.packMain()
    TimelineLinkage.follow(from: before, to: &pasted, deletesContent: true)
    checkEqual(start(pasted, cue: fx.cueInA.id), 2, "A 还在原地：A 里的字幕不会跑去新粘的那一段上")
}

// MARK: - 撞上了让开

private func checkLinkageLanding() {
    // A [0,10) ... C [20,30)，中间空着；操作把 C 挪到 [10,20)。缝上压着的东西没有宿主、不动；C 里的东西跟着前移，撞上就让。
    var state = TimelineState()
    let a = video(assetA, at: 0, duration: 10)
    let c = video(assetC, at: 20, duration: 10)
    state.mainClips = [a, c]
    let obstacle = video(assetB, at: 12, duration: 3)       // V2，缝上
    let follower = video(assetB, at: 22, duration: 3)       // V2，C 里 → 要挪到 [12,15)
    state.overlayTracks = [EditLane(clips: [obstacle, follower])]
    let soundObstacle = sound(assetMusic, at: 12, duration: 1)
    let soundFollower = sound(assetMusic, at: 22, duration: 1)
    state.audioTracks = [EditLane(clips: [soundObstacle, soundFollower])]
    let textObstacle = TextOverlay(text: "gap", timelineStart: 12, duration: 2)
    let textFollower = TextOverlay(text: "in C", timelineStart: 22, duration: 2)
    state.textOverlays = [textObstacle, textFollower]
    let filterObstacle = FilterClip(preset: .tealOrange, timelineStart: 12, duration: 2, layer: 0)
    let filterFollower = FilterClip(preset: .tealOrange, timelineStart: 22, duration: 2, layer: 0)
    state.filters = [filterObstacle, filterFollower]

    var after = state
    after.update(c.id) { $0.timelineStart = 10 }
    let report = TimelineLinkage.follow(from: state, to: &after, deletesContent: false)
    checkEqual(report.moved, 4, "C 里的四样跟着挪")
    checkEqual(start(after, clip: follower.id), 12, "B-roll 跟着 C 前移到 12")
    checkEqual(after.overlayTracks.count, 2, "撞上缝上那段：往上抬一轨")
    check(after.overlayTracks.dropFirst().first?.clips.map(\.id) == [follower.id], "抬上去的是跟着挪的那段，不动的留在原轨")
    checkEqual(after.overlayTracks.first?.clips.map(\.id), [obstacle.id], "原轨只剩没动的那段")
    checkEqual(after.audioTracks.count, 2, "音效撞上：另开一条音频轨")
    check(after.audioTracks.dropFirst().first?.clips.map(\.id) == [soundFollower.id], "新开的音频轨上是跟着挪的那段")
    checkEqual(after.textOverlays.first { $0.id == textFollower.id }?.row, 1, "文字撞上同一行：往上找空行")
    checkEqual(after.textOverlays.first { $0.id == textObstacle.id }?.row, 0, "没动的文字还在原行")
    checkEqual(after.filters.first { $0.id == filterFollower.id }?.layer, 1, "滤镜撞上同一层：往上找空层")
    checkEqual(after.filters.first { $0.id == filterObstacle.id }?.layer, 0, "没动的滤镜还在原层")

    // 没撞上就一个不碰。
    var free = state
    free.update(c.id) { $0.timelineStart = 15 }
    TimelineLinkage.follow(from: state, to: &free, deletesContent: false)
    checkEqual(free.overlayTracks.count, 1, "没撞上：不开新轨")
    checkEqual(start(free, clip: follower.id), 17, "B-roll 跟着 C 到 17")
    checkEqual(free.textOverlays.first { $0.id == textFollower.id }?.row, 0, "没撞上：文字不换行")
}

// MARK: - 拖动计划要的名单

private func checkLinkageAttachments() {
    let f = Fixture()
    let onA = TimelineLinkage.attachments(of: [f.a.id], in: f.state)
    checkEqual(Set(onA.clips.map(\.id)), [f.broll.id, f.sfx.id], "压在 A 上的段：B-roll 和音效（配乐跨到别的块上，不算）")
    checkEqual(onA.cues.map(\.id), [f.cueInA.id], "压在 A 上的字幕只有完全在 A 里的那句（跨 A|B 的不算）")
    check(onA.texts.isEmpty && onA.shapes.isEmpty && onA.filters.isEmpty, "A 上没有文字 / 形状 / 滤镜")
    check(onA.clips.allSatisfy { $0.host == f.a.id }, "宿主记的是 A")
    let onAB = TimelineLinkage.attachments(of: [f.a.id, f.b.id], in: f.state)
    checkEqual(Set(onAB.cues.map(\.id)), [f.cueInA.id, f.cueAB.id], "A、B 一起动：跨 A|B 的字幕也算")
    check(onAB.cues.first { $0.id == f.cueAB.id }?.host == f.a.id, "跨 A|B 的字幕宿主是它底下最早的那段 A")
    checkEqual(onAB.texts.map(\.id), [f.text.id], "B 里的文字算")
    checkEqual(onAB.filters.map(\.id), [f.filter.id], "B 里的滤镜算")
    check(!onAB.ids.contains(f.music.id), "配乐跨到 C 上，不算")
    check(TimelineLinkage.attachments(of: [], in: f.state) == .none, "没有主轨块就没有名单")
    checkEqual(onAB.ids.count, 6, "名单的 id 集合：B-roll、音效、两句字幕、文字、滤镜")

    // 挂进拖动计划：没有障碍、带宿主、已经在计划里的不重复。
    let plan = ClipDragPlan(
        draggedID: f.a.id, draggedSpan: TimelineSpan(start: 0, end: 10),
        members: [.init(id: f.a.id, span: TimelineSpan(start: 0, end: 10), obstacles: [], kind: .clip)],
        candidates: [], magnet: nil
    ).adding(shapes: [], texts: [], cues: [(id: f.cueInA.id, span: TimelineSpan(start: 2, end: 4))]).adding(attachments: onA)
    checkEqual(plan.members.count, 4, "A + 框选带的那句字幕 + B-roll + 音效（字幕不重复挂）")
    check(plan.members.filter { $0.host != nil }.count == 2, "联动带进来的两个成员记着宿主")
    check(plan.members.allSatisfy { $0.obstacles.isEmpty }, "联动带进来的成员没有障碍")
}
