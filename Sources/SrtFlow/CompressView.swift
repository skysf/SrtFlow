import SwiftUI
import SrtFlowCore

/// 压缩视频：拖一堆视频进来排队，在不明显损失画质的前提下把体积压下去。
struct CompressView: View {
    @StateObject private var queue = EncodeQueue(outputSuffix: "_compressed")
    @StateObject private var toolchain = MediaToolchain.shared
    @StateObject private var handoff = CompressHandoff.shared
    // 这个视图在代码里拼字符串（L10n(...)），不是纯 LocalizedStringKey，
    // 光靠环境 locale 变化不会重新求值 body，所以要显式观察语言选择。
    @ObservedObject private var languageStore = AppLanguageStore.shared

    /// 设置存在 UserDefaults 里，下次打开还是上次那套。
    @AppStorage("compressSettings") private var storedSettings = ""

    var body: some View {
        HSplitView {
            queueSide
                .frame(minWidth: 420, idealWidth: 560, maxWidth: .infinity)
            settingsSide
                .frame(minWidth: 340, idealWidth: 380, maxWidth: 460)
        }
        .frame(minWidth: 820, minHeight: 520)
        .onAppear {
            toolchain.resolveIfNeeded()
            restoreSettings()
            takeHandoff()
        }
        .onChange(of: handoff.pendingVideos) { _, _ in takeHandoff() }
        .onChange(of: queue.settings) { _, _ in persistSettings() }
        .onDropOfFiles { urls in add(urls) }
    }

    // MARK: - 左侧：队列

    private var queueSide: some View {
        VStack(spacing: 0) {
            EncodeQueueListView(
                queue: queue,
                emptyPrompt: "Drop videos here to compress them.\nEach one keeps its own progress and size saving.",
                onAddFiles: chooseFiles
            )
            Divider()
            footer
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            OutputLocationPicker(queue: queue)

            HStack(spacing: 10) {
                Button("Add Files…", action: chooseFiles)

                if queue.isRunning {
                    Button("Stop All") { queue.cancelAll() }
                } else {
                    Button {
                        queue.start()
                    } label: {
                        Label(startTitle, systemImage: "play.fill")
                    }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(!queue.canStart)
                }

                Button("Clear Finished") { queue.clearFinished() }
                    .disabled(!queue.items.contains(where: \.isDone))

                Spacer()

                if let summary = totalSummary {
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
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

    private var startTitle: LocalizedStringKey {
        queue.waitingCount > 1 ? "Compress \(queue.waitingCount) Videos" : "Compress"
    }

    /// 全部完成后汇总一下总共省了多少。
    private var totalSummary: String? {
        let finished = queue.items.filter { $0.status == .finished }
        guard !finished.isEmpty else { return nil }
        let original = finished.compactMap { $0.info?.fileBytes }.reduce(0, +)
        let output = finished.compactMap(\.outputBytes).reduce(0, +)
        guard original > 0 else { return nil }
        let saving = 1 - Double(output) / Double(original)
        return String(
            format: L10n("%d done · %@ → %@ · %@"),
            finished.count,
            MediaFormatting.bytes(original),
            MediaFormatting.bytes(output),
            MediaFormatting.saving(saving)
        )
    }

    // MARK: - 右侧：设置

    private var settingsSide: some View {
        VStack(spacing: 0) {
            EncodeSettingsView(settings: $queue.settings)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                CommandPreview(command: previewCommand, executableName: "ffmpeg")
            }
            .padding(12)
        }
    }

    /// 给命令预览用的样例：优先拿队列里第一个文件，没有就编一个占位名。
    private var previewCommand: FFmpegCommand {
        let sample = queue.items.first
        return FFmpegCommand(
            inputPath: sample?.inputURL.lastPathComponent ?? "input.mp4",
            outputPath: sample?.outputURL.lastPathComponent ?? "input_compressed.mp4",
            settings: queue.settings,
            hasAudio: sample?.info?.hasAudio ?? true,
            audioCanCopy: sample?.info?.audioCanCopyToMP4 ?? true,
            sourceHeight: sample?.info?.height ?? 1080,
            sourceFrameRate: sample?.info?.frameRate
        )
    }

    // MARK: - 动作

    private func chooseFiles() {
        add(FilePicker.chooseFiles(types: MediaFileTypes.video))
    }

    private func add(_ urls: [URL]) {
        let videos = urls.filter(MediaFileTypes.isVideo)
        guard !videos.isEmpty else { return }
        queue.add(urls: videos)
    }

    private func takeHandoff() {
        let staged = handoff.take()
        if !staged.isEmpty { queue.add(urls: staged) }
    }

    // MARK: - 设置持久化

    private func persistSettings() {
        guard let data = try? JSONEncoder().encode(queue.settings) else { return }
        storedSettings = String(decoding: data, as: UTF8.self)
    }

    private func restoreSettings() {
        guard !storedSettings.isEmpty,
              let decoded = try? JSONDecoder().decode(VideoEncodeSettings.self, from: Data(storedSettings.utf8))
        else { return }
        queue.settings = decoded
    }
}
