import SwiftUI
import SrtFlowCore

// 字幕拖框：轨道上点选任一 cue 后叠在预览画面上（用户决定的语义）——
// 拖框体移动、拖左右边改换行宽度（把两行拖回一行）、拖角等比缩放字号。
// 改的是**工程级**布局（TimelineState.subtitleLayout）：一个框 = 该工程
// 全部字幕；预览（BurnInSubtitleOverlay.layout）与烧录（assStyle(layout:)）
// 共用同一份数值。复用 ResizableFrameBox（剪辑/形状同款）。
struct SubtitleFrameCanvas: View {
    @ObservedObject var project: VideoEditProject
    let boxSize: CGSize
    let style: BurnInStyle
    /// 当前字幕文本块的实测高度（BurnInSubtitleOverlay 回报）。
    let blockHeight: Double

    /// 手势开始时的（框, 布局）快照：角把手的字号倍率按它算绝对增量，
    /// 反复应用不叠加（与 ResizableFrameBox 自身的 startRect 同一纪律）。
    @State private var dragStart: (rect: CGRect, layout: SubtitleLayout)?

    private var scale: Double {
        boxSize.height / Double(BurnInStyle.referenceHeight)
    }

    /// 当前生效布局：还没有覆盖时从全局样式推导（第一次拖动就落成覆盖）。
    /// 覆盖的锚定固定为底部中心 —— 全局样式是九宫格时，推导只近似垂直位置。
    private var effectiveLayout: SubtitleLayout {
        if let layout = project.state.subtitleLayout { return layout }
        let blockUnits = blockHeight / max(scale, 0.0001)
        let reference = Double(BurnInStyle.referenceHeight)
        let bottom: Double
        switch style.position.row {
        case 0: bottom = Double(style.marginVertical)
        case 1: bottom = (reference - blockUnits) / 2
        default: bottom = reference - Double(style.marginVertical) - blockUnits
        }
        return SubtitleLayout(
            marginLeft: style.marginHorizontal,
            marginRight: style.marginHorizontal,
            marginBottom: Int(max(0, bottom).rounded()),
            fontScale: 1
        )
    }

    private var frameRect: CGRect {
        let layout = effectiveLayout
        let left = Double(layout.marginLeft) * scale
        let right = Double(layout.marginRight) * scale
        let bottom = Double(layout.marginBottom) * scale
        let height = max(blockHeight, 24)
        return CGRect(
            x: left,
            y: boxSize.height - bottom - height,
            width: max(boxSize.width - left - right, 30),
            height: height
        )
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ResizableFrameBox(
                rect: frameRect,
                bounds: boxSize,
                // 上下边把手不给：块高由内容和字号决定，不是可拖的自由度。
                handles: [
                    .leading, .trailing,
                    .topLeading, .topTrailing, .bottomLeading, .bottomTrailing
                ],
                keepAspectOnCorners: true,
                movable: true,
                onChange: { next in apply(next) },
                onEnd: {
                    dragStart = nil
                    project.endLiveEdit(rebuildsPreview: false)
                }
            )
        }
        .frame(width: boxSize.width, height: boxSize.height, alignment: .topLeading)
    }

    private func apply(_ next: CGRect) {
        if dragStart == nil { dragStart = (frameRect, effectiveLayout) }
        guard let start = dragStart, scale > 0 else { return }
        var layout = start.layout
        // 高度变了 = 角把手（等比）：字号倍率跟着框高走；移动/拉边高度不变。
        let heightFactor = start.rect.height > 1 ? next.height / start.rect.height : 1
        if abs(heightFactor - 1) > 0.001 {
            layout.fontScale = min(
                max(start.layout.fontScale * heightFactor, SubtitleLayout.fontScaleRange.lowerBound),
                SubtitleLayout.fontScaleRange.upperBound
            )
        }
        layout.marginLeft = Int(max(0, next.minX / scale).rounded())
        layout.marginRight = Int(max(0, (boxSize.width - next.maxX) / scale).rounded())
        layout.marginBottom = Int(max(0, (boxSize.height - next.maxY) / scale).rounded())
        project.liveSetSubtitleLayout(layout)
    }
}
