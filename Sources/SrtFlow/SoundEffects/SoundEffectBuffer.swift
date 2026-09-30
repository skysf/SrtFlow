import Foundation

// MARK: - 合成音效的立体声缓冲（纯值）
//
// 管什么：左右两条 Double 采样，叠加（等功率声像）、拼接、倒放、峰值、归一（峰值封顶 + 响度封顶）、裁尾巴、淡入淡出，
// 和 BS.1770 的 K 加权最大瞬时响度（纯音调的声音峰值一样时听着比噪声响得多，归一要看响度不能只看峰值，
// docs/plans/2026-09-30-sound-effects.md 第六节）。
// 不管什么：怎么合成（预设文件）、怎么写文件（AIAudioFileWriter）。

struct SFXBuffer: Sendable {
    var left: [Double]
    var right: [Double]

    init(count: Int) {
        left = Array(repeating: 0, count: max(count, 0))
        right = left
    }

    init(seconds: Double) { self.init(count: Int(seconds * SFX.sampleRate)) }

    var count: Int { left.count }
    var seconds: Double { Double(count) / SFX.sampleRate }

    /// 等功率声像，pan ∈ [-1, 1]。越界的下标丢掉。
    mutating func add(_ i: Int, _ value: Double, pan: Double = 0) {
        guard i >= 0, i < left.count else { return }
        let angle = (pan + 1) * Double.pi / 4
        left[i] += value * cos(angle)
        right[i] += value * sin(angle)
    }

    mutating func add(_ i: Int, left l: Double, right r: Double) {
        guard i >= 0, i < left.count else { return }
        left[i] += l
        right[i] += r
    }

    mutating func resize(_ n: Int) {
        let target = max(n, 0)
        if target < left.count {
            left.removeLast(left.count - target)
            right.removeLast(right.count - target)
        } else {
            left.append(contentsOf: Array(repeating: 0, count: target - left.count))
            right.append(contentsOf: Array(repeating: 0, count: target - right.count))
        }
    }

    /// 把另一段叠上来（不够长就加长）。
    mutating func mix(_ other: SFXBuffer, gain: Double = 1, at offset: Int = 0) {
        let needed = offset + other.count
        if needed > count { resize(needed) }
        for i in 0..<other.count {
            left[offset + i] += other.left[i] * gain
            right[offset + i] += other.right[i] * gain
        }
    }

    func reversed() -> SFXBuffer {
        var out = self
        out.left.reverse()
        out.right.reverse()
        return out
    }

    mutating func scale(_ gain: Double) {
        for i in 0..<count {
            left[i] *= gain
            right[i] *= gain
        }
    }

    var peak: Double {
        var p = 0.0
        for i in 0..<count { p = max(p, abs(left[i]), abs(right[i])) }
        return p
    }

    /// 最响的那个采样在第几个（两声道一起看）。
    var peakIndex: Int {
        var p = 0.0, at = 0
        for i in 0..<count {
            let v = max(abs(left[i]), abs(right[i]))
            if v > p {
                p = v
                at = i
            }
        }
        return at
    }

    mutating func normalize(peakDB: Double) {
        let p = peak
        guard p > 0 else { return }
        scale(SFX.linear(dB: peakDB) / p)
    }

    /// 峰值封顶 peakDB，再把最大瞬时响度压到 loudnessLUFS 以下（到不了的不动）。
    mutating func normalize(peakDB: Double, loudnessLUFS: Double) {
        normalize(peakDB: peakDB)
        let lufs = maxMomentaryLoudness
        if lufs > loudnessLUFS { scale(SFX.linear(dB: loudnessLUFS - lufs)) }
    }

    /// 从最后一个超过门限的采样往后全切掉。
    mutating func trimTail(thresholdDB: Double) {
        let threshold = SFX.linear(dB: thresholdDB)
        var last = -1
        for i in stride(from: count - 1, through: 0, by: -1) where max(abs(left[i]), abs(right[i])) > threshold {
            last = i
            break
        }
        resize(last + 1)
    }

    mutating func fadeIn(seconds: Double) {
        let n = min(Int(seconds * SFX.sampleRate), count)
        for i in 0..<n {
            let g = SFX.smoothstep(Double(i) / Double(n))
            left[i] *= g
            right[i] *= g
        }
    }

    mutating func fadeOut(seconds: Double) {
        let n = min(Int(seconds * SFX.sampleRate), count)
        for k in 0..<n {
            let i = count - 1 - k
            let g = Double(k) / Double(n)
            left[i] *= g
            right[i] *= g
        }
    }

    /// BS.1770 的 K 加权（AudioKWeighting，48 kHz 的系数），400 ms 窗、100 ms 步的最大瞬时响度（LUFS）。不够 400 ms 的按整段算。
    var maxMomentaryLoudness: Double {
        var weightL = AudioKWeighting(), weightR = AudioKWeighting()
        var power = [Double](repeating: 0, count: count)
        for i in 0..<count {
            let l = weightL.process(left[i]), r = weightR.process(right[i])
            power[i] = l * l + r * r
        }
        let window = min(Int(0.4 * SFX.sampleRate), count), hop = max(1, Int(0.1 * SFX.sampleRate))
        guard window > 0 else { return -200 }
        var best = -200.0
        var start = 0
        while start + window <= count {
            var sum = 0.0
            for i in start..<start + window { sum += power[i] }
            best = max(best, AudioKWeighting.offsetLU + 10 * log10(sum / Double(window) + 1e-20))
            if window == count { break }
            start += hop
        }
        return best
    }

    /// 写文件用的两条 Float 声道。
    var floatChannels: [[Float]] { [left.map { Float($0) }, right.map { Float($0) }] }
}
