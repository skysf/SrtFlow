import SwiftUI

// MARK: - 检查器里「Shows for」的秒数框
//
// 管什么：形状 / 文字的「显示多久」这一格 —— 能打字、能拖调（2026-09-24 用户拍板），
// 打字提交走离散绑定（一次一步），拖调走调用方给的 live 写入、松手一步撤销。
// 不管什么：秒数怎么写进模型（调用方给绑定和 live 写入）。

struct InspectorDurationField: View {
    /// 离散绑定（set 里 `perform` 一次）：打字提交和箭头走它。
    let value: Binding<Double>
    /// 拖调每一拍的 live 写入（`liveApply` / `liveUpdateTextOverlay`），松手由这里收快照。
    let onLiveChange: (Double) -> Void
    let project: VideoEditProject

    /// 与形状 / 文字的最短时长同一个数（0.2 秒），上限 10 分钟。
    static let range: ClosedRange<Double> = 0.2...600

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        InspectorScrubbableNumberField(
            value: value,
            range: Self.range,
            fractionDigits: 1,
            width: 54,
            onScrubBegin: { project.beginLiveEdit() },
            onScrubChanged: { onLiveChange(max(Self.range.lowerBound, $0)) },
            // 叠层自己会跟着状态重画，不用重建预览（同 updateShape / updateTextOverlay）。
            onScrubEnd: { project.endLiveEdit(rebuildsPreview: false) },
            onScrubCancel: { project.cancelLiveEdit() }
        )
        Text("s")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }
}
