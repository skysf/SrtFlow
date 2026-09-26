import AppKit
import SwiftUI
import SrtFlowCore

/// 视频编辑：上面是预览 + 检查器，下面是工具栏 + 时间线。
struct VideoEditView: View {
    /// `@Bindable` 只为三个开关的 `$project.x`。body 读了工程的哪个属性，整个编辑器就在它变时重算一遍：
    /// **别在这儿读选择**（点选一段会叫醒一切），看选择的按钮放进小视图（preview-perf-ratchet.md 第十三节）。
    @Bindable private var project = VideoEditProject.shared
    @ObservedObject private var exporter = VideoEditExporter.shared
    @StateObject private var toolchain = MediaToolchain.shared
    // 字幕轨的样式沿用「烧制字幕」页调好的那套。
    @ObservedObject private var burnInQueue = EncodeQueue.burnIn
    @ObservedObject private var languageStore = AppLanguageStore.shared
    /// 播放器时钟：**持有不订阅**。播放时它一秒跳二十下，根视图订阅它就是整个编辑器一秒重算
    /// 二十遍（播放卡的大头）。跟着它变的几小块各自订阅，见 `VideoEditPlayheadFollowers.swift`；
    /// body 里别再直接读 `clock.time`（docs/architecture/preview-perf-ratchet.md 第十二节）。
    private let clock: PlayerClock

    @Environment(\.undoManager) private var undoManager
    @State private var showsExportSheet = false
    @State private var showsSubtitlePanel = false
    /// 预览左边那栏转场库的显隐。记住上次的选择 —— 它是布局偏好，不是工程数据。
    /// 左栏（转场 / 滤镜 / 音频三页共用）的显隐。
    ///
    /// **`@AppStorage` 的键仍叫 `transitionLibraryVisible`**：这一栏最早只有转场库，
    /// 键名跟着语义改的话，用户上次收起来的状态会丢 —— 为了一个看不见的字符串
    /// 让所有人的界面跳一下不划算。变量名改了，键名是历史。
    @AppStorage("transitionLibraryVisible") private var showsLibraryColumn = true
    @ObservedObject private var recordingCoordinator = ScreenRecordingCoordinator.shared
    /// 空格/V 快捷键的事件监听。捏合缩放由时间线里 TimelineMagnificationBridge
    /// 的 local monitor 处理，不在这里。
    @State private var eventMonitor: Any?
    /// 当前字幕文本块的实测高度（overlay 回报，字幕拖框定框用）。
    @State private var subtitleBlockHeight: Double = 0
    /// 预览里正在就地编辑的那条字幕（双击画面上的字幕进入）。
    @State private var previewEditingCueID: UUID?

