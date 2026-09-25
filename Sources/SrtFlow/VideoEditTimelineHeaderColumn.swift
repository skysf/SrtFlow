import AppKit
import SwiftUI

// MARK: - 左侧轨道头列
//
// 轨道色条 + 类型图标 + 音量推子 + 整轨隐藏的眼睛，行高和右边的轨道行严格一致。
// 推子（2026-09-23）只在能出声的轨上（主轨 / 上层视频轨 / 音频轨）；最上面的标尺行
// 放**总推子**（那一格原来是空的）。推子本体在 VideoEditTrackFader.swift。
// 2026-09-24 起学 Logic：按住轨道头**上下拖 = 整条轨换位置**（上层轨之间、音频轨之间，
// 接线在 `VideoEditTimelineLaneReorder.swift`）；拖轨道头的**下边缘**调**这一条**轨的
// 行高（一轨一个高度，接线在 `VideoEditTimelineRowHeightDrag.swift`）；点一下
//（非眼睛的地方）选中这一行的全部素材。
//
// 它在滚动区**外面**（横向滚动不该把轨道头滚走），所以时间线纵向滚动时得自己
// 跟上：`.offset(y: -geometry.offset.y)`。这是**唯一**一处订阅
// `TimelineScrollGeometry` 的地方之一（另一处是钉住的标尺）——
// 单拎成一个视图就是为了让滚动的每一帧只重画这一列，而不是整棵时间线视图树
// （docs/architecture/timeline-drag-gestures.md §5b）。

struct TimelineHeaderColumn: View {
    /// 轨道头列自己的坐标系：钉在不随滚动走的外框上。换位置、调行高两个拖动都量在它
    /// 上面 —— 被拖的行自己会挪（换位跟着指针、调行高时下边缘跟着长），以行自己为
    /// 参照的 translation 会被自己的位移污染（§1 那条规则）。
    static let space = "timelineHeaderColumn"

    let rows: [VideoEditTimelineView.RowSpec]
    let rowSpacing: Double
    /// 拉开的插入缝垫在哪一行上面（和轨道行垫**同一行、同一段**，§5h）。nil = 没有缝。
    let gapRowID: String?
    let project: VideoEditProject
    /// 纵向滚动量的推送值：只有这一列和标尺订阅它。
    @ObservedObject var geometry: TimelineScrollGeometry
    @Binding var resizeBase: RowHeightDragState?
    /// 正在进行的整轨换位（§5i）。时间线主体持有它：轨道行要跟着同一份位移走。
    @Binding var reorder: LaneReorderSession?
    /// 拖到视口上下边缘时推 NSScrollView 的心跳（和拖块共用一台）。
    let autoScroller: TimelineAutoScroller
    /// 可见视口的高度：换位拖到上下边缘时自动滚动要拿它判断到没到边。
    let viewportHeight: Double

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        // **这一列不许决定时间线的高度。** 它的固有高度是所有行加起来（十来条轨
        // 就 500pt 往上），直接摆在 HStack 里的话，整条时间线会按这个高度去要
        // 地方 —— VSplitView 给不了那么多，工具栏和标尺就被挤出窗口。
        // `Color.clear` 的固有尺寸是弹性的：面板给多少就是多少，真正的那一列
        // 画在它上面、超出的部分裁掉。
        Color.clear
            .frame(width: TimelineHeaderMetrics.columnWidth)
            .overlay(alignment: .top) { column }
            .clipped()
            // `.clipped()` 只裁绘制不裁命中：没有这一条，滚出视口的那些眼睛
            // 按钮照样点得中（同块内装饰那条老教训）。
            .contentShape(Rectangle())
            .coordinateSpace(name: Self.space)
    }

    private var column: some View {
        let lanes = LaneReorderContext.make(for: rows)
        return VStack(alignment: .center, spacing: rowSpacing) {
            ForEach(rows) { row in
                TimelineHeaderRow(
                    row: row,
                    project: project,
                    resizeBase: $resizeBase,
                    lane: lanes[row.id],
                    reorder: $reorder,
                    autoScroller: autoScroller,
                    scroll: geometry,
                    viewportHeight: viewportHeight
                )
                // 缝和换位的位移都垫在行**外面**：`TimelineHeaderRow` 的输入不变，它在
                // 时钟每跳一下时就照旧不重算（docs/architecture/preview-perf-ratchet.md）。
                .padding(.top, row.id == gapRowID ? TimelineSeams.gapExtra : 0)
                .laneReorderOffset(reorder, rowID: row.id)
            }
        }
        .padding(.vertical, TimelineRowMetrics.inset)
        // 轨道行是**同一份 `rows`** 排出来的，所以只要减掉同一个纵向滚动量，
        // 两边就永远对得上（不用各自去量位置）。
        .offset(y: -geometry.offset.y)
    }
}

