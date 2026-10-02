import Foundation
import SrtFlowCore

// 第 1g 组：磁吸跟着工程走，只在改到 V1 的排布时排紧 V1（`MainMagnet`，2026-10-02）。
//
// 南极工程（docs/bugfixes/2026-10-02-magnet-closes-v1-gaps-on-any-edit.md）：磁吸开着、V1 有用户特意留的黑场缝，
// AI 改一条音量曲线 / 一句字幕 / 往 V2 放一段，整条 V1 就被合拢，联动再把压在上面的东西跟着挪。规矩：
// 1. 磁吸关着：什么都不排。
// 2. 磁吸开着：改字幕、音量、别的轨、V1 段的非排布属性（音量、调色）都不动 V1 —— 哪怕 V1 上本来就有缝。
// 3. 磁吸开着、改到了 V1 的排布（起点、时长、先后、转场、增删）：排紧，报出挪了几段。
// 4. 磁吸这次才打开：排紧（工具栏拨开那一下）。

private let source = URL(fileURLWithPath: "/tmp/srtflow-snap-check/magnet.mp4")
private let music = URL(fileURLWithPath: "/tmp/srtflow-snap-check/magnet-music.m4a")

/// V1：A [0,10) 缝 B [12,17) C [17,20)（缝是磁吸关着时留的黑场）；A1 上一段配乐、V1 的 B 上压着一句旁白和一句字幕。
private struct MagnetFixture {
    var state = TimelineState()
    let a = EditClip(sourceURL: source, sourceDuration: 10, timelineStart: 0)
    let b = EditClip(sourceURL: source, sourceDuration: 5, timelineStart: 12)
    let c = EditClip(sourceURL: source, sourceDuration: 3, timelineStart: 17)
    let narration = EditClip(sourceURL: music, isAudioOnly: true, sourceDuration: 2, timelineStart: 13)
    let score = EditClip(sourceURL: music, isAudioOnly: true, sourceDuration: 20, timelineStart: 0)
    let cue = SubtitleCue(start: 13, end: 15, text: "over B")

    init(magnet: Bool) {
        state.mainMagnet = magnet
        state.mainClips = [a, b, c]
        state.audioTracks = [EditLane(clips: [narration]), EditLane(clips: [score])]
        var original = SubtitleDocumentModel(format: .srt)
        original.cues = [cue]
        state.subtitle = original
    }
}

private func starts(_ state: TimelineState) -> [Double] { state.mainClips.map(\.timelineStart) }

