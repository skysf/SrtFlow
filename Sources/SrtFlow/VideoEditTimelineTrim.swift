import Foundation
import SrtFlowCore

// MARK: - 裁切：一段能裁多少、一组一起裁
//
// 管什么：时间线上每一种块（剪辑 / 形状 / 文字 / 滤镜 / 字幕 cue）裁一边能走的范围、
// 按同一个量裁一组（每个成员各自的范围取交集 —— **谁先到头整组一起停**）、以及真把它们裁掉。
// 不管什么：裁哪一组（选择、链接由 VideoEditProject 定）、手势（块的把手）。
//
// 2026-09-25 用户拍板：选中的块一起裁，同一条边、同一个量；链接开着时链接伙伴跟着一起裁
//（案例 docs/bugfixes/2026-09-25-trim-ignores-linked-clips.md）。
// 长期约束见 docs/architecture/timeline-drag-gestures.md「3.6 多段一起裁」。

enum TimelineTrim {
    enum Kind: Hashable, Sendable {
        case clip, shape, text, filter, cue
    }

    struct Member: Hashable, Sendable {
        var id: UUID
        var kind: Kind
    }

    /// 剪辑裁到最短还剩多少（和以前 `liveTrim` 里的 0.1 同一个数）。
    static let clipMinimumDuration = 0.1
    /// 字幕 cue 裁到最短还剩多少。
    static let cueMinimumDuration = 0.1

    /// 拉 `anchor` 的把手时一起裁的名单（2026-09-25 用户拍板：所有能选中的都算）：
    /// - 拉的那个块在选中集合里 → 整个选择（剪辑、形状、文字、cue；含隐藏轨上被 ⌘A 选中的剪辑）；
    /// - 没选中 → 只有它自己；
    /// - 链接开着时，名单里每一段剪辑的链接伙伴都跟着（和挪、切、删同一条语义）；
    /// - 滤镜段（框选 / ⌘A 选中的）也算一份，和别的一起裁。
    /// 顺序固定（按 id），同一份输入永远同一份名单。
    static func members(
        anchor: Member,
        selectedClips: Set<UUID>, selectedShapes: Set<UUID>, selectedTexts: Set<UUID>, selectedCues: Set<UUID>,
        selectedFilters: Set<UUID> = [],
        linkage: Bool, in state: TimelineState
    ) -> [Member] {
        let anchored: Bool
        switch anchor.kind {
        case .clip: anchored = selectedClips.contains(anchor.id)
        case .shape: anchored = selectedShapes.contains(anchor.id)
        case .text: anchored = selectedTexts.contains(anchor.id)
        case .cue: anchored = selectedCues.contains(anchor.id)
        case .filter: anchored = selectedFilters.contains(anchor.id)
        }
        var clips: Set<UUID> = anchor.kind == .clip ? [anchor.id] : []
        var shapes: Set<UUID> = anchor.kind == .shape ? [anchor.id] : []
        var texts: Set<UUID> = anchor.kind == .text ? [anchor.id] : []
        var cues: Set<UUID> = anchor.kind == .cue ? [anchor.id] : []
        var filters: Set<UUID> = anchor.kind == .filter ? [anchor.id] : []
        if anchored {
            clips.formUnion(selectedClips)
            shapes.formUnion(selectedShapes)
            texts.formUnion(selectedTexts)
            cues.formUnion(selectedCues)
            filters.formUnion(selectedFilters)
        }
        if linkage {
            for id in clips { clips.formUnion(state.linkedClipIDs(of: id)) }
        }
        func sorted(_ ids: Set<UUID>, _ kind: Kind) -> [Member] {
            ids.sorted { $0.uuidString < $1.uuidString }.map { Member(id: $0, kind: kind) }
        }
        return sorted(clips, .clip) + sorted(shapes, .shape) + sorted(texts, .text) + sorted(cues, .cue)
            + sorted(filters, .filter)
    }

    /// 整组能一起走的量：每个成员的范围取交集，再把要求的量夹进去。交集为空（有人一步都
    /// 不能动）就是 0 —— 整组不动，不会出现「别人动了、它没动」。
    static func clamp(_ requested: Double, ranges: [ClosedRange<Double>]) -> Double {
        var lower = -Double.infinity
        var upper = Double.infinity
        for range in ranges {
            lower = max(lower, range.lowerBound)
            upper = min(upper, range.upperBound)
        }
        guard lower <= upper, requested.isFinite else { return 0 }
        return min(max(requested, lower), upper)
    }
}

