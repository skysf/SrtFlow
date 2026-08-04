import AVFoundation
import CoreVideo
import Foundation

/// 预览合成的纯色底素材：64×36 的两帧纯色 H.264，AVAssetWriter 直接生成，
/// 不依赖 ffmpeg。黑底垫在半透明合成下面；白底给关键帧画中画的蒙版
/// 预渲染当「白块」用。放在缓存目录，被系统清掉就重新写一个。
///
/// actor + 单飞：预览重建高频触发，并发进来只允许一个真正去写；生成先落
/// **唯一命名的临时文件**，写完验证能读出视频轨才原子替换到正式路径 ——
/// 光看「文件存在」会把并发写到一半的残骸当缓存，绿底就回来了。
actor BlackBaseVideoFactory {
    static let shared = BlackBaseVideoFactory()

    private var inFlight: [String: Task<URL?, Never>] = [:]

    static func videoURL() async -> URL? {
        await shared.resolve(fileName: "black-base-v1.mp4", bgra: 0xFF00_0000)
    }

    /// 纯白版本（蒙版渲染的「白块」素材）。
    static func whiteVideoURL() async -> URL? {
        await shared.resolve(fileName: "white-base-v1.mp4", bgra: 0xFFFF_FFFF)
    }

    private func resolve(fileName: String, bgra: UInt32) async -> URL? {
        let destination = Self.cacheURL(fileName)
        if await Self.isUsable(destination) { return destination }
        if let existing = inFlight[fileName] { return await existing.value }
        let task = Task { await Self.generate(to: destination, bgra: bgra) }
        inFlight[fileName] = task
        let result = await task.value
        inFlight[fileName] = nil
        return result
    }

    private static func cacheURL(_ fileName: String) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SrtFlowPreview", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    /// 真能当素材用吗：必须读得出视频轨且时长正常，坏文件当场删掉重来。
    private static func isUsable(_ url: URL) async -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let range = try? await track.load(.timeRange),
              range.duration.seconds > 0.5 else {
            try? FileManager.default.removeItem(at: url)
            return false
        }
        return true
    }

    private static func generate(to destination: URL, bgra: UInt32) async -> URL? {
        let directory = destination.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temp = directory.appendingPathComponent("base-\(UUID().uuidString).tmp.mp4")
        // 所有提前退出的分支都不许留半成品。
        defer { try? FileManager.default.removeItem(at: temp) }

        do {
            let writer = try AVAssetWriter(outputURL: temp, fileType: .mp4)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 64,
                AVVideoHeightKey: 36
            ])
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: 64,
                    kCVPixelBufferHeightKey as String: 36
                ]
            )
            writer.add(input)
            guard writer.startWriting() else { return nil }
            writer.startSession(atSourceTime: .zero)

            guard let pool = adaptor.pixelBufferPool else { return nil }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { return nil }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let baseAddress = CVPixelBufferGetBaseAddress(buffer) {
                let byteCount = CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer)
                // 按 32 位 BGRA 模式填纯色（A=255 的黑或白）。
                let words = baseAddress.assumingMemoryBound(to: UInt32.self)
                for index in 0..<(byteCount / 4) { words[index] = bgra }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])

            // isReadyForMoreMediaData 在 writer 异步失败后可能**永远**不恢复
            // （Apple 文档明说会长时间为 false）。不设状态检查和超时的话，
            // 这个循环挂死 → 单飞任务永不返回 → 之后所有预览重建全部卡在它上。
            var waitedNanoseconds: UInt64 = 0
            for seconds in [0.0, 1.0] {
                while !input.isReadyForMoreMediaData {
                    guard writer.status == .writing, waitedNanoseconds < 5_000_000_000 else {
                        writer.cancelWriting()
                        return nil
                    }
                    try? await Task.sleep(nanoseconds: 5_000_000)
                    waitedNanoseconds += 5_000_000
                }
                // append 返回 false 就是写失败（Apple 文档明说），不能当没看见。
                guard adaptor.append(
                    buffer,
                    withPresentationTime: CMTime(seconds: seconds, preferredTimescale: 600)
                ) else {
                    writer.cancelWriting()
                    return nil
                }
            }
            input.markAsFinished()
            await writer.finishWriting()
            guard writer.status == .completed else { return nil }

            // 原子替换到正式路径，最后再验一遍才交出去。
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: destination)
            }
            guard await isUsable(destination) else { return nil }
            return destination
        } catch {
            return nil
        }
    }
}

