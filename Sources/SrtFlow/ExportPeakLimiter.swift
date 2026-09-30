import Foundation

// MARK: - 成片的峰值限幅器（流式、纯值）
//
// 管什么：一路交错的 float 声音流过来，保证写出去的**每个采样都不超过上限**（−1 dBFS），而且不是削平 —— 峰值到之前
// 就把增益压到位、峰值过后再按释放时间慢慢回来，没过顶的地方一个采样都不动。顺手记下限幅前的峰值、超过上限的帧数、
// 压得最深的增益和写出去的峰值，报给用户。
// 为什么：2026-09-30 之前写 f32 那一步是硬削（docs/bugfixes/2026-09-30-export-mix-over-0dbfs-into-aac.md 之后的第一版）：
// 不削就交给 AAC 编码器会失真，削平又是另一种失真。用户拍板换成真的限幅器（docs/plans/2026-09-30-export-limiter-and-easing.md）。
// 怎么做（三步，每步都是有名字的老办法）：
//   1. 每一帧要压到多少：r = min(1, 上限 / 这一帧最响的声道)。
//   2. 前瞻：往后看 `lookahead` 帧里最小的 r（单调队列，O(1) 均摊），信号本身延迟同样多的帧 —— 峰值到之前增益就到位了。
//   3. 平滑：把这条「最小值」再做同样长的滑动平均，台阶变成斜坡（不「咔」一声）；数学上每一帧的增益仍然 ≤ 它自己的 r，
//      所以一个采样都不会超过上限。往上回只按释放时间（一阶）慢慢来，低频不会被抽成锯齿。
// 用在哪：只在 ExportAudioMixdown 写 f32 之前那一步（预览走 AVPlayer，不经过这里，是已知差异）。
// 不管什么：读混音、写文件、量响度（ExportLoudnessMeter）。
// 长期约束：docs/architecture/export-audio-mixdown.md 第二节第 3 条。

struct ExportPeakLimiter {
    /// 上限：−1 dBFS（留 1 dB 给编码器的过冲，同配音文件 AIVoiceLevel.peakCeiling）。
    static let defaultCeiling: Float = 0.891
    /// 前瞻 5 ms：够把一个尖峰前面的斜坡铺开，又短到听不出「提前变轻」。
    static let defaultLookaheadSeconds = 0.005
    /// 释放约 80 ms：过了峰值慢慢回来；太快会把低频抽成锯齿，太慢会把后面的话压轻。
    static let defaultReleaseSeconds = 0.08

    let channels: Int
    let ceiling: Float
    /// 前瞻的帧数 = 信号延迟的帧数。
    let lookahead: Int
    private let releaseCoefficient: Double

    /// 限幅前的采样峰值（线性，只算真正喂进来的帧）。
    private(set) var inputPeak: Float = 0
    /// 写出去的采样峰值（线性）。
    private(set) var outputPeak: Float = 0
    /// 超过上限、被压下来的帧数（任一声道超过就算）。
    private(set) var overFrames = 0
    /// 压得最深的增益（1 = 从没压过）。
    private(set) var minimumGain: Float = 1
    /// 真正喂进来的帧数。
    private(set) var received = 0
    /// 写出去的帧数（比 `received` 晚 `lookahead` 帧，`flush` 之后相等）。
    private(set) var emitted = 0

    // 延迟线：最近 `lookahead` 帧的原样采样。
    private var delay: [Float]
    // 单调队列（r 递增）：装的是 (帧号, r)，队首就是前瞻窗里最小的 r。
    private var queueIndex: [Int]
    private var queueGain: [Float]
    private var queueHead = 0
    private var queueTail = 0
    // 滑动平均：最近 `lookahead` 个「窗内最小 r」和它们的和。
    private var window: [Float]
    private var windowSum: Double = 0
    /// 当前增益。用 Double：释放到 0.9999 附近时每一步只加 3e-8，Float 在 1 附近的一格是 6e-8，会停在那儿永远回不到 1。
    private var gain: Double = 1
    /// 释放到离目标只差这么点就直接归位（−140 dB 的一步，听不见），之后没过顶的采样又是逐位原样。
    private static let releaseSnap = 1e-7
    /// 喂进来的帧数，含 flush 时垫的静音。
    private var fed = 0

