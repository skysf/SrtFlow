import AVFoundation
import AppKit
import ImageIO
import SwiftUI
import os
import SrtFlowCore

// MARK: - 时间线这一族文件的分工
//
// 这个文件只留「骨架」：行模型（`RowSpec` / `rowLayouts`）、轨道头列、滚动容器、
// 轨道行、播放头。其余各自成文件（2026-09-18 拆分，拆分前这一个文件 2101 行）：
//
// - `VideoEditTimelineMarqueeGesture.swift` 框选接线
// - `VideoEditTimelineDragWiring.swift`     四类块共用的拖动接线
// - `VideoEditTimelineClipBlock.swift`      剪辑块
// - `VideoEditTimelineShapeRow.swift`       形状行与形状块
// - `VideoEditTimelineTextRow.swift`        文字行与文字块
// - `VideoEditTimelineSubtitleRow.swift`    字幕行（原文/译文两条镜像轨）
// - `VideoEditTimelineRuler.swift`          标尺与行高拖调
// - `VideoEditTimelineThumbnails.swift`     缩略图条
// - `VideoEditTimelineWaveform.swift`       波形条
// - `VideoEditTimelinePinchZoom.swift`      捏合缩放
// - `VideoEditTimelineDropRouter.swift`     时间线上唯一的拖放落点（文件 / 滤镜 / 音频库 / 转场）
//
// 手势与落点的长期约束在 docs/architecture/timeline-drag-gestures.md，
// 接线守卫 `checks/timeline-drag-wiring.sh` 按上面这批文件逐个扫描。

/// 时间线区域：左边一列轨道头图标，右边横向滚动的标尺 + 各轨 + 播放头。
struct VideoEditTimelineView: View {
    @ObservedObject var project: VideoEditProject
    /// 必须**直接**订阅播放器时钟：它是 project 上的普通属性，不是 @Published，
    /// 光观察 project 的话时钟跳动不会触发重绘 —— 播放头就会僵在原地。
    @ObservedObject var clock: PlayerClock

    /// 正在进行的剪辑拖动。**拖动中不写 `TimelineState`**：块画在哪只由它的
    /// `offset` 决定，松手才 `commitMove` 落一次（见
    /// docs/architecture/timeline-drag-gestures.md）。
    @State var clipDrag: ClipDragSession?
    /// 正在拉的选择框。同一条约束：**拖框中不写 `project`**，高亮谁只由它的
    /// `hit` 决定，松手才 `applyBoxSelection` 落一次。
    @State var marquee: TimelineMarquee.Session?
    /// 正在被拖的字幕 cue。剪辑/形状块各自是独立视图、用自己的 `isMoving`
    /// 标记起手，cue 块是 `ForEach` 里的裸图形，只能在这一层按 id 记。
    @State var movingCueID: UUID?
    /// 指针正悬在某枚标记帽子上时，那枚标记所在的时间线时刻；nil = 没悬着。
    /// **扫帧 peek 的仲裁位**（合同见 `hoverPeek` / `markerPeek`）。
    ///
    /// 必须记在**这一层**：扫帧 peek 的唯一所有者是容器，而标记帽子是剪辑块里的
    /// 子视图 —— 仲裁位留在块内的话容器看不见，鼠标一碰标记，容器下一拍就会把
    /// 画面从标记那一帧拽回指针底下。
    @State var markerPeekTime: Double?
    /// 双击打开了就地编辑浮层的那条 cue（编辑本体是 `SubtitleInlineEditor`，
    /// 与预览里双击字幕共用同一份提交规则）。
    ///
    /// **连行别一起记**：原文行和译文行是同一批 cue ID 的镜像，只按 ID 判定的话
    /// 双击一行会让两行同时弹出浮层。
    @State var editingCue: EditingCue?
    /// 播放跟随滚动的节流。
    @State private var lastFollowTime: Double = -1
    /// 垂直拖动瞄准的目标行（高亮它）。
    @State var dragTargetRow: (id: String, target: VideoEditProject.RowTarget)?
    /// 轨道头上下拖调行高的基准。
    @State private var headerResizeBase: RowHeightDragState?
    /// 从转场库拖卡片进来时的落点框。**只是视图状态** —— 拖动过程中一个字都不
    /// 写 `TimelineState`（§0），模型只在松手那一下改一次。
    @State private var transitionDrop: TransitionDropPreview?
    /// 从滤镜库拖卡片进来时的落点。落点挂在**整块滚动内容**上而不是某一行 ——
    /// 滤镜落在哪一层由指针的纵向位置决定，得拿得到 y（见 VideoEditFilterDrag.swift）。
    @State private var filterDrop: FilterDropPlan?
    @State private var audioLibraryDrop: AudioLibraryDropPlan?
    /// 从 Finder 拖文件进来时的落点（落进哪条轨由指针的纵向位置决定），
    /// 见 VideoEditMediaFileDrop.swift。
    @State private var mediaFileDrop: MediaFileDropPlan?
    /// 滚动量的唯一真相：手势要用的时候从 `NSScrollView` **现读**。
    ///
    /// 以前这里是一个由 preference 喂的 `@State`，而那是**异步观察**来的数 ——
    /// 框选起手那一拍读到的可能还是上一次布局的值，框就整体画到指针左边、偏差
    /// 正好是当时的滚动量（docs/bugfixes/2026-09-18-marquee-anchored-at-stale-
    /// scroll-offset.md）。别再把它缓存回 `@State`。
    @State var scrollGeometry = TimelineScrollGeometry()
    /// 可见视口的尺寸（自动滚动要拿它判断指针到没到边）。
    @State var viewportWidth: Double = 0
    @State var viewportHeight: Double = 0
    /// 拖到边缘时推 NSScrollView 的心跳。
    @State var autoScroller = TimelineAutoScroller()