/// 把时间线状态翻译成 AVFoundation 的预览合成。
///
/// 结构：主轨用**两条**合成视频轨 A/B 交替放段落 —— 转场要求前后两段在重叠区
/// 同时有画面，同一条轨做不到。画中画每条时间线轨各占一条合成轨。转场用
/// 透明度渐变近似（压黑/闪白在导出时由 xfade 精确渲染，预览的时间账完全一致）。
/// 变速用 scaleTimeRange，播放条目上配 `.spectral` 保音调，跟导出的 atempo 听感一致。
enum VideoEditCompositionBuilder {

    struct Built {
        var composition: AVMutableComposition
        var videoComposition: AVMutableVideoComposition?
        var audioMix: AVMutableAudioMix?
        var renderSize: CGSize
    }

    /// 素材摆进画布所需的固定几何量（关键帧动画每片重算变换时复用）。
    private struct ClipGeometry {
        var preferredTransform: CGAffineTransform
        /// 源旋转摆正后包围盒的原点（挪回原点用）。
        var boundsOrigin: CGPoint
        /// 显示方向上的裁切区（没裁就是整幅）。
        var sourceRect: CGRect
    }

    /// 预览里参与画面合成的一段（换算好合成轨和转场之后的产物）。
    private struct PlacedClip {
        var clip: EditClip
        /// 这段落在哪条合成轨上。layer instruction 要拿它当 assetTrack 用。
        var track: AVMutableCompositionTrack
        var transform: CGAffineTransform
        /// 四边裁切换算回源轨自然坐标系的矩形；nil = 不裁。
        var cropRect: CGRect?
        /// 关键帧动画的段每片重算变换用；静态段是 nil。
        var geometry: ClipGeometry?
        /// 动画摆放的默认基准（主轨铺满还是画中画九宫格）。
        var isOverlay = false
        /// 画面的叠放层级，越大越靠上（主轨 0，画中画 1+轨号）。
        var layer: Int
        var start: Double { clip.timelineStart }
        var end: Double { clip.timelineEnd }
        /// 开头的淡入（跟上一段的转场决定），(时长, 后半才亮?)。
        var fadeIn: (duration: Double, delayedHalf: Bool)?
        /// 结尾的淡出，(时长, 前半就灭?)。
        var fadeOut: (duration: Double, earlyHalf: Bool)?
    }

