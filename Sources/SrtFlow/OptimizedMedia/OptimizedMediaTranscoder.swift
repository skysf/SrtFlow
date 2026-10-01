import AVFoundation
import Foundation

// MARK: - 把一个源的一块转成密关键帧的代理
//
// 管什么：源时间 `[10i, 10i + 10)` 这一块 → 一个 .mov（原分辨率 / 4K 减半的 H.264，0.5 秒一个关键帧、没有 B 帧，
// 只有画面，旋转矩阵照抄），落到 OptimizedMediaStore。读和编都是阻塞的，跑在 `MediaReadQueue.proxy` 上
//（docs/architecture/blocking-media-reads.md）。
// 不管什么：转哪些块、什么时候转（V2 的队列）、换进预览（builder，V2）。
//
// 用 AVAssetReader → AVAssetWriter（VideoToolbox 硬编）而不是 ffmpeg：不开子进程、帧边界精确、和预览合成同一套 AVFoundation。
// 10-bit / HDR 的源（iPhone 的 HLG / Dolby Vision）第一版先不转（H.264 只有 8-bit，转了颜色会变灰）：报 `unsupportedSource`，
// 调用方照用原片。HEVC Main10 的代理是后面一刀。

enum OptimizedMediaTranscoder {
    enum Failure: Error, Equatable {
        case noVideoTrack
        case unsupportedSource(String)
        case readerFailed(String)
        case writerFailed(String)
        case cancelled
    }

    /// 转码要的几样源的属性（在 async 里先加载好，阻塞的那一段只做读和编）。
    struct Source {
        let asset: AVAsset
        let track: AVAssetTrack
        let naturalSize: CGSize
        let preferredTransform: CGAffineTransform
        let nominalFrameRate: Double
        let duration: Double
        let identity: OptimizedMediaStore.SourceIdentity