    /// 滚动视口的命名坐标系。四类块的移动手势和框选都钉在它上面，而它们分散在
    /// 上面列的那批文件里 —— 所以既不能是 private 也不能是 fileprivate。
    static let scrollSpace = "timelineScroll"

    /// 就地编辑浮层的落点：哪一条 cue、开在哪一行上。
    struct EditingCue: Equatable {
        var id: UUID
        var kind: SubtitleRowKind
    }

    var pps: Double { project.pixelsPerSecond }

    /// 内容总宽度：留出结尾空白，方便把素材拖到最后。
    ///
    /// 拖动中额外给一段**弹性尾部**：自由落点的轨道（上层轨/音频/磁吸关掉的主轨/
    /// 形状）允许把块拖到现有内容之外，内容宽度按投影落点临时长出去，还留半个
    /// 视口好继续拖；松手后由新的 `project.duration` 接管，没落地就自己缩回来。
    /// 磁吸主轨**不给** —— 它最终只能插进现有故事线的某条缝，扩太远只会把真正的
    /// 插入指示线滚出视野。
    var contentWidth: Double {
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
    struct RowSpec: Identifiable {
        var id: String
        var icon: String
        var height: Double
        var slot: TrackSlot?
        /// 这一行的行高存在哪（nil = 这一行的高度不可调）。键是轨道身份不是
        /// 行号，见 `TimelineRowHeights`。
        var heightKey: TimelineRowHeightKey?
        var isRuler = false
        var isShapes = false
        /// 文字行的层号（nil = 不是文字行）。重叠的文字自动多分一层，
        /// 层号由 `TextOverlayStacking` 算出来，不进模型。
        var textLevel: Int?
        /// 字幕行属于哪条字幕轨（nil = 不是字幕行）。一个语言一条轨。
        var subtitleKind: SubtitleRowKind?
        /// 滤镜行的层号（nil = 不是滤镜行）。**和文字行不同，层号进模型**
        ///（`FilterClip.layer`）—— LUT 不可交换，现算的层号会在拖动别的段时
        /// 重排，画面跟着变。
        var filterLayer: Int?
        /// 整轨隐藏中（灰显，不可编辑）。
        var isHidden = false

        /// 轨道头点一下要选中谁；nil = 这一行没有可选的东西（标尺）。
        /// 判据本体在 `TimelineRowSelection` —— 这里只做「行 → 身份」的翻译，
        /// 一条规则都不许在这儿写（空轨、隐藏轨那些边界都归它判）。
        var selectionRow: TimelineRowSelection.Row? {
            if isRuler { return nil }
            // 滤镜行的轨道头点不出选择：滤镜是单选的（`EditSelection.filterID`），
            // 「整行一起选」没地方放。点行头什么都不做，好过选中一批 ⌫ 删不掉的东西。
            if filterLayer != nil { return nil }
            if let slot { return .track(slot) }
            if let subtitleKind { return .subtitle(subtitleKind) }
            if let textLevel { return .textLevel(textLevel) }
            if isShapes { return .shapes }
            return nil
        }
    }

    private var rows: [RowSpec] {
        var result: [RowSpec] = [RowSpec(id: "ruler", icon: "", height: 26, slot: nil, isRuler: true)]
        // 滤镜行在**最顶上**：它作用于下面全部画面，不参与「行的上下顺序就是
        // 叠放次序」那套视频轨语义，混进去只会让人以为它是一条能放素材的轨。
        // 层号大的画在上面 —— 上面的后作用（docs/architecture/filters.md）。
        for layer in (0..<project.state.filterLayerCount).reversed() {
            result.append(RowSpec(
                id: "filter-\(layer)", icon: "camera.filters", height: 26, slot: nil,
                filterLayer: layer
            ))
        }
        // 上层视频轨：编号大的画在上面，行也放上面 —— 行的上下顺序就是叠放顺序。
        // 图标与主轨**同一个**：它们是对等的视频轨，区别只有叠放次序（行的位置
        // 已经表达了）和颜色。用 pip 图标会把「这是个小窗」的旧心智带回来。
        for index in project.state.overlayTracks.indices.reversed() {
            let row = trackRowHeight(.overlay(index))
            result.append(RowSpec(
                id: "overlay-\(project.state.overlayTracks[index].id)",
                icon: "film",
                height: row.height,
                slot: .overlay(index),
                heightKey: row.key,
                isHidden: project.state.overlayTracks[index].isHidden
            ))
        }
        // 文字行在形状行**上面**：行的上下顺序就是叠放顺序，而文字压在形状之上。
        for level in (0..<TextOverlayStacking.levelCount(for: project.state.textOverlays)).reversed() {
            result.append(RowSpec(
                id: "text-\(level)", icon: "textformat", height: 26, slot: nil, textLevel: level
            ))
        }
        if !project.state.shapes.isEmpty {
            result.append(RowSpec(id: "shapes", icon: "square.on.square.dashed", height: 26, slot: nil, isShapes: true))
        }
        let mainRow = trackRowHeight(.main)
        result.append(RowSpec(
            id: "main",
            icon: "film",
            height: mainRow.height,
            slot: .main,
            heightKey: mainRow.key,
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
            let row = trackRowHeight(.audio(index))
            result.append(RowSpec(
                id: "audio-\(project.state.audioTracks[index].id)",
                icon: "music.note",
                height: row.height,
                slot: .audio(index),
                heightKey: row.key,
                isHidden: project.state.audioTracks[index].isHidden
            ))
        }
        return result
    }

    /// 视频轨 / 音频轨这一行多高，以及它的行高存在哪个键上。
    /// **一轨一个值**：没单独调过的轨才回落到这一类的默认高度。
    private func trackRowHeight(_ slot: TrackSlot) -> (height: Double, key: TimelineRowHeightKey?) {
        let key = TimelineRowHeights.key(for: slot, in: project.state)
        return (project.rowHeight(for: key, kind: TrackRowKind(slot)), key)
    }

    /// 每行的纵向位置（垂直拖动找目标行用），和 VStack 的排布严格一致。
    struct RowLayout {
        var spec: RowSpec
        var minY: Double
        var midY: Double
        var maxY: Double
    }

    func rowLayouts() -> [RowLayout] {
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
            TimelineHeaderColumn(
                rows: rows,
                rowSpacing: rowSpacing,
                project: project,
                geometry: scrollGeometry,
                resizeBase: $headerResizeBase
            )
            Divider()
            GeometryReader { viewport in
                // **双向**滚动：轨道多到一屏放不下时要能上下滚（2026-09-18；
                // 在那之前只有横向，下面的轨道整条被裁掉、只能靠放大窗口看见）。
                // 轨道头列和标尺各自跟着 `scrollGeometry` 钉住，别的都跟着滚。
                ScrollView([.horizontal, .vertical], showsIndicators: true) {
                    // 两个尺寸约束（内容宽、至少填满视口）都写在 `scrolledContent`
                    // 里面，不在这儿：点击 / 悬停 / 框选的命中区必须盖在**填满视口
                    // 之后**的那一块上，而修饰符的顺序就是那个「之后」——
                    // 摆在这里的话，撑出来的空白永远在命中区外面（见那边的注释）。
                    scrolledContent
                }
                // 参照层铺满可见视口，标定「捏合该生效的区域」；事件本身
                // 由 TimelineMagnificationBridge 里的 local monitor 处理。
                .overlay(
                    TimelineMagnificationBridge(pixelsPerSecond: $project.pixelsPerSecond)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                )
                .coordinateSpace(name: Self.scrollSpace)
                .onChange(of: viewport.size.width, initial: true) { _, width in
                    viewportWidth = width
                }
                .onChange(of: viewport.size.height, initial: true) { _, height in
                    viewportHeight = height
                }
                .onChange(of: clock.time) { _, newTime in
                    followPlayhead(newTime)
                }
                // 视图消失（切栏目、关窗、切工程）时心跳必须跟着停 ——
                // 正常松手走 onEnded，这条管的是「手势没有终点」的那些死法。
                .onDisappear {
                    autoScroller.stop()
                    // 扫帧的 `.ended` 不保证会来（切栏目、关窗、模态挡在前面时
                    // 指针「离开」这件事根本不发事件，同 2026-08-23 那条教训）。
                    // 不收的话影子指针留在屏幕上、画面僵在那一帧。
                    clock.endPeek()
                    markerPeekTime = nil
                    clipDrag = nil
                    dragTargetRow = nil
                    marquee = nil
                    // 手势的「起手标记」也要一起清。留着的话，视图回来之后
                    // 再拖**同一条** cue，第一拍会因为 id 还相等而跳过
                    // beginCueDrag —— 整次拖动没有会话，等于白拖一回。
                    movingCueID = nil
                }
            }
        }
    }

    /// 时间线上**唯一**的拖放落点（理由见 VideoEditTimelineDropRouter.swift 的
    /// 文件头）。四套拖放各自的代理原样不动，由它按载荷分派；行布局只算一次，
    /// 四个代理共用同一份。
    private var timelineDropRouter: TimelineDropRouter {
        let layouts = rowLayouts()
        let viewport = CGSize(width: viewportWidth, height: viewportHeight)
        let main = layouts.first { $0.spec.slot == .main && !$0.spec.isHidden }
        return TimelineDropRouter(
            files: MediaFileDropDelegate(
                project: project,
                pps: pps,
                rowLayouts: layouts,
                geometry: scrollGeometry,
                autoScroller: autoScroller,
                viewport: viewport,
                preview: $mediaFileDrop
            ),
            filter: FilterDropDelegate(
                project: project,
                pps: pps,
                rowLayouts: layouts,
                geometry: scrollGeometry,
                autoScroller: autoScroller,
                viewport: viewport,
                preview: $filterDrop
            ),
            audio: AudioLibraryDropDelegate(
                project: project,
                pps: pps,
                rowLayouts: layouts,
                geometry: scrollGeometry,
                autoScroller: autoScroller,
                viewport: viewport,
                preview: $audioLibraryDrop
            ),
            transition: TransitionDropDelegate(
                project: project,
                pps: pps,
                geometry: scrollGeometry,
                autoScroller: autoScroller,
                viewport: viewport,
                preview: $transitionDrop
            ),
            mainRow: main.map { $0.minY...$0.maxY },
            contentWidth: contentWidth
        )
    }

    var rowSpacing: Double { 5 }

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
            // 所以跨轨对齐（上面上层轨的边缘对上下面主轨的边缘）一眼能看见。
            TimelineAlignmentGuides(
                times: clipDrag?.guides ?? filterDrop?.guides ?? audioLibraryDrop?.guides
                    ?? mediaFileDrop?.guides ?? [],
                pixelsPerSecond: pps
            )

            // 主轨磁吸开着时松手会插进的位置：和被拖素材**等长**的占位框，
            // 一眼看出这 6 秒会占到哪里（时刻和宽度由 TimelineSnap.mainInsertion
            // 算，落地同一个函数 —— 框指哪儿、有多长，落地就是哪儿、就那么长）。
            if let span = mainInsertionSpan,
               let layout = rowLayouts().first(where: { $0.spec.slot == .main }) {
                dropPlaceholder(span: span, y: layout.minY, height: layout.spec.height)
            }

            // 跨轨拖动：目标行上画出松手后的真实落点（等长占位框，位置与
            // relocateClip 共用同一份挤开算法 —— 框不说谎）。
            if let ghost = crossTrackGhost {
                dropPlaceholder(span: ghost.span, y: ghost.y, height: ghost.height)
            }

            // 拖音频库素材进来时的落点框。**复用剪辑拖动那个虚线框** ——
            // 落下去就是一个普通的音频块，没道理让用户学第二种落点语言。
            if let audioLibraryDrop {
                dropPlaceholder(
                    span: TimelineSpan(start: audioLibraryDrop.start,
                                       end: audioLibraryDrop.end),
                    y: audioLibraryDrop.rowY,
                    height: audioLibraryDrop.rowHeight
                )
            }

            // 从 Finder 拖文件进来时的落点（画在 VideoEditMediaFileDrop.swift 里，
            // 同 FilterDropIndicator 的分工：框跟着它的代理走）。
            if let mediaFileDrop {
                MediaFileDropIndicator(plan: mediaFileDrop, pps: pps, fullWidth: contentWidth)
            }

            // 拖滤镜卡片进来时的落点框。和滤镜块同一套几何（同一份
            // FilterBlockMetrics），所以松手之后块在哪儿、框就在哪儿。
            if let filterDrop {
                FilterDropIndicator(
                    plan: filterDrop,
                    pps: pps,
                    // 这一层还没有行：新行会长在标尺底下那一条的位置。
                    fallbackY: rowLayouts().first { !$0.spec.isRuler }?.minY ?? 2
                )
            }

            // 滚动量的现读与自动滚动都要直接摸 NSScrollView，放个零尺寸参照物
            // 把它认出来。
            TimelineScrollViewAccessor(geometry: scrollGeometry, scroller: autoScroller)
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
        // 内容区这一层：宽度就是 `contentWidth`，轨道底色和标尺刻度都画到这儿为止。
        .frame(width: contentWidth, alignment: .topLeading)
        .contentShape(Rectangle())
        // 至少填满视口、左上角对齐。**两轴都要**：内容比视口小时 SwiftUI 的
        // ScrollView 会把它居中（实测 800 宽的视口放 200 宽的内容，内容
        // minX = 300），于是：
        // - 纵向（轨道少，这是常态）：播放头那条线只画在中间那一段，上面接不到
        //   标尺 —— 用户看见的就是「指针是断的」；而标尺靠 `.offset` 被拉回视口
        //   顶上之后，它的**命中区没跟过去**，点标尺 seek 不了。
        // - 横向（工程短、窗口宽，同样是常态）：整条时间线连标尺带轨道一起飘到
        //   视口中间，看着就是「刚加进来的素材没贴左边」；更要命的是框选的
        //   `内容 x = 视口 x + offsetX` 这个前提被打破，框会整体画到指针右边
        //   (视口宽 - 内容宽)/2 那么远。
        // 全是同一个根：内容不该被居中。
        .frame(minWidth: viewportWidth, minHeight: viewportHeight, alignment: .topLeading)
        // 点击 / 框选的命中区盖的是**填满视口之后**的这一整块，所以必须挂在上面
        // 那个 frame 后面。挂在它前面（2026-09-21 之前就是那样）的话，命中区只有
        // `contentWidth` 宽 —— 工程短的时候那是 600pt 的地板，窗口一宽，右边小半
        // 个视口是**彻底的死区**：点了不移播放头、不清选择，框也拉不起来。
        .contentShape(Rectangle())
        // 拖放：**整条时间线只有这一个落点**。从 Finder 拖进来的文件、滤镜 / 音频库 /
        // 转场三种卡片全在这儿按载荷分派（`TimelineDropRouter`）。别在行上、块上、
        // 或者这条链的别处再挂 `.onDrop`：SwiftUI 把拖放交给指针底下最里面那个
        // 落点，类型对不上也不往外找（空类型的 `.onDrop(of: [])` 也一样独占），
        // 多挂一个就会把别人的拖入吞掉（2026-09-23 探针实测，案例见路由器文件头）。
        //
        // 挂在「填满视口」之后，所以右边 / 下边撑出来的空白也接得住文件；滤镜只许
        // 落在内容区以内这条老规矩由路由器按 `contentWidth` 判。
        .onDrop(of: TimelineDropRouter.types, delegate: timelineDropRouter)
        // 点非素材处：播放头挪过来，并且三类选择一起取消（含字幕 cue —— 漏了它，
        // 拖框会在没有任何选中项的界面上继续挂着）。
        //
        // 「非素材处」不用自己判：块本体、标尺、裁切把手、标记帽子各有自己的手势，
        // SwiftUI 里子视图的手势优先，所以能落到这儿的**只有**谁都不认领的空白。
        .onTapGesture(coordinateSpace: .local) { location in
            project.clearSelection()
            seekFromTimeline(time: location.x / pps, precise: true)
        }
        // 空白处按下拖动 = 拉框选。挂在容器上而不是各行上：SwiftUI 里子视图的
        // 手势优先，所以块本体的移动手势、标尺的 scrub 都照旧归它们自己，只有
        // 谁都不认领的空白才落到这里。刀片模式下整条停掉（`.subviews` 保留
        // 子视图的点击），不然本该落下的那一刀会被 4pt 的手抖吃成一次框选。
        //
        // 和上面那一下点击分得开：这条起手要 4pt，点击是零位移，一次鼠标操作
        // 只会走其中一条。
        .gesture(marqueeGesture, including: project.activeTool == .split ? .subviews : .all)
        // 扫帧预览（peek）：整条时间线**只有这一个入口**，理由见 hoverPeek。
        .onContinuousHover(coordinateSpace: .local, perform: hoverPeek)
    }

