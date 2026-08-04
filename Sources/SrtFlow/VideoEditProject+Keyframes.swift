import Foundation
import CoreGraphics

// MARK: - 关键帧操作（Inspector 的 ‹ ◇ › 与自动落帧）
//
// 约定（对齐 CapCut）：
// - ◇ 在播放头处打帧（写入当前生效值）；已压在帧上就删这帧。
// - 某行删掉最后一帧时，把此刻的值固化回静态字段 —— 画面不跳。
// - 行里有关键帧后，改数值/拖预览框自动在播放头处落新帧
//   （见 setPlacement/livePlace/setRotation/setClipOpacity 里的分支）。

extension VideoEditProject {
    /// Inspector 的四行：Position 行管 centerX+centerY，Scale 行管 width+height。
    enum KeyframeProperty: CaseIterable {
        case position, scale, rotation, opacity
    }

    /// 播放头在这段画面里吗（打帧按钮的可用条件）。
    func playheadInsideClip(_ clip: EditClip) -> Bool {
        let t = clock.time
        return t >= clip.timelineStart - 0.001 && t <= clip.timelineEnd + 0.001
    }

    /// 这一行有没有关键帧轨（有 → 改值自动落帧）。
    func hasKeyframes(_ clip: EditClip, _ property: KeyframeProperty) -> Bool {
        guard let animation = (state.clip(with: clip.id) ?? clip).animation else { return false }
        switch property {
        case .position: return !animation.centerX.isEmpty || !animation.centerY.isEmpty
        case .scale: return !animation.width.isEmpty || !animation.height.isEmpty
        case .rotation: return !animation.rotation.isEmpty
        case .opacity: return !animation.opacity.isEmpty
        }
    }

    /// 播放头正压在这一行的关键帧上吗（◇ 实心显示；点按变成删除）。
    func isOnKeyframe(_ clip: EditClip, _ property: KeyframeProperty) -> Bool {
        guard let live = state.clip(with: clip.id), let animation = live.animation else { return false }
        let source = live.sourceTime(atTimeline: clock.time)
        switch property {
        case .position:
            return animation.centerX.key(atSourceTime: source) != nil
                || animation.centerY.key(atSourceTime: source) != nil
        case .scale:
            return animation.width.key(atSourceTime: source) != nil
                || animation.height.key(atSourceTime: source) != nil
        case .rotation: return animation.rotation.key(atSourceTime: source) != nil
        case .opacity: return animation.opacity.key(atSourceTime: source) != nil
        }
    }

    /// ◇：播放头处打帧 / 删帧。
    func toggleKeyframe(_ id: UUID, _ property: KeyframeProperty) {
        guard let clip = state.clip(with: id), playheadInsideClip(clip) else { return }
        if isOnKeyframe(clip, property) {
            removeKeyframes(id, [property])
        } else {
            addKeyframes(id, [property])
        }
    }

    /// 标题行的 ◇：四行齐打；任一行压在帧上则四行齐删。
    func toggleAllKeyframes(_ id: UUID) {
        guard let clip = state.clip(with: id), playheadInsideClip(clip) else { return }
        if KeyframeProperty.allCases.contains(where: { isOnKeyframe(clip, $0) }) {
            removeKeyframes(id, KeyframeProperty.allCases)
        } else {
            addKeyframes(id, KeyframeProperty.allCases)
        }
    }

    /// ‹ ›：跳到上一/下一个关键帧（property nil = 所有轨的并集）。
    func seekToAdjacentKeyframe(_ id: UUID, _ property: KeyframeProperty?, forward: Bool) {
        guard let clip = state.clip(with: id), let animation = clip.animation else { return }
        let sourceTimes: [Double]
        switch property {
        case nil: sourceTimes = animation.allKeyTimes
        case .position:
            sourceTimes = merged(animation.centerX, animation.centerY)
        case .scale:
            sourceTimes = merged(animation.width, animation.height)
        case .rotation: sourceTimes = animation.rotation.keys.map(\.time)
        case .opacity: sourceTimes = animation.opacity.keys.map(\.time)
        }
        let times = sourceTimes.map { clip.timelineTime(atSource: $0) }
            .filter { $0 >= clip.timelineStart - 0.001 && $0 <= clip.timelineEnd + 0.001 }
            .sorted()
        let now = clock.time
        let target = forward
            ? times.first { $0 > now + KeyframeTrack.timeTolerance }
            : times.last { $0 < now - KeyframeTrack.timeTolerance }
        if let target {
            clock.seek(to: min(max(target, 0), duration), precise: true)
        }
    }

