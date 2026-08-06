import AVFoundation
import Foundation
import SrtFlowCore

// 按源区间抽音频（docs/plans/2026-08-06-native-subtitle-generation.md 11.3）。
//
// 走计划里的稳妥路径：AVAssetReader 按 timeRange 读 16k/16bit/单声道 PCM，
// 落成临时 CAF，喂 SpeechAnalyzer 的 inputAudioFile（官方支持的文件输入，
// Phase 0 spike 已实测跑通）。窗口级临时文件用完即删，defer 兜底；
// 内存里永远只有一个采样块。

enum AudioWindowReader {

    /// 素材本身读不了（缺音轨、解码失败……）：调用方可按「单素材跳过」处理。
    struct ReadError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// 我们自己的基础设施出问题（临时文件建不了、PCM 格式造不出……）：
    /// **不是**素材的错，调用方必须整体失败并保留原始原因，
    /// 不得误报成「素材不可读」。
    struct InfrastructureError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// 16kHz/mono/Int16 —— Phase 0 实测的 bestAvailableAudioFormat。
    static let sampleRate = 16_000.0

    /// 把素材的一段源区间抽成临时 CAF。返回文件 URL；
    /// 词时间 = 文件内时间 + range.start（调用方补偿）。
    static func extract(
        assetURL: URL,
        range: SourceRange,
        into directory: URL,
        isCancelled: @escaping () -> Bool
    ) async throws -> URL {
        let asset = AVURLAsset(url: assetURL)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw ReadError(message: String(
                format: L10n("“%@” has no audio track."), assetURL.lastPathComponent
            ))
        }

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: range.start, preferredTimescale: 600),
            duration: CMTime(seconds: range.duration, preferredTimescale: 600)
        )
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true
        ) else {
            throw InfrastructureError(message: "Failed to create PCM format.")
        }
        let fileURL = directory.appendingPathComponent("window-\(UUID().uuidString).caf")
        let file: AVAudioFile
        do {
            file = try AVAudioFile(
                forWriting: fileURL,
                settings: format.settings,
                commonFormat: .pcmFormatInt16,
                interleaved: true
            )
        } catch {
            // 临时目录写不进去是我们的问题（磁盘满/权限），不是素材的。
            throw InfrastructureError(message: error.localizedDescription)
        }

        guard reader.startReading() else {
            throw reader.error ?? ReadError(message: "Audio reader failed to start.")
        }
        defer { reader.cancelReading() }

        while let sample = output.copyNextSampleBuffer() {
            if isCancelled() { throw CancellationError() }
            let frames = CMSampleBufferGetNumSamples(sample)
            guard frames > 0 else { continue }
            guard let pcm = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)
            ) else {
                // 静默跳块 = 半截 CAF 照常转写、缺失区间被记成已覆盖，
                // 重跑也不会补 —— 必须整体失败（评审 P2）。
                throw InfrastructureError(message: "Failed to allocate PCM buffer.")
            }
            pcm.frameLength = AVAudioFrameCount(frames)
            let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
                sample, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList
            )
            guard status == noErr else {
                throw ReadError(message: "PCM copy failed (\(status)).")
            }
            do {
                try file.write(from: pcm)
            } catch {
                // 写盘失败（磁盘满等）同样是基础设施问题。
                throw InfrastructureError(message: error.localizedDescription)
            }
        }
        if let error = reader.error { throw error }
        return fileURL
    }
}
