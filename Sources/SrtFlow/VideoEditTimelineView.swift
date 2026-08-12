import AVFoundation
import AppKit
import ImageIO
import SwiftUI
import os
import SrtFlowCore

/// 时间线区域：左边一列轨道头图标，右边横向滚动的标尺 + 各轨 + 播放头。
struct VideoEditTimelineView: View {
    @ObservedObject var project: VideoEditProject
    /// 必须**直接**订阅播放器时钟：它是 project 上的普通属性，不是 @Published，
    /// 光观察 project 的话时钟跳动不会触发重绘 —— 播放头就会僵在原地。
    @ObservedObject var clock: PlayerClock

    /// 正在进行的剪辑拖动。**拖动中不写 `TimelineState`**：块画在哪只由它的
    /// `offset` 决定，松手才 `commitMove` 落一次（见
    /// docs/architecture/timeline-drag-gestures.md）。
    @State private var clipDrag: ClipDragSession?
    /// 正在拉的选择框。同一条约束：**拖框中不写 `project`**，高亮谁只由它的
    /// `hit` 决定，松手才 `applyBoxSelection` 落一次。
    @State private var marquee: TimelineMarquee.Session?
    /// 拉框起手时的滚动量：自动滚动把内容抽走时要补回来（同 `ClipDragSession`）。
    @State private var marqueeOriginScrollOffset: Double = 0
    /// 正在被拖的字幕 cue。剪辑/形状块各自是独立视图、用自己的 `isMoving`
    /// 标记起手，cue 块是 `ForEach` 里的裸图形，只能在这一层按 id 记。
    @State private var movingCueID: UUID?
    /// 播放跟随滚动的节流。
    @State private var lastFollowTime: Double = -1
    /// 垂直拖动瞄准的目标行（高亮它）。
    @State private var dragTargetRow: (id: String, target: VideoEditProject.RowTarget)?
    /// 轨道头上下拖调行高的基准。
    @State private var headerResizeBase: Double?
    /// 时间线横向已滚动了多少（判断播放头还在不在视野里、拖到边缘要不要自动滚）。
    @State private var scrollOffset: Double = 0
    /// 可见视口的宽度（自动滚动要拿它判断指针到没到边）。
    @State private var viewportWidth: Double = 0
    /// 拖到边缘时推 NSScrollView 的心跳。
    @State private var autoScroller = TimelineAutoScroller()

    /// 滚动视口的命名坐标系。剪辑块的移动手势也钉在它上面（见 `moveGesture`），
    /// 所以不能是 private。
    fileprivate static let scrollSpace = "timelineScroll"

    private var pps: Double { project.pixelsPerSecond }

    /// 内容总宽度：留出结尾空白，方便把素材拖到最后。
    ///
    /// 拖动中额外给一段**弹性尾部**：自由落点的轨道（画中画/音频/磁吸关掉的主轨/
    /// 形状）允许把块拖到现有内容之外，内容宽度按投影落点临时长出去，还留半个
    /// 视口好继续拖；松手后由新的 `project.duration` 接管，没落地就自己缩回来。
    /// 磁吸主轨**不给** —— 它最终只能插进现有故事线的某条缝，扩太远只会把真正的
    /// 插入指示线滚出视野。
    private var contentWidth: Double {
        let base = max(600, project.duration * pps + 320)
        guard let drag = clipDrag, drag.allowsFreeLanding else { return base }
        return max(base, drag.end * pps + max(320, viewportWidth * 0.5))
    }

    var body: some View {
        if project.state.isEmpty {
            emptyState
        } else {
            timeline
        }
    }

    // MARK: - 空状态

