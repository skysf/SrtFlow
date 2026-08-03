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

        Task {
            do {
                let plan = try VideoEditExportGraph.plan(
                    state: state,
                    settings: settings,
                    subtitleStyle: subtitleStyle,
                    subtitleFontURL: subtitleFontURL,
                    output: output
                )
                workspace = plan.workspace

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
                progress = 1
                finishedURL = output
            } catch FFmpegProcessError.cancelled {
                try? FileManager.default.removeItem(at: output)
            } catch {
                errorMessage = error.localizedDescription
                try? FileManager.default.removeItem(at: output)
            }
            if let workspace { try? FileManager.default.removeItem(at: workspace) }
            workspace = nil
            process = nil
            isExporting = false
        }
    }

    func cancel() {
        process?.cancel()
    }
}

// MARK: - 滤镜图

/// 纯函数地把时间线翻译成 ffmpeg 参数。工作目录里放 ASS、字体和形状 PNG。
enum VideoEditExportGraph {

    struct Plan {
        var arguments: [String]
        var workspace: URL
        var totalDuration: Double
        /// 一点画面都没有（只选了音频）：输出纯音频文件。
        var isAudioOnly = false
    }

    /// 这份时间线导出来是不是纯音频（选中导出时给保存面板挑扩展名用）。
    static func isAudioOnly(_ state: TimelineState) -> Bool {
        let mainVisible = state.mainHidden
            ? []
            : state.mainClips.filter { !$0.needsStillConversion }
        let overlayVisible = state.overlayTracks
            .filter { !$0.isHidden }
            .flatMap(\.clips)
            .filter { !$0.needsStillConversion }
        let hasAudio = !state.audioTracks.filter { !$0.isHidden }.flatMap(\.clips).isEmpty
        return mainVisible.isEmpty && overlayVisible.isEmpty && hasAudio
    }

    struct PlanError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// 主轨在时间线上的一节：素材段或需要补的黑场。
    private struct MainSegment {
        var clip: EditClip?
        var duration: Double
        /// 与下一节之间的转场（黑场补出来的节永远是硬切）。
        var transition: ClipTransition = .none
        var transitionDuration: Double = 0
    }

