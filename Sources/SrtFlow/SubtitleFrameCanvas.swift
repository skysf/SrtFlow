import AppKit
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
    /// 框内双击 = 就地改这句的文字。
    ///
    /// 拖框盖在字幕块正上方，双击事件到不了下面那层的热区 —— 少了这一路，
    /// 「选中一条 cue 之后就没法双击改字了」，而选中恰恰是改字前的常态。
    var onDoubleClick: () -> Void = {}

    /// 手势开始时的（框, 布局）快照：角把手的字号倍率按它算绝对增量，
    /// 反复应用不叠加（与 ResizableFrameBox 自身的 startRect 同一纪律）。
    @State private var dragStart: (rect: CGRect, layout: SubtitleLayout)?

    /// 换算与定框的唯一实现，与就地编辑的输入框共用（SubtitleFrameGeometry）。
    private var geometry: SubtitleFrameGeometry {
        SubtitleFrameGeometry(
            boxSize: boxSize,
            style: style,
            layout: project.state.subtitleLayout,
            blockHeight: blockHeight
        )
    }

    private var scale: Double { geometry.scale }
    private var effectiveLayout: SubtitleLayout { geometry.effectiveLayout }
    private var frameRect: CGRect { geometry.frameRect }

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
                // 单击不做事（这条 cue 已经是选中的那条），只挑出双击。
                // 双击判据问 NSEvent 要 clickCount：再挂一个 count: 2 的
                // TapGesture 会和框内的移动手势抢，拖框当场变迟钝。
                onTap: { _ in
                    if (NSApp.currentEvent?.clickCount ?? 1) >= 2 { onDoubleClick() }
                },
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