    private var emptyState: some View {
        VStack {
            Spacer()
            HStack(spacing: 10) {
                Image(systemName: "film")
                    .foregroundStyle(.secondary)
                Text("Drag material here and start to create")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 36)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    .foregroundStyle(.quaternary)
            )
            .padding(.horizontal, 24)
            Spacer()
        }
    }

    // MARK: - 时间线

    /// 行的描述，轨道头列和滚动区共用，保证两边行高对得上。
    private struct RowSpec: Identifiable {
        var id: String
        var icon: String
        var height: Double
        var slot: TrackSlot?
        var isRuler = false
        var isShapes = false
        /// 字幕行属于哪条字幕轨（nil = 不是字幕行）。一个语言一条轨。
        var subtitleKind: SubtitleRowKind?
        /// 整轨隐藏中（灰显，不可编辑）。
        var isHidden = false
    }

    private var rows: [RowSpec] {
        var result: [RowSpec] = [RowSpec(id: "ruler", icon: "", height: 26, slot: nil, isRuler: true)]
        // 画中画轨：编号大的画在上面，行也放上面 —— 行的上下顺序就是叠放顺序。
        for index in project.state.overlayTracks.indices.reversed() {
            result.append(RowSpec(
                id: "overlay-\(project.state.overlayTracks[index].id)",
                icon: "pip",
                height: project.overlayRowHeight,
                slot: .overlay(index),
                isHidden: project.state.overlayTracks[index].isHidden
            ))
        }
        if !project.state.shapes.isEmpty {
            result.append(RowSpec(id: "shapes", icon: "square.on.square.dashed", height: 26, slot: nil, isShapes: true))
        }
        result.append(RowSpec(
            id: "main",
            icon: "film",
            height: project.mainRowHeight,
            slot: .main,
            isHidden: project.state.mainHidden
        ))
        // 一个语言一条字幕轨：原文一行，有译文再来一行。显示什么由这两只
        // 眼睛推导（TimelineState.visibleSubtitleChoice），没有额外的模式选择器。
        if project.state.subtitle != nil {
            result.append(RowSpec(
                id: "subtitle-original", icon: "captions.bubble", height: 22, slot: nil,
                subtitleKind: .original,
                isHidden: project.state.subtitleHidden
            ))
            if project.state.subtitleCompanion?.translation != nil {
                result.append(RowSpec(
                    id: "subtitle-translation", icon: "character.bubble", height: 22, slot: nil,
                    subtitleKind: .translation,
                    isHidden: project.state.translationHidden
                ))
            }
        }
        for index in project.state.audioTracks.indices {
            result.append(RowSpec(
                id: "audio-\(project.state.audioTracks[index].id)",
                icon: "music.note",
                height: project.audioRowHeight,
                slot: .audio(index),
                isHidden: project.state.audioTracks[index].isHidden
            ))
        }
        return result
    }

    /// 每行的纵向位置（垂直拖动找目标行用），和 VStack 的排布严格一致。
    private struct RowLayout {
        var spec: RowSpec
        var minY: Double
        var midY: Double
        var maxY: Double
    }

    private func rowLayouts() -> [RowLayout] {
        var y = 2.0
        var result: [RowLayout] = []
        for spec in rows {
            result.append(RowLayout(spec: spec, minY: y, midY: y + spec.height / 2, maxY: y + spec.height))
            y += spec.height + rowSpacing
        }
        return result
    }

    private var timeline: some View {
        HStack(alignment: .top, spacing: 0) {
            headerColumn
            Divider()
            GeometryReader { viewport in
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: true) {
                        scrolledContent
                            .frame(width: contentWidth, alignment: .topLeading)
                            .background(
                                GeometryReader { content in
                                    Color.clear.preference(
                                        key: TimelineScrollOffsetKey.self,
                                        value: -content.frame(in: .named(Self.scrollSpace)).minX
                                    )
                                }
                            )
                    }
                    // 参照层铺满可见视口，标定「捏合该生效的区域」；事件本身
                    // 由 TimelineMagnificationBridge 里的 local monitor 处理。
                    .overlay(
                        TimelineMagnificationBridge(pixelsPerSecond: $project.pixelsPerSecond)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    )
                    .coordinateSpace(name: Self.scrollSpace)
                    .onPreferenceChange(TimelineScrollOffsetKey.self) { scrollOffset = $0 }
                    .onChange(of: viewport.size.width, initial: true) { _, width in
                        viewportWidth = width
                    }
                    .onChange(of: clock.time) { _, newTime in
                        followPlayhead(newTime, proxy: proxy, viewportWidth: viewport.size.width)
                    }
                    // 视图消失（切栏目、关窗、切工程）时心跳必须跟着停 ——
                    // 正常松手走 onEnded，这条管的是「手势没有终点」的那些死法。
                    .onDisappear {
                        autoScroller.stop()
                        clipDrag = nil
                        dragTargetRow = nil
                        marquee = nil
                    }
                }
            }
        }
    }

    /// 左侧的轨道头：类型图标 + 整轨隐藏的眼睛（快捷键 V），行高和右边严格一致。
    /// 在主轨/画中画/音频的图标上**上下拖**可以调那一类轨道的行高。
    private var headerColumn: some View {
        VStack(alignment: .center, spacing: rowSpacing) {
            ForEach(rows) { row in
                Group {
                    if row.isRuler {
                        Color.clear
                    } else {
                        HStack(spacing: 3) {
                            Image(systemName: row.icon)
                                .font(.caption)
                                .foregroundStyle(row.isHidden ? .tertiary : .secondary)
                            if let slot = row.slot {
                                Button {
                                    project.toggleLaneHidden(slot)
                                } label: {
                                    Image(systemName: row.isHidden ? "eye.slash" : "eye")
                                        .font(.system(size: 9))
                                        .foregroundStyle(row.isHidden ? .orange : .secondary)
                                }
                                .buttonStyle(.borderless)
                                .instantHelp("Hide or show this track", shortcut: .plain("V"))
                            } else if let kind = row.subtitleKind {
                                // 字幕轨的眼睛：语义与其他轨道一致（预览+烧录
                                // 都跳过），只是隐藏状态不挂在 slot 上。
                                Button {
                                    switch kind {
                                    case .original: project.toggleSubtitleHidden()
                                    case .translation: project.toggleTranslationHidden()
                                    }
                                } label: {
                                    Image(systemName: row.isHidden ? "eye.slash" : "eye")
                                        .font(.system(size: 9))
                                        .foregroundStyle(row.isHidden ? .orange : .secondary)
                                }
                                .buttonStyle(.borderless)
                                .instantHelp(kind == .original
                                      ? "Hide or show the original subtitle track"
                                      : "Hide or show the translated subtitle track")
                            }
                        }
                    }
                }
                .frame(width: 54, height: row.height)
                .contentShape(Rectangle())
                .modifier(RowHeightDragModifier(
                    kind: rowKind(row),
                    project: project,
                    base: $headerResizeBase
                ))
            }
        }
        .padding(.vertical, 2)
    }

    private var rowSpacing: Double { 5 }

    private func rowKind(_ row: RowSpec) -> TrackRowKind {
        switch row.slot {
        case .main: return .main
        case .overlay: return .overlay
        case .audio: return .audio
        case nil: return .other
        }
    }

    private var scrolledContent: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: rowSpacing) {
                ForEach(rows) { row in
                    rowView(row)
                        .frame(height: row.height)
                }
            }
            .padding(.vertical, 2)

            // 对齐参考线：块的两条边各自去够参考点，对上了就亮一条通高的线，
            // 所以跨轨对齐（上面画中画的边缘对上下面主轨的边缘）一眼能看见。
            TimelineAlignmentGuides(times: clipDrag?.guides ?? [], pixelsPerSecond: pps)

            // 主轨磁吸开着时松手会插进的那条缝。拖动中主轨不再当场重排，
            // 落点靠这条线交代（时刻由 TimelineSnap.mainInsertion 算，落地同一个函数）。
            if let time = mainInsertionTime,
               let layout = rowLayouts().first(where: { $0.spec.slot == .main }) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.teal)
                    .frame(width: 3, height: layout.spec.height)
                    .offset(x: time * pps - 1.5, y: layout.minY)
                    .allowsHitTesting(false)
            }

            // 自动滚动要直接推 NSScrollView，放个零尺寸参照物把它认出来。
            TimelineScrollViewAccessor(scroller: autoScroller)
                .frame(width: 0, height: 0)

            // 垂直拖动的目标行高亮：现有行描边，新轨画一条插入线。
            if let target = dragTargetRow {
                if let layout = rowLayouts().first(where: { $0.spec.id == target.id }) {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.teal, lineWidth: 2)
                        .frame(width: contentWidth, height: layout.spec.height)
                        .offset(y: layout.minY)
                        .allowsHitTesting(false)
                } else {
                    let y: Double = {
                        let layouts = rowLayouts()
                        if target.id == "new-top" {
                            return (layouts.first { $0.spec.slot != nil }?.minY ?? 30) - 4
                        }
                        return (layouts.last?.maxY ?? 30) + 4
                    }()
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.teal)
                        .frame(width: contentWidth, height: 3)
                        .offset(y: y)
                        .allowsHitTesting(false)
                }
            }

            // 正在拉的选择框。画在播放头之下、块之上，不拦事件。
            if let marquee, marquee.rect.width > 0 || marquee.rect.height > 0 {
                Rectangle()
                    .fill(Color.teal.opacity(0.12))
                    .overlay(Rectangle().strokeBorder(Color.teal.opacity(0.9), lineWidth: 1))
                    .frame(width: marquee.rect.width, height: marquee.rect.height)
                    .offset(x: marquee.rect.minX, y: marquee.rect.minY)
                    .allowsHitTesting(false)
            }

            hoverPointer
            playhead
        }
        .contentShape(Rectangle())
        // 点空白处：三类选择一起取消（含字幕 cue —— 漏了它，拖框会在没有任何
        // 选中项的界面上继续挂着）。
        .onTapGesture { project.clearSelection() }
        // 空白处按下拖动 = 拉框选。挂在容器上而不是各行上：SwiftUI 里子视图的
        // 手势优先，所以块本体的移动手势、标尺的 scrub 都照旧归它们自己，只有
        // 谁都不认领的空白才落到这里。刀片模式下整条停掉（`.subviews` 保留
        // 子视图的点击），不然本该落下的那一刀会被 4pt 的手抖吃成一次框选。
        .gesture(marqueeGesture, including: project.activeTool == .split ? .subviews : .all)
    }

    // MARK: - 框选

    /// 空白处拉框：相交即选中，⌘/⇧ 加选，拖到视口边缘自动滚动。
    ///
    /// **整轮拖框不写 `project`** —— 命中集合只在 `marquee` 这个 `@State` 里，
    /// 松手才落一次。每一拍写 `@Published` 的选择会连带预览区、检查器、所有块
    /// 连同缩略图与波形重建，还要重挂一次自动保存，框立刻就跟不上光标了
    /// （和拖块同一条约束，见 docs/architecture/timeline-drag-gestures.md）。
    private var marqueeGesture: some Gesture {
        // 起手门槛和块的移动手势一致：手抖几个点不该把已有的选择清掉。
        DragGesture(minimumDistance: 4, coordinateSpace: .named(VideoEditTimelineView.scrollSpace))
            .onChanged { value in
                if marquee == nil { beginMarquee(at: value.startLocation) }
                updateMarquee(pointer: value.location)
            }
            .onEnded { _ in endMarquee() }
    }

    private func beginMarquee(at start: CGPoint) {
        // 拉框期间把悬停预览收掉，画面回播放头 —— 和拖块的处理一致。
        project.clock.endPeek()
        marqueeOriginScrollOffset = scrollOffset
        let flags = NSEvent.modifierFlags
        marquee = TimelineMarquee.Session(
            anchor: CGPoint(x: start.x + scrollOffset, y: start.y),
            additive: flags.contains(.command) || flags.contains(.shift),
            base: TimelineMarquee.Hit(
                clips: project.selectedClipIDs,
                shapes: project.selectedShapeIDs,
                cues: project.selectedSubtitleCueIDs
            )
        )
    }

    /// `pointer` 是指针在滚动视口里的位置（手势坐标系钉在视口上）。
    private func updateMarquee(pointer: CGPoint) {
        guard marquee != nil else { return }
        applyMarqueePoint(pointer: pointer, scrollOffset: scrollOffset)
        autoScroller.update(pointerX: pointer.x, viewportWidth: viewportWidth) { offset in
            // 自动滚动那一拍指针没动，只有滚动量变了 —— 框要跟着内容继续长。
            scrollOffset = offset
            applyMarqueePoint(pointer: pointer, scrollOffset: offset)
        }
    }

    private func applyMarqueePoint(pointer: CGPoint, scrollOffset: Double) {
        guard var session = marquee else { return }
        session.update(
            current: CGPoint(x: pointer.x + scrollOffset, y: pointer.y),
            rows: marqueeRows(),
            pixelsPerSecond: pps
        )
        marquee = session
    }

    private func endMarquee() {
        autoScroller.stop()
        defer { marquee = nil }
        guard let session = marquee else { return }
        // 空框 = 点了一下空白：三类一起清（和 `.onTapGesture` 同义）。
        project.applyBoxSelection(
            clips: session.hit.clips,
            shapes: session.hit.shapes,
            cues: session.hit.cues
        )
    }

    /// 喂给命中判定的行模型。y 用滚动内容的坐标 —— 时间线没有纵向滚动，
    /// 视口坐标和内容坐标在 y 上是同一个数（`rowLayouts` 也按这个排）。
    private func marqueeRows() -> [TimelineMarquee.Row] {
        rowLayouts().compactMap { layout -> TimelineMarquee.Row? in
            let spec = layout.spec
            let items: [TimelineMarquee.Item]
            if let slot = spec.slot {
                items = project.state[track: slot].map {
                    TimelineMarquee.Item(id: $0.id, start: $0.timelineStart, end: $0.timelineEnd, kind: .clip)
                }
            } else if spec.isShapes {
                items = project.state.shapes.map {
                    TimelineMarquee.Item(id: $0.id, start: $0.timelineStart, end: $0.timelineEnd, kind: .shape)
                }
            } else if let kind = spec.subtitleKind {
                // 译文轨是原文轨的镜像（同 ID 同时间），从哪一行框中的都是同一条 cue。
                let cues = kind == .original
                    ? project.state.subtitle?.cues
                    : project.state.subtitleCompanion?.translation?.cues
                items = (cues ?? []).map {
                    TimelineMarquee.Item(id: $0.id, start: $0.start, end: $0.end, kind: .subtitleCue)
                }
            } else {
                // 标尺行：拖它是 scrub，框不到任何东西。
                return nil
            }
            // 纵向按**画出来的**块算，不是整行：字幕/形状块在行内上下都留了白，
            // 按整行判的话框从留白里扫过也会选中（常量与画块处共用）。
            let minY: Double
            let maxY: Double
            if spec.isShapes {
                minY = layout.minY + TimelineMarquee.shapeTopInset
                maxY = minY + TimelineMarquee.shapeHeight
            } else if spec.subtitleKind != nil {
                minY = layout.minY + TimelineMarquee.cueTopInset
                maxY = minY + TimelineMarquee.cueHeight
            } else {
                minY = layout.minY
                maxY = layout.maxY
            }
            return TimelineMarquee.Row(
                minY: minY,
                maxY: maxY,
                isHidden: spec.isHidden,
                items: items
            )
        }
    }

    /// 拉框中的高亮只看框，不看模型 —— 模型要等松手才写。
    private func isSelected(clip id: UUID) -> Bool {
        marquee?.hit.clips.contains(id) ?? project.selectedClipIDs.contains(id)
    }

    private func isSelected(shape id: UUID) -> Bool {
        marquee?.hit.shapes.contains(id) ?? project.selectedShapeIDs.contains(id)
    }

    private func isSelected(cue id: UUID) -> Bool {
        marquee?.hit.cues.contains(id) ?? project.selectedSubtitleCueIDs.contains(id)
    }

    @ViewBuilder
    private func rowView(_ row: RowSpec) -> some View {
        if row.isRuler {
            TimelineRuler(
                pps: pps,
                duration: project.duration,
                onSeek: { time, precise in
                    clock.seek(to: min(max(0, time), project.duration), precise: precise)
                }
            )
        } else if row.isShapes {
            shapesRow
        } else if let kind = row.subtitleKind {
            subtitleRow(kind: kind)
        } else if let slot = row.slot {
            trackRow(slot: slot, height: row.height, hidden: row.isHidden)
        }
    }

    // MARK: - 轨道行

    private func trackRow(slot: TrackSlot, height: Double, hidden: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4)
                .fill(.quaternary.opacity(0.35))
                .frame(width: contentWidth)
            ForEach(project.state[track: slot]) { clip in
                ClipBlockView(
                    clip: clip,
                    slot: slot,
                    height: height,
                    pps: pps,
                    isSelected: isSelected(clip: clip.id),
                    dragOffset: dragOffset(for: clip),
                    project: project,
                    onDragBegin: { beginClipDrag(clip, slot: slot) },
                    onDragChange: { translation, pointerViewportX in
                        updateClipDrag(translation: translation, pointerViewportX: pointerViewportX)
                    },
                    onDragEnd: { endClipDrag() },
                    onTrim: { leading, delta in
                        project.liveTrim(clip.id, leading: leading, deltaSeconds: delta)
                    },
                    onTrimEnd: {
                        project.endLiveEdit()
                    }
                )
            }
            // 隐藏的轨：灰显、去色、点不动。
            .opacity(hidden ? 0.35 : 1)
            .saturation(hidden ? 0 : 1)
            .allowsHitTesting(!hidden)
        }
    }

    // MARK: - 剪辑拖动

    /// 这个块此刻的渲染位移（秒）。nil = 没在被拖，按模型里的位置画。
    /// 整组共用**同一个**位移 —— 逐块各算各的会把相对错位弄坏。
    private func dragOffset(for clip: EditClip) -> Double? {
        dragOffset(movingID: clip.id)
    }

    /// 同上，按 id 查。三类块（剪辑 / 形状 / 字幕 cue）共用这一个 —— 名单来自
    /// 同一份计划，谁在这一组里谁就画同一个位移。
    private func dragOffset(movingID id: UUID) -> Double? {
        guard let drag = clipDrag, drag.movingIDs.contains(id) else { return nil }
        return drag.offset
    }

    private func beginClipDrag(_ clip: EditClip, slot: TrackSlot) {
        // 开始拖动就收掉悬停预览，画面回播放头 —— 拖动过程里 hover 回调被
        // ClipBlockView 的 guard 挡住，不会再把 peek 顶回来。
        project.clock.endPeek()
        // 拖一个没选中的块 = 单选它；拖已选中的块 = 整组一起动。
        if !project.selectedClipIDs.contains(clip.id) {
            project.select(clip.id, additive: false)
        }
        guard let plan = project.dragPlan(draggedID: clip.id, slot: slot) else { return }
        clipDrag = ClipDragSession(
            subject: .clip(slot: slot),
            plan: plan,
            originScrollOffset: scrollOffset
        )
    }

    private func beginShapeDrag(_ shape: ShapeAnnotation) {
        project.clock.endPeek()
        // 和剪辑对称：拖一个没选中的形状 = 单选它；拖已选中的 = 整组一起动。
        if !project.selectedShapeIDs.contains(shape.id) {
            project.selectShape(shape.id, additive: false)
        }
        guard let plan = project.shapeDragPlan(shapeID: shape.id) else { return }
        clipDrag = ClipDragSession(subject: .shape, plan: plan, originScrollOffset: scrollOffset)
    }

    /// 字幕 cue 起手的拖动。与剪辑/形状三处严格对称，包括「拖一个没选中的
    /// = 单选它再拖」这条语义。
    private func beginCueDrag(_ cue: SubtitleCue) {
        project.clock.endPeek()
        if !project.selectedSubtitleCueIDs.contains(cue.id) {
            project.selectSubtitleCue(cue.id, additive: false)
        }
        guard let plan = project.cueDragPlan(cueID: cue.id) else { return }
        clipDrag = ClipDragSession(subject: .subtitleCue, plan: plan, originScrollOffset: scrollOffset)
    }

    /// `pointerViewportX` 是指针在滚动视口里的 x（手势坐标系就钉在视口上）。
    private func updateClipDrag(translation: CGSize, pointerViewportX: Double) {
        guard var drag = clipDrag else { return }
        drag.update(translation: translation, scrollOffset: scrollOffset, pixelsPerSecond: pps)
        clipDrag = drag
        dragTargetRow = verticalTarget(for: drag, dy: translation.height)
        autoScroller.update(
            pointerX: pointerViewportX,
            viewportWidth: viewportWidth
        ) { offset in
            // 自动滚动那一拍指针没动，位移还是上一次那个，只有滚动量变了。
            scrollOffset = offset
            guard var drag = clipDrag else { return }
            drag.update(translation: drag.translation, scrollOffset: offset, pixelsPerSecond: pps)
            clipDrag = drag
        }
    }

    private func endClipDrag() {
        autoScroller.stop()
        defer {
            clipDrag = nil
            dragTargetRow = nil
        }
        guard let drag = clipDrag else { return }
        switch drag.subject {
        case .shape, .subtitleCue:
            // 这两类自己不跨轨、不插空，但同一组里可能挂着剪辑 —— 落地仍走
            // 和剪辑同一个 applyDrag（`commitFreeDrag`），位移只有一份。
            project.commitFreeDrag(drag.plan, resolution: drag.resolution)
        case .clip:
            // 水平平移、跨轨搬运、磁吸插空都在 commitDrag 的**同一次 perform**
            // 里，所以是一步撤销，也不会出现「视频换了轨、链接音频留在旧时刻」。
            project.commitDrag(
                drag.plan,
                resolution: drag.resolution,
                crossTrack: dragTargetRow?.target
            )
        }
    }

    /// 主轨磁吸开着时，松手会插进哪条缝。只在块留在自己轨上时给
    /// —— 跨轨落地走 `relocate`，插入位置是另一套算法，画在这儿会说谎。
    private var mainInsertionTime: Double? {
        // 跨轨落地走的是另一套插入算法，这条线画出来会说谎。
        guard dragTargetRow == nil else { return nil }
        return clipDrag?.mainInsertionTime
    }

    /// 垂直拖出 18pt 之后开始找目标行：同类行里挑离指尖最近的；
    /// 拖出最上面（视频）/最下面（音频）就是开新轨。
    private func verticalTarget(
        for drag: ClipDragSession,
        dy: Double
    ) -> (id: String, target: VideoEditProject.RowTarget)? {
        guard abs(dy) > 18 else { return nil }
        // 形状只在自己那一行里横向移动，没有跨轨这回事。
        guard let slot = drag.clipSlot,
              let clip = project.state.clip(with: drag.draggedID) else { return nil }
        let layouts = rowLayouts()
        guard let source = layouts.first(where: { $0.spec.slot == slot }) else { return nil }
        let pointY = source.midY + dy

        var candidates: [(id: String, midY: Double, target: VideoEditProject.RowTarget)] = []
        if clip.isAudioOnly {
            for layout in layouts {
                if case .audio(let index) = layout.spec.slot {
                    candidates.append((layout.spec.id, layout.midY, .audio(index)))
                }
            }
            if let bottom = layouts.last {
                candidates.append(("new-bottom", bottom.maxY + 16, .newAudioBottom))
            }
        } else {
            for layout in layouts {
                switch layout.spec.slot {
                case .main:
                    candidates.append((layout.spec.id, layout.midY, .main))
                case .overlay(let index):
                    candidates.append((layout.spec.id, layout.midY, .overlay(index)))
                default:
                    break
                }
            }
            if let firstContent = layouts.first(where: { $0.spec.slot != nil }) {
                candidates.append(("new-top", firstContent.minY - 16, .newOverlayTop))
            }
        }

        guard let best = candidates.min(by: { abs($0.midY - pointY) < abs($1.midY - pointY) }) else {
            return nil
        }
        if best.id == source.spec.id { return nil }
        return (best.id, best.target)
    }

    // MARK: - 形状行

    private var shapesRow: some View {
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
                    onDragChange: { translation, pointerViewportX in
                        updateClipDrag(translation: translation, pointerViewportX: pointerViewportX)
                    },
                    onDragEnd: { endClipDrag() }
                )
            }
        }
    }

    // MARK: - 字幕行

    private func subtitleRow(kind: SubtitleRowKind) -> some View {
        // 译文轨是原文轨的**镜像**：同 ID、同时间（LinkedSubtitleEditing 强制），
        // 所以两行的块位置天然对齐，点任意一行选中的是同一条 cue。
        let cues = kind == .original
            ? project.state.subtitle?.cues
            : project.state.subtitleCompanion?.translation?.cues
        let hidden = kind == .original
            ? project.state.subtitleHidden
            : project.state.translationHidden
        let tint: Color = kind == .original ? .orange : .teal
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4)
                .fill(.quaternary.opacity(0.25))
                .frame(width: contentWidth)
            if let cues {
                ForEach(cues) { cue in
                    let selected = isSelected(cue: cue.id)
                    let offset = dragOffset(movingID: cue.id)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(tint.opacity(selected ? 0.8 : 0.45))
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .strokeBorder(.white, lineWidth: selected ? 1.2 : 0)
                        )
                        // 宽和高都与框选的命中判定共用常量：画多大就该按多大判，
                        // 否则一条 0.05 秒的 cue 框得中却看不见、或反过来。
                        .frame(
                            width: max(TimelineMarquee.cueMinimumWidth, (cue.end - cue.start) * pps),
                            height: TimelineMarquee.cueHeight
                        )
                        .offset(
                            x: (cue.start + (offset ?? 0)) * pps,
                            y: TimelineMarquee.cueTopInset
                        )
                        .zIndex(offset != nil ? 10 : 0)
                        .onTapGesture {
                            // 点选 = 选中这条 cue（预览出字幕拖框）+ 把播放头
                            // 带进这条字幕，画面上立刻有字可调。⌘/⇧ 点是加选。
                            let flags = NSApp.currentEvent?.modifierFlags ?? []
                            let additive = flags.contains(.command) || flags.contains(.shift)
                            if !additive { clock.seek(to: cue.start + 0.05) }
                            project.selectSubtitleCue(cue.id, additive: additive)
                        }
                        .gesture(
                            // 与剪辑/形状块同一套：坐标系钉在不动的滚动视口上
                            //（块会在手指底下挪窝，自动滚动还会把内容抽走）。
                            DragGesture(minimumDistance: 4, coordinateSpace: .named(VideoEditTimelineView.scrollSpace))
                                .onChanged { value in
                                    if movingCueID != cue.id {
                                        movingCueID = cue.id
                                        beginCueDrag(cue)
                                    }
                                    updateClipDrag(
                                        translation: value.translation,
                                        pointerViewportX: value.location.x
                                    )
                                }
                                .onEnded { _ in
                                    movingCueID = nil
                                    endClipDrag()
                                }
                        )
                        .instantHelp(verbatim: SubtitleSerializer.plainText(cue.text))
                }
            }
        }
        // 隐藏中：灰显，与其他轨道的隐藏观感一致。
        .opacity(hidden ? 0.35 : 1)
    }

    // MARK: - 播放头

    /// 悬停预览的影子指针：半透明细线、没有把手 —— 只说明「画面此刻在看这儿」。
    /// 真播放头（白色实线 + 把手）留在用户点定的位置，点击才会把它移过来。
    @ViewBuilder
    private var hoverPointer: some View {
        if let peek = clock.peekTime {
            Rectangle()
                .fill(.white.opacity(0.5))
                .frame(width: 1)
                .frame(maxHeight: .infinity, alignment: .top)
                .offset(x: peek * pps - 0.5)
                .allowsHitTesting(false)
        }
    }

    private var playhead: some View {
        let x = clock.time * pps
        return VStack(spacing: 0) {
            // 标尺上的把手。
            RoundedRectangle(cornerRadius: 2)
                .fill(.white)
                .frame(width: 9, height: 14)
                .shadow(radius: 1)
            Rectangle()
                .fill(.white)
                .frame(width: 1.5)
                .shadow(radius: 0.5)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .offset(x: x - 4.5)
        .allowsHitTesting(false)
        // 播放头本身是 .offset 画的，不占布局位置，scrollTo 找不到它 ——
        // 所以另放一个**占真实布局**的锚点跟着播放头走，滚动认那个。
        .overlay(alignment: .topLeading) {
            HStack(spacing: 0) {
                Color.clear.frame(width: max(0, x), height: 1)
                Color.clear.frame(width: 1, height: 1).id(Self.playheadAnchor)
                Spacer(minLength: 0)
            }
            .allowsHitTesting(false)
        }
    }

    private static let playheadAnchor = "playhead-anchor"

    /// 播放时让播放头留在视野里：只有它快滚出去了才动一下，
    /// 平时不跟着走 —— 每帧都居中会看得人晕。
    private func followPlayhead(_ time: Double, proxy: ScrollViewProxy, viewportWidth: Double) {
        guard clock.isPlaying, viewportWidth > 80 else { return }
        guard abs(time - lastFollowTime) > 0.15 else { return }
        lastFollowTime = time

        let x = time * pps
        let leftEdge = scrollOffset + 40
        let rightEdge = scrollOffset + viewportWidth - 80
        guard x < leftEdge || x > rightEdge else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            // 挪到视野偏左的位置，后面还留着一大段能看。
            proxy.scrollTo(Self.playheadAnchor, anchor: UnitPoint(x: 0.15, y: 0))
        }
    }
}

