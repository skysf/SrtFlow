import SwiftUI

// MARK: - 检查器：盖一块（模糊 / 马赛克）
//
// 管什么：选中一块盖一块时的参数区 —— 名称 + 力度 + 大小 + 显示多久。它是形状的一种（时间线上的块、选中框、拖动、V 隐藏、复制粘贴
// 都是形状那一套），但不画东西，所以没有颜色 / 线宽 / 实心。力度（`coverAmount`）：模糊的半径 / 马赛克每格的边长，1080p 基准的像素。
// 不管什么：形状本身的参数区（`shapeSection`）、盖一块怎么盖（CoverPreviewLayer、VideoEditCoverExport）。
// 形状不参与 AV 合成（盖一块在预览里是图层，导出里是滤镜），松手不用重建预览（同 `updateShape`）。

extension VideoEditInspectorView {
    @ViewBuilder
    func coverSection(_ shape: ShapeAnnotation) -> some View {
        HStack(spacing: 6) {
            Image(systemName: shape.kind.icon).foregroundStyle(.secondary)
            Text(LocalizedStringKey(shape.kind.title)).fontWeight(.semibold)
            Spacer()
        }

        Divider()

        VStack(alignment: .leading, spacing: 8) {
            labelledSlider(
                "Strength",
                value: liveShapeBinding(shape, \.coverAmount),
                range: ShapeKind.coverAmountRange
            )
            labelledSlider("Width", value: liveShapeBinding(shape, \.width), range: 0.02...1, scale: 100, unit: "%")
            labelledSlider("Height", value: liveShapeBinding(shape, \.height), range: 0.02...1, scale: 100, unit: "%")
        }

        Divider()

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Shows for").font(.caption).foregroundStyle(.secondary)
                Spacer()
                InspectorDurationField(
                    value: shapeDurationBinding(shape),
                    onLiveChange: { seconds in
                        project.liveApply { $0.updateShape(shape.id) { $0.duration = seconds } }
                    },
                    project: project
                )
            }
            Text("Blurs or pixelates the picture under it — text, shapes and subtitles stay sharp. Drag its frame on the preview to place it.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Divider()

        Button("Delete Shape", systemImage: "trash", role: .destructive) {
            project.deleteShape(shape.id)
        }
        .controlSize(.small)
        .instantHelp("Remove this shape from the timeline", shortcut: .plain("⌫"))
    }
}
