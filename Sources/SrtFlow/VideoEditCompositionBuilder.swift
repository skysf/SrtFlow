import AVFoundation
import Foundation

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

    /// 预览里参与画面合成的一段（换算好合成轨和转场之后的产物）。
    private struct PlacedClip {
        var clip: EditClip
        /// 这段落在哪条合成轨上。layer instruction 要拿它当 assetTrack 用。
        var track: AVMutableCompositionTrack
        var transform: CGAffineTransform
        /// 画面的叠放层级，越大越靠上（主轨 0，画中画 1+轨号）。
        var layer: Int
        var start: Double { clip.timelineStart }
        var end: Double { clip.timelineEnd }
        /// 开头的淡入（跟上一段的转场决定），(时长, 后半才亮?)。
        var fadeIn: (duration: Double, delayedHalf: Bool)?
        /// 结尾的淡出，(时长, 前半就灭?)。
        var fadeOut: (duration: Double, earlyHalf: Bool)?
    }

    static func build(from state: TimelineState) async -> Built? {
        guard !state.isEmpty else { return nil }

        let composition = AVMutableComposition()
        var placed: [PlacedClip] = []
        var audioParams: [AVMutableAudioMixInputParameters] = []

        // 输出尺寸：第一段主轨素材说了算。
        let renderSize = Self.renderSize(for: state)

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
            let transform = fittingTransform(
                naturalSize: naturalSize,
                preferredTransform: preferred,
                renderSize: renderSize,
                placement: clip.placement,
                overlay: nil
            )

            // 进出场的渐变由前后两个转场决定。
            let overlapBefore = index > 0 ? state.transitionOverlap(afterMainIndex: index - 1) : 0
            let overlapAfter = state.transitionOverlap(afterMainIndex: index)
            let kindBefore = index > 0 ? state.mainClips[index - 1].transitionAfter : .none
            let kindAfter = clip.transitionAfter

            var item = PlacedClip(
                clip: clip,
                track: videoTrack,
                transform: transform,
                layer: 0
            )
            if overlapBefore > 0 {
                // 叠化：后段整场垫在底下，不用淡入。压黑/闪白：后半段才亮起来。
                if kindBefore != .crossFade {
                    item.fadeIn = (overlapBefore, true)
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
                let transform = fittingTransform(
                    naturalSize: naturalSize,
                    preferredTransform: preferred,
                    renderSize: renderSize,
                    placement: clip.placement,
                    overlay: (clip.overlayFraction, clip.overlayAnchor)
                )
                placed.append(PlacedClip(
                    clip: clip,
                    track: videoTrack,
                    transform: transform,
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
        if !audioParams.isEmpty {
            let mix = AVMutableAudioMix()
            mix.inputParameters = audioParams
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

    /// 素材画面摆进输出画布的变换：先按源自带的旋转摆正，把包围盒挪回原点，
    /// 再缩放，最后平移到位（主画面居中、画中画按停靠位）。
    /// 用户在预览里摆过的（`placement`）优先：直接非等比缩放进那个归一化框。
    private static func fittingTransform(
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        renderSize: CGSize,
        placement: ClipPlacement?,
        overlay: (fraction: Double, anchor: OverlayAnchor)?
    ) -> CGAffineTransform {
        let bounds = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let display = CGSize(width: abs(bounds.width), height: abs(bounds.height))
        guard display.width > 0, display.height > 0 else { return .identity }

        if let placement {
            let target = placement.frame(in: renderSize)
            return preferredTransform
                .concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
                .concatenating(CGAffineTransform(
                    scaleX: target.width / display.width,
                    y: target.height / display.height
                ))
                .concatenating(CGAffineTransform(translationX: target.minX, y: target.minY))
        }

        let scale: Double
        let origin: CGPoint
        if let overlay {
            scale = renderSize.width * overlay.fraction / display.width
            let scaled = CGSize(width: display.width * scale, height: display.height * scale)
            origin = overlay.anchor.origin(
                canvas: renderSize,
                overlay: scaled,
                inset: renderSize.width * 0.02
            )
        } else {
            scale = min(renderSize.width / display.width, renderSize.height / display.height)
            let scaled = CGSize(width: display.width * scale, height: display.height * scale)
            origin = CGPoint(x: (renderSize.width - scaled.width) / 2, y: (renderSize.height - scaled.height) / 2)
        }

        return preferredTransform
            .concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: origin.x, y: origin.y))
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
                layer.setTransform(item.transform, at: time(sliceStart))
                applyOpacity(layer, item: item, sliceStart: sliceStart, sliceEnd: sliceEnd)
                layers.append(layer)
            }
            instruction.layerInstructions = layers
            instructions.append(instruction)
        }

        videoComposition.instructions = instructions
        return videoComposition
    }

    /// 一片时间里这段画面的透明度。
    private static func applyOpacity(
        _ layer: AVMutableVideoCompositionLayerInstruction,
        item: PlacedClip,
        sliceStart: Double,
        sliceEnd: Double
    ) {
        // 淡入
        if let fadeIn = item.fadeIn {
            let fadeStart = fadeIn.delayedHalf ? item.start + fadeIn.duration / 2 : item.start
            let fadeEnd = item.start + fadeIn.duration
            if sliceStart < fadeEnd, sliceEnd > item.start {
                if sliceStart < fadeStart {
                    layer.setOpacity(0, at: time(sliceStart))
                }
                if sliceEnd > fadeStart, sliceStart < fadeEnd {
                    let rampStart = max(sliceStart, fadeStart)
                    let rampEnd = min(sliceEnd, fadeEnd)
                    if rampEnd > rampStart {
                        let from = Float((rampStart - fadeStart) / max(0.001, fadeEnd - fadeStart))
                        let to = Float((rampEnd - fadeStart) / max(0.001, fadeEnd - fadeStart))
                        layer.setOpacityRamp(
                            fromStartOpacity: from, toEndOpacity: to,
                            timeRange: CMTimeRange(start: time(rampStart), end: time(rampEnd))
                        )
                    }
                }
                return
            }
        }
        // 淡出
        if let fadeOut = item.fadeOut {
            let fadeStart = item.end - fadeOut.duration
            let fadeEnd = fadeOut.earlyHalf ? item.end - fadeOut.duration / 2 : item.end
            if sliceEnd > fadeStart, sliceStart < item.end {
                if sliceStart >= fadeEnd {
                    layer.setOpacity(0, at: time(sliceStart))
                    return
                }
                let rampStart = max(sliceStart, fadeStart)
                let rampEnd = min(sliceEnd, fadeEnd)
                if rampEnd > rampStart {
                    let from = Float(1 - (rampStart - fadeStart) / max(0.001, fadeEnd - fadeStart))
                    let to = Float(1 - (rampEnd - fadeStart) / max(0.001, fadeEnd - fadeStart))
                    layer.setOpacityRamp(
                        fromStartOpacity: from, toEndOpacity: to,
                        timeRange: CMTimeRange(start: time(rampStart), end: time(rampEnd))
                    )
                }
                return
            }
        }
        layer.setOpacity(1, at: time(sliceStart))
    }
}