/// 触控板捏合缩放时间线。
///
/// 不能走视图命中：两指刚落上触控板时系统先发 scrollWheel(mayBegin) 决定这一轮
/// 手势序列的接收者，此后同序列的 magnify 事件不再重新 hitTest —— 时间线的
/// NSScrollView 把序列锁走，盖在上面的捕获层永远等不到捏合。所以这里用
/// local event monitor：事件进窗口分发**之前**就先看一眼，是捏合且光标在
/// 时间线视口内就缩放并吞掉；其余事件原样放行，点选、拖动、滚动零干扰。
/// 视图本身只当几何参照（hitTest 永远返回 nil）。
private struct TimelineMagnificationBridge: NSViewRepresentable {
    @Binding var pixelsPerSecond: Double

    func makeCoordinator() -> Coordinator {
        Coordinator(pixelsPerSecond: $pixelsPerSecond)
    }

    func makeNSView(context: Context) -> TimelineZoomReferenceView {
        let view = TimelineZoomReferenceView()
        context.coordinator.referenceView = view
        context.coordinator.installMonitorIfNeeded()
        return view
    }

    func updateNSView(_ nsView: TimelineZoomReferenceView, context: Context) {
        context.coordinator.pixelsPerSecond = $pixelsPerSecond
        context.coordinator.referenceView = nsView
    }