    @ViewBuilder
    private func rowView(_ row: RowSpec) -> some View {
        if row.isRuler {
            // 标尺钉在视口顶上：纵向滚动时它不跟着走。
            TimelinePinnedRuler(
                pps: pps,
                duration: project.duration,
                frameRate: project.state.frameRate,
                rowSpacing: rowSpacing,
                playheadX: clock.time * pps,
                geometry: scrollGeometry,
                onSeek: { time, precise in
                    seekFromTimeline(time: time, precise: precise)
                }
            )
        } else if let layer = row.filterLayer {
            filterRow(layer: layer)
        } else if row.isShapes {
            shapesRow
        } else if let level = row.textLevel {
            textRow(level: level)
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
                    onDragChange: { translation, pointerViewport in
                        updateClipDrag(translation: translation, pointerViewport: pointerViewport)
                    },
                    onDragEnd: { endClipDrag() },
                    onTrim: { leading, delta in
                        project.liveTrim(clip.id, leading: leading, deltaSeconds: delta)
                    },
                    onTrimEnd: {
                        project.endLiveEdit()
                    },
                    onMarkerPeek: { markerPeek($0) }
                )
            }
            // 隐藏的轨：灰显、去色、点不动。
            .opacity(hidden ? 0.35 : 1)
            .saturation(hidden ? 0 : 1)
            .allowsHitTesting(!hidden)

