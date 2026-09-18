import AVFoundation
import SwiftUI

// MARK: - 波形条
//
// 从 `VideoEditTimelineView.swift` 拆出来（拆分前 2101 行，远超仓库约 800 行的
// 警戒线）。画的是**听到的**声音：音量和渐入渐出都乘进柱高里。同样是纯装饰，不吃事件。
// 接线守卫 `checks/timeline-drag-wiring.sh` 按文件扫描，挪动这里的东西要同步改它。

// MARK: - 波形

/// 音频块里的波形。真读采样（降到几百个桶），异步画。
/// 波形条。画的是**听到的**声音，不是源文件的原始波形 —— 音量和渐入渐出
/// 都乘进柱高里，所以拉音量、改淡变时轨道上当场跟着变。
///
/// 增益只影响绘制，不进 `.task` 的 id：改音量不该让它重读一遍 PCM。
struct WaveformView: View {
    let clip: EditClip

    @State private var samples: [Float] = []

    /// 这一柱（时间线上的位置 0…1）实际听到的增益。
    private func gain(atFraction fraction: Double) -> Double {
        guard !clip.isMuted else { return 0 }
        let span = clip.timelineDuration
        guard span > 0 else { return clip.volume }
        let fades = clip.audioFades
        let elapsed = fraction * span
        var envelope = 1.0
        if fades.fadeIn > 0, elapsed < fades.fadeIn {
            envelope = min(envelope, elapsed / fades.fadeIn)
        }
        if fades.fadeOut > 0, elapsed > span - fades.fadeOut {
            envelope = min(envelope, max(0, span - elapsed) / fades.fadeOut)
        }
        return clip.volume * envelope
    }

    var body: some View {
        Canvas { context, size in
            guard !samples.isEmpty else { return }
            let barWidth = size.width / Double(samples.count)
            for (index, value) in samples.enumerated() {
                // 柱心对准这一段的中点，渐变的斜坡才不会整体偏半柱。
                let fraction = (Double(index) + 0.5) / Double(samples.count)
                // 音量能推到 +6dB（线性 2.0），高度得夹住，不然柱子冲出轨道。
                let scaled = min(1, Double(value) * gain(atFraction: fraction))
                let h = max(1, scaled * size.height)
                let rect = CGRect(
                    x: Double(index) * barWidth,
                    y: size.height - h,
                    width: max(0.8, barWidth - 0.6),
                    height: h
                )
                context.fill(Path(rect), with: .color(.white.opacity(0.75)))
            }
        }
        .task(id: "\(clip.sourceURL.path)|\(Int(clip.sourceStart * 10))|\(Int(clip.sourceDuration * 10))") {
            // 同缩略图条：裁切拖动中先拿旧波形撑着，手停稳了再重读 PCM。
            if !samples.isEmpty {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }
            let loaded = await WaveformCache.shared.samples(
                url: clip.sourceURL,
                start: clip.sourceStart,
                duration: clip.sourceDuration
            )
            guard !Task.isCancelled, !loaded.isEmpty else { return }
            samples = loaded
        }
        // 与缩略图条同一条合同：块内装饰不吃事件（守卫在 timeline-drag-wiring）。
        .allowsHitTesting(false)
    }
}

/// 波形采样缓存：AVAssetReader 读 PCM，按桶取峰值。
actor WaveformCache {
    static let shared = WaveformCache()

    private var cache: [String: [Float]] = [:]

    func samples(url: URL, start: Double, duration: Double, bucketCount: Int = 240) async -> [Float] {
        let key = "\(url.path)|\(Int(start * 10))|\(Int(duration * 10))"
        if let cached = cache[key] { return cached }

        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first else { return [] }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 8000
        ]
        guard let reader = try? AVAssetReader(asset: asset) else { return [] }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(output)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: duration, preferredTimescale: 600)
        )
        guard reader.startReading() else { return [] }

        let totalSamples = Int(8000 * duration)
        let samplesPerBucket = max(1, totalSamples / bucketCount)
        var buckets: [Float] = []
        var currentPeak: Int16 = 0
        var currentCount = 0

        while let buffer = output.copyNextSampleBuffer(),
              let block = CMSampleBufferGetDataBuffer(buffer) {
            let length = CMBlockBufferGetDataLength(block)
            var data = Data(count: length)
            data.withUnsafeMutableBytes { raw in
                if let base = raw.baseAddress {
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
                }
            }
            data.withUnsafeBytes { raw in
                let int16 = raw.bindMemory(to: Int16.self)
                for value in int16 {
                    currentPeak = max(currentPeak, Int16(clamping: abs(Int32(value))))
                    currentCount += 1
                    if currentCount >= samplesPerBucket {
                        buckets.append(Float(currentPeak) / Float(Int16.max))
                        currentPeak = 0
                        currentCount = 0
                    }
                }
            }
        }
        if currentCount > 0 {
            buckets.append(Float(currentPeak) / Float(Int16.max))
        }
        reader.cancelReading()

        // 稍微抬一下小信号，看得见形状。
        let shaped = buckets.map { min(1, pow($0, 0.7)) }
        cache[key] = shaped
        return shaped
    }
}
