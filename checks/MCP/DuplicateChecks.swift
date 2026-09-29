import Foundation
import SrtFlowMCPKit

// duplicate_items（AIDuplicate）：走 ⌘C / ⌘V 那两个纯函数 —— 不给落点紧接在后面、落在占着的地方往上抬一轨、
// 链接的声音跟着来、文字找空的行、每样换新身份；不认识的 id 报错。编法见 scripts/check-mcp.sh。

func runDuplicateChecks() {
    var state = TimelineState()
    let first = videoClip(0, 4)
    let second = videoClip(4, 4)
    state.mainClips = [first, second]
    var linked = audioClip(0, 4)
    let group = UUID()
    linked.linkGroup = group
    state.mainClips[0].linkGroup = group
    state.audioTracks = [EditLane(clips: [linked])]
    let title = TextOverlay(text: "南极", timelineStart: 1)
    state.textOverlays = [title]

    // 第二段复制一份、不给落点：紧接在它后面（8 秒），V1 那儿是空的。
    var after = state
    let appended = try? AIDuplicate.apply(
        try AIDuplicate.selection([second.id], in: state, linkage: true), to: &after, at: nil, pointing: nil
    )
    let copy = appended.flatMap { $0.clips.first }.flatMap { after.clip(with: $0) }
    checkEqual(copy?.timelineStart, 8, "no start: the copy goes right after the original")
    check(copy.map { $0.id != second.id } ?? false, "the copy has a new id")
    checkEqual(after.mainClips.count, 3, "the copy lands on V1 where it is free")

    // 第一段复制到 0 秒：V1 占着，往上抬一轨；链接开着，它的声音跟着来。
    var lifted = state
    let atZero = try? AIDuplicate.apply(
        try AIDuplicate.selection([first.id], in: state, linkage: true), to: &lifted, at: 0, pointing: nil
    )
    checkEqual(atZero?.clips.count, 2, "the linked audio is copied too")
    checkEqual(lifted.overlayTracks.count, 1, "a copy that would overlap on V1 goes up to a new video track")
    let copiedGroups = Set(lifted.allClips.filter { atZero?.clips.contains($0.id) == true }.compactMap(\.linkGroup))
    check(copiedGroups.count == 1 && !copiedGroups.contains(group), "the copied pair gets a fresh link group of its own")

    var texts = state
    let textCopy = try? AIDuplicate.apply(
        try AIDuplicate.selection([title.id], in: state, linkage: false), to: &texts, at: 1, pointing: nil
    )
    checkEqual(textCopy?.texts.count, 1, "a text is copied")
    checkEqual(texts.textOverlays.count, 2, "both texts are there")
    checkThrows("an id that does not exist is refused") { _ = try AIDuplicate.selection([UUID()], in: state, linkage: false) }
}
