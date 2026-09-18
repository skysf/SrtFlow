import SwiftUI
import SrtFlowCore

// MARK: - 文字检查器：内容与版面
//
// 单独成文件（单文件 ~800 行警戒线，同 VideoEditInspector+Transform.swift）。
// 外观那一半在 VideoEditInspector+TextStyle.swift。
//
// 所有改动都走 `project.updateTextOverlay`（一步撤销、不重建预览）；滑块拖动
// 中由 `labelledSlider` 统一在松手时收一次 `endLiveEdit`。

extension VideoEditInspectorView {

    @ViewBuilder
    func textSection(_ overlay: TextOverlay) -> some View {
        HStack(spacing: 6) {
            Image(systemName: overlay.number == nil ? "textformat" : "number")
                .foregroundStyle(.secondary)
            Text(overlay.number == nil ? "Text" : "Number").fontWeight(.semibold)
            Spacer()
            if overlay.number == nil {
                Button {
                    project.textEditingRequest = overlay.id
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .instantHelp("Edit this text on the preview")
            }
        }

        // 「写什么」这一块按内容来源分流；底下的字体、外观、动画三区
        // 数字和文字完全共用 —— 数字元件只是内容从别处来的文字。
        if let roll = liveOverlay(overlay).number {
            numberSection(overlay, roll)
        } else {
            // 内容：多行框。就地编辑那条路（画面双击）和这里写的是同一个字段，
            // 差别只有输入框在哪儿。
            TextField("Text", text: textBinding(overlay), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...6)
        }

        Divider()

        VStack(alignment: .leading, spacing: 8) {
            TextFontPicker(
                fontName: fontNameBinding(overlay),
                catalog: TextFontCatalogStore.shared
            )
            HStack(spacing: 8) {
                Toggle("Bold", isOn: styleBinding(overlay, \.bold))
                Toggle("Italic", isOn: styleBinding(overlay, \.italic))
                Spacer()
            }
            .toggleStyle(.checkbox)
            .font(.caption)

            labelledSlider(
                "Size",
                value: liveStyleBinding(overlay, \.fontSize),
                range: TextStyle.fontSizeRange,
                format: { String(format: "%.0f", $0) }
            )

            // 对齐只在多行（含自动折行）时看得出差别，但不因此隐藏 ——
            // 隐藏的控件会让人以为功能不存在，而换行随时可能发生。
            Picker("", selection: styleBinding(overlay, \.alignment)) {
                ForEach(TextBlockAlignment.allCases) { alignment in
                    // 分段控件里只有图标，旁白得靠它才念得出来。
                    Image(systemName: alignment.icon)
                        .accessibilityLabel(LocalizedStringKey(alignment.title))
                        .tag(alignment)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .instantHelp("How lines line up inside the text box")

            labelledSlider(
                "Box width",
                value: liveTextBinding(overlay, \.boxWidth),
                range: TextOverlay.boxWidthRange,
                format: { String(format: "%.0f%%", $0 * 100) }
            )
            labelledSlider(
                "Line height",
                value: liveStyleBinding(overlay, \.lineSpacing),
                range: TextStyle.lineSpacingRange,
                format: { String(format: "%.2f×", $0) }
            )
            labelledSlider(
                "Tracking",
                value: liveStyleBinding(overlay, \.letterSpacing),
                range: TextStyle.letterSpacingRange,
                format: { String(format: "%.0f", $0) }
            )
            labelledSlider(
                "Angle",
                value: liveTextBinding(overlay, \.rotationDegrees),
                range: -180...180,
                format: { String(format: "%.0f°", $0) }
            )
        }

        Divider()

        textStyleSection(overlay)

        Divider()

        textAnimationSection(overlay)

        Divider()

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Shows for").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.1fs", overlay.duration))
                    .font(.caption)
                    .monospacedDigit()
                Stepper("", value: textDurationBinding(overlay), in: 0.2...600, step: 0.5)
                    .labelsHidden()
            }
            Text(placementHint(overlay))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }

        HStack {
            Spacer()
            Button("Delete", systemImage: "trash", role: .destructive) {
                project.deleteTextOverlay(overlay.id)
            }
        }
    }

    // MARK: - 绑定
    //
    // 一律**读回模型里的当前值**而不是闭包捕获的那份：检查器的 body 会被
    // 时钟驱动着反复重建，捕获值会过期一拍，滑块就会来回跳。

    func liveOverlay(_ overlay: TextOverlay) -> TextOverlay {
        project.state.textOverlays.first { $0.id == overlay.id } ?? overlay
    }

    private func textBinding(_ overlay: TextOverlay) -> Binding<String> {
        Binding(
            get: { liveOverlay(overlay).text },
            set: { value in project.updateTextOverlay(overlay.id) { $0.text = value } }
        )
    }

    /// 摆放提示。抽成函数而不是内联三元表达式：本地化守卫扫的是
    /// `Text("字面量")` 这种调用点，三元里的字面量它一条都看不见，
    /// 而返回 `LocalizedStringKey` 的函数体是它扫得到的。
    private func placementHint(_ overlay: TextOverlay) -> LocalizedStringKey {
        if overlay.number != nil {
            return "Drag the number on the preview to place it, or its block on the timeline to retime it."
        }
        return "Drag the text on the preview to place it, or its block on the timeline to retime it. Double-click the text to edit the words."
    }

    // MARK: 离散 vs 连续
    //
    // **下拉、开关、数值框的打字与步进箭头一律走 `perform`（离散），
    // 只有滑块和横向拖动走 live。**
    //
    // 理由是 `liveApply` 的语义：它每次都从**手势开始时的那份快照**重新应用
    // 一次完整修改。滑块有「松手」信号（`labelledSlider` 会调 `endLiveEdit`
    // 把快照收掉），离散控件没有 —— 快照会一直挂着，下一次写入就从那份陈旧
    // 的状态出发，把上一次的改动一起抹掉。
    //
    // 2026-09-17 的现场：入场选了 Fade（快照里还是 None），再点秒数的步进
    // 箭头，Fade 当场退回 None。同一个错误也让「勾了粗体再拖字号」掉粗体。
    // 合同与 `clipAnimationSection` 一致（那里的数值框 setter 走 `setVideoFade`
    // = perform，只有 `onScrubChanged` 走 live）。

    /// 连续写入：滑块、横向拖动。调用方**必须**保证有结束信号
    /// （`labelledSlider` 自带；数值框靠 `onScrubEnd`）。
    func liveTextBinding(
        _ overlay: TextOverlay, _ keyPath: WritableKeyPath<TextOverlay, Double>
    ) -> Binding<Double> {
        Binding(
            get: { liveOverlay(overlay)[keyPath: keyPath] },
            set: { value in
                project.beginLiveEdit()
                project.liveUpdateTextOverlay(overlay.id) { $0[keyPath: keyPath] = value }
            }
        )
    }

    /// 离散写入：下拉、开关、数值框打字与步进。一次操作 = 一步撤销。
    func styleBinding<Value>(
        _ overlay: TextOverlay, _ keyPath: WritableKeyPath<TextStyle, Value>
    ) -> Binding<Value> {
        Binding(
            get: { liveOverlay(overlay).style[keyPath: keyPath] },
            set: { value in
                project.updateTextOverlay(overlay.id) { $0.style[keyPath: keyPath] = value }
            }
        )
    }

    /// 连续写入版本，同上。
    func liveStyleBinding(
        _ overlay: TextOverlay, _ keyPath: WritableKeyPath<TextStyle, Double>
    ) -> Binding<Double> {
        Binding(
            get: { liveOverlay(overlay).style[keyPath: keyPath] },
            set: { value in
                project.beginLiveEdit()
                project.liveUpdateTextOverlay(overlay.id) { $0.style[keyPath: keyPath] = value }
            }
        )
    }

    private func fontNameBinding(_ overlay: TextOverlay) -> Binding<String> {
        Binding(
            get: { liveOverlay(overlay).style.fontName },
            // 换字体是一次性选择，不是连续拖动：直接落一步撤销。
            set: { value in project.updateTextOverlay(overlay.id) { $0.style.fontName = value } }
        )
    }

    private func textDurationBinding(_ overlay: TextOverlay) -> Binding<Double> {
        Binding(
            get: { liveOverlay(overlay).duration },
            set: { value in project.updateTextOverlay(overlay.id) { $0.duration = value } }
        )
    }
}
