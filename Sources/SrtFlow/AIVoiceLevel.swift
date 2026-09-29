import Foundation

// MARK: - 配音的音量（纯值）
//
// 管什么：一句配音写成文件之前统一过一道：先整句乘一个增益，让**说话部分**的响度到同一个水平（`targetRMS`，比中位数响
// 12 dB 以上的那几格不算 —— 那是炸出来的一下或者爆破音的尖，不是说话）；再**限幅**：超过 −1 dBFS（`peakCeiling`）的地方
// 只把那十几毫秒压下来，别处不动。Kokoro 和 macOS 的声音都走这一处，于是各句旁白、各个音色的音量也一致。
// 为什么：
// - 2026-09-28 用户用 en_male（am_fenrir）配的「One. / Two. / Three.」开头一声声「啪」：原始声音超过满幅、直接交给 AAC
//   编码器（docs/bugfixes/2026-09-28-kokoro-voiceover-clipping.md）。
// - 第一版的修法是「整句乘一个增益、峰值封顶」，可那一下是满幅的 90 倍（Kokoro 单独读「Two.」炸了），整句跟着被压了
//   37 dB，说话几乎听不见（docs/bugfixes/2026-09-29-kokoro-short-pieces-explode.md）。**一个尖峰不许决定整句的音量。**
// 用在哪：只在 AIAudioFileWriter.writeVoiceover 里（两种声音写文件都走它，绕不过去）。
// 不管什么：怎么合成（KokoroVoiceSpeech / AISpeechSynthesis）、怎么写文件（AIAudioFileWriter）。

enum AIVoiceLevel {
    /// 说话部分的均方根目标：−18 dBFS。各个声音原始的响度在 −15.6 到 −21.6 dBFS 之间（2026-09-28 实测），大多数句子只动 1–3 dB。
    static let targetRMS: Float = 0.126
    /// 峰值上限：−1 dBFS（AAC 编码后读回来差不到 0.05 dB，留 1 dB 够）。
    static let peakCeiling: Float = 0.891
    /// 比这个轻的 20 毫秒不算「说话」（−45 dBFS），停顿不拉低平均。
    static let activeFloor: Float = 0.0056
    /// 比说话的中位数响 4 倍（12 dB）以上的 20 毫秒不算说话：炸出来的一下、爆破音的尖（正常的重音在 6 dB 以内）。
    static let outlierRatio: Float = 4
    /// 最多放大 4 倍（+12 dB）：真的说话用不着，只防一句几乎全是底噪的被放大成噪音。
    static let maxBoost: Float = 4

    /// 整句乘一个增益（不压缩、不改音色），再把超过 −1 dBFS 的那几小截压下来。全是静音的原样返回。
    static func normalized(_ samples: [Float], sampleRate: Double) -> [Float] {
        let gain = self.gain(for: samples, sampleRate: sampleRate)
        var output = gain == 1 ? samples : samples.map { $0 * gain }
        limit(&output, sampleRate: sampleRate)
        return output
    }

    /// 整句乘的那一个增益：说话部分（去掉太轻的停顿和太响的尖）的均方根到 `targetRMS`，最多放大 `maxBoost` 倍。
    static func gain(for samples: [Float], sampleRate: Double) -> Float {
        let window = max(1, Int(sampleRate * 0.02))
        var powers: [(sum: Double, count: Int)] = []
        var start = 0
        while start < samples.count {
            let end = min(samples.count, start + window)
            var sum: Double = 0
            for index in start..<end { sum += Double(samples[index] * samples[index]) }
            if (sum / Double(end - start)).squareRoot() >= Double(activeFloor) { powers.append((sum, end - start)) }
            start = end
        }
        guard !powers.isEmpty else { return 1 }
        let levels = powers.map { ($0.sum / Double($0.count)).squareRoot() }.sorted()
        let ceiling = levels[levels.count / 2] * Double(outlierRatio)
        let speech = powers.filter { ($0.sum / Double($0.count)).squareRoot() <= ceiling }
        let energy = speech.reduce(0) { $0 + $1.sum }
        let count = speech.reduce(0) { $0 + $1.count }
        guard count > 0, energy > 0 else { return 1 }
        return min(targetRMS / Float((energy / Double(count)).squareRoot()), maxBoost)
    }

    /// 限幅：10 毫秒一格，哪一格的峰值超过上限，那一格就压到正好碰到上限；每格再取前后各一格里压得最多的那个（提前、多压一格），
    /// 格与格的中心之间线性过渡（不「咔」一声）。这样每个采样乘到的增益都不超过它那一格要的，一个采样都不会超过上限。
    static func limit(_ samples: inout [Float], sampleRate: Double) {
        let window = max(1, Int(sampleRate * 0.01))
        let windows = (samples.count + window - 1) / window
        guard windows > 0 else { return }
        var needed = [Float](repeating: 1, count: windows)
        var any = false
        for index in 0..<windows {
            let peak = samples[(index * window)..<min(samples.count, (index + 1) * window)].reduce(0) { max($0, abs($1)) }
            if peak > peakCeiling {
                needed[index] = peakCeiling / peak
                any = true
            }
        }
        guard any else { return }
        let held = needed.indices.map { index in
            needed[max(0, index - 1)...min(windows - 1, index + 1)].min() ?? 1
        }
        for position in samples.indices {
            // 这个采样落在哪两格的中心之间。
            let place = (Double(position) - Double(window) / 2) / Double(window)
            let low = min(windows - 1, max(0, Int(place.rounded(.down))))
            let high = min(windows - 1, low + 1)
            let fraction = Float(min(1, max(0, place - Double(low))))
            let gain = held[low] + (held[high] - held[low]) * fraction
            samples[position] = min(peakCeiling, max(-peakCeiling, samples[position] * gain))
        }
    }
}
