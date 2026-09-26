import Foundation
import SrtFlowCore

// MARK: - 把剪贴板里的一批东西粘进时间线（纯值）
//
// 管什么：整批平移到落点（最早的那个开头对齐落点）、每一样换新身份、各类落到哪一行 / 哪条轨：
// - 剪辑：按原来那条轨分组，撞上了往上抬（`ClipPasteLanding`）；链接组换新组号；
// - 文字 / 滤镜：从指着的那一行 / 那一层（单一来源时）或原来那一行 / 那一层起往上找空的；
// - 字幕句：指着哪条字幕轨就粘到哪条（单一来源时），否则回原来那条；允许和已有的句子重叠；
// - 形状：只有一行、允许重叠，平移就完了。
// 不管什么：落点从哪来（鼠标 / 播放头、吸附，App 那一层 `VideoEditTimelineClipboard.swift`）、
// 一步撤销和重建预览（调用方包在一次 `perform` 里）。
//
// 2026-09-26 用户拍板（docs/plans/2026-09-26-timeline-clipboard-and-zoom.md）；长期约束见
// docs/architecture/timeline-clipboard.md。纯值，自检编得动（scripts/check-timeline-clipboard.sh）。

/// 粘贴时鼠标指着的是哪一行（鼠标在轨道区里才有；按播放头粘时是 nil）。
enum TimelinePasteRow: Equatable {
    case track(TrackSlot)
    case textRow(Int)
    case filterLayer(Int)
    case subtitle(SubtitleTrack)
    case shapes
}

/// 粘出来的都是谁（粘完选中它们）。
struct TimelinePasteResult: Equatable {
    /// 复制时静帧还没转完的图片段：粘完照原图再转一次。
    struct StillConversion: Equatable {
        var clip: UUID
        var image: URL
    }

    var clips: Set<UUID> = []
    var shapes: Set<UUID> = []
    var texts: Set<UUID> = []
    var cues: Set<UUID> = []
    var filters: Set<UUID> = []
    var stillConversions: [StillConversion] = []

    var isEmpty: Bool {
        clips.isEmpty && shapes.isEmpty && texts.isEmpty && cues.isEmpty && filters.isEmpty
    }
}

enum TimelinePaste {

    /// 把 `payload` 粘进 `state`：整批里最早的开头落在 `anchor`（负数当 0），`pointing` 是鼠标指着的那一行。
    static func apply(
        _ payload: TimelineClipboardPayload, to state: inout TimelineState,
        at anchor: Double, pointing row: TimelinePasteRow?
    ) -> TimelinePasteResult {
        guard let start = payload.start else { return TimelinePasteResult() }
        let delta = max(0, anchor) - start
        var result = TimelinePasteResult()
        pasteClips(payload.clips, delta: delta, pointing: row, into: &state, result: &result)
        for shape in payload.shapes {
            guard var copy = ClipboardIdentity.renewed(shape) else { continue }
            copy.timelineStart = shape.timelineStart + delta
            state.shapes.append(copy)
            result.shapes.insert(copy.id)
        }
        pasteTexts(payload.texts, delta: delta, pointing: row, into: &state, result: &result)
        pasteFilters(payload.filters, delta: delta, pointing: row, into: &state, result: &result)
        pasteCues(payload.cues, delta: delta, pointing: row, into: &state, result: &result)
        return result
    }

    // MARK: 剪辑

    private static func pasteClips(
        _ items: [TimelineClipboardPayload.Clip], delta: Double, pointing row: TimelinePasteRow?,
        into state: inout TimelineState, result: inout TimelinePasteResult
    ) {
        guard !items.isEmpty else { return }
        // 链接组：同一组在这一批里至少两段，才换一个新组号（粘出来的一对彼此链接、不和原来那对链在一起）；
        // 只拿到组里一段时不留组号 —— 一个人的链接组没有意义。
        var members: [UUID: Int] = [:]
        for item in items { if let group = item.clip.linkGroup { members[group, default: 0] += 1 } }
        var renamed: [UUID: UUID] = [:]
        var clips: [EditClip] = []
        var landing: [ClipPasteLanding.Item] = []
        for item in items {
            guard var clip = ClipboardIdentity.renewed(item.clip) else { continue }
            clip.timelineStart = item.clip.timelineStart + delta
            clip.needsStillConversion = item.needsStillConversion
            if let group = item.clip.linkGroup, (members[group] ?? 0) >= 2 {
                let fresh = renamed[group] ?? UUID()
                renamed[group] = fresh
                clip.linkGroup = fresh
            } else {
                clip.linkGroup = nil
            }
            clips.append(clip)
            landing.append(ClipPasteLanding.Item(
                lane: item.lane, span: TimelineSpan(start: clip.timelineStart, end: clip.timelineEnd)
            ))
        }
        var pointed: TrackSlot?
        if case .track(let slot) = row { pointed = slot }
        state.insertPasted(clips, at: ClipPasteLanding.targets(for: landing, in: state, pointing: pointed))
        result.clips = Set(clips.map(\.id))
        result.stillConversions = clips.compactMap { clip in
            guard clip.needsStillConversion, let image = clip.stillImageURL else { return nil }
            return TimelinePasteResult.StillConversion(clip: clip.id, image: image)
        }
    }

