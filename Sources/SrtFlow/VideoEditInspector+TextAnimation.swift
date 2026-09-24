import SwiftUI
import SrtFlowCore

// MARK: - 文字检查器：动画
//
// 三个槽（入场 / 出场 / 强调）+ 一个强度，**没有更多旋钮**。
// 质感来自缓动曲线、逐字错峰间隔、回弹幅度这些用户调不出来的东西，
// 摊开只会让人调出难看的结果还以为是功能不行。

extension VideoEditInspectorView {

    @ViewBuilder
    func textAnimationSection(_ overlay: TextOverlay) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Animation").font(.callout).fontWeight(.medium)

            animationRow(
                overlay, title: "In",
                kind: animationBinding(overlay, \.entrance),
                seconds: animationBinding(overlay, \.entranceDuration),
                liveSeconds: liveAnimationBinding(overlay, \.entranceDuration)
            )
            animationRow(
                overlay, title: "Out",
                kind: animationBinding(overlay, \.exit),
                seconds: animationBinding(overlay, \.exitDuration),
                liveSeconds: liveAnimationBinding(overlay, \.exitDuration)
            )

            HStack(spacing: 6) {
                Text("Emphasis").font(.caption).foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .leading)
                Picker("", selection: animationBinding(overlay, \.emphasis)) {
                    ForEach(TextEmphasisKind.allCases) { kind in
                        Text(LocalizedStringKey(kind.title)).tag(kind)
                    }
                }
                .labelsHidden()
                .instantHelp("Runs the whole time the text is on screen")
            }

            if !liveOverlay(overlay).animation.isEmpty {
                labelledSlider(
                    "Intensity",
                    value: liveAnimationBinding(overlay, \.intensity),
                    range: TextAnimation.intensityRange,
                    scale: 100, unit: "%"
                )
            }
            // 只在真选了对焦时才露出来：它对别的效果没有意义，
            // 摆在那儿只会让人以为自己漏设了什么。
            if liveOverlay(overlay).animation.usesFocus {
                labelledSlider(
                    "Start at",
                    value: liveAnimationBinding(overlay, \.focusStartOpacity),
                    range: TextAnimation.focusStartOpacityRange,
                    scale: 100, unit: "%"
                )
            }

            ForEach(animationNotes(overlay), id: \.self) { note in
                // 已经是查过表的文本，走 Text 的 StringProtocol 重载（逐字显示）。
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 一行 = 一个槽：效果下拉 + 时长。效果选 None 时时长框收起来 ——
    /// 一个不生效的数字框只会让人怀疑自己是不是漏设了什么。
    @ViewBuilder
    private func animationRow(
        _ overlay: TextOverlay, title: LocalizedStringKey,
        kind: Binding<TextAnimationKind>,
        seconds: Binding<Double>, liveSeconds: Binding<Double>
    ) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            Picker("", selection: kind) {
                ForEach(TextAnimationKind.allCases) { value in
                    Text(LocalizedStringKey(value.title)).tag(value)
                }
            }
            .labelsHidden()
            if kind.wrappedValue != .none {
                InspectorScrubbableNumberField(
                    // `value` 是**离散**通道（打字、步进箭头），横向拖动另走
                    // 下面三个回调 —— 与 `clipAnimationSection` 同一份合同。
                    value: seconds,
                    range: TextAnimation.durationRange,
                    fractionDigits: 1,
                    width: 52,
                    onScrubBegin: { project.beginLiveEdit() },
                    onScrubChanged: { liveSeconds.wrappedValue = $0 },
                    onScrubEnd: { project.endLiveEdit(rebuildsPreview: false) },
                    onScrubCancel: { project.cancelLiveEdit() }
                )
                Text("s").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    /// 当场说清楚三件容易让人以为"坏了"的事。
    /// 返回**已经查过表的文本**，不是 `LocalizedStringKey`：
    /// 一来后者不是 Hashable，`ForEach` 挂不上去；二来经 `L10n(...)` 之后
    /// 本地化守卫才扫得到这几条文案（它认调用点，不认 return 后面的裸字面量）。
    private func animationNotes(_ overlay: TextOverlay) -> [String] {
        let live = liveOverlay(overlay)
        let animation = live.animation
        var notes: [String] = []

        // 一、选了描边生长却没开描边 —— 什么都不会发生。
        if (animation.entrance.needsStroke || animation.exit.needsStroke), live.style.stroke == nil {
            notes.append(L10n("Draw on needs an outline — turn on Outline above."))
        }

        // 二、入场 + 出场比这段文字还长，被按比例收了。判据与声音/画面渐变
        //     共用同一个 `FadeWindow.clamped`，所以数字一定对得上。
        let window = animation.window(span: live.duration)
        let asked = (animation.entrance == .none ? 0 : animation.entranceDuration)
            + (animation.exit == .none ? 0 : animation.exitDuration)
        if asked > live.duration + 0.005, window.fadeIn + window.fadeOut > 0 {
            notes.append(L10n("In and out are longer than this text lasts, so both were shortened to fit."))
        }

        // 三、对焦那个滑块调到两头时观感差别很大，当场说清楚它在控什么。
        if animation.usesFocus {
            if animation.focusStartOpacity >= 0.99 {
                notes.append(L10n("Focus starts fully opaque — like a camera pulling into focus."))
            } else if animation.focusStartOpacity <= 0.01 {
                notes.append(L10n("Focus fades in from nothing, so the camera-focus feel is gone."))
            }
        }

        // 四、循环动画会让导出多渲不少帧 —— 用户有权知道代价从哪来。
        if animation.emphasis != .none, live.duration > 20 {
            notes.append(L10n("A looping animation on a long text makes exporting slower."))
        }
        return notes
    }

    // MARK: 离散 vs 连续（合同见 VideoEditInspector+Text.swift 的同名小节）

    /// 离散写入：下拉、数值框的打字与步进箭头。一次操作 = 一步撤销。
    private func animationBinding<Value>(
        _ overlay: TextOverlay, _ keyPath: WritableKeyPath<TextAnimation, Value>
    ) -> Binding<Value> {
        Binding(
            get: { liveOverlay(overlay).animation[keyPath: keyPath] },
            set: { value in
                project.updateTextOverlay(overlay.id) { $0.animation[keyPath: keyPath] = value }
            }
        )
    }

    /// 连续写入：滑块、横向拖动。有结束信号才能用。
    private func liveAnimationBinding(
        _ overlay: TextOverlay, _ keyPath: WritableKeyPath<TextAnimation, Double>
    ) -> Binding<Double> {
        Binding(
            get: { liveOverlay(overlay).animation[keyPath: keyPath] },
            set: { value in
                project.beginLiveEdit()
                project.liveUpdateTextOverlay(overlay.id) { $0.animation[keyPath: keyPath] = value }
            }
        )
    }
}
