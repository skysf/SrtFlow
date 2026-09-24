import AppKit
import SwiftUI
import SrtFlowCore

// MARK: - 剪辑块
//
// 从 `VideoEditTimelineView.swift` 拆出来（拆分前 2101 行，远超仓库约 800 行的
// 警戒线）。块自己只管画和收手势，所有落点算法都在父级 —— 与 `ShapeBlockView` /
// `TextBlockView` 逐行同构，包括「拖动中只是渲染偏移、松手才写模型」这条
// 硬约束（docs/architecture/timeline-drag-gestures.md）。
// 接线守卫 `checks/timeline-drag-wiring.sh` 按文件扫描，挪动这里的东西要同步改它。

// MARK: - 剪辑块

/// 块上要画的、来自工程的那几个值：由时间线（它订阅工程）算好传进来。
///
/// **块自己不订阅工程。** 订阅的话，工程里任何一处变化都让全部块重算一遍 ——
/// 2026-09-24 在用户 70 多段的工程上实测：点选一段，73 个块全部重算、61 条音量线
/// 全部重画，一次点击吃掉约 0.6 秒 CPU；拖一段文字，每动一下又是全部块重算一遍。
/// 现在块按值比较（`ClipBlockView` 的 `==`），画面用得到的输入没变就不重算。
/// 块里再读工程的值，一律先加到这里来。
struct ClipBlockContext: Equatable {
    /// 所在那条轨的颜色（`TimelineState.trackColorIndex`）。
    var colorIndex: Int
    /// 所在那条轨的推子：波形画「听到的声音」，推子也乘进去。
    var trackGain: Double
    var activeTool: TimelineTool
    /// 关键帧菱形按工程帧率判「是不是同一帧」。
    var frameRate: ProjectFrameRate

    @MainActor
    init(slot: TrackSlot, project: VideoEditProject) {
        colorIndex = project.state.trackColorIndex(for: slot)
        trackGain = project.state.trackVolume(for: slot)
        activeTool = project.activeTool
        frameRate = project.state.frameRate
    }
}

/// 一段素材的块：视频带缩略图条和名字，音频画波形，选中描白框。
///
/// 调用方要套 `.equatable()`：块的输入里有闭包，SwiftUI 比不出闭包「没变」，不套的话
/// 时间线每重算一次（拖动每动一下），全部块都跟着重算。
struct ClipBlockView: View, Equatable {
    let clip: EditClip
    let slot: TrackSlot
    let height: Double
    let pps: Double
    let isSelected: Bool
    /// 拖动中的渲染位移（秒）。nil = 没在被拖。被拖的块和跟着它动的伙伴都拿它
    /// 画位置 —— 拖动期间模型一个字都不改，所以 `timelineStart` 是拖前那个值。
    let dragOffset: Double?
    let context: ClipBlockContext
    /// 只拿来**调动作**（选中、切、打标记、右键菜单），不订阅 —— 见 `ClipBlockContext`。
    let project: VideoEditProject
    let onDragBegin: () -> Void
    /// (手势总位移, 指针在滚动视口里的位置)。位移的垂直分量用来跨轨，指针位置
    /// 用来判断到没到视口边缘（两轴的自动滚动）。都在视口坐标系里量，
    /// 见 `moveGesture`。
    let onDragChange: (CGSize, CGPoint) -> Void
    let onDragEnd: () -> Void
    let onTrim: (Bool, Double) -> Void
    let onTrimEnd: () -> Void
    /// 指针进出块上的标记帽子。扫帧 peek 的所有者是时间线容器，块只负责把
    /// 「悬着哪一枚」报上去（仲裁本体在 `VideoEditTimelineView.markerPeek`）。
    let onMarkerPeek: (Double?) -> Void

    /// 移动手势进行中：第一拍要开一轮拖动会话。（扫帧让位归容器判 —— 它看
    /// `clipDrag`，那是同一件事的模型侧。）
    @State private var isMoving = false
    /// 裁切进行中：块自己要严格跟手，磁吸重排动画只留给邻居。
    @State private var isTrimming = false
    /// 这块上有没有标记正被悬着。只用来抬 zIndex（备注气泡会铺到邻块上面去，
    /// 不抬起来会被后画的块盖住）—— peek 的仲裁位在时间线容器那一层。
    @State private var markerHovered = false

