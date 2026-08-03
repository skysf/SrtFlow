import SwiftUI
import SrtFlowCore

/// 把字幕永久烧进画面。左边是队列和预览，右边是样式与导出设置。
struct BurnInView: View {
    // 队列和预览都是全局的，不是这个视图的 @StateObject —— 切到别的栏目时视图会
    // 被销毁，跟着视图走的话正在跑的编码会断、渲染好的预览帧也会白丢。
    @ObservedObject private var queue = EncodeQueue.burnIn
    @ObservedObject private var renderer = BurnInPreviewRenderer.shared
    @StateObject private var toolchain = MediaToolchain.shared
    @StateObject private var fontCatalog = FontCatalogStore.shared
    @StateObject private var presets = StylePresetStore.shared
    @StateObject private var handoff = BurnInHandoff.shared
    /// 没配到视频、单独打开编辑的字幕文件。
    @StateObject private var standalone = StandaloneSubtitleStore.shared
    /// 拖边距滑块时预览上闪出的参考线。
    @StateObject private var guides = MarginGuideFlash()
    /// 预览播放器。放在这一层而不是预览视图里：放大/还原时预览视图会被重建，
    /// 播放器跟着走的话一放大就从头开始播了。
    @StateObject private var clock = PlayerClock(observationInterval: 0.05)
    // 这个视图在代码里拼字符串（L10n(...)），不是纯 LocalizedStringKey，
    // 光靠环境 locale 变化不会重新求值 body，所以要显式观察语言选择。
    @ObservedObject private var languageStore = AppLanguageStore.shared

    @State private var didResolveFont = false
    /// 这次是不是从 UserDefaults 里恢复出了用户上次调好的样式。
    @State private var didRestoreStyle = false

    @AppStorage("burnInSettings") private var storedSettings = ""
    @AppStorage("burnInStyle") private var storedStyle = ""
    @AppStorage("burnInSoftTrack") private var storedSoftTrack = false
    /// 预览是「播放」还是「精确帧」。
    @AppStorage("burnInPreviewMode") private var previewMode = BurnInPreviewMode.playback
    /// 预览铺满整个窗口。字幕看不看得清、位置对不对，小窗里判断不了。
    @State private var isPreviewExpanded = false

    var body: some View {
        // 放大的预览必须用 overlay 而不是 ZStack 的兄弟节点：ZStack 的尺寸取各子项
        // 的最大值，而放大预览里那个 GeometryReader 是「有多少要多少」，会一路把
        // 窗口撑大（实测一点放大窗口就从 760 高变成 1838）。overlay 的尺寸跟着
        // 底下的视图走，不参与窗口定尺。
        splitLayout
            .overlay {
                if isPreviewExpanded {
                    expandedPreview
                }
            }
            // 放大时按 Esc 还原。
            .onExitCommand { setPreviewExpanded(false) }
    }

    /// 放大预览时把侧边栏一起收起来，整个窗口都让给画面；还原时再放回来。
    /// 想要真正的满屏就在放大后按 ⌃⌘F 让窗口进系统全屏。
    private func setPreviewExpanded(_ expanded: Bool) {
        isPreviewExpanded = expanded
        MainWindowState.shared.sidebarVisibility = expanded ? .detailOnly : .all
    }

