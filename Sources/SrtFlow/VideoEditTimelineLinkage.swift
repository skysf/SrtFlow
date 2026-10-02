import Foundation
import SrtFlowCore

// MARK: - 联动：压在主轨块上的东西跟着它的画面走
//
// 管什么：「联动」开关（`EditorToggles.linkage`，默认开）开着时，时间线上任何不在主轨上的东西 —— 上层轨 / 音频轨的段、
// 文字、形状（含盖一块）、滤镜段、两条轨上的字幕句 —— 怎么跟着它底下压着的主轨**画面**走：画面挪了它挪、画面没了它没了。
// 一次改动结束时（`VideoEditProject.perform` / `liveApply` 收尾）拿改之前、改之后的主轨比一遍，这次操作没碰过的东西按
// 下面的规矩挪 / 删（`follow`）；拖动一段主轨块时压在它上面的东西要实时跟着画，那份名单也从这里要（`attachments`）。
// 不管什么：显式的链接组（`linkGroup`：视频 + 分离出来的音频，`linkedClipIDs`，照旧、更强）、开关本身、撤销（调用方一次
// perform 一步）、拖动中怎么画（`ClipDragPlan` 的成员）、撞上了往哪让（`TimelineLinkageLanding`）。
//
// 规矩（2026-10-02 按用户体验定的，理由见 docs/plans/2026-10-02-timeline-linkage.md；长期约束见
// docs/architecture/timeline-linkage.md）：
// 1. 跟着**画面**走，不跟块的 id：每样东西看自己底下压着主轨的哪些画面（哪个素材的第几秒），画面挪到哪它挪到哪。
//    分割、cut_speech、定格插入切出来的新 id 照样认得出（同一个素材、接着的源时间）；同 id 的段永远优先。
// 2. 完全落在一段主轨块里的：删它就删、挪它就挪（按它底下最早还在的那一截画面挪，和那截画面的相对位置不变）。
// 3. 跨两段的：底下的画面**全部**挪同一个量才跟，否则不动；画面**全没了**才删。
// 4. 画面没了只在**真删**的操作里连带删（`deletesContent`：⌫、AI 的 delete_items / cut_speech）；裁切 / 变速让画面
//    没了的，东西留在原地不动。
// 纯值、不 import AppKit：scripts/check-timeline-snap.sh 直接编（checks/TimelineSnap/Linkage.swift）。

enum TimelineLinkage {
    static let epsilon = 0.000_5

    /// 一次操作之后联动挪了几样、删了几样（AI 的结果里报出来）。
    struct Report: Equatable {
        var moved = 0
        var deleted = 0
        var isEmpty: Bool { moved == 0 && deleted == 0 }
    }

    // MARK: 主轨的画面账

    /// 主轨一段的画面：时间线 `[start, end)` 对应素材的哪一截。
    struct Piece {
        let id: UUID
        let start: Double
        let end: Double
        let sourceStart: Double
        let speed: Double
        let asset: AssetKey

        /// 新切出来的段要按素材认：图片段的身份是原图（静帧缓存随时会换），别的是源文件。
        struct AssetKey: Hashable {
            var url: URL
            var audioOnly: Bool
        }

        init(_ clip: EditClip) {
            id = clip.id
            start = clip.timelineStart
            end = clip.timelineEnd
            sourceStart = clip.sourceStart
            speed = max(0.05, clip.speed)
            asset = AssetKey(url: clip.stillImageURL ?? clip.sourceURL, audioOnly: clip.isAudioOnly)
        }

        var sourceEnd: Double { source(at: end) }
        func source(at time: Double) -> Double { sourceStart + (time - start) * speed }
        func time(atSource source: Double) -> Double { start + (source - sourceStart) / speed }
        func overlaps(_ span: TimelineSpan) -> Bool { start < span.end - epsilon && span.start < end - epsilon }
        func contains(_ span: TimelineSpan) -> Bool { start <= span.start + epsilon && span.end <= end + epsilon }
    }

