import Foundation

// MARK: - 合成音效：预设清单、参数、渲染入口
//
// 管什么：16 个预设的名字和默认时长；AI 给的参数（duration / pitch / brightness / size / variation）和它们的范围；
// 「同参数 = 同文件」的名字（参数 + 合成器版本的哈希）；渲染的收尾（峰值 −1 dBFS 封顶、K 加权最大瞬时响度 ≤ −9 LUFS、
// 尾巴按 −60 dB 裁、末尾淡出）；每个预设自己知道**落点**（`hitAt`：最响那一刻在第几秒，AI 按它把冲击压在切点上）。
// 用户 2026-09-30 逐个听过定稿（docs/plans/2026-09-30-sound-effects.md 第六节），改声音设计要再给用户听。
// 不管什么：声音设计本身（SFXAirPresets / SFXHitPresets / SFXTonePresets）、写文件和放上时间线（AISoundEffectTool）。

enum SoundEffectPreset: String, CaseIterable, Codable, Sendable {
    case whoosh, swoosh, suction, riser, downlifter
    case impact, boom, hit, pop, click, tick
    case ding, sparkle, beep, glitch, shutter

    /// 默认多长（秒，不含混响尾巴）。用户 2026-09-30：「就像别的，裁剪到就开始那一次声音就可以了」—— 都短。
    var defaultDuration: Double {
        switch self {
        case .whoosh: return 0.9
        case .swoosh: return 0.38
        case .suction: return 1.2
        case .riser: return 1.2
        case .downlifter: return 1.0
        case .impact: return 1.6
        case .boom: return 2.0
        case .hit: return 0.5
        case .pop: return 0.15
        case .click: return 0.05
        case .tick: return 0.08
        case .ding: return 0.9
        case .sparkle: return 1.2
        case .beep: return 0.2
        case .glitch: return 0.4
        case .shutter: return 0.2
        }
    }

    /// 默认的空间（0 干 … 1 大厅）。
    var defaultSize: Double {
        switch self {
        case .whoosh: return 0.25
        case .swoosh: return 0.15
        case .suction: return 0.93
        case .riser: return 0.3
        case .downlifter: return 0.4
        case .impact: return 0.7
        case .boom: return 0.2
        case .hit: return 0.15
        case .ding: return 0.4
        case .sparkle: return 0.8
        case .pop, .click, .tick, .beep, .glitch, .shutter: return 0
        }
    }
}

struct SoundEffectParameters: Hashable, Sendable {
    var preset: SoundEffectPreset
    /// nil = 预设自己的默认长度
    var duration: Double?
    /// 音高倍数
    var pitch: Double = 1
    /// 0–1
    var brightness: Double = 0.5
    /// 空间 0–1，nil = 预设默认
    var size: Double?
    /// 变体种子：只换随机数和 ±5–10% 的抖动
    var variation: Int = 0

    static let durationRange: ClosedRange<Double> = 0.05...10
    static let pitchRange: ClosedRange<Double> = 0.25...4
    static let unitRange: ClosedRange<Double> = 0...1
    static let variationRange: ClosedRange<Int> = 0...999

    init(preset: SoundEffectPreset, duration: Double? = nil, pitch: Double = 1, brightness: Double = 0.5,
         size: Double? = nil, variation: Int = 0) {
        self.preset = preset
        self.duration = duration
        self.pitch = pitch
        self.brightness = brightness
        self.size = size
        self.variation = variation
    }

    /// 哪个参数越界了（给 AI 的话）；都在范围里就 nil。
    var problem: String? {
        if let duration, !Self.durationRange.contains(duration) { return "duration must be between 0.05 and 10 seconds." }
        if !Self.pitchRange.contains(pitch) { return "pitch must be between 0.25 and 4." }
        if !Self.unitRange.contains(brightness) { return "brightness must be between 0 and 1." }
        if let size, !Self.unitRange.contains(size) { return "size must be between 0 and 1." }
        if !Self.variationRange.contains(variation) { return "variation must be a whole number from 0 to 999." }
        return nil
    }