    /// - Parameter renderSizeOverride: 导出预渲染要用外层时间线的画布尺寸，
    ///   传它覆盖「按素材推断」的默认逻辑。
    ///
    /// 注意：默认合成器的 `backgroundColor` **只支持不透明色（alpha 被忽略，
    /// 文档明说）**，所以这里出不了透明背景 —— 带 alpha 的预渲染走
    /// fill + matte 双渲染（见 AnimatedClipPrerenderer）。
    static func build(
        from state: TimelineState,
        renderSizeOverride: CGSize? = nil
    ) async -> Built? {
        guard !state.isEmpty else { return nil }

        let composition = AVMutableComposition()
        var placed: [PlacedClip] = []
        var audioParams: [AVMutableAudioMixInputParameters] = []

        // 输出尺寸：第一段主轨素材说了算（预渲染时由外层画布指定）。
        let renderSize = renderSizeOverride ?? Self.renderSize(for: state)

        // 素材缓存：同一个文件出现几段，AVURLAsset 只开一次。
        var assets: [URL: AVURLAsset] = [:]
        func asset(for url: URL) -> AVURLAsset {
            if let existing = assets[url] { return existing }
            let created = AVURLAsset(url: url)
            assets[url] = created
            return created
        }

        // MARK: 主轨（A/B 交替）

        let videoA = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        let videoB = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        let audioA = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        let audioB = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        var videoCursors: [Double] = [0, 0]
        var audioCursors: [Double] = [0, 0]
        let audioAParams = audioA.map(AVMutableAudioMixInputParameters.init(track:))
        let audioBParams = audioB.map(AVMutableAudioMixInputParameters.init(track:))

        for (index, clip) in state.mainClips.enumerated() {
            // 整轨隐藏 → 主轨完全不进合成（预览是黑场）；
            // 还在后台转静帧的图片占位块也先跳过，转完会重建。
            guard !state.mainHidden, !clip.needsStillConversion else { continue }
            let slot = index % 2
            guard let videoTrack = (slot == 0 ? videoA : videoB) else { continue }
            let sourceAsset = asset(for: clip.sourceURL)
            guard let sourceVideo = try? await sourceAsset.loadTracks(withMediaType: .video).first else { continue }

            guard await insert(
                source: sourceVideo,
                clip: clip,
                into: videoTrack,
                cursor: &videoCursors[slot]
            ) else { continue }

            let naturalSize = (try? await sourceVideo.load(.naturalSize)) ?? renderSize
            let preferred = (try? await sourceVideo.load(.preferredTransform)) ?? .identity
            let fitted = fittingTransform(
                naturalSize: naturalSize,
                preferredTransform: preferred,
                renderSize: renderSize,
                clip: clip,
                isOverlay: false
            )

            // 进出场的渐变由前后两个转场决定。
            let overlapBefore = index > 0 ? state.transitionOverlap(afterMainIndex: index - 1) : 0
            let overlapAfter = state.transitionOverlap(afterMainIndex: index)
            let kindBefore = index > 0 ? state.mainClips[index - 1].transitionAfter : .none
            let kindAfter = clip.transitionAfter

            var item = PlacedClip(
                clip: clip,
                track: videoTrack,
                transform: fitted.transform,
                cropRect: fitted.cropRect,
                geometry: fitted.geometry,
                isOverlay: false,
                layer: 0
            )
            if overlapBefore > 0 {
                // 叠化：后段整场垫在底下不淡入 —— 接缝两侧都「盖满画布且不透明」
                // 时，这个叠法逐像素等于导出的 xfade dissolve。压黑/闪白：后半段才亮。
                //
                // 只要有一侧盖不满或半透明（缩小挪位、旋转透明角、整层透明度），
                // 「垫底常亮」会让后段从转场第一帧就透出来，而导出是先把每段
                // 压平到黑底再 dissolve。这种接缝改成双向线性淡变：后段从黑里
                // 亮起来，贴合导出模型（代价是中点轻微变暗，见架构文档）。
                // 判定必须用 coversCanvasOpaquely，别拿 hasVisualTransform 凑 ——
                // 仅翻转照样满幅不透明，误走近似路径就是白闪变暗。
                if kindBefore != .crossFade {
                    item.fadeIn = (overlapBefore, true)
                } else if !clip.coversCanvasOpaquely(canvas: renderSize, isOverlay: false)
                    || !state.mainClips[index - 1].coversCanvasOpaquely(canvas: renderSize, isOverlay: false) {
                    item.fadeIn = (overlapBefore, false)
                }
            }
            if overlapAfter > 0 {
                item.fadeOut = (overlapAfter, kindAfter != .crossFade)
            }
            placed.append(item)

            // 声音
            if clip.hasAudio, !clip.isMuted,
               let audioTrack = (slot == 0 ? audioA : audioB),
               let params = (slot == 0 ? audioAParams : audioBParams),
               let sourceAudio = try? await sourceAsset.loadTracks(withMediaType: .audio).first,
               await insert(source: sourceAudio, clip: clip, into: audioTrack, cursor: &audioCursors[slot]) {
                addVolumeRamps(
                    params: params,
                    clip: clip,
                    fadeIn: overlapBefore > 0 ? overlapBefore : nil,
                    fadeOut: overlapAfter > 0 ? overlapAfter : nil
                )
            }
        }
        if let audioAParams { audioParams.append(audioAParams) }
        if let audioBParams { audioParams.append(audioBParams) }

        // MARK: 画中画轨

        for (trackIndex, lane) in state.overlayTracks.enumerated()
        where !lane.clips.isEmpty && !lane.isHidden {
            guard let videoTrack = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { continue }
            let audioTrack = composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
            )
            let params = audioTrack.map(AVMutableAudioMixInputParameters.init(track:))
            var videoCursor = 0.0
            var audioCursor = 0.0

            for clip in lane.clips.sorted(by: { $0.timelineStart < $1.timelineStart })
            where !clip.needsStillConversion {
                let sourceAsset = asset(for: clip.sourceURL)
                guard let sourceVideo = try? await sourceAsset.loadTracks(withMediaType: .video).first else { continue }
                guard await insert(source: sourceVideo, clip: clip, into: videoTrack, cursor: &videoCursor) else { continue }

                let naturalSize = (try? await sourceVideo.load(.naturalSize)) ?? renderSize
                let preferred = (try? await sourceVideo.load(.preferredTransform)) ?? .identity
                let fitted = fittingTransform(
                    naturalSize: naturalSize,
                    preferredTransform: preferred,
                    renderSize: renderSize,
                    clip: clip,
                    isOverlay: true
                )
                placed.append(PlacedClip(
                    clip: clip,
                    track: videoTrack,
                    transform: fitted.transform,
                    cropRect: fitted.cropRect,
                    geometry: fitted.geometry,
                    isOverlay: true,
                    layer: 1 + trackIndex
                ))

                if clip.hasAudio, !clip.isMuted,
                   let audioTrack, let params,
                   let sourceAudio = try? await sourceAsset.loadTracks(withMediaType: .audio).first,
                   await insert(source: sourceAudio, clip: clip, into: audioTrack, cursor: &audioCursor) {
                    addVolumeRamps(params: params, clip: clip, fadeIn: nil, fadeOut: nil)
                }
            }
            if let params { audioParams.append(params) }
        }