    static func dismantleNSView(_ nsView: TimelineZoomReferenceView, coordinator: Coordinator) {
        coordinator.tearDown()
    }

    @MainActor
    final class Coordinator: NSObject {
        var pixelsPerSecond: Binding<Double>
        weak var referenceView: TimelineZoomReferenceView?
        private var monitor: Any?
        private weak var timelineScrollView: NSScrollView?
        private var isZooming = false
        private var anchorTime: Double = 0
        private var anchorViewportX: Double = 0
        private var scrollCorrectionGeneration = 0
        /// 诊断日志：`log show --predicate 'subsystem == "com.srtflow.SrtFlow"'`
        /// 能直接回答「捏合事件到底进没进 App」。
        private static let log = Logger(subsystem: "com.srtflow.SrtFlow", category: "timeline-zoom")

        init(pixelsPerSecond: Binding<Double>) {
            self.pixelsPerSecond = pixelsPerSecond
        }

        func installMonitorIfNeeded() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.magnify, .scrollWheel]) { [weak self] event in
                guard let self else { return event }
                return MainActor.assumeIsolated { self.handle(event) }
            }
        }

        func tearDown() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            referenceView = nil
            endZoom()
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            switch event.type {
            case .magnify:
                return handleMagnify(event)
            case .scrollWheel:
                // Ctrl + 滚轮也缩放（无触控板时的替代），普通滚动原样放行。
                guard event.modifierFlags.contains(.control),
                      cursorInsideTimeline(event) else { return event }
                captureAnchor(atWindowPoint: event.locationInWindow)
                let factor = exp(-Double(event.scrollingDeltaY) * 0.025)
                setScale(pixelsPerSecond.wrappedValue * factor)
                timelineScrollView = nil
                return nil
            default:
                return event
            }
        }

        private func handleMagnify(_ event: NSEvent) -> NSEvent? {
            if !isZooming {
                let inside = cursorInsideTimeline(event)
                if event.phase == .began {
                    Self.log.log("magnify began, insideTimeline=\(inside)")
                }
                guard inside else { return event }
                isZooming = true
                captureAnchor(atWindowPoint: event.locationInWindow)
            }
            if event.phase == .ended || event.phase == .cancelled {
                Self.log.log("magnify ended at scale \(self.pixelsPerSecond.wrappedValue)")
                endZoom()
                return nil
            }
            // NSEvent.magnification 是这一帧的增量，逐帧乘到当前比例上才会平滑。
            let factor = 1 + Double(event.magnification)
            if factor > 0 {
                setScale(pixelsPerSecond.wrappedValue * factor)
            }
            return nil
        }

        /// 事件落在时间线的可见视口里吗？参照视图正好铺满那个视口。
        private func cursorInsideTimeline(_ event: NSEvent) -> Bool {
            guard let view = referenceView,
                  let window = view.window,
                  event.window === window else { return false }
            let point = view.convert(event.locationInWindow, from: nil)
            return view.bounds.contains(point)
        }

        func endZoom() {
            isZooming = false
            timelineScrollView = nil
        }

        /// 记住鼠标下的时刻和它在可见视口中的 x；每次缩放后把这个
        /// 时刻滚回同一个 x，就是录屏里 CapCut 的「指针下缩放」。
        private func captureAnchor(atWindowPoint pointInWindow: NSPoint) {
            guard let window = referenceView?.window,
                  let rootView = window.contentView else {
                timelineScrollView = nil
                return
            }
            let pointInRoot = rootView.convert(pointInWindow, from: nil)
            guard let scrollView = enclosingScrollView(at: pointInRoot, in: rootView),
                  let documentView = scrollView.documentView else {
                timelineScrollView = nil
                return
            }
            let clipView = scrollView.contentView
            let pointInClip = clipView.convert(pointInWindow, from: nil)
            let pointInDocument = documentView.convert(pointInWindow, from: nil)
            timelineScrollView = scrollView
            anchorViewportX = pointInClip.x - clipView.bounds.minX
            anchorTime = max(0, pointInDocument.x) / max(pixelsPerSecond.wrappedValue, 1)
        }

        private func enclosingScrollView(at point: NSPoint, in hostView: NSView) -> NSScrollView? {
            var view = hostView.hitTest(point)
            while let current = view {
                if let scrollView = current as? NSScrollView { return scrollView }
                view = current.superview
            }
            return nil
        }

        private func setScale(_ scale: Double) {
            guard scale.isFinite else { return }
            // 夹进和工具栏同一份区间：捏合以前只查 finite，能一路缩到 1 以下，
            // 那时块的位移换算被 max(pps, 1) 兜底，1:1 跟手就坏了。
            let clamped = min(
                max(scale, VideoEditProject.zoomRange.lowerBound),
                VideoEditProject.zoomRange.upperBound
            )
            guard clamped != pixelsPerSecond.wrappedValue else { return }
            pixelsPerSecond.wrappedValue = clamped
            keepAnchorFixed(atScale: clamped)
        }

        private func keepAnchorFixed(atScale scale: Double) {
            guard let scrollView = timelineScrollView else { return }
            scrollCorrectionGeneration += 1
            let generation = scrollCorrectionGeneration
            let time = anchorTime
            let viewportX = anchorViewportX

            // @Published 先让 SwiftUI 重排内容宽度，下一轮 main loop 再校正滚动量。
            DispatchQueue.main.async { [weak self, weak scrollView] in
                guard let self,
                      generation == self.scrollCorrectionGeneration,
                      let scrollView,
                      let documentView = scrollView.documentView else { return }
                let clipView = scrollView.contentView
                let minX = documentView.bounds.minX
                let maxX = max(minX, documentView.bounds.maxX - clipView.bounds.width)
                let proposed = time * scale - viewportX
                let x = min(max(proposed, minX), maxX)
                clipView.scroll(to: NSPoint(x: x, y: clipView.bounds.origin.y))
                scrollView.reflectScrolledClipView(clipView)
            }
        }

    }
}

