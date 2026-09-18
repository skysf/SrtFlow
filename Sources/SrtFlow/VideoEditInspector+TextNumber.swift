import SwiftUI
import SrtFlowCore

// MARK: - 文字检查器：数字滚动
//
// 数字元件和普通文字共用同一个 `TextOverlay` —— 样式、动画、摆放、时间线
// 全都一样，只有**内容从哪来**不同。所以这里只替换"写什么"那一块，
// 底下的字体、外观、动画三区原样复用。
//
// 写入一律走 `perform`（离散）：这里全是下拉、开关、数值框的打字与步进，
// 没有一个是连续手势。合同见 VideoEditInspector+Text.swift 的「离散 vs 连续」。

extension VideoEditInspectorView {

    @ViewBuilder
    func numberSection(_ overlay: TextOverlay, _ roll: NumberRoll) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Style").font(.caption).foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .leading)
                Picker("", selection: numberBinding(overlay, \.style)) {
                    ForEach(NumberRollStyle.allCases) { style in
                        Text(LocalizedStringKey(style.title)).tag(style)
                    }
                }
                .labelsHidden()
                .instantHelp("Count up changes the whole number; Odometer rolls each digit on its own wheel")
            }

            numberValueRow(overlay, "From", roll: roll, keyPath: \.from)
            numberValueRow(overlay, "To", roll: roll, keyPath: \.to)

            // 横向拖动那条通道要的 live 绑定先落成一个 `live…` 开头的常量：
            // 名字得一路带着走，下游才看得出它需要结束信号
            //（合同见 VideoEditInspector+Text.swift 的「离散 vs 连续」）。
            let liveDuration = liveNumberBinding(overlay, \.duration)
            HStack(spacing: 6) {
                Text("Roll for").font(.caption).foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .leading)
                InspectorScrubbableNumberField(
                    value: numberBinding(overlay, \.duration),
                    range: NumberRoll.durationRange,
                    fractionDigits: 1,
                    width: 58,
                    onScrubBegin: { project.beginLiveEdit() },
                    onScrubChanged: { liveDuration.wrappedValue = $0 },
                    onScrubEnd: { project.endLiveEdit(rebuildsPreview: false) },
                    onScrubCancel: { project.cancelLiveEdit() }
                )
                Text("s").font(.caption2).foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }

            HStack(spacing: 6) {
                Text("Decimals").font(.caption).foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .leading)
                Stepper(
                    "\(roll.fractionDigits)",
                    value: numberBinding(overlay, \.fractionDigits),
                    in: NumberRoll.fractionDigitsRange
                )
                .font(.caption)
                .monospacedDigit()
                Spacer(minLength: 0)
                Toggle("Thousands", isOn: numberBinding(overlay, \.groupsThousands))
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .instantHelp("Group thousands with commas")
            }

            HStack(spacing: 6) {
                TextField("Prefix", text: numberBinding(overlay, \.prefix))
                TextField("Suffix", text: numberBinding(overlay, \.suffix))
            }
            .textFieldStyle(.roundedBorder)
            .font(.caption)

            Text("Numbers always use a comma for thousands and a period for the decimal point, so the same project renders identically on any machine.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func numberValueRow(
        _ overlay: TextOverlay, _ title: LocalizedStringKey,
        roll: NumberRoll, keyPath: WritableKeyPath<NumberRoll, Double>
    ) -> some View {
        let liveValue = liveNumberBinding(overlay, keyPath)
        return HStack(spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
            InspectorScrubbableNumberField(
                value: numberBinding(overlay, keyPath),
                // 范围给得很宽：标题里的数字什么量级都可能，夹太紧会让人
                // 以为打不进去。上界按 Double 仍能精确表示整数来定。
                range: -1_000_000_000...1_000_000_000,
                fractionDigits: roll.fractionDigits,
                width: 96,
                onScrubBegin: { project.beginLiveEdit() },
                onScrubChanged: { liveValue.wrappedValue = $0 },
                onScrubEnd: { project.endLiveEdit(rebuildsPreview: false) },
                onScrubCancel: { project.cancelLiveEdit() }
            )
            Spacer(minLength: 0)
        }
    }

    // MARK: - 绑定

    /// 离散写入。数字区里全是离散控件。
    private func numberBinding<Value>(
        _ overlay: TextOverlay, _ keyPath: WritableKeyPath<NumberRoll, Value>
    ) -> Binding<Value> {
        Binding(
            get: { (liveOverlay(overlay).number ?? .default)[keyPath: keyPath] },
            set: { value in
                project.updateTextOverlay(overlay.id) { $0.number?[keyPath: keyPath] = value }
            }
        )
    }

    /// 连续写入：只给数值框的横向拖动，有 `onScrubEnd` 收尾。
    private func liveNumberBinding(
        _ overlay: TextOverlay, _ keyPath: WritableKeyPath<NumberRoll, Double>
    ) -> Binding<Double> {
        Binding(
            get: { (liveOverlay(overlay).number ?? .default)[keyPath: keyPath] },
            set: { value in
                project.beginLiveEdit()
                project.liveUpdateTextOverlay(overlay.id) { $0.number?[keyPath: keyPath] = value }
            }
        )
    }
}