            // 接缝上的转场遮罩。只有主轨有 —— 转场只对主轨有语义。
            // 轨藏起来时不画：那条轨本来就不渲染，遮罩摆在那儿只会挡住点击。
            if slot.isMain, !hidden {
                ForEach(seamIndicesWithTransition, id: \.self) { index in
                    TransitionMaskView(
                        project: project,
                        seamIndex: index,
                        rowHeight: height,
                        pps: pps
                    )
                }
                // 从库里拖卡片进来时的落点框。和遮罩同一套几何，所以松手之后
                // 框在哪儿遮罩就在哪儿。
                if let preview = transitionDrop {
                    TransitionDropIndicator(preview: preview, rowHeight: height)
                }
            }
        }
        // 这一行**不挂** `.onDrop`：转场卡片的落点在滚动内容上那个唯一的路由器里，
        // 按主轨这一行的纵向范围判（`TimelineDropRouter.mainRow`）。以前挂在每条
        // 轨道行上（非主轨传空类型），空类型的落点照样独占拖入 —— 滤镜 / 音频库
        // 卡片、Finder 的文件拖到轨道行上那一下全被它吞掉。
    }

    /// 主轨上有转场遮罩可画的那几条缝。
    private var seamIndicesWithTransition: [Int] {
        let clips = project.state.mainClips
        guard clips.count >= 2 else { return [] }
        return (0..<(clips.count - 1)).filter {
            project.state.transitionWindow(afterMainIndex: $0) != nil
        }
    }

    // MARK: - 播放头

    /// 时间线上所有「把播放头挪过去」的落点：标尺的点 / 拖，和空白处的点击。
    ///
    /// **夹紧只能有这一处。** 两个调用点各写一份 `min(max(0, t), duration)` 迟早
    /// 会分叉：标尺夹到片尾、点空白不夹的话，点右边那一大片空白就会把播放头送到
    /// 工程之外 —— 那里根本没有帧，画面停在最后一帧，而播放头却在几十秒开外，
    /// 工具栏上所有「播放头得落在片段内」才可用的按钮（分割、冻结、标记、删左、
    /// 删右）随即全部变灰。
    func seekFromTimeline(time: Double, precise: Bool) {
        clock.seek(to: min(max(0, time), project.duration), precise: precise)
    }

    /// 鼠标扫过时间线**任何地方**，画面就滚到指的那一帧看一眼（peek）：真播放头
    /// 原地不动，时间线上另画一根影子指针，指针离开时间线就把画面滚回播放头。
    ///
    /// **整条时间线只有这一个扫帧入口**（2026-09-21 用户拍板）。在那之前它挂在
    /// 剪辑块自己身上，于是只有视频块本体能预览 —— 标尺、轨道空白、音频轨、块
    /// 以外的空白全都没有。挪到容器上之后，块那圈 `.onContinuousHover` 必须
    /// **删掉**：两圈都在、都写 peek 的话，谁后到谁赢，那是竞态，不是行为。
    ///
    /// `.local` 坐标以内容原点为零点，所以 `point.x / pps` 直接就是时刻，不用补
    /// 滚动量（和框选的分别见 docs/architecture/timeline-drag-gestures.md §5e）。
    func hoverPeek(_ phase: HoverPhase) {
        switch phase {
        case .active(let point):
            // 播放中、拖块、拖框、裁切（`liveEditOrigin`：连续修改的快照还挂着）
            // 都不扫帧。裁切那条只能从 project 上判 —— `isTrimming` 是块内的
            // @State，容器看不见。
            guard !clock.isPlaying, clipDrag == nil, marquee == nil,
                  project.liveEditOrigin == nil else { return }
            // 标记正接管着 peek，别把画面从标记那一帧拽回指针底下。
            guard markerPeekTime == nil else { return }
            // 和点击同一份夹紧：超出工程长度的那片空白里，影子指针停在片尾，画面
            // 也就是最后一帧 —— 影子指着哪儿、画面就是哪儿，不会各说各话。
            let time = min(max(0, point.x / pps), project.duration)
            // 时刻没变就不写。`peekTime` 是 @Published，每写一次连带整条时间线
            // 视图树重算，而纵向移动、亚像素抖动算出来都是同一刻 —— 现在鼠标扫过
            // 时间线**任何地方**都会走到这里，这道门槛不是省几次重绘的事。
            guard abs(time - (clock.peekTime ?? -1)) * pps > 0.5 else { return }
            clock.peek(at: time)
        case .ended:
            // 指针是「进了块上的标记」而不是「离开了时间线」，peek 该留给标记。
            guard markerPeekTime == nil else { return }
            clock.endPeek()
        }
    }

    /// 指针进出标记帽子时，peek 的交接。
    ///
    /// 标记的帽子是可命中的子视图，但 `.onContinuousHover` 不会因为指针压在子视图
    /// 上就停发 —— 所以这里不是「接住块让出来的 peek」，而是**把容器顶掉**：
    /// 悬着标记期间 `hoverPeek` 自己让位，画面钉在标记那一帧（帽子有 hitWidth，
    /// 指针在帽子里挪几个点不该让画面跟着漂）。
    ///
    /// 离开标记时**照常** endPeek：指针要是还在时间线上，下一次鼠标移动会立刻把
    /// 扫帧接回去；指针要是已经走了，画面也不会僵在标记那一帧。
    func markerPeek(_ time: Double?) {
        markerPeekTime = time
        guard !clock.isPlaying, clipDrag == nil, marquee == nil,
              project.liveEditOrigin == nil else { return }
        if let time {
            clock.peek(at: time)
        } else {
            clock.endPeek()
        }
    }

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

    /// 播放头的**竖线**。它贯穿所有轨道，所以跟着内容一起纵向滚。
    ///
    /// 标尺上那枚把手不在这儿 —— 它画在 `TimelinePinnedRuler` 里，跟着标尺一起
    /// 钉在视口顶上。画在这里的话，纵向滚下去之后把手会藏到标尺后面（标尺是不
    /// 透明的），用户就看不见播放头的抓手了。
    private var playhead: some View {
        Rectangle()
            .fill(.white)
            .frame(width: 1.5)
            .shadow(radius: 0.5)
            .frame(maxHeight: .infinity, alignment: .top)
            .offset(x: clock.time * pps - 0.75)
            .allowsHitTesting(false)
    }

    /// 播放时让播放头留在视野里：只有它快滚出去了才动一下，
    /// 平时不跟着走 —— 每帧都居中会看得人晕。
    ///
    /// **只碰横向。** 以前走 `ScrollViewProxy.scrollTo(_:anchor:)`，那个锚点是
    /// 双轴的：时间线能上下滚之后（2026-09-18），正在看下面几条轨时一按播放，
    /// 画面会被连带拽回最顶上。
    private func followPlayhead(_ time: Double) {
        guard clock.isPlaying, viewportWidth > 80 else { return }
        guard abs(time - lastFollowTime) > 0.15 else { return }
        lastFollowTime = time

        let x = time * pps
        let offset = scrollGeometry.offsetX
        let leftEdge = offset + 40
        let rightEdge = offset + viewportWidth - 80
        guard x < leftEdge || x > rightEdge else { return }
        // 挪到视野偏左的位置，后面还留着一大段能看。
        scrollGeometry.scrollHorizontally(to: x - viewportWidth * 0.15, animated: true)
    }
}
