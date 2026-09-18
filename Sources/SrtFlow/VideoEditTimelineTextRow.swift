import AppKit
import SwiftUI

// MARK: - 时间线上的文字块
//
// 从 VideoEditTimelineView.swift 拆出来（那个文件已 2000 行，远超仓库
// ~800 行警戒线）。块自己只管画和收手势，所有落点算法都在父级 ——
// 与 `ShapeBlockView` 逐行同构，包括「拖动中只是渲染偏移、松手才写模型」
// 这条硬约束（理由见 `VideoEditProject.commitDrag`）。

struct TextBlockView: View {
    let overlay: TextOverlay
    let pps: Double
    let isSelected: Bool
    /// 拖动中的渲染位移（秒）。nil = 没在被拖，按模型里的位置画。
    let dragOffset: Double?
    let onSelect: () -> Void
    /// 双击：跳到这段文字的起点并请求就地编辑。
    let onEdit: () -> Void
    let onDragBegin: () -> Void
    /// (手势总位移, 指针在滚动视口里的 x)。与剪辑块同一套语义。
    /// (手势总位移, 指针在滚动视口里的位置)。与剪辑块同一套语义。
    let onDragChange: (CGSize, CGPoint) -> Void
    let onDragEnd: () -> Void
    /// 分割工具下不给把手（与剪辑块同规矩）。
    let canTrim: Bool
    let onTrim: (Bool, Double) -> Void
    let onTrimEnd: () -> Void

    @State private var isMoving = false

    private var width: Double { max(TimelineMarquee.textMinimumWidth, overlay.duration * pps) }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "textformat")
                .font(.system(size: 8))
            Text(overlay.displayName)
                .font(.system(size: 9))
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 5)
        // 宽和高都与框选的命中判定共用常量（`TimelineMarquee`）：画多大就按多大判。
        .frame(width: width, height: TimelineMarquee.textHeight, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(TrackPalette.textBlock)
        )
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 4).strokeBorder(.white, lineWidth: 1.5)
            }
        }
        // 把手要在 .offset 之前挂上，不然会留在块没偏移时的位置（同剪辑块）。
        .overlay(alignment: .leading) { trimHandle(leading: true) }
        .overlay(alignment: .trailing) { trimHandle(leading: false) }
        .offset(x: (overlay.timelineStart + (dragOffset ?? 0)) * pps, y: TimelineMarquee.textTopInset)
        .zIndex(dragOffset != nil ? 10 : 0)
        // 双击在前：单击手势要让出双击，否则 SwiftUI 会先吃掉第一下。
        .onTapGesture(count: 2, perform: onEdit)
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

    /// 与剪辑/形状的裁切把手同款：太窄不给（点不到移动区），手势必须用 .global
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
                        .onChanged { value in onTrim(leading, value.translation.width / pps) }
                        .onEnded { _ in onTrimEnd() }
                )
                .onHover { inside in
                    if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                }
        }
    }
}

// MARK: - 文字行
//
// 行本体和块放在一起：层号由重叠关系算出来，不进模型。

extension VideoEditTimelineView {

    // MARK: - 文字行

    /// 这一层上的文字。层号纯显示用，由时间重叠关系算出来。
    func textOverlays(atLevel level: Int) -> [TextOverlay] {
        let levels = project.textOverlayLevels
        return project.state.textOverlays.enumerated()
            .filter { levels.indices.contains($0.offset) && levels[$0.offset] == level }
            .map(\.element)
    }

    func textRow(level: Int) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4)
                .fill(.quaternary.opacity(0.25))
                .frame(width: contentWidth)
            ForEach(textOverlays(atLevel: level)) { overlay in
                TextBlockView(
                    overlay: overlay,
                    pps: pps,
                    isSelected: isSelected(text: overlay.id),
                    // 文字和剪辑走**同一套**拖动会话（冻结候选、自由落点解析、
                    // 边缘自动滚动、松手落一次），理由同形状块。
                    dragOffset: dragOffset(movingID: overlay.id),
                    onSelect: {
                        let flags = NSApp.currentEvent?.modifierFlags ?? []
                        project.selectText(
                            overlay.id,
                            additive: flags.contains(.command) || flags.contains(.shift)
                        )
                    },
                    onEdit: {
                        // 播放头先落进这段文字的区间，否则预览里它根本不显示，
                        // 就地编辑的输入框会浮在一片空白上。
                        project.clock.endPeek()
                        clock.seek(to: overlay.timelineStart, precise: true)
                        project.selectText(overlay.id, additive: false)
                        // 数字元件不进就地编辑（内容在检查器里调）。
                        if overlay.number == nil { project.textEditingRequest = overlay.id }
                    },
                    onDragBegin: { beginTextDrag(overlay) },
                    onDragChange: { translation, pointerViewport in
                        updateClipDrag(translation: translation, pointerViewport: pointerViewport)
                    },
                    onDragEnd: { endClipDrag() },
                    canTrim: project.activeTool == .select,
                    onTrim: { leading, delta in
                        project.clock.endPeek()
                        project.liveTrimTextOverlay(overlay.id, leading: leading, deltaSeconds: delta)
                    },
                    // 文字不参与 AV 合成，收尾不用重建预览（同 updateTextOverlay）。
                    onTrimEnd: { project.endLiveEdit(rebuildsPreview: false) }
                )
            }
        }
    }

}
