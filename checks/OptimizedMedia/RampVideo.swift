import AVFoundation
import CoreGraphics
import Foundation

// 优化媒体自检的素材：AVAssetWriter 直接写的 H.264（不依赖 ffmpeg），亮度随时间从黑到白线性变化（每一帧的灰度 =
// 时间 ÷ 总长），关键帧间隔由 `keyframeEvery`（帧数）定 —— 长 GOP 的源就是这么造出来的。放临时目录 `root`（main.swift）。

struct FixtureError: Error, CustomStringConvertible {
    let description: String
}

/// `firstFrameOffset`：每一帧都往后挪这么多（块头落在两帧之间的源）；`gap`：这一段帧号的帧不写（变帧率的录屏：静止期没有帧）。
/// `frameDuration`：不传就是 1/fps；传 1001/30000 就是 29.97 fps 那种不落在整秒上的格子（块头 10 秒落在两帧之间）。
func makeRampVideo(
    seconds: Double, fps: Int, size: CGSize, keyframeEvery: Int?, name: String,
    firstFrameOffset: CMTime = .zero, gap: Range<Int>? = nil, frameDuration: CMTime? = nil
) async throws -> URL {
    let url = root.appendingPathComponent(name)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    var compression: [String: Any] = [AVVideoAllowFrameReorderingKey: false]
    if let keyframeEvery { compression[AVVideoMaxKeyFrameIntervalKey] = keyframeEvery }
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: Int(size.width),
        AVVideoHeightKey: Int(size.height),
        AVVideoCompressionPropertiesKey: compression,
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
        ]
    )
    writer.add(input)
    guard writer.startWriting() else { throw FixtureError(description: "writer 起不来：\(writer.error?.localizedDescription ?? "?")") }
    writer.startSession(atSourceTime: .zero)
    guard let pool = adaptor.pixelBufferPool else { throw FixtureError(description: "拿不到 pixel buffer pool") }
    let frames = Int((seconds * Double(fps)).rounded())
    for frame in 0..<frames {
        if let gap, gap.contains(frame) { continue }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { throw FixtureError(description: "拿不到 pixel buffer") }
        let gray = UInt32(min(255, max(0, Int((Double(frame) / Double(max(1, frames - 1)) * 255).rounded()))))
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            let count = CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer) / 4
            let words = base.assumingMemoryBound(to: UInt32.self)
            let pixel = 0xFF00_0000 | (gray << 16) | (gray << 8) | gray
            for index in 0..<count { words[index] = pixel }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        var waited = 0
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing, waited < 5000 else { throw FixtureError(description: "writer 不收帧") }
            try await Task.sleep(nanoseconds: 1_000_000)
            waited += 1
        }
        let pts = frameDuration.map { CMTimeMultiply($0, multiplier: Int32(frame)) } ?? CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))
        guard adaptor.append(buffer, withPresentationTime: pts + firstFrameOffset) else {
            throw FixtureError(description: "append 失败：\(writer.error?.localizedDescription ?? "?")")
        }
    }
    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else { throw FixtureError(description: "finishWriting：\(writer.error?.localizedDescription ?? "?")") }
    return url
}

/// 某一刻那一帧的平均亮度（0…1）。
func brightness(of url: URL, at seconds: Double) async -> Double {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 60)
    generator.appliesPreferredTrackTransform = true
    guard let (image, _) = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)) else { return -1 }
    let width = image.width, height = image.height
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let data = context.data.map({ $0.assumingMemoryBound(to: UInt8.self) }) else { return -1 }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    var sum = 0.0
    for index in stride(from: 0, to: width * height * 4, by: 4) {
        sum += (Double(data[index]) + Double(data[index + 1]) + Double(data[index + 2])) / 3
    }
    return sum / Double(width * height) / 255
}

/// 直通读一遍画面轨：几帧、解码时间戳和显示时间戳一不一样（有 B 帧就不一样）。
func passthroughStats(of url: URL) async -> (frames: Int, reordered: Int)? {
    let asset = AVURLAsset(url: url)
    guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return nil }
    nonisolated(unsafe) let videoTrack = track
    nonisolated(unsafe) let readerAsset = asset
    return await MediaReadQueue.run(on: MediaReadQueue.detail) {
        guard let reader = try? AVAssetReader(asset: readerAsset) else { return nil }
        let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        reader.add(output)
        guard reader.startReading() else { return nil }
        var frames = 0, reordered = 0
        while let buffer = output.copyNextSampleBuffer() {
            // 直通读取夹着的零采样标记缓冲不是帧（MediaKeyframeProbe 同样跳过）。
            guard CMSampleBufferGetNumSamples(buffer) > 0 else { continue }
            frames += 1
            let dts = CMSampleBufferGetDecodeTimeStamp(buffer)
            let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
            if dts.isValid, abs(dts.seconds - pts.seconds) > 0.0001 { reordered += 1 }
        }
        return (frames, reordered)
    }
}
