import Foundation

// MARK: - 合成音效的地基（纯值、确定、不碰文件）
//
// 管什么：采样率和几个数学小件（包络、指数插值、软削波、dB）、确定性随机数（SplitMix64，同种子同序列）、粉噪声、
// 相位累加器、PolyBLEP 锯齿、RBJ 双二阶滤波（系数可以逐采样换，用来扫频）。
// 不管什么：立体声缓冲（SoundEffectBuffer）、混响（SoundEffectReverb）、预设的声音设计（SFXAirPresets / SFXHitPresets /
// SFXTonePresets）、写文件（AIAudioFileWriter）。合同见 docs/architecture/sound-effect-synth.md。

enum SFX {
    static let sampleRate = 48_000.0
    static let twoPi = 2.0 * Double.pi

    static func clamp01(_ x: Double) -> Double { min(max(x, 0), 1) }

    static func smoothstep(_ x: Double) -> Double {
        let t = clamp01(x)
        return t * t * (3 - 2 * t)
    }

    /// 指数衰减 e^(−t/τ)；t < 0 是 0。
    static func decay(_ t: Double, tau: Double) -> Double { t < 0 ? 0 : Foundation.exp(-t / tau) }

    /// 线性起音：seconds 秒内从 0 到 1。
    static func attack(_ t: Double, _ seconds: Double) -> Double { seconds <= 0 ? 1 : clamp01(t / seconds) }

    /// a → b 的指数插值（音高、滤波频率都按这个走），x 夹在 0–1。
    static func sweep(_ a: Double, _ b: Double, _ x: Double) -> Double { a * pow(b / a, clamp01(x)) }

    static func softClip(_ x: Double, drive: Double) -> Double { tanh(x * drive) / tanh(drive) }

    static func linear(dB: Double) -> Double { pow(10, dB / 20) }

    /// PolyBLEP 锯齿：去掉边沿的混叠。
    static func polyBlepSaw(phase: Double, frequency: Double) -> Double {
        let dt = frequency / sampleRate
        var value = 2 * phase - 1
        if phase < dt {
            let t = phase / dt
            value -= t + t - t * t - 1
        } else if phase > 1 - dt {
            let t = (phase - 1) / dt
            value -= t * t + t + t + 1
        }
        return value
    }
}

// MARK: - 随机数（SplitMix64：同一种子同一序列，同参数渲出来逐采样一样）

struct SFXRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    /// 一段文字的 FNV-1a 哈希，当种子。
    static func seed(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x1_0000_0000_01b3
        }
        return hash
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// [0, 1)
    mutating func unit() -> Double { Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0) }
    /// [-1, 1)
    mutating func bipolar() -> Double { unit() * 2 - 1 }
    mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * unit() }
    mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    /// 1 ± amount
    mutating func jitter(_ amount: Double) -> Double { 1 + amount * bipolar() }
}

// MARK: - 噪声与振荡器

/// 粉噪声（Paul Kellet 的近似）：喂白噪声 [-1,1]，出来约 ±0.3。
struct SFXPinkNoise {
    private var b0 = 0.0, b1 = 0.0, b2 = 0.0, b3 = 0.0, b4 = 0.0, b5 = 0.0, b6 = 0.0

    mutating func next(_ white: Double) -> Double {
        b0 = 0.99886 * b0 + white * 0.0555179
        b1 = 0.99332 * b1 + white * 0.0750759
        b2 = 0.96900 * b2 + white * 0.1538520
        b3 = 0.86650 * b3 + white * 0.3104856
        b4 = 0.55000 * b4 + white * 0.5329522
        b5 = -0.7616 * b5 - white * 0.0168980
        let pink = b0 + b1 + b2 + b3 + b4 + b5 + b6 + white * 0.5362
        b6 = white * 0.115926
        return pink * 0.11
    }
}

/// 相位累加器：每拍给出相位 [0,1) 再按频率推进。
struct SFXPhasor {
    var phase = 0.0

    mutating func tick(_ frequency: Double) -> Double {
        let p = phase
        phase += frequency / SFX.sampleRate
        if phase >= 1 { phase -= floor(phase) }
        return p
    }
}

// MARK: - RBJ 双二阶（转置直接 II 型）

struct SFXBiquad {
    private var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    private var z1 = 0.0, z2 = 0.0

    init() {}

    /// 直接给系数（K 加权这类查表的）。
    init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
    }

    private static func clamped(_ frequency: Double) -> Double { min(max(frequency, 10), SFX.sampleRate * 0.45) }

    mutating func lowpass(_ frequency: Double, q: Double) {
        let w0 = SFX.twoPi * Self.clamped(frequency) / SFX.sampleRate
        let c = cos(w0), alpha = sin(w0) / (2 * q), a0 = 1 + alpha
        b0 = (1 - c) / 2 / a0; b1 = (1 - c) / a0; b2 = b0
        a1 = -2 * c / a0; a2 = (1 - alpha) / a0
    }

    mutating func highpass(_ frequency: Double, q: Double) {
        let w0 = SFX.twoPi * Self.clamped(frequency) / SFX.sampleRate
        let c = cos(w0), alpha = sin(w0) / (2 * q), a0 = 1 + alpha
        b0 = (1 + c) / 2 / a0; b1 = -(1 + c) / a0; b2 = b0
        a1 = -2 * c / a0; a2 = (1 - alpha) / a0
    }

    /// 峰值 0 dB 的带通。
    mutating func bandpass(_ frequency: Double, q: Double) {
        let w0 = SFX.twoPi * Self.clamped(frequency) / SFX.sampleRate
        let c = cos(w0), alpha = sin(w0) / (2 * q), a0 = 1 + alpha
        b0 = alpha / a0; b1 = 0; b2 = -alpha / a0
        a1 = -2 * c / a0; a2 = (1 - alpha) / a0
    }

    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}
