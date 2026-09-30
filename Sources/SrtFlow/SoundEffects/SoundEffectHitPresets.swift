import Foundation

// MARK: - 冲击一族的声音设计：impact / boom / hit / pop / click / tick（落点都在开头）
//
// 管什么：这六个预设怎么合成。impact 的低音一路不进混响、其余进大混响；boom 的包络分快慢两段让开头明显最响
// （软削波压平波形后「峰值时刻」才有意义）。
// 不管什么：地基（SoundEffectDSP）、混响（SoundEffectReverb）、收尾（SoundEffectSynth.render）。

enum SFXHitPresets {
    static func impact(_ p: SoundEffectParameters, _ rng: inout SFXRandom) -> SoundEffectRender {
        let dur = p.resolvedDuration
        let n = Int(dur * SFX.sampleRate)
        let attackTime = 0.005
        let subHi = 95 * p.pitch * rng.jitter(0.1), subLo = 36 * p.pitch
        var subPh = SFXPhasor(), thumpPh = SFXPhasor()
        var bodyLP = SFXBiquad(), clickHP = SFXBiquad()
        bodyLP.lowpass(900 * (0.5 + p.brightness), q: 0.7)
        clickHP.highpass(3000, q: 0.7)
        var pink = SFXPinkNoise()
        var sub = SFXBuffer(count: n), send = SFXBuffer(count: n)
        for i in 0..<n {
            let t = Double(i) / SFX.sampleRate
            let a = SFX.attack(t, attackTime)
            let fSub = subLo + (subHi - subLo) * SFX.decay(t, tau: 0.12)
            let low = SFX.softClip(sin(SFX.twoPi * subPh.tick(fSub)) * SFX.decay(t, tau: 0.55), drive: 2.0)
            let thump = sin(SFX.twoPi * thumpPh.tick(170 * p.pitch)) * SFX.decay(t, tau: 0.08) * 0.7
            let white = rng.bipolar()
            let body = bodyLP.process(pink.next(white)) * 3 * SFX.decay(t, tau: 0.09) * 0.8
            let click = clickHP.process(white) * SFX.decay(t, tau: 0.006) * 0.5
            sub.add(i, low * a)
            send.add(i, (thump + body + click) * a)
        }
        var dry = sub
        dry.mix(send)
        let size = p.resolvedSize
        let out = SFX.mixReverb(dry: dry, send: send, size: size, damp: 0.5 - 0.3 * p.brightness, tail: 0.3 + 2.0 * size, maxRatio: 0.55)
        return SoundEffectRender(audio: out, hitAt: attackTime)
    }

    static func boom(_ p: SoundEffectParameters, _ rng: inout SFXRandom) -> SoundEffectRender {
        let dur = p.resolvedDuration
        let n = Int(dur * SFX.sampleRate)
        let attackTime = 0.004
        let hi = 70 * p.pitch * rng.jitter(0.1), lo = 26 * p.pitch
        var ph = SFXPhasor()
        var thudLP = SFXBiquad()
        thudLP.lowpass(400, q: 0.7)
        var pink = SFXPinkNoise()
        var out = SFXBuffer(count: n)
        for i in 0..<n {
            let t = Double(i) / SFX.sampleRate
            let a = SFX.attack(t, attackTime)
            let f = lo + (hi - lo) * SFX.decay(t, tau: 0.25)
            let env = 0.55 * SFX.decay(t, tau: 0.8) + 0.45 * SFX.decay(t, tau: 0.12)
            let low = SFX.softClip(sin(SFX.twoPi * ph.tick(f)) * env, drive: 3.0)
            let thud = thudLP.process(pink.next(rng.bipolar())) * 3 * SFX.decay(t, tau: 0.03) * 0.5
            out.add(i, (low + thud) * a)
        }
        let size = p.resolvedSize
        out = SFX.mixReverb(dry: out, send: out, size: size, damp: 0.7, tail: 0.3 + 1.0 * size, maxRatio: 0.3)
        return SoundEffectRender(audio: out, hitAt: attackTime)
    }