/// 只用来把「时间线视口」这块区域标定在 AppKit 坐标系里，事件一概不碰。
@MainActor
private final class TimelineZoomReferenceView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// 时间线横向滚动量。
private struct TimelineScrollOffsetKey: PreferenceKey {
    static let defaultValue: Double = 0
    static func reduce(value: inout Double, nextValue: () -> Double) {
        value = nextValue()
    }
}

// MARK: - 行高拖调

/// 轨道行的类别，行高各记各的。
private enum TrackRowKind {
    case main, overlay, audio, other
}

/// 轨道头图标上的上下拖：调那一类轨道的行高。
private struct RowHeightDragModifier: ViewModifier {
    let kind: TrackRowKind
    @ObservedObject var project: VideoEditProject
    @Binding var base: Double?

    func body(content: Content) -> some View {
        if kind == .other {
            content
        } else {
            content
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            if base == nil { base = current }
                            apply((base ?? current) + value.translation.height)
                        }
                        .onEnded { _ in base = nil }
                )
                .onHover { inside in
                    if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                }
                .instantHelp("Drag up or down to resize this kind of track")
        }
    }

    private var current: Double {
        switch kind {
        case .main: return project.mainRowHeight
        case .overlay: return project.overlayRowHeight
        case .audio: return project.audioRowHeight
        case .other: return 0
        }
    }

    private func apply(_ height: Double) {
        switch kind {
        case .main: project.mainRowHeight = min(max(height, 28), 120)
        case .overlay: project.overlayRowHeight = min(max(height, 24), 110)
        case .audio: project.audioRowHeight = min(max(height, 20), 100)
        case .other: break
        }
    }
}