    private var splitLayout: some View {
        HSplitView {
            mainSide
                .frame(minWidth: 580, idealWidth: 820, maxWidth: .infinity)
            sidebar
                .frame(minWidth: 340, idealWidth: 390, maxWidth: 470)
        }
        // 主窗口左边还有侧边栏，这里的下限比原来独立开窗时收一点。
        .frame(minWidth: 930, minHeight: 580)
        .onAppear {
            toolchain.resolveIfNeeded()
            fontCatalog.loadIfNeeded()
            restore()
            // 字体表可能早就扫好了（切回这一栏时），那样 onChange 不会再触发。
            pickDefaultFontIfNeeded(fontCatalog.fonts)
            takeHandoff()
            // 从别的栏目切回来时预览通常还在（渲染器是全局的）；只有队列里有片子
            // 却一帧都还没渲染过时才需要补一次。
            if previewMode == .exactFrame, !renderer.hasContent { requestPreview() }
        }
        .onChange(of: handoff.pendingVideos) { _, _ in takeHandoff() }
        .onChange(of: fontCatalog.fonts) { _, fonts in pickDefaultFontIfNeeded(fonts) }
        .onChange(of: queue.burnInStyle) { _, _ in
            persistStyle()
            // 播放模式下的字幕是即时画的，不用起 ffmpeg。
            if previewMode == .exactFrame { requestPreview() }
        }
        .onChange(of: queue.settings) { _, _ in persistSettings() }
        .onChange(of: renderer.cueIndex) { _, _ in
            if previewMode == .exactFrame { requestPreview() }
        }
        .onChange(of: previewMode) { _, mode in
            if mode == .exactFrame { requestPreview() }
        }
        .onChange(of: queue.attachSoftSubtitleTrack) { _, value in storedSoftTrack = value }
        // 在字幕列里改了内容，「精确帧」也要跟着重渲。去抖：打字的每一击都起一次
        // ffmpeg 太浪费，停手片刻再渲。
        .onChange(of: previewItem?.burnIn?.cues) { _, _ in
            guard previewMode == .exactFrame else { return }
            cueEditRefreshTask?.cancel()
            cueEditRefreshTask = Task {
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard !Task.isCancelled else { return }
                requestPreview()
            }
        }
        .onDropOfFiles { urls in add(urls) }
    }

    /// 字幕编辑后重渲精确帧的去抖任务。
    @State private var cueEditRefreshTask: Task<Void, Never>?

    // MARK: - 左侧

    private var mainSide: some View {
        VStack(spacing: 0) {
            // 预览在最上面吃掉主要高度 —— 盯着看的是画面，不是文件列表。
            workArea
                .frame(maxHeight: .infinity)
                .layoutPriority(1)
            Divider()
            fileList
            Divider()
            footer
        }
    }

    /// 预览 + 字幕列。字幕整份可见、就地可编辑，播放到哪句滚到哪句。
    private var workArea: some View {
        HSplitView {
            previewArea
                .frame(minWidth: 320, idealWidth: 540, maxWidth: .infinity)
            SubtitleEditPanel(
                queue: queue,
                standalone: standalone,
                itemID: previewItem?.id,
                clock: clock,
                renderer: renderer,
                previewMode: previewMode,
                onOpenSubtitle: openSubtitleForEditing
            )
            .frame(minWidth: 252, idealWidth: 320, maxWidth: 460)
        }
    }

    /// 预览下面的紧凑素材条：空着时只占一行提示，有文件时也别跟预览抢高度。
    private var fileList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Videos and subtitles").font(.headline)
                if queue.items.isEmpty {
                    Text("Drop a video and its subtitle file here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Files with matching names are paired automatically.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer()
                Button("Add Files…") { chooseFiles() }
                    .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if !queue.items.isEmpty {
                List {
                    ForEach(queue.items) { item in
                        BurnInRow(
                            item: item,
                            queue: queue,
                            isPreviewSource: item.id == previewItem?.id,
                            onPickSubtitle: { pickSubtitle(for: item.id) }
                        )
                    }
                }
                .listStyle(.inset)
                .frame(minHeight: 64, maxHeight: 150)
            }
        }
    }

    private var previewArea: some View {
        BurnInPreviewArea(
            item: previewItem,
            style: queue.burnInStyle,
            mode: $previewMode,
            renderer: renderer,
            guides: guides,
            clock: clock,
            onToggleExpand: { setPreviewExpanded(true) }
        )
    }

    /// 铺满整个窗口的预览。窗口再按 ⌃⌘F 进系统全屏就是真全屏了，字幕叠层
    /// 一路都在（它和画面在同一个 SwiftUI 层级里，不像 AVPlayerView 自带的全屏
    /// 会把叠层甩掉）。
    private var expandedPreview: some View {
        ZStack {
            Rectangle()
                .fill(.background)
                .ignoresSafeArea()
            BurnInPreviewArea(
                item: previewItem,
                style: queue.burnInStyle,
                mode: $previewMode,
                renderer: renderer,
                guides: guides,
                clock: clock,
                isExpanded: true,
                onToggleExpand: { setPreviewExpanded(false) }
            )
        }
        .transition(.opacity)
    }

