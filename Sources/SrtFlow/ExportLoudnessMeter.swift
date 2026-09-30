import Foundation

// MARK: - 成片的整段响度（BS.1770-4 的 integrated loudness，流式、纯值）
//
// 管什么：一路交错的 float 立体声流过来，边流边量，最后给出整段响度（LUFS）：K 加权（前置高架 + 高通，48 kHz 的系数）→
// 400 ms 块、100 ms 步的均方功率 → 先按绝对门限（−70 LUFS）、再按相对门限（比剩下的平均低 10 LU）筛掉安静的块 → 剩下的平均。
// 为什么：用户要知道成片有多响（平台各有自己的目标：YouTube −14、播客 −16……），限幅器压了多少也要有个响度当参照；
// 不做响度归一（用户 2026-09-30 拍板：只报、不改）。
// 用在哪：只在 ExportAudioMixdown 写 f32 时喂它（喂的是限幅之后、真写进文件的采样）。
// K 加权只有 AudioKWeighting 一份（合成音效的最大瞬时响度也用它）。
// 不管什么：限幅（ExportPeakLimiter）、写文件。
// 长期约束：docs/architecture/export-audio-mixdown.md 第二节第 3 条。

struct ExportLoudnessMeter {
    /// 只认 48 kHz：K 加权的系数是按这个采样率查表的（混音文件正是 48 kHz，ExportAudioMixdown.sampleRate）。
    static let sampleRate = AudioKWeighting.sampleRate
    /// 绝对门限：比这个安静的块不算。
    static let absoluteGateLUFS = -70.0
    /// 相对门限：比（过了绝对门限的块的平均）低这么多的块不算。
    static let relativeGateLU = -10.0

    /// 100 ms 一个子块，4 个子块拼成一个 400 ms 的块（步长 100 ms）。
    private static let subBlockFrames = sampleRate / 10
    private static let subBlocksPerBlock = 4

    let channels: Int
    private var filters: [AudioKWeighting]
    /// 每个已经量完的 100 ms 子块的功率和（两个声道加在一起）。30 分钟约 18,000 个，存得下。
    private var subBlocks: [Double] = []
    private var pendingSum: Double = 0
    private var pendingFrames = 0

    init(channels: Int) {
        precondition(channels > 0)
        self.channels = channels
        filters = [AudioKWeighting](repeating: AudioKWeighting(), count: channels)
    }

    /// 喂 `frames` 帧交错采样。
    mutating func add(_ samples: UnsafeBufferPointer<Float>, frames: Int) {
        precondition(samples.count >= frames * channels)
        for frame in 0 ..< frames {
            let base = frame * channels
            for channel in 0 ..< channels {
                let weighted = filters[channel].process(Double(samples[base + channel]))
                pendingSum += weighted * weighted
            }
            pendingFrames += 1
            if pendingFrames == Self.subBlockFrames {
                subBlocks.append(pendingSum)
                pendingSum = 0
                pendingFrames = 0
            }
        }
    }

    /// 整段响度（LUFS）。全是静音、或一个子块都没量满时是 nil。不够 400 ms 的按已有的子块拼成一块算。
    var integratedLUFS: Double? {
        guard !subBlocks.isEmpty else { return nil }
        let perBlock = min(Self.subBlocksPerBlock, subBlocks.count)
        let framesPerBlock = Double(perBlock * Self.subBlockFrames)
        var blocks: [Double] = []
        blocks.reserveCapacity(subBlocks.count)
        var sum = 0.0
        for (index, power) in subBlocks.enumerated() {
            sum += power
            if index >= perBlock { sum -= subBlocks[index - perBlock] }
            if index >= perBlock - 1 { blocks.append(sum / framesPerBlock) }
        }
        func loudness(_ meanPower: Double) -> Double { AudioKWeighting.offsetLU + 10 * log10(meanPower + 1e-30) }
        let aboveAbsolute = blocks.filter { loudness($0) > Self.absoluteGateLUFS }
        guard !aboveAbsolute.isEmpty else { return nil }
        let relativeGate = loudness(aboveAbsolute.reduce(0, +) / Double(aboveAbsolute.count)) + Self.relativeGateLU
        let gated = aboveAbsolute.filter { loudness($0) > relativeGate }
        guard !gated.isEmpty else { return nil }
        return loudness(gated.reduce(0, +) / Double(gated.count))
    }
}
