import Foundation

// MARK: - 音调一族的声音设计：ding / sparkle / beep / glitch / shutter
//
// 管什么：这五个预设怎么合成。ding 的落点是敲下去那一下；sparkle / glitch 的落点是**起点**（一串的，之后堆起来更响是设计）。
// 不管什么：地基（SoundEffectDSP）、混响（SoundEffectReverb）、收尾（SoundEffectSynth.render）。

enum SFXTonePresets {
    /// FM 铃：载波约 1.32 kHz、调制比 1.4、调制指数随时间衰减，左右声道差 0.3 Hz 产生拍频；敲下去那一下比余音亮一截。
    static func ding(_ p: SoundEffectParameters, _ rng: inout SFXRandom) -> SoundEffectRender {
        let dur = p.resolvedDuration
        let n = Int(dur * SFX.sampleRate)
        let fc = 1320 * p.pitch * rng.jitter(0.03)
        let ratio = 1.4
        var carL = SFXPhasor(), carR = SFXPhasor(), modL = SFXPhasor(), modR = SFXPhasor()
        var out = SFXBuffer(count: n)
        for i in 0..<n {
            let t = Double(i) / SFX.sampleRate
            let index = (6 * SFX.decay(t, tau: 0.25) + 0.8) * (0.6 + 0.8 * p.brightness)
            let amp = SFX.attack(t, 0.002) * SFX.decay(t, tau: 0.35) * (1 + 0.35 * SFX.decay(t, tau: 0.03)) * SFX.attack(dur - t, 0.1)
            let l = sin(SFX.twoPi * carL.tick(fc) + index * sin(SFX.twoPi * modL.tick(fc * ratio)))
            let r = sin(SFX.twoPi * carR.tick(fc + 0.3) + index * sin(SFX.twoPi * modR.tick((fc + 0.3) * ratio)))
            out.add(i, left: l * amp * 0.7, right: r * amp * 0.7)
        }
        let size = p.resolvedSize
        out = SFX.mixReverb(dry: out, send: out, size: size, damp: 0.3, tail: 0.3 + 1.5 * size, maxRatio: 0.4)
        SFX.limitTail(&out, to: dur + 0.4, fade: 0.35)
        return SoundEffectRender(audio: out, hitAt: 0.002)
    }

    /// 0.45 秒内错落 8 个高音「闪」（C7 往上的五声音阶，顺序随机），每个带一条 2.76 倍的泛音、随机声像；第一下最响。
    static func sparkle(_ p: SoundEffectParameters, _ rng: inout SFXRandom) -> SoundEffectRender {
        let n = Int(p.resolvedDuration * SFX.sampleRate)
        var scale = [2093.0, 2349.3, 2637.0, 3136.0, 3520.0, 4186.0, 4698.6, 5274.0].map { $0 * p.pitch }
        for i in stride(from: scale.count - 1, to: 0, by: -1) { scale.swapAt(i, rng.int(i + 1)) }
        var out = SFXBuffer(count: n)
        for k in 0..<8 {
            let start: Double = k == 0 ? 0 : Double(k) * 0.45 / 8 + rng.range(0, 0.02)
            let pan = rng.range(-0.8, 0.8)
            let level = k == 0 ? 0.9 : 0.4 * rng.jitter(0.3)
            let f = scale[k]
            var ph1 = SFXPhasor(), ph2 = SFXPhasor()
            let from = Int(start * SFX.sampleRate)
            for i in from..<n {
                let t = Double(i - from) / SFX.sampleRate
                let s = (sin(SFX.twoPi * ph1.tick(f)) + 0.35 * sin(SFX.twoPi * ph2.tick(f * 2.76)))
                    * SFX.attack(t, 0.001) * SFX.decay(t, tau: 0.35)
                out.add(i, s * level, pan: pan)
            }
        }
        let size = p.resolvedSize
        out = SFX.mixReverb(dry: out, send: out, size: size, damp: 0.15, tail: 0.3 + 1.5 * size, maxRatio: 0.5)
        return SoundEffectRender(audio: out, hitAt: 0, hitKind: .onset)
    }