    /// 一样东西底下的画面这次怎么了。
    enum Outcome: Equatable {
        case stay
        case move(by: Double)
        case delete
    }

    /// 改之前、改之后的主轨画面账。
    struct Ledger {
        /// 改之前主轨上的段（时间顺序）。
        let before: [Piece]
        /// 改之后同 id 的段在哪（不管在哪条轨：主轨块拖去上层轨照样认）。
        let afterByID: [UUID: Piece]
        /// 改之后主轨上这次**新出来**的段（分割 / 定格切出来的右半）。
        let fresh: [Piece]

        init(before: TimelineState, after: TimelineState) {
            self.before = before.mainClips.map(Piece.init)
            let known = Set(before.allClips.map(\.id))
            afterByID = Dictionary(after.allClips.map { ($0.id, Piece($0)) }, uniquingKeysWith: { first, _ in first })
            fresh = after.mainClips.filter { !known.contains($0.id) }.map(Piece.init)
        }

        /// 占着 `span` 的东西该怎么办（规矩 2–4）。
        func outcome(for span: TimelineSpan, deletesContent: Bool) -> Outcome {
            guard span.end - span.start > epsilon else { return .stay }
            let hosts = before.filter { $0.overlaps(span) }
            guard !hosts.isEmpty else { return .stay }
            let inside = hosts.contains { $0.contains(span) }
            var survivors: [(at: Double, delta: Double)] = []
            for host in hosts {
                let lo = host.source(at: max(span.start, host.start))
                let hi = host.source(at: min(span.end, host.end))
                // 同 id 的段优先：它还盖着这截画面就只认它（粘贴 / 复制出来的同素材新段不算画面挪过去了）。
                let same = afterByID[host.id].flatMap { survivor($0, host: host, lo: lo, hi: hi) }
                if let same {
                    survivors.append(same)
                    continue
                }
                for piece in fresh where piece.asset == host.asset {
                    if let found = survivor(piece, host: host, lo: lo, hi: hi) { survivors.append(found) }
                }
            }
            guard !survivors.isEmpty else { return deletesContent ? .delete : .stay }
            survivors.sort { $0.at < $1.at }
            let delta = survivors[0].delta
            if !inside, !survivors.allSatisfy({ abs($0.delta - delta) <= epsilon }) { return .stay }
            return abs(delta) <= epsilon ? .stay : .move(by: delta)
        }

        /// `piece` 还盖着 `host` 的素材 `[lo, hi)` 里的哪一截；盖着就给出那截最早一点改之前在哪、挪了多少。
        private func survivor(_ piece: Piece, host: Piece, lo: Double, hi: Double) -> (at: Double, delta: Double)? {
            let from = max(lo, piece.sourceStart)
            let to = min(hi, piece.sourceEnd)
            guard to - from > epsilon else { return nil }
            let wasAt = host.time(atSource: from)
            return (wasAt, piece.time(atSource: from) - wasAt)
        }
    }

    /// 主轨的画面有没有挪过：没挪就什么都不用算（每次 perform / liveApply 都会问一遍）。
    struct Signature: Equatable {
        var id: UUID
        var start: Double
        var sourceStart: Double
        var sourceDuration: Double
        var speed: Double
    }

    static func signature(of state: TimelineState) -> [Signature] {
        state.mainClips.map {
            Signature(id: $0.id, start: $0.timelineStart, sourceStart: $0.sourceStart, sourceDuration: $0.sourceDuration, speed: $0.speed)
        }
    }

    // MARK: 一次改动收尾：没被碰过的东西跟着画面走

