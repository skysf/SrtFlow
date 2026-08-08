import AppKit
import SwiftUI
import SrtFlowCore

/// 视频编辑：上面是预览 + 检查器，下面是工具栏 + 时间线。
struct VideoEditView: View {
    @ObservedObject private var project = VideoEditProject.shared
    @ObservedObject private var exporter = VideoEditExporter.shared
    @StateObject private var toolchain = MediaToolchain.shared
    // 字幕轨的样式沿用「烧制字幕」页调好的那套。
    @ObservedObject private var burnInQueue = EncodeQueue.burnIn
    @ObservedObject private var languageStore = AppLanguageStore.shared
    @ObservedObject private var clock: PlayerClock

    @Environment(\.undoManager) private var undoManager
    @State private var showsExportSheet = false
    @State private var showsSubtitlePanel = false
    @ObservedObject private var recordingCoordinator = ScreenRecordingCoordinator.shared
    /// 空格/V 快捷键的事件监听。捏合缩放由时间线里 TimelineMagnificationBridge
    /// 的 local monitor 处理，不在这里。
    @State private var eventMonitor: Any?
    /// 当前字幕文本块的实测高度（overlay 回报，字幕拖框定框用）。
    @State private var subtitleBlockHeight: Double = 0

    init() {
        clock = VideoEditProject.shared.clock
    }

    var body: some View {
        VSplitView {
            HSplitView {
                previewPane
                    .frame(minWidth: 430, idealWidth: 700, maxWidth: .infinity)
                    .layoutPriority(1)
                VideoEditInspectorView(project: project, clock: clock, onExport: { showsExportSheet = true })
                    .frame(minWidth: 252, idealWidth: 290, maxWidth: 360)
            }
            .frame(minHeight: 300, idealHeight: 400, maxHeight: .infinity)

            timelinePane
                .frame(minHeight: 210, idealHeight: 260, maxHeight: .infinity)
        }
        .frame(minWidth: 900, minHeight: 580)
        .onAppear {
            toolchain.resolveIfNeeded()
            project.undoManager = undoManager
            installEventMonitor()
            // GUI 冒烟测试的导入钩子：环境变量不设就完全不生效。
            // 可以用 : 分隔多个路径（PATH 惯例），addMedia 按类型分流 —— 想验
            // 字幕相关的界面就再挂一个 .srt，否则拿不到「有字幕」的状态。
            if let smoke = ProcessInfo.processInfo.environment["SRTFLOW_SMOKE_VIDEO"],
               !smoke.isEmpty, project.state.isEmpty {
                let urls = smoke.split(separator: ":")
                    .map { URL(fileURLWithPath: String($0)) }
                project.addMedia(urls: urls)
            }
        }
        .onDisappear {
            if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
            eventMonitor = nil
            // 切去别的栏目时把挂着的自动保存写下去，别留在内存里等。
            project.flushAutosave()
        }
        .onDropOfFiles { urls in project.addMedia(urls: urls) }
        .onDeleteCommand { project.deleteSelected() }
        .sheet(isPresented: $showsExportSheet) {
            VideoEditExportSheet(project: project, exporter: exporter)
        }
        .sheet(isPresented: $showsSubtitlePanel) {
            SubtitleGenPanel(project: project)
        }
        // 录制设置页 = `state == .configuring` 的投影。会话一旦被撤销
        // （Quit、失败、取消），页自己就关了。
        .sheet(isPresented: Binding(
            get: { recordingCoordinator.state == .configuring },
            set: { if !$0 { recordingCoordinator.cancelConfiguring() } }
        )) {
            ScreenRecordingSetupView(project: project)
        }
        // partial 结果：**工程锁还在**，用户必须先处置（计划 §11.4）。
        .sheet(item: Binding(
            get: { recordingCoordinator.pendingPartial.map(IdentifiedRecording.init) },
            set: { _ in }
        )) { item in
            ScreenRecordingPartialSheet(result: item.result) { shouldImport in
                Task { await recordingCoordinator.resolvePartial(import: shouldImport) }
            }
        }
        // 崩溃恢复：启动时发现上次的残留。三选一，「保留」绝不删文件。
        .sheet(item: Binding(
            get: { recordingCoordinator.pendingRecovery },
            set: { _ in }
        )) { recovery in
            ScreenRecordingRecoverySheet(recovery: recovery) { decision in
                Task { await recordingCoordinator.resolveRecovery(decision) }
            }
        }
        .task {
            // 启动恢复：只处理 manifest 点名的精确路径，禁止 glob。
            await recordingCoordinator.recoverIfNeeded()
        }
        // Export 放窗口右上角的工具栏，随时够得着。
        .toolbar {
            // 工程名下拉放最左边，它就是这个编辑器的文件菜单。
            ToolbarItem(placement: .navigation) {
                VideoEditProjectMenu(project: project)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if exporter.isExporting {
                    ProgressView(value: exporter.progress)
                        .frame(width: 80)
                }
                if #available(macOS 15.0, *) {
                    Button {
                        // 设置页的显隐**完全由 coordinator 状态决定**（见下面的
                        // sheet 绑定），这里只推状态，不另外拿一个本地开关 ——
                        // 两份真相会让「会话被撤销但页还开着」这种状态存在。
                        recordingCoordinator.begin()
                    } label: {
                        Label("Record Screen", systemImage: "record.circle")
                    }
                    .help("Record the screen into this project")
                    .disabled(recordingCoordinator.isBusy)
                }
                Button {
                    showsSubtitlePanel = true
                } label: {
                    Label("Subtitles", systemImage: "captions.bubble")
                }
                .disabled(project.state.isEmpty)
                .help("Generate, translate, and edit subtitle tracks")
                Button {
                    showsExportSheet = true
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(project.state.isEmpty || exporter.isExporting)
                .help("Export the timeline or the selected clips")
            }
        }
    }