    /// 两段提示音；variation 换音型：0 上行（880 → 1320 Hz）、1 下行、2 单音。正弦加少量 3、5 次谐波。
    static func beep(_ p: SoundEffectParameters, _ rng: inout SFXRandom) -> SoundEffectRender {
        let tones: [(f: Double, start: Double, length: Double)]
        switch p.variation % 3 {
        case 0: tones = [(880, 0, 0.07), (1320, 0.09, 0.09)]
        case 1: tones = [(1320, 0, 0.07), (880, 0.09, 0.09)]
        default: tones = [(1100, 0, 0.12)]
        }
        let n = Int(p.resolvedDuration * SFX.sampleRate)
        let h3 = 0.15 * (0.4 + 1.2 * p.brightness), h5 = 0.06 * (0.4 + 1.2 * p.brightness)
        var out = SFXBuffer(count: n)
        for tone in tones {
            var ph = SFXPhasor()
            let f = tone.f * p.pitch
            let from = Int(tone.start * SFX.sampleRate), to = min(n, Int((tone.start + tone.length) * SFX.sampleRate))
            for i in from..<max(from, to) {
                let t = Double(i - from) / SFX.sampleRate
                let env = SFX.attack(t, 0.003) * SFX.attack(tone.length - t, 0.008)
                let x = SFX.twoPi * ph.tick(f)
                out.add(i, (sin(x) + h3 * sin(3 * x) + h5 * sin(5 * x)) * env * 0.8)
            }
        }
        return SoundEffectRender(audio: out, hitAt: 0.003)
    }

    /// 故障音：15–60 ms 的随机片段（方波 / 噪声 / 静音），5 bit 量化、×6 采样保持、声像乱跳；第一段一定有声、最响。
    static func glitch(_ p: SoundEffectParameters, _ rng: inout SFXRandom) -> SoundEffectRender {
        let n = Int(p.resolvedDuration * SFX.sampleRate)
        var out = SFXBuffer(count: n)
        var at = 0
        while at < n {
            let length = Int(rng.range(0.015, 0.06) * SFX.sampleRate)
            var kind = rng.int(4)   // 0,1 方波；2 噪声；3 静音
            let f = SFX.sweep(200, 2000, rng.unit()) * p.pitch
            var amp = rng.range(0.4, 0.9)
            if at == 0 {
                kind = kind == 3 ? 0 : kind
                amp = 1
            }
            let pan = rng.range(-0.9, 0.9)
            var ph = SFXPhasor()
            var held = 0.0
            let end = min(n, at + length)
            for i in at..<end where kind != 3 {
                if (i - at) % 6 == 0 {
                    let raw = kind == 2 ? rng.bipolar() : (ph.phase < 0.5 ? 1.0 : -1.0)
                    held = (raw * 16).rounded() / 16
                }
                _ = ph.tick(f)
                let t = Double(i - at) / SFX.sampleRate
                let env = SFX.attack(t, 0.0005) * SFX.attack(Double(end - i) / SFX.sampleRate, 0.0005)
                out.add(i, held * amp * env * (0.4 + 0.6 * p.brightness), pan: pan)
            }
            at = end
        }
        return SoundEffectRender(audio: out, hitAt: 0, hitKind: .onset)
    }

    /// 快门：两下「咔」（0 和 85 ms，第二下略轻），中间一点机械声。
    static func shutter(_ p: SoundEffectParameters, _ rng: inout SFXRandom) -> SoundEffectRender {
        let n = Int(p.resolvedDuration * SFX.sampleRate)
        let second = 0.085 * rng.jitter(0.1)
        var out = SFXBuffer(count: n)
        for (index, start) in [0.0, second].enumerated() {
            let level = index == 0 ? 1.0 : 0.8
            var band = SFXBiquad()
            band.bandpass(3500 * p.pitch, q: 1.5)
            var ph1 = SFXPhasor(), ph2 = SFXPhasor()
            let from = Int(start * SFX.sampleRate)
            for i in from..<min(n, from + Int(0.05 * SFX.sampleRate)) {
                let t = Double(i - from) / SFX.sampleRate
                let s = band.process(rng.bipolar()) * SFX.decay(t, tau: 0.006)
                    + sin(SFX.twoPi * ph1.tick(1250 * p.pitch)) * SFX.decay(t, tau: 0.008) * 0.5
                    + sin(SFX.twoPi * ph2.tick(2600 * p.pitch)) * SFX.decay(t, tau: 0.005) * 0.4
                out.add(i, s * SFX.attack(t, 0.0003) * level)
            }
        }
        var lp = SFXBiquad()
        lp.lowpass(1200, q: 0.7)
        var pink = SFXPinkNoise()
        let from = Int(0.01 * SFX.sampleRate), to = min(n, Int(second * SFX.sampleRate))
        for i in from..<max(from, to) {
            let buzz = 0.5 + 0.5 * sin(SFX.twoPi * 120 * Double(i) / SFX.sampleRate)
            out.add(i, lp.process(pink.next(rng.bipolar())) * 3 * buzz * 0.12)
        }
        return SoundEffectRender(audio: out, hitAt: 0.001)
    }
}
