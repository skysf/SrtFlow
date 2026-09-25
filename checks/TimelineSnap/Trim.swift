import Foundation
import SrtFlowCore

// 第 1b 组：裁切（`TimelineTrim` / `TimelineState.trimGroup`，2026-09-25）。
//
// 1. 一段能裁多少：起点端往左最多退到素材开头，往右最多缩到最短；终点端反之（剪辑按素材
//    余量，叠层类没有素材边界）。
// 2. 一组一起裁：每个成员的范围取交集，谁先到头整组一起停；交集为空整组不动。
// 3. 链接伙伴：`liveTrim` 走 `linkedClipIDs`（案例 docs/bugfixes/2026-09-25-trim-ignores-linked-clips.md），
//    这里钉住纯值那一半：两段一起裁、同一个量、被短的那段拦住。
// 4. 混合一组（剪辑 + 形状 + 文字 + 滤镜 + cue）同一个量，各自的字段各自改。

func checkTrim() {
    // ---- 单段范围 ----
    var state = TimelineState()
    var video = EditClip(sourceURL: media, sourceDuration: 4, timelineStart: 10)
    video.sourceStart = 1            // 素材 0–1 还在前面，后面还有 assetDuration - 5
    video.info = MediaInfo(
        duration: 8, displaySize: CGSize(width: 320, height: 180), frameRate: 30,
        videoCodec: "h264", audioCodec: "aac", hasAudio: true, audioCanCopyToMP4: true, fileBytes: 1
    )
    var audio = EditClip(sourceURL: media, isAudioOnly: true, sourceDuration: 4, timelineStart: 10, audioAssetDuration: 5)
    audio.sourceStart = 1
    let group = UUID()
    video.linkGroup = group
    audio.linkGroup = group
    state.mainClips = [video]
    state.audioTracks = [EditLane(clips: [audio])]
    let v = TimelineTrim.Member(id: video.id, kind: .clip)
    let a = TimelineTrim.Member(id: audio.id, kind: .clip)
    checkEqual(state.trimRange(v, leading: true), (-1.0)...3.9, "起点端：往左最多 1s（素材开头），往右最多缩到剩 0.1s")
    checkEqual(state.trimRange(v, leading: false), (-3.9)...3.0, "终点端：素材后面还有 3s，往左最多缩到剩 0.1s")
    checkEqual(state.trimRange(a, leading: false), (-3.9)...0.0, "音频素材后面没余量了，终点端只能往左")
    checkEqual(state.trimRange(TimelineTrim.Member(id: UUID(), kind: .clip), leading: true), nil, "不在的段是 nil")

    // ---- 整组一起停 ----
    checkEqual(TimelineTrim.clamp(2, ranges: [(-1)...3, (-3.9)...0]), 0, "终点端一起往右：音频一步都不能动 → 整组不动")
    checkEqual(TimelineTrim.clamp(-2, ranges: [(-3.9)...3, (-1)...0]), -1, "一起往左：被只能退 1s 的那段拦住")
    checkEqual(TimelineTrim.clamp(5, ranges: []), 5, "没有范围就是原样")
    checkEqual(TimelineTrim.clamp(1, ranges: [2...3, 0...1]), 0, "交集为空 → 0")
    checkEqual(TimelineTrim.clamp(.nan, ranges: [0...1]), 0, "坏值不入模型")

    // ---- 链接组：两段一起裁、同一个量、被短的拦住 ----
    var linked = state
    let walked = linked.trimGroup([v, a], leading: false, by: 2)
    checkEqual(walked, 0, "音频没余量，视频也不许往右伸")
    checkEqual(linked.clip(with: video.id)?.sourceDuration, 4, "视频没动")
    let shrunk = linked.trimGroup([v, a], leading: false, by: -1.5)
    checkClose(shrunk, -1.5, "一起往左缩 1.5s")
    checkClose(linked.clip(with: video.id)?.sourceDuration ?? 0, 2.5, "视频缩到 2.5s")
    checkClose(linked.clip(with: audio.id)?.sourceDuration ?? 0, 2.5, "音频跟着缩到 2.5s（不再留在原长）")
    let moved = linked.trimGroup([v, a], leading: true, by: -3)
    checkClose(moved, -1, "起点端往左：素材开头只剩 1s，整组退 1s")
    checkClose(linked.clip(with: video.id)?.timelineStart ?? 0, 9, "视频起点退到 9s")
    checkClose(linked.clip(with: audio.id)?.timelineStart ?? 0, 9, "音频起点也退到 9s")
    checkClose(linked.clip(with: audio.id)?.sourceStart ?? 0, 0, "音频的素材起点回到 0")

    // ---- 混合一组：各自的字段各自改，同一个量 ----
    var mixed = state
    let shape = ShapeAnnotation(kind: .rectangle, timelineStart: 10, duration: 4)
    let text = TextOverlay(text: "T", timelineStart: 10, duration: 4)
    let filter = FilterClip(preset: FilterPreset.allCases[0], timelineStart: 10, duration: 4)
    mixed.shapes = [shape]
    mixed.textOverlays = [text]
    mixed.filters = [filter]
    let cue = SubtitleCue(index: 1, start: 10, end: 14, text: "hi")
    mixed.subtitle = SubtitleDocumentModel(cues: [cue])
    let members = [v, TimelineTrim.Member(id: shape.id, kind: .shape), TimelineTrim.Member(id: text.id, kind: .text),
                   TimelineTrim.Member(id: filter.id, kind: .filter), TimelineTrim.Member(id: cue.id, kind: .cue)]
    let together = mixed.trimGroup(members, leading: false, by: 5)
    checkClose(together, 3, "终点端一起往右：被视频的素材余量（3s）拦住，形状 / 文字 / 滤镜 / cue 都只走 3s")
    checkClose(mixed.shapes[0].duration, 7, "形状 4 → 7")
    checkClose(mixed.textOverlays[0].duration, 7, "文字 4 → 7")
    checkClose(mixed.filters[0].duration, 7, "滤镜 4 → 7")
    checkClose(mixed.subtitle?.cues.first?.end ?? 0, 17, "cue 结尾 14 → 17")
    let front = mixed.trimGroup(members, leading: true, by: 2)
    checkClose(front, 2, "起点端一起往右缩 2s")
    checkClose(mixed.shapes[0].timelineStart, 12, "形状起点 10 → 12")
    checkClose(mixed.subtitle?.cues.first?.start ?? 0, 12, "cue 起点 10 → 12")
    checkClose(mixed.clip(with: video.id)?.timelineStart ?? 0, 12, "视频起点 10 → 12")
    checkClose(mixed.clip(with: video.id)?.sourceStart ?? 0, 3, "视频素材起点 1 → 3")
    let tooShort = mixed.trimGroup(members, leading: true, by: 10)
    checkClose(tooShort, 4.8, "再往右缩：形状 / 文字 / 滤镜最短剩 0.2s，比剪辑的 0.1s 先到头 → 整组只走 4.8s")
    check((mixed.subtitle?.cues.first).map { $0.end - $0.start >= TimelineTrim.cueMinimumDuration } == true,
          "cue 不会被裁成负时长")

    // ---- 名单：拉的那个在选中集合里 → 整个选择；没选中 → 只有它；链接伙伴跟着；滤镜只有自己 ----
    let other = EditClip(sourceURL: media, sourceDuration: 3, timelineStart: 30)
    var listed = mixed
    listed.mainClips.append(other)
    let sel = (clips: Set([video.id, other.id]), shapes: Set([shape.id]), texts: Set([text.id]), cues: Set([cue.id]))
    let whole = TimelineTrim.members(anchor: v, selectedClips: sel.clips, selectedShapes: sel.shapes,
                                     selectedTexts: sel.texts, selectedCues: sel.cues, linkage: true, in: listed)
    checkEqual(Set(whole.map(\.id)), [video.id, audio.id, other.id, shape.id, text.id, cue.id],
               "拉选中的剪辑：整个选择 + 链接伙伴")
    checkEqual(whole.map(\.kind).filter { $0 == .clip }.count, 3, "剪辑三段（含链接的音频）")
    let alone = TimelineTrim.members(anchor: TimelineTrim.Member(id: other.id, kind: .clip),
                                     selectedClips: [], selectedShapes: sel.shapes, selectedTexts: sel.texts,
                                     selectedCues: [], linkage: true, in: listed)
    checkEqual(alone.map(\.id), [other.id], "拉没选中的剪辑：只有它（别的选择不跟）")
    let linkedOnly = TimelineTrim.members(anchor: v, selectedClips: [], selectedShapes: [], selectedTexts: [],
                                          selectedCues: [], linkage: true, in: listed)
    checkEqual(Set(linkedOnly.map(\.id)), [video.id, audio.id], "拉没选中的视频：它 + 链接的音频")
    let unlinked = TimelineTrim.members(anchor: v, selectedClips: [], selectedShapes: [], selectedTexts: [],
                                        selectedCues: [], linkage: false, in: listed)
    checkEqual(unlinked.map(\.id), [video.id], "链接关着：只有它")
    let fromText = TimelineTrim.members(anchor: TimelineTrim.Member(id: text.id, kind: .text),
                                        selectedClips: sel.clips, selectedShapes: sel.shapes, selectedTexts: sel.texts,
                                        selectedCues: sel.cues, linkage: false, in: listed)
    checkEqual(Set(fromText.map(\.id)), [video.id, other.id, shape.id, text.id, cue.id], "从文字起手一样带上整个选择")
    let filterOnly = TimelineTrim.members(anchor: TimelineTrim.Member(id: filter.id, kind: .filter),
                                          selectedClips: sel.clips, selectedShapes: sel.shapes, selectedTexts: sel.texts,
                                          selectedCues: sel.cues, linkage: true, in: listed)
    checkEqual(filterOnly.map(\.id), [filter.id], "拉没选中的滤镜：只裁自己")
    let filterAnchored = TimelineTrim.members(anchor: TimelineTrim.Member(id: filter.id, kind: .filter),
                                              selectedClips: sel.clips, selectedShapes: [], selectedTexts: [],
                                              selectedCues: [], selectedFilters: [filter.id], linkage: false, in: listed)
    checkEqual(Set(filterAnchored.map(\.id)), [filter.id, video.id, other.id], "拉选中的滤镜（⌘A 那一片）：整个选择一起裁")
    let withFilters = TimelineTrim.members(anchor: v, selectedClips: sel.clips, selectedShapes: [], selectedTexts: [],
                                           selectedCues: [], selectedFilters: [filter.id], linkage: false, in: listed)
    check(withFilters.contains(TimelineTrim.Member(id: filter.id, kind: .filter)), "从剪辑起手，选中的滤镜段也在名单里")

    // ---- 框选：滤镜行也出 item，框到就选中 ----
    let hit = TimelineMarquee.hits(
        rect: CGRect(x: 0, y: 0, width: 100, height: 30),
        rows: [TimelineMarquee.Row(minY: 3, maxY: 23, items: [
            TimelineMarquee.Item(id: filter.id, start: 1, end: 3, kind: .filter),
            TimelineMarquee.Item(id: other.id, start: 30, end: 33, kind: .filter),
        ])],
        pixelsPerSecond: 24
    )
    checkEqual(hit.filters, [filter.id], "框到的滤镜段进 hit.filters，框外的不进")
    check(!hit.isEmpty, "只框到滤镜也不算空")
    checkEqual(whole, TimelineTrim.members(anchor: v, selectedClips: sel.clips, selectedShapes: sel.shapes,
                                            selectedTexts: sel.texts, selectedCues: sel.cues, linkage: true, in: listed),
               "同一份输入永远同一份名单（顺序固定）")
}
