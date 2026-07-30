import AppKit
import SwiftUI
import SrtFlowCore

/// 样式预览：直接让 ffmpeg 在真实画面上烧出一帧。
///
/// 没有用 SwiftUI/Core Text 去模拟一遍 ASS 的排版 —— 模拟永远对不齐真实结果，
/// 描边粗细、换行位置、行距都会差一点。这里走的是**和导出完全相同的滤镜链**，
/// 所以预览看到的就是成品的样子。代价是每次要起一次 ffmpeg，所以做了防抖。
@MainActor
final class BurnInPreviewRenderer: ObservableObject {
    /// 和两个编码队列一样是全局的：切走烧字幕那一栏时视图会被销毁，渲染好的
    /// 那一帧留在这里，切回来就不用再等一次 ffmpeg。
    static let shared = BurnInPreviewRenderer()

    @Published private(set) var image: NSImage?
    @Published private(set) var isRendering = false
    @Published private(set) var errorMessage: String?
    /// 预览取第几条字幕。它得和上面那张图一起活着，否则切回来时步进器显示
    /// 「1 / N」而画面其实是第 4 条 —— 对不上。
    @Published var cueIndex = 0

    /// 有没有东西可显示。切回栏目时用它判断要不要重新渲染。
    var hasContent: Bool { image != nil || errorMessage != nil || isRendering }

    private var pendingTask: Task<Void, Never>?
    private var currentProcess: FFmpegProcess?

    /// 样式一动就会被调用，所以先等 250ms，中途再有新请求就把上一个丢掉。
    private let debounceNanoseconds: UInt64 = 250_000_000

    struct Request {
        var video: URL
        var info: MediaInfo
        var cues: [SubtitleCue]
        var style: BurnInStyle
        var fontFileURL: URL?
        var timeSeconds: Double
    }

    func request(_ request: Request) {
        pendingTask?.cancel()
        currentProcess?.cancel()

        pendingTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: debounceNanoseconds)
            guard !Task.isCancelled else { return }
            await self.render(request)
        }
    }

    func clear() {
        pendingTask?.cancel()
        currentProcess?.cancel()
        image = nil
        errorMessage = nil
        isRendering = false
    }

    private func render(_ request: Request) async {
        guard let runtime = MediaToolchain.shared.runtime, runtime.canBurnInSubtitles else {
            errorMessage = MediaToolchain.shared.warning
            return
        }

        isRendering = true
        defer { isRendering = false }

        let workspace: BurnInWorkspace.Prepared
        do {
            workspace = try BurnInWorkspace.create(
                cues: request.cues,
                style: request.style,
                fontFileURL: request.fontFileURL,
                aspectRatio: request.info.aspectRatio,
                title: "preview"
            )
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        defer { try? FileManager.default.removeItem(at: workspace.directory) }

        let outputURL = workspace.directory.appendingPathComponent("preview.png")
        var command = FFmpegCommand(
            inputPath: request.video.path,
            outputPath: outputURL.lastPathComponent,
            mode: .stillFrame(atSeconds: request.timeSeconds),
            burnIn: workspace.paths,
            sourceHeight: request.info.height
        )
        // 预览要的是「字幕长什么样」，缩放和降帧对这个没有影响，跳过它们，
        // 但分辨率信息仍然保留，画布比例才对得上。
        command.settings.resolution = .original
        command.settings.frameRate = .original

        let process = FFmpegProcess()
        currentProcess = process
        do {
            try await process.run(
                executable: runtime.url,
                arguments: FFmpegArgumentBuilder.arguments(for: command),
                workingDirectory: workspace.directory
            )
        } catch FFmpegProcessError.cancelled {
            return
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        currentProcess = nil

        guard !Task.isCancelled else { return }
        guard let rendered = NSImage(contentsOf: outputURL) else {
            errorMessage = L10n("Could not render the preview frame.")
            return
        }
        image = rendered
        errorMessage = nil
    }
}
