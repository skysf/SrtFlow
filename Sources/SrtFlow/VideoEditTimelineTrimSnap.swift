import Foundation
import SrtFlowCore

// MARK: - 裁切时的吸附与对齐线
//
// 管什么：拉把手裁切时，哪一条边在动、它往哪边走、对着哪些点吸、裁完之后亮哪几条线。纯值，
// 在**手势开始时**的状态上算（`VideoEditProject.liveTrim` 拿 `liveEditOrigin` 喂进来，拖动中不变 =
// 冻结的候选，同拖动那一套：跟着一起动的东西不能当自己的参考点，否则粘手）。
// 不管什么：裁多少、谁一起裁（`TimelineTrim.members` / `trimGroup`，VideoEditTimelineTrim.swift）、
// 线画在哪（`TimelineTrimGuides`）。
//
// 规格（2026-09-25 讨论、2026-09-26 用户拍板「按 FCP 的方式来」）：
// - 看**真正在动的那条边**；一组一起裁时看整组最靠外那条（裁开头看最早的开头，裁结尾看最晚的结尾）。
// - 磁吸开着裁主轨段的开头：FCP 的做法是实时 ripple —— 段头贴着前一段不动，段尾连同后面整串实时往前缩。
//   在动的是段尾，所以吸的、亮线的都是（主轨成员里最靠后的）段尾；后面跟着挪的主轨段不当参考点。
// - 吸附距离和拖动一样（`TimelineSnap.thresholdPixels`，屏幕上 7pt）；吸附关掉 = 不吸也不亮线（调用方不给计划）。

/// 一轮裁切的吸附计划。
struct TrimSnapPlan: Equatable {
    /// 手势开始时，那条会动的边在哪（秒）。
    var edge: Double
    /// 边随手势的位移怎么走：+1 同向；-1 反向（磁吸开着裁主轨段开头：段尾往回缩）。
    var direction: Double
    /// 对齐点：不含这一组自己，也不含磁吸下会跟着 ripple 的主轨段。
    var candidates: [Double]

    /// 把手势要的量吸到最近的对齐点上；阈值外原样返回。吸完还要交给 `trimGroup` 按整组的范围夹一次。
    func snapped(_ requested: Double, pixelsPerSecond: Double) -> Double {
        let proposed = edge + direction * requested
        let threshold = TimelineSnap.thresholdPixels / max(pixelsPerSecond, 1)
        var best: Double?
        var bestDistance = threshold
        for candidate in candidates {
            let distance = abs(candidate - proposed)
            // 严格小于：平手时留住先出现的候选（同 `TimelineSnap.resolve`）。
            if distance < bestDistance {
                bestDistance = distance
                best = candidate
            }
        }
        guard let best else { return requested }
        return (best - edge) / direction
    }

    /// 真正裁了 `delta` 之后（整组夹过），那条边压着哪些对齐点 —— 要亮的线。
    /// 被夹住、没到吸附点的话一般是空的：**先夹再算线**，线和边才对得上。
    func guides(after delta: Double, pixelsPerSecond: Double) -> [Double] {
        TimelineSnap.alignedCandidates(
            start: edge + direction * delta, duration: 0, candidates: candidates, pixelsPerSecond: pixelsPerSecond
        )
    }
}

extension TimelineTrim {

    /// 这一组、这一边的吸附计划。成员都不在了就是 nil（没东西可裁，也就没有线）。
    ///
    /// - Parameters:
    ///   - magnet: 主轨磁吸开着没有（开着时主轨裁完会被 `packMain` 合拢，见文件开头）。
    ///   - playhead: 播放头此刻在哪（它也是对齐点，裁切中不会动）。
    static func snapPlan(
        members: [Member], leading: Bool, magnet: Bool, in state: TimelineState, playhead: Double
    ) -> TrimSnapPlan? {
        let spans = members.compactMap { member in state.trimSpan(of: member).map { (member, $0) } }
        guard !spans.isEmpty else { return nil }
        let movingIDs = Set(members.map(\.id))
        let mainIDs = Set(state.mainClips.map(\.id))
        let mainSpans = spans.filter { $0.0.kind == .clip && mainIDs.contains($0.0.id) }.map(\.1)

        // 磁吸开着、裁到了主轨：裁完 packMain，被裁的那段之后的整串主轨都会跟着挪 —— 它们不当参考点。
        var ripple: Set<UUID> = []
        if magnet, let firstMain = mainSpans.map(\.start).min() {
            ripple = Set(state.mainClips.filter { $0.timelineStart >= firstMain - 0.0005 }.map(\.id))
        }
        let candidates = TimelineSnap.candidates(
            in: state, moving: movingIDs.union(ripple), playhead: playhead
        )
        if magnet, leading, let lastMainEnd = mainSpans.map(\.end).max() {
            // FCP 式实时 ripple：段头不动，段尾随手势反着走。
            return TrimSnapPlan(edge: lastMainEnd, direction: -1, candidates: candidates)
        }
        let edge = leading ? spans.map(\.1.start).min()! : spans.map(\.1.end).max()!
        return TrimSnapPlan(edge: edge, direction: 1, candidates: candidates)
    }
}

extension TimelineState {
    /// 一个裁切成员在时间线上占的那一段（秒）。成员不在了就是 nil。
    func trimSpan(of member: TimelineTrim.Member) -> TimelineSpan? {
        switch member.kind {
        case .clip:
            return clip(with: member.id).map { TimelineSpan(start: $0.timelineStart, end: $0.timelineEnd) }
        case .shape:
            return shapes.first { $0.id == member.id }.map { TimelineSpan(start: $0.timelineStart, end: $0.timelineEnd) }
        case .text:
            return textOverlays.first { $0.id == member.id }
                .map { TimelineSpan(start: $0.timelineStart, end: $0.timelineEnd) }
        case .filter:
            return filters.first { $0.id == member.id }.map { TimelineSpan(start: $0.timelineStart, end: $0.timelineEnd) }
        case .cue:
            return subtitleCue(member.id).map { TimelineSpan(start: $0.start, end: $0.end) }
        }
    }
}
