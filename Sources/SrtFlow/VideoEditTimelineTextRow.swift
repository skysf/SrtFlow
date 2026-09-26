import AppKit
import SwiftUI

// MARK: - 时间线上的文字块
//
// 从 VideoEditTimelineView.swift 拆出来（那个文件已 2000 行，远超仓库
// ~800 行警戒线）。块自己只管画和收手势，所有落点算法都在父级 ——
// 与 `ShapeBlockView` 逐行同构，包括「拖动中只是渲染偏移、松手才写模型」
// 这条硬约束（理由见 `VideoEditProject.commitDrag`）。

struct TextBlockView: View, Equatable {
    let overlay: TextOverlay
    let pps: Double
    /// 模型里的选中。拉框进行中的实时高亮另走 `marqueeHit`（看框不看模型）。
    let isSelected: Bool
    /// 拖动 / 拉框的会话盒子：只 `onReceive` 自己那份位移和框选命中（同 `ClipBlockView`）。
    let drag: TimelineDragBox
    /// 在不在这一轮拖动的成员里（时间线按 `dragMembers` 算好传进来，一轮只变两次）：
    /// 是成员才订阅位移，不是就拿一个永远不发的发布者（§0b）。
    let isDragMember: Bool
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
    /// 右键「隐藏 / 显示」：和 V 同一个动作，先替用户选中这一个（同剪辑块的右键项）。
    let onToggleHidden: () -> Void

    /// 拖动中的渲染位移（秒）。nil = 没在被拖，按模型里的位置画。从 `drag.$offsets` 收。
    @State private var dragOffset: Double?
    /// 拉框进行中这块在不在框里；nil = 没在拉框、或者和模型里一样，按 `isSelected` 画。
    @State private var marqueeHit: Bool?
    @State private var isMoving = false

    private var width: Double { max(TimelineMarquee.textMinimumWidth, overlay.duration * pps) }
    private var highlighted: Bool { marqueeHit ?? isSelected }

    /// 按值比较，只比画面用得到的输入（同 `ClipBlockView`）。闭包比不了、也不用比：
    /// 它们捕获的是时间线视图，读的是它的 `@State` 和工程对象，永远是最新的。
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.overlay == rhs.overlay && lhs.pps == rhs.pps && lhs.isSelected == rhs.isSelected
            && lhs.canTrim == rhs.canTrim && lhs.drag === rhs.drag && lhs.isDragMember == rhs.isDragMember
    }

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        HStack(spacing: 3) {
            Image(systemName: "textformat")
                .font(.system(size: 8))
            Text(overlay.displayName)
                .font(.system(size: 9))
                .lineLimit(1)
            // 灰显本身还不够（同剪辑块）：得看得出这一个是按 V 藏起来的。
            if overlay.isHidden {
                Image(systemName: "eye.slash").font(.system(size: 8))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 5)
        // 宽和高都与框选的命中判定共用常量（`TimelineMarquee`）：画多大就按多大判。
        .frame(width: width, height: TimelineMarquee.textHeight, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(TrackPalette.textBlock)
        )
        .timelineHiddenLook(overlay.isHidden)
        .overlay {
            if highlighted {
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
        .contextMenu {
            Button(overlay.isHidden ? "Show Text" : "Hide Text", action: onToggleHidden)
        }
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
        // 只收自己那份：位移 / 框选命中没变就不写 @State，这块就不重算（§0b）。
        .onReceive(drag.offsets(member: isDragMember)) { offsets in
            let mine = offsets.offset(for: overlay.id)
            if mine != dragOffset { dragOffset = mine }
        }
        .onReceive(drag.$marqueeHit) { hit in
            // 框里的和模型里的一样就记 nil：不然框一起手，全部块都从 nil 变成 false、各重算一遍。
            let mine = hit.map { $0.texts.contains(overlay.id) }.flatMap { $0 == isSelected ? nil : $0 }
            if mine != marqueeHit { marqueeHit = mine }
        }
    }

    /// 与剪辑/形状的裁切把手同款：太窄不给（点不到移动区），手势必须用 .global
    /// —— 把手挂在块边缘，.local 会随裁切生效跟着块边移动，位移被自己抵消。
    @ViewBuilder
    private func trimHandle(leading: Bool) -> some View {
        if width > 26, canTrim {
            Rectangle()
                .fill(highlighted ? .white.opacity(0.85) : .white.opacity(0.001))
                .frame(width: highlighted ? 5 : 8)
                .clipShape(RoundedRectangle(cornerRadius: 2))
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 2, coordinateSpace: .global)
                        .onChanged { value in onTrim(leading, value.translation.width / pps) }
                        .onEnded { _ in onTrimEnd() }
                )
                .pointerStyle(.columnResize)
        }
    }
}

// MARK: - 文字行
//
// 行本体和块放在一起。行号进模型（`TextOverlay.row`，VideoEditTextRows.swift）：
// 这一行画的就是 `row` 等于它的那些文字。

extension VideoEditTimelineView {

    // MARK: - 文字行

    func textRow(row: Int) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4)
                .fill(.quaternary.opacity(0.25))
                .frame(width: contentWidth)
            ForEach(project.state.textOverlays(onRow: row)) { overlay in
                TextBlockView(
                    overlay: overlay,
                    pps: pps,
                    isSelected: project.selectedTextIDs.contains(overlay.id),
                    // 文字和剪辑走**同一套**拖动会话（冻结候选、自由落点解析、
                    // 边缘自动滚动、松手落一次），理由同形状块；块自己从盒子里收位移（§0b）。
                    drag: dragBox,
                    isDragMember: dragMembers.contains(overlay.id),
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
                    onTrimEnd: { project.endLiveEdit(rebuildsPreview: false) },
                    onToggleHidden: {
                        project.selectText(overlay.id, additive: false)
                        project.toggleHiddenForSelection()
                    }
                )
                // 按值比较：拖动每动一下时间线都重算，没变的块别跟着重算（见 `ClipBlockContext`）。
                .equatable()
            }
        }
    }

}