func checkMagnet() {
    // ---- 1. 关着：改到 V1 也不排 ----
    let off = MagnetFixture(magnet: false)
    var trimmedOff = off.state
    trimmedOff.update(off.a.id) { $0.sourceDuration = 8 }
    checkEqual(MainMagnet.needsPacking(trimmedOff, after: off.state), false, "磁吸关着：裁短 V1 也不排")
    checkEqual(MainMagnet.settle(&trimmedOff, after: off.state), 0, "磁吸关着：settle 什么都不挪")
    checkEqual(starts(trimmedOff), [0, 12, 17], "磁吸关着：V1 的缝留着")

    // ---- 2. 开着、V1 有缝，改的不是 V1 的排布：一段都不动 ----
    let on = MagnetFixture(magnet: true)
    var volume = on.state
    volume.update(on.score.id) { $0.volume = 0.5 }   // 南极工程：AI 只改了一段配乐的音量（曲线）
    checkEqual(MainMagnet.needsPacking(volume, after: on.state), false, "磁吸开着：改配乐音量不排 V1")
    checkEqual(MainMagnet.settle(&volume, after: on.state), 0, "改配乐音量：settle 不挪 V1")
    checkEqual(starts(volume), [0, 12, 17], "改配乐音量：V1 的黑场缝还在")

    var subtitle = on.state
    subtitle.editSubtitleTracks { original, _ in original.cues[0].text = "over B, edited" }
    checkEqual(MainMagnet.needsPacking(subtitle, after: on.state), false, "磁吸开着：改一句字幕不排 V1")

    var overlay = on.state
    overlay.overlayTracks = [EditLane(clips: [EditClip(sourceURL: source, sourceDuration: 2, timelineStart: 3)])]
    checkEqual(MainMagnet.needsPacking(overlay, after: on.state), false, "磁吸开着：往 V2 放一段不排 V1")

    var clipVolume = on.state
    clipVolume.update(on.b.id) { $0.volume = 0.3 }
    checkEqual(MainMagnet.needsPacking(clipVolume, after: on.state), false, "磁吸开着：改 V1 一段的音量（不是排布）不排")

    // 和 perform 收尾同一个顺序：磁吸 → 联动。V1 没动，联动什么都不跟（以前这一步联动挪了 97 样）。
    var chain = on.state
    chain.update(on.score.id) { $0.volume = 0.5 }
    let packed = MainMagnet.settle(&chain, after: on.state)
    let followed = TimelineLinkage.follow(from: on.state, to: &chain, deletesContent: false)
    checkEqual(packed, 0, "南极工程的那一步：磁吸不挪 V1")
    checkEqual(followed, TimelineLinkage.Report(), "南极工程的那一步：联动什么都不跟")
    checkEqual(chain.clip(with: on.narration.id)?.timelineStart, 13, "压在 B 上的旁白还在 13 秒")
    checkEqual(chain.subtitleCue(on.cue.id)?.start, 13, "压在 B 上的字幕还在 13 秒")

    // ---- 3. 开着、改到了 V1 的排布：排紧，报挪了几段 ----
    var trimmed = on.state
    trimmed.update(on.c.id) { $0.sourceDuration = 2 }   // 只裁 C 的尾巴
    checkEqual(MainMagnet.needsPacking(trimmed, after: on.state), true, "磁吸开着：裁 V1 一段 → 排")
    checkEqual(MainMagnet.settle(&trimmed, after: on.state), 2, "排紧：B、C 往前挪了 2 秒，报 2 段")
    checkEqual(starts(trimmed), [0, 10, 15], "排紧之后 V1 首尾相接")

    var moved = on.state
    moved.update(on.b.id) { $0.timelineStart = 30 }
    moved.sortMainClipsByStart()
    checkEqual(MainMagnet.needsPacking(moved, after: on.state), true, "磁吸开着：挪 V1 一段 → 排")

    var transition = on.state
    transition.mainClips[0].transitionAfter = .crossFade
    checkEqual(MainMagnet.needsPacking(transition, after: on.state), true, "磁吸开着：V1 加转场 → 排（叠掉的长度变了）")

    var added = on.state
    added.mainClips.append(EditClip(sourceURL: source, sourceDuration: 4, timelineStart: 40))
    checkEqual(MainMagnet.needsPacking(added, after: on.state), true, "磁吸开着：V1 多了一段 → 排")

    // ---- 4. 这次才打开：排紧 ----
    var switchedOn = off.state
    switchedOn.mainMagnet = true
    checkEqual(MainMagnet.needsPacking(switchedOn, after: off.state), true, "磁吸这次才打开 → 排")
    checkEqual(MainMagnet.settle(&switchedOn, after: off.state), 2, "拨开磁吸：B、C 合拢（挪了 2 段）")
    checkEqual(starts(switchedOn), [0, 10, 15], "拨开磁吸之后 V1 首尾相接")
    var switchedOff = on.state
    switchedOff.mainMagnet = false
    checkEqual(MainMagnet.needsPacking(switchedOff, after: on.state), false, "磁吸这次关掉：不排、缝留着")

    // ---- 新建工程用上次拨的值（记住的那个只当新建工程的默认） ----
    checkEqual(MainMagnet.newTimeline(remembered: true).mainMagnet, true, "上次拨开了磁吸：新建工程磁吸开")
    checkEqual(MainMagnet.newTimeline(remembered: false).mainMagnet, false, "上次关着：新建工程磁吸关")
    checkEqual(MainMagnet.newTimeline(remembered: true).mainClips.count, 0, "新建工程是空的")
}
