import SwiftUI

// MARK: - 形状检查器：入场 / 出场动画
//
// 管什么：形状参数区里「动画」那一块：入场、出场各选一种效果 + 一个时长（和文字动画同一种排法，见
// VideoEditInspector+TextAnimation.swift）。没有强调、强度这些旋钮（docs/architecture/shapes.md「入场 / 出场动画」）。
// 不管什么：效果怎么求值、怎么画（`ShapeAnimator`、`ShapeOutline`），形状别的参数（`shapeSection`）。
// 下拉和数值框的打字 / 箭头走 perform，只有横向拖动走 live（合同见 checks/inspector-live-binding-wiring.sh）。

extension VideoEditInspectorView {

    @ViewBuilder
    func shapeAnimationSection(_ shape: ShapeAnnotation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Animation").font(.callout).fontWeight(.medium)
            shapeAnimationRow(
                shape, title: "In",
                kind: shapeAnimationBinding(shape, \.entrance),
                seconds: shapeAnimationBinding(shape, \.entranceDuration),
                liveSeconds: liveShapeAnimationBinding(shape, \.entranceDuration)
            )
            shapeAnimationRow(
                shape, title: "Out",
                kind: shapeAnimationBinding(shape, \.exit),
                seconds: shapeAnimationBinding(shape, \.exitDuration),
                liveSeconds: liveShapeAnimationBinding(shape, \.exitDuration)
            )
            // 入场 + 出场比这一块还长时被按比例收了（同一个 FadeWindow.clamped，数字对得上），当场说清楚。
            if shapeAnimationShortened(shape) {
                Text(L10n("In and out are longer than this shape lasts, so both were shortened to fit."))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 一行 = 一个槽：效果下拉 + 时长。选 None 时时长框收起来。
    @ViewBuilder
    private func shapeAnimationRow(
        _ shape: ShapeAnnotation, title: LocalizedStringKey,
        kind: Binding<ShapeAnimationKind>,
        seconds: Binding<Double>, liveSeconds: Binding<Double>
    ) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            Picker("", selection: kind) {
                ForEach(ShapeAnimationKind.allCases) { value in
                    Text(LocalizedStringKey(value.title)).tag(value)
                }
            }
            .labelsHidden()
            if kind.wrappedValue != .none {
                InspectorScrubbableNumberField(
                    value: seconds,
                    range: ShapeAnimation.durationRange,
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

    private func currentShape(_ shape: ShapeAnnotation) -> ShapeAnnotation {
        project.state.shapes.first { $0.id == shape.id } ?? shape
    }

    private func shapeAnimationShortened(_ shape: ShapeAnnotation) -> Bool {
        let live = currentShape(shape)
        let animation = live.animation
        let window = animation.window(span: live.duration)
        let asked = (animation.entrance == .none ? 0 : animation.entranceDuration)
            + (animation.exit == .none ? 0 : animation.exitDuration)
        return asked > live.duration + 0.005 && window.fadeIn + window.fadeOut > 0
    }

    /// 离散写入：下拉、数值框的打字与步进箭头。一次操作 = 一步撤销。
    private func shapeAnimationBinding<Value>(
        _ shape: ShapeAnnotation, _ keyPath: WritableKeyPath<ShapeAnimation, Value>
    ) -> Binding<Value> {
        Binding(
            get: { currentShape(shape).animation[keyPath: keyPath] },
            set: { value in project.updateShape(shape.id) { $0.animation[keyPath: keyPath] = value } }
        )
    }

    /// 连续写入：横向拖动时长。有结束信号（onScrubEnd）才能用。
    private func liveShapeAnimationBinding(
        _ shape: ShapeAnnotation, _ keyPath: WritableKeyPath<ShapeAnimation, Double>
    ) -> Binding<Double> {
        Binding(
            get: { currentShape(shape).animation[keyPath: keyPath] },
            set: { value in
                project.beginLiveEdit()
                project.liveApply { state in state.updateShape(shape.id) { $0.animation[keyPath: keyPath] = value } }
            }
        )
    }
}