    static func plan(
        state: TimelineState,
        settings: VideoEncodeSettings,
        subtitleStyle: BurnInStyle,
        subtitleFontURL: URL?,
        output: URL
    ) throws -> Plan {
        // 图片段还没转成静帧视频时是进不了成片的。以前这里直接把它们滤掉，
        // 导出会「成功」，但用户的图片凭空消失且毫无提示 —— 宁可拦下来说清楚。
        // 只看真正会进成片的段：藏起来的轨本来就不导出，别拿它拦人。
        let pendingStills = ((state.mainHidden ? [] : state.mainClips)
            + state.overlayTracks.filter { !$0.isHidden }.flatMap(\.clips))
            .filter(\.needsStillConversion)
        if !pendingStills.isEmpty {
            let names = pendingStills
                .map(\.name)
                .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            throw PlanError(message: String(
                format: L10n("These image clips aren’t ready yet: %@. Wait for them to finish, or relink them if the images are missing."),
                names.joined(separator: "、")
            ))
        }

        // 隐藏的轨和还在转静帧的占位块都不进成片。
        let mainVisible = (state.mainHidden ? [] : state.mainClips)
            .filter { !$0.needsStillConversion }
        let overlayLanes = state.overlayTracks.filter { !$0.isHidden }
        let audioLanes = state.audioTracks.filter { !$0.isHidden }
        let overlayVisible = overlayLanes.flatMap(\.clips).filter { !$0.needsStillConversion }
        let audioClips = audioLanes.flatMap(\.clips).filter { !$0.isMuted }

        let hasVisual = !mainVisible.isEmpty || !overlayVisible.isEmpty
        guard hasVisual || !audioClips.isEmpty else {
            throw PlanError(message: L10n("Add at least one clip to the main track first."))
        }

        let renderSize = VideoEditCompositionBuilder.renderSize(for: state)
        let width = Int(renderSize.width)
        let height = Int(renderSize.height)
        let total = state.duration

        // 工作目录：字幕 ASS、字体软链、形状 PNG 都放这儿，进程工作目录设成它。
        let workspace: URL
        if let subtitle = state.subtitle, !subtitle.cues.isEmpty {
            let prepared = try BurnInWorkspace.create(
                cues: subtitle.cues,
                style: subtitleStyle,
                fontFileURL: subtitleFontURL,
                aspectRatio: renderSize.width / max(1, renderSize.height),
                title: state.subtitleURL?.deletingPathExtension().lastPathComponent ?? "SrtFlow"
            )
            workspace = prepared.directory
        } else {
            workspace = FileManager.default.temporaryDirectory
                .appendingPathComponent("SrtFlow-Edit-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        }

        // 形状 → 整幅透明 PNG。
        var shapeFiles: [(shape: ShapeAnnotation, filename: String)] = []
        for (index, shape) in state.shapes.enumerated() {
            let filename = "shape\(index).png"
            guard let png = ShapePNGRenderer.render(shape, canvas: renderSize) else { continue }
            try png.write(to: workspace.appendingPathComponent(filename))
            shapeFiles.append((shape, filename))
        }

        // 输入表：素材文件 + 形状 PNG。
        var inputs: [String] = []
        var inputArguments: [String] = []
        var inputIndex: [String: Int] = [:]
        func input(for url: URL) -> Int {
            if let existing = inputIndex[url.path] { return existing }
            let index = inputs.count
            inputs.append(url.path)
            inputArguments += ["-i", url.path]
            inputIndex[url.path] = index
            return index
        }

        var filters: [String] = []
        var labelCounter = 0
        func nextLabel(_ prefix: String) -> String {
            labelCounter += 1
            return "\(prefix)\(labelCounter)"
        }

        /// 一段音频剪辑的滤镜链（裁剪、变速、音量、落到时间线位置）。
        func audioChain(for clip: EditClip, source: Int, label: String) -> String {
            let end = clip.sourceStart + clip.sourceDuration
            let delay = Int((clip.timelineStart * 1000).rounded())
            return "[\(source):a]atrim=start=\(fmt(clip.sourceStart)):end=\(fmt(end))," +
                "asetpts=PTS-STARTPTS,\(atempoChain(clip.speed))" +
                "volume=\(fmt(clip.volume)),adelay=\(delay)|\(delay),aresample=48000," +
                "aformat=sample_fmts=fltp:channel_layouts=stereo[\(label)]"
        }

        // MARK: 纯音频：只选了声音，出一个音频文件

        if !hasVisual {
            var labels: [String] = []
            for clip in audioClips {
                let label = nextLabel("ta")
                filters.append(audioChain(for: clip, source: input(for: clip.sourceURL), label: label))
                labels.append(label)
            }
            var audioOut = labels[0]
            if labels.count > 1 {
                let mixed = nextLabel("a")
                let all = labels.map { "[\($0)]" }.joined()
                filters.append("\(all)amix=inputs=\(labels.count):duration=longest:normalize=0[\(mixed)]")
                audioOut = mixed
            }
            var args: [String] = ["-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-progress", "pipe:1"]
            args += inputArguments
            args += ["-filter_complex", filters.joined(separator: ";")]
            args += ["-map", "[\(audioOut)]", "-c:a", "aac", "-b:a", "\(settings.audio.kbps)k"]
            args += ["-t", fmt(total)]
            args.append(output.path)
            return Plan(arguments: args, workspace: workspace, totalDuration: total, isAudioOnly: true)
        }

        // MARK: 主轨分节（素材 + 黑场补隙 + 结尾补到总长）

        var segments: [MainSegment] = []
        var cursor = 0.0
        let ordered = mainVisible.sorted { $0.timelineStart < $1.timelineStart }
        for (index, clip) in ordered.enumerated() {
            if clip.timelineStart > cursor + 0.01 {
                segments.append(MainSegment(clip: nil, duration: clip.timelineStart - cursor))
            }
            var segment = MainSegment(clip: clip, duration: clip.timelineDuration)
            // 转场只在两段实际首尾相叠时成立（磁吸排出来的就是这样）。
            if index + 1 < ordered.count, clip.transitionAfter != .none {
                let next = ordered[index + 1]
                let overlap = min(
                    clip.transitionDuration,
                    clip.timelineDuration * 0.45,
                    next.timelineDuration * 0.45
                )
                if overlap > 0.01, abs(next.timelineStart - (clip.timelineEnd - overlap)) < 0.02 {
                    segment.transition = clip.transitionAfter
                    segment.transitionDuration = overlap
                }
            }
            segments.append(segment)
            cursor = max(cursor, clip.timelineEnd)
        }
        if total > cursor + 0.01 {
            segments.append(MainSegment(clip: nil, duration: total - cursor))
        }

        // MARK: 每节的视频/音频流

        var segmentLabels: [(video: String, audio: String, duration: Double)] = []
        for segment in segments {
            let vLabel = nextLabel("v")
            let aLabel = nextLabel("a")
            if let clip = segment.clip {
                let source = input(for: clip.sourceURL)
                let end = clip.sourceStart + clip.sourceDuration
                if let placement = clip.placement {
                    // 用户摆过的主轨段：缩放到摆放框，再叠到黑底画布上。
                    // 用 overlay 而不是 pad —— 框可以比画布大、也可以探出边界。
                    let target = placement.frame(in: renderSize)
                    let fg = nextLabel("fg")
                    let bg = nextLabel("bg")
                    filters.append(
                        "[\(source):v]trim=start=\(fmt(clip.sourceStart)):end=\(fmt(end))," +
                        "setpts=(PTS-STARTPTS)/\(fmt(clip.speed)),fps=30," +
                        "scale=\(evenPixel(target.width)):\(evenPixel(target.height)),setsar=1[\(fg)]"
                    )
                    filters.append(
                        "color=black:s=\(width)x\(height):r=30:d=\(fmt(segment.duration))[\(bg)]"
                    )
                    filters.append(
                        "[\(bg)][\(fg)]overlay=x=\(Int(target.minX.rounded())):y=\(Int(target.minY.rounded())):" +
                        "shortest=1,format=yuv420p[\(vLabel)]"
                    )
                } else {
                    filters.append(
                        "[\(source):v]trim=start=\(fmt(clip.sourceStart)):end=\(fmt(end))," +
                        "setpts=(PTS-STARTPTS)/\(fmt(clip.speed)),fps=30," +
                        "scale=\(width):\(height):force_original_aspect_ratio=decrease," +
                        "pad=\(width):\(height):(ow-iw)/2:(oh-ih)/2,setsar=1,format=yuv420p[\(vLabel)]"
                    )
                }
                if clip.hasAudio, !clip.isMuted {
                    filters.append(
                        "[\(source):a]atrim=start=\(fmt(clip.sourceStart)):end=\(fmt(end))," +
                        "asetpts=PTS-STARTPTS,\(atempoChain(clip.speed))" +
                        "volume=\(fmt(clip.volume)),aresample=48000," +
                        "aformat=sample_fmts=fltp:channel_layouts=stereo[\(aLabel)]"
                    )
                } else {
                    filters.append(
                        "anullsrc=r=48000:cl=stereo,atrim=0:\(fmt(segment.duration))[\(aLabel)]"
                    )
                }
            } else {
                filters.append(
                    "color=black:s=\(width)x\(height):r=30:d=\(fmt(segment.duration)),format=yuv420p[\(vLabel)]"
                )
                filters.append(
                    "anullsrc=r=48000:cl=stereo,atrim=0:\(fmt(segment.duration))[\(aLabel)]"
                )
            }
            segmentLabels.append((vLabel, aLabel, segment.duration))
        }

        // MARK: 顺次拼接：硬切用 concat，转场用 xfade + acrossfade

        var video = segmentLabels[0].video
        var audio = segmentLabels[0].audio
        var accumulated = segmentLabels[0].duration
        for index in 1..<segmentLabels.count {
            let next = segmentLabels[index]
            let boundary = segments[index - 1]
            let outV = nextLabel("v")
            let outA = nextLabel("a")
            if boundary.transition != .none, let xfade = boundary.transition.xfadeName {
                let d = boundary.transitionDuration
                let offset = accumulated - d
                filters.append(
                    "[\(video)][\(next.video)]xfade=transition=\(xfade):duration=\(fmt(d)):offset=\(fmt(offset))[\(outV)]"
                )
                filters.append(
                    "[\(audio)][\(next.audio)]acrossfade=d=\(fmt(d)):c1=tri:c2=tri[\(outA)]"
                )
                accumulated = accumulated + next.duration - d
            } else {
                filters.append("[\(video)][\(next.video)]concat=n=2:v=1:a=0[\(outV)]")
                filters.append("[\(audio)][\(next.audio)]concat=n=2:v=0:a=1[\(outA)]")
                accumulated += next.duration
            }
            video = outV
            audio = outA
        }

        // MARK: 画中画

        var mixInputs: [String] = []
        for lane in overlayLanes {
            for clip in lane.clips where !clip.needsStillConversion {
                let source = input(for: clip.sourceURL)
                let end = clip.sourceStart + clip.sourceDuration
                let scaled = nextLabel("ov")
                // 摆过的画中画按摆放框缩放定位；没摆过走九宫格表达式。
                let scaleFilter: String
                let x: String
                let y: String
                if let placement = clip.placement {
                    let target = placement.frame(in: renderSize)
                    scaleFilter = "scale=\(evenPixel(target.width)):\(evenPixel(target.height))"
                    x = "\(Int(target.minX.rounded()))"
                    y = "\(Int(target.minY.rounded()))"
                } else {
                    let overlayWidth = Int((renderSize.width * clip.overlayFraction / 2).rounded() * 2)
                    scaleFilter = "scale=\(overlayWidth):-2"
                    let inset = Int(renderSize.width * 0.02)
                    x = xExpression(for: clip.overlayAnchor, inset: inset)
                    y = yExpression(for: clip.overlayAnchor, inset: inset)
                }
                filters.append(
                    "[\(source):v]trim=start=\(fmt(clip.sourceStart)):end=\(fmt(end))," +
                    "setpts=(PTS-STARTPTS)/\(fmt(clip.speed)),fps=30," +
                    "\(scaleFilter),setsar=1," +
                    "setpts=PTS+\(fmt(clip.timelineStart))/TB[\(scaled)]"
                )
                let outV = nextLabel("v")
                filters.append(
                    "[\(video)][\(scaled)]overlay=x=\(x):y=\(y):eof_action=pass:" +
                    "enable='between(t,\(fmt(clip.timelineStart)),\(fmt(clip.timelineEnd)))'[\(outV)]"
                )
                video = outV

                if clip.hasAudio, !clip.isMuted {
                    let aLabel = nextLabel("oa")
                    filters.append(audioChain(for: clip, source: source, label: aLabel))
                    mixInputs.append(aLabel)
                }
            }
        }

        // MARK: 音频轨

        for clip in audioClips {
            let aLabel = nextLabel("ta")
            filters.append(audioChain(for: clip, source: input(for: clip.sourceURL), label: aLabel))
            mixInputs.append(aLabel)
        }

        if !mixInputs.isEmpty {
            let outA = nextLabel("a")
            let all = ([audio] + mixInputs).map { "[\($0)]" }.joined()
            filters.append(
                "\(all)amix=inputs=\(mixInputs.count + 1):duration=longest:normalize=0[\(outA)]"
            )
            audio = outA
        }

        // MARK: 形状

        for (shape, filename) in shapeFiles {
            // -loop 1 让单帧 PNG 变成持续的流，enable 控制何时可见。
            inputArguments += ["-loop", "1", "-t", fmt(total), "-i", filename]
            let shapeInput = inputs.count
            inputs.append(filename)

            let outV = nextLabel("v")
            filters.append(
                "[\(video)][\(shapeInput):v]overlay=x=0:y=0:eof_action=pass:" +
                "enable='between(t,\(fmt(shape.timelineStart)),\(fmt(shape.timelineEnd)))'[\(outV)]"
            )
            video = outV
        }

        // MARK: 字幕（最后烧，压在所有画面之上）

        if let subtitle = state.subtitle, !subtitle.cues.isEmpty {
            let paths = FFmpegCommand.BurnIn()
            let outV = nextLabel("v")
            filters.append(
                "[\(video)]subtitles=filename=\(paths.assFileName):fontsdir=\(paths.fontsDirName)[\(outV)]"
            )
            video = outV
        }

        // MARK: 组装参数

        var args: [String] = ["-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-progress", "pipe:1"]
        args += inputArguments
        args += ["-filter_complex", filters.joined(separator: ";")]
        args += ["-map", "[\(video)]", "-map", "[\(audio)]"]

        switch settings.encoder {
        case .softwareCRF:
            args += [
                "-c:v", "libx264",
                "-crf", String(settings.crf),
                "-preset", settings.preset.rawValue,
                "-pix_fmt", "yuv420p"
            ]
        case .hardware:
            args += [
                "-c:v", "h264_videotoolbox",
                "-q:v", String(settings.hardwareQuality),
                "-spatial_aq", "1",
                "-pix_fmt", "yuv420p"
            ]
        }
        args += ["-c:a", "aac", "-b:a", "\(settings.audio.kbps)k"]
        if settings.stripMetadata { args += ["-map_metadata", "-1"] }
        if settings.fastStart { args += ["-movflags", "+faststart"] }
        args += ["-t", fmt(total)]
        args.append(output.path)

        return Plan(arguments: args, workspace: workspace, totalDuration: total)
    }

    // MARK: 小工具

    /// 摆放框的像素尺寸收成正偶数：yuv420 要偶数，scale 不吃 0。
    private static func evenPixel(_ value: Double) -> Int {
        max(2, Int((value / 2).rounded()) * 2)
    }

    /// `30.0` → `"30"`，`1.2345` → `"1.234"`。滤镜参数里别出现一长串小数。
    private static func fmt(_ value: Double) -> String {
        let rounded = (value * 1000).rounded() / 1000
        if rounded.truncatingRemainder(dividingBy: 1) == 0 {
            return String(Int(rounded))
        }
        return String(format: "%g", rounded)
    }

    /// atempo 只吃 0.5–2，之外的倍速拆成一串。返回内容自带结尾逗号。
    static func atempoChain(_ speed: Double) -> String {
        var remaining = speed
        guard abs(remaining - 1) > 0.001 else { return "" }
        var factors: [Double] = []
        while remaining > 2.0 {
            factors.append(2)
            remaining /= 2
        }
        while remaining < 0.5 {
            factors.append(0.5)
            remaining /= 0.5
        }
        factors.append(remaining)
        return factors.map { "atempo=\(fmt($0))" }.joined(separator: ",") + ","
    }

    private static func xExpression(for anchor: OverlayAnchor, inset: Int) -> String {
        switch anchor.column {
        case 0: return "\(inset)"
        case 1: return "(W-w)/2"
        default: return "W-w-\(inset)"
        }
    }

    private static func yExpression(for anchor: OverlayAnchor, inset: Int) -> String {
        switch anchor.row {
        case 0: return "\(inset)"
        case 1: return "(H-h)/2"
        default: return "H-h-\(inset)"
        }
    }
}

// MARK: - 形状 PNG

/// 把一个形状按输出尺寸渲成整幅透明 PNG，位置和预览里画的一致。
enum ShapePNGRenderer {
    static func render(_ shape: ShapeAnnotation, canvas: CGSize) -> Data? {
        let width = Int(canvas.width)
        let height = Int(canvas.height)
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }

        // CG 的原点在左下，翻一下让坐标和预览（左上原点）一致。
        context.translateBy(x: 0, y: canvas.height)
        context.scaleBy(x: 1, y: -1)

        let color = CGColor(
            srgbRed: shape.color.red,
            green: shape.color.green,
            blue: shape.color.blue,
            alpha: shape.color.opacity
        )
        let strokeWidth = max(0.5, shape.lineWidth * canvas.height / 1080)
        let frame = shape.frame(in: canvas)

        switch shape.kind {
        case .line:
            context.saveGState()
            context.translateBy(x: frame.midX, y: frame.midY)
            context.rotate(by: shape.rotationDegrees * .pi / 180)
            context.setStrokeColor(color)
            context.setLineWidth(strokeWidth)
            context.setLineCap(.round)
            context.move(to: CGPoint(x: -frame.width / 2, y: 0))
            context.addLine(to: CGPoint(x: frame.width / 2, y: 0))
            context.strokePath()
            context.restoreGState()
        case .rectangle, .square:
            context.setStrokeColor(color)
            context.setLineWidth(strokeWidth)
            // 预览用的是 strokeBorder（描边全在框内），这里也往里收半个线宽。
            context.stroke(frame.insetBy(dx: strokeWidth / 2, dy: strokeWidth / 2))
        }

        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

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

            EncodeSettingsView(settings: $exporter.settings)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                if project.state.subtitle != nil {
                    Label("Subtitles are burned in with the Burn In tool's current style.", systemImage: "captions.bubble")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
                            .controlSize(.small)
                    }
                }

                HStack {
                    Button("Close") {
                        dismiss()
                    }
                    Spacer()
                    if exporter.isExporting {
                        Button("Stop") { exporter.cancel() }
                    } else {
                        Button {
                            startExport()
                        } label: {
                            Label("Export…", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(project.state.mainClips.isEmpty)
                    }
                }
            }
            .padding(14)
        }
        .frame(width: 400)
        .onAppear { fontCatalog.loadIfNeeded() }
    }

    private func startExport() {
        let state = exportState
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
