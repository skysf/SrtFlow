import AVFoundation
import Foundation

// MARK: - 这台机器解码有多快（fps）：量一次、记下来
//
// 管什么：用一段真实素材解若干帧，算出这台机器（VideoToolbox）的解码速度，按「机型 + 系统版本」记在 UserDefaults 里；
// 要不要转优化媒体的判据（OptimizedMediaPolicy）拿它算「一个 GOP 要解多久」。
// 不管什么：拿哪一段素材去量（调用方给；没有合适的就用现造的小视频，量出来偏快 —— 宁可多转）。
//
// 解码是阻塞的，跑在 MediaReadQueue 上（docs/architecture/blocking-media-reads.md）。

enum DecodeSpeedProbe {
    static let defaultsKeyPrefix = "optimizedMedia.decodeFPS."

    /// 记下来用的键：换机型 / 换 macOS 大版本就重量。
    static var machineKey: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(defaultsKeyPrefix)\(hardwareModel).\(version.majorVersion)"
    }

    static var hardwareModel: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var bytes = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &bytes, &size, nil, 0)
        return String(cString: bytes)
    }

    /// 上次量到的（没量过就是 nil）。
    static func remembered(defaults: UserDefaults = .standard) -> Double? {
        let value = defaults.double(forKey: machineKey)
        return value > 0 ? value : nil
    }

    static func remember(_ fps: Double, defaults: UserDefaults = .standard) {
        defaults.set(fps, forKey: machineKey)
    }

    /// 解 `frames` 帧（或读到文件尾）量速度；文件太短、读不出画面轨 → nil。
    static func measure(sample url: URL, frames: Int = 120) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return nil }
        nonisolated(unsafe) let videoTrack = track
        nonisolated(unsafe) let readerAsset = asset
        return await MediaReadQueue.run(on: MediaReadQueue.detail) {
            decodeRate(asset: readerAsset, track: videoTrack, frames: frames)
        }
    }

    /// 阻塞地解帧计时。**只在 MediaReadQueue 上调。**
    static func decodeRate(asset: AVAsset, track: AVAssetTrack, frames: Int) -> Double? {
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        defer { reader.cancelReading() }
        var decoded = 0
        let start = ProcessInfo.processInfo.systemUptime
        while decoded < frames, let buffer = output.copyNextSampleBuffer() {
            if CMSampleBufferGetImageBuffer(buffer) != nil { decoded += 1 }
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        guard decoded >= 10, elapsed > 0 else { return nil }
        return Double(decoded) / elapsed
    }
}
