import Foundation
import SrtFlowMCPKit

// 合成音效（docs/architecture/sound-effect-synth.md）：16 个预设都渲得出、峰值 −1 dBFS 封顶、K 加权响度 ≤ −9 LUFS、
// 落点在声音里且实测峰值离它不远（sparkle / glitch 的落点是起点，不比）、文件短、末尾淡完；同参数逐采样一致、换 variation 就不同、
// 同参数同文件名；whoosh 的亮度先升后降、riser / suction 一路升、downlifter 一路降；参数范围；add_clips 的 sound_effect 条目
// 怎么读、落点怎么算开头；词表和 App 的预设对账、总说明里提到它。编法见 scripts/check-mcp.sh。

func runSoundEffectChecks() {
    presetChecks()
    determinismChecks()
    shapeChecks()
    parameterChecks()
    soundEffectRequestChecks()
    checkEqual(MCPVocabulary.soundEffectPresets, SoundEffectPreset.allCases.map(\.rawValue), "the sound_effect presets match SoundEffectPreset")
    check(MCPInstructions.text.contains("add_clips sound_effect"), "the instructions' Sound line points at add_clips sound_effect")
}

private func presetChecks() {
    for preset in SoundEffectPreset.allCases {
        let render = SoundEffectSynth.render(SoundEffectParameters(preset: preset))
        let audio = render.audio
        let name = preset.rawValue
        check(audio.count > 0 && audio.seconds >= preset.defaultDuration * 0.5, "\(name) renders something at least half its default length (\(audio.seconds) s)")
        check(audio.seconds <= preset.defaultDuration + 2.4, "\(name) does not drag on past its default length + tail (\(audio.seconds) s)")
        let peak = audio.peak
        check(peak <= SFX.linear(dB: -1) + 1e-6, "\(name) peaks at or under -1 dBFS (\(peak))")
        check(peak >= 0.2, "\(name) is not silent after normalization (\(peak))")
        check(audio.maxMomentaryLoudness <= SoundEffectSynth.loudnessCeilingLUFS + 0.05, "\(name) stays under -9 LUFS momentary (\(audio.maxMomentaryLoudness))")
        check(!audio.left.contains { !$0.isFinite } && !audio.right.contains { !$0.isFinite }, "\(name) has no NaN or infinity")
        check(render.hitAt >= 0 && render.hitAt <= audio.seconds + 0.01, "\(name)'s hit_at lies inside the sound (\(render.hitAt) of \(audio.seconds) s)")
        if render.hitKind == .peak {
            let peakAt = Double(audio.peakIndex) / SFX.sampleRate
            let tolerance: Double = [.whoosh, .swoosh, .riser, .downlifter].contains(preset) ? 0.12 : 0.025
            check(abs(peakAt - render.hitAt) <= tolerance, "\(name)'s loudest sample is within \(tolerance) s of its hit_at (peak at \(peakAt), hit_at \(render.hitAt))")
        }
        let last = max(abs(audio.left.last ?? 0), abs(audio.right.last ?? 0))
        check(last < 0.02, "\(name) fades out at the end (last sample \(last))")
    }
    check(SoundEffectSynth.render(SoundEffectParameters(preset: .sparkle)).hitKind == .onset, "sparkle's hit is its onset")
    check(SoundEffectSynth.render(SoundEffectParameters(preset: .glitch)).hitKind == .onset, "glitch's hit is its onset")
}

private func determinismChecks() {
    let a = SoundEffectSynth.render(SoundEffectParameters(preset: .whoosh, variation: 1)).audio
    let b = SoundEffectSynth.render(SoundEffectParameters(preset: .whoosh, variation: 1)).audio
    check(a.left == b.left && a.right == b.right, "the same parameters render the same samples")
    let c = SoundEffectSynth.render(SoundEffectParameters(preset: .whoosh, variation: 2)).audio
    check(a.left != c.left, "another variation is another take")
    let p1 = SoundEffectParameters(preset: .impact, duration: 1.6)
    let p2 = SoundEffectParameters(preset: .impact)
    checkEqual(p1.fileStem, p2.fileStem, "the default duration spelled out gives the same file")
    check(p1.fileStem.hasPrefix("impact-"), "the file name starts with the preset")
    check(SoundEffectParameters(preset: .impact, pitch: 1.5).fileStem != p2.fileStem, "another pitch is another file")
    check(SoundEffectParameters(preset: .impact, variation: 3).fileStem != p2.fileStem, "another variation is another file")
    check(SoundEffectParameters(preset: .impact, size: 0.7).fileStem == p2.fileStem, "the default size spelled out gives the same file")
}

/// 过零率当亮度的粗尺子：一段里每秒穿过零线几次。
private func brightness(_ audio: SFXBuffer, from: Double, to: Double) -> Double {
    let a = max(0, Int(from * Double(audio.count))), b = min(audio.count, Int(to * Double(audio.count)))
    guard b > a + 1 else { return 0 }
    var crossings = 0
    for i in (a + 1)..<b where ((audio.left[i - 1] + audio.right[i - 1]) < 0) != ((audio.left[i] + audio.right[i]) < 0) { crossings += 1 }
    return Double(crossings) / Double(b - a) * SFX.sampleRate / 2
}

