import AppKit
import SwiftUI
import SrtFlowCore

/// 导出弹窗。一眼看到的只有三样 —— 标题、导出至、分辨率（工程有字幕时再加一个
/// 「烧不烧字幕」）—— 其余收进「高级」，默认收着。
///
/// 点「导出」直接开始，不再弹保存面板：名字和位置已经摆在面板上了。
/// 产品决策与理由：docs/plans/2026-09-24-export-panel.md；
/// 长期约束（只放管线真消费的设置、撞名、记住与重置）：docs/architecture/export-settings.md。
struct VideoEditExportSheet: View {
    @ObservedObject var project: VideoEditProject
    @ObservedObject var exporter: VideoEditExporter
    @ObservedObject private var burnInQueue = EncodeQueue.burnIn
    @StateObject private var fontCatalog = FontCatalogStore.shared
    @Environment(\.dismiss) private var dismiss

    /// 只导出选中的内容（单段、多段、纯音频都行）。
    @State private var selectionOnly = false
    /// 字幕：烧不烧（主区）+ 独立文件（高级里）。
    @State private var subtitleOptions = SubtitleExportOptions()
    /// 标题框里的字。打开面板时取「这个工程里改过的」，没改过就是默认标题。
    @State private var title = ""
    @State private var confirmsReplace = false
    /// 展开 / 收起记住：大多数人从来不开，开过的人下次多半还要看。
    @AppStorage("videoEditExportAdvancedExpanded") private var advancedExpanded = false

    private var exportState: TimelineState {
        project.stateForExport(selectionOnly: selectionOnly && !project.selectedClipIDs.isEmpty)
    }

    private var isAudioOnly: Bool { VideoEditExportGraph.isAudioOnly(exportState) }
    private var fileExtension: String { isAudioOnly ? "m4a" : "mp4" }

    /// 默认标题：工程名；还没存过的工程用第一段素材的名字。
    private var defaultTitle: String {
        let raw = project.documentURL?.deletingPathExtension().lastPathComponent
            ?? project.state.mainClips.first?.name
            ?? project.state.audioTracks.first?.clips.first?.name
            ?? "Timeline"
        return ExportFileName.stem(from: raw, droppingExtension: "", fallback: "Timeline")
    }