    private var footer: some View {
        VStack(spacing: 10) {
            OutputLocationPicker(queue: queue)

            HStack(spacing: 10) {
                if queue.isRunning {
                    Button("Stop All") { queue.cancelAll() }
                } else {
                    Button {
                        queue.start()
                    } label: {
                        Label(startTitle, systemImage: "play.fill")
                    }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(!canStart)
                }

                Button("Clear Finished") { queue.clearFinished() }
                    .disabled(!queue.items.contains(where: \.isDone))

                Spacer()

                if let item = queue.items.first(where: { $0.status == .running }) {
                    Text(runningSummary(item))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            if let warning = toolchain.warning {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(warning).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
            }
        }
        .padding(12)
    }

    private func runningSummary(_ item: EncodeItem) -> String {
        var parts = [MediaFormatting.percent(item.progress)]
        if let speed = item.speed { parts.append(MediaFormatting.speed(speed)) }
        if let eta = item.etaSeconds { parts.append(MediaFormatting.eta(eta)) }
        return parts.joined(separator: " · ")
    }

    private var startTitle: LocalizedStringKey {
        let ready = readyItems.count
        return ready > 1 ? "Burn In \(ready) Videos" : "Burn In Subtitles"
    }

    private var readyItems: [EncodeItem] {
        queue.items.filter { $0.status == .waiting && !($0.burnIn?.cues.isEmpty ?? true) }
    }

    private var canStart: Bool {
        guard let runtime = toolchain.runtime, runtime.canBurnInSubtitles else { return false }
        return !queue.isRunning && !readyItems.isEmpty
    }

    // MARK: - 右侧

    private var sidebar: some View {
        TabView {
            SubtitleStyleEditor(
                style: $queue.burnInStyle,
                fontCatalog: fontCatalog,
                presets: presets,
                guides: guides
            )
            .tabItem { Text("Style") }

            VStack(spacing: 0) {
                EncodeSettingsView(settings: $queue.settings)
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Also attach a switchable subtitle track", isOn: $queue.attachSoftSubtitleTrack)
                    Text("Adds the subtitles as an mp4 text track on top of the burned-in copy, so players that support it can toggle a selectable version too.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let command = previewCommandForSidebar {
                        CommandPreview(command: command, executableName: "ffmpeg")
                    }
                }
                .padding(12)
            }
            .tabItem { Text("Export") }
        }
        .padding(.top, 6)
    }

    private var previewCommandForSidebar: FFmpegCommand? {
        guard let item = previewItem else { return nil }
        return FFmpegCommand(
            inputPath: item.inputURL.lastPathComponent,
            outputPath: item.outputURL.lastPathComponent,
            settings: queue.settings,
            burnIn: FFmpegCommand.BurnIn(),
            softSubtitlePath: queue.attachSoftSubtitleTrack ? "soft.srt" : nil,
            hasAudio: item.info?.hasAudio ?? true,
            audioCanCopy: item.info?.audioCanCopyToMP4 ?? true,
            sourceHeight: item.info?.height ?? 1080,
            sourceFrameRate: item.info?.frameRate
        )
    }

    // MARK: - 预览驱动

    /// 预览拿第一个配好字幕的条目。
    private var previewItem: EncodeItem? {
        queue.items.first { !($0.burnIn?.cues.isEmpty ?? true) }
    }

    private var previewCues: [SubtitleCue]? {
        previewItem?.burnIn?.cues
    }

    private func requestPreview() {
        guard let item = previewItem,
              let info = item.info,
              let cues = item.burnIn?.cues,
              !cues.isEmpty else {
            renderer.clear()
            return
        }

        let index = min(max(0, renderer.cueIndex), cues.count - 1)
        let cue = cues[index]
        // 取这条字幕的中点，保证画面上一定有字。
        var time = (cue.start + cue.end) / 2
        if cue.end <= cue.start { time = cue.start + 0.1 }
        if info.duration > 0 { time = min(time, max(0, info.duration - 0.05)) }

        renderer.request(BurnInPreviewRenderer.Request(
            video: item.inputURL,
            info: info,
            cues: cues,
            style: queue.burnInStyle,
            fontFileURL: fontCatalog.font(named: queue.burnInStyle.fontName)?.fileURL,
            timeSeconds: time
        ))
    }

    // MARK: - 文件处理

    private func chooseFiles() {
        var types = MediaFileTypes.video
        types.append(contentsOf: SubtitleFileTypes.readable)
        add(FilePicker.chooseFiles(types: types))
    }

    /// 字幕列空着时的「打开字幕」：有等着配字幕的视频就配给它，没有就独立打开。
    private func openSubtitleForEditing() {
        let urls = FilePicker.chooseFiles(types: SubtitleFileTypes.readable, allowsMultiple: false)
        guard let url = urls.first else { return }
        add([url])
    }

    private func add(_ urls: [URL]) {
        let videos = urls.filter(MediaFileTypes.isVideo)
        let subtitles = urls.filter(MediaFileTypes.isSubtitle)

        // 先把视频排进队列。
        for video in videos where !queue.items.contains(where: { $0.inputURL == video && !$0.isDone }) {
            queue.add(urls: [video], burnIn: BurnInRequest(subtitleURL: nil))
        }

        guard !subtitles.isEmpty else {
            requestPreviewSoon()
            return
        }

        // 再按文件名给还没配字幕的视频配上。
        let unpaired = queue.items.filter { ($0.burnIn?.cues.isEmpty ?? true) }.map(\.inputURL)
        let pairs = SubtitleLoader.match(videos: unpaired, subtitles: subtitles)
        for (video, subtitle) in pairs {
            guard let item = queue.items.first(where: { $0.inputURL == video }) else { continue }
            attach(subtitle: subtitle, to: item.id)
        }

        // 配不上的字幕也不能扔：还有缺字幕的视频就给第一个，一个视频都没有
        // 就当作独立的字幕文件打开来编辑 —— 双击 .srt 进来走的就是这条路。
        let leftovers = subtitles.filter { !pairs.values.contains($0) }
        if let first = leftovers.first {
            if let waiting = queue.items.first(where: { ($0.burnIn?.cues.isEmpty ?? true) && !$0.isDone }) {
                attach(subtitle: first, to: waiting.id)
            } else {
                standalone.open(first)
            }
        }
        requestPreviewSoon()
    }

    private func pickSubtitle(for id: EncodeItem.ID) {
        let urls = FilePicker.chooseFiles(types: SubtitleFileTypes.readable, allowsMultiple: false)
        guard let url = urls.first else { return }
        attach(subtitle: url, to: id)
        requestPreviewSoon()
    }

    private func attach(subtitle: URL, to id: EncodeItem.ID) {
        do {
            let document: SubtitleDocumentModel
            if standalone.url == subtitle, let edited = standalone.document, standalone.hasUnsavedEdits {
                // 这个文件正在字幕列里改着呢，配给视频时要带着没保存的改动走，
                // 不能从磁盘重读一份把编辑丢了。
                document = edited
                queue.updateBurnIn(
                    BurnInRequest(subtitleURL: subtitle, document: document, hasUnsavedEdits: true),
                    for: id
                )
                standalone.clear()
            } else {
                document = try SubtitleLoader.load(subtitle)
                queue.updateBurnIn(BurnInRequest(subtitleURL: subtitle, document: document), for: id)
                if standalone.url == subtitle { standalone.clear() }
            }
            if document.cues.isEmpty {
                queue.setError(
                    String(
                        format: L10n("No subtitle lines found in %@."),
                        subtitle.lastPathComponent
                    ),
                    for: id
                )
            }
        } catch {
            queue.setError(error.localizedDescription, for: id)
        }
    }

    private func takeHandoff() {
        let staged = handoff.take()
        guard !staged.videos.isEmpty || !staged.subtitles.isEmpty else { return }
        add(staged.videos + staged.subtitles)
    }

    /// 队列刚变动时 info 可能还在探测，稍等一下再画预览。
    private func requestPreviewSoon() {
        renderer.cueIndex = 0
        Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            requestPreview()
        }
    }