        // MARK: 音频轨

        for lane in state.audioTracks where !lane.clips.isEmpty && !lane.isHidden {
            guard let audioTrack = composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { continue }
            let params = AVMutableAudioMixInputParameters(track: audioTrack)
            var cursor = 0.0
            for clip in lane.clips.sorted(by: { $0.timelineStart < $1.timelineStart }) {
                let sourceAsset = asset(for: clip.sourceURL)
                guard let sourceAudio = try? await sourceAsset.loadTracks(withMediaType: .audio).first else { continue }
                guard await insert(source: sourceAudio, clip: clip, into: audioTrack, cursor: &cursor) else { continue }
                if clip.isMuted {
                    params.setVolume(0, at: time(clip.timelineStart))
                } else {
                    addVolumeRamps(params: params, clip: clip, fadeIn: nil, fadeOut: nil)
                }
            }
            audioParams.append(params)
        }

        // MARK: 不透明黑底轨
        //
        // 默认合成器的坑：画面上有半透明图层（Transform 的不透明度、转场的
        // 淡入淡出）时，它换到混合路径，`instruction.backgroundColor` 不再生效，
        // 未覆盖区域是零填充的 YUV 缓冲 —— 显示成暗绿色。所以这种时候垫一条
        // 真正的黑视频铺满全程当底，混合永远发生在不透明底之上。
        let needsOpaqueBase = placed.contains {
            $0.clip.minimumOpacity < 0.999 || $0.fadeIn != nil || $0.fadeOut != nil
        }
        if needsOpaqueBase, let baseURL = await BlackBaseVideoFactory.videoURL() {
            let baseAsset = asset(for: baseURL)
            if let baseSource = try? await baseAsset.loadTracks(withMediaType: .video).first,
               let baseTrack = composition.addMutableTrack(
                   withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
               ),
               let sourceRange = try? await baseSource.load(.timeRange),
               (try? baseTrack.insertTimeRange(sourceRange, of: baseSource, at: .zero)) != nil {
                baseTrack.scaleTimeRange(
                    CMTimeRange(start: .zero, duration: sourceRange.duration),
                    toDuration: time(state.duration)
                )
                let natural = (try? await baseSource.load(.naturalSize)) ?? CGSize(width: 64, height: 36)
                var base = EditClip(sourceURL: baseURL, sourceDuration: state.duration)
                base.timelineStart = 0
                placed.append(PlacedClip(
                    clip: base,
                    track: baseTrack,
                    transform: CGAffineTransform(
                        scaleX: renderSize.width / max(natural.width, 1),
                        y: renderSize.height / max(natural.height, 1)
                    ),
                    cropRect: nil,
                    geometry: nil,
                    isOverlay: false,
                    layer: Int.min
                ))
            }
        }

        // 清掉没有任何内容的合成轨（A/B 双轨和音轨是无条件建的）。
        // AVPlayer 容忍空轨，AVAssetExportSession 会报 InvalidVideoComposition
        //（表述是 "Operation Stopped"）—— 预渲染走导出会话，必须干净。
        for track in composition.tracks where track.segments.isEmpty {
            composition.removeTrack(track)
        }
        let remainingTrackIDs = Set(composition.tracks.map(\.trackID))
        let effectiveAudioParams = audioParams.filter { remainingTrackIDs.contains($0.trackID) }

        // 纯音频时间线：没有任何画面就不配 videoComposition。
        let hasVideoContent = placed.contains { !$0.clip.isAudioOnly }
        var videoComposition: AVMutableVideoComposition?
        if hasVideoContent {
            videoComposition = buildVideoComposition(
                placed: placed,
                renderSize: renderSize,
                totalDuration: state.duration
            )
        }