// MARK: - 三格的固定宽度

/// 轨道头一行的排版尺寸。
///
/// **每一格都必须写死宽度。** 以前是「色条 + 图标 + 眼睛」直接塞进居中的 HStack：
/// `film` 比 `music.note` 宽、字幕行压根没有色条，于是每一行的 HStack 总宽都不
/// 一样，居中之后色条和眼睛的 x **一行一个样**（2026-09-18 用户报的「这一列要
/// 对齐」）。每格宽度固定 → 每行总宽相同 → 居中即对齐，不用去量任何位置。
/// 2026-09-23 加了推子那一格（没有推子的行照样占着），整列从 54pt 宽到 132pt。
enum TimelineHeaderMetrics {
    static let columnWidth: Double = 132
    static let accentWidth: Double = 3
    static let iconWidth: Double = 16
    static let faderWidth: Double = 78
    static let faderHeight: Double = 14
    static let eyeWidth: Double = 14
    static let spacing: Double = 3
    /// 下边缘调行高的那一条有多高，以及伸出行外多少（伸进行与行之间 5pt 的缝里，
    /// 不碰下一行）。
    static let resizeEdge: Double = 8
    static let resizeEdgeOverhang: Double = 3
}

// MARK: - 轨道头的一行

private struct TimelineHeaderRow: View {
    let row: VideoEditTimelineView.RowSpec
    let project: VideoEditProject
    @Binding var resizeBase: RowHeightDragState?
    /// 这一行能不能拖着换位置（nil = 不能：主轨、非轨道行、这一组只有它一条）。
    /// **输入只许是值**：这一行在时钟每跳一下时不重算，靠的是输入每次都「相等」。
    let lane: LaneReorderContext?
    @Binding var reorder: LaneReorderSession?
    let autoScroller: TimelineAutoScroller
    /// 滚动量的现读入口。**不订阅**（不是 @ObservedObject）：订阅了的话，滚动的每一帧
    /// 整列行都要重算；这里只在手势回调里现读一次。
    let scroll: TimelineScrollGeometry
    let viewportHeight: Double

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        let dragging = reorder?.rowID == row.id
        reorderHint(
            Group {
                if row.isRuler {
                    masterStrip
                } else {
                    HStack(spacing: TimelineHeaderMetrics.spacing) {
                        accent
                        icon
                        fader
                        eye
                    }
                }
            }
            .frame(width: TimelineHeaderMetrics.columnWidth, height: row.height)
            // 被拖着换位的那一行垫个底色：它压在别的行上面跟着指针走，一眼认得出是哪条。
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(dragging ? Color.accentColor.opacity(0.18) : Color.clear)
            )
            .contentShape(Rectangle())
            // 点一下（非眼睛的地方）= 选中这一行的全部素材。眼睛是 Button，它自己
            // 把点击吃掉，落不到这里。换位是 `minimumDistance: 3` 的拖动，没挪动的
            // 点击不会被它吃掉（和时间线空白处「点 = 移播放头、拖 = 框选」同一种分法）。
            .onTapGesture { selectRow() }
            .gesture(reorderGesture, including: lane == nil ? .subviews : .all)
            .pointerStyle(lane == nil ? nil : (dragging ? .grabActive : .grabIdle))
        )
        // 调行高挪到下边缘（2026-09-24，学 Logic）：盖在行上面的一条，它自己的手势先认。
        .overlay(alignment: .bottom) { resizeEdge }
    }

    // MARK: 换位置（§5i）

    /// 能换位的行才挂提示；主轨、非轨道行的轨道头上拖了也没反应，别让提示说谎。
    @ViewBuilder
    private func reorderHint<Content: View>(_ content: Content) -> some View {
        if lane != nil {
            content.instantHelp("Drag up or down to move this track")
        } else {
            content
        }
    }

    /// 按住轨道头上下拖 = 整条轨换位置。拖动中只写视图状态（`reorder`），松手才
    /// `moveLane` 落一次（一步撤销）。
    private var reorderGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(TimelineHeaderColumn.space))
            .onChanged { value in
                guard let lane else { return }
                var session = reorder
                // 新的一轮：没有会话、别的行的、或者起点变了（上一轮的 onEnded 没来）。
                if session?.rowID != row.id || session?.startY != value.startLocation.y {
                    session = LaneReorderSession(
                        context: lane,
                        rowID: row.id,
                        startY: value.startLocation.y,
                        originScrollY: scroll.offsetY
                    )
                }
                guard var next = session else { return }
                next.translation = value.translation.height
                publish(next)
                // 拖到视口上下边缘：纵向自动滚动，被拖的那条轨照样跟着指针（横向不碰）。
                autoScroller.update(
                    pointer: CGPoint(x: 0, y: value.location.y),
                    viewport: CGSize(width: 0, height: viewportHeight)
                ) {
                    guard var current = reorder, current.rowID == row.id else { return }
                    current.scrolled = scroll.offsetY - current.originScrollY
                    publish(current)
                }
            }
            .onEnded { _ in
                autoScroller.stop()
                guard let session = reorder, session.rowID == row.id else { return }
                reorder = nil
                let move = session.arrayMove
                project.moveLane(session.context.group, from: move.from, to: move.to)
            }
    }

    /// 落点变了的那一拍，其余行带动画让开；被拖的那一行自己不动画（`laneReorderOffset`）。
    private func publish(_ next: LaneReorderSession) {
        if next.resolution.destination != reorder?.resolution.destination {
            withAnimation(LaneReorderSession.animation) { reorder = next }
        } else {
            reorder = next
        }
    }

    // MARK: 调行高（下边缘）

    /// 下边缘那一条：上下拖调**这一条**轨的行高。只有视频轨 / 音频轨有。
    @ViewBuilder
    private var resizeEdge: some View {
        if row.heightKey != nil, TrackRowKind(row.slot).heightRange != nil {
            Color.clear
                .frame(height: TimelineHeaderMetrics.resizeEdge)
                .contentShape(Rectangle())
                .modifier(RowHeightDragModifier(
                    kind: TrackRowKind(row.slot),
                    key: row.heightKey,
                    project: project,
                    session: $resizeBase
                ))
                .offset(y: TimelineHeaderMetrics.resizeEdgeOverhang)
        }
    }

    // MARK: 三格

    /// 轨道色条：与这条轨上所有块同色。空轨在时间线上一个块都没有，只有它能
    /// 告诉用户那是哪条轨。没有色条的行（文字/形状/字幕）**也占着这一格**，
    /// 否则那几行的图标和眼睛会整体左移。
    @ViewBuilder
    private var accent: some View {
        Group {
            if let slot = row.slot {
                Capsule()
                    .fill(project.state.trackAccent(for: slot))
                    .frame(width: TimelineHeaderMetrics.accentWidth, height: max(10, row.height - 10))
                    .opacity(row.isHidden ? 0.3 : 1)
            } else {
                Color.clear
            }
        }
        .frame(width: TimelineHeaderMetrics.accentWidth)
    }

    private var icon: some View {
        Image(systemName: row.icon)
            .font(.caption)
            .foregroundStyle(row.isHidden ? .tertiary : .secondary)
            .frame(width: TimelineHeaderMetrics.iconWidth)
    }

    /// 这条轨的推子。没有推子的行（字幕 / 文字 / 形状 / 滤镜）一样占着这一格 ——
    /// 少了它，那几行的眼睛就会跑到别人推子的位置上。
    @ViewBuilder
    private var fader: some View {
        Group {
            if let slot = row.slot {
                TrackFaderView(
                    value: project.state.trackVolume(for: slot),
                    isMaster: false,
                    isDimmed: row.isHidden,
                    onLive: { project.previewTrackVolume($0, for: slot) },
                    onCommit: { project.setTrackVolume($0, for: slot) },
                    meter: row.heightKey.map {
                        TrackMeterSource(engine: project.meters, key: .track($0), clock: project.clock)
                    }
                )
                .frame(height: TimelineHeaderMetrics.faderHeight)
            } else {
                Color.clear
            }
        }
        .frame(width: TimelineHeaderMetrics.faderWidth)
    }

    /// 标尺那一行：总推子（所有轨混完之后再乘一次）。图标那一格放一个喇叭，
    /// 色条和眼睛两格空着 —— 占住位置，推子才和下面每条轨的推子对齐。
    private var masterStrip: some View {
        HStack(spacing: TimelineHeaderMetrics.spacing) {
            Color.clear.frame(width: TimelineHeaderMetrics.accentWidth)
            Image(systemName: "speaker.wave.2")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: TimelineHeaderMetrics.iconWidth)
            TrackFaderView(
                value: project.state.masterVolume,
                isMaster: true,
                isDimmed: false,
                onLive: { project.previewMasterVolume($0) },
                onCommit: { project.setMasterVolume($0) },
                meter: TrackMeterSource(engine: project.meters, key: .master, clock: project.clock)
            )
            .frame(width: TimelineHeaderMetrics.faderWidth, height: TimelineHeaderMetrics.faderHeight)
            Color.clear.frame(width: TimelineHeaderMetrics.eyeWidth)
        }
    }

    /// 整轨显隐的眼睛。没有眼睛的行（文字/形状）一样占着这一格 —— 少了它，
    /// 那几行的图标就会跑到别人眼睛的位置上。
    @ViewBuilder
    private var eye: some View {
        Group {
            if let slot = row.slot {
                eyeButton { project.toggleLaneHidden(slot) }
                    .instantHelp("Hide or show this track")
            } else if let kind = row.subtitleKind {
                // 字幕轨的眼睛：语义与其他轨道一致（预览+烧录都跳过），
                // 只是隐藏状态不挂在 slot 上。
                eyeButton {
                    switch kind {
                    case .original: project.toggleSubtitleHidden()
                    case .translation: project.toggleTranslationHidden()
                    }
                }
                .instantHelp(kind == .original
                      ? "Hide or show the original subtitle track"
                      : "Hide or show the translated subtitle track")
            } else {
                Color.clear
            }
        }
        .frame(width: TimelineHeaderMetrics.eyeWidth)
    }

    private func eyeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: row.isHidden ? "eye.slash" : "eye")
                .font(.system(size: 9))
                .foregroundStyle(row.isHidden ? .orange : .secondary)
        }
        .buttonStyle(.borderless)
    }

    // MARK: 点选

    /// ⌘/⇧ 点是加选 / 取消，和块的点选一致。选谁由 `TimelineRowSelection` 决定
    /// （空行、隐藏行什么都不做）—— 这里不自己判断任何一条。
    private func selectRow() {
        guard let target = row.selectionRow else { return }
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        project.selectRow(target, additive: flags.contains(.command) || flags.contains(.shift))
    }
}