    /// 首次使用时挑一个**有中文字形**的默认字体。
    ///
    /// 不能只在「当前字体不存在」时才挑：BurnInStyle 的默认值是 Helvetica，
    /// 它在系统里确实存在，但完全没有汉字，中文字幕会被 fontconfig 悄悄换成
    /// 别的字体 —— 看着能用，其实用户根本没得选。
    private func pickDefaultFontIfNeeded(_ fonts: [SubtitleFont]) {
        guard !didResolveFont, !fonts.isEmpty else { return }
        didResolveFont = true

        let current = fontCatalog.font(named: queue.burnInStyle.fontName)
        let needsDefault = current == nil || !didRestoreStyle
        guard needsDefault, let preferred = FontCatalog.preferredDefault(in: fonts) else { return }
        queue.burnInStyle.fontName = preferred.familyName
    }

    // MARK: - 持久化

    private func persistSettings() {
        guard let data = try? JSONEncoder().encode(queue.settings) else { return }
        storedSettings = String(decoding: data, as: UTF8.self)
    }

    private func persistStyle() {
        guard let data = try? JSONEncoder().encode(queue.burnInStyle) else { return }
        storedStyle = String(decoding: data, as: UTF8.self)
    }

    private func restore() {
        if !storedSettings.isEmpty,
           let decoded = try? JSONDecoder().decode(VideoEncodeSettings.self, from: Data(storedSettings.utf8)) {
            queue.settings = decoded
        }
        if !storedStyle.isEmpty,
           let decoded = try? JSONDecoder().decode(BurnInStyle.self, from: Data(storedStyle.utf8)) {
            queue.burnInStyle = decoded
            didRestoreStyle = true
        }
        queue.attachSoftSubtitleTrack = storedSoftTrack
    }
}