// MARK: - 标尺

/// `|00:00 · · · · |00:10 · · · ·` 的刻度条，可点、可拖着走播放头。
private struct TimelineRuler: View {
    let pps: Double
    let duration: Double
    let onSeek: (Double, Bool) -> Void

    var body: some View {
        Canvas { context, size in
            let major = majorStep
            let minor = major / 5
            var t: Double = 0
            while t * pps < size.width {
                let x = t * pps
                let isMajor = t.truncatingRemainder(dividingBy: major) < 0.0001
                    || major - t.truncatingRemainder(dividingBy: major) < 0.0001
                if isMajor {
                    context.draw(
                        Text("|" + label(t))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary),
                        at: CGPoint(x: x + 2, y: size.height / 2),
                        anchor: .leading
                    )
                } else {
                    let dot = Path(ellipseIn: CGRect(x: x - 1, y: size.height / 2 - 1, width: 2, height: 2))
                    context.fill(dot, with: .color(.secondary.opacity(0.5)))
                }
                t += minor
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    onSeek(value.location.x / pps, false)
                }
                .onEnded { value in
                    onSeek(value.location.x / pps, true)
                }
        )
    }

    /// 主刻度间隔按缩放挑，保证相邻标签不打架。
    private var majorStep: Double {
        let candidates: [Double] = [1, 2, 5, 10, 30, 60, 120, 300, 600]
        for candidate in candidates where candidate * pps >= 76 {
            return candidate
        }
        return 600
    }

    private func label(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

// MARK: - 剪辑块

/// 一段素材的块：视频带缩略图条和名字，音频画波形，选中描白框。
private struct ClipBlockView: View {
    let clip: EditClip
    let slot: TrackSlot
    let height: Double
    let pps: Double
    let isSelected: Bool
    /// 拖动中的渲染位移（秒）。nil = 没在被拖。被拖的块和跟着它动的伙伴都拿它
    /// 画位置 —— 拖动期间模型一个字都不改，所以 `timelineStart` 是拖前那个值。
    let dragOffset: Double?
    @ObservedObject var project: VideoEditProject
    let onDragBegin: () -> Void
    /// (手势总位移, 指针在滚动视口里的 x)。垂直分量用来跨轨，x 用来判断到没到
    /// 视口边缘（自动滚动）。两者都在视口坐标系里量，见 `moveGesture`。
    let onDragChange: (CGSize, Double) -> Void
    let onDragEnd: () -> Void
    let onTrim: (Bool, Double) -> Void
    let onTrimEnd: () -> Void

    /// 移动手势进行中（悬停扫帧要让位，第一拍还要开一轮拖动会话）。
    @State private var isMoving = false
    /// 裁切进行中：块自己要严格跟手，磁吸重排动画只留给邻居。
    @State private var isTrimming = false
    /// 刀片工具的十字光标压没压进光标栈（离开时要弹回来）。
    @State private var pushedSplitCursor = false
    /// 指针正悬在某枚标记上时，那枚标记所在的时间线时刻；nil = 没悬着。
    /// 扫帧 peek 归属的仲裁位，见 `markerHover`。
    @State private var markerHoverTime: Double?

    /// 最小宽度和框选的命中判定共用一个常量（`TimelineMarquee`）：画多宽就该
    /// 按多宽判，两边各写一个字面量迟早分叉。
    private var width: Double { max(TimelineMarquee.clipMinimumWidth, clip.timelineDuration * pps) }
    private var isAudioRow: Bool { slot.isAudio }
    /// 视频块里底部要不要塞一条波形（有声、没静音、行高够）。
    private var showsInlineWaveform: Bool {
        !isAudioRow && !clip.isAudioOnly && clip.hasAudio && !clip.isMuted && height > 46
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            background
            content
            if isSelected {
                // 白框 + 青色光晕：选中的是谁一目了然。
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(.white, lineWidth: 2)
                    .shadow(color: .teal.opacity(0.9), radius: 3)
            }
        }
        .frame(width: width, height: height)
        .onTapGesture(coordinateSpace: .local) { location in
            if project.activeTool == .split {
                // 刀片：点哪儿切哪儿。链接组的处理和 ⌘B 一致。
                project.splitClip(clip.id, at: clip.timelineStart + min(max(0, location.x), width) / pps)
            } else {
                let flags = NSApp.currentEvent?.modifierFlags ?? []
                project.select(clip.id, additive: flags.contains(.command) || flags.contains(.shift))
            }
        }
        // 分割模式下移动手势整个停掉（.subviews 保留上面的点击）：
        // 只 guard 回调的话，4pt 的手抖仍会被手势吃掉，本该落下的那一刀就没了。
        .gesture(moveGesture, including: project.activeTool == .split ? .subviews : .all)
        .overlay(alignment: .bottomLeading) { keyframeMarkers }
        .onContinuousHover(coordinateSpace: .local, perform: hoverScrub)
        .onHover(perform: updateSplitCursor)
        // 标记要压在扫帧之上（它自己接管 peek），但必须排在裁切把手**之前** ——
        // 排在后面的话，贴着块两端的标记会盖住把手，那一端就再也裁不动了。
        // 刀片模式下整条让路：点在标记上也该落下那一刀。
        .overlay(alignment: .topLeading) { markerStrip }
        // 把手要在 .offset 之前挂上，不然会留在块没偏移时的位置。
        .overlay(alignment: .leading) { trimHandle(leading: true) }
        .overlay(alignment: .trailing) { trimHandle(leading: false) }
        .contextMenu { contextMenu }
        .instantHelp(verbatim: clip.name)
        .offset(x: (clip.timelineStart + (dragOffset ?? 0)) * pps)
        // 备注气泡会铺到邻块上面去，所以悬着标记的块要抬起来，别被后画的块盖住。
        .zIndex(dragOffset != nil ? 10 : (markerHoverTime != nil ? 5 : 0))
        // 邻居被磁吸重排时平滑挪过去，别硬跳。**正在被拖/被裁的块必须豁免**：
        // 它每一拍都在改位置，0.12s 动画反复重定向画出来的就是「低通滤波后的
        // 鼠标」—— 手越快落后越多，这正是 2026-08-09 那个「光标到最右、块还在
        // 中间」的 bug。约束见 docs/architecture/timeline-drag-gestures.md。
        .animation(isTrimming || dragOffset != nil ? nil : .easeOut(duration: 0.12), value: clip.timelineStart)
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(fillStyle)
    }

    private var fillStyle: Color {
        if isAudioRow || clip.isAudioOnly {
            return Color.blue.opacity(0.42)
        }
        if case .overlay = slot {
            return Color.purple.opacity(0.4)
        }
        return Color.teal.opacity(0.36)
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 名字行
            HStack(spacing: 4) {
                if clip.isStillImage {
                    Image(systemName: "photo").font(.system(size: 8))
                }
                Text(clip.name)
                    .font(.system(size: 9, weight: .medium))
                    .lineLimit(1)
                if abs(clip.speed - 1) > 0.001 {
                    Text(String(format: "%.2fx", clip.speed))
                        .font(.system(size: 8, weight: .semibold))
                        .padding(.horizontal, 3)
                        .background(.black.opacity(0.45), in: Capsule())
                }
                if clip.isMuted, !clip.isAudioOnly {
                    Image(systemName: "speaker.slash").font(.system(size: 8))
                }
                if clip.transitionAfter != .none {
                    Spacer(minLength: 2)
                    Image(systemName: "square.filled.and.line.vertical.and.square")
                        .font(.system(size: 8))
                }
            }
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)

            // 内容区：音频给波形；视频给缩略图条，有声视频底下再垫一条小波形，
            // 一眼能看出这段有没有声、声音在哪起伏（对齐 CapCut 的做法）。
            if clip.isAudioOnly || isAudioRow {
                WaveformView(clip: clip)
                    .padding(.horizontal, 2)
                    .padding(.bottom, 2)
            } else if height > 28 {
                let waveformHeight: Double = showsInlineWaveform ? min(16, (height - 20) * 0.35) : 0
                ThumbnailStripView(clip: clip, height: max(10, height - 20 - waveformHeight))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .padding(.horizontal, 2)
                if showsInlineWaveform {
                    WaveformView(clip: clip)
                        .frame(height: waveformHeight - 2)
                        .padding(.horizontal, 2)
                        .padding(.bottom, 2)
                }
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    // MARK: 手势

    private var moveGesture: some Gesture {
        // 坐标系钉在**滚动视口**上，不用 `.local`：拖动会让块自己在手指底下挪窝
        //（`.offset`），而边缘自动滚动还会把整块内容抽走 —— 两者都会污染以块
        // 自身为参照的 translation。视口这个参照物既不随块动也不随内容滚，
        // `value.location.x` 顺带就是指针在视口里的 x，自动滚动判边界直接拿它用。
        DragGesture(minimumDistance: 4, coordinateSpace: .named(VideoEditTimelineView.scrollSpace))
            .onChanged { value in
                if !isMoving {
                    isMoving = true
                    onDragBegin()
                }
                onDragChange(value.translation, value.location.x)
            }
            .onEnded { _ in
                isMoving = false
                onDragEnd()
            }
    }

    /// 关键帧菱形：贴着块的底边标出每个关键帧的位置（所有属性轨的并集）。
    @ViewBuilder
    private var keyframeMarkers: some View {
        if let animation = clip.animation, !animation.isEmpty, height > 26 {
            ZStack(alignment: .bottomLeading) {
                Color.clear
                ForEach(
                    Array(animation.allKeyTimes(
                        tolerance: KeyframeTrack.sourceTolerance(
                            frameRate: project.state.frameRate, speed: clip.speed
                        )
                    ).enumerated()),
                    id: \.offset
                ) { _, sourceTime in
                    let x = (clip.timelineTime(atSource: sourceTime) - clip.timelineStart) * pps
                    if x >= -0.5, x <= width + 0.5 {
                        Image(systemName: "diamond.fill")
                            .font(.system(size: 6))
                            .foregroundStyle(.white.opacity(0.95))
                            .shadow(color: .black.opacity(0.7), radius: 0.7)
                            .offset(x: x - 3, y: -2)
                    }
                }
            }
            .frame(width: width, height: height, alignment: .bottomLeading)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .allowsHitTesting(false)
        }
    }

    /// 块上的标记。刀片模式整条不吃事件（点哪儿切哪儿优先）。
    @ViewBuilder
    private var markerStrip: some View {
        if !clip.markers.isEmpty {
            ClipMarkerStrip(
                clip: clip,
                width: width,
                height: height,
                pps: pps,
                project: project,
                onHoverMarker: markerHover
            )
            .allowsHitTesting(project.activeTool == .select)
        }
    }

    /// 指针进出标记时，peek 的交接。
    ///
    /// 必须有这么一个仲裁位：标记的帽子是可命中的子视图，指针一进去，块自己那圈
    /// `.onContinuousHover` 立刻收到 `.ended` —— 什么都不做的话，鼠标一碰标记
    /// 画面就弹回播放头。所以进标记时由标记把 peek 顶到它自己那一帧，块那边的
    /// `.ended` 让位；离开标记时**照常** endPeek：指针要是还在块上，下一次
    /// 鼠标移动会立刻把扫帧接回去，指针要是已经走了，画面也不会僵在标记那一帧。
    private func markerHover(_ time: Double?) {
        markerHoverTime = time
        guard !project.clock.isPlaying, !isMoving, !isTrimming else { return }
        if let time {
            project.clock.peek(at: time)
        } else {
            project.clock.endPeek()
        }
    }

    /// 刀片工具悬在块上给十字光标，一眼知道现在点下去是切。
    private func updateSplitCursor(_ inside: Bool) {
        if inside, project.activeTool == .split, !pushedSplitCursor {
            NSCursor.crosshair.push()
            pushedSplitCursor = true
        } else if !inside, pushedSplitCursor {
            NSCursor.pop()
            pushedSplitCursor = false
        }
    }

    /// 鼠标扫过视频块时，画面滚到指的那一帧**看一眼**（peek）：真播放头原地
    /// 不动，时间线上另画一根影子指针，鼠标离开就把画面滚回播放头。
    /// 以前这里直接 seek —— 用户点好的播放头位置会被悬停悄悄拖走。
    /// 不做节流：peek 走 PlayerClock 的链式 seek，天然限流。
    private func hoverScrub(_ phase: HoverPhase) {
        guard !clip.isAudioOnly, !isAudioRow else { return }
        switch phase {
        case .active(let point):
            guard !project.clock.isPlaying, !isMoving, !isTrimming else { return }
            // 标记正接管着 peek，别把画面从标记那一帧拽回指针底下。
            guard markerHoverTime == nil else { return }
            let x = min(max(0, point.x), width)
            project.clock.peek(at: clip.timelineStart + x / pps)
        case .ended:
            // 指针是「进了块上的标记」而不是「离开了块」，peek 该留给标记。
            guard markerHoverTime == nil else { return }
            project.clock.endPeek()
        }
    }

    @ViewBuilder
    private func trimHandle(leading: Bool) -> some View {
        // 块太窄时不给裁切把手，不然根本点不到移动区。
        // 分割模式下彻底不给：把手压着块的两端，边缘那一刀会变成裁切。
        if width > 26, project.activeTool == .select {
            Rectangle()
                .fill(isSelected ? .white.opacity(0.85) : .white.opacity(0.001))
                .frame(width: isSelected ? 5 : 8)
                .clipShape(RoundedRectangle(cornerRadius: 2))
                .contentShape(Rectangle())
                .gesture(
                    // 必须用 .global：把手挂在块边缘，.local 坐标系会随着裁切生效
                    // 跟着块边移动，translation 被自己的位移抵消——表现为裁切量只有
                    // 鼠标位移的一半，且每 tick 在两个位置间振荡（闪烁）。
                    DragGesture(minimumDistance: 2, coordinateSpace: .global)
                        .onChanged { value in
                            if !isTrimming { project.clock.endPeek() }
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

    // MARK: 右键菜单

    @ViewBuilder
    private var contextMenu: some View {
        Button("Split at Playhead") {
            project.select(clip.id, additive: false)
            project.splitAtPlayhead()
        }
        // 右键这一项和 M 是同一个动作，只是把「先选中这一段」替用户做了 ——
        // 快捷键得能被发现，藏在文档里的快捷键等于没有。
        Button("Add Marker at Playhead") {
            project.addMarker(toClip: clip.id, atTimeline: project.clock.time)
        }
        .disabled(!clip.contains(time: project.clock.time))
        if !clip.isAudioOnly {
            if clip.hasAudio, !clip.isMuted {
                Button("Detach Audio") { project.detachAudio(from: clip.id) }
            }
            if slot.isMain {
                Button("Move to Picture-in-Picture") { project.toggleOverlay(clip.id) }
            } else if case .overlay = slot {
                Button("Move to Main Track") { project.toggleOverlay(clip.id) }
            }
        }
        Divider()
        if let url = revealTarget {
            Button("Show in Finder") { revealInFinder(url) }
            Divider()
        }
        Button("Delete", role: .destructive) {
            project.select(clip.id, additive: false)
            project.deleteSelected()
        }
    }

    /// 揭示目标：图片素材优先原图（`sourceURL` 是生成的静帧缓存视频），
    /// 原图不在了退回缓存视频；都不在（素材丢失）就不出这一项。
    private var revealTarget: URL? {
        [clip.stillImageURL, clip.sourceURL]
            .compactMap { $0 }
            .first { FileManager.default.fileExists(atPath: $0.path) }
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
    /// (手势总位移, 指针在滚动视口里的 x)。与剪辑块同一套语义。
    let onDragChange: (CGSize, Double) -> Void
    let onDragEnd: () -> Void

    @State private var isMoving = false

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
        .frame(
            width: max(TimelineMarquee.shapeMinimumWidth, shape.duration * pps),
            height: TimelineMarquee.shapeHeight,
            alignment: .leading
        )
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(shape.color.swiftUIColor.opacity(0.55))
        )
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 4).strokeBorder(.white, lineWidth: 1.5)
            }
        }
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
                    onDragChange(value.translation, value.location.x)
                }
                .onEnded { _ in
                    isMoving = false
                    onDragEnd()
                }
        )
    }
}

