import Foundation

// MARK: - 波形数据里的能量（均方）：「听」量响度用
//
// 管什么：读波形的那一遍里，每 `WaveformPowerBuilder.bucket` 个采样帧顺手攒一个均方（每声道），和多级峰值
// 一起存在块里（`WaveformChunk.power`）；以及按任意一段采样帧取回均方（`WaveformPeaks.meanSquare`）。
// 不管什么：峰值（VideoEditWaveformData.swift）、拿均方算电平 / 静音段（AIAudioLevels）。
//
// 为什么要它：峰值只说「最响的那一下」，说不了「整体多响」—— 给 AI 配音乐、压背景声要的是 RMS。
// 一个文件还是只读一遍（docs/architecture/audio-waveform.md）：每个采样多一次乘加，存的量是第 0 级峰值的
// 1/32（1024 帧一个 Float，48kHz 一小时每声道约 675KB）。

/// 边读边攒均方。块的起点对齐桶的起点（一块 1048576 帧正好 1024 个桶），最后一块的零头按实际帧数平均。
struct WaveformPowerBuilder {
    /// 一个桶多少个采样帧（48kHz 下约 21ms）。
    static let bucket = 1024

    let channels: Int
    private var sums: [Double]
    private var frames = 0
    private var values: [[Float]]

    init(channels: Int) {
        self.channels = max(1, channels)
        sums = Array(repeating: 0, count: max(1, channels))
        values = Array(repeating: [], count: max(1, channels))
    }

    mutating func add(_ sample: Float, channel: Int) {
        sums[channel] += Double(sample) * Double(sample)
    }

    /// 一帧的每个声道都 `add` 过之后调一次。
    mutating func endFrame() {
        frames += 1
        if frames == Self.bucket { close() }
    }

    /// 这一块攒下的均方交出去（没满的最后一个桶按实际帧数平均），重新开始。
    mutating func take() -> [[Float]] {
        if frames > 0 { close() }
        defer { values = Array(repeating: [], count: channels) }
        return values
    }

    private mutating func close() {
        for channel in 0..<channels {
            values[channel].append(Float(sums[channel] / Double(frames)))
            sums[channel] = 0
        }
        frames = 0
    }
}

extension WaveformPeaks {
    /// `[from, to)` 这段采样帧的均方（0…1，满幅正弦是 0.5）。`channel` 为 nil 时是各声道的平均（立体声的整体
    /// 响度）。桶只被盖住一部分时按盖住的帧数算权重。没数据返回 nil。
    func meanSquare(channel: Int?, from: Int, to: Int) -> Double? {
        guard to > from, !chunks.isEmpty else { return nil }
        let bucket = WaveformPowerBuilder.bucket
        let channels = channel.map { [$0] } ?? Array(0..<channelCount)
        let firstChunk = max(0, from / Self.framesPerChunk)
        let lastChunk = min(chunks.count - 1, (to - 1) / Self.framesPerChunk)
        guard firstChunk <= lastChunk else { return nil }
        var total = 0.0
        var weight = 0.0
        for chunk in chunks[firstChunk...lastChunk] {
            let localFrom = max(0, from - chunk.startFrame)
            let localTo = min(chunk.frameCount, to - chunk.startFrame)
            guard localTo > localFrom else { continue }
            for ch in channels where chunk.power.indices.contains(ch) {
                let values = chunk.power[ch]
                let last = min((localTo - 1) / bucket, values.count - 1)
                guard localFrom / bucket <= last else { continue }
                for index in (localFrom / bucket)...last {
                    let start = index * bucket
                    let overlap = min(start + bucket, localTo) - max(start, localFrom)
                    guard overlap > 0 else { continue }
                    total += Double(values[index]) * Double(overlap)
                    weight += Double(overlap)
                }
            }
        }
        return weight > 0 ? total / weight : nil
    }
}
