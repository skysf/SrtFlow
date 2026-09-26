import AppKit
import SwiftUI
import SrtFlowCore

// 字幕拖框：轨道上点选任一 cue 后叠在预览画面上（用户决定的语义）——
// 拖框体移动、拖左右边改换行宽度（把两行拖回一行）、拖角等比缩放字号。
// 改的是**那条轨**的布局（原文 `subtitleLayout` / 译文 `translationLayout`）：一个框 = 这条轨
// 全部字幕；预览（BurnInSubtitleOverlay.layout）与烧录（assStyle(layout:)）共用同一份数值。
// 复用 ResizableFrameBox（剪辑/形状同款）。
//
// 两条轨叠在一起时（译文没有自己的布局，计划 S7/S8）：框只框选中那条轨的几行；一拖两条就此分开 ——
// 被拖的跟手，另一条换成自己的布局钉在原地（不跳）。
struct SubtitleFrameCanvas: View {
    let project: VideoEditProject
    let frames: SubtitlePreviewFrames
    /// 选中那句所在的那一块（叠在一起时是两条轨的那一块）。
    let block: SubtitleScreenBlock
    /// 选中那句在哪条轨上：框只框它的几行，拖它就改它的布局。
    let track: SubtitleTrack
    /// 框内双击 = 就地改这句的文字。
    ///
    /// 拖框盖在字幕块正上方，双击事件到不了下面那层的热区 —— 少了这一路，
    /// 「选中一条 cue 之后就没法双击改字了」，而选中恰恰是改字前的常态。
    var onDoubleClick: () -> Void = {}

    /// 手势开始时的快照：框、布局（角把手的字号倍率按它算绝对增量，反复应用不叠加 ——
    /// 与 ResizableFrameBox 自身的 startRect 同一纪律），以及叠在一起时另一条轨要钉在哪。
    @State private var dragStart: DragStart?

    private struct DragStart {
        var rect: CGRect
        var layout: SubtitleLayout
        var pinned: SubtitleLayout?
    }

    /// 换算与定框的唯一实现，与就地编辑的输入框共用（SubtitleFrameGeometry）。
    private var geometry: SubtitleFrameGeometry { frames.geometry(of: block) }
    private var frameRect: CGRect { frames.rect(of: track, in: block) }

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        ZStack(alignment: .topLeading) {
            ResizableFrameBox(
                rect: frameRect,
                bounds: frames.boxSize,
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
        .frame(width: frames.boxSize.width, height: frames.boxSize.height, alignment: .topLeading)
    }

    private func apply(_ next: CGRect) {
        let geometry = self.geometry
        if dragStart == nil {
            let fontScale = geometry.effectiveLayout.fontScale
            // 叠在一起：另一条轨此刻那几行在哪，就钉在哪。
            let other = block.isStacked ? block.tracks.first { $0 != track } : nil
            dragStart = DragStart(
                rect: frameRect,
                layout: geometry.layout(for: frameRect, fontScale: fontScale),
                pinned: other.map { geometry.layout(for: frames.rect(of: $0, in: block), fontScale: fontScale) }
            )
        }
        guard let start = dragStart, geometry.scale > 0 else { return }
        var layout = geometry.layout(for: next, fontScale: start.layout.fontScale)
        // 高度变了 = 角把手（等比）：字号倍率跟着框高走；移动/拉边高度不变。
        let heightFactor = start.rect.height > 1 ? next.height / start.rect.height : 1
        if abs(heightFactor - 1) > 0.001 {
            layout.fontScale = min(
                max(start.layout.fontScale * heightFactor, SubtitleLayout.fontScaleRange.lowerBound),
                SubtitleLayout.fontScaleRange.upperBound
            )
        }
        project.liveSetSubtitleLayout(layout, for: track, pinning: start.pinned)
    }
}