    init() {
        clock = VideoEditProject.shared.clock
    }

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        VSplitView {
            HSplitView {
                // 素材库（转场 / 滤镜两页）：预览左边的一栏，只占上半区 ——
                // 时间线仍然通栏。
                // 宽度预算：库 196 + 预览 430 + 检查器 252 = 878，没超过下面那
                // 条 minWidth 900，所以加这一栏不用抬窗口的最小宽度。
                if showsLibraryColumn {
                    LibraryColumn(project: project)
                        .frame(minWidth: 196, idealWidth: 220, maxWidth: 340)
                }
                previewPane
                    // idealWidth 从 700 收到 560（2026-09-22 用户拍板：预览默认
                    // 窄一点，要大自己拉）。**只对没拖过分栏器的窗口生效** ——
                    // AppKit 会 autosave 用户拖过的位置，这是有意接受的行为。
                    .frame(minWidth: 430, idealWidth: 560, maxWidth: .infinity)
                    .layoutPriority(1)
                // 右栏一位两用：字幕表**盖在检查器上面**，✕ 回到检查器
                //（2026-08-12 用户拍板）。
                // 它曾经是并排的第三栏，实测分栏器会把排在最后的检查器整条挤出
                // 窗口右边界（改 idealWidth / layoutPriority 都拉不回来）——
                // 共用一栏之后分栏器始终只有两块，宽度问题不存在了。
                Group {
                    if project.showsSubtitleList {
                        VideoEditSubtitlePanel(
                            project: project,
                            clock: clock,
                            onOpenGenerator: { showsSubtitlePanel = true }
                        )
                    } else {
                        VideoEditInspectorView(
                            project: project,
                            clock: clock,
                            playhead: clock.whilePaused,
                            onExport: { showsExportSheet = true }
                        )
                    }
                }
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
            // GUI 冒烟 / 性能测试的环境变量钩子，不设就完全不生效（DevHooks.swift）。
            DevHooks.editorAppeared(project: project)
        }
        .onDisappear {
            if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
            eventMonitor = nil
            // 切去别的栏目时把挂着的自动保存写下去，别留在内存里等。
            project.flushAutosave()
        }
        .onDropOfFiles { urls in project.addMedia(urls: urls) }
        // ⌫ 的第二条路：monitor 放行后系统会把它解释成 delete command 送回来。
        // 与 handleEvent 同一条纪律：字幕草稿开着（正在字幕输入框里编辑）时不删。
        .onDeleteCommand {
            guard project.subtitleDraft == nil else { return }
            project.deleteSelected()
        }
        .sheet(isPresented: $showsExportSheet) {
            VideoEditExportSheet(project: project, exporter: exporter).appLanguage()
        }
        .sheet(isPresented: $showsSubtitlePanel) {
            SubtitleGenPanel(project: project).appLanguage()
        }
        // 录制设置页 = `state == .configuring` 的投影。会话一旦被撤销
        // （Quit、失败、取消），页自己就关了。
        .sheet(isPresented: Binding(
            get: { recordingCoordinator.state == .configuring },
            set: { if !$0 { recordingCoordinator.cancelConfiguring() } }
        )) {
            ScreenRecordingSetupView(project: project).appLanguage()
        }
        // partial 结果：**工程锁还在**，用户必须先处置（计划 §11.4）。
        .sheet(item: Binding(
            get: { recordingCoordinator.pendingPartial.map(IdentifiedRecording.init) },
            set: { _ in }
        )) { item in
            ScreenRecordingPartialSheet(result: item.result) { shouldImport in
                Task { await recordingCoordinator.resolvePartial(import: shouldImport) }
            }
            .appLanguage()
        }
        // 崩溃恢复：启动时发现上次的残留。三选一，「保留」绝不删文件。
        .sheet(item: Binding(
            get: { recordingCoordinator.pendingRecovery },
            set: { _ in }
        )) { recovery in
            ScreenRecordingRecoverySheet(recovery: recovery) { decision in
                Task { await recordingCoordinator.resolveRecovery(decision) }
            }
            .appLanguage()
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
            // 素材库的开关挨着工程名放最左边，和系统那个侧边栏开关呼应 ——
            // 都是「把左边那一栏收起来」。
            ToolbarItem(placement: .navigation) {
                Button {
                    showsLibraryColumn.toggle()
                } label: {
                    Label(
                        "Library",
                        systemImage: "square.filled.and.line.vertical.and.square"
                    )
                }
                .instantHelp("Show or hide the transition, filter and audio library")
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
                    .instantHelp("Record the screen into this project")
                    .disabled(recordingCoordinator.isBusy)
                }
                Button {
                    project.showsSubtitleList.toggle()
                } label: {
                    Label("Subtitles", systemImage: "captions.bubble")
                }
                .disabled(project.state.isEmpty)
                .instantHelp("Show or hide the subtitle list")
                Button {
                    showsExportSheet = true
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(project.state.isEmpty || exporter.isExporting)
                .instantHelp("Export the timeline or the selected clips")
            }
        }
    }

    // MARK: - 键盘