    // MARK: 文字、滤镜

    /// 文字：从指着的那一行（这一批只来自一行时）或原来那一行起往上找第一条空的（同拖文字换行），
    /// 那一行在这个工程里没有（跨工程）就在最上面新开一行（同新加一段文字）。最后收拢空行。
    private static func pasteTexts(
        _ texts: [TextOverlay], delta: Double, pointing row: TimelinePasteRow?,
        into state: inout TimelineState, result: inout TimelinePasteResult
    ) {
        guard !texts.isEmpty else { return }
        var pointed: Int?
        if case .textRow(let target) = row, Set(texts.map(\.row)).count == 1 { pointed = target }
        for text in texts.sorted(by: { ($0.row, $0.timelineStart) < ($1.row, $1.timelineStart) }) {
            guard var copy = ClipboardIdentity.renewed(text) else { continue }
            copy.timelineStart = text.timelineStart + delta
            copy.row = state.freeTextRow(from: pointed ?? text.row, start: copy.timelineStart, end: copy.timelineEnd)
            state.textOverlays.append(copy)
            result.texts.insert(copy.id)
        }
        state.compactTextRows()
    }

    /// 滤镜：从指着的那一层（这一批只来自一层时）或原来那一层起往上找第一层空的（同拖卡片落层）；
    /// 那一层在这个工程里没有（跨工程）就落在空着的最低层（同按 `+`）。最后收拢空层。
    private static func pasteFilters(
        _ filters: [FilterClip], delta: Double, pointing row: TimelinePasteRow?,
        into state: inout TimelineState, result: inout TimelinePasteResult
    ) {
        guard !filters.isEmpty else { return }
        var pointed: Int?
        if case .filterLayer(let target) = row, Set(filters.map(\.layer)).count == 1 { pointed = target }
        for filter in filters.sorted(by: { ($0.layer, $0.timelineStart) < ($1.layer, $1.timelineStart) }) {
            guard var copy = ClipboardIdentity.renewed(filter) else { continue }
            copy.timelineStart = filter.timelineStart + delta
            let end = copy.timelineStart + copy.duration
            if let from = pointed ?? (filter.layer < state.filterLayerCount ? filter.layer : nil) {
                copy.layer = state.freeFilterLayer(from: from, start: copy.timelineStart, end: end)
            } else {
                copy.layer = state.lowestFreeFilterLayer(start: copy.timelineStart, end: end)
            }
            state.filters.append(copy)
            result.filters.insert(copy.id)
        }
        state.compactFilterLayers()
    }

    // MARK: 字幕句

    /// 指着哪条字幕轨就粘到哪条（这一批只来自一条轨时），否则回原来那条。允许和已有的句子重叠（同拖字幕句）。
    /// 还没有原文轨就新建一条空的（同手写第一行字幕）；没有原文轨时译文句也落进原文轨 —— 只有译文、
    /// 没有原文的工程说不清。藏着的照样藏着（记在旁表里）。
    private static func pasteCues(
        _ items: [TimelineClipboardPayload.Cue], delta: Double, pointing row: TimelinePasteRow?,
        into state: inout TimelineState, result: inout TimelinePasteResult
    ) {
        guard !items.isEmpty else { return }
        var pointed: SubtitleTrack?
        if case .subtitle(let track) = row, Set(items.map(\.isTranslation)).count == 1 { pointed = track }
        for item in items.sorted(by: { $0.cue.start < $1.cue.start }) {
            var cue = item.cue
            cue.id = UUID()
            cue.start = item.cue.start + delta
            cue.end = item.cue.end + delta
            var track = pointed ?? (item.isTranslation ? .translation : .original)
            if track == .translation, state.subtitle == nil { track = .original }
            var inserted = false
            state.editSubtitleTracks(creatingOriginal: true) { original, companion in
                inserted = SubtitleTrackEditing.insertCue(cue, into: track, original: &original, companion: &companion) != nil
                if inserted, item.isHidden { companion.hiddenCueIDs.insert(cue.id) }
            }
            if inserted { result.cues.insert(cue.id) }
        }
    }
}