    static func hit(_ p: SoundEffectParameters, _ rng: inout SFXRandom) -> SoundEffectRender {
        let dur = p.resolvedDuration
        let n = Int(dur * SFX.sampleRate)
        let attackTime = 0.001
        let hi = 160 * p.pitch * rng.jitter(0.1), lo = 48 * p.pitch
        var ph = SFXPhasor()
        var snapBand = SFXBiquad()
        snapBand.bandpass(3000 * (0.6 + 0.8 * p.brightness), q: 1.2)
        var out = SFXBuffer(count: n)
        for i in 0..<n {
            let t = Double(i) / SFX.sampleRate
            let f = lo + (hi - lo) * SFX.decay(t, tau: 0.035)
            let kick = SFX.softClip(sin(SFX.twoPi * ph.tick(f)) * SFX.decay(t, tau: 0.15), drive: 1.5)
            let snap = snapBand.process(rng.bipolar()) * SFX.decay(t, tau: 0.012) * 0.8
            out.add(i, (kick + snap) * SFX.attack(t, attackTime))
        }
        let size = p.resolvedSize
        out = SFX.mixReverb(dry: out, send: out, size: size, damp: 0.6, tail: 0.2 + 0.8 * size, maxRatio: 0.35)
        return SoundEffectRender(audio: out, hitAt: attackTime)
    }

    static func pop(_ p: SoundEffectParameters, _ rng: inout SFXRandom) -> SoundEffectRender {
        let n = Int(p.resolvedDuration * SFX.sampleRate)
        let hi = 1250 * p.pitch * rng.jitter(0.12), lo = 320 * p.pitch
        var ph = SFXPhasor()
        var clickHP = SFXBiquad()
        clickHP.highpass(4000, q: 0.7)
        var out = SFXBuffer(count: n)
        for i in 0..<n {
            let t = Double(i) / SFX.sampleRate
            let f = lo + (hi - lo) * SFX.decay(t, tau: 0.012)
            let tone = sin(SFX.twoPi * ph.tick(f)) * SFX.attack(t, 0.0005) * SFX.decay(t, tau: 0.028)
            out.add(i, tone + clickHP.process(rng.bipolar()) * SFX.decay(t, tau: 0.002) * 0.4)
        }
        return SoundEffectRender(audio: out, hitAt: 0.002)
    }

    static func click(_ p: SoundEffectParameters, _ rng: inout SFXRandom) -> SoundEffectRender {
        let n = Int(p.resolvedDuration * SFX.sampleRate)
        var hp = SFXBiquad()
        hp.highpass(5000, q: 0.7)
        var ph = SFXPhasor()
        let f = 3800 * p.pitch * rng.jitter(0.1)
        var out = SFXBuffer(count: n)
        for i in 0..<n {
            let t = Double(i) / SFX.sampleRate
            let noise = hp.process(rng.bipolar()) * SFX.attack(t, 0.0002) * SFX.decay(t, tau: 0.0015)
            out.add(i, noise + sin(SFX.twoPi * ph.tick(f)) * SFX.decay(t, tau: 0.006) * 0.7)
        }
        return SoundEffectRender(audio: out, hitAt: 0.001)
    }

    static func tick(_ p: SoundEffectParameters, _ rng: inout SFXRandom) -> SoundEffectRender {
        let n = Int(p.resolvedDuration * SFX.sampleRate)
        var ph1 = SFXPhasor(), ph2 = SFXPhasor()
        let f1 = 1900 * p.pitch * rng.jitter(0.05), f2 = 2950 * p.pitch * rng.jitter(0.05)
        var hp = SFXBiquad()
        hp.highpass(4000, q: 0.7)
        var out = SFXBuffer(count: n)
        for i in 0..<n {
            let t = Double(i) / SFX.sampleRate
            let s = sin(SFX.twoPi * ph1.tick(f1)) * SFX.decay(t, tau: 0.022)
                + sin(SFX.twoPi * ph2.tick(f2)) * SFX.decay(t, tau: 0.014) * 0.7
                + hp.process(rng.bipolar()) * SFX.decay(t, tau: 0.0008) * 0.3
            out.add(i, s * SFX.attack(t, 0.0003))
        }
        return SoundEffectRender(audio: out, hitAt: 0.001)
    }
}
