import AVFoundation

// 性能测试里 GPU / 解码那一侧的代理数字（docs/architecture/preview-perf-ratchet.md）。
//
// 预览的合成交给系统合成器在 GPU 上做，它的 GPU 时间不记在我们进程头上（2026-09-24
// 探针：按进程统计的 GPU 时间读出来是 0），CI 的虚拟机也读不到能耗。所以这里不量
// 「GPU 忙了多久」，而是从我们交给系统的那份合成指令里**数它要做多少活**：
//
// - `layerFrames`：每一帧要合成几层，全片加总（一层就是一路解码 + 一次混合）；
// - `megapixelFrames`：每一帧每一层实际落在画布上的像素，全片加总（百万像素·帧）；
// - `filterFrames`：每一帧挂了几层滤镜，全片加总（滤镜在 GPU 上逐像素算）。
//
// 这几个数只能靠「不做看不见的活」降下来（被整个盖住的层、全透明的段、强度为 0 的
// 滤镜），画面不会变 —— 用户拍过板：不许拿画质换数字。

enum PreviewBenchComposition {
    struct Load {
        var compositionTracks: Int
        var layerFrames: Int
        var megapixelFrames: Int
        var filterFrames: Int
    }

    @MainActor
    static func measure(item: AVPlayerItem?, project: VideoEditProject) async throws -> Load {
        guard let item, let composition = item.asset as? AVComposition,
              let videoComposition = item.videoComposition else {
            throw PreviewBench.Failure("预览没有合成（播放条目不是 AVComposition 或没有 videoComposition）")
        }
        let videoTracks = try await composition.loadTracks(withMediaType: .video)
        var naturalSizes: [CMPersistentTrackID: CGSize] = [:]
        for track in videoTracks {
            naturalSizes[track.trackID] = try await track.load(.naturalSize)
        }
        let duration = try await composition.load(.duration)
        let step = videoComposition.frameDuration
        guard step.seconds > 0, duration.seconds > 0 else {
            throw PreviewBench.Failure("合成的时长或帧长是 0")
        }

        let canvas = CGRect(origin: .zero, size: videoComposition.renderSize)
        let instructions = videoComposition.instructions.compactMap { $0 as? AVVideoCompositionInstruction }
        let frameCount = Int((duration.seconds / step.seconds).rounded(.down))
        var layerFrames = 0
        var pixels = 0.0
        var filterFrames = 0
        for frame in 0..<frameCount {
            let time = CMTimeMultiply(step, multiplier: Int32(frame))
            filterFrames += project.activeFilters(at: time.seconds).count
            guard let instruction = instructions.first(where: { $0.timeRange.containsTime(time) }) else { continue }
            for layer in instruction.layerInstructions {
                guard opacity(of: layer, at: time) > 0.001,
                      let natural = naturalSizes[layer.trackID] else { continue }
                let source = crop(of: layer, at: time) ?? CGRect(origin: .zero, size: natural)
                let visible = source.applying(transform(of: layer, at: time)).intersection(canvas)
                guard !visible.isNull, visible.width > 0, visible.height > 0 else { continue }
                layerFrames += 1
                pixels += visible.width * visible.height
            }
        }
        return Load(
            compositionTracks: videoTracks.count,
            layerFrames: layerFrames,
            megapixelFrames: Int((pixels / 1_000_000).rounded()),
            filterFrames: filterFrames
        )
    }

    // MARK: - 斜坡取值（和合成器一样按时间线性插值）

    private static func fraction(_ time: CMTime, in range: CMTimeRange) -> Double {
        let length = range.duration.seconds
        guard length > 0 else { return 0 }
        return min(max((time - range.start).seconds / length, 0), 1)
    }

    private static func opacity(of layer: AVVideoCompositionLayerInstruction, at time: CMTime) -> Double {
        var start: Float = 1
        var end: Float = 1
        var range = CMTimeRange.zero
        guard layer.getOpacityRamp(for: time, startOpacity: &start, endOpacity: &end, timeRange: &range) else {
            return 1
        }
        let t = fraction(time, in: range)
        return Double(start) + (Double(end) - Double(start)) * t
    }

    private static func transform(of layer: AVVideoCompositionLayerInstruction, at time: CMTime) -> CGAffineTransform {
        var start = CGAffineTransform.identity
        var end = CGAffineTransform.identity
        var range = CMTimeRange.zero
        guard layer.getTransformRamp(for: time, start: &start, end: &end, timeRange: &range) else {
            return .identity
        }
        let t = CGFloat(fraction(time, in: range))
        return CGAffineTransform(
            a: start.a + (end.a - start.a) * t, b: start.b + (end.b - start.b) * t,
            c: start.c + (end.c - start.c) * t, d: start.d + (end.d - start.d) * t,
            tx: start.tx + (end.tx - start.tx) * t, ty: start.ty + (end.ty - start.ty) * t
        )
    }

    private static func crop(of layer: AVVideoCompositionLayerInstruction, at time: CMTime) -> CGRect? {
        var start = CGRect.zero
        var end = CGRect.zero
        var range = CMTimeRange.zero
        guard layer.getCropRectangleRamp(
            for: time, startCropRectangle: &start, endCropRectangle: &end, timeRange: &range
        ) else { return nil }
        let t = CGFloat(fraction(time, in: range))
        return CGRect(
            x: start.minX + (end.minX - start.minX) * t, y: start.minY + (end.minY - start.minY) * t,
            width: start.width + (end.width - start.width) * t, height: start.height + (end.height - start.height) * t
        )
    }
}