// MARK: - 缩略图条

/// 视频块里的缩略图条：按可见宽度取若干帧铺满。取帧是异步的，先给底色。
private struct ThumbnailStripView: View {
    let clip: EditClip
    let height: Double

    @State private var images: [CGImage] = []

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                if images.isEmpty {
                    Color.black.opacity(0.25)
                } else {
                    ForEach(Array(images.enumerated()), id: \.offset) { _, image in
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .scaledToFill()
                            .frame(
                                width: proxy.size.width / Double(images.count),
                                height: height
                            )
                            .clipped()
                    }
                }
            }
            .task(id: taskKey(width: proxy.size.width)) {
                await loadThumbnails(width: proxy.size.width)
            }
        }
        .frame(height: height)
    }

    private func taskKey(width: Double) -> String {
        "\(clip.sourceURL.path)|\(Int(clip.sourceStart * 10))|\(Int(clip.sourceDuration * 10))|\(Int(width / 56))"
    }

    private func loadThumbnails(width: Double) async {
        guard width > 4 else { return }
        // 裁切/缩放拖动中 key 每个 tick 都在变：已有图先撑着，等手停稳 200ms 再取，
        // 否则每一拍都解码一串帧、旧任务的结果还会乱序落地把新图盖掉——就是闪烁。
        // 首次加载（还没图）不等，尽快替掉底色。
        if !images.isEmpty {
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
        }
        let count = max(1, min(24, Int(width / 56)))
        // 图片素材：直接读原图铺满（比开 AVAsset 快得多，占位期也能显示）。
        if let stillURL = clip.stillImageURL {
            if let image = await ClipThumbnailCache.shared.stillThumbnail(url: stillURL) {
                images = Array(repeating: image, count: count)
            }
            return
        }
        let loaded = await ClipThumbnailCache.shared.thumbnails(
            url: clip.sourceURL,
            start: clip.sourceStart,
            duration: clip.sourceDuration,
            count: count
        )
        guard !Task.isCancelled, !loaded.isEmpty else { return }
        images = loaded
    }
}