    init(
        channels: Int, sampleRate: Int, ceiling: Float = defaultCeiling,
        lookaheadSeconds: Double = defaultLookaheadSeconds, releaseSeconds: Double = defaultReleaseSeconds
    ) {
        precondition(channels > 0)
        self.channels = channels
        self.ceiling = ceiling
        lookahead = max(1, Int((lookaheadSeconds * Double(sampleRate)).rounded()))
        releaseCoefficient = 1 - exp(-1 / (releaseSeconds * Double(sampleRate)))
        delay = [Float](repeating: 0, count: lookahead * channels)
        // 队列最多装 lookahead + 1 个（窗里每一帧一个），用环形下标。
        queueIndex = [Int](repeating: 0, count: lookahead + 1)
        queueGain = [Float](repeating: 1, count: lookahead + 1)
        window = [Float](repeating: 1, count: lookahead)
    }

    /// 喂 `frames` 帧交错采样，把能出的帧接在 `output` 后面（开头 `lookahead − 1` 帧先攒着，之后一进一出）。
    mutating func process(_ input: UnsafeBufferPointer<Float>, frames: Int, into output: inout [Float]) {
        precondition(input.count >= frames * channels)
        output.reserveCapacity(output.count + frames * channels)
        for frame in 0 ..< frames {
            let base = frame * channels
            var magnitude: Float = 0
            for channel in 0 ..< channels {
                let value = abs(input[base + channel])
                if value > magnitude { magnitude = value }
            }
            if magnitude > inputPeak { inputPeak = magnitude }
            if magnitude > ceiling { overFrames += 1 }
            received += 1
            push(input, base: base, magnitude: magnitude, into: &output)
        }
    }

    /// 把延迟线里剩下的帧冲出来：之后 `emitted == received`，总长度和喂进来的一样。
    mutating func flush(into output: inout [Float]) {
        let silence = [Float](repeating: 0, count: channels)
        silence.withUnsafeBufferPointer { zero in
            while emitted < received {
                push(zero, base: 0, magnitude: 0, into: &output)
            }
        }
    }

    /// 一帧进、（延迟够了之后）一帧出。
    private mutating func push(_ input: UnsafeBufferPointer<Float>, base: Int, magnitude: Float, into output: inout [Float]) {
        let index = fed
        fed += 1
        let slot = (index % lookahead) * channels
        for channel in 0 ..< channels { delay[slot + channel] = input[base + channel] }

        // 1. 这一帧要压到多少。
        let required: Float = magnitude > ceiling ? ceiling / magnitude : 1
        // 2. 单调队列：把队尾比它大（或相等）的都弹掉，它排进去。
        while queueTail > queueHead, queueGain[(queueTail - 1) % queueGain.count] >= required { queueTail -= 1 }
        queueIndex[queueTail % queueIndex.count] = index
        queueGain[queueTail % queueGain.count] = required
        queueTail += 1

        // 延迟还没攒够：不出帧。
        guard index >= lookahead - 1 else { return }
        let out = index - lookahead + 1
        // 队首比窗口 [out, out + lookahead) 还早的弹掉，剩下的队首就是窗里最小的 r。
        while queueIndex[queueHead % queueIndex.count] < out { queueHead += 1 }
        let windowMinimum = queueGain[queueHead % queueGain.count]

        // 3. 滑动平均（开头不满 lookahead 个时只平均已有的：它们的窗都包着 out，所以平均值仍 ≤ r[out]）。
        let windowSlot = out % lookahead
        if out >= lookahead { windowSum -= Double(window[windowSlot]) }
        window[windowSlot] = windowMinimum
        windowSum += Double(windowMinimum)
        let smoothed = windowSum / Double(min(out + 1, lookahead))
        if smoothed < gain {
            gain = smoothed
        } else {
            gain += (smoothed - gain) * releaseCoefficient
            if smoothed - gain < Self.releaseSnap { gain = smoothed }
        }
        if Float(gain) < minimumGain { minimumGain = Float(gain) }

        // 只有真正喂进来的帧才写出去（flush 垫的静音只是为了把延迟线推空）。
        guard emitted < received else { return }
        let source = (out % lookahead) * channels
        let applied = Float(gain)
        for channel in 0 ..< channels {
            let value = delay[source + channel] * applied
            let magnitude = abs(value)
            if magnitude > outputPeak { outputPeak = magnitude }
            output.append(value)
        }
        emitted += 1
    }
}
