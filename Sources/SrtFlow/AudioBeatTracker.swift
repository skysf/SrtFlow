import Accelerate
import Foundation

// MARK: - 鼓点：一段音乐的速度和每一拍在哪（纯计算）
//
// 管什么：单声道采样 → 起音强度（频谱通量）→ 速度（起音强度的自相关，偏向 120 BPM 附近）→ 每一拍（动态规划：
// 拍要落在起音强的地方，相邻两拍的间隔要接近这个速度，Ellis 2007 那一套）→ 每四拍里哪一拍是小节头（猜的：
// 四种相位里起音加起来最强的那个）。给 listen 的 beats、cut_to_beat 用（方案第 13 条：鼓点这份原始数据 + 音乐踩点）。
// 不管什么：读采样（AIBeats，在 MediaReadQueue 上读）、换算到时间线（调用方）。
//
// 口径：
// - 采样率由调用方给（读成 11025 Hz 就够：看的是鼓点，不是高频细节）；帧长 512、跳 128（约 11.6 毫秒一格）。
// - 通量取对数幅度（log1p(100·|X|)）的正向变化，**分六个频带各自按平均值归一再相加**（不然宽频的踩镲压过只占几个
//   低频格的底鼓，拍子会被拉到后半拍上），减掉 0.4 秒的滑动平均、只留正的，再除以标准差 —— 响的段落和轻的段落
//   同样看得出拍子。
// - 一格的时间 = (格号 × 跳 + 帧长 / 2) / 采样率（窗的中间）。
// - 速度只在 50–200 BPM 里找。没有明显的起音（最强的起音不到中位数的 3 倍）时不给结果（nil）—— 调用方照实说
//   「听不出清楚的节拍」；有起音但不太规整时结果照给，`confidence` 低，调用方也要说出来。

enum AudioBeatTracker {
    struct Analysis: Equatable, Sendable {
        var bpm: Double
        /// 每一拍（秒，从这段采样的开头算）。
        var beats: [Double]
        /// 猜的小节头（每四拍一个）。
        var downbeats: [Double]
        /// 节拍有多清楚：0–1（选中那个间隔上的自相关 / 零延迟的自相关）。
        var confidence: Double
    }

    static let frameSize = 512
    static let hop = 128
    /// 分频带看起音（频率格的边，11025 Hz、512 点时一格约 21.5 Hz）：底鼓、低音、人声 / 和弦、军鼓、踩镲大致各占一段。
    static let bandEdges = [1, 4, 10, 24, 56, 128, 256]
    static let minBPM = 50.0
    static let maxBPM = 200.0
    /// 低于它就算「拍子弱或不规整」：listen 照给但说一句，cut_to_beat 不踩。实测：合成鼓点 0.6–0.9，音乐库里有节奏的曲子
    /// 0.4 上下，很慢的钢琴曲 0.1，说话、环境声 0.16–0.25。
    static let clearConfidence = 0.3

    static func analyze(_ samples: [Float], sampleRate: Double) -> Analysis? {
        let envelope = onsetEnvelope(samples, sampleRate: sampleRate)
        let framesPerSecond = sampleRate / Double(hop)
        guard envelope.count > Int(framesPerSecond * 2),
              let tempo = tempoPeriod(envelope, framesPerSecond: framesPerSecond) else { return nil }
        let frames = track(envelope, period: tempo.period)
        guard frames.count >= 2 else { return nil }
        let time = { (frame: Int) in (Double(frame * hop) + Double(frameSize) / 2) / sampleRate }
        let beats = frames.map(time)
        let phase = (0..<4).max { a, b in
            strength(envelope, frames, phase: a) < strength(envelope, frames, phase: b)
        } ?? 0
        let downbeats = stride(from: phase, to: frames.count, by: 4).map { time(frames[$0]) }
        return Analysis(
            bpm: 60 * framesPerSecond / tempo.period, beats: beats, downbeats: downbeats, confidence: tempo.confidence
        )
    }

    private static func strength(_ envelope: [Float], _ frames: [Int], phase: Int) -> Float {
        stride(from: phase, to: frames.count, by: 4).reduce(0) { $0 + envelope[frames[$1]] }
    }