    /// 把 `after` 里这次操作**没碰过**的非主轨东西按 `before` → `after` 主轨画面的变化挪 / 删。
    /// `deletesContent`：这次是真删（⌫、delete_items、cut_speech）才连带删画面没了的东西。返回挪了几样、删了几样。
    @discardableResult
    static func follow(from before: TimelineState, to after: inout TimelineState, deletesContent: Bool) -> Report {
        guard signature(of: before) != signature(of: after) else { return Report() }
        let ledger = Ledger(before: before, after: after)
        var plan = Plan()

        let oldClips = Dictionary(before.laneClips.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for clip in after.laneClips {
            guard let old = oldClips[clip.id], old == clip else { continue }
            Plan.take(ledger.outcome(for: old.span, deletesContent: deletesContent), id: clip.id, start: old.timelineStart, into: &plan.clips)
        }
        let oldShapes = Dictionary(before.shapes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for shape in after.shapes {
            guard let old = oldShapes[shape.id], old == shape else { continue }
            Plan.take(ledger.outcome(for: old.span, deletesContent: deletesContent), id: shape.id, start: old.timelineStart, into: &plan.shapes)
        }
        let oldTexts = Dictionary(before.textOverlays.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for text in after.textOverlays {
            guard let old = oldTexts[text.id], old == text else { continue }
            Plan.take(ledger.outcome(for: old.span, deletesContent: deletesContent), id: text.id, start: old.timelineStart, into: &plan.texts)
        }
        let oldFilters = Dictionary(before.filters.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for filter in after.filters {
            guard let old = oldFilters[filter.id], old == filter else { continue }
            Plan.take(ledger.outcome(for: old.span, deletesContent: deletesContent), id: filter.id, start: old.timelineStart, into: &plan.filters)
        }
        let oldCues = Dictionary(before.allSubtitleCues.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for cue in after.allSubtitleCues {
            guard let old = oldCues[cue.id], old == cue else { continue }
            Plan.take(ledger.outcome(for: old.span, deletesContent: deletesContent), id: cue.id, start: old.start, into: &plan.cues)
        }

        // 这次操作自己挪过的段 / 文字 / 滤镜（拖动的成员）撞上了也要让开，和联动挪的一起交给落点。
        let movedByEdit = after.laneClips.filter { clip in oldClips[clip.id].map { $0.timelineStart != clip.timelineStart } ?? false }.map(\.id)
        let textsByEdit = after.textOverlays.filter { text in oldTexts[text.id].map { $0.timelineStart != text.timelineStart } ?? false }.map(\.id)
        let filtersByEdit = after.filters.filter { filter in oldFilters[filter.id].map { $0.timelineStart != filter.timelineStart } ?? false }.map(\.id)

        plan.apply(to: &after)
        TimelineLinkageLanding.settle(
            lanes: Set(plan.clips.moves.keys).union(movedByEdit),
            texts: Set(plan.texts.moves.keys).union(textsByEdit),
            filters: Set(plan.filters.moves.keys).union(filtersByEdit),
            in: &after
        )
        return plan.report
    }

    /// 算好了要挪谁、删谁，再一次写进去。
    struct Plan {
        struct Kind {
            var moves: [UUID: Double] = [:]
            var deletes: Set<UUID> = []
        }

        var clips = Kind()
        var shapes = Kind()
        var texts = Kind()
        var filters = Kind()
        var cues = Kind()

        var report: Report {
            let kinds = [clips, shapes, texts, filters, cues]
            return Report(moved: kinds.reduce(0) { $0 + $1.moves.count }, deleted: kinds.reduce(0) { $0 + $1.deletes.count })
        }

        static func take(_ outcome: Outcome, id: UUID, start: Double, into kind: inout Kind) {
            switch outcome {
            case .stay: break
            case .move(let delta): kind.moves[id] = max(0, start + delta)
            case .delete: kind.deletes.insert(id)
            }
        }

        func apply(to state: inout TimelineState) {
            for id in clips.deletes { state.remove(id) }
            for (id, start) in clips.moves { state.update(id) { $0.timelineStart = start } }
            if !shapes.deletes.isEmpty { state.shapes.removeAll { shapes.deletes.contains($0.id) } }
            for (id, start) in shapes.moves { state.updateShape(id) { $0.timelineStart = start } }
            if !texts.deletes.isEmpty { state.textOverlays.removeAll { texts.deletes.contains($0.id) } }
            for (id, start) in texts.moves { state.updateTextOverlay(id) { $0.timelineStart = start } }
            if !filters.deletes.isEmpty { state.filters.removeAll { filters.deletes.contains($0.id) } }
            for (id, start) in filters.moves { state.updateFilter(id) { $0.timelineStart = start } }
            if !cues.deletes.isEmpty || !cues.moves.isEmpty {
                state.editSubtitleTracks { original, companion in
                    SubtitleTrackEditing.removeCues(ids: cues.deletes, original: &original, companion: &companion)
                    SubtitleTrackEditing.setStarts(cues.moves, original: &original, companion: &companion)
                }
            }
            if !texts.deletes.isEmpty { state.compactTextRows() }
            if !filters.deletes.isEmpty { state.compactFilterLayers() }
        }
    }

    // MARK: 拖动计划要的名单

    /// 压在某几段主轨块上的一样东西。`host`：它底下最早的那段（磁吸下按这段实际落到哪再平一次，`realignCompanions`）。
    struct Attachment: Equatable {
        var id: UUID
        var span: TimelineSpan
        var host: UUID
    }

    /// 压在这几段主轨块上的东西：底下压着的主轨块**全在** `hosts` 里才算（跨到别的块上的不算 —— 松手之后由 `follow`
    /// 按规矩 3 决定跟不跟）。
    struct Attachments: Equatable {
        var clips: [Attachment] = []
        var shapes: [Attachment] = []
        var texts: [Attachment] = []
        var cues: [Attachment] = []
        var filters: [Attachment] = []

        static let none = Attachments()

        var ids: Set<UUID> {
            Set((clips + shapes + texts + cues + filters).map(\.id))
        }
    }

    static func attachments(of hosts: Set<UUID>, in state: TimelineState) -> Attachments {
        guard !hosts.isEmpty else { return .none }
        let pieces = state.mainClips.map(Piece.init)
        func attachment(_ id: UUID, _ span: TimelineSpan) -> Attachment? {
            let under = pieces.filter { $0.overlaps(span) }
            guard let first = under.first, under.allSatisfy({ hosts.contains($0.id) }) else { return nil }
            return Attachment(id: id, span: span, host: first.id)
        }
        var result = Attachments()
        result.clips = state.laneClips.compactMap { attachment($0.id, $0.span) }
        result.shapes = state.shapes.compactMap { attachment($0.id, $0.span) }
        result.texts = state.textOverlays.compactMap { attachment($0.id, $0.span) }
        result.cues = state.allSubtitleCues.compactMap { attachment($0.id, $0.span) }
        result.filters = state.filters.compactMap { attachment($0.id, $0.span) }
        return result
    }
}

// MARK: - 各种块的时间段（只给联动用的小读法）

extension TimelineState {
    /// 不在主轨上的段：上层轨 + 音频轨。
    var laneClips: [EditClip] { overlayTracks.flatMap(\.clips) + audioTracks.flatMap(\.clips) }
}

extension EditClip {
    var span: TimelineSpan { TimelineSpan(start: timelineStart, end: timelineEnd) }
}

extension ShapeAnnotation {
    var span: TimelineSpan { TimelineSpan(start: timelineStart, end: timelineEnd) }
}

extension TextOverlay {
    var span: TimelineSpan { TimelineSpan(start: timelineStart, end: timelineEnd) }
}

extension FilterClip {
    var span: TimelineSpan { TimelineSpan(start: timelineStart, end: timelineEnd) }
}

extension SubtitleCue {
    var span: TimelineSpan { TimelineSpan(start: start, end: end) }
}
