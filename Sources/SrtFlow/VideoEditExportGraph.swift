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

/// 纯函数地把时间线翻译成 ffmpeg 参数。工作目录里放 ASS、字体、形状和文字 PNG。
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
        let mainVisible = ClipVisibility.visible(state.mainHidden ? [] : state.mainClips)
            .filter { !$0.needsStillConversion }
        let overlayVisible = ClipVisibility.visible(
            state.overlayTracks.filter { !$0.isHidden }.flatMap(\.clips)
        ).filter { !$0.needsStillConversion }
        let hasAudio = !ClipVisibility.visible(
            state.audioTracks.filter { !$0.isHidden }.flatMap(\.clips)
        ).isEmpty
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
        // 混音要的是**用户那一份**：它走预览合成（`build` 自己排序、展开），展开只许一次。
        let requested = state
        // 主轨的黑场补齐和 xfade 链都按数组顺序算，乱序输入会算出负时长的
        // 黑场/错位的转场。与预览合成同款防御（见 CompositionBuilder.build）。
        var state = state
        state.sortMainClipsByStart()
        // 与预览合成同一个位置、同一个函数：转场向两边借余料，展开后两段真的
        // 相叠，下面的分节和 xfade 链原样成立（VideoEditTransitionHandles.swift）。
        state = state.expandingTransitionHandles()
        // 图片段还没转成静帧视频时是进不了成片的。以前这里直接把它们滤掉，
        // 导出会「成功」，但用户的图片凭空消失且毫无提示 —— 宁可拦下来说清楚。
        // 只看真正会进成片的段：藏起来的轨本来就不导出，别拿它拦人。
        let pendingStills = ClipVisibility.visible(
            (state.mainHidden ? [] : state.mainClips)
                + state.overlayTracks.filter { !$0.isHidden }.flatMap(\.clips)
        ).filter(\.needsStillConversion)
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
        // 隐藏的轨、单独隐藏的段（V）、还在转静帧的占位块都不进成片。
        // 两级隐藏同一条语义，见 docs/architecture/clip-visibility.md。
        let mainVisible = ClipVisibility.visible(state.mainHidden ? [] : state.mainClips)
            .filter { !$0.needsStillConversion }
        let overlayLanes = state.overlayTracks.filter { !$0.isHidden }
        let audioLanes = state.audioTracks.filter { !$0.isHidden }
        let overlayVisible = ClipVisibility.visible(overlayLanes.flatMap(\.clips))
            .filter { !$0.needsStillConversion }
        let audioClips = ClipVisibility.visible(audioLanes.flatMap(\.clips))
            .filter { !$0.isMuted }

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
                title: state.subtitleURL?.deletingPathExtension().lastPathComponent ?? "SrtFlow",
                // 工程级布局覆盖：与预览的 BurnInSubtitleOverlay.layout 同一份。
                layout: state.subtitleLayout
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

        // 形状 → 整幅透明 PNG。
        var shapeFiles: [(shape: ShapeAnnotation, filename: String)] = []
        for (index, shape) in state.renderedShapes.enumerated() {  // 藏起来的（V）不进成片
            let filename = "shape\(index).png"
            guard let png = ShapePNGRenderer.render(shape, canvas: renderSize) else { continue }
            try png.write(to: workspace.appendingPathComponent(filename))
            shapeFiles.append((shape, filename))
        }

        // 文字 → 包络大小的透明 PNG（**不是**整幅画布，理由见 TextOverlayExport）。
        // 画面由 `TextRenderer.render` 出，和预览是同一个函数。
        let textFiles = try TextOverlayExport.renderFiles(
            state.renderedTextOverlays, canvas: renderSize,  // 叠放序同预览：行号小的先贴；藏起来的不算
            frameRate: state.frameRate, into: workspace
        )

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

        // MARK: 声音：离线读出预览那份混音
        //
        // 成片的声音**不在这张图里搭**：和预览同一份合成 + audioMix，由 ExportAudioMixdown 读成
        // 一个正好 `total` 秒的 raw 文件，这里只把它当一路输入接上去、编成 AAC。音量、渐变、曲线、
        // 推子、转场的交叉淡变、首尾定格的静音都已经在里面了（docs/architecture/export-audio-mixdown.md）。
        // 一个出声的段都没有时垫一路静音：成片照旧总有一条音轨。
        let mixdownFile = workspace.appendingPathComponent("audio-mixdown.f32")
        switch try await ExportAudioMixdown.render(
            state: requested, duration: total, to: mixdownFile, cancellation: cancellation
        ) {
        case .written:
            inputArguments += ExportAudioMixdown.inputArguments(mixdownFile)
        case .silent:
            inputArguments += ["-f", "lavfi", "-t", fmt(total), "-i", "anullsrc=r=48000:cl=stereo"]
        }
        let audioMap = "\(inputs.count):a"
        inputs.append(mixdownFile.path)

        // MARK: 纯音频：只选了声音，出一个音频文件

        if !hasVisual {
            var args: [String] = ["-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-progress", "pipe:1"]
            args += inputArguments
            args += ["-map", audioMap, "-c:a", "aac", "-b:a", "\(settings.audio.kbps)k"]
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

        // MARK: 逐帧动画段的预渲染
        //
        // 关键帧动画和预设入/出场（位移/缩放/擦除）的段：先用预览同一套合成渲成
        // 中间片（AnimatedClipPrerenderer），ffmpeg 图里当普通素材吃。主轨一条
        // 黑底 422；上层轨 fill+matte 两条（alphamerge 合回带 alpha 的流），
        // 细节见 AnimatedClipPrerenderer。
        //
        // **必须排在分节之后**：中间片里要不要烤进头尾渐变，取决于这条接缝上有没有
        // 转场，而那个判据只有分节表算得出来（转场只在两段真的首尾相叠时成立）。
        // 预渲染的临时时间线里只有它自己、没有邻居，仲裁不做完就传进去的话，
        // 本该让位给 xfade 的渐变会被烤进画面 —— 见
        // docs/bugfixes/2026-09-18-prerender-fade-ignores-transition.md。
        enum Prerendered {
            case main(URL)
            case overlay(fill: URL, matte: URL)
        }
        var prerendered: [UUID: Prerendered] = [:]
        for (segmentIndex, segment) in segments.enumerated() {
            guard let clip = segment.clip, clip.needsPerFrameRender else { continue }
            prerendered[clip.id] = .main(try await AnimatedClipPrerenderer.renderMain(
                clip: clip,
                // 判据与下面非预渲染分支的 `VideoFade.effective` 逐字相同。
                fades: VideoFade.effective(
                    clip: clip,
                    hasTransitionBefore: segmentIndex > 0 && segments[segmentIndex - 1].transition != .none,
                    hasTransitionAfter: segment.transition != .none
                ),
                renderSize: renderSize, frameRate: state.frameRate,
                into: workspace, cancellation: cancellation
            ))
        }
        // 只走 overlayVisible：藏起来的轨、单独藏起来的段（V）、还在转静帧的都不进成片，
        // 也就不必预渲染（清单只有一份，别再按轨去 lane.clips 里取 —— 那样漏过 V）。
        for clip in overlayVisible where clip.needsPerFrameRender {
            let pair = try await AnimatedClipPrerenderer.renderOverlay(
                clip: clip,
                // 上层视频轨没有轨内转场，那条边永远归用户的渐变管
                //（与预览合成的 `hasTransitionAfter` 同款注释）。
                fades: VideoFade.effective(
                    clip: clip, hasTransitionBefore: false, hasTransitionAfter: false
                ),
                renderSize: renderSize, frameRate: state.frameRate,
                into: workspace, cancellation: cancellation
            )
            prerendered[clip.id] = .overlay(fill: pair.fill, matte: pair.matte)
        }

        // MARK: 每节的画面流

        var segmentLabels: [(video: String, duration: Double)] = []
        for (segmentIndex, segment) in segments.enumerated() {
            let vLabel = nextLabel("v")
            if let clip = segment.clip {
                let source = input(for: clip.sourceURL)
                // 真正从素材里取的那一段。转场余料不够时，渲染副本在两头多记了
                // 一截**定格**（`renderHoldHead` / `renderHoldTail`），那两截不在
                // 素材里：先按真素材截，变速之后再用 `tpad` 复制首尾帧把它们接回去
                // —— 和预览合成那边「插一帧再拉长」同一笔账（定格那两截的静音在混音里）。
                let start = clip.renderSourceStart
                let end = start + clip.renderSourceDuration
                let videoHolds = Self.holdSteps(video: clip)
                if case .main(let intermediate) = prerendered[clip.id] {
                    // 关键帧动画的段：中间片就是压平好的整段画面（黑底、画布
                    // 尺寸、0 起点、时长=段长），直接进拼接链。
                    let preSource = input(for: intermediate)
                    filters.append(
                        "[\(preSource):v]fps=\(fps),setsar=1,format=yuv420p[\(vLabel)]"
                    )
                } else if clip.hasVisualTransform {
                    // 摆放/旋转/裁切/翻转/透明度任一非默认的主轨段：
                    // 变换链处理后叠到黑底画布上。用 overlay 而不是 pad ——
                    // 框可以比画布大、可以探出边界，旋转还会撑大输出框。
                    // 画面渐变与声音同一套仲裁：接缝上有转场就让位给 xfade。
                    let transformed = transformSteps(
                        clip: clip, renderSize: renderSize,
                        fades: VideoFade.effective(
                            clip: clip,
                            hasTransitionBefore: segmentIndex > 0
                                && segments[segmentIndex - 1].transition != .none,
                            hasTransitionAfter: segment.transition != .none
                        )
                    )
                    let fg = nextLabel("fg")
                    let bg = nextLabel("bg")
                    filters.append(
                        "[\(source):v]trim=start=\(fmt(start)):end=\(fmt(end))," +
                        "setpts=(PTS-STARTPTS)/\(fmt(clip.speed)),fps=\(fps)," +
                        "\(videoHolds)\(transformed.chain)[\(fg)]"
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
                        "[\(source):v]trim=start=\(fmt(start)):end=\(fmt(end))," +
                        "setpts=(PTS-STARTPTS)/\(fmt(clip.speed)),fps=\(fps)," +
                        "\(videoHolds)" +
                        "scale=\(width):\(height):force_original_aspect_ratio=decrease," +
                        "pad=\(width):\(height):(ow-iw)/2:(oh-ih)/2,setsar=1,format=yuv420p[\(vLabel)]"
                    )
                }
            } else {
                filters.append(
                    "color=black:s=\(width)x\(height):r=\(fps):d=\(fmt(segment.duration)),format=yuv420p[\(vLabel)]"
                )
            }
            segmentLabels.append((vLabel, segment.duration))
        }

        // MARK: 顺次拼接：硬切用 concat，转场用 xfade

        var video = segmentLabels[0].video
        var accumulated = segmentLabels[0].duration
        for index in 1..<segmentLabels.count {
            let next = segmentLabels[index]
            let boundary = segments[index - 1]
            let outV = nextLabel("v")
            if boundary.transition != .none, let xfade = boundary.transition.xfadeName {
                let d = boundary.transitionDuration
                let offset = accumulated - d
                // xfade 在 config_output 里**硬性要求**两条输入的 timebase 逐字段
                // 相等，不相等就直接报 EINVAL、整个导出失败。而这条链上的两种
                // 来源天生就不一样：段自己走 fps=<帧率> 出来是 1/fps，concat 的
                // 输出固定被置成 AVTB(1/1000000)。于是「先硬切、后转场」这种最
                // 常见的排法必炸（见 docs/bugfixes/2026-08-12-xfade-timebase-mismatch.md）。
                // 两边都显式压成 AVTB：xfade 的输出也跟着是 AVTB，后面再接
                // concat / 下一次 xfade 都还是这个值，整条链自洽。
                let leftTB = nextLabel("tb")
                let rightTB = nextLabel("tb")
                filters.append("[\(video)]settb=AVTB[\(leftTB)]")
                filters.append("[\(next.video)]settb=AVTB[\(rightTB)]")
                filters.append(
                    "[\(leftTB)][\(rightTB)]xfade=transition=\(xfade):duration=\(fmt(d)):offset=\(fmt(offset))[\(outV)]"
                )
                accumulated = accumulated + next.duration - d
            } else {
                filters.append("[\(video)][\(next.video)]concat=n=2:v=1:a=0[\(outV)]")
                accumulated += next.duration
            }
            video = outV
        }

        // MARK: 上层视频轨

        // 同一份 overlayVisible（见上面预渲染那一圈）：轨按数组顺序、轨内按段的顺序，叠放次序不变。
        for clip in overlayVisible {
            let source = input(for: clip.sourceURL)
            let scaled = nextLabel("ov")
            let x: String
            let y: String
            if case .overlay(let fill, let matte) = prerendered[clip.id] {
                // 关键帧动画的上层轨段：fill（内容压黑底）+ matte（白块蒙版）
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
                // 上层视频轨的每一段都走完整变换链（中心定位）。
                //
                // 这里**只有一条路**：默认摆放已经和主轨同账（等比铺满居中），
                // `transformSteps` 从 `resolvedPlacement` 算框，摆没摆过都对。
                // 原来那条「没变换就走九宫格表达式」的分支跟着画中画一起删了
                // —— 留着它就是给同一件事留两份账，迟早分叉。
                //
                // 比例对不上时两侧留空，**不补 pad**：这里是 overlay 到已经
                // 累积好的画面上，补黑就把主轨遮死了。
                let end = clip.sourceStart + clip.sourceDuration
                // 上层轨还没有轨内转场，两条边都归用户设的渐变管。
                let transformed = transformSteps(
                    clip: clip, renderSize: renderSize,
                    fades: VideoFade.effective(
                        clip: clip, hasTransitionBefore: false, hasTransitionAfter: false
                    )
                )
                let chain = transformed.chain
                x = transformed.overlayX
                y = transformed.overlayY
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
        }

        // MARK: 滤镜（调色）
        //
        // 落点是**画面合成之后、形状之前**：滤镜染的是这一段时间里的全部画面
        //（主轨 + 上层轨），不染形状/文字/字幕。这和预览侧「滤镜挂在播放器视图
        // 上、叠层是它上面的兄弟视图」一字不差 —— 两处的层序必须同一个说法。
        //
        // 三条和预览对齐的硬约束（改这里之前先读 docs/architecture/filters.md）：
        //
        // 1. **顺序按 `orderedFilters`**（层号小的先作用）。LUT 不可交换，两条
        //    管线各排各的就是「预览一个味道、成片另一个味道」。
        // 2. **`interp=trilinear` 必须显式写**。lut3d 默认是 tetrahedral，而预览
        //    侧的 CIColorCube 是三线性；不写这一项，同一张表两边算出来就不一样。
        // 3. **`format=gbrp` 垫在前面**。不指定的话滤镜图会自己协商像素格式，
        //    万一谈成 YUV，这张 RGB 查找表会被当成对 Y/U/V 查表用 —— 画面直接
        //    烂掉。显式压成 8bit 平面 RGB，定义域和预览一致。
        //
        // 强度 0 的段整条跳过：那是「先关掉看看」，成片应当和原片逐像素相同，
        // 而不是白跑一遍恒等表（预览侧 `FilterStack` 有同一条短路）。
        let gradeFilters = state.renderedFilters.filter {  // 按 orderedFilters 的顺序、藏起来的不算
            $0.strength > 0.0005 && $0.timelineEnd > 0 && $0.timelineStart < total
        }
        if !gradeFilters.isEmpty {
            let rgb = nextLabel("v")
            filters.append("[\(video)]format=gbrp[\(rgb)]")
            video = rgb
            for (index, grade) in gradeFilters.enumerated() {
                let filename = "filter\(index).cube"
                try FilterLUT.cubeFileText(for: grade.preset, strength: grade.strength)
                    .write(
                        to: workspace.appendingPathComponent(filename),
                        atomically: true, encoding: .utf8
                    )
                let outV = nextLabel("v")
                filters.append(
                    "[\(video)]lut3d=file=\(filename):interp=trilinear:" +
                    "enable='between(t,\(fmt(max(0, grade.timelineStart))),\(fmt(min(total, grade.timelineEnd))))'" +
                    "[\(outV)]"
                )
                video = outV
            }
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

        // MARK: 文字（压在形状之上、字幕之下）
        //
        // 次序是产品口径，不是实现顺手：文字要能放在"半透明色块当底板"的形状
        // 上面，所以文字必须后贴。见 docs/architecture/text-overlays.md。

        // 一段文字可能切成三段（入场序列 / 中间静止图 / 出场序列），各有各的
        // 接法。切法和理由见 TextOverlayExport；三种接法的实测依据：
        //   · 静止段：`-loop 1` 拉成持续流，与形状同款。
        //   · 一次性序列：`-itsoffset` 把序列推到落点，帧与时间线精确对齐。
        //   · 循环段：只有一个周期的帧，`loop` 滤镜铺满，`setpts` 补回时间轴。
        let textFps = Double(max(1, state.frameRate.fps))
        for file in textFiles {
            let stream: String
            switch file.source {
            case .still:
                inputArguments += ["-loop", "1", "-t", fmt(total), "-i", file.pattern]
                let index = inputs.count
                inputs.append(file.pattern)
                stream = "\(index):v"

            case .sequence:
                inputArguments += [
                    "-itsoffset", fmt(file.timelineStart),
                    "-framerate", fmt(textFps), "-start_number", "0", "-i", file.pattern
                ]
                let index = inputs.count
                inputs.append(file.pattern)
                stream = "\(index):v"

            case .looping(let frames):
                inputArguments += [
                    "-framerate", fmt(textFps), "-start_number", "0", "-i", file.pattern
                ]
                let index = inputs.count
                inputs.append(file.pattern)
                let looped = nextLabel("tl")
                // `loop` 之后 PTS 要自己重建（N 是帧序号），再整体推到落点。
                filters.append(
                    "[\(index):v]loop=loop=-1:size=\(frames):start=0," +
                    "setpts=N/\(fmt(textFps))/TB+\(fmt(file.timelineStart))/TB[\(looped)]"
                )
                stream = looped
            }

            let outV = nextLabel("v")
            filters.append(
                "[\(video)][\(stream)]overlay=x=\(fmt(file.origin.x)):y=\(fmt(file.origin.y))" +
                ":eof_action=pass:enable='between(t,\(fmt(file.timelineStart)),\(fmt(file.timelineEnd)))'[\(outV)]"
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

        // MARK: 缩小到导出分辨率（只降不升，放在最后）
        //
        // 画布、文字、形状、字幕全按工程尺寸画完，最后整幅等比缩小：成片就是
        // 全尺寸那一版缩小，预览看到什么、导出就是什么。压缩工具是先缩再烧字幕
        // （为了字幕更清晰），这里不学它 —— 理由见 docs/architecture/export-settings.md。
        // `setsar=1`：取偶数会让宽高比差一丝，scale 会改 SAR 去补，播放器照着
        // 那个 SAR 显示就是非方形像素。
        if let target = settings.resolution.cappedSize(width: width, height: height) {
            let outV = nextLabel("v")
            filters.append("[\(video)]scale=\(target.width):\(target.height),setsar=1[\(outV)]")
            video = outV
        }

        // MARK: 组装参数

        var args: [String] = ["-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-progress", "pipe:1"]
        args += inputArguments
        args += try ExportFilterScript.arguments(filters.joined(separator: ";"), workspace: workspace)
        args += ["-map", "[\(video)]", "-map", audioMap]

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
    /// 裁切 → 翻转 → 缩放进摆放框 → 旋转（rgba 透明角）→ 不透明度 → 画面渐变。
    /// 定位用中心表达式 —— 旋转会把输出框撑大（rotw/roth），
    /// 只有中心是不变量。时间账与预览的 fittingTransform 完全同构。
    ///
    /// - Parameter fades: **已经过转场仲裁**的画面渐变窗口（`VideoFade.effective`）。
    ///   渐变挂在链的最末尾，`st` 才对得上时间线秒（见 VideoEditVideoFade.swift）。
    private static func transformSteps(
        clip: EditClip,
        renderSize: CGSize,
        fades: FadeWindow
    ) -> (chain: String, overlayX: String, overlayY: String) {
        let target = clip.resolvedPlacement(canvas: renderSize)
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
        // 渐变是在 alpha 上做的，没有 alpha 通道 `fade=…:alpha=1` 就是空转。
        if rotated || translucent || !fades.isEmpty { steps.append("format=rgba") }
        if rotated {
            let radians = fmt(clip.rotationDegrees * .pi / 180)
            steps.append("rotate=\(radians):ow=rotw(\(radians)):oh=roth(\(radians)):c=black@0")
        }
        if translucent { steps.append("colorchannelmixer=aa=\(fmt(clip.opacity))") }
        return (
            steps.joined(separator: ",")
                + VideoFade.filterSteps(fades, timelineDuration: clip.timelineDuration),
            "\(Int(target.midX.rounded()))-w/2",
            "\(Int(target.midY.rounded()))-h/2"
        )
    }

    /// `30.0` → `"30"`，`1.2345` → `"1.234"`。滤镜参数里别出现一长串小数。
    static func fmt(_ value: Double) -> String {
        let rounded = (value * 1000).rounded() / 1000
        if rounded.truncatingRemainder(dividingBy: 1) == 0 {
            return String(Int(rounded))
        }
        return String(format: "%g", rounded)
    }

    /// 首尾定格的画面滤镜段（`tpad` 复制首帧 / 尾帧），接在变速和 `fps` 之后 ——
    /// 那时链上的时间已经是时间线秒，定格时长直接用。没有定格时是空串；
    /// 有的话自带结尾逗号。只有渲染副本里转场余料不够的主轨段才会有
    /// （`EditClip.renderHoldHead` / `renderHoldTail`，见 VideoEditTransitionHandles）。
    static func holdSteps(video clip: EditClip) -> String {
        var options: [String] = []
        if clip.renderHoldHead > 0.0005 {
            options.append("start_mode=clone:start_duration=\(fmt(clip.renderHoldHead))")
        }
        if clip.renderHoldTail > 0.0005 {
            options.append("stop_mode=clone:stop_duration=\(fmt(clip.renderHoldTail))")
        }
        return options.isEmpty ? "" : "tpad=" + options.joined(separator: ":") + ","
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