        /// 8-bit、SDR 才转得了。
        var unsupportedReason: String? {
            guard let format = track.formatDescriptions.first else { return nil }
            let description = format as! CMFormatDescription
            if let bits = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_BitsPerComponent) as? Int,
               bits > 8 {
                return "\(bits)-bit"
            }
            if let transfer = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String,
               transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
                || transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String) {
                return "HDR (\(transfer))"
            }
            return nil
        }
    }

    /// 加载源的属性。
    static func load(_ url: URL) async -> Result<Source, Failure> {
        guard let identity = OptimizedMediaStore.SourceIdentity(url: url) else { return .failure(.readerFailed("stat")) }
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return .failure(.noVideoTrack) }
        guard let (natural, transform, fps) = try? await track.load(.naturalSize, .preferredTransform, .nominalFrameRate),
              let duration = try? await asset.load(.duration) else { return .failure(.readerFailed("load")) }
        _ = try? await track.load(.formatDescriptions)
        let source = Source(asset: asset, track: track, naturalSize: natural, preferredTransform: transform,
                            nominalFrameRate: Double(fps), duration: duration.seconds, identity: identity)
        if let reason = source.unsupportedReason { return .failure(.unsupportedSource(reason)) }
        return .success(source)
    }

    /// 转第 `chunk` 块：源时间 `[chunk × 10, +10)`（最后一块到源的结尾）。**只在 MediaReadQueue.proxy 上调。**
    /// `isCancelled` 每读一帧问一次。成功返回落好的块文件。
    static func transcode(
        _ source: Source, chunk: Int, isCancelled: () -> Bool = { false }
    ) -> Result<URL, Failure> {
        let range = OptimizedMediaPolicy.chunkRange(chunk)
        let start = range.lowerBound
        let end = min(range.upperBound, source.duration)
        guard end - start > 0.001 else { return .failure(.readerFailed("块在源的结尾之外")) }
        let size = OptimizedMediaPolicy.targetSize(forNatural: source.naturalSize)

        let startTime = CMTime(seconds: start, preferredTimescale: 600)
        let endTime = CMTime(seconds: end, preferredTimescale: 600)
        let frameDuration = OptimizedMediaPolicy.proxyFrameDuration(sourceFPS: source.nominalFrameRate)

        guard let reader = try? AVAssetReader(asset: source.asset) else { return .failure(.readerFailed("AVAssetReader")) }
        // 经视频合成读：时间范围的起点先出一帧、之后画面变了才出帧（变帧率的录屏静止期没有帧，一帧撑到下一次变化）、顺手缩到目标尺寸。
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: [source.track], videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        // **必须拷贝**：合成输出的像素缓冲交给编码器之后还在它手里，不拷贝的话读取器下一帧就把那块内存回收重用，
        // 编码器在第 4、5 帧上报 kVTParameterErr（-12902）—— 时有时无（2026-10-01 探针：不拷贝 3/4 红、拷贝 0/4）。
        output.alwaysCopiesSampleData = true
        output.videoComposition = resampling(source: source, size: size, frameDuration: frameDuration)
        guard reader.canAdd(output) else { return .failure(.readerFailed("canAdd")) }
        reader.add(output)
        reader.timeRange = CMTimeRange(start: startTime, end: endTime)

        let temporary = OptimizedMediaStore.temporaryURL(for: source.identity)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let writer = try? AVAssetWriter(outputURL: temporary, fileType: .mov) else { return .failure(.writerFailed("AVAssetWriter")) }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoScalingModeKey: AVVideoScalingModeResize,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: OptimizedMediaPolicy.bitRate(for: size),
                AVVideoMaxKeyFrameIntervalDurationKey: OptimizedMediaPolicy.keyframeInterval,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: max(1, Int((1 / frameDuration.seconds).rounded())),
            ] as [String: Any],
        ])
        input.expectsMediaDataInRealTime = false
        input.transform = source.preferredTransform
        guard writer.canAdd(input) else { return .failure(.writerFailed("canAdd")) }
        writer.add(input)

        guard reader.startReading() else { return .failure(.readerFailed(reader.error?.localizedDescription ?? "startReading")) }
        guard writer.startWriting() else {
            reader.cancelReading()
            return .failure(.writerFailed("startWriting: \(describe(writer.error))"))
        }
        // 块文件自己的时间从 0 起 = 源的 `start`。
        writer.startSession(atSourceTime: startTime)

        var appended = 0
        while let buffer = output.copyNextSampleBuffer() {
            // 读取器按 GOP 解，块尾之外的几帧也会吐出来：不要。
            let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
            if pts >= endTime { continue }
            if isCancelled() {
                reader.cancelReading()
                writer.cancelWriting()
                return .failure(.cancelled)
            }
            // 块头落在两帧之间（29.97、变帧率的录屏）也不用挪：合成器在时间范围的起点先出一帧（探针：29.97 的源从 10 秒读，
            // 第一帧 10.000、第二帧 10.010），块的时间真从 0 起、第一截才插得进合成（合成轨只能引用源轨范围之内的时间）。
            let sample = buffer
            // 编码器吃不下就等一小会儿；writer 已经失败了就别等了（isReadyForMoreMediaData 可能永远不回来）。
            var waited = 0
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing, waited < 10_000 else {
                    reader.cancelReading()
                    writer.cancelWriting()
                    return .failure(.writerFailed("not ready after \(appended) frames (status \(writer.status.rawValue)): \(describe(writer.error))"))
                }
                usleep(1000)
                waited += 1
            }
            guard input.append(sample) else {
                reader.cancelReading()
                writer.cancelWriting()
                return .failure(.writerFailed("append frame \(appended) at \(pts.seconds): \(describe(writer.error))"))
            }
            appended += 1
        }
        if reader.status == .failed {
            writer.cancelWriting()
            return .failure(.readerFailed(reader.error?.localizedDescription ?? "reading"))
        }
        guard appended > 0 else {
            writer.cancelWriting()
            return .failure(.readerFailed("这一块一帧都没读到"))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: end, preferredTimescale: 600))
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        finished.wait()
        guard writer.status == .completed else {
            return .failure(.writerFailed("finishWriting after \(appended) frames: \(describe(writer.error))"))
        }
        do {
            return .success(try OptimizedMediaStore.commit(chunk: chunk, temporary: temporary, for: source.identity))
        } catch {
            return .failure(.writerFailed("commit: \(error)"))
        }
    }

    /// 读的时候套的视频合成：`frameDuration` 的格子、输出 `size`（4K 减半就在这儿缩），不转方向（旋转矩阵抄进块的轨道）。
    static func resampling(source: Source, size: CGSize, frameDuration: CMTime) -> AVMutableVideoComposition {
        let composition = AVMutableVideoComposition()
        composition.renderSize = size
        composition.frameDuration = frameDuration
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: max(1, source.duration + 1), preferredTimescale: 600))
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: source.track)
        let natural = source.naturalSize
        if natural.width > 0, natural.height > 0, natural != size {
            layer.setTransform(CGAffineTransform(scaleX: size.width / natural.width, y: size.height / natural.height), at: .zero)
        }
        instruction.layerInstructions = [layer]
        composition.instructions = [instruction]
        return composition
    }

    /// 报错时把域、码和底层的错一起写上（"The operation could not be completed" 一句什么都看不出来）。
    static func describe(_ error: Error?) -> String {
        guard let error = error as NSError? else { return "no error" }
        var text = "\(error.domain) \(error.code) \(error.localizedDescription)"
        if let reason = error.userInfo[NSLocalizedFailureReasonErrorKey] as? String { text += " — \(reason)" }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError { text += " (underlying \(underlying.domain) \(underlying.code))" }
        return text
    }
}
