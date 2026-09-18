import AppKit
import SwiftUI

// MARK: - 形状行与形状块
//
// 从 `VideoEditTimelineView.swift` 拆出来（拆分前 2101 行，远超仓库约 800 行的
// 警戒线）。形状块与剪辑块逐行同构（同一套拖动会话、同一个坐标系、同款裁切把手），
// 区别只有落地时改的字段。
// 接线守卫 `checks/timeline-drag-wiring.sh` 按文件扫描，挪动这里的东西要同步改它。

extension VideoEditTimelineView {

    // MARK: - 形状行

    var shapesRow: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4)
                .fill(.quaternary.opacity(0.25))
                .frame(width: contentWidth)
            ForEach(project.state.shapes) { shape in
                ShapeBlockView(
                    shape: shape,
                    pps: pps,
                    isSelected: isSelected(shape: shape.id),
                    // 形状和剪辑走**同一套**拖动会话：冻结候选、自由落点解析、
                    // 边缘自动滚动、松手落一次。它每一拍写的也是同一个
                    // @Published TimelineState，「形状很轻」并不成立。
                    dragOffset: dragOffset(movingID: shape.id),
                    onSelect: {
                        let flags = NSApp.currentEvent?.modifierFlags ?? []
                        project.selectShape(
                            shape.id,
                            additive: flags.contains(.command) || flags.contains(.shift)
                        )
                    },
                    onDragBegin: { beginShapeDrag(shape) },
                    onDragChange: { translation, pointerViewport in
                        updateClipDrag(translation: translation, pointerViewport: pointerViewport)
                    },
                    onDragEnd: { endClipDrag() },
                    canTrim: project.activeTool == .select,
                    onTrim: { leading, delta in
                        project.clock.endPeek()
                        project.liveTrimShape(shape.id, leading: leading, deltaSeconds: delta)
                    },
                    // 形状不参与 AV 合成，收尾不用重建预览（同 updateShape）。
                    onTrimEnd: { project.endLiveEdit(rebuildsPreview: false) }
                )
            }
        }
    }

}

// MARK: - 形状块

private struct ShapeBlockView: View {
    let shape: ShapeAnnotation
    let pps: Double
    let isSelected: Bool
    /// 拖动中的渲染位移（秒）。nil = 没在被拖，按模型里的位置画。
    let dragOffset: Double?
    let onSelect: () -> Void
    let onDragBegin: () -> Void
    /// (手势总位移, 指针在滚动视口里的位置)。与剪辑块同一套语义。
    let onDragChange: (CGSize, CGPoint) -> Void
    let onDragEnd: () -> Void
    /// 分割工具下不给把手（与剪辑块同规矩）：父级传 `activeTool == .select`。
    let canTrim: Bool
    /// (leading, 手势开始以来的总位移秒数)。落到 `liveTrimShape`。
    let onTrim: (Bool, Double) -> Void
    let onTrimEnd: () -> Void

    @State private var isMoving = false
    @State private var isTrimming = false

    private var width: Double { max(TimelineMarquee.shapeMinimumWidth, shape.duration * pps) }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: shape.kind.icon)
                .font(.system(size: 8))
            Text(LocalizedStringKey(shape.kind.title))
                .font(.system(size: 9))
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 5)
        // 宽和高都与框选的命中判定共用常量（`TimelineMarquee`）：画多大就按多大判。
        .frame(width: width, height: TimelineMarquee.shapeHeight, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(shape.color.swiftUIColor.opacity(0.55))
        )
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 4).strokeBorder(.white, lineWidth: 1.5)
            }
        }
        // 把手要在 .offset 之前挂上，不然会留在块没偏移时的位置（同剪辑块）。
        .overlay(alignment: .leading) { trimHandle(leading: true) }
        .overlay(alignment: .trailing) { trimHandle(leading: false) }
        .offset(x: (shape.timelineStart + (dragOffset ?? 0)) * pps, y: TimelineMarquee.shapeTopInset)
        .zIndex(dragOffset != nil ? 10 : 0)
        .onTapGesture(perform: onSelect)
        .gesture(
            // 同剪辑块：块会在手指底下挪窝、自动滚动还会把内容抽走，
            // 坐标系必须钉在不动的滚动视口上，不能用 .local。
            DragGesture(minimumDistance: 4, coordinateSpace: .named(VideoEditTimelineView.scrollSpace))
                .onChanged { value in
                    if !isMoving {
                        isMoving = true
                        onDragBegin()
                    }
                    onDragChange(value.translation, value.location)
                }
                .onEnded { _ in
                    isMoving = false
                    onDragEnd()
                }
        )
    }

    /// 与剪辑块的裁切把手同款：太窄不给（点不到移动区），手势必须用 .global
    /// —— 把手挂在块边缘，.local 会随裁切生效跟着块边移动，位移被自己抵消。
    @ViewBuilder
    private func trimHandle(leading: Bool) -> some View {
        if width > 26, canTrim {
            Rectangle()
                .fill(isSelected ? .white.opacity(0.85) : .white.opacity(0.001))
                .frame(width: isSelected ? 5 : 8)
                .clipShape(RoundedRectangle(cornerRadius: 2))
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 2, coordinateSpace: .global)
                        .onChanged { value in
                            isTrimming = true
                            onTrim(leading, value.translation.width / pps)
                        }
                        .onEnded { _ in
                            isTrimming = false
                            onTrimEnd()
                        }
                )
                .onHover { inside in
                    if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                }
        }
    }
}