    /// 行复原：清掉这一行的关键帧轨，并把静态字段回到默认。
    func clearKeyframes(_ id: UUID, _ property: KeyframeProperty) {
        guard let clip = state.clip(with: id) else { return }
        let fallback = clip.defaultPlacement(canvas: renderSize, isOverlay: isOverlayClip(id))
        perform { state in
            state.update(id) { c in
                var animation = c.animation ?? ClipAnimation()
                switch property {
                case .position:
                    animation.centerX = KeyframeTrack()
                    animation.centerY = KeyframeTrack()
                    if var placement = c.placement {
                        placement.centerX = fallback.centerX
                        placement.centerY = fallback.centerY
                        c.placement = placement
                    }
                case .scale:
                    animation.width = KeyframeTrack()
                    animation.height = KeyframeTrack()
                    if var placement = c.placement {
                        placement.width = fallback.width
                        placement.height = fallback.height
                        c.placement = placement
                    }
                case .rotation:
                    animation.rotation = KeyframeTrack()
                    c.rotationDegrees = 0
                case .opacity:
                    animation.opacity = KeyframeTrack()
                    c.opacity = 1
                }
                c.animation = animation.isEmpty ? nil : animation
            }
        }
    }

    // MARK: 内部

    private func merged(_ a: KeyframeTrack, _ b: KeyframeTrack) -> [Double] {
        var times = a.keys.map(\.time)
        for key in b.keys
        where !times.contains(where: { abs($0 - key.time) < KeyframeTrack.timeTolerance }) {
            times.append(key.time)
        }
        return times
    }

    /// 打帧：写入播放头此刻的**生效值**（动画插值优先，其次静态）。
    private func addKeyframes(_ id: UUID, _ properties: [KeyframeProperty]) {
        guard let clip = state.clip(with: id) else { return }
        let t = clock.time
        let source = clip.sourceTime(atTimeline: t)
        let placement = clip.animatedPlacement(
            atTimeline: t, canvas: renderSize, isOverlay: isOverlayClip(id)
        )
        let rotation = clip.animatedRotation(atTimeline: t)
        let opacityValue = clip.animatedOpacity(atTimeline: t)
        perform { state in
            state.update(id) { c in
                var animation = c.animation ?? ClipAnimation()
                for property in properties {
                    switch property {
                    case .position:
                        animation.centerX.set(placement.centerX, atSourceTime: source)
                        animation.centerY.set(placement.centerY, atSourceTime: source)
                    case .scale:
                        animation.width.set(placement.width, atSourceTime: source)
                        animation.height.set(placement.height, atSourceTime: source)
                    case .rotation:
                        animation.rotation.set(rotation, atSourceTime: source)
                    case .opacity:
                        animation.opacity.set(opacityValue, atSourceTime: source)
                    }
                }
                c.animation = animation
            }
        }
    }

    /// 删帧；某行删空时把此刻的值固化回静态字段，画面不跳。
    private func removeKeyframes(_ id: UUID, _ properties: [KeyframeProperty]) {
        guard let clip = state.clip(with: id) else { return }
        let t = clock.time
        let source = clip.sourceTime(atTimeline: t)
        let placement = clip.animatedPlacement(
            atTimeline: t, canvas: renderSize, isOverlay: isOverlayClip(id)
        )
        let rotation = clip.animatedRotation(atTimeline: t)
        let opacityValue = clip.animatedOpacity(atTimeline: t)
        perform { state in
            state.update(id) { c in
                guard var animation = c.animation else { return }
                for property in properties {
                    switch property {
                    case .position:
                        animation.centerX.remove(atSourceTime: source)
                        animation.centerY.remove(atSourceTime: source)
                        if animation.centerX.isEmpty, animation.centerY.isEmpty {
                            var frozen = c.placement ?? placement
                            frozen.centerX = placement.centerX
                            frozen.centerY = placement.centerY
                            c.placement = frozen
                        }
                    case .scale:
                        animation.width.remove(atSourceTime: source)
                        animation.height.remove(atSourceTime: source)
                        if animation.width.isEmpty, animation.height.isEmpty {
                            var frozen = c.placement ?? placement
                            frozen.width = placement.width
                            frozen.height = placement.height
                            c.placement = frozen
                        }
                    case .rotation:
                        animation.rotation.remove(atSourceTime: source)
                        if animation.rotation.isEmpty { c.rotationDegrees = rotation }
                    case .opacity:
                        animation.opacity.remove(atSourceTime: source)
                        if animation.opacity.isEmpty { c.opacity = opacityValue }
                    }
                }
                c.animation = animation.isEmpty ? nil : animation
            }
        }
    }
}