    /// 最小宽度和框选的命中判定共用一个常量（`TimelineMarquee`）：画多宽就该
    /// 按多宽判，两边各写一个字面量迟早分叉。
    private var width: Double { max(TimelineMarquee.clipMinimumWidth, clip.timelineDuration * pps) }
    private var isAudioRow: Bool { slot.isAudio }
    /// 视频块里底部要不要塞一条波形（有声、没静音、行高够）。
    private var showsInlineWaveform: Bool {
        !isAudioRow && !clip.isAudioOnly && clip.hasAudio && !clip.isMuted && height > 46
    }

    /// 视频块底部那条波形带多高：跟着行高长（行拉高了，声音那一半也该看得清、
    /// 曲线也该拖得动），最矮 12、最高 64。
    private var inlineWaveformHeight: Double {
        guard showsInlineWaveform else { return 0 }
        return min(64, max(12, (height - 20) * 0.4))
    }

    private var trackGain: Double { context.trackGain }

    /// 只比画面用得到的输入。闭包比不了、也不用比：它们捕获的是时间线视图，读的是它的
    /// `@State` 和工程对象，永远是最新的；`project` 是同一个对象。
    nonisolated static func == (lhs: ClipBlockView, rhs: ClipBlockView) -> Bool {
        lhs.clip == rhs.clip && lhs.slot == rhs.slot && lhs.height == rhs.height
            && lhs.pps == rhs.pps && lhs.isSelected == rhs.isSelected
            && lhs.dragOffset == rhs.dragOffset && lhs.context == rhs.context
    }

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        ZStack(alignment: .topLeading) {
            // 单独隐藏的段（V）：灰显去色，但**不关命中** —— 它还得点得中、拖得动、
            // 能再按一次 V 放出来（整轨隐藏那边才是「灰显且不可编辑」，合同见
            // docs/architecture/clip-visibility.md）。选中框不跟着变淡，否则
            // 「藏着而且正选中」这个状态看不出来。
            ZStack(alignment: .topLeading) {
                background
                content
            }
            .opacity(clip.isHidden ? 0.4 : 1)
            .saturation(clip.isHidden ? 0 : 1)
            if isSelected {
                // 白框 + 青色光晕：选中的是谁一目了然。
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(.white, lineWidth: 2)
                    .shadow(color: .teal.opacity(0.9), radius: 3)
            }
        }
        .frame(width: width, height: height)
        .onTapGesture(coordinateSpace: .local) { location in
            if context.activeTool == .split {
                // 刀片：点哪儿切哪儿。链接组的处理和 ⌘B 一致。
                project.splitClip(clip.id, at: clip.timelineStart + min(max(0, location.x), width) / pps)
            } else {
                let flags = NSApp.currentEvent?.modifierFlags ?? []
                project.select(clip.id, additive: flags.contains(.command) || flags.contains(.shift))
            }
        }
        // 分割模式下移动手势整个停掉（.subviews 保留上面的点击）：
        // 只 guard 回调的话，4pt 的手抖仍会被手势吃掉，本该落下的那一刀就没了。
        .gesture(moveGesture, including: context.activeTool == .split ? .subviews : .all)
        .overlay(alignment: .bottomLeading) { keyframeMarkers }
        // 刀片工具悬在块上给十字光标，一眼知道现在点下去是切。
        // nil = 这一处不接管指针，交回外层。
        .pointerStyle(context.activeTool == .split ? .rectSelection : nil)
        // 标记必须排在裁切把手**之前** —— 排在后面的话，贴着块两端的标记会盖住
        // 把手，那一端就再也裁不动了。（悬到帽子上时容器的扫帧会让位给它，
        // 仲裁在 VideoEditTimelineView.markerPeek。）
        // 刀片模式下整条让路：点在标记上也该落下那一刀。
        .overlay(alignment: .topLeading) { markerStrip }
        // 把手要在 .offset 之前挂上，不然会留在块没偏移时的位置。
        .overlay(alignment: .leading) { trimHandle(leading: true) }
        .overlay(alignment: .trailing) { trimHandle(leading: false) }
        .contextMenu { contextMenu }
        .instantHelp(verbatim: clip.name)
        .offset(x: (clip.timelineStart + (dragOffset ?? 0)) * pps)
        // 备注气泡会铺到邻块上面去，所以悬着标记的块要抬起来，别被后画的块盖住。
        .zIndex(dragOffset != nil ? 10 : (markerHovered ? 5 : 0))
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

