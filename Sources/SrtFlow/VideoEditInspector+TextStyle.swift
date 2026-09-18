import SwiftUI
import SrtFlowCore

// MARK: - 文字检查器：外观（填充 / 描边 / 投影 / 底板）
//
// 从 VideoEditInspector+Text.swift 再拆一层：那边是"写什么、排成什么样"，
// 这边是"长什么样"。两边加起来才是一个文字的全部可调项。
//
// ## 三个装饰为什么是可选值，不是「宽度设 0 就算关」
//
// 关掉再打开时，用户上次调好的颜色/偏移得留着。用 0 表达"关"的话，那些值
// 没地方存，每次重新打开都从默认值开始 —— 调一次投影要重来一遍。

extension VideoEditInspectorView {

    @ViewBuilder
    func textStyleSection(_ overlay: TextOverlay) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            fillRow(overlay)
            decorationRow(
                "Outline",
                isOn: strokeToggle(overlay),
                help: "Draw an outline around the letters"
            ) {
                if let stroke = liveOverlay(overlay).style.stroke {
                    HStack(spacing: 8) {
                        colorWell(get: { stroke.color }) { color in
                            update(overlay) { $0.stroke?.color = color }
                        }
                        labelledSlider(
                            "Width",
                            value: liveStrokeWidthBinding(overlay, fallback: stroke.width),
                            range: TextStroke.widthRange,
                            format: { String(format: "%.1f", $0) }
                        )
                    }
                }
            }
            decorationRow(
                "Shadow",
                isOn: shadowToggle(overlay),
                help: "Drop a soft shadow behind the letters"
            ) {
                if let shadow = liveOverlay(overlay).style.shadow {
                    VStack(alignment: .leading, spacing: 6) {
                        colorWell(get: { shadow.color }) { color in
                            update(overlay) { $0.shadow?.color = color }
                        }
                        labelledSlider(
                            "Offset X",
                            value: liveShadowBinding(overlay, \.offsetX, fallback: shadow.offsetX),
                            range: TextShadow.offsetRange,
                            format: { String(format: "%.0f", $0) }
                        )
                        labelledSlider(
                            "Offset Y",
                            value: liveShadowBinding(overlay, \.offsetY, fallback: shadow.offsetY),
                            range: TextShadow.offsetRange,
                            format: { String(format: "%.0f", $0) }
                        )
                        labelledSlider(
                            "Blur",
                            value: liveShadowBinding(overlay, \.blur, fallback: shadow.blur),
                            range: TextShadow.blurRange,
                            format: { String(format: "%.0f", $0) }
                        )
                    }
                }
            }
            decorationRow(
                "Backdrop",
                isOn: backgroundToggle(overlay),
                help: "Put a coloured plate behind the text"
            ) {
                if let background = liveOverlay(overlay).style.background {
                    VStack(alignment: .leading, spacing: 6) {
                        colorWell(get: { background.color }) { color in
                            update(overlay) { $0.background?.color = color }
                        }
                        labelledSlider(
                            "Corner",
                            value: liveBackgroundBinding(overlay, \.cornerRadius, fallback: background.cornerRadius),
                            range: TextBackground.cornerRadiusRange,
                            format: { String(format: "%.0f", $0) }
                        )
                        labelledSlider(
                            "Pad X",
                            value: liveBackgroundBinding(overlay, \.paddingX, fallback: background.paddingX),
                            range: TextBackground.paddingRange,
                            format: { String(format: "%.0f", $0) }
                        )
                        labelledSlider(
                            "Pad Y",
                            value: liveBackgroundBinding(overlay, \.paddingY, fallback: background.paddingY),
                            range: TextBackground.paddingRange,
                            format: { String(format: "%.0f", $0) }
                        )
                    }
                }
            }
        }
    }

    // MARK: - 填充

    /// 纯色 / 渐变是**同一个填充的两种形态**，不是两个并列的开关 ——
    /// 后者会产生「两个都设着，谁生效」这种没人答得上来的状态。
    @ViewBuilder
    private func fillRow(_ overlay: TextOverlay) -> some View {
        let fill = liveOverlay(overlay).style.fill
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Fill").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Picker("", selection: fillModeBinding(overlay)) {
                    Text("Solid").tag(false)
                    Text("Gradient").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 140)
            }
            switch fill {
            case .solid(let color):
                colorWell(get: { color }) { new in
                    update(overlay) { $0.fill = .solid(new) }
                }
            case .gradient(let from, let to, let angle):
                HStack(spacing: 8) {
                    colorWell(get: { from }) { new in
                        update(overlay) { $0.fill = .gradient(from: new, to: to, angleDegrees: angle) }
                    }
                    colorWell(get: { to }) { new in
                        update(overlay) { $0.fill = .gradient(from: from, to: new, angleDegrees: angle) }
                    }
                }
                labelledSlider(
                    "Angle",
                    value: liveGradientAngleBinding(overlay, fallback: angle),
                    range: 0...360,
                    format: { String(format: "%.0f°", $0) }
                )
            }
        }
    }

    // MARK: - 零件

    @ViewBuilder
    private func decorationRow<Content: View>(
        _ title: LocalizedStringKey,
        isOn: Binding<Bool>,
        help: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(title, isOn: isOn)
                .toggleStyle(.checkbox)
                .font(.caption)
                .instantHelp(help)
            content()
        }
    }

    private func colorWell(
        get: @escaping () -> SubtitleColor,
        set: @escaping (SubtitleColor) -> Void
    ) -> some View {
        ColorPicker("", selection: Binding(
            get: { get().swiftUIColor },
            set: { set(SubtitleColor($0)) }
        ), supportsOpacity: true)
        .labelsHidden()
    }

    private func update(_ overlay: TextOverlay, _ change: @escaping (inout TextStyle) -> Void) {
        project.updateTextOverlay(overlay.id) { change(&$0.style) }
    }

    // MARK: - 绑定
    //
    // 三个装饰的开关：打开时给一份默认值，关掉时置 nil。

    private func strokeToggle(_ overlay: TextOverlay) -> Binding<Bool> {
        Binding(
            get: { liveOverlay(overlay).style.stroke != nil },
            set: { on in update(overlay) { $0.stroke = on ? .default : nil } }
        )
    }

    private func shadowToggle(_ overlay: TextOverlay) -> Binding<Bool> {
        Binding(
            get: { liveOverlay(overlay).style.shadow != nil },
            set: { on in update(overlay) { $0.shadow = on ? .default : nil } }
        )
    }

    private func backgroundToggle(_ overlay: TextOverlay) -> Binding<Bool> {
        Binding(
            get: { liveOverlay(overlay).style.background != nil },
            set: { on in update(overlay) { $0.background = on ? .default : nil } }
        )
    }

    /// 切换纯色/渐变时**保住已经调好的颜色**：从纯色去渐变，起点色就是原来
    /// 那个色；从渐变回纯色，取起点色。跳回白色会让人以为配色被清了。
    private func fillModeBinding(_ overlay: TextOverlay) -> Binding<Bool> {
        Binding(
            get: { liveOverlay(overlay).style.fill.isGradient },
            set: { wantsGradient in
                update(overlay) { style in
                    let primary = style.fill.primaryColor
                    style.fill = wantsGradient
                        ? .gradient(from: primary, to: .white, angleDegrees: 90)
                        : .solid(primary)
                }
            }
        )
    }

    private func liveGradientAngleBinding(_ overlay: TextOverlay, fallback: Double) -> Binding<Double> {
        Binding(
            get: {
                guard case .gradient(_, _, let angle) = liveOverlay(overlay).style.fill else { return fallback }
                return angle
            },
            set: { value in
                project.beginLiveEdit()
                project.liveUpdateTextOverlay(overlay.id) { overlay in
                    guard case .gradient(let from, let to, _) = overlay.style.fill else { return }
                    overlay.style.fill = .gradient(from: from, to: to, angleDegrees: value)
                }
            }
        )
    }

    private func liveStrokeWidthBinding(_ overlay: TextOverlay, fallback: Double) -> Binding<Double> {
        Binding(
            get: { liveOverlay(overlay).style.stroke?.width ?? fallback },
            set: { value in
                project.beginLiveEdit()
                project.liveUpdateTextOverlay(overlay.id) { $0.style.stroke?.width = value }
            }
        )
    }

    private func liveShadowBinding(
        _ overlay: TextOverlay, _ keyPath: WritableKeyPath<TextShadow, Double>, fallback: Double
    ) -> Binding<Double> {
        Binding(
            get: { liveOverlay(overlay).style.shadow?[keyPath: keyPath] ?? fallback },
            set: { value in
                project.beginLiveEdit()
                project.liveUpdateTextOverlay(overlay.id) { $0.style.shadow?[keyPath: keyPath] = value }
            }
        )
    }

    private func liveBackgroundBinding(
        _ overlay: TextOverlay, _ keyPath: WritableKeyPath<TextBackground, Double>, fallback: Double
    ) -> Binding<Double> {
        Binding(
            get: { liveOverlay(overlay).style.background?[keyPath: keyPath] ?? fallback },
            set: { value in
                project.beginLiveEdit()
                project.liveUpdateTextOverlay(overlay.id) { $0.style.background?[keyPath: keyPath] = value }
            }
        )
    }
}