/// 取帧走全局缓存：同一段素材反复布局时别重复解码。
actor ClipThumbnailCache {
    static let shared = ClipThumbnailCache()

    private var cache: [String: [CGImage]] = [:]
    private var generators: [URL: AVAssetImageGenerator] = [:]
    private var stills: [URL: CGImage] = [:]

    /// 静态图片的小缩略图（CGImageSource 直读，快）。
    func stillThumbnail(url: URL) -> CGImage? {
        if let cached = stills[url] { return cached }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 160,
            kCGImageSourceCreateThumbnailWithTransform: true
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        stills[url] = image
        return image
    }

    func thumbnails(url: URL, start: Double, duration: Double, count: Int) async -> [CGImage] {
        let key = "\(url.path)|\(Int(start * 10))|\(Int(duration * 10))|\(count)"
        if let cached = cache[key] { return cached }

        let generator: AVAssetImageGenerator
        if let existing = generators[url] {
            generator = existing
        } else {
            let asset = AVURLAsset(url: url)
            generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 160, height: 90)
            // 缩略图不用帧准，给宽容差能快一个数量级。
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
            generators[url] = generator
        }

        var result: [CGImage] = []
        for index in 0..<count {
            // 调用方（.task）已经换 key 取消了就别接着磨：actor 是串行的，
            // 磨完一整串废帧会把新请求堵在门外。
            if Task.isCancelled { return [] }
            let fraction = (Double(index) + 0.5) / Double(count)
            let seconds = start + duration * fraction
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            if let image = try? await generator.image(at: time).image {
                result.append(image)
            }
        }
        if !result.isEmpty { cache[key] = result }
        return result
    }
}

// MARK: - 波形

/// 音频块里的波形。真读采样（降到几百个桶），异步画。
/// 波形条。画的是**听到的**声音，不是源文件的原始波形 —— 音量和渐入渐出
/// 都乘进柱高里，所以拉音量、改淡变时轨道上当场跟着变。
///
/// 增益只影响绘制，不进 `.task` 的 id：改音量不该让它重读一遍 PCM。
private struct WaveformView: View {
    let clip: EditClip

    @State private var samples: [Float] = []

    /// 这一柱（时间线上的位置 0…1）实际听到的增益。
    private func gain(atFraction fraction: Double) -> Double {
        guard !clip.isMuted else { return 0 }
        let span = clip.timelineDuration
        guard span > 0 else { return clip.volume }
        let fades = clip.audioFades
        let elapsed = fraction * span
        var envelope = 1.0
        if fades.fadeIn > 0, elapsed < fades.fadeIn {
            envelope = min(envelope, elapsed / fades.fadeIn)
        }
        if fades.fadeOut > 0, elapsed > span - fades.fadeOut {
            envelope = min(envelope, max(0, span - elapsed) / fades.fadeOut)
        }
        return clip.volume * envelope
    }

    var body: some View {
        Canvas { context, size in
            guard !samples.isEmpty else { return }
            let barWidth = size.width / Double(samples.count)
            for (index, value) in samples.enumerated() {
                // 柱心对准这一段的中点，渐变的斜坡才不会整体偏半柱。
                let fraction = (Double(index) + 0.5) / Double(samples.count)
                // 音量能推到 +6dB（线性 2.0），高度得夹住，不然柱子冲出轨道。
                let scaled = min(1, Double(value) * gain(atFraction: fraction))
                let h = max(1, scaled * size.height)
                let rect = CGRect(
                    x: Double(index) * barWidth,
                    y: size.height - h,
                    width: max(0.8, barWidth - 0.6),
                    height: h
                )
                context.fill(Path(rect), with: .color(.white.opacity(0.75)))
            }
        }
        .task(id: "\(clip.sourceURL.path)|\(Int(clip.sourceStart * 10))|\(Int(clip.sourceDuration * 10))") {
            // 同缩略图条：裁切拖动中先拿旧波形撑着，手停稳了再重读 PCM。
            if !samples.isEmpty {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }
            let loaded = await WaveformCache.shared.samples(
                url: clip.sourceURL,
                start: clip.sourceStart,
                duration: clip.sourceDuration
            )
            guard !Task.isCancelled, !loaded.isEmpty else { return }
            samples = loaded
        }
    }
}

/// 波形采样缓存：AVAssetReader 读 PCM，按桶取峰值。
actor WaveformCache {
    static let shared = WaveformCache()

    private var cache: [String: [Float]] = [:]

    func samples(url: URL, start: Double, duration: Double, bucketCount: Int = 240) async -> [Float] {
        let key = "\(url.path)|\(Int(start * 10))|\(Int(duration * 10))"
        if let cached = cache[key] { return cached }

        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first else { return [] }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 8000
        ]
        guard let reader = try? AVAssetReader(asset: asset) else { return [] }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(output)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: duration, preferredTimescale: 600)
        )
        guard reader.startReading() else { return [] }

        let totalSamples = Int(8000 * duration)
        let samplesPerBucket = max(1, totalSamples / bucketCount)
        var buckets: [Float] = []
        var currentPeak: Int16 = 0
        var currentCount = 0

        while let buffer = output.copyNextSampleBuffer(),
              let block = CMSampleBufferGetDataBuffer(buffer) {
            let length = CMBlockBufferGetDataLength(block)
            var data = Data(count: length)
            data.withUnsafeMutableBytes { raw in
                if let base = raw.baseAddress {
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
                }
            }
            data.withUnsafeBytes { raw in
                let int16 = raw.bindMemory(to: Int16.self)
                for value in int16 {
                    currentPeak = max(currentPeak, Int16(clamping: abs(Int32(value))))
                    currentCount += 1
                    if currentCount >= samplesPerBucket {
                        buckets.append(Float(currentPeak) / Float(Int16.max))
                        currentPeak = 0
                        currentCount = 0
                    }
                }
            }
        }
        if currentCount > 0 {
            buckets.append(Float(currentPeak) / Float(Int16.max))
        }
        reader.cancelReading()

        // 稍微抬一下小信号，看得见形状。
        let shaped = buckets.map { min(1, pow($0, 0.7)) }
        cache[key] = shaped
        return shaped
    }
}
