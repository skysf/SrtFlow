import AVFoundation
import CoreGraphics
import Foundation

// 预览合成自检的测试素材：纯色 / 两色视频（AVAssetWriter 直接写，不依赖 ffmpeg），带声音的 WAV。
// 放临时目录 `root`（main.swift）。编译方式见 scripts/check-preview-composition.sh。

struct SolidVideoError: Error, CustomStringConvertible {
    let description: String
}

func makeSolidVideo(
    white: Double, seconds: Double, name: String, size: CGSize = CGSize(width: 64, height: 36)
) async throws -> URL {
    try await makeVideo(seconds: seconds, name: name, size: size) { _, _ in white }
}

/// 左半白右半黑的两色素材：分辨「擦除露出自己窗口外的进场段」和
/// 「推移把画面另半边滑进来」的关键探针（纯色素材下两者长得一样）。
func makeHalfToneVideo(
    seconds: Double, name: String, size: CGSize = CGSize(width: 64, height: 36)
) async throws -> URL {
    try await makeVideo(seconds: seconds, name: name, size: size) { column, width in
        column < width / 2 ? 1 : 0
    }
}

func makeVideo(
    seconds: Double, name: String, size: CGSize,
    brightness: (_ column: Int, _ width: Int) -> Double
) async throws -> URL {
    let url = root.appendingPathComponent(name)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: Int(size.width),
        AVVideoHeightKey: Int(size.height)
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height)
        ]
    )
    writer.add(input)
    guard writer.startWriting() else {
        throw SolidVideoError(description: "writer 起不来：\(writer.error?.localizedDescription ?? "?")")
    }
    writer.startSession(atSourceTime: .zero)
    guard let pool = adaptor.pixelBufferPool else {
        writer.cancelWriting()
        throw SolidVideoError(description: "拿不到 pixel buffer pool")
    }
    var buffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
    guard let buffer else {
        writer.cancelWriting()
        throw SolidVideoError(description: "拿不到 pixel buffer")
    }
    CVPixelBufferLockBaseAddress(buffer, [])
    if let base = CVPixelBufferGetBaseAddress(buffer) {
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let width = CVPixelBufferGetWidth(buffer)
        for row in 0..<CVPixelBufferGetHeight(buffer) {
            let words = (base + row * bytesPerRow).assumingMemoryBound(to: UInt32.self)
            for column in 0..<width {
                let level = UInt32(min(max(brightness(column, width), 0), 1) * 255)
                words[column] = 0xFF00_0000 | (level << 16) | (level << 8) | level
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    // 和产线 BlackBaseVideoFactory 同一课：isReadyForMoreMediaData 在 writer
    // 异步失败后可能永远为 false，等待必须有状态检查和截止时间，
    // 不然整个自检脚本挂死，连最后的 semaphore.signal() 都到不了。
    let fps = 10.0
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    for frame in 0..<Int(seconds * fps) {
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing, ContinuousClock.now < deadline else {
                writer.cancelWriting()
                throw SolidVideoError(
                    description: "写测试视频卡住或失败：status=\(writer.status.rawValue) "
                        + (writer.error?.localizedDescription ?? "")
                )
            }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        guard adaptor.append(
            buffer,
            withPresentationTime: CMTime(seconds: Double(frame) / fps, preferredTimescale: 600)
        ) else {
            writer.cancelWriting()
            throw SolidVideoError(
                description: "append 失败：\(writer.error?.localizedDescription ?? "?")"
            )
        }
    }
    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else {
        throw SolidVideoError(description: "写测试视频收尾失败：\(writer.error?.localizedDescription ?? "?")")
    }
    return url
}

/// 一段 48kHz 立体声 16 位的 WAV（440Hz 正弦），和 AI 在南极工程里生成的音效同一种格式。
func makeToneWAV(seconds: Double, name: String) throws -> URL {
    let url = root.appendingPathComponent(name)
    let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 2, interleaved: true)!
    let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
    let frames = AVAudioFrameCount((seconds * 48_000).rounded())
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    let samples = buffer.int16ChannelData![0]
    for frame in 0..<Int(frames) {
        let value = Int16(8_000 * sin(2 * Double.pi * 440 * Double(frame) / 48_000))
        samples[frame * 2] = value
        samples[frame * 2 + 1] = value
    }
    try file.write(from: buffer)
    return url
}