    var resolvedDuration: Double { duration ?? preset.defaultDuration }
    var resolvedSize: Double { size ?? preset.defaultSize }

    /// 参数的一份文字（三位小数），种子和文件名都从它来：同参数就是同一个种子、同一个文件。
    var canonical: String {
        func f(_ x: Double) -> String { String(format: "%.3f", x) }
        return "\(preset.rawValue)|d=\(f(resolvedDuration))|p=\(f(pitch))|b=\(f(brightness))|s=\(f(resolvedSize))|v=\(variation)"
    }

    var seed: UInt64 { SFXRandom.seed("\(preset.rawValue):\(variation)") }

    /// 文件名（不带扩展名）：预设名 + 参数和合成器版本的 8 位哈希。
    var fileStem: String {
        let hash = SFXRandom.seed(canonical + "|synth=\(SoundEffectSynth.version)")
        return "\(preset.rawValue)-" + String(format: "%08x", UInt32(truncatingIfNeeded: hash ^ (hash >> 32)))
    }
}

struct SoundEffectRender: Sendable {
    enum HitKind: String, Sendable {
        /// 最响的那一刻
        case peak
        /// 声音从这儿起（sparkle 那种一串的，落点是第一下，之后堆起来更响是设计）
        case onset
    }

    var audio: SFXBuffer
    /// 落点（秒）
    var hitAt: Double
    var hitKind: HitKind = .peak
}

enum SoundEffectSynth {
    /// 声音设计变了就 +1：文件名跟着变，旧文件不会被当成同一个声音复用。
    static let version = 1
    /// 峰值封顶。
    static let peakCeilingDB = -1.0
    /// K 加权最大瞬时响度的上限：定在用户点头的噪声 / 冲击类（whoosh −9.4、impact −9.0）上，它们照旧由峰值封顶；
    /// 音调类的（ding、beep、glitch、sparkle）被它压下来。
    static let loudnessCeilingLUFS = -9.0
    /// 尾巴比这个轻的切掉。
    static let tailFloorDB = -60.0

    static func render(_ parameters: SoundEffectParameters) -> SoundEffectRender {
        let p = parameters
        var rng = SFXRandom(seed: p.seed)
        var result: SoundEffectRender
        var endFade = 0.01
        switch p.preset {
        case .whoosh: result = SFXAirPresets.whoosh(p, &rng, short: false)
        case .swoosh: result = SFXAirPresets.whoosh(p, &rng, short: true)
        case .suction:
            result = SFXAirPresets.suction(p, &rng)
            endFade = 0.002   // 结尾就是落点，戛然而止
        case .riser: result = SFXAirPresets.riser(p, &rng)
        case .downlifter: result = SFXAirPresets.downlifter(p, &rng)
        case .impact: result = SFXHitPresets.impact(p, &rng)
        case .boom: result = SFXHitPresets.boom(p, &rng)
        case .hit: result = SFXHitPresets.hit(p, &rng)
        case .pop: result = SFXHitPresets.pop(p, &rng)
        case .click: result = SFXHitPresets.click(p, &rng)
        case .tick: result = SFXHitPresets.tick(p, &rng)
        case .ding: result = SFXTonePresets.ding(p, &rng)
        case .sparkle: result = SFXTonePresets.sparkle(p, &rng)
        case .beep: result = SFXTonePresets.beep(p, &rng)
        case .glitch: result = SFXTonePresets.glitch(p, &rng)
        case .shutter: result = SFXTonePresets.shutter(p, &rng)
        }
        // 先按峰值归一（裁尾巴的门限才是相对峰值的），裁掉尾巴，再按响度封顶：短于 400 ms 的声音裁掉尾部静音后
        // 同一窗的平均功率会升，响度要在裁完的那一份上量。
        result.audio.normalize(peakDB: peakCeilingDB)
        result.audio.trimTail(thresholdDB: tailFloorDB)
        result.audio.normalize(peakDB: peakCeilingDB, loudnessLUFS: loudnessCeilingLUFS)
        result.audio.fadeOut(seconds: endFade)
        return result
    }
}