    // MARK: - 键盘

    /// 空格播放/暂停；V 切换所在轨的隐藏；A/B 切换选择/分割工具。
    /// 这个视图只在「视频剪辑」栏可见时存在，监听不会漏到别的页面。
    private func installEventMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { handleEvent(event) }
        }
    }

    private func handleEvent(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .keyDown:
            // 正在打字（哪怕是别的输入框）就别抢按键。
            if NSApp.keyWindow?.firstResponder is NSTextView { return event }
            guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else {
                return event
            }
            // ⌫ / fn⌫：删掉选中的剪辑或形状，和工具栏 trash 按钮同一个动作。
            // 按 keyCode 认（51 = delete，117 = forward delete）——
            // charactersIgnoringModifiers 那边是控制字符，走字符串会一团糟。
            if event.keyCode == 51 || event.keyCode == 117 {
                guard !project.selectedClipIDs.isEmpty || project.selectedShapeID != nil else {
                    return event
                }
                project.deleteSelected()
                return nil
            }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case " ":
                if !project.state.isEmpty { clock.togglePlayback() }
                return nil
            case "v":
                project.toggleHiddenForSelectionLane()
                return nil
            case "a":
                project.activeTool = .select
                return nil
            case "b":
                project.activeTool = .split
                return nil
            default:
                return event
            }
        default:
            return event
        }
    }

    // MARK: - 预览

    private var previewPane: some View {
        VStack(spacing: 0) {
            if !project.missingMedia.isEmpty {
                MissingMediaBar(project: project)
                Divider()
            }
            if showsStartScreen {
                VideoEditStartScreen(project: project)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                videoBox
            }
            Divider()
            transport
        }
    }

    /// 空的未命名工程给起始页（拖放提示 + 最近工程），比一整块黑屏有用。
    /// 打开过的工程哪怕是空的也照常显示预览区 —— 那是「这条工程本来就空」。
    private var showsStartScreen: Bool {
        project.state.isEmpty && project.isUntitled && project.importingCount == 0
    }

    private var aspect: Double {
        let size = project.renderSize
        guard size.height > 0 else { return 16.0 / 9.0 }
        return size.width / size.height
    }

    private var videoBox: some View {
        GeometryReader { proxy in
            let size = fitted(in: proxy.size)
            ZStack {
                Color.black
                if !project.state.isEmpty {
                    PlayerViewRepresentable(player: clock.player, controlsStyle: .none)
                    // 点选画面内容 + 变换框。放在形状叠层下面：形状的点击优先。
                    ClipTransformCanvas(project: project, clock: clock, boxSize: size)
                } else {
                    Text("Add clips to start editing.")
                        .foregroundStyle(.secondary)
                }
                ShapeOverlayCanvas(project: project, boxSize: size)
                if let text = currentSubtitleText {
                    BurnInSubtitleOverlay(
                        text: text,
                        style: burnInQueue.burnInStyle,
                        scale: size.height / Double(BurnInStyle.referenceHeight),
                        boxSize: size,
                        layout: project.state.subtitleLayout,
                        onBlockSize: { subtitleBlockHeight = $0.height }
                    )
                    // 轨道上点选了 cue：叠出工程级字幕拖框（移动/换行宽度/
                    // 等比字号）。放最上层 —— 有选中时字幕调整优先。
                    if let cueID = project.selectedSubtitleCueID,
                       project.state.subtitle?.cues.contains(where: { $0.id == cueID }) == true {
                        SubtitleFrameCanvas(
                            project: project,
                            boxSize: size,
                            style: burnInQueue.burnInStyle,
                            blockHeight: subtitleBlockHeight
                        )
                    }
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(minHeight: 220)
        .padding(10)
    }

    private func fitted(in available: CGSize) -> CGSize {
        guard available.width > 1, available.height > 1 else { return CGSize(width: 1, height: 1) }
        var width = available.width
        var height = width / aspect
        if height > available.height {
            height = available.height
            width = height * aspect
        }
        return CGSize(width: width, height: height)
    }

    /// 播放头此刻的字幕文本（字幕轨直接按时间线时间对齐）。
    /// 多条重叠 cue 全部显示，顺序走第 9 节合同（与烧录共用同一排序实现）；
    /// 轨道选择（原文/译文/双语）跟随 project.subtitlePreviewTrack。
    private var currentSubtitleText: String? {
        // 选中的轨道可能已经不在了（译文被删、或工程重开时 subtitlePreviewTrack
        // 还留着旧值），这时 subtitleDocument(for:) 返回 nil。直接跟着返回 nil 会让
        // 预览字幕无声无息地整个消失 —— 回退到原文轨，宁可显示原文也不要空白。
        // visible 变体：字幕轨隐藏（眼睛）时预览一律不画（与烧录同一份合同）。
        guard let doc = project.state.visibleSubtitleDocument(for: project.subtitlePreviewTrack)
            ?? project.state.visibleSubtitleDocument(for: .original) else {
            return nil
        }
        // displayTime：悬停预览时字幕要和画面显示的那一帧对上，而不是播放头。
        let active = SubtitleOverlap.active(at: clock.displayTime, in: doc.cues)
        guard !active.isEmpty else { return nil }
        // doc.cues 已按合同排序，active 保序。overlay 文本块底部对齐，
        // 而 libass 把最早的事件排在最底、后来的往上叠 —— 所以显示时要
        // 倒序拼行（合同序的第一条落在最后一行 = 画面最底），预览和
        // 烧录的堆叠方向才一致。
        let text = active.reversed().map { SubtitleSerializer.plainText($0.text) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    private var transport: some View {
        HStack(spacing: 10) {
            Button {
                clock.togglePlayback()
            } label: {
                Image(systemName: clock.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 14)
            }
            .buttonStyle(.borderless)
            .disabled(project.state.isEmpty)
            .help(clock.isPlaying ? LocalizedStringKey("Pause") : LocalizedStringKey("Play (Space)"))

            Text("\(clockLabel(clock.time)) / \(clockLabel(project.duration))")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)

            // 画布比例：16:9、9:16 …… auto 跟随第一段素材。
            Menu {
                ForEach(CanvasRatio.allCases) { ratio in
                    Button {
                        project.setCanvasRatio(ratio)
                    } label: {
                        if project.state.canvasRatio == ratio {
                            Label(LocalizedStringKey(ratio.title), systemImage: "checkmark")
                        } else {
                            Text(LocalizedStringKey(ratio.title))
                        }
                    }
                }
            } label: {
                Label(
                    project.state.canvasRatio == .auto
                        ? "\(Int(project.renderSize.width))×\(Int(project.renderSize.height))"
                        : project.state.canvasRatio.title,
                    systemImage: "aspectratio"
                )
                .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Canvas aspect ratio")

            // 工程帧率：预览、导出、预渲染、关键帧容差全都跟它走。
            Menu {
                ForEach(ProjectFrameRate.allCases) { rate in
                    Button {
                        project.setFrameRate(rate)
                    } label: {
                        if project.state.frameRate == rate {
                            Label(rate.title, systemImage: "checkmark")
                        } else {
                            Text(rate.title)
                        }
                    }
                }
            } label: {
                Label(project.state.frameRate.title, systemImage: "speedometer")
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(recordingCoordinator.isBusy)
            .help("Project frame rate — preview, export and keyframes all follow it")

            if project.isRebuildingPreview {
                ProgressView().controlSize(.mini)
            }

            if project.importingCount > 0 {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text("Adding…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if let notice = project.notice {
                // **不要 lineLimit(1) + 截断。** 权限指引这类文案被切成半句
                // （「SrtFlow doesn't have permi...on, turn it off and on again.」）
                // 等于没报 —— 用户看不到该去哪、该做什么。给两行并允许换行。
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420, alignment: .leading)
                    .help(notice)
                Button {
                    project.notice = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }

            if exporter.isExporting {
                Button {
                    exporter.cancel()
                } label: {
                    Image(systemName: "stop.circle")
                }
                .buttonStyle(.borderless)
                .help("Stop")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func clockLabel(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00.0" }
        let tenth = Int((seconds * 10).rounded())
        return String(format: "%d:%02d.%d", tenth / 600, (tenth / 10) % 60, tenth % 10)
    }

    // MARK: - 时间线 + 工具栏

    private var timelinePane: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            VideoEditTimelineView(project: project, clock: clock)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            addMenu
            toolMenu

            Divider().frame(height: 16)

            ToolbarIcon(icon: "arrow.uturn.backward", help: "Undo") {
                undoManager?.undo()
            }
            .disabled(!(undoManager?.canUndo ?? false))
            ToolbarIcon(icon: "arrow.uturn.forward", help: "Redo") {
                undoManager?.redo()
            }
            .disabled(!(undoManager?.canRedo ?? false))

            Divider().frame(height: 16)

            ToolbarIcon(icon: "scissors", help: "Split at playhead (⌘B)") {
                project.splitAtPlayhead()
            }
            .keyboardShortcut("b", modifiers: [.command])
            .disabled(!canSplit)
            ToolbarIcon(icon: "snowflake", help: "Freeze the frame at the playhead (⇧⌘F)") {
                project.freezeFrameAtPlayhead()
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(!project.canFreezeFrame)
            ToolbarIcon(icon: "delete.left", help: "Delete everything left of the playhead in this clip") {
                project.trimToPlayhead(keepRight: true)
            }
            .disabled(!canSplit)
            ToolbarIcon(icon: "delete.right", help: "Delete everything right of the playhead in this clip") {
                project.trimToPlayhead(keepRight: false)
            }
            .disabled(!canSplit)
            ToolbarIcon(icon: "trash", help: "Delete the selection") {
                project.deleteSelected()
            }
            .disabled(project.selectedClipIDs.isEmpty && project.selectedShapeID == nil)
            ToolbarIcon(icon: "waveform.badge.minus", help: "Detach the audio onto its own track") {
                if let id = project.selectedClip?.id { project.detachAudio(from: id) }
            }
            .disabled(!canDetach)

            Spacer()

            ToolbarToggle(icon: "arrow.right.and.line.vertical.and.arrow.left", help: "Main track magnet (auto close gaps)", isOn: $project.magnetEnabled)
            ToolbarToggle(icon: "arrow.down.to.line.compact", help: "Auto snapping while dragging", isOn: $project.snappingEnabled)
            ToolbarToggle(icon: "link", help: "Linkage: detached audio moves with its video", isOn: $project.linkageEnabled)

            Divider().frame(height: 16)

            ToolbarIcon(icon: "minus.magnifyingglass", help: "Zoom out") {
                project.pixelsPerSecond = max(4, project.pixelsPerSecond / 1.4)
            }
            Slider(value: $project.pixelsPerSecond, in: 4...120)
                .frame(width: 84)
                .controlSize(.mini)
            ToolbarIcon(icon: "plus.magnifyingglass", help: "Zoom in") {
                project.pixelsPerSecond = min(120, project.pixelsPerSecond * 1.4)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var addMenu: some View {
        Menu {
            Button("Add Media…") { pickMedia(toOverlay: false) }
            Button("Add Picture-in-Picture…") { pickMedia(toOverlay: true) }
                .disabled(project.state.mainClips.isEmpty)
            Button("Add Subtitle File…") { pickSubtitle() }
            Divider()
            ForEach(ShapeKind.allCases) { kind in
                Button {
                    project.addShape(kind)
                } label: {
                    Label(LocalizedStringKey(kind.title), systemImage: kind.icon)
                }
            }
        } label: {
            Label("Add", systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()

    }

    /// 鼠标工具下拉：选择（A）/ 分割（B）。快捷键走本视图的事件监听，
    /// 不挂 keyboardShortcut —— 无修饰键的键盘等价符会抢文本框的输入。
    private var toolMenu: some View {
        Menu {
            ForEach(TimelineTool.allCases) { tool in
                Button {
                    project.activeTool = tool
                } label: {
                    if project.activeTool == tool {
                        Label("\(L10n(tool.title)) (\(tool.shortcutLabel))", systemImage: "checkmark")
                    } else {
                        Label("\(L10n(tool.title)) (\(tool.shortcutLabel))", systemImage: tool.icon)
                    }
                }
            }
        } label: {
            Image(systemName: project.activeTool.icon)
                .frame(width: 20, height: 18)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Mouse tool: Select (A) or Split (B)")
    }

    private var canSplit: Bool {
        let time = clock.time
        if project.selectedClipIDs.contains(where: { project.state.clip(with: $0)?.contains(time: time) == true }) {
            return true
        }
        return project.mainClipAtPlayhead() != nil
    }

    private var canDetach: Bool {
        guard let clip = project.selectedClip else { return false }
        return !clip.isAudioOnly && clip.hasAudio && !clip.isMuted
    }

    private func pickMedia(toOverlay: Bool) {
        var types = MediaFileTypes.video
        types.append(contentsOf: [.image, .png, .jpeg, .audio, .mp3, .mpeg4Audio, .wav])
        if !toOverlay {
            types.append(contentsOf: SubtitleFileTypes.readable)
        }
        let urls = FilePicker.chooseFiles(types: types)
        guard !urls.isEmpty else { return }
        project.addMedia(urls: urls, videosToOverlay: toOverlay)
    }

    private func pickSubtitle() {
        let urls = FilePicker.chooseFiles(types: SubtitleFileTypes.readable, allowsMultiple: false)
        guard let url = urls.first else { return }
        project.attachSubtitle(url)
    }
}

// MARK: - 工具栏的小件

private struct ToolbarIcon: View {
    let icon: String
    let help: LocalizedStringKey
    let action: () -> Void

    init(icon: String, help: LocalizedStringKey, action: @escaping () -> Void) {
        self.icon = icon
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .frame(width: 20, height: 18)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

private struct ToolbarToggle: View {
    let icon: String
    let help: LocalizedStringKey
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Image(systemName: icon)
                .frame(width: 20, height: 18)
        }
        .toggleStyle(.button)
        .buttonStyle(.borderless)
        .tint(.teal)
        .help(help)
    }
}

// MARK: - 形状叠层

/// 画面上的形状：按归一化坐标画在预览框里，选中可拖动。
private struct ShapeOverlayCanvas: View {
    @ObservedObject var project: VideoEditProject
    let boxSize: CGSize

    /// 拖动开始时的中心（归一化），增量都相对它算。
    @State private var dragOrigin: CGPoint?
    /// 中心参考线的亮灭（竖线, 横线）。
    @State private var centerGuides = (vertical: false, horizontal: false)

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            // displayTime：悬停预览时形状的出没要跟画面那一帧走。
            ForEach(project.visibleShapes(at: project.clock.displayTime)) { shape in
                shapeView(shape)
            }
            // 选中形状的变换框：线条只给左右（改长度），正方形只给四角（保形），
            // 长方形全套八个。移动仍走形状本体的拖动手势，框体不拦事件。
            if let shape = project.selectedShape, shape.contains(time: project.clock.displayTime) {
                ResizableFrameBox(
                    rect: resizeBoxRect(shape),
                    bounds: boxSize,
                    handles: resizeHandles(shape),
                    keepAspectOnCorners: true,
                    movable: false,
                    onCenterGuides: { centerGuides = (vertical: $0, horizontal: $1) },
                    onChange: { newRect in applyShapeResize(shape, newRect) },
                    onEnd: { project.endLiveEdit(rebuildsPreview: false) }
                )
            }

            CenterGuideLines(
                canvas: boxSize,
                showVertical: centerGuides.vertical,
                showHorizontal: centerGuides.horizontal
            )
        }
        .frame(width: boxSize.width, height: boxSize.height)
    }

    /// 框比形状本体略大一圈。线条按**旋转后的包络**画框（绘制带
    /// rotationEffect，`frame(in:)` 不带），细的方向撑到能看见。
    private func resizeBoxRect(_ shape: ShapeAnnotation) -> CGRect {
        var frame = shape.frame(in: boxSize)
        if shape.kind == .line {
            let angle = shape.rotationDegrees * .pi / 180
            let w = abs(frame.width * cos(angle))
            let h = abs(frame.width * sin(angle))
            frame = CGRect(x: frame.midX - w / 2, y: frame.midY - h / 2, width: w, height: h)
        }
        frame = frame.insetBy(dx: -4, dy: -4)
        if shape.kind == .line {
            let minSide = 14.0
            if frame.height < minSide {
                frame = frame.insetBy(dx: 0, dy: -(minSide - frame.height) / 2)
            }
            if frame.width < minSide {
                frame = frame.insetBy(dx: -(minSide - frame.width) / 2, dy: 0)
            }
        }
        return frame
    }

    private func resizeHandles(_ shape: ShapeAnnotation) -> Set<FrameHandle> {
        switch shape.kind {
        case .line:
            // 转过角度的线，左右把手方向就不对了：只留框做选中指示，
            // 长度在检查器里调。没转的照旧左右改长度。
            let rotated = abs(shape.rotationDegrees.truncatingRemainder(dividingBy: 360)) > 0.5
            return rotated ? [] : FrameHandle.horizontal
        case .square: return FrameHandle.corners
        case .rectangle: return FrameHandle.all
        }
    }

    /// 把新框写回归一化的形状字段。正方形由 `updateShape` 强制保形；
    /// 线条只吃长度和中心，高度是撑出来的视觉量，不落模型。
    private func applyShapeResize(_ shape: ShapeAnnotation, _ newRect: CGRect) {
        let rect = newRect.insetBy(dx: 4, dy: 4)
        let kind = shape.kind
        project.liveApply { state in
            state.updateShape(shape.id) {
                $0.centerX = min(max(newRect.midX / boxSize.width, 0), 1)
                $0.centerY = min(max(newRect.midY / boxSize.height, 0), 1)
                $0.width = min(max(rect.width / boxSize.width, 0.02), 1)
                if kind == .rectangle {
                    $0.height = min(max(rect.height / boxSize.height, 0.02), 1)
                }
            }
        }
    }

    @ViewBuilder
    private func shapeView(_ shape: ShapeAnnotation) -> some View {
        let frame = shape.frame(in: boxSize)
        let strokeWidth = max(0.5, shape.lineWidth * boxSize.height / 1080)

        Group {
            switch shape.kind {
            case .line:
                RoundedRectangle(cornerRadius: strokeWidth / 2)
                    .fill(shape.color.swiftUIColor)
                    .frame(width: max(2, frame.width), height: strokeWidth)
                    .rotationEffect(.degrees(shape.rotationDegrees))
                    .frame(width: max(2, frame.width), height: max(strokeWidth, frame.width))
            case .rectangle, .square:
                Rectangle()
                    .strokeBorder(shape.color.swiftUIColor, lineWidth: strokeWidth)
                    .frame(width: max(2, frame.width), height: max(2, frame.height))
            }
        }
        .contentShape(Rectangle().inset(by: -8))
        .position(x: shape.centerX * boxSize.width, y: shape.centerY * boxSize.height)
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if dragOrigin == nil {
                        dragOrigin = CGPoint(x: shape.centerX, y: shape.centerY)
                        project.selectedShapeID = shape.id
                    }
                    guard let origin = dragOrigin else { return }
                    // 接近画布中心时吸附并亮参考线，和剪辑变换框同一套手感。
                    let size = shape.frame(in: boxSize).size
                    var proposed = CGRect(
                        x: (origin.x + value.translation.width / boxSize.width) * boxSize.width - size.width / 2,
                        y: (origin.y + value.translation.height / boxSize.height) * boxSize.height - size.height / 2,
                        width: size.width,
                        height: size.height
                    )
                    let snapped = CenterSnap.snap(proposed, in: boxSize)
                    proposed = snapped.rect
                    centerGuides = (vertical: snapped.snappedX, horizontal: snapped.snappedY)
                    let nx = proposed.midX / boxSize.width
                    let ny = proposed.midY / boxSize.height
                    project.liveApply { state in
                        state.updateShape(shape.id) {
                            $0.centerX = min(max(nx, 0), 1)
                            $0.centerY = min(max(ny, 0), 1)
                        }
                    }
                }
                .onEnded { _ in
                    dragOrigin = nil
                    centerGuides = (vertical: false, horizontal: false)
                    project.endLiveEdit(rebuildsPreview: false)
                }
        )
        .onTapGesture { project.selectedShapeID = shape.id }
    }
}


/// `sheet(item:)` 需要 Identifiable。`ScreenRecordingResult` 是纯值类型，
/// 不给它硬塞 id —— 在这里包一层。
@available(macOS 15.0, *)
struct IdentifiedRecording: Identifiable {
    let result: ScreenRecordingResult
    var id: String { result.mainURL.path }

    init(_ result: ScreenRecordingResult) { self.result = result }
}
