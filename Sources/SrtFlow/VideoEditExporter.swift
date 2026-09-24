import AppKit
import CoreGraphics
import SwiftUI
import SrtFlowCore

/// 把时间线导出成 mp4。
///
/// 整个画面走一张 filter_complex 图：每段 trim + 变速（atempo 保音调），
/// 转场用 xfade（fadeblack / fade / fadewhite，和预览的时间账一致），
/// 上层视频轨用 overlay，形状渲成整幅透明 PNG 按时间叠上去，字幕最后烧。
@MainActor
final class VideoEditExporter: ObservableObject {
    static let shared = VideoEditExporter()

    @Published private(set) var isExporting = false
    @Published private(set) var progress: Double = 0
    @Published var errorMessage: String?
    @Published private(set) var finishedURL: URL?

    /// 编码设置（含导出分辨率）。**记住上次的**，下次打开还是它
    /// （docs/plans/2026-09-24-export-panel.md）；设错了用「恢复默认设置」。
    @Published var settings: VideoEncodeSettings {
        didSet { Self.store(settings) }
    }

    /// 上次导出、或手动选过的文件夹。全局只记一个；用之前先看 `usableExportFolder`。
    @Published var exportFolder: URL? {
        didSet { UserDefaults.standard.set(exportFolder?.path, forKey: Keys.folder) }
    }

    /// 用户在这个工程里改过的标题，按工程代号（`documentGeneration`）认：换了工程
    /// 就回到工程名。只放内存，不进工程文件 —— 它不是画面数据，不值得动格式版本。
    var titleOverride: (generation: Int, title: String)?

    private var process: FFmpegProcess?
    private var workspace: URL?
    private var cancellationToken: ExportCancellationToken?

    private enum Keys {
        static let settings = "videoEditExportSettings"
        static let folder = "videoEditExportFolder"
    }

    private init() {
        let defaults = UserDefaults.standard
        settings = defaults.data(forKey: Keys.settings)
            .flatMap { try? JSONDecoder().decode(VideoEncodeSettings.self, from: $0) }
            ?? .default
        exportFolder = defaults.string(forKey: Keys.folder).map { URL(fileURLWithPath: $0) }
    }

    private static func store(_ settings: VideoEncodeSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: Keys.settings)
    }

    /// 记住的文件夹还在就用它；被删了、外接盘拔了就当没记过。
    var usableExportFolder: URL? {
        guard let folder = exportFolder else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return folder
    }

    /// 「恢复默认设置」只管高级区里那些；分辨率在面板外面、看得见，不动它。
    func restoreDefaultAdvancedSettings() {
        settings = advancedDefaults
    }

    var advancedSettingsAreDefault: Bool { settings == advancedDefaults }

    private var advancedDefaults: VideoEncodeSettings {
        var defaults = VideoEncodeSettings.default
        defaults.resolution = settings.resolution
        return defaults
    }

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
