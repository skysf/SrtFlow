import AppKit
import SwiftUI

// MARK: - 时间线上的滤镜块与滤镜行
//
// 与 `TextBlockView` / `ShapeBlockView` 逐行同构，包括「拖动中只是渲染偏移、
// 松手才写模型」这条硬约束（理由见 `VideoEditProject.commitDrag`）。
//
// 只有一处不同：**层号进模型**。文字那边层号由重叠关系现算（纯显示用），
// 滤镜不行 —— LUT 不可交换，现算的层号会在用户拖动别的段时重排，画面跟着变。
// 所以这里按 `FilterClip.layer` 分行，而不是按重叠关系分。

/// 滤镜块的尺寸。与形状/文字块同一档（26pt 的细行）。
enum FilterBlockMetrics {
    static let height: Double = 20
    static let topInset: Double = 3
    static let minimumWidth: Double = 24
}

struct FilterBlockView: View, Equatable {
    let filter: FilterClip
    let pps: Double
    let isSelected: Bool
    /// 拖动中的渲染位移（秒）。nil = 没在被拖，按模型里的位置画。
    let dragOffset: Double?
    let onSelect: () -> Void
    let onDragBegin: () -> Void
    /// (手势总位移, 指针在滚动视口里的位置)。与剪辑块同一套语义。
    let onDragChange: (CGSize, CGPoint) -> Void
    let onDragEnd: () -> Void
    /// 分割工具下不给把手（与剪辑块同规矩）。
    let canTrim: Bool
    let onTrim: (Bool, Double) -> Void
    let onTrimEnd: () -> Void

    @State private var isMoving = false

    private var width: Double { max(FilterBlockMetrics.minimumWidth, filter.duration * pps) }

    /// 按值比较，只比画面用得到的输入（同 `ClipBlockView`）。闭包比不了、也不用比：
    /// 它们捕获的是时间线视图，读的是它的 `@State` 和工程对象，永远是最新的。
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.filter == rhs.filter && lhs.pps == rhs.pps && lhs.isSelected == rhs.isSelected
            && lhs.dragOffset == rhs.dragOffset && lhs.canTrim == rhs.canTrim
    }

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        HStack(spacing: 3) {
            Image(systemName: "camera.filters")
                .font(.system(size: 8))
            Text(filter.displayName)
                .font(.system(size: 9))
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 5)
        .frame(width: width, height: FilterBlockMetrics.height, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(TrackPalette.filterBlock)
        )
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 4).strokeBorder(.white, lineWidth: 1.5)
            }
        }
        // 把手要在 .offset 之前挂上，不然会留在块没偏移时的位置（同剪辑块）。
        .overlay(alignment: .leading) { trimHandle(leading: true) }
        .overlay(alignment: .trailing) { trimHandle(leading: false) }
        .offset(
            x: (filter.timelineStart + (dragOffset ?? 0)) * pps,
            y: FilterBlockMetrics.topInset
        )
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

    /// 与剪辑/形状/文字的裁切把手同款：太窄不给（点不到移动区），手势必须用
    /// `.global` —— 把手挂在块边缘，`.local` 会随裁切生效跟着块边移动，位移被
    /// 自己抵消。
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
                .pointerStyle(.columnResize)
        }
    }
}

// MARK: - 滤镜行

extension VideoEditTimelineView {

    func filterRow(layer: Int) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4)
                .fill(.quaternary.opacity(0.25))
                .frame(width: contentWidth)
            ForEach(project.state.filters(onLayer: layer)) { filter in
                FilterBlockView(
                    filter: filter,
                    pps: pps,
                    isSelected: project.selectedFilterID == filter.id,
                    // 滤镜和剪辑走**同一套**拖动会话（冻结候选、自由落点解析、
                    // 边缘自动滚动、松手落一次），理由同形状块。
                    dragOffset: dragOffset(movingID: filter.id),
                    onSelect: { project.selectFilter(filter.id) },
                    onDragBegin: { beginFilterDrag(filter) },
                    onDragChange: { translation, pointerViewport in
                        updateClipDrag(translation: translation, pointerViewport: pointerViewport)
                    },
                    onDragEnd: { endClipDrag() },
                    canTrim: project.activeTool == .select,
                    onTrim: { leading, delta in
                        project.clock.endPeek()
                        project.liveTrimFilter(filter.id, leading: leading, deltaSeconds: delta)
                    },
                    // 滤镜不参与 AV 合成（调色挂在播放器视图上），收尾不用重建预览。
                    onTrimEnd: { project.endLiveEdit(rebuildsPreview: false) }
                )
                // 按值比较：拖动每动一下时间线都重算，没变的块别跟着重算（见 `ClipBlockContext`）。
                .equatable()
            }
        }
    }
}