    /// 块的填充色**按所在轨道**取，不是按轨道种类 —— 多条上层视频轨全是
    /// 一个颜色的话，一眼看不出某个块属于哪一条。见 TrackPalette。
    private var fillStyle: Color {
        // 纯音频段被拖到视频轨上（少见但允许）时按音频色走：颜色跟的是
        // 「这块是什么」，块上画的也是波形。
        let index = context.colorIndex
        if isAudioRow || clip.isAudioOnly { return TrackPalette.clipFill(audio: index) }
        return TrackPalette.clipFill(video: index)
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
                // 灰显本身还不够：轨道整条藏起来时块也是灰的，两种状态得分得开。
                if clip.isHidden {
                    Image(systemName: "eye.slash").font(.system(size: 8))
                }
                // 挂了声音场景：按场景那一组给一枚小图标（喇叭 / 房子 / 树）。
                if let scene = clip.soundScene {
                    Image(systemName: scene.kind.group.symbol).font(.system(size: 8))
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

            // 内容区：音频给波形；视频给缩略图条，有声视频底下再垫一条波形带，
            // 一眼能看出这段有没有声、声音在哪起伏（对齐 CapCut 的做法）。
            //
            // 波形**铺满块宽、不留左右边距**：它的 x 直接就是「离段起点多少秒 × pps」，
            // 放大到一帧 200pt 之后，2pt 的边距就是一段看得见的错位。圆角由块的
            // clipShape 裁。
            if clip.isAudioOnly || isAudioRow {
                WaveformView(clip: clip, pps: pps, trackGain: trackGain)
                    // 音量线画在波形上、贴着线操作（它自己的命中区只是线那一条窄带）。
                    .overlay {
                        VolumeCurveOverlay(clip: clip, pps: pps, activeTool: context.activeTool, project: project)
                    }
                    .padding(.bottom, 2)
            } else if height > 28 {
                ThumbnailStripView(clip: clip, height: max(10, height - 20 - inlineWaveformHeight), pps: pps)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .padding(.horizontal, 2)
                if showsInlineWaveform {
                    WaveformView(clip: clip, pps: pps, trackGain: trackGain)
                        .overlay {
                            VolumeCurveOverlay(clip: clip, pps: pps, activeTool: context.activeTool, project: project)
                        }
                        .frame(height: inlineWaveformHeight - 2)
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
                onDragChange(value.translation, value.location)
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
                            frameRate: context.frameRate, speed: clip.speed
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
            .allowsHitTesting(context.activeTool == .select)
        }
    }

    /// 指针进出标记帽子：只往上报，不自己动 peek。
    ///
    /// 扫帧 peek 的**唯一所有者是时间线容器**（2026-09-21 起，见
    /// `VideoEditTimelineView.hoverPeek`）。块这边再写一份的话，容器和块两圈
    /// hover 都在写 `peekTime`，谁后到谁赢 —— 那是竞态，不是行为。
    /// 本地只留一个「有没有悬着」给 zIndex 用。
    private func markerHover(_ time: Double?) {
        markerHovered = time != nil
        onMarkerPeek(time)
    }

    @ViewBuilder
    private func trimHandle(leading: Bool) -> some View {
        // 块太窄时不给裁切把手，不然根本点不到移动区。
        // 分割模式下彻底不给：把手压着块的两端，边缘那一刀会变成裁切。
        if width > 26, context.activeTool == .select {
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
                .pointerStyle(.columnResize)
        }
    }

    // MARK: 右键菜单

    @ViewBuilder
    private var contextMenu: some View {
        Button("Split at Playhead") {
            project.select(clip.id, additive: false)
            project.splitAtPlayhead()
        }
        // 和 V 同一个动作，同样把「先选中这一段」替用户做了。
        Button(clip.isHidden ? "Show Clip" : "Hide Clip") {
            project.select(clip.id, additive: false)
            project.toggleHiddenForSelection()
        }
        // 右键这一项和 M 是同一个动作，只是把「先选中这一段」替用户做了 ——
        // 快捷键得能被发现，藏在文档里的快捷键等于没有。
        Button("Add Marker at Playhead") {
            project.addMarker(toClip: clip.id, atTimeline: project.clock.time)
        }
        .disabled(!clip.contains(time: project.clock.time))
        // 右键点在音量线上也落到这份菜单（线只接管拖动和点击）。
        if clip.hasVolumeCurve {
            Button("Remove Volume Curve") { project.removeVolumeCurve(clip.id) }
        }
        if !clip.isAudioOnly {
            if clip.hasAudio, !clip.isMuted {
                Button("Detach Audio") { project.detachAudio(from: clip.id) }
            }
            if slot.isMain {
                Button("Move to Upper Track") { project.toggleOverlay(clip.id) }
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
