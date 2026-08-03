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
    /// 触控板捏合缩放和空格/V 快捷键的事件监听（SwiftUI 手势在 ScrollView 上收不到捏合）。
    @State private var eventMonitor: Any?

    init() {
        clock = VideoEditProject.shared.clock
    }

    var body: some View {
        VSplitView {
            HSplitView {
                previewPane
                    .frame(minWidth: 430, idealWidth: 700, maxWidth: .infinity)
                    .layoutPriority(1)
                VideoEditInspectorView(project: project, onExport: { showsExportSheet = true })
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
        }
        .onDisappear {
            if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
            eventMonitor = nil
        }
        .onDropOfFiles { urls in project.addMedia(urls: urls) }
        .onDeleteCommand { project.deleteSelected() }
        .sheet(isPresented: $showsExportSheet) {
            VideoEditExportSheet(project: project, exporter: exporter)
        }
        // Export 放窗口右上角的工具栏，随时够得着。
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if exporter.isExporting {
                    ProgressView(value: exporter.progress)
                        .frame(width: 80)
                }
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

    // MARK: - 触控板与键盘

    /// 捏合缩放时间线；空格播放/暂停；V 切换所在轨的隐藏。
    /// 这个视图只在「视频剪辑」栏可见时存在，监听不会漏到别的页面。
    private func installEventMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.magnify, .keyDown]) { event in
            MainActor.assumeIsolated { handleEvent(event) }
        }
    }

    private func handleEvent(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .magnify:
            project.pixelsPerSecond = min(max(project.pixelsPerSecond * (1 + event.magnification), 4), 120)
            return event
        case .keyDown:
            // 正在打字（哪怕是别的输入框）就别抢按键。
            if NSApp.keyWindow?.firstResponder is NSTextView { return event }
            guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else {
                return event
            }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case " ":
                if !project.state.isEmpty { clock.togglePlayback() }
                return nil
            case "v":
                project.toggleHiddenForSelectionLane()
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
            videoBox
            Divider()
            transport
        }
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
                } else {
                    Text("Add clips to start editing.")
                        .foregroundStyle(.secondary)
                }
                ShapeOverlayCanvas(project: project, boxSize: size)
                if let cue = currentSubtitleCue {
                    BurnInSubtitleOverlay(
                        text: SubtitleSerializer.plainText(cue.text),
                        style: burnInQueue.burnInStyle,
                        scale: size.height / Double(BurnInStyle.referenceHeight),
                        boxSize: size
                    )
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

    /// 播放头此刻的字幕（字幕轨直接按时间线时间对齐）。
    private var currentSubtitleCue: SubtitleCue? {
        guard let cues = project.state.subtitle?.cues else { return nil }
        let time = clock.time
        return cues.last { $0.start <= time && time < $0.end }
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
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .truncationMode(.middle)
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

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(project.visibleShapes(at: project.clock.time)) { shape in
                shapeView(shape)
            }
        }
        .frame(width: boxSize.width, height: boxSize.height)
    }

    @ViewBuilder
    private func shapeView(_ shape: ShapeAnnotation) -> some View {
        let frame = shape.frame(in: boxSize)
        let strokeWidth = max(0.5, shape.lineWidth * boxSize.height / 1080)
        let isSelected = project.selectedShapeID == shape.id

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
        .overlay {
            if isSelected {
                Rectangle()
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(-4)
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
                    let nx = origin.x + value.translation.width / boxSize.width
                    let ny = origin.y + value.translation.height / boxSize.height
                    project.liveApply { state in
                        state.updateShape(shape.id) {
                            $0.centerX = min(max(nx, 0), 1)
                            $0.centerY = min(max(ny, 0), 1)
                        }
                    }
                }
                .onEnded { _ in
                    dragOrigin = nil
                    project.endLiveEdit(rebuildsPreview: false)
                }
        )
        .onTapGesture { project.selectedShapeID = shape.id }
    }
}
