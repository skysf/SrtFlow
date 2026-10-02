import AVFoundation
import Foundation

// MARK: - 从原片裁出送去 upscale 的那一段（只有画面）
//
// 管什么：原片 `[start, end)` → 一个 H.264 的 .mp4，原分辨率、原帧率、没有声音（声音做完再从原片封回去，UpscaleAudioMux），
// 码率按面积给足（送去放大的源别先被压坏；FLUX 限 50 MB，20 秒以内够用）。AVAssetReader → AVAssetWriter（VideoToolbox 硬编），
// 不开子进程、帧边界精确；读和编是阻塞的，**只在 MediaReadQueue.export 上跑**（docs/architecture/blocking-media-reads.md）。
// 照 OptimizedMediaTranscoder 的写法（拷贝像素缓冲、块尾之外的帧丢掉、writer 不收帧就等一小会儿）。
// 不管什么：裁哪一段（UpscaleRange）、整个文件要不要裁（UpscalePipeline：mp4 的整个文件直接上传）。

enum UpscaleSourceTrimmer {
    enum Failure: Error, Equatable {
        case noVideoTrack
        case readerFailed(String)
        case writerFailed(String)
        case cancelled
    }

    struct Source {
        let asset: AVAsset
        let track: AVAssetTrack
        let naturalSize: CGSize
        let preferredTransform: CGAffineTransform
        let nominalFrameRate: Double
        let duration: Double
    }

    /// 给送去放大的源的码率：每像素每帧 0.3 bit，6–20 Mbps 之间（20 秒 × 20 Mbps = 50 MB，正好是 FLUX 的上限）。
    static func bitRate(for size: CGSize, frameRate: Double) -> Int {
        let raw = size.width * size.height * max(1, frameRate) * 0.3
        return Int(min(20_000_000, max(6_000_000, raw)))
    }

    static func load(_ url: URL) async -> Result<Source, Failure> {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return .failure(.noVideoTrack) }
        guard let (natural, transform, fps) = try? await track.load(.naturalSize, .preferredTransform, .nominalFrameRate),
              let duration = try? await asset.load(.duration) else { return .failure(.readerFailed("load")) }
        return .success(Source(asset: asset, track: track, naturalSize: natural, preferredTransform: transform,
                               nominalFrameRate: Double(fps), duration: duration.seconds))
    }

    /// 裁 `[start, end)` 到 `output`。**只在 MediaReadQueue.export 上调。** 文件自己的时间从 0 起 = 原片的 `start`。
    static func trim(_ source: Source, start: Double, end: Double, to output: URL, isCancelled: () -> Bool = { false }) -> Result<URL, Failure> {
        let end = min(end, source.duration)
        guard end - start > 0.001 else { return .failure(.readerFailed("范围在源的结尾之外")) }
        let startTime = CMTime(seconds: start, preferredTimescale: 600)
        let endTime = CMTime(seconds: end, preferredTimescale: 600)
        guard let reader = try? AVAssetReader(asset: source.asset) else { return .failure(.readerFailed("AVAssetReader")) }
        let readerOutput = AVAssetReaderTrackOutput(track: source.track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        readerOutput.alwaysCopiesSampleData = true
        guard reader.canAdd(readerOutput) else { return .failure(.readerFailed("canAdd")) }
        reader.add(readerOutput)
        reader.timeRange = CMTimeRange(start: startTime, end: endTime)

        try? FileManager.default.removeItem(at: output)
        guard let writer = try? AVAssetWriter(outputURL: output, fileType: .mp4) else { return .failure(.writerFailed("AVAssetWriter")) }
        let size = source.naturalSize
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate(for: size, frameRate: source.nominalFrameRate),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: max(1, Int(source.nominalFrameRate.rounded())),
            ] as [String: Any],
        ])
        input.expectsMediaDataInRealTime = false
        input.transform = source.preferredTransform
        guard writer.canAdd(input) else { return .failure(.writerFailed("canAdd")) }
        writer.add(input)
        guard reader.startReading() else { return .failure(.readerFailed(reader.error?.localizedDescription ?? "startReading")) }
        guard writer.startWriting() else {
            reader.cancelReading()
            return .failure(.writerFailed(writer.error?.localizedDescription ?? "startWriting"))
        }
        writer.startSession(atSourceTime: startTime)

        var appended = 0
        while let buffer = readerOutput.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
            // 读取器按 GOP 解，范围之外的帧也会吐出来：不要。
            if pts < startTime || pts >= endTime { continue }
            if isCancelled() {
                reader.cancelReading()
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: output)
                return .failure(.cancelled)
            }
            var waited = 0
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing, waited < 10_000 else {
                    reader.cancelReading()
                    writer.cancelWriting()
                    return .failure(.writerFailed("not ready after \(appended) frames"))
                }
                usleep(1000)
                waited += 1
            }
            guard input.append(buffer) else {
                reader.cancelReading()
                writer.cancelWriting()
                return .failure(.writerFailed("append frame \(appended): \(writer.error?.localizedDescription ?? "?")"))
            }
            appended += 1
        }
        if reader.status == .failed {
            writer.cancelWriting()
            return .failure(.readerFailed(reader.error?.localizedDescription ?? "reading"))
        }
        guard appended > 0 else {
            writer.cancelWriting()
            return .failure(.readerFailed("这一段一帧都没读到"))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: endTime)
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        finished.wait()
        guard writer.status == .completed else { return .failure(.writerFailed(writer.error?.localizedDescription ?? "finishWriting")) }
        return .success(output)
    }
}