private func shapeChecks() {
    let whoosh = SoundEffectSynth.render(SoundEffectParameters(preset: .whoosh)).audio
    let (start, middle, end) = (brightness(whoosh, from: 0, to: 0.15), brightness(whoosh, from: 0.3, to: 0.45), brightness(whoosh, from: 0.75, to: 0.9))
    check(middle > start * 1.15 && middle > end * 1.15, "whoosh brightens toward its hit and darkens after (\(start), \(middle), \(end))")
    let riser = SoundEffectSynth.render(SoundEffectParameters(preset: .riser)).audio
    check(brightness(riser, from: 0.45, to: 0.6) > brightness(riser, from: 0.05, to: 0.2) * 1.5, "riser gets brighter as it builds")
    let suction = SoundEffectSynth.render(SoundEffectParameters(preset: .suction)).audio
    check(brightness(suction, from: 0.8, to: 0.98) > brightness(suction, from: 0.2, to: 0.4) * 1.1, "suction rises toward its end")
    let down = SoundEffectSynth.render(SoundEffectParameters(preset: .downlifter)).audio
    check(brightness(down, from: 0.02, to: 0.15) > brightness(down, from: 0.45, to: 0.6) * 1.3, "downlifter darkens as it falls")
    let long = SoundEffectSynth.render(SoundEffectParameters(preset: .riser, duration: 2.4)).audio
    check(long.seconds > riser.seconds + 1, "duration makes a riser longer")
}

private func parameterChecks() {
    check(SoundEffectParameters(preset: .pop).problem == nil, "defaults are fine")
    check(SoundEffectParameters(preset: .pop, duration: 0.01).problem?.contains("duration") == true, "too short a duration is refused")
    check(SoundEffectParameters(preset: .pop, duration: 11).problem?.contains("duration") == true, "too long a duration is refused")
    check(SoundEffectParameters(preset: .pop, pitch: 5).problem?.contains("pitch") == true, "pitch 5 is refused")
    check(SoundEffectParameters(preset: .pop, brightness: 1.2).problem?.contains("brightness") == true, "brightness 1.2 is refused")
    check(SoundEffectParameters(preset: .pop, size: -0.1).problem?.contains("size") == true, "a negative size is refused")
    check(SoundEffectParameters(preset: .pop, variation: 1000).problem?.contains("variation") == true, "variation 1000 is refused")
}

private func soundEffectRequestChecks() {
    check((try? AISoundEffectRequest.parse(args(["file": .string("a.mp4")]), index: 0)) == nil, "no sound_effect key, no request")
    let request = try? AISoundEffectRequest.parse(
        args(["sound_effect": .object(["preset": .string("Whoosh"), "duration": .number(0.6), "variation": .number(2)]), "hit_at": .number(12)]), index: 0
    )
    checkEqual(request?.parameters.preset, .whoosh, "the preset is read case-insensitively")
    checkEqual(request?.parameters.duration, 0.6, "duration is read")
    checkEqual(request?.parameters.variation, 2, "variation is read")
    checkEqual(request?.hitAt, 12, "hit_at is read from the item")
    checkEqual(request?.volumeDB, AISoundEffectRequest.defaultVolumeDB, "volume defaults to -8 dB")
    let loud = try? AISoundEffectRequest.parse(args(["sound_effect": .object(["preset": .string("pop"), "volume_db": .number(-2)])]), index: 0)
    checkEqual(loud?.volumeDB, -2, "volume_db inside sound_effect is read")
    checkThrows("an unknown preset is refused") { _ = try AISoundEffectRequest.parse(args(["sound_effect": .object(["preset": .string("laser")])]), index: 0) }
    checkThrows("a missing preset is refused") { _ = try AISoundEffectRequest.parse(args(["sound_effect": .object(["duration": .number(1)])]), index: 0) }
    checkThrows("an out-of-range pitch is refused") { _ = try AISoundEffectRequest.parse(args(["sound_effect": .object(["preset": .string("pop"), "pitch": .number(9)])]), index: 0) }
    checkThrows("sound_effect must be an object") { _ = try AISoundEffectRequest.parse(args(["sound_effect": .string("whoosh")]), index: 0) }
    let ahead = AISoundEffectRequest.placement(hitAt: 5, renderedHit: 0.6)
    check(ahead.start == 4.4 && ahead.sourceIn == 0, "the start is hit_at minus the sound's own hit")
    let early = AISoundEffectRequest.placement(hitAt: 0.2, renderedHit: 0.6)
    check(early.start == 0 && abs(early.sourceIn - 0.4) < 1e-9, "a hit before the sound fits starts inside the sound instead")
}
