import Foundation

// MARK: - 合成音效的混响：纯 Swift 的 Freeverb（确定、好测）
//
// 管什么：8 comb + 4 allpass 的 Freeverb（延迟按 44.1k 的原表换算到 48k，右声道错开 23 个采样）；
// 把湿声叠到干声上按**峰值比例**（`mixReverb`）；短音效的尾巴固定只留零点几秒（`limitTail`）。
// 为什么按峰值比例：Freeverb 的湿声增益随房间大小变得很厉害（大房间对持续输入的稳态增益近 9 倍），按固定系数混，
// impact / ding 的峰值被混响堆起来推后 100–400 ms、suction 的峰值跑到结尾前 200 ms，落点 hit_at 就不准了
// （docs/plans/2026-09-30-sound-effects.md 第四节「原型里学到的」）。
// 不管什么：预设的声音设计。

private struct SFXComb {
    private var buffer: [Double]
    private var index = 0
    private var store = 0.0
    private let feedback: Double, damp1: Double, damp2: Double

    init(length: Int, feedback: Double, damp: Double) {
        buffer = Array(repeating: 0, count: length)
        self.feedback = feedback
        damp1 = damp
        damp2 = 1 - damp
    }

    mutating func process(_ x: Double) -> Double {
        let out = buffer[index]
        store = out * damp2 + store * damp1
        buffer[index] = x + store * feedback
        index += 1
        if index == buffer.count { index = 0 }
        return out
    }
}

private struct SFXAllpass {
    private var buffer: [Double]
    private var index = 0

    init(length: Int) { buffer = Array(repeating: 0, count: length) }

    mutating func process(_ x: Double) -> Double {
        let bufout = buffer[index]
        buffer[index] = x + bufout * 0.5
        index += 1
        if index == buffer.count { index = 0 }
        return bufout - x
    }
}

struct SFXFreeverb {
    private var combsL: [SFXComb] = [], combsR: [SFXComb] = []
    private var allL: [SFXAllpass] = [], allR: [SFXAllpass] = []

    /// roomSize、damp 都是 0–1。
    init(roomSize: Double, damp: Double) {
        let feedback = 0.7 + 0.28 * SFX.clamp01(roomSize)
        let damping = 0.4 * SFX.clamp01(damp)
        let ratio = SFX.sampleRate / 44_100
        let spread = Int(23 * ratio)
        for n in [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617] {
            let length = Int(Double(n) * ratio)
            combsL.append(SFXComb(length: length, feedback: feedback, damp: damping))
            combsR.append(SFXComb(length: length + spread, feedback: feedback, damp: damping))
        }
        for n in [556, 441, 341, 225] {
            let length = Int(Double(n) * ratio)
            allL.append(SFXAllpass(length: length))
            allR.append(SFXAllpass(length: length + spread))
        }
    }

    /// 只回湿声。
    mutating func process(_ inL: Double, _ inR: Double) -> (Double, Double) {
        let input = (inL + inR) * 0.015
        var outL = 0.0, outR = 0.0
        for i in combsL.indices {
            outL += combsL[i].process(input)
            outR += combsR[i].process(input)
        }
        for i in allL.indices {
            outL = allL[i].process(outL)
            outR = allR[i].process(outR)
        }
        return (outL * 3, outR * 3)
    }
}

extension SFX {
    /// 房间大小从 size 0–1 换算，所有预设一个口径。
    static func roomSize(_ size: Double) -> Double { 0.5 + 0.47 * clamp01(size) }

    /// 把 send 送进混响，回来的只有湿声，比 send 长 tail 秒。
    static func reverbWet(_ send: SFXBuffer, roomSize: Double, damp: Double, tail: Double) -> SFXBuffer {
        var reverb = SFXFreeverb(roomSize: roomSize, damp: damp)
        var out = SFXBuffer(count: send.count + Int(tail * sampleRate))
        for i in 0..<out.count {
            let l = i < send.count ? send.left[i] : 0
            let r = i < send.count ? send.right[i] : 0
            let (wl, wr) = reverb.process(l, r)
            out.left[i] = wl
            out.right[i] = wr
        }
        return out
    }

    /// 干声 + 湿声：湿声的峰值 = 干声峰值 × maxRatio × size。size ≈ 0 就不加。
    static func mixReverb(dry: SFXBuffer, send: SFXBuffer, size: Double, damp: Double, tail: Double, maxRatio: Double) -> SFXBuffer {
        var out = dry
        guard size > 0.01 else { return out }
        let wet = reverbWet(send, roomSize: roomSize(size), damp: damp, tail: tail)
        let wetPeak = wet.peak, dryPeak = dry.peak
        guard wetPeak > 0, dryPeak > 0 else { return out }
        out.mix(wet, gain: dryPeak / wetPeak * maxRatio * clamp01(size))
        return out
    }

    /// 文件只留到 seconds 这么长，最后 fade 秒淡出（混响尾巴按门限裁还是太长，短音效要自己收）。
    static func limitTail(_ audio: inout SFXBuffer, to seconds: Double, fade: Double) {
        audio.resize(min(audio.count, Int(seconds * sampleRate)))
        audio.fadeOut(seconds: fade)
    }
}
