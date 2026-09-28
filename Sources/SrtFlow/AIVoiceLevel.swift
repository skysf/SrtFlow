import Foundation

// MARK: - 配音的音量（纯值）
//
// 管什么：一句配音写成文件之前统一过一道：说话那部分的响度拉到同一个水平（`targetRMS`），峰值封顶在 −1 dBFS（`peakCeiling`），
// 两样冲突时听峰值的（宁可小一点也不削波）。Kokoro 和 macOS 的声音都走这一处，于是各句旁白、各个音色的音量也一致。
// 为什么：Kokoro 有的音色读出来的原始声音会超过满幅 —— 2026-09-28 用户用 en_male（am_fenrir）配的「One.」「Two.」「Three.」
// 开头的三句峰值 1.05–1.15，直接交给 AAC 编码器就被截平，听起来是一声声刺耳的「啪」；别的音色峰值只有 0.4–0.7
// （docs/bugfixes/2026-09-28-kokoro-voiceover-clipping.md）。
// 用在哪：只在 AIAudioFileWriter.writeVoiceover 里（两种声音写文件都走它，绕不过去）。
// 不管什么：怎么合成（KokoroVoiceSpeech / AISpeechSynthesis）、怎么写文件（AIAudioFileWriter）。

enum AIVoiceLevel {
    /// 说话部分的均方根目标：−18 dBFS。各个声音原始的响度在 −15.6 到 −21.6 dBFS 之间（2026-09-28 实测），大多数句子只动 1–3 dB；
    /// 起伏大的声音（am_fenrir）先顶到峰值上限，比别的轻 1–2 dB。
    static let targetRMS: Float = 0.126
    /// 峰值上限：−1 dBFS。
    static let peakCeiling: Float = 0.891
    /// 比这个轻的 20 毫秒不算「说话」（−45 dBFS），停顿不拉低平均。
    static let activeFloor: Float = 0.0056
    /// 最多放大 4 倍（+12 dB）：真的说话用不着（2026-09-28 实测 Kokoro 八个音色、这台 Mac 的声音原始响度都在 −15.6 到 −21.6 dBFS），
    /// 只防一句几乎全是底噪的被放大成噪音。
    static let maxBoost: Float = 4

    /// 整句乘同一个增益：不压缩、不改音色，只让它不削波、和别的句子一样响。全是静音的原样返回。
    static func normalized(_ samples: [Float], sampleRate: Double) -> [Float] {
        let gain = self.gain(for: samples, sampleRate: sampleRate)
        guard gain != 1 else { return samples }
        return samples.map { $0 * gain }
    }

    static func gain(for samples: [Float], sampleRate: Double) -> Float {
        let window = max(1, Int(sampleRate * 0.02))
        var activeSum: Double = 0
        var activeCount = 0
        var peak: Float = 0
        var start = 0
        while start < samples.count {
            let end = min(samples.count, start + window)
            var sum: Float = 0
            for index in start..<end {
                sum += samples[index] * samples[index]
                peak = max(peak, abs(samples[index]))
            }
            if (sum / Float(end - start)).squareRoot() >= activeFloor {
                activeSum += Double(sum)
                activeCount += end - start
            }
            start = end
        }
        guard activeCount > 0, peak > 0 else { return 1 }
        let rms = Float((activeSum / Double(activeCount)).squareRoot())
        return min(targetRMS / rms, peakCeiling / peak, maxBoost)
    }
}
