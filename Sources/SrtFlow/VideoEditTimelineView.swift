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

    /// 拖动时吸附到的参考时刻（画一条黄线）。
    @State private var snapGuide: Double?
    /// 播放跟随滚动的节流。
    @State private var lastFollowTime: Double = -1
    /// 正在进行的水平拖动（落点时刻，跨轨落地时要用）。
    @State private var activeDrag: (clipID: UUID, proposed: Double)?
    /// 垂直拖动瞄准的目标行（高亮它）。
    @State private var dragTargetRow: (id: String, target: VideoEditProject.RowTarget)?
    /// 轨道头上下拖调行高的基准。
    @State private var headerResizeBase: Double?
    /// 时间线横向已滚动了多少（判断播放头还在不在视野里）。
    @State private var scrollOffset: Double = 0

    private static let scrollSpace = "timelineScroll"

    private var pps: Double { project.pixelsPerSecond }

    /// 内容总宽度：留出结尾空白，方便把素材拖到最后。
    private var contentWidth: Double {
        max(600, project.duration * pps + 320)
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
        var isSubtitle = false
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
        if project.state.subtitle != nil {
            result.append(RowSpec(id: "subtitle", icon: "captions.bubble", height: 22, slot: nil, isSubtitle: true))
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
                    .onChange(of: clock.time) { _, newTime in
                        followPlayhead(newTime, proxy: proxy, viewportWidth: viewport.size.width)
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
                                .help("Hide or show this track (V)")
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

            // 吸附参考线
            if let snapGuide {
                Rectangle()
                    .fill(.yellow)
                    .frame(width: 1)
                    .offset(x: snapGuide * pps)
            }

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

            playhead
        }
        .contentShape(Rectangle())
        // 点空白处：取消选中。
        .onTapGesture {
            project.selectedClipIDs = []
            project.selectedShapeID = nil
        }
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
        } else if row.isSubtitle {
            subtitleRow
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
                    isSelected: project.selectedClipIDs.contains(clip.id),
                    project: project,
                    onDrag: { proposed, dy in
                        let snapped = project.snap(proposed, excluding: clip.id)
                        snapGuide = snapped.guide
                        activeDrag = (clip.id, snapped.time)
                        project.liveMove(clip.id, toStart: snapped.time)
                        dragTargetRow = verticalTarget(for: clip, slot: slot, dy: dy)
                    },
                    onDragEnd: {
                        snapGuide = nil
                        if let target = dragTargetRow, let drag = activeDrag, drag.clipID == clip.id {
                            // 跨轨：先回滚水平预挪，整个动作合成一步撤销。
                            project.cancelLiveEdit()
                            project.relocate(clip.id, to: target.target, start: drag.proposed)
                        } else {
                            project.endLiveEdit()
                        }
                        activeDrag = nil
                        dragTargetRow = nil
                    },
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

    /// 垂直拖出 18pt 之后开始找目标行：同类行里挑离指尖最近的；
    /// 拖出最上面（视频）/最下面（音频）就是开新轨。
    private func verticalTarget(
        for clip: EditClip,
        slot: TrackSlot,
        dy: Double
    ) -> (id: String, target: VideoEditProject.RowTarget)? {
        guard abs(dy) > 18 else { return nil }
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
                    isSelected: project.selectedShapeID == shape.id,
                    onSelect: { project.selectedShapeID = shape.id },
                    onDrag: { proposed in
                        let snapped = project.snap(proposed, excluding: shape.id)
                        snapGuide = snapped.guide
                        project.liveApply { state in
                            state.updateShape(shape.id) { $0.timelineStart = max(0, snapped.time) }
                        }
                    },
                    onDragEnd: {
                        snapGuide = nil
                        project.endLiveEdit(rebuildsPreview: false)
                    }
                )
            }
        }
    }

    // MARK: - 字幕行

    private var subtitleRow: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4)
                .fill(.quaternary.opacity(0.25))
                .frame(width: contentWidth)
            if let cues = project.state.subtitle?.cues {
                ForEach(cues) { cue in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.orange.opacity(0.45))
                        .frame(
                            width: max(2, (cue.end - cue.start) * pps),
                            height: 14
                        )
                        .offset(x: cue.start * pps, y: 4)
                        .onTapGesture {
                            clock.seek(to: cue.start + 0.05)
                        }
                        .help(SubtitleSerializer.plainText(cue.text))
                }
            }
        }
    }

    // MARK: - 播放头

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
            pixelsPerSecond.wrappedValue = scale
            keepAnchorFixed(atScale: scale)
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
                .help("Drag up or down to resize this kind of track")
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
    @ObservedObject var project: VideoEditProject
    /// (水平落点秒, 垂直位移点) —— 垂直分量用来跨轨。
    let onDrag: (Double, Double) -> Void
    let onDragEnd: () -> Void
    let onTrim: (Bool, Double) -> Void
    let onTrimEnd: () -> Void

    /// 手势开始时的起点/状态，绝对增量都相对它算。
    @State private var dragStartOrigin: Double?
    /// 拖动中的视觉位置：跟手画，state 里的磁吸重排照常进行 ——
    /// 不然拖动块每一拍都被吸回格点，看起来就是闪烁。
    @State private var dragVisualStart: Double?
    /// 裁切进行中：块自己要严格跟手，磁吸重排动画只留给邻居。
    @State private var isTrimming = false

    private var width: Double { max(6, clip.timelineDuration * pps) }
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
        .onTapGesture {
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            project.select(clip.id, additive: flags.contains(.command) || flags.contains(.shift))
        }
        .gesture(moveGesture)
        .onContinuousHover(coordinateSpace: .local, perform: hoverScrub)
        // 把手要在 .offset 之前挂上，不然会留在块没偏移时的位置。
        .overlay(alignment: .leading) { trimHandle(leading: true) }
        .overlay(alignment: .trailing) { trimHandle(leading: false) }
        .contextMenu { contextMenu }
        .help(clip.name)
        .offset(x: (dragVisualStart ?? clip.timelineStart) * pps)
        .zIndex(dragVisualStart != nil ? 10 : 0)
        // 邻居被磁吸重排时平滑挪过去，别硬跳。裁切中的块例外：
        // 每个 tick 都在改 timelineStart/宽度，动画反复重定向就是「追手指」的卡顿感。
        .animation(isTrimming ? nil : .easeOut(duration: 0.12), value: clip.timelineStart)
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
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if dragStartOrigin == nil {
                    dragStartOrigin = clip.timelineStart
                    // 拖一个没选中的块 = 单选它；拖已选中的块 = 整组一起动。
                    if !project.selectedClipIDs.contains(clip.id) {
                        project.select(clip.id, additive: false)
                    }
                }
                guard let origin = dragStartOrigin else { return }
                let proposed = origin + value.translation.width / pps
                dragVisualStart = max(0, proposed)
                onDrag(proposed, value.translation.height)
            }
            .onEnded { _ in
                dragStartOrigin = nil
                dragVisualStart = nil
                onDragEnd()
            }
    }

    /// 鼠标扫过视频块时，画面直接滚到指的那一帧（播放中和拖动中不抢）。
    /// 不做节流：`precise: false` 走 PlayerClock 的链式 seek，天然限流。
    private func hoverScrub(_ phase: HoverPhase) {
        guard !clip.isAudioOnly, !isAudioRow else { return }
        guard case .active(let point) = phase else { return }
        guard !project.clock.isPlaying, dragStartOrigin == nil, !isTrimming else { return }
        let x = min(max(0, point.x), width)
        project.clock.seek(to: clip.timelineStart + x / pps, precise: false)
    }

    @ViewBuilder
    private func trimHandle(leading: Bool) -> some View {
        // 块太窄时不给裁切把手，不然根本点不到移动区。
        if width > 26 {
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
        Button("Delete", role: .destructive) {
            project.select(clip.id, additive: false)
            project.deleteSelected()
        }
    }
}

// MARK: - 形状块

private struct ShapeBlockView: View {
    let shape: ShapeAnnotation
    let pps: Double
    let isSelected: Bool
    let onSelect: () -> Void
    let onDrag: (Double) -> Void
    let onDragEnd: () -> Void

    @State private var dragStartOrigin: Double?

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
        .frame(width: max(24, shape.duration * pps), height: 20, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(shape.color.swiftUIColor.opacity(0.55))
        )
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 4).strokeBorder(.white, lineWidth: 1.5)
            }
        }
        .offset(x: shape.timelineStart * pps, y: 3)
        .onTapGesture(perform: onSelect)
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    if dragStartOrigin == nil {
                        dragStartOrigin = shape.timelineStart
                        onSelect()
                    }
                    guard let origin = dragStartOrigin else { return }
                    onDrag(origin + value.translation.width / pps)
                }
                .onEnded { _ in
                    dragStartOrigin = nil
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
private struct WaveformView: View {
    let clip: EditClip

    @State private var samples: [Float] = []

    var body: some View {
        Canvas { context, size in
            guard !samples.isEmpty else { return }
            let barWidth = size.width / Double(samples.count)
            for (index, value) in samples.enumerated() {
                let h = max(1, Double(value) * size.height)
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
