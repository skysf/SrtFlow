import AppKit
import SwiftUI

// MARK: - 剪辑块
//
// 从 `VideoEditTimelineView.swift` 拆出来（拆分前 2101 行，远超仓库约 800 行的
// 警戒线）。块自己只管画和收手势，所有落点算法都在父级 —— 与 `ShapeBlockView` /
// `TextBlockView` 逐行同构，包括「拖动中只是渲染偏移、松手才写模型」这条
// 硬约束（docs/architecture/timeline-drag-gestures.md）。
// 接线守卫 `checks/timeline-drag-wiring.sh` 按文件扫描，挪动这里的东西要同步改它。

// MARK: - 剪辑块

/// 一段素材的块：视频带缩略图条和名字，音频画波形，选中描白框。
struct ClipBlockView: View {
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
    /// (手势总位移, 指针在滚动视口里的位置)。位移的垂直分量用来跨轨，指针位置
    /// 用来判断到没到视口边缘（两轴的自动滚动）。都在视口坐标系里量，
    /// 见 `moveGesture`。
    let onDragChange: (CGSize, CGPoint) -> Void
    let onDragEnd: () -> Void
    let onTrim: (Bool, Double) -> Void
    let onTrimEnd: () -> Void

    /// 移动手势进行中（悬停扫帧要让位，第一拍还要开一轮拖动会话）。
    @State private var isMoving = false
    /// 裁切进行中：块自己要严格跟手，磁吸重排动画只留给邻居。
    @State private var isTrimming = false
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
        // 刀片工具悬在块上给十字光标，一眼知道现在点下去是切。
        // nil = 这一处不接管指针，交回外层。
        .pointerStyle(project.activeTool == .split ? .rectSelection : nil)
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

    /// 块的填充色**按所在轨道**取，不是按轨道种类 —— 多条上层视频轨全是
    /// 一个颜色的话，一眼看不出某个块属于哪一条。见 TrackPalette。
    private var fillStyle: Color {
        // 纯音频段被拖到视频轨上（少见但允许）时按音频色走：颜色跟的是
        // 「这块是什么」，块上画的也是波形。
        let index = project.state.trackColorIndex(for: slot)
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