extension TimelineState {
    /// 这一段的这一边能走的范围（秒；负 = 往左）。成员不在了就是 nil（整组照样算，少它一个）。
    /// 起点端：往左最多退到素材开头 / 时间线 0，往右最多缩到最短时长；终点端反之。
    func trimRange(_ member: TimelineTrim.Member, leading: Bool) -> ClosedRange<Double>? {
        switch member.kind {
        case .clip:
            guard let clip = clip(with: member.id) else { return nil }
            let shrink = clip.timelineDuration - TimelineTrim.clipMinimumDuration
            if leading {
                return (-(clip.sourceStart / clip.speed))...max(0, shrink)
            }
            let extend = (clip.assetDuration - clip.sourceStart - clip.sourceDuration) / clip.speed
            return (-max(0, shrink))...max(0, extend)
        case .shape:
            guard let shape = shapes.first(where: { $0.id == member.id }) else { return nil }
            return overlayRange(start: shape.timelineStart, duration: shape.duration, minimum: 0.2, leading: leading)
        case .text:
            guard let overlay = textOverlays.first(where: { $0.id == member.id }) else { return nil }
            return overlayRange(start: overlay.timelineStart, duration: overlay.duration,
                                minimum: TextOverlay.minimumDuration, leading: leading)
        case .filter:
            guard let filter = filters.first(where: { $0.id == member.id }) else { return nil }
            return overlayRange(start: filter.timelineStart, duration: filter.duration,
                                minimum: FilterClip.minimumDuration, leading: leading)
        case .cue:
            guard let cue = subtitleCue(member.id) else { return nil }
            return overlayRange(start: cue.start, duration: cue.end - cue.start,
                                minimum: TimelineTrim.cueMinimumDuration, leading: leading)
        }
    }

    /// 叠层类（形状 / 文字 / 滤镜 / cue）没有素材边界：起点端最多退到 0，终点端随便拉长。
    private func overlayRange(start: Double, duration: Double, minimum: Double, leading: Bool) -> ClosedRange<Double> {
        let shrink = max(0, duration - minimum)
        return leading ? (-start)...shrink : (-shrink)...Double.infinity
    }

    /// 按同一个量裁一组：先按每个成员的范围取交集夹一次，再逐个裁。返回真正走的量。
    @discardableResult
    mutating func trimGroup(_ members: [TimelineTrim.Member], leading: Bool, by requested: Double) -> Double {
        let ranges = members.compactMap { trimRange($0, leading: leading) }
        let delta = TimelineTrim.clamp(requested, ranges: ranges)
        guard delta != 0 else { return 0 }
        for member in members { trim(member, leading: leading, by: delta) }
        return delta
    }

    /// 真把一段裁掉 `delta`。调用方先经 `trimGroup` 夹过；这里再按它自己的范围夹一次，
    /// 单独调也不会裁出负时长。
    mutating func trim(_ member: TimelineTrim.Member, leading: Bool, by requested: Double) {
        guard let range = trimRange(member, leading: leading) else { return }
        let delta = min(max(requested, range.lowerBound), range.upperBound)
        switch member.kind {
        case .clip:
            update(member.id) { clip in
                if leading {
                    clip.sourceStart += delta * clip.speed
                    clip.sourceDuration -= delta * clip.speed
                    clip.timelineStart += delta
                } else {
                    clip.sourceDuration += delta * clip.speed
                }
            }
        case .shape:
            updateShape(member.id) { shape in
                if leading { shape.timelineStart += delta; shape.duration -= delta } else { shape.duration += delta }
            }
        case .text:
            updateTextOverlay(member.id) { overlay in
                if leading { overlay.timelineStart += delta; overlay.duration -= delta } else { overlay.duration += delta }
            }
        case .filter:
            updateFilter(member.id) { filter in
                if leading { filter.timelineStart += delta; filter.duration -= delta } else { filter.duration += delta }
            }
        case .cue:
            guard let cue = subtitleCue(member.id) else { return }
            // 只改这句所在的那条轨（和挪 cue 同一份合同）；改完重排 + 重编号在 setTime 里。
            editSubtitleTracks {
                SubtitleTrackEditing.setTime(
                    id: member.id,
                    start: leading ? cue.start + delta : cue.start,
                    end: leading ? cue.end : cue.end + delta,
                    original: &$0, companion: &$1
                )
            }
        }
    }
}