    /// 记住的文件夹 → 工程文件旁边 → ~/Movies。
    private var folder: URL {
        exporter.usableExportFolder
            ?? project.documentURL?.deletingLastPathComponent()
            ?? FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    private var stem: String {
        ExportFileName.stem(from: title, droppingExtension: fileExtension, fallback: defaultTitle)
    }

    private var outputURL: URL {
        folder.appendingPathComponent(stem).appendingPathExtension(fileExtension)
    }

    /// 导出会替换一个已有文件。刚从这个面板导出去的那一份不算 —— 不然一导完就冒出
    /// 「已存在」；真要再导一次，点「导出」时照样会问。
    private var showsReplaceHint: Bool {
        FileManager.default.fileExists(atPath: outputURL.path)
            && exporter.finishedURL?.standardizedFileURL.path != outputURL.standardizedFileURL.path
    }

    /// 这次导出的画布（选中导出、Auto 画布时可能和整条时间线不同）。
    private var canvas: (width: Int, height: Int) {
        let size = VideoEditCompositionBuilder.renderSize(for: exportState)
        return (Int(size.width), Int(size.height))
    }

    private var resolutionOptions: [ResolutionLimit] {
        ResolutionLimit.downscaleOptions(width: canvas.width, height: canvas.height)
    }

    /// 记住的档位这块画布给不了（换到了更小的工程）就显示「跟随工程」——
    /// 导出那边同一个结果：档位不小于画布短边时 `cappedSize` 本来就不缩。
    private var resolutionSelection: Binding<ResolutionLimit> {
        Binding(
            get: {
                resolutionOptions.contains(exporter.settings.resolution)
                    ? exporter.settings.resolution : .original
            },
            set: { exporter.settings.resolution = $0 }
        )
    }

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        VStack(spacing: 0) {
            header
            Divider()
            Form {
                Section {
                    titleRow
                    if showsReplaceHint {
                        Label(
                            String(
                                format: L10n("“%@” is already in this folder. Exporting will replace it."),
                                outputURL.lastPathComponent
                            ),
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                    folderRow
                    if !isAudioOnly { resolutionRow }
                }
                // 只出声音（.m4a）就没有画面可烧，这一行也不该出现。
                if exportState.subtitle != nil, !isAudioOnly {
                    Section {
                        SubtitleBurnInToggle(options: $subtitleOptions, exportState: exportState)
                    }
                }
                Section { advancedHeader }
                if advancedExpanded {
                    EncodeSettingsSections(
                        settings: $exporter.settings,
                        pipeline: isAudioOnly ? .timelineAudioOnly : .timeline
                    )
                    if exportState.subtitle != nil {
                        Section("Subtitle files") {
                            SubtitleFilesExport(
                                options: $subtitleOptions, exportState: exportState,
                                folder: folder, stem: stem
                            )
                        }
                    }
                    Section {
                        Button("Restore Defaults") { exporter.restoreDefaultAdvancedSettings() }
                            .disabled(exporter.advancedSettingsAreDefault)
                            .instantHelp("Put every advanced setting back to its default")
                    }
                }
            }
            .formStyle(.grouped)
            // 导出途中改了也不作数（参数在开始那一刻就定了），干脆锁住，免得误会。
            .disabled(exporter.isExporting)
            Divider()
            footer
        }
        .frame(width: 420)
        .onAppear {
            fontCatalog.loadIfNeeded()
            if let saved = exporter.titleOverride, saved.generation == project.documentGeneration {
                title = saved.title
            } else {
                title = defaultTitle
            }
        }
        .onChange(of: title) { _, newValue in
            // 只记用户改过的；和默认一样就不记，工程改名时标题才会跟着走。
            exporter.titleOverride = newValue == defaultTitle
                ? nil : (project.documentGeneration, newValue)
        }
        .onExitCommand { dismiss() }
        .alert(
            Text(verbatim: String(format: L10n("Replace “%@”?"), outputURL.lastPathComponent)),
            isPresented: $confirmsReplace
        ) {
            Button("Replace", role: .destructive) { startExport() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(verbatim: String(
                format: L10n("A file with this name is already in “%@”. Replacing it overwrites its contents."),
                folder.lastPathComponent
            ))
        }
    }

    // MARK: - 顶栏

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Export Video").font(.headline)
                Spacer()
                Text(MediaFormatting.duration(exportState.duration))
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if !project.selectedClipIDs.isEmpty {
                Picker("", selection: $selectionOnly) {
                    Text("Full timeline").tag(false)
                    Text(String(format: L10n("Selected only (%d)"), project.selectedClipIDs.count))
                        .tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(exporter.isExporting)
                if selectionOnly, isAudioOnly {
                    Text("Only audio is selected, so this exports an audio file (.m4a).")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(14)
    }

    // MARK: - 主区三行

    private var titleRow: some View {
        LabeledContent("Title") {
            HStack(spacing: 4) {
                TextField("", text: $title, prompt: Text(verbatim: defaultTitle))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
                    .labelsHidden()
                // 扩展名不归用户填：只导音频时自动变 .m4a。
                Text(verbatim: "." + fileExtension)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var folderRow: some View {
        LabeledContent("Export to") {
            HStack(spacing: 6) {
                // 封住理想宽度：长路径从中间截断，这一行不至于被挤成上下两行。
                Text(verbatim: (folder.path as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 230, alignment: .trailing)
                    .instantHelp(verbatim: folder.path)
                Button {
                    if let chosen = FilePicker.chooseDirectory(startingAt: folder) {
                        exporter.exportFolder = chosen
                    }
                } label: {
                    Image(systemName: "folder")
                }
                .instantHelp("Choose the folder to export into")
            }
        }
    }

    private var resolutionRow: some View {
        LabeledContent("Resolution") {
            HStack(spacing: 8) {
                Picker("Resolution", selection: resolutionSelection) {
                    Text(verbatim: String(
                        format: L10n("Same as project (%d×%d)"), canvas.width, canvas.height
                    ))
                    .tag(ResolutionLimit.original)
                    ForEach(resolutionOptions, id: \.self) { option in
                        Text(verbatim: resolutionLabel(option)).tag(option)
                    }
                }
                .labelsHidden()
                .fixedSize()
                Text(verbatim: String(format: L10n("%d fps"), project.state.frameRate.fps))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .instantHelp("The frame rate follows the project")
            }
        }
    }

    private func resolutionLabel(_ option: ResolutionLimit) -> String {
        let size = option.cappedSize(width: canvas.width, height: canvas.height)
            ?? (canvas.width, canvas.height)
        return String(format: L10n("%@ (%d×%d)"), L10n(option.displayName), size.width, size.height)
    }

    // MARK: - 高级

    /// 收着的时候右边一行摘要：改过的参数藏在里面也看得见（面板会记住上次的设置）。
    private var advancedHeader: some View {
        Button {
            advancedExpanded.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(advancedExpanded ? 90 : 0))
                Text("Advanced")
                Spacer(minLength: 12)
                Text(verbatim: advancedSummary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .instantHelp(
            advancedExpanded
                ? LocalizedStringKey("Hide the advanced settings")
                : LocalizedStringKey("Show the advanced settings")
        )
    }

    /// 和高级区里显示的是同一批设置：只导音频时只剩码率。
    private var advancedSummary: String {
        let settings = exporter.settings
        var parts: [String] = []
        if !isAudioOnly {
            switch settings.encoder {
            case .softwareCRF:
                parts.append(String(format: L10n("H.264 CRF %d"), settings.crf))
                parts.append(L10n(settings.preset.displayName))
            case .hardware:
                parts.append(String(format: L10n("Hardware, quality %d"), settings.hardwareQuality))
            }
        }
        parts.append(String(format: L10n("AAC %d kbps"), settings.audio.kbps))
        if !isAudioOnly {
            if !settings.fastStart { parts.append(L10n("Not optimised for web")) }
            if settings.stripMetadata { parts.append(L10n("Metadata stripped")) }
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - 底栏

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if exporter.isExporting {
                ProgressView(value: exporter.progress) {
                    Text(String(format: L10n("Exporting… %@"), MediaFormatting.percent(exporter.progress)))
                        .font(.caption)
                }
            }
            if let error = exporter.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .lineLimit(4)
            }
            if let finished = exporter.finishedURL {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(finished.lastPathComponent)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Show in Finder") { revealInFinder(finished) }
                        .instantHelp("Reveal the exported file in Finder")
                        .controlSize(.small)
                }
            }

            HStack {
                Button("Close") { dismiss() }
                    .instantHelp("Close the export panel")
                Spacer()
                if exporter.isExporting {
                    Button("Stop") { exporter.cancel() }
                        .instantHelp("Cancel the export")
                } else {
                    Button {
                        requestExport()
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(project.state.mainClips.isEmpty)
                    .instantHelp("Render the timeline to a video file", shortcut: .defaultAction)
                }
            }
        }
        .padding(14)
    }

    // MARK: - 动作

    /// 目标已经有同名文件就先问一句（和系统保存面板一样）；没有就直接开始。
    private func requestExport() {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            confirmsReplace = true
        } else {
            startExport()
        }
    }

    private func startExport() {
        var state = exportState
        // 烧录矩阵：按眼睛把 subtitle 换成要烧的文档，关掉烧录就清掉。只出声音时
        // 没有画面可烧（面板上也没有那一行），同样清掉。
        state.subtitle = isAudioOnly ? nil : subtitleOptions.burnDocument(state: state)
        // 这次用的文件夹就是「上次导出的文件夹」，下次打开面板还在这儿。
        exporter.exportFolder = folder
        exporter.export(
            state: state,
            to: outputURL,
            subtitleStyle: burnInQueue.burnInStyle,
            subtitleFontURL: fontCatalog.font(named: burnInQueue.burnInStyle.fontName)?.fileURL
        )
    }
}