    // MARK: 起音强度

    /// 每一格一个值：频谱通量（对数幅度的正向变化），去掉慢变化、按标准差归一。
    static func onsetEnvelope(_ samples: [Float], sampleRate: Double) -> [Float] {
        let count = samples.count
        guard count >= frameSize else { return [] }
        let log2n = vDSP_Length(log2(Double(frameSize)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }
        let half = frameSize / 2
        var window = [Float](repeating: 0, count: frameSize)
        vDSP_hann_window(&window, vDSP_Length(frameSize), Int32(vDSP_HANN_NORM))
        var windowed = [Float](repeating: 0, count: frameSize)
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var magnitudes = [Float](repeating: 0, count: half)
        var previous = [Float](repeating: 0, count: half)
        var difference = [Float](repeating: 0, count: half)
        let edges = bandEdges.map { min($0, half) }
        var bands = [[Float]](repeating: [], count: edges.count - 1)
        var start = 0
        while start + frameSize <= count {
            samples.withUnsafeBufferPointer { buffer in
                vDSP_vmul(buffer.baseAddress! + start, 1, window, 1, &windowed, 1, vDSP_Length(frameSize))
            }
            real.withUnsafeMutableBufferPointer { realBuffer in
                imag.withUnsafeMutableBufferPointer { imagBuffer in
                    var split = DSPSplitComplex(realp: realBuffer.baseAddress!, imagp: imagBuffer.baseAddress!)
                    windowed.withUnsafeBufferPointer { input in
                        input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    // 第 0 格里压着直流和奈奎斯特（zrip 的打包方式），起音不看它们。
                    split.realp[0] = 0
                    split.imagp[0] = 0
                    vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(half))
                }
            }
            var scale: Float = 100
            vDSP_vsmul(magnitudes, 1, &scale, &magnitudes, 1, vDSP_Length(half))
            var length = Int32(half)
            vvlog1pf(&magnitudes, magnitudes, &length)
            vDSP_vsub(previous, 1, magnitudes, 1, &difference, 1, vDSP_Length(half))
            var zero: Float = 0
            vDSP_vthres(difference, 1, &zero, &difference, 1, vDSP_Length(half))
            for band in 0..<(edges.count - 1) {
                var sum: Float = 0
                difference.withUnsafeBufferPointer { buffer in
                    vDSP_sve(buffer.baseAddress! + edges[band], 1, &sum, vDSP_Length(edges[band + 1] - edges[band]))
                }
                bands[band].append(start == 0 ? 0 : sum)
            }
            previous = magnitudes
            start += hop
        }
        // 每个频带按它自己的平均值归一再加起来：底鼓只占几个低频格、踩镲是宽频噪声，直接加总的话踩镲压过底鼓，
        // 八分音符的踩镲会把拍子拉到后半拍上（合成的鼓点实测：128 BPM 每一拍都差了半拍）。
        var flux = [Float](repeating: 0, count: bands.first?.count ?? 0)
        for series in bands {
            let mean = series.reduce(0, +) / Float(max(series.count, 1))
            guard mean > 0 else { continue }
            for index in series.indices { flux[index] += series[index] / mean }
        }
        // 没有明显的起音（最强的那 0.5% 不到中位数的 3 倍：长音、铺底的环境声、很平的音乐）就当没有节拍 ——
        // 不然归一化会把幅度上周期性的一点起伏（长音的相位和分帧错开）放大成「拍子」。
        let ranked = flux.sorted()
        let median = ranked[ranked.count / 2]
        let peak = ranked[min(ranked.count - 1, ranked.count * 995 / 1000)]
        guard peak > 3 * max(median, 1e-6) else { return [Float](repeating: 0, count: flux.count) }
        return normalized(flux, smoothing: Int(0.4 * sampleRate / Double(hop)))
    }

    /// 减掉 `smoothing` 格宽的滑动平均、只留正的，再除以标准差。
    static func normalized(_ values: [Float], smoothing: Int) -> [Float] {
        guard !values.isEmpty else { return [] }
        let radius = max(1, smoothing / 2)
        var prefix = [Double](repeating: 0, count: values.count + 1)
        for (index, value) in values.enumerated() { prefix[index + 1] = prefix[index] + Double(value) }
        var result = values.indices.map { index -> Float in
            let low = max(0, index - radius)
            let high = min(values.count, index + radius + 1)
            let mean = (prefix[high] - prefix[low]) / Double(high - low)
            return max(0, values[index] - Float(mean))
        }
        let mean = result.reduce(0, +) / Float(result.count)
        let variance = result.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(result.count)
        let deviation = variance.squareRoot()
        if deviation > 0 { result = result.map { $0 / deviation } }
        return result
    }

    // MARK: 速度

    /// 一拍几格（可以是小数）和节拍有多清楚。自相关乘一个偏向 120 BPM 的先验（对数刻度上一个八度的宽度），
    /// 挑最高的那个间隔，再用抛物线插值到小数格。
    static func tempoPeriod(_ envelope: [Float], framesPerSecond: Double) -> (period: Double, confidence: Double)? {
        let shortest = max(2, Int((60 / maxBPM * framesPerSecond).rounded(.down)))
        let longest = Int((60 / minBPM * framesPerSecond).rounded(.up))
        guard envelope.count > longest * 2 else { return nil }
        let energy = autocorrelation(envelope, lag: 0)
        guard energy > 0 else { return nil }
        var scores: [Int: Double] = [:]
        for lag in (shortest - 1)...(longest + 1) {
            let bpm = 60 * framesPerSecond / Double(lag)
            let octaves = log2(bpm / 120)
            scores[lag] = autocorrelation(envelope, lag: lag) * exp(-0.5 * octaves * octaves)
        }
        guard let best = (shortest...longest).max(by: { scores[$0]! < scores[$1]! }) else { return nil }
        let (left, middle, right) = (scores[best - 1]!, scores[best]!, scores[best + 1]!)
        let curvature = left - 2 * middle + right
        let offset = curvature < 0 ? 0.5 * (left - right) / curvature : 0
        // 插值不许把间隔推出 50–200 BPM 的范围（没有拍子的音乐最强的往往就在边上）。
        let period = min(Double(longest), max(Double(shortest), Double(best) + max(-0.5, min(0.5, offset))))
        return (period, min(1, autocorrelation(envelope, lag: best) / energy))
    }

    static func autocorrelation(_ values: [Float], lag: Int) -> Double {
        guard lag < values.count else { return 0 }
        var sum: Float = 0
        values.withUnsafeBufferPointer { buffer in
            vDSP_dotpr(buffer.baseAddress!, 1, buffer.baseAddress! + lag, 1, &sum, vDSP_Length(values.count - lag))
        }
        return Double(sum) / Double(values.count - lag)
    }

    // MARK: 跟拍

    /// 动态规划：每一格的分 = 它自己的起音强度 + 往前 0.5–2 拍里最好的那一格的分 − 间隔偏离一拍的罚分；
    /// 从最后一拍里分最高的那一格倒着找回来。
    static func track(_ envelope: [Float], period: Double, tightness: Double = 100) -> [Int] {
        let count = envelope.count
        guard count > 0, period >= 1 else { return [] }
        var score = [Double](repeating: 0, count: count)
        var previous = [Int](repeating: -1, count: count)
        let nearest = max(1, Int((period / 2).rounded()))
        let farthest = max(nearest, Int((period * 2).rounded()))
        for frame in 0..<count {
            var best = -Double.infinity
            var bestFrame = -1
            let low = max(0, frame - farthest)
            let high = frame - nearest
            if high >= low {
                for candidate in low...high {
                    let ratio = log(Double(frame - candidate) / period)
                    let value = score[candidate] - tightness * ratio * ratio
                    if value > best { best = value; bestFrame = candidate }
                }
            }
            score[frame] = Double(envelope[frame]) + (bestFrame >= 0 ? best : 0)
            previous[frame] = bestFrame
        }
        let tail = max(0, count - Int(period.rounded(.up)))
        guard var frame = (tail..<count).max(by: { score[$0] < score[$1] }) else { return [] }
        var frames = [frame]
        while previous[frame] >= 0 {
            frame = previous[frame]
            frames.append(frame)
        }
        return frames.reversed()
    }
}
