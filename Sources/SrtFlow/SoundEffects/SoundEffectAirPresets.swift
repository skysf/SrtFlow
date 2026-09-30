import Foundation

// MARK: - 气流一族的声音设计：whoosh / swoosh / suction / riser / downlifter
//
// 管什么：这五个预设怎么合成、各自的落点。riser / downlifter 是 2026-09-30 第二版：照 ElevenLabs 的 Kinetic_Lift / The_Descent
// 量出来的形状重做（riser 音量按 dB 线性升、频谱从偏音调变宽噪声、左右不相关；descent 是低音音调「涌起再往下掉」），
// 第一版的锯齿 + 颤音用户听着「不舒服、不自然」。
// 不管什么：地基（SoundEffectDSP）、混响（SoundEffectReverb）、收尾（SoundEffectSynth.render）。

enum SFXAirPresets {
    /// whoosh（0.9 s，落点在 60%）/ swoosh（0.38 s，更亮、带一条轻的下滑音）：粉噪声过扫频带通，慢起（幂 2.4）到落点再落下，
    /// 落点前偏高、落点后偏低（多普勒），声像从一边扫到另一边。
    static func whoosh(_ p: SoundEffectParameters, _ rng: inout SFXRandom, short: Bool) -> SoundEffectRender {
        let dur = p.resolvedDuration * rng.jitter(0.06)
        let hitFrac = short ? 0.55 : 0.6
        let hitTime = dur * hitFrac
        let n = Int(dur * SFX.sampleRate)
        let fLow = 220 * p.pitch * rng.jitter(0.12)
        let fTop = (short ? 5000.0 : 2600.0) * p.pitch * (0.55 + 0.9 * p.brightness) * rng.jitter(0.1)
        let fEnd = fTop * 0.3
        let q = 1.0 * rng.jitter(0.25)
        let direction: Double = rng.unit() < 0.5 ? 1 : -1
        let fallTau = (dur - hitTime) / 3.5
        var pink = SFXPinkNoise()
        var band = SFXBiquad(), air = SFXBiquad()
        var sweep = SFXPhasor()
        var dry = SFXBuffer(count: n)
        for i in 0..<n {
            let t = Double(i) / SFX.sampleRate
            let u = t / dur
            let env = u < hitFrac ? pow(u / hitFrac, 2.4) : SFX.decay(t - hitTime, tau: fallTau)
            let doppler = 1 + 0.12 * tanh((hitFrac - u) * 6)
            let f = u < hitFrac
                ? SFX.sweep(fLow, fTop, SFX.smoothstep(u / hitFrac))
                : SFX.sweep(fTop, fEnd, (u - hitFrac) / (1 - hitFrac))
            band.bandpass(f * doppler, q: q)
            air.highpass(min(f * 2.5, 12_000), q: 0.7)
            let white = rng.bipolar()
            var s = band.process(pink.next(white)) * 3.0
            s += air.process(white) * 0.12 * p.brightness
            if short {
                s += sin(SFX.twoPi * sweep.tick(SFX.sweep(1100 * p.pitch, 380 * p.pitch, u))) * 0.10
            }
            s *= env
            dry.add(i, s, pan: direction * 0.8 * tanh((u - hitFrac) * 4))
        }
        let size = p.resolvedSize
        let out = SFX.mixReverb(dry: dry, send: dry, size: size, damp: 0.6 - 0.4 * p.brightness, tail: 0.2 + 1.2 * size, maxRatio: 0.4)
        return SoundEffectRender(audio: out, hitAt: hitTime)
    }

    /// suction（倒吸）：一小段噪声爆发 + 大混响，整段倒过来、开头 smoothstep 淡入；再叠一条往上扫的噪声给方向感。落点 = 结尾。
    static func suction(_ p: SoundEffectParameters, _ rng: inout SFXRandom) -> SoundEffectRender {
        let dur = p.resolvedDuration * rng.jitter(0.08)
        let n = Int(dur * SFX.sampleRate)
        let burstN = Int(0.3 * SFX.sampleRate)
        var burst = SFXBuffer(count: burstN)
        var pink = SFXPinkNoise()
        var band = SFXBiquad()
        band.bandpass(1400 * p.pitch * (0.6 + 0.8 * p.brightness) * rng.jitter(0.15), q: 0.8)
        for i in 0..<burstN {
            let t = Double(i) / SFX.sampleRate
            burst.add(i, band.process(pink.next(rng.bipolar())) * 3 * SFX.attack(t, 0.002) * SFX.decay(t, tau: 0.08))
        }
        var forward = SFX.mixReverb(dry: burst, send: burst, size: p.resolvedSize, damp: 0.3, tail: dur, maxRatio: 0.75)
        forward.resize(n)
        var sweepBand = SFXBiquad()
        var pink2 = SFXPinkNoise()
        var rising = SFXBuffer(count: n)
        for i in 0..<n {
            let t = Double(i) / SFX.sampleRate
            let u = t / dur
            sweepBand.bandpass(SFX.sweep(300 * p.pitch, 3200 * p.pitch, u), q: 1.2)
            rising.add(i, sweepBand.process(pink2.next(rng.bipolar())) * 3 * pow(u, 2.5) * SFX.attack(dur - t, 0.003))
        }
        var out = forward.reversed()
        out.mix(rising, gain: 0.4 * burst.peak / max(rising.peak, 1e-9))
        out.fadeIn(seconds: dur * 0.15)
        return SoundEffectRender(audio: out, hitAt: dur)
    }

    /// 正弦 + 弱的 2、3 次泛音：软、不像锯齿。
    private static func droneVoice(_ ph: inout SFXPhasor, _ f: Double) -> Double {
        let x = SFX.twoPi * ph.tick(f)
        return sin(x) + 0.3 * sin(2 * x) + 0.12 * sin(3 * x)
    }

