import SwiftUI

// MARK: - 检查器里的滑杆行
//
// 管什么：标题 + 滑杆 + **能打字的数值框**这一行（2026-09-24 用户拍板：所有滑杆行都能打字），
// 以及「打字提交 / 箭头 / 拖调 / 滑杆松手」四种输入怎么落到 live 编辑的一步撤销上。
// 不管什么：值本身怎么写进模型（调用方给的 live 绑定）、数值框的手势（InspectorScrubbableNumberField）。
//
// 调用方一律经 `VideoEditInspectorView.labelledSlider(…)`（`checks/inspector-live-binding-wiring.sh`
// 把它算作滑块位置：live 绑定只准接在这里）。

/// 一行：`Text(title)` 68pt + `Slider` + 数值框 50pt + 单位 10pt，放得进检查器那条约 220pt 的窄栏
/// （docs/architecture/inspector-layout.md）。
///
/// `value` 是 live 绑定（每写一次都从手势起点的快照重放）。滑杆松手时 `endLiveEdit` 收快照；
/// 数值框的**打字提交和箭头**没有松手信号，所以给它的绑定在 set 里写完立刻 `endLiveEdit`
/// （`fieldBinding`）—— 一次提交一步撤销，快照不会挂着把下一次改动抹掉。框上的拖调走
/// `onScrub*` 四个回调，和滑杆一样整次一步。
struct InspectorSliderRow: View {
    let title: LocalizedStringKey
    let value: Binding<Double>
    let range: ClosedRange<Double>
    /// 松手 / 提交时要不要重建预览合成（画面段的属性要 true，叠层不用）。
    let rebuildsPreview: Bool
    /// 模型值 × scale = 框里的数（0…1 的百分比传 100）。
    let scale: Double
    let fractionDigits: Int
    let unit: String
    /// 只拿来收 / 放 live 编辑的快照，不订阅。
    let project: VideoEditProject

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        HStack(spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 68, alignment: .leading)
            Slider(value: value, in: range, onEditingChanged: { editing in
                if !editing { project.endLiveEdit(rebuildsPreview: rebuildsPreview) }
            })
            InspectorScrubbableNumberField(
                value: fieldBinding,
                range: (range.lowerBound * scale)...(range.upperBound * scale),
                fractionDigits: fractionDigits,
                width: 50,
                onScrubBegin: { project.beginLiveEdit() },
                onScrubChanged: { value.wrappedValue = $0 / scale },
                onScrubEnd: { project.endLiveEdit(rebuildsPreview: rebuildsPreview) },
                onScrubCancel: { project.cancelLiveEdit() }
            )
            if !unit.isEmpty {
                Text(verbatim: unit)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 10, alignment: .leading)
            }
        }
    }

    /// 数值框的绑定：读 = 模型值换算成框里的数；写 = 经同一条 live 绑定写入，然后**立刻收掉
    /// 快照**（打字提交、箭头都是一次一步，没有松手信号）。
    private var fieldBinding: Binding<Double> {
        Binding(
            get: { value.wrappedValue * scale },
            set: { shown in
                value.wrappedValue = shown / scale
                project.endLiveEdit(rebuildsPreview: rebuildsPreview)
            }
        )
    }
}