        var audioMix: AVMutableAudioMix?
        if !effectiveAudioParams.isEmpty {
            let mix = AVMutableAudioMix()
            mix.inputParameters = effectiveAudioParams
            audioMix = mix
        }

        return Built(
            composition: composition,
            videoComposition: videoComposition,
            audioMix: audioMix,
            renderSize: renderSize
        )
    }

    // MARK: - 小工具

    private static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: max(0, seconds), preferredTimescale: 600)
    }

    static func renderSize(for state: TimelineState) -> CGSize {
        // 选了固定比例就用标准尺寸；auto 跟随第一段素材。
        if let fixed = state.canvasRatio.fixedSize { return fixed }
        let size = state.mainClips.compactMap(\.info).first?.displaySize
            ?? state.overlayTracks.flatMap(\.clips).compactMap(\.info).first?.displaySize
            ?? CGSize(width: 1920, height: 1080)
        // yuv420 的世界里宽高都得是偶数。
        return CGSize(
            width: max(2, (size.width / 2).rounded() * 2),
            height: max(2, (size.height / 2).rounded() * 2)
        )
    }

    /// 把素材段插进合成轨。轨内必须连续，落点之前的空档用空段补齐。
    /// 变速在插完之后用 scaleTimeRange 拉伸。
    ///
    /// 截取范围要收口到**源轨自己的范围**里：音频流经常比视频流短一小截，
    /// 按视频时长去截音频会越界抛错 —— 整段声音就这么无声无息地丢了。
    private static func insert(
        source: AVAssetTrack,
        clip: EditClip,
        into track: AVMutableCompositionTrack,
        cursor: inout Double
    ) async -> Bool {
        let at = clip.timelineStart

        let trackRange = (try? await source.load(.timeRange))
            ?? CMTimeRange(start: .zero, duration: CMTime(seconds: clip.assetDuration, preferredTimescale: 600))
        let trackEnd = trackRange.end.seconds
        let start = max(clip.sourceStart, max(0, trackRange.start.seconds))
        let available = trackEnd - start
        guard available > 0.01, clip.sourceDuration > 0.01 else { return false }
        let sourceDuration = min(clip.sourceDuration, available)

        if at > cursor + 0.0005 {
            track.insertEmptyTimeRange(CMTimeRange(start: time(cursor), end: time(at)))
        }
        do {
            try track.insertTimeRange(
                CMTimeRange(start: time(start), duration: CMTime(seconds: sourceDuration, preferredTimescale: 600)),
                of: source,
                at: time(at)
            )
        } catch {
            return false
        }
        if abs(clip.speed - 1) > 0.001 {
            // 被收口的部分按同一比例折算，画面和声音才不会错位。
            let scaledDuration = clip.timelineDuration * (sourceDuration / clip.sourceDuration)
            track.scaleTimeRange(
                CMTimeRange(start: time(at), duration: CMTime(seconds: sourceDuration, preferredTimescale: 600)),
                toDuration: CMTime(seconds: scaledDuration, preferredTimescale: 600)
            )
        }
        cursor = at + clip.timelineDuration
        return true
    }

    /// 素材画面摆进输出画布的完整变换：源自带旋转摆正 → 裁切区挪到原点 →
    /// 缩放（翻转就是负缩放）→ 绕摆放框中心旋转 → 平移到摆放框。
    /// 摆放框：用户摆过的（placement）优先，否则默认布局（主轨等比铺满居中、
    /// 画中画按停靠位，都按**裁后的**宽高比）。返回的 cropRect 是换算回源轨
    /// 自然坐标系的裁切矩形，layer instruction 用它真正剪掉框外像素。
    private static func fittingTransform(
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        renderSize: CGSize,
        clip: EditClip,
        isOverlay: Bool
    ) -> (transform: CGAffineTransform, cropRect: CGRect?, geometry: ClipGeometry?) {
        let bounds = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let display = CGSize(width: abs(bounds.width), height: abs(bounds.height))
        guard display.width > 0, display.height > 0 else { return (.identity, nil, nil) }

        // 显示方向上的裁切区（没裁就是整幅）。
        let hasCrop = !(clip.crop?.isEmpty ?? true)
        let source = clip.crop.flatMap { $0.isEmpty ? nil : $0.rect(in: display) }
            ?? CGRect(origin: .zero, size: display)
        let geometry = ClipGeometry(
            preferredTransform: preferredTransform,
            boundsOrigin: CGPoint(x: bounds.minX, y: bounds.minY),
            sourceRect: source
        )

        // 摆放框：placement 或按裁后宽高比的默认布局。
        // 注意别用 clip.defaultPlacement —— 那个基于 probe 的 displaySize，
        // 和这里从源轨实测的尺寸可能差一两个像素，两边要用同一份。
        let target: CGRect
        if clip.isAnimated || clip.placement != nil {
            // 动画段（以及摆过的段）统一走归一化摆放：和预览里的交互框
            // 完全同一套换算，动画哪个分量没打关键帧就用它的静态/默认值。
            target = clip.animatedPlacement(atTimeline: clip.timelineStart, canvas: renderSize, isOverlay: isOverlay)
                .frame(in: renderSize)
        } else if isOverlay {
            let scale = renderSize.width * clip.overlayFraction / source.width
            let size = CGSize(width: source.width * scale, height: source.height * scale)
            let origin = clip.overlayAnchor.origin(
                canvas: renderSize,
                overlay: size,
                inset: renderSize.width * 0.02
            )
            target = CGRect(origin: origin, size: size)
        } else {
            let scale = min(renderSize.width / source.width, renderSize.height / source.height)
            let size = CGSize(width: source.width * scale, height: source.height * scale)
            target = CGRect(
                x: (renderSize.width - size.width) / 2,
                y: (renderSize.height - size.height) / 2,
                width: size.width,
                height: size.height
            )
        }

        let transform = placedTransform(
            geometry: geometry,
            target: target,
            rotationDegrees: clip.rotationDegrees,
            flippedHorizontally: clip.flippedHorizontally,
            flippedVertically: clip.flippedVertically
        )

        // 裁切矩形换算回自然坐标：显示矩形先挪回包围盒位置，再逆着源旋转变换。
        var cropRect: CGRect?
        if hasCrop {
            cropRect = source
                .offsetBy(dx: bounds.minX, dy: bounds.minY)
                .applying(preferredTransform.inverted())
                .standardized
        }
        return (transform, cropRect, clip.isAnimated ? geometry : nil)
    }

    /// 给定摆放框和旋转角，算完整变换（几何量固定，动画每片重算时只换这两个）。
    private static func placedTransform(
        geometry: ClipGeometry,
        target: CGRect,
        rotationDegrees: Double,
        flippedHorizontally: Bool,
        flippedVertically: Bool
    ) -> CGAffineTransform {
        let source = geometry.sourceRect
        guard source.width > 0, source.height > 0, target.width > 0, target.height > 0 else {
            return .identity
        }
        var transform = geometry.preferredTransform
            .concatenating(CGAffineTransform(translationX: -geometry.boundsOrigin.x, y: -geometry.boundsOrigin.y))
            .concatenating(CGAffineTransform(translationX: -source.minX, y: -source.minY))
            .concatenating(CGAffineTransform(
                scaleX: target.width / source.width * (flippedHorizontally ? -1 : 1),
                y: target.height / source.height * (flippedVertically ? -1 : 1)
            ))
        if flippedHorizontally || flippedVertically {
            transform = transform.concatenating(CGAffineTransform(
                translationX: flippedHorizontally ? target.width : 0,
                y: flippedVertically ? target.height : 0
            ))
        }
        if abs(rotationDegrees) > 0.01 {
            let radians = rotationDegrees * .pi / 180
            transform = transform
                .concatenating(CGAffineTransform(translationX: -target.width / 2, y: -target.height / 2))
                .concatenating(CGAffineTransform(rotationAngle: radians))
                .concatenating(CGAffineTransform(translationX: target.width / 2, y: target.height / 2))
        }
        return transform.concatenating(CGAffineTransform(translationX: target.minX, y: target.minY))
    }

    /// 动画段在某时刻的完整变换（摆放框 + 旋转都按关键帧取值）。
    private static func animatedTransform(
        _ item: PlacedClip,
        geometry: ClipGeometry,
        at timelineTime: Double,
        renderSize: CGSize
    ) -> CGAffineTransform {
        let clamped = min(max(timelineTime, item.start), item.end)
        let target = item.clip
            .animatedPlacement(atTimeline: clamped, canvas: renderSize, isOverlay: item.isOverlay)
            .frame(in: renderSize)
        return placedTransform(
            geometry: geometry,
            target: target,
            rotationDegrees: item.clip.animatedRotation(atTimeline: clamped),
            flippedHorizontally: item.clip.flippedHorizontally,
            flippedVertically: item.clip.flippedVertically
        )
    }

    /// 剪辑范围内的恒定音量；转场重叠区做交叉淡变。
    private static func addVolumeRamps(
        params: AVMutableAudioMixInputParameters,
        clip: EditClip,
        fadeIn: Double?,
        fadeOut: Double?
    ) {
        let volume = Float(clip.isMuted ? 0 : clip.volume)
        var bodyStart = clip.timelineStart
        var bodyEnd = clip.timelineEnd
        if let fadeIn, fadeIn > 0 {
            params.setVolumeRamp(
                fromStartVolume: 0, toEndVolume: volume,
                timeRange: CMTimeRange(start: time(clip.timelineStart), end: time(clip.timelineStart + fadeIn))
            )
            bodyStart += fadeIn
        }
        if let fadeOut, fadeOut > 0 { bodyEnd -= fadeOut }
        if bodyEnd > bodyStart {
            params.setVolumeRamp(
                fromStartVolume: volume, toEndVolume: volume,
                timeRange: CMTimeRange(start: time(bodyStart), end: time(bodyEnd))
            )
        }
        if let fadeOut, fadeOut > 0 {
            params.setVolumeRamp(
                fromStartVolume: volume, toEndVolume: 0,
                timeRange: CMTimeRange(start: time(clip.timelineEnd - fadeOut), end: time(clip.timelineEnd))
            )
        }
    }

    /// 按所有段落的边界切片，每一片描述「此刻谁可见、透明度怎么变」。
    private static func buildVideoComposition(
        placed: [PlacedClip],
        renderSize: CGSize,
        totalDuration: Double
    ) -> AVMutableVideoComposition {
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)

        var boundaries: Set<Double> = [0, totalDuration]
        for item in placed {
            boundaries.insert(item.start)
            boundaries.insert(item.end)
            if let fadeIn = item.fadeIn {
                boundaries.insert(item.start + fadeIn.duration)
                boundaries.insert(item.start + fadeIn.duration / 2)
            }
            if let fadeOut = item.fadeOut {
                boundaries.insert(item.end - fadeOut.duration)
                boundaries.insert(item.end - fadeOut.duration / 2)
            }
            addAnimationBoundaries(for: item, into: &boundaries)
        }
        let times = boundaries.filter { $0 >= 0 && $0 <= totalDuration }.sorted()

        var instructions: [AVMutableVideoCompositionInstruction] = []
        for index in 0..<(max(1, times.count) - 1) {
            let sliceStart = times[index]
            let sliceEnd = times[index + 1]
            guard sliceEnd - sliceStart > 0.0005 else { continue }
            let middle = (sliceStart + sliceEnd) / 2

            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: time(sliceStart), end: time(sliceEnd))
            instruction.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)

            // 可见的段：层级高的排前面（layerInstructions 第一个在最上面）。
            let active = placed
                .filter { $0.start - 0.0005 <= middle && middle < $0.end + 0.0005 && !$0.clip.isAudioOnly }
                .sorted { lhs, rhs in
                    if lhs.layer != rhs.layer { return lhs.layer > rhs.layer }
                    // 主轨重叠区：出场的那段画在上面，淡出后露出下面的进场段。
                    return lhs.start > rhs.start ? false : true
                }

            var layers: [AVMutableVideoCompositionLayerInstruction] = []
            for item in active {
                let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: item.track)
                if let geometry = item.geometry, item.clip.isAnimated {
                    let fromTransform = animatedTransform(item, geometry: geometry, at: sliceStart, renderSize: renderSize)
                    let toTransform = animatedTransform(item, geometry: geometry, at: sliceEnd, renderSize: renderSize)
                    if fromTransform == toTransform {
                        layer.setTransform(fromTransform, at: time(sliceStart))
                    } else {
                        layer.setTransformRamp(
                            fromStart: fromTransform,
                            toEnd: toTransform,
                            timeRange: CMTimeRange(start: time(sliceStart), end: time(sliceEnd))
                        )
                    }
                } else {
                    layer.setTransform(item.transform, at: time(sliceStart))
                }
                if let crop = item.cropRect {
                    layer.setCropRectangle(crop, at: time(sliceStart))
                }
                applyOpacity(layer, item: item, sliceStart: sliceStart, sliceEnd: sliceEnd)
                layers.append(layer)
            }
            instruction.layerInstructions = layers
            instructions.append(instruction)
        }

        videoComposition.instructions = instructions
        return videoComposition
    }

    /// 动画段的额外切片边界：位置/缩放/不透明度的斜坡本身是精确线性，
    /// 只要在每个关键帧处断片；旋转斜坡是矩阵线性插值（走弦不走弧，角度大了
    /// 明显缩小变形），相邻帧之间按 ≤6°/片加密；不透明度动画和转场衰减相乘
    /// 是二次曲线，斜坡只会线性，转场窗口内按 0.1s 加密补齐。
    private static func addAnimationBoundaries(for item: PlacedClip, into boundaries: inout Set<Double>) {
        guard let animation = item.clip.animation, !animation.isEmpty else { return }
        let clip = item.clip

        func insert(_ timelineTime: Double) {
            if timelineTime > item.start + 0.0005, timelineTime < item.end - 0.0005 {
                boundaries.insert(timelineTime)
            }
        }

        for sourceTime in animation.allKeyTimes {
            insert(clip.timelineTime(atSource: sourceTime))
        }

        let rotationKeys = animation.rotation.keys
        if rotationKeys.count >= 2 {
            for index in 1..<rotationKeys.count {
                let a = rotationKeys[index - 1]
                let b = rotationKeys[index]
                // 单段最多 400 片：十几圈的疯转宁可略糙，别把指令表撑爆。
                let steps = min(400, Int((abs(b.value - a.value) / 6).rounded(.up)))
                guard steps > 1 else { continue }
                for step in 1..<steps {
                    let sourceTime = a.time + (b.time - a.time) * Double(step) / Double(steps)
                    insert(clip.timelineTime(atSource: sourceTime))
                }
            }
        }

        if !animation.opacity.isEmpty {
            var windows: [(Double, Double)] = []
            if let fadeIn = item.fadeIn { windows.append((item.start, item.start + fadeIn.duration)) }
            if let fadeOut = item.fadeOut { windows.append((item.end - fadeOut.duration, item.end)) }
            for window in windows {
                var t = window.0
                while t < window.1 {
                    insert(t)
                    t += 0.1
                }
            }
        }
    }

    /// 一片时间里这段画面的透明度。转场的淡入淡出斜坡整体乘上剪辑自己的
    /// 不透明度（Transform 面板的 Opacity，可能带关键帧），两套互不干扰。
    private static func applyOpacity(
        _ layer: AVMutableVideoCompositionLayerInstruction,
        item: PlacedClip,
        sliceStart: Double,
        sliceEnd: Double
    ) {
        // 切片边界包含了所有折点（淡变起止/半程、关键帧、加密点），所以片内
        // 两个通道都是线性，端点求值就能精确重建整片；乘积的二次误差由
        // 0.1s 加密压到不可见。
        let from = fadeFactor(item: item, at: sliceStart)
            * Float(item.clip.animatedOpacity(atTimeline: min(max(sliceStart, item.start), item.end)))
        let to = fadeFactor(item: item, at: sliceEnd)
            * Float(item.clip.animatedOpacity(atTimeline: min(max(sliceEnd, item.start), item.end)))
        if abs(from - to) < 0.0005 {
            layer.setOpacity(from, at: time(sliceStart))
        } else {
            layer.setOpacityRamp(
                fromStartOpacity: from, toEndOpacity: to,
                timeRange: CMTimeRange(start: time(sliceStart), end: time(sliceEnd))
            )
        }
    }

    /// 转场淡入淡出在某时刻的衰减系数（0…1，片内线性）。
    private static func fadeFactor(item: PlacedClip, at timelineTime: Double) -> Float {
        var factor = 1.0
        if let fadeIn = item.fadeIn {
            let fadeStart = fadeIn.delayedHalf ? item.start + fadeIn.duration / 2 : item.start
            let fadeEnd = item.start + fadeIn.duration
            if timelineTime <= fadeStart {
                factor = 0
            } else if timelineTime < fadeEnd {
                factor = min(factor, (timelineTime - fadeStart) / max(0.001, fadeEnd - fadeStart))
            }
        }
        if let fadeOut = item.fadeOut {
            let fadeStart = item.end - fadeOut.duration
            let fadeEnd = fadeOut.earlyHalf ? item.end - fadeOut.duration / 2 : item.end
            if timelineTime >= fadeEnd {
                factor = 0
            } else if timelineTime > fadeStart {
                factor = min(factor, 1 - (timelineTime - fadeStart) / max(0.001, fadeEnd - fadeStart))
            }
        }
        return Float(min(max(factor, 0), 1))
    }
}