/// 队列里的一行：视频 + 配到的字幕。
private struct BurnInRow: View {
    let item: EncodeItem
    @ObservedObject var queue: EncodeQueue
    let isPreviewSource: Bool
    let onPickSubtitle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                statusIcon
                Text(item.inputURL.lastPathComponent)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if isPreviewSource {
                    Text("Preview")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.tint.opacity(0.18), in: Capsule())
                }
                Spacer(minLength: 8)
                controls
            }

            HStack(spacing: 6) {
                if let subtitleURL = item.burnIn?.subtitleURL, !(item.burnIn?.cues.isEmpty ?? true) {
                    Image(systemName: "captions.bubble")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(subtitleURL.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("· \(item.burnIn?.cues.count ?? 0) lines")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    Image(systemName: "exclamationmark.circle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Text("No subtitle file yet")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button("Choose…", action: onPickSubtitle)
                        .controlSize(.small)
                        .buttonStyle(.link)
                }
                Spacer()
                if let info = item.info {
                    Text("\(info.resolutionLabel) · \(MediaFormatting.bytes(info.fileBytes))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            if item.status == .running {
                ProgressView(value: item.progress).progressViewStyle(.linear)
            }
            if item.status == .finished, let bytes = item.outputBytes {
                Text("→ \(item.outputURL.lastPathComponent) · \(MediaFormatting.bytes(bytes))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let message = item.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 3)
    }

    private var statusIcon: some View {
        Group {
            switch item.status {
            case .waiting: Image(systemName: "clock").foregroundStyle(.secondary)
            case .probing, .running: ProgressView().controlSize(.small)
            case .finished: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
            case .cancelled: Image(systemName: "slash.circle").foregroundStyle(.secondary)
            }
        }
        .frame(width: 16)
    }

    private var controls: some View {
        HStack(spacing: 6) {
            if item.status == .finished {
                Button { revealInFinder(item.outputURL) } label: { Image(systemName: "folder") }
                    .buttonStyle(.borderless)
                    .help("Show in Finder")
            }
            if item.isActive || item.status == .waiting {
                Button { queue.cancel(id: item.id) } label: { Image(systemName: "stop.circle") }
                    .buttonStyle(.borderless)
                    .help("Cancel")
            }
            if !item.isActive {
                Button { queue.remove(id: item.id) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Remove from list")
            }
        }
    }
}