    /// riser：两路独立噪声（左右不相关）过一对打开的低通 + 抬高的高通 = 气流越来越宽越来越亮；一条 Q 高的带通噪声给开头的
    /// 「口哨」质感；一层很软的音调升一个八度垫底、比重随时间减小。音量从 −36 dB 按 dB 线性升到 0，结尾 15 ms 收掉。落点 = 结尾。
    static func riser(_ p: SoundEffectParameters, _ rng: inout SFXRandom) -> SoundEffectRender {
        let dur = p.resolvedDuration * rng.jitter(0.05)
        let n = Int(dur * SFX.sampleRate)
        let bright = 0.6 + 0.8 * p.brightness
        let lpEnd = 14_000 * bright * rng.jitter(0.1), hpEnd = 800 * rng.jitter(0.1)
        let whistleQ = 3.0 * rng.jitter(0.2)
        let droneF0 = 165 * p.pitch * rng.jitter(0.04)
        var pinkL = SFXPinkNoise(), pinkR = SFXPinkNoise(), pinkW = SFXPinkNoise()
        var lpL = SFXBiquad(), lpR = SFXBiquad(), hpL = SFXBiquad(), hpR = SFXBiquad(), whistle = SFXBiquad()
        var droneL = SFXPhasor(), droneR = SFXPhasor(), vib = SFXPhasor()
        var dry = SFXBuffer(count: n)
        for i in 0..<n {
            let t = Double(i) / SFX.sampleRate
            let u = t / dur
            let cutoff = SFX.sweep(800, lpEnd, u), floor = SFX.sweep(100, hpEnd, u)
            lpL.lowpass(cutoff, q: 0.8); lpR.lowpass(cutoff, q: 0.8)
            hpL.highpass(floor, q: 0.7); hpR.highpass(floor, q: 0.7)
            whistle.bandpass(SFX.sweep(500, 5000 * bright, u), q: whistleQ)
            let bodyL = hpL.process(lpL.process(pinkL.next(rng.bipolar()))) * 3
            let bodyR = hpR.process(lpR.process(pinkR.next(rng.bipolar()))) * 3
            let whistleN = whistle.process(pinkW.next(rng.bipolar())) * 3 * 0.5
            let f = SFX.sweep(droneF0, droneF0 * 2, u) * (1 + 0.004 * sin(SFX.twoPi * vib.tick(5.5)))
            let droneLevel = (0.35 - 0.15 * u) * (1.2 - 0.6 * p.brightness)
            let dl = droneVoice(&droneL, f * 1.003), dr = droneVoice(&droneR, f * 0.997)
            let env = SFX.linear(dB: -36 + 36 * u) * SFX.attack(t, 0.06) * SFX.attack(dur - t, 0.015)
            dry.add(i, left: (bodyL + whistleN + dl * droneLevel) * env, right: (bodyR + whistleN + dr * droneLevel) * env)
        }
        let size = p.resolvedSize
        var out = SFX.mixReverb(dry: dry, send: dry, size: size, damp: 0.5, tail: 0.3 + 1.2 * size, maxRatio: 0.4)
        SFX.limitTail(&out, to: dur + 0.35, fade: 0.3)
        return SoundEffectRender(audio: out, hitAt: dur)
    }

    /// downlifter：低音音调「涌起再往下掉」。音高在前 40% 从 110 Hz 掉一个八度；音量前 12% 平滑涌起到顶，之后指数衰减、
    /// 最后 15% 淡完；一层暗下去的气声（低通 3 kHz → 300 Hz）。落点 = 涌起到顶的那一刻。
    static func downlifter(_ p: SoundEffectParameters, _ rng: inout SFXRandom) -> SoundEffectRender {
        let dur = p.resolvedDuration * rng.jitter(0.05)
        let n = Int(dur * SFX.sampleRate)
        let f0 = 110 * p.pitch * rng.jitter(0.05)
        let swell = 0.12 * dur
        var voiceL = SFXPhasor(), voiceR = SFXPhasor(), vib = SFXPhasor()
        var pinkL = SFXPinkNoise(), pinkR = SFXPinkNoise()
        var lpL = SFXBiquad(), lpR = SFXBiquad()
        let bright = 0.6 + 0.8 * p.brightness
        var dry = SFXBuffer(count: n)
        for i in 0..<n {
            let t = Double(i) / SFX.sampleRate
            let u = t / dur
            let f = SFX.sweep(f0, f0 * 0.5, u / 0.4) * (1 + 0.005 * sin(SFX.twoPi * vib.tick(4.5)))
            let cutoff = SFX.sweep(3000 * bright, 300, u)
            lpL.lowpass(cutoff, q: 0.8); lpR.lowpass(cutoff, q: 0.8)
            let airL = lpL.process(pinkL.next(rng.bipolar())) * 3 * 0.35
            let airR = lpR.process(pinkR.next(rng.bipolar())) * 3 * 0.35
            let env = (t < swell ? SFX.smoothstep(t / swell) : SFX.decay(t - swell, tau: 0.25 * dur)) * SFX.attack(dur - t, 0.15 * dur)
            let vl = droneVoice(&voiceL, f * 1.004), vr = droneVoice(&voiceR, f * 0.996)
            dry.add(i, left: (vl * 0.7 + airL) * env, right: (vr * 0.7 + airR) * env)
        }
        let size = p.resolvedSize
        var out = SFX.mixReverb(dry: dry, send: dry, size: size, damp: 0.5, tail: 0.3 + 1.5 * size, maxRatio: 0.4)
        SFX.limitTail(&out, to: dur + 0.4, fade: 0.35)
        return SoundEffectRender(audio: out, hitAt: swell)
    }
}