    /// 空格播放/暂停；V 切换**选中那几段**的隐藏；A/B 切换选择/分割工具；M 打标记。
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
            // 字幕草稿开着 = 用户正在字幕输入框里编辑。多行 TextField + 中文输入法
            // 下第一响应者会偶发丢掉（上面那条判不住），这一拍的按键就会往下落进
            // 快捷键：⌫ 把正在编辑的 cue 整条从轨上删掉，空格开播、V 切段的显隐。
            // 草稿随提交（回车/失焦）清空，不会长期挡住快捷键。
            if project.subtitleDraft != nil { return event }
            // ⌘A 选中时间线上的一切、⌘⇧A 取消（2026-09-25 用户拍板）。放在修饰键那道闸门
            // **前面**：带 ⌘ 的组合默认放行给系统，这两个是例外；正在打字时上面已经让路了
            //（输入框里的 ⌘A 仍是全选文字）。按 keyCode 认（0 = A），不看输入法。
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if event.keyCode == 0, modifiers == [.command] {
                project.selectAllOnTimeline()
                return nil
            }
            if event.keyCode == 0, modifiers == [.command, .shift] {
                project.clearSelection()
                return nil
            }
            guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else {
                return event
            }
            // ⌫ / fn⌫：删掉选中的东西（剪辑 / 形状 / 字幕 cue / 标记，框选可以
            // 一次选中前三类），和工具栏 trash 按钮同一个动作。判据直接问
            // `EditSelection` 自己，别在这里重列一遍类别 —— 加一类就会漏一处。
            // 按 keyCode 认（51 = delete，117 = forward delete）——
            // charactersIgnoringModifiers 那边是控制字符，走字符串会一团糟。
            if event.keyCode == 51 || event.keyCode == 117 {
                guard !project.selection.isEmpty else {
                    return event
                }
                project.deleteSelected()
                return nil
            }
            // Return / 小键盘 Enter / Home（fn ←）：播放头回到开头、时间线滚回最左（2026-09-26 用户拍板；
            // FCP 默认是 Home，GarageBand 是 Return，两个都接）。按 keyCode 认：36 / 76 / 115。
            // 只认主窗口上的：sheet、弹窗、popover 里的 Return 是它们的默认按钮（导出面板、「替换吗」）。
            if [36, 76, 115].contains(event.keyCode), event.window?.isMainWindow == true, !project.state.isEmpty {
                clock.goToStart()
                return nil
            }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case " ":
                if !project.state.isEmpty { clock.togglePlayback() }
                return nil
            case "v":
                project.toggleHiddenForSelection()
                return nil
            case "a":
                project.activeTool = .select
                return nil
            case "b":
                project.activeTool = .split
                return nil
            case "m":
                project.addMarkerAtPlayhead()
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
                    // 播放器画面 + 此刻的调色。滤镜挂在播放器视图自己身上，所以 ZStack 里
                    // 它**上面**的叠层天然不吃调色（见 PreviewPlayerSurface）。
                    PreviewPlayerSurface(project: project, clock: clock)
                    // 点选画面内容 + 变换框。放在形状叠层下面：形状的点击优先。
                    ClipTransformCanvas(project: project, clock: clock, boxSize: size)
                } else {
                    Text("Add clips to start editing.")
                        .foregroundStyle(.secondary)
                }
                ShapeOverlayCanvas(project: project, clock: clock, boxSize: size)
                // 文字压在形状之上、字幕之下 —— 与导出滤镜链一字不差
                //（docs/architecture/text-overlays.md）。
                TextOverlayCanvas(project: project, clock: clock, boxSize: size)
                // 字幕（文字 + 画面上点选 / 就地改字 + 选中 cue 的拖框），跟着播放头换句。
                PreviewSubtitleLayer(
                    project: project,
                    clock: clock,
                    boxSize: size,
                    style: burnInQueue.burnInStyle,
                    blockHeight: $subtitleBlockHeight,
                    editingCueID: $previewEditingCueID
                )
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        // 下限压到 120：预览框是**唯一**该让步的东西。它以前钉在 220（加 padding
        // 就是 240），上半区在 VSplitView 里只有 300 的下限 —— 再叠一条缺失素材
        // 条、或者 notice 撑到两行，这个 VStack 的最小高度就超过了分给它的高度。
        // SwiftUI 不会把拒绝再矮的 videoBox 压下去，只会把它下面的 transport 挤
        // 出边界，压到时间线工具栏那一排按钮上（用户报的重叠就是这么来的）。
        .frame(minHeight: 120)
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

    private var transport: some View {
        HStack(spacing: 10) {
            // 这两块各自订阅自己那一份（播放状态 / 显示的那一格时间），播放时不牵动这一行。
            TransportPlayButton(clock: clock, isDisabled: project.state.isEmpty)
            TransportTimeLabel(clock: clock, duration: project.duration)

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
            .instantHelp("Canvas aspect ratio")

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
            .instantHelp("Project frame rate — preview, export and keyframes all follow it")

            // 只有它订阅「正在重建」：放在工程上发的话，每次重建整个编辑器多算两轮。
            PreviewRebuildSpinner(status: project.rebuildStatus)

            if project.importingCount > 0 {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    // 定格也记在 `importingCount` 上（它同样是后台转码），但
                    // 「正在添加…」是导入素材那件事的文案 —— 用户点的是定格，
                    // 看到「添加」只会以为自己点错了按钮。两件事同时在跑时算定格：
                    // 那是他刚刚亲手点的那一个。
                    // **两个字面量各写在自己的分支里**，不要写成
                    // `Text(cond ? "A" : "B")` —— 文案覆盖扫描器认不出三目里的
                    // 字面量，那样写会把这两条一起从"用到的文案"里漏掉，
                    // 检查照样绿（它只查用到的有没有译文），等于悄悄开一个洞。
                    // 实测：改成三目之后计数从 626 掉到 625。
                    Group {
                        if project.isFreezing {
                            Text("Freezing…")
                        } else {
                            Text("Adding…")
                        }
                    }
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
                    .instantHelp(verbatim: notice)
                Button {
                    project.notice = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .instantHelp("Dismiss this message")
            }

            if exporter.isExporting {
                Button {
                    exporter.cancel()
                } label: {
                    Image(systemName: "stop.circle")
                }
                .buttonStyle(.borderless)
                .instantHelp("Stop")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        // 这一行按自然高度**先**拿走空间，剩下的才归预览框：
        // `fixedSize` 让它拒绝被压扁（notice 撑到两行时也如实变高），
        // `layoutPriority` 保证 VStack 先满足它 —— 两个缺一个，空间不够时
        // 被牺牲的就又是它自己了。
        .fixedSize(horizontal: false, vertical: true)
        .layoutPriority(1)
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

            // 撤销栈不可观察：这两个按钮自己听撤销栈的通知，别让根视图替它们刷新（第十三节）。
            UndoRedoToolbarButtons(project: project)

            Divider().frame(height: 16)

            // 下面五个能不能点看播放头：判据跟着时钟走，但只有那个小修饰器订阅它（工具栏本身不重算）。
            ToolbarIcon(icon: "scissors", help: "Split at playhead", shortcut: .command("B")) {
                project.splitAtPlayhead()
            }
            .disabled(followingPlayhead: clock) { !canSplit }
            // 定格要抽帧 + 转码，实测 720p 约 0.5 秒、4K 更久。反馈就放在用户
            // 刚点的这个按钮上 —— 播放条那一行虽然也有转圈，但那是另一行工具栏。
            ToolbarIcon(
                icon: "snowflake", help: "Freeze the frame at the playhead",
                shortcut: .commandShift("F"), isBusy: project.isFreezing
            ) {
                project.freezeFrameAtPlayhead()
            }
            .disabled(followingPlayhead: clock) { !project.canFreezeFrame }
            // `.plain` 只显示不挂等价符：无修饰键的键盘等价符会抢文本框的输入，
            // M 由 handleEvent 里的事件监听接（那边会先让开正在打字的输入框）。
            ToolbarIcon(icon: "bookmark", help: "Add a marker at the playhead", shortcut: .plain("M")) {
                project.addMarkerAtPlayhead()
            }
            .disabled(followingPlayhead: clock) { !project.canAddMarker }
            ToolbarIcon(icon: "delete.left", help: "Delete everything left of the playhead in this clip") {
                project.trimToPlayhead(keepRight: true)
            }
            .disabled(followingPlayhead: clock) { !canSplit }
            ToolbarIcon(icon: "delete.right", help: "Delete everything right of the playhead in this clip") {
                project.trimToPlayhead(keepRight: false)
            }
            .disabled(followingPlayhead: clock) { !canSplit }
            // 垃圾桶和分离声音看选择：单拎成小视图，点选一段只叫醒它俩、不叫醒整个编辑器（第十三节）。
            SelectionToolbarButtons(project: project)

            Spacer()

            ToolbarToggle(icon: "arrow.right.and.line.vertical.and.arrow.left", help: "Main track magnet (auto close gaps)", isOn: $project.magnetEnabled)
            ToolbarToggle(icon: "arrow.down.to.line.compact", help: "Auto snapping while dragging", isOn: $project.snappingEnabled)
            ToolbarToggle(icon: "link", help: "Linkage: detached audio moves with its video", isOn: $project.linkageEnabled)

            Divider().frame(height: 16)

            ToolbarIcon(icon: "minus.magnifyingglass", help: "Zoom out", shortcut: .command("-")) {
                project.setPixelsPerSecond(project.pixelsPerSecond / VideoEditProject.zoomStep)
            }
            // **对数刻度**：缩放区间 4…4800 有 1200 倍宽，线性滑杆上原来那一整段（4…120）
            // 只占最左边 2%。按对数取值，每挪一段放大的倍数都一样。
            Slider(value: zoomSliderBinding, in: log(VideoEditProject.zoomRange.lowerBound)...log(VideoEditProject.zoomRange.upperBound))
                .frame(width: 96)
                .controlSize(.mini)
            ToolbarIcon(icon: "plus.magnifyingglass", help: "Zoom in", shortcut: .command("=")) {
                project.setPixelsPerSecond(project.pixelsPerSecond * VideoEditProject.zoomStep)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// 缩放滑杆读写的是 log(pps)；写入仍走唯一的缩放入口 `setPixelsPerSecond`。
    private var zoomSliderBinding: Binding<Double> {
        Binding(
            get: { log(max(project.pixelsPerSecond, VideoEditProject.zoomRange.lowerBound)) },
            set: { project.setPixelsPerSecond(exp($0)) }
        )
    }

    private var addMenu: some View {
        Menu {
            Button("Add Media…") { pickMedia(toOverlay: false) }
            Button("Add to Upper Track…") { pickMedia(toOverlay: true) }
                .disabled(project.state.mainClips.isEmpty)
            Button("Add Subtitle File…") { pickSubtitle() }
            Divider()
            Button {
                project.addTextOverlay()
            } label: {
                Label("Text", systemImage: "textformat")
            }
            Button {
                project.addNumberOverlay()
            } label: {
                Label("Number", systemImage: "number")
            }
            ForEach(ShapeKind.allCases) { kind in
                Button {
                    project.addShape(kind)
                } label: {
                    Label(LocalizedStringKey(kind.title), systemImage: kind.icon)
                }
            }
            Divider()
            // 第一刀的滤镜入口。第二刀换成左边那栏的滤镜库（卡片 + 悬停 +），
            // 这个菜单项留着 —— 菜单是「在播放头放一个东西」的统一入口。
            Menu {
                ForEach(FilterPreset.allCases) { preset in
                    Button(LocalizedStringKey(preset.title)) { project.addFilter(preset) }
                }
            } label: {
                Label("Filter", systemImage: "camera.filters")
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
        .instantHelp("Mouse tool: Select or Split", shortcut: .plain("A / B"))
    }

    private var canSplit: Bool {
        let time = clock.time
        if project.selectedClipIDs.contains(where: { project.state.clip(with: $0)?.contains(time: time) == true }) {
            return true
        }
        return project.mainClipAtPlayhead() != nil
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

/// `sheet(item:)` 需要 Identifiable。`ScreenRecordingResult` 是纯值类型，
/// 不给它硬塞 id —— 在这里包一层。
@available(macOS 15.0, *)
struct IdentifiedRecording: Identifiable {
    let result: ScreenRecordingResult
    var id: String { result.mainURL.path }

    init(_ result: ScreenRecordingResult) { self.result = result }
}
