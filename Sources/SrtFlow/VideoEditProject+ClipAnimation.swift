import Foundation

// MARK: - 写入：画面段的入场 / 出场动画
//
// 模型与仲裁见 VideoEditClipAnimation.swift，逐帧求值见 VideoEditClipAnimator.swift。
//
// 三条写入通道，按 Inspector 数值框合同分（docs/architecture/inspector-scrub-number-field.md）：
//   · 离散（下拉选效果、数值框打字与步进箭头）→ `perform`，一次操作一步撤销；
//   · 连续（强度滑块、数值框横向拖调）→ `beginLiveEdit` / `liveApply` / `endLiveEdit`，
//     整次手势结成一步；
//   · 夹紧只写一份，两条通道共用，永不分叉。
//
// **入参一律收 `[UUID]`**：批量套用（多选时把同一套动画铺到所有选中段）是第二刀，
// 界面接上去就行，写入路径不必再改一次。单段调用点传 `[id]`。

extension VideoEditProject {

    // MARK: 时长（= 画面渐变，两者是同一个槽）

    /// 入/出场时长（时间线秒）。文本提交和箭头点击走这条，一次一步撤销。
    func setVideoFade(_ ids: [UUID], edge: FadeEdge, seconds: Double) {
        perform(videoFadeMutation(ids, edge: edge, seconds: seconds))
    }

    /// Inspector 数值框横向拖调用：同 `setVideoFade`，整次拖动结成一步。
    func liveSetVideoFade(_ ids: [UUID], edge: FadeEdge, seconds: Double) {
        liveApply(videoFadeMutation(ids, edge: edge, seconds: seconds))
    }

    /// 单段的便利写法（面板里选中一段时用）。
    func setVideoFade(_ id: UUID, edge: FadeEdge, seconds: Double) {
        setVideoFade([id], edge: edge, seconds: seconds)
    }

    func liveSetVideoFade(_ id: UUID, edge: FadeEdge, seconds: Double) {
        liveSetVideoFade([id], edge: edge, seconds: seconds)
    }

    /// 夹紧只写在这一份里，discrete 和 live 永不分叉（Inspector 数值框合同）。
    /// 与声音渐变逐字同构：这里只挡负数和 NaN，「不超过段长」由
    /// `EditClip.videoFades` 在读侧统一收口 —— 存的是用户设的意图，段被拉长
    /// 之后渐变应当跟着恢复，而不是在写入那一刻就被当时的段长永久截短。
    private func videoFadeMutation(
        _ ids: [UUID], edge: FadeEdge, seconds: Double
    ) -> (inout TimelineState) -> Void {
        let clamped = max(0, seconds.isFinite ? seconds : 0)
        return { state in
            for id in ids {
                state.update(id) { clip in
                    switch edge {
                    case .fadeIn: clip.videoFadeInDuration = clamped
                    case .fadeOut: clip.videoFadeOutDuration = clamped
                    }
                }
            }
        }
    }

    // MARK: 效果

    /// 选一种入场 / 出场效果。
    ///
    /// **效果和时长一起改**（不变量见 `ClipPresetAnimation.isEmpty`）：
    /// 选上效果时，那一侧还没有时长就给一个默认值 —— 否则用户选完 Rise
    /// 画面纹丝不动，只会以为功能坏了；选回 None 时把时长清零 ——
    /// 留着的话这一侧会退回"只有画面渐变"的老语义，界面显示"无"、画面还在淡，
    /// 而且下次打开工程会被解码迁移重新认成 Fade。
    func setClipPresetKind(_ ids: [UUID], edge: FadeEdge, kind: ClipPresetKind) {
        perform { state in
            for id in ids {
                state.update(id) { clip in
                    switch edge {
                    case .fadeIn:
                        clip.presetAnimation.entrance = kind
                        clip.videoFadeInDuration = Self.duration(
                            for: kind, current: clip.videoFadeInDuration
                        )
                    case .fadeOut:
                        clip.presetAnimation.exit = kind
                        clip.videoFadeOutDuration = Self.duration(
                            for: kind, current: clip.videoFadeOutDuration
                        )
                    }
                }
            }
        }
    }

    private static func duration(for kind: ClipPresetKind, current: Double) -> Double {
        guard kind != .none else { return 0 }
        return current > 0 ? current : ClipPresetAnimation.defaultDuration
    }

    // MARK: 强度

    /// 强度（0…1）。数值提交走这条。
    func setClipPresetIntensity(_ ids: [UUID], _ value: Double) {
        perform(intensityMutation(ids, value))
    }

    /// 强度滑块拖动中：整次拖动结成一步撤销。
    func liveSetClipPresetIntensity(_ ids: [UUID], _ value: Double) {
        liveApply(intensityMutation(ids, value))
    }

    private func intensityMutation(
        _ ids: [UUID], _ value: Double
    ) -> (inout TimelineState) -> Void {
        { state in
            for id in ids {
                state.update(id) { clip in
                    clip.presetAnimation.intensity = value
                    clip.presetAnimation.clampToValidRange()
                }
            }
        }
    }
}
