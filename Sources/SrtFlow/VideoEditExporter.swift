import AppKit
import CoreGraphics
import SwiftUI
import UniformTypeIdentifiers
import SrtFlowCore

/// 把时间线导出成 mp4。
///
/// 整个画面走一张 filter_complex 图：每段 trim + 变速（atempo 保音调），
/// 转场用 xfade（fadeblack / fade / fadewhite，和预览的时间账一致），
/// 画中画用 overlay，形状渲成整幅透明 PNG 按时间叠上去，字幕最后烧。
@MainActor
final class VideoEditExporter: ObservableObject {
    static let shared = VideoEditExporter()

    @Published private(set) var isExporting = false
    @Published private(set) var progress: Double = 0
    @Published var errorMessage: String?
    @Published private(set) var finishedURL: URL?
    @Published var settings = VideoEncodeSettings.default

    private var process: FFmpegProcess?
    private var workspace: URL?
    private var cancellationToken: ExportCancellationToken?

    private init() {}

    func export(state: TimelineState, to output: URL, subtitleStyle: BurnInStyle, subtitleFontURL: URL?) {
        guard !isExporting else { return }
        guard let runtime = MediaToolchain.shared.runtime else {
            errorMessage = L10n("The video engine is not ready yet.")
            return
        }
        errorMessage = nil
        finishedURL = nil
        progress = 0
        isExporting = true

        let token = ExportCancellationToken()
        cancellationToken = token

        Task {
            do {
                let plan = try await VideoEditExportGraph.plan(
                    state: state,
                    settings: settings,
                    subtitleStyle: subtitleStyle,
                    subtitleFontURL: subtitleFontURL,
                    output: output,
                    cancellation: token
                )
                workspace = plan.workspace
                // 预渲染和 ffmpeg 起跑之间有条窄缝：Stop 恰好点在这中间也要认。
                if token.isCancelled { throw CancellationError() }

                let ffmpeg = FFmpegProcess()
                process = ffmpeg
                let duration = plan.totalDuration
                try await ffmpeg.run(
                    executable: runtime.url,
                    arguments: plan.arguments,
                    workingDirectory: plan.workspace
                ) { [weak self] update in
                    guard let self else { return }
                    if let fraction = update.fraction(duration: duration) {
                        self.progress = fraction
                    }
                }
                // ffmpeg 成功返回和这里之间也有一条窄缝：ffmpeg 进程已经退出，
                // process.cancel() 这时已经不管用了，得靠 token 再认一次——
                // 不然临场点 Stop 会被吞掉，文件照样被替换。
                if token.isCancelled { throw CancellationError() }
                // ffmpeg 退出码 0 之后才碰用户目标：先落到 workspace 里的临时
                // 文件，这里再原子替换过去——预渲染或 ffmpeg 中途任何失败都
                // 还没碰过 output，用户原有文件（覆盖导出场景）不会被牵连。
                guard FileManager.default.fileExists(atPath: plan.tempOutput.path) else {
                    throw VideoEditExportGraph.PlanError(
                        message: L10n("ffmpeg finished but produced no output file.")
                    )
                }
                if FileManager.default.fileExists(atPath: output.path) {
                    _ = try FileManager.default.replaceItemAt(output, withItemAt: plan.tempOutput)
                } else {
                    try FileManager.default.moveItem(at: plan.tempOutput, to: output)
                }
                progress = 1
                finishedURL = output
            } catch is CancellationError {
                // 用户点了 Stop（预渲染或 ffmpeg 阶段）：临时产物随 workspace
                // 一起清掉，不设 errorMessage，也不碰用户原有文件。
            } catch FFmpegProcessError.cancelled {
            } catch {
                errorMessage = error.localizedDescription
            }
            if let workspace { try? FileManager.default.removeItem(at: workspace) }
            workspace = nil
            process = nil
            cancellationToken = nil
            isExporting = false
        }
    }

    func cancel() {
        cancellationToken?.cancel()
        process?.cancel()
    }
}

// MARK: - 滤镜图


// MARK: - 导出面板

/// 导出弹窗：编码设置 + 输出位置 + 进度。
struct VideoEditExportSheet: View {
    @ObservedObject var project: VideoEditProject
    @ObservedObject var exporter: VideoEditExporter
    @ObservedObject private var burnInQueue = EncodeQueue.burnIn
    @StateObject private var fontCatalog = FontCatalogStore.shared
    @Environment(\.dismiss) private var dismiss

    /// 只导出选中的内容（单段、多段、纯音频都行）。
    @State private var selectionOnly = false
    /// 字幕矩阵：烧录轨道选择 + 独立文件（SubtitleGen/SubtitleExportSection.swift）。
    @State private var subtitleOptions = SubtitleExportOptions()

    private var exportState: TimelineState {
        project.stateForExport(selectionOnly: selectionOnly && !project.selectedClipIDs.isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
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
                    if selectionOnly, VideoEditExportGraph.isAudioOnly(exportState) {
                        Text("Only audio is selected, so this exports an audio file (.m4a).")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(14)

            Divider()

            // 剪辑导出不消费分辨率/帧率上限：输出规格由工程画布和工程帧率决定，
            // 显示可调控件等于给不存在的承诺（计划 §3.3）。改为在下面明示规格。
            EncodeSettingsView(settings: $exporter.settings, showsScalingLimits: false)

            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                Text(String(
                    format: L10n("Output follows the project: %d×%d, %d fps."),
                    Int(project.renderSize.width), Int(project.renderSize.height),
                    project.state.frameRate.fps
                ))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                SubtitleExportSection(
                    project: project, options: $subtitleOptions, exportState: exportState
                )
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
                    Button("Close") {
                        dismiss()
                    }
                    .instantHelp("Close the export panel")
                    Spacer()
                    if exporter.isExporting {
                        Button("Stop") { exporter.cancel() }
                    .instantHelp("Cancel the export")
                    } else {
                        Button {
                            startExport()
                        } label: {
                            Label("Export…", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(project.state.mainClips.isEmpty)
                        .instantHelp("Render the timeline to a video file")
                    }
                }
            }
            .padding(14)
        }
        .frame(width: 400)
        .onAppear { fontCatalog.loadIfNeeded() }
    }

    private func startExport() {
        var state = exportState
        // 烧录矩阵：按选择把 subtitle 换成合成文档（原文/译文/双语），选无则清掉。
        state.subtitle = subtitleOptions.burnDocument(state: state)
        let audioOnly = VideoEditExportGraph.isAudioOnly(state)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [audioOnly ? .mpeg4Audio : .mpeg4Movie]
        panel.nameFieldStringValue = suggestedName(for: state, audioOnly: audioOnly)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exporter.export(
            state: state,
            to: url,
            subtitleStyle: burnInQueue.burnInStyle,
            subtitleFontURL: fontCatalog.font(named: burnInQueue.burnInStyle.fontName)?.fileURL
        )
    }

    private func suggestedName(for state: TimelineState, audioOnly: Bool) -> String {
        let base = state.mainClips.first?.name
            ?? state.audioTracks.first?.clips.first?.name
            ?? "Timeline"
        return audioOnly ? "\(base)_audio.m4a" : "\(base)_edit.mp4"
    }
}
