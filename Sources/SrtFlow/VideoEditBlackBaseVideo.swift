import AVFoundation
import CoreVideo
import Foundation

// MARK: - 预览合成垫底的纯色素材
//
// 2026-09-24 从 VideoEditCompositionBuilder.swift 原样搬出来：那个文件超过了 600 行的上限
//（docs/architecture/coding-standards.md），而这个工厂本来就是独立的一件事 —— 只负责「有一段能用
// 的纯色视频」，合成怎么用它是 builder 的事。

/// 预览合成的纯色底素材：64×36 的两帧纯色 H.264，AVAssetWriter 直接生成，
/// 不依赖 ffmpeg。黑底垫在半透明合成下面；白底给上层轨关键帧段的蒙版
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
