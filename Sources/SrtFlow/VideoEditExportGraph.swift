import AVFoundation
import Foundation
import SrtFlowCore

// 从 VideoEditExporter.swift 拆出来（那个文件已 908 行，超仓库 ~800 行警戒线）。
//
// 拆分的另一个理由更实在：`VideoEditExporter`（@MainActor 的 ObservableObject）
// 和导出 sheet 视图带着 VideoEditProject / EncodeQueue / SwiftUI 一大票依赖，
// 混在一个文件里就没法把这段**纯函数**单独编出来做回归。拆开之后
// `scripts/check-export-frame-rate.sh` 才能直接调 plan() 拿真实 ffmpeg 参数、
// 真跑一遍、数输出帧 —— 这是计划 §17.3 要求的「真实生产滤镜回归」，
// alpha fixture 替代不了它。

/// 纯函数地把时间线翻译成 ffmpeg 参数。工作目录里放 ASS、字体和形状 PNG。
enum VideoEditExportGraph {

    struct Plan {
        var arguments: [String]
        var workspace: URL
        var totalDuration: Double
        /// ffmpeg 实际写入的路径：workspace 里的临时文件，不是用户选的目标——
        /// 全部成功后才由调用方原子替换过去，失败/取消都不碰用户原有文件。
        var tempOutput: URL
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
        output: URL,
        cancellation: ExportCancellationToken? = nil
    ) async throws -> Plan {
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

        // 工程帧率是唯一事实来源。以前这条管线的九处滤镜写死 fps=30 / r=30，
        // 与预览合成的 1/30 各写一遍 —— 改帧率必须两边一起动，漏一处就是
        // 「预览 24、导出 30」。文件末尾有扫描守卫防止再写死。
        let fps = state.frameRate.fps
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
        // 下面任何一步失败（预渲染报错、被取消……）都要把 workspace 连同已经
        // 落盘的中间片一起清掉——不然调用方要等 plan() 成功返回才拿得到
        // workspace 路径，异常分支永远够不着它，大体积 ProRes 中间片就烂在
        // 临时目录里了。只有正常 return 之前才把 ownershipTransferred 置真，
        // 表示「调用方接手了，它来负责清理」。
        var workspaceOwnershipTransferred = false
        defer {
            if !workspaceOwnershipTransferred {
                try? FileManager.default.removeItem(at: workspace)
            }
        }

        // ffmpeg 落盘目标：workspace 里的临时文件，扩展名跟真实输出一致
        // （ffmpeg 靠文件名猜 muxer）。真正的用户目标只在全部成功后才由
        // 调用方原子替换过去——ffmpeg 的 -y 一旦打开文件就地截断，直接写
        // 用户选的路径的话，编码编到一半失败也会把人家原来的文件先冲掉。
        let tempOutput = workspace
            .appendingPathComponent("export-output")
            .appendingPathExtension(output.pathExtension)

        // 关键帧动画的段：先用预览同一套合成渲成中间片（AnimatedClipPrerenderer），
        // ffmpeg 图里当普通素材吃。主轨一条黑底 422；画中画 fill+matte 两条
        //（alphamerge 合回带 alpha 的流），细节见 AnimatedClipPrerenderer。
        enum Prerendered {
            case main(URL)
            case overlay(fill: URL, matte: URL)
        }
        var prerendered: [UUID: Prerendered] = [:]
        for clip in mainVisible where clip.isAnimated {
            prerendered[clip.id] = .main(try await AnimatedClipPrerenderer.renderMain(
                clip: clip, renderSize: renderSize, frameRate: state.frameRate,
                    into: workspace, cancellation: cancellation
            ))
        }
        for lane in overlayLanes {
            for clip in lane.clips where clip.isAnimated && !clip.needsStillConversion {
                let pair = try await AnimatedClipPrerenderer.renderOverlay(
                    clip: clip, renderSize: renderSize, frameRate: state.frameRate,
                    into: workspace, cancellation: cancellation
                )
                prerendered[clip.id] = .overlay(fill: pair.fill, matte: pair.matte)
            }
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
            args.append(tempOutput.path)
            workspaceOwnershipTransferred = true
            return Plan(
                arguments: args, workspace: workspace, totalDuration: total,
                tempOutput: tempOutput, isAudioOnly: true
            )
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
                if case .main(let intermediate) = prerendered[clip.id] {
                    // 关键帧动画的段：中间片就是压平好的整段画面（黑底、画布
                    // 尺寸、0 起点、时长=段长），直接进拼接链。声音仍走原素材。
                    let preSource = input(for: intermediate)
                    filters.append(
                        "[\(preSource):v]fps=\(fps),setsar=1,format=yuv420p[\(vLabel)]"
                    )
                } else if clip.hasVisualTransform {
                    // 摆放/旋转/裁切/翻转/透明度任一非默认的主轨段：
                    // 变换链处理后叠到黑底画布上。用 overlay 而不是 pad ——
                    // 框可以比画布大、可以探出边界，旋转还会撑大输出框。
                    let transformed = transformSteps(clip: clip, renderSize: renderSize, isOverlay: false)
                    let fg = nextLabel("fg")
                    let bg = nextLabel("bg")
                    filters.append(
                        "[\(source):v]trim=start=\(fmt(clip.sourceStart)):end=\(fmt(end))," +
                        "setpts=(PTS-STARTPTS)/\(fmt(clip.speed)),fps=\(fps)," +
                        "\(transformed.chain)[\(fg)]"
                    )
                    filters.append(
                        "color=black:s=\(width)x\(height):r=\(fps):d=\(fmt(segment.duration))[\(bg)]"
                    )
                    filters.append(
                        "[\(bg)][\(fg)]overlay=x=\(transformed.overlayX):y=\(transformed.overlayY):" +
                        "shortest=1,format=yuv420p[\(vLabel)]"
                    )
                } else {
                    filters.append(
                        "[\(source):v]trim=start=\(fmt(clip.sourceStart)):end=\(fmt(end))," +
                        "setpts=(PTS-STARTPTS)/\(fmt(clip.speed)),fps=\(fps)," +
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
                    "color=black:s=\(width)x\(height):r=\(fps):d=\(fmt(segment.duration)),format=yuv420p[\(vLabel)]"
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
                let scaled = nextLabel("ov")
                let x: String
                let y: String
                if case .overlay(let fill, let matte) = prerendered[clip.id] {
                    // 关键帧动画的画中画：fill（内容压黑底）+ matte（白块蒙版）
                    // alphamerge 合回带 alpha 的整幅画布，原位叠放。
                    // 位置/缩放/旋转/不透明度全在两条中间片里烘焙好了。
                    //
                    // fill 是压在黑底上合成出来的：边缘抗锯齿处的 RGB 已经是
                    // 「真实色 × coverage × opacity」（黑底=0，预乘的定义），但 alphamerge
                    // 只是把这份 RGB 原样接上 matte 给的 alpha，出来的流对
                    // ffmpeg 来说是 straight alpha 语义。直接喂给 overlay 默认
                    // 的 straight 混合，边缘的 alpha 会被多乘一次（50% 覆盖处
                    // 只有该有亮度的一半，实测验证过）。overlay 自带的
                    // alpha=premultiplied 选项在这张图上不生效（依赖帧的
                    // alpha_mode 元数据协商，alphamerge 不会打这个标记，测过
                    // 多种组合数值都不对）——改成显式按 matte 把 fill 除回
                    // 真实色（真实色 = 255×fill/matte），这样交给 overlay 的
                    // 就是名副其实的 straight alpha，用它默认的混合就对。
                    let fillSource = input(for: fill)
                    let matteSource = input(for: matte)
                    let fillLabel = nextLabel("kf")
                    let matteLabel = nextLabel("km")
                    let matteRGBLabel = nextLabel("kmc")
                    let straightLabel = nextLabel("ks")
                    filters.append("[\(fillSource):v]fps=\(fps),setsar=1,format=rgb24[\(fillLabel)]")
                    filters.append("[\(matteSource):v]fps=\(fps),setsar=1,format=gray[\(matteLabel)]")
                    // matteRGB 单独从 matteSource 转，不能从 matteLabel 派生：
                    // 同一条流喂给两个下游（这里 + alphamerge）会让 alphamerge
                    // 拿到的 alpha 整段跑偏（实测 128 会变成 76），原因不明，
                    // 两条各转各的就没事——踩过一次，别改回「省一次解码」的
                    // 写法。
                    filters.append("[\(matteSource):v]fps=\(fps),setsar=1,format=rgb24[\(matteRGBLabel)]")
                    filters.append(
                        "[\(fillLabel)][\(matteRGBLabel)]blend=all_expr=" +
                        "'if(gt(B,0),min(255,255*A/B),0)'[\(straightLabel)]"
                    )
                    filters.append(
                        "[\(straightLabel)][\(matteLabel)]alphamerge,format=rgba," +
                        "setpts=PTS+\(fmt(clip.timelineStart))/TB[\(scaled)]"
                    )
                    x = "0"
                    y = "0"
                } else {
                    // 有任何变换的画中画走完整变换链（中心定位）；否则九宫格表达式。
                    let end = clip.sourceStart + clip.sourceDuration
                    let chain: String
                    if clip.hasVisualTransform {
                        let transformed = transformSteps(clip: clip, renderSize: renderSize, isOverlay: true)
                        chain = transformed.chain
                        x = transformed.overlayX
                        y = transformed.overlayY
                    } else {
                        let overlayWidth = Int((renderSize.width * clip.overlayFraction / 2).rounded() * 2)
                        chain = "scale=\(overlayWidth):-2,setsar=1"
                        let inset = Int(renderSize.width * 0.02)
                        x = xExpression(for: clip.overlayAnchor, inset: inset)
                        y = yExpression(for: clip.overlayAnchor, inset: inset)
                    }
                    filters.append(
                        "[\(source):v]trim=start=\(fmt(clip.sourceStart)):end=\(fmt(end))," +
                        "setpts=(PTS-STARTPTS)/\(fmt(clip.speed)),fps=\(fps)," +
                        "\(chain)," +
                        "setpts=PTS+\(fmt(clip.timelineStart))/TB[\(scaled)]"
                    )
                }
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
        args.append(tempOutput.path)

        workspaceOwnershipTransferred = true
        return Plan(arguments: args, workspace: workspace, totalDuration: total, tempOutput: tempOutput)
    }

    // MARK: 小工具

    /// 摆放框的像素尺寸收成正偶数：yuv420 要偶数，scale 不吃 0。
    private static func evenPixel(_ value: Double) -> Int {
        max(2, Int((value / 2).rounded()) * 2)
    }

    /// Transform 面板的完整滤镜链（接在 fps=<工程帧率> 之后）：
    /// 裁切 → 翻转 → 缩放进摆放框 → 旋转（rgba 透明角）→ 不透明度。
    /// 定位用中心表达式 —— 旋转会把输出框撑大（rotw/roth），
    /// 只有中心是不变量。时间账与预览的 fittingTransform 完全同构。
    private static func transformSteps(
        clip: EditClip,
        renderSize: CGSize,
        isOverlay: Bool
    ) -> (chain: String, overlayX: String, overlayY: String) {
        let target = clip.resolvedPlacement(canvas: renderSize, isOverlay: isOverlay)
            .frame(in: renderSize)
        var steps: [String] = []
        if let crop = clip.crop, !crop.isEmpty, let display = clip.info?.displaySize {
            let rect = crop.rect(in: display)
            steps.append(
                "crop=\(Int(rect.width.rounded())):\(Int(rect.height.rounded())):" +
                "\(Int(rect.minX.rounded())):\(Int(rect.minY.rounded()))"
            )
        }
        if clip.flippedHorizontally { steps.append("hflip") }
        if clip.flippedVertically { steps.append("vflip") }
        steps.append("scale=\(evenPixel(target.width)):\(evenPixel(target.height))")
        steps.append("setsar=1")
        let rotated = abs(clip.rotationDegrees) > 0.01
        let translucent = clip.opacity < 0.999
        if rotated || translucent { steps.append("format=rgba") }
        if rotated {
            let radians = fmt(clip.rotationDegrees * .pi / 180)
            steps.append("rotate=\(radians):ow=rotw(\(radians)):oh=roth(\(radians)):c=black@0")
        }
        if translucent { steps.append("colorchannelmixer=aa=\(fmt(clip.opacity))") }
        return (
            steps.joined(separator: ","),
            "\(Int(target.midX.rounded()))-w/2",
            "\(Int(target.midY.rounded()))-h/2"
        )
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
