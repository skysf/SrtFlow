import Foundation

// 分割之后理顺链接组（LinkRegrouping）：一对链接的段（视频 + 分离出来的声音）切开之后是两对，不是四段连成一串 ——
// 以前右半段原样抄了组号，链接开着时删掉 / 拖走其中一块，整串都跟着走
// （docs/bugfixes/2026-09-28-split-links-every-piece-together.md）。再切一刀是三对；J / L 切（声音比画面长出一截）按重叠认对；
// 只切了画面、声音横跨两半时三段还是一串（两半都和那段声音在一起放）；首尾刚好相接不算重叠。

func checkLinkGroups() {
    let group = UUID()
    var state = TimelineState()
    let video = EditClip(sourceURL: media, sourceDuration: 30, timelineStart: 0, linkGroup: group)
    let sound = EditClip(sourceURL: media, isAudioOnly: true, sourceDuration: 30, timelineStart: 0, linkGroup: group, audioAssetDuration: 30)
    state.mainClips = [video]
    state.audioTracks = [EditLane(clips: [sound])]
    LinkRegrouping.split([video.id, sound.id], at: 10, in: &state)
    let right = state.mainClips.first { $0.timelineStart == 10 }
    checkEqual(state.linkedClipIDs(of: right?.id ?? UUID()).count, 2, "切开一对：右半的画面只和右半的声音链在一起")
    checkEqual(state.linkedClipIDs(of: video.id).count, 2, "左半的画面只和左半的声音链在一起")
    check(state.mainClips.first?.linkGroup == group, "最早那一对留着原来的组号")
    LinkRegrouping.split([right!.id] + Array(state.linkedClipIDs(of: right!.id)), at: 20, in: &state)
    checkEqual(Set(state.allClips.compactMap(\.linkGroup)).count, 3, "再切一刀：三对，三个组号")
    let middle = state.mainClips.first { $0.contains(time: 15) }!
    checkEqual(state.linkedClipIDs(of: middle.id).count, 2, "中间那块只带着中间那块声音（删它不会把整条素材连声音全删掉）")
    // 和手动 ⌫ 同一个写法（链接开着时按 linkedClipIDs 带上伙伴，deleteSelected）。
    var deleted = state
    for id in deleted.linkedClipIDs(of: middle.id) { deleted.remove(id) }
    checkEqual(deleted.allClips.count, 4, "链接开着删中间那块：只删它和它的声音，剩四段")

    // J 切：声音比画面早开始，只有声音被这一刀切到。
    let jGroup = UUID()
    var jCut = TimelineState()
    let picture = EditClip(sourceURL: media, sourceDuration: 10, timelineStart: 2, linkGroup: jGroup)
    let early = EditClip(sourceURL: media, isAudioOnly: true, sourceDuration: 12, timelineStart: 0, linkGroup: jGroup, audioAssetDuration: 30)
    jCut.mainClips = [picture]
    jCut.audioTracks = [EditLane(clips: [early])]
    LinkRegrouping.split([picture.id, early.id], at: 1, in: &jCut)
    let tail = jCut.audioTracks[0].clips.first { $0.timelineStart == 1 }
    check(tail?.linkGroup != nil && tail?.linkGroup == jCut.mainClips[0].linkGroup, "J 切：画面和跟它一起放的那半截声音还链着")
    check(jCut.audioTracks[0].clips.first { $0.timelineStart == 0 }?.linkGroup == nil, "只在画面前面的那一小截声音落单、不再链接")

    // 只切画面、声音横跨两半：三段一起放，还是一串。
    let spanGroup = UUID()
    var span = TimelineState()
    let spanVideo = EditClip(sourceURL: media, sourceDuration: 10, timelineStart: 0, linkGroup: spanGroup)
    let spanSound = EditClip(sourceURL: media, isAudioOnly: true, sourceDuration: 10, timelineStart: 0, linkGroup: spanGroup, audioAssetDuration: 30)
    span.mainClips = [spanVideo]
    span.audioTracks = [EditLane(clips: [spanSound])]
    LinkRegrouping.split([spanVideo.id], at: 4, in: &span)
    checkEqual(Set(span.allClips.map(\.linkGroup)), [spanGroup], "只切画面：两半都和横跨的那段声音一起放，三段还是一个组")

    checkEqual(LinkRegrouping.components([(UUID(), 0, 5), (UUID(), 5, 9)]).count, 2, "首尾刚好相接不算重叠")
}
