import SwiftUI

// MARK: - 画面渐入渐出
//
// 单独成文件（单文件 ~800 行警戒线，同 VideoEditInspector+Transform.swift）。
// 模型与两条管线的落点见 VideoEditVideoFade.swift；数值框合同见
// docs/architecture/inspector-scrub-number-field.md。

extension VideoEditInspectorView {
    /// 画面的渐入/渐出：秒数按时间线算（变速之后），0 = 关。
    ///
    /// 和声音的渐变行逐字同构（同一个数值框合同、同一套夹紧、同一条转场
    /// 仲裁），只是写到 `videoFade*` 上。放在 Transform 区后面 —— 它是画面
    /// 属性，不是声音属性。
    @ViewBuilder
    func videoFadeSection(_ clip: EditClip, location: ClipLocation?) -> some View {
        Divider()
        VStack(alignment: .leading, spacing: 6) {
            Text("Fade").font(.callout).fontWeight(.medium)
            videoFadeRow(clip, edge: .fadeIn, title: "Fade in")
            videoFadeRow(clip, edge: .fadeOut, title: "Fade out")
            // 只在真设了渐变时才解释「渐变到什么」：没设的时候这行是纯噪音，
            // 而 Transform 区下面本来就已经挤了。
            if !clip.videoFades.isEmpty {
                Text(videoFadeHint(location))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let note = videoFadeNote(clip, location: location) {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 渐变露出来的是这一段**底下那一层**，而底下是什么随轨道不同 ——
    /// 主轨底下是黑场，上层轨底下是主轨画面。不说清楚的话，用户在上层轨设了
    /// 淡入却没看到「变黑」，会以为是坏了。
    private func videoFadeHint(_ location: ClipLocation?) -> LocalizedStringKey {
        if let location, case .overlay = location.track {
            return "On an upper track the clip fades to and from whatever is on the track below, not to black."
        }
        return "On the bottom track the clip fades to and from black."
    }

    private func videoFadeRow(
        _ clip: EditClip, edge: FadeEdge, title: LocalizedStringKey
    ) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            InspectorScrubbableNumberField(
                value: videoFadeBinding(clip, edge: edge),
                // 上限是段长：整段淡入淡出是合理诉求，比这更长没有意义。
                range: 0...max(0.1, clip.timelineDuration),
                fractionDigits: 1,
                width: 54,
                onScrubBegin: { project.beginLiveEdit() },
                onScrubChanged: { project.liveSetVideoFade(clip.id, edge: edge, seconds: $0) },
                onScrubEnd: { project.endLiveEdit() },
                onScrubCancel: { project.cancelLiveEdit() }
            )
            Text("s")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .instantHelp(edge == .fadeIn
            ? LocalizedStringKey("Seconds for the picture to ramp up from fully transparent")
            : LocalizedStringKey("Seconds for the picture to ramp down to fully transparent"))
    }

    /// 主轨接缝上有转场时，那一边的画面渐变不生效（转场自己在做交叉淡变）——
    /// 判据与声音那边同一个来源（`transitionOverlap`），文案也对仗。
    private func videoFadeNote(_ clip: EditClip, location: ClipLocation?) -> LocalizedStringKey? {
        guard let location, location.track.isMain else { return nil }
        let fades = clip.videoFades
        let index = location.clipIndex
        let suppressedIn = index > 0
            && project.state.transitionOverlap(afterMainIndex: index - 1) > 0
            && fades.fadeIn > 0
        let suppressedOut = project.state.transitionOverlap(afterMainIndex: index) > 0
            && fades.fadeOut > 0
        guard suppressedIn || suppressedOut else { return nil }
        return "A transition already cross-fades the picture at that seam, so the fade on that side is skipped."
    }

    private func videoFadeBinding(_ clip: EditClip, edge: FadeEdge) -> Binding<Double> {
        Binding(
            get: {
                let live = project.state.clip(with: clip.id) ?? clip
                return edge == .fadeIn ? live.videoFadeInDuration : live.videoFadeOutDuration
            },
            set: { project.setVideoFade(clip.id, edge: edge, seconds: $0) }
        )
    }
}
