import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// add_voiceover 的 fal 那一档（方案第 42 条最上面一档、第 52 条克隆）的纯值部分：
// 挑音色（fal 可用时没点名 / 点名角色 / 点名 ElevenLabs 的预制音色走 fal，点名 Kokoro 的或这台 Mac 的仍照点名；
// fal 不可用时和以前一模一样）、角色表和 `AIVoiceRole` 一一对上、fal 报的词时间换成字幕认的词（写法照识别器的、字数对不上不要、
// 中日韩不加空格）、克隆用的参考音频包成 WAV。真去调 fal 靠 scripts/check-fal.sh 的假 URLSession 和人工清单。

func runFalVoiceChecks() {
    let tingting = AIVoiceChoice.Voice(identifier: "com.apple.voice.1.zh-CN.Tingting", name: "Tingting", language: "zh-CN", gender: .female, quality: 1)
    let daniel = AIVoiceChoice.Voice(identifier: "com.apple.voice.1.en-GB.Daniel", name: "Daniel", language: "en-GB", gender: .male, quality: 1)
    let installed = [tingting, daniel]

    func chosen(_ requested: String?, language: String, fal: Bool, kokoro: [String]? = nil) -> AIVoiceChoice.Engine? {
        (try? AIVoiceChoice.choose(requested, textLanguage: language, kokoroVoices: kokoro, installed: installed, falAvailable: fal))?.engine
    }

    // fal 可用：没点名按文字的语言取温和的角色、点名角色换成对应音色、点名 ElevenLabs 的音色照用（大小写不敏感）
    checkEqual(chosen(nil, language: "en", fal: true), .fal(voice: "Rachel"), "no voice named, English: the warm English role's voice")
    checkEqual(chosen(nil, language: "zh", fal: true), .fal(voice: "Sarah"), "no voice named, Chinese: the warm Chinese role's voice")
    checkEqual(chosen(nil, language: "ja", fal: true), .fal(voice: "Rachel"), "a language without a role: the default voice")
    checkEqual(chosen("en_male", language: "en", fal: true), .fal(voice: "Brian"), "a role becomes its fal.ai voice")
    checkEqual(chosen("ZH_MALE", language: "zh", fal: true), .fal(voice: "Eric"), "roles are case-insensitive")
    checkEqual(chosen("brian", language: "en", fal: true), .fal(voice: "Brian"), "an ElevenLabs premade voice is used as named, in its own spelling")
    // 点名 Kokoro 的、这台 Mac 的：仍照点名（fal 不抢）
    checkEqual(chosen("af_heart", language: "en", fal: true, kokoro: ["af_heart"]), .kokoro(voice: "af_heart", language: "en"), "a named SrtFlow voice is still used")
    if case .system(let voice)? = chosen("Tingting", language: "zh", fal: true) {
        checkEqual(voice.name, "Tingting", "a named Mac voice is still used")
    } else {
        check(false, "a named Mac voice should stay a Mac voice")
    }
    // 名字撞了（Daniel 既是 ElevenLabs 的音色也是 Mac 的英式男声）：fal 可用时按 fal —— fal > 本机 > macOS
    checkEqual(chosen("Daniel", language: "en", fal: true), .fal(voice: "Daniel"), "a name both fal.ai and this Mac have goes to fal.ai when it is available")
    // fal 不可用：和以前一模一样
    if case .system(let voice)? = chosen("Daniel", language: "en", fal: false) {
        checkEqual(voice.name, "Daniel", "without fal.ai, Daniel is the Mac's voice")
    } else {
        check(false, "without fal.ai a name is looked up on this Mac")
    }
    checkEqual(chosen("en_male", language: "en", fal: false, kokoro: ["am_fenrir"]), .kokoro(voice: "am_fenrir", language: "en"), "without fal.ai a role uses SrtFlow's voice when it is downloaded")
    let plain = try? AIVoiceChoice.choose(nil, textLanguage: "zh", kokoroVoices: nil, installed: installed)
    checkEqual(plain?.name, "Tingting", "the default parameter keeps the old behaviour")
    let falChoice = try? AIVoiceChoice.choose("en_male", textLanguage: "en", kokoroVoices: nil, installed: installed, falAvailable: true)
    checkEqual(falChoice?.name, "Brian", "the choice's name is the voice")
    checkEqual(falChoice?.qualityName, "fal.ai voice", "and its quality says where it comes from")

    // 角色表和 AIVoiceRole 对账：每个角色都有音色、没有多出来的、音色都是 ElevenLabs 的预制音色
    checkEqual(Set(AIFalVoices.byRole.keys), Set(AIVoiceRole.all.map(\.name)), "every voice role has a fal.ai voice, and no extra")
    check(AIFalVoices.byRole.values.allSatisfy { AIFalVoices.premade.contains($0) }, "every mapped voice is a premade voice fal.ai lists")
    checkEqual(AIFalVoices.premade.count, Set(AIFalVoices.premade).count, "no voice is listed twice")
    check(AIFalVoices.named("nobody") == nil && AIFalVoices.named("") == nil, "an unknown name is not a premade voice")
    checkEqual(AIFalVoices.named(" rachel "), "Rachel", "spaces around a name are ignored")

    // ---- 词时间
    let hello = [FalWordTime(text: "Hello", start: 0.1, end: 0.5), FalWordTime(text: "world.", start: 0.6, end: 1.0)]
    let words = AIFalVoices.timedWords(hello, text: "Hello world.", duration: 1.2)
    checkEqual(words.map(\.text), ["Hello", " world."], "English words keep the recogniser's spelling: a leading space after the first")
    checkEqual(words.map(\.start), [0.1, 0.6], "starts are kept")
    checkEqual(words.map(\.end), [0.5, 1.0], "ends are kept")
    let clamped = AIFalVoices.timedWords([FalWordTime(text: "a", start: 0.4, end: 9), FalWordTime(text: "b", start: 5, end: 6)], text: "a b", duration: 1)
    checkEqual(clamped.map(\.end), [1.0, 1.02], "an end past the audio is cut to it, and a word is at least 20 ms")
    check(clamped[1].start == 1.0, "a start past the audio is cut to it")
    let chinese = AIFalVoices.timedWords(
        [FalWordTime(text: "你", start: 0, end: 0.2), FalWordTime(text: "好", start: 0.2, end: 0.4)], text: "你好", duration: 0.5
    )
    checkEqual(chinese.map(\.text), ["你", "好"], "Chinese characters get no spaces between them")
    check(AIFalVoices.timedWords(hello, text: "A completely different and much longer sentence.", duration: 1.2).isEmpty, "words that do not match the text are not trusted")
    check(AIFalVoices.timedWords(hello, text: "Hi", duration: 1.2).isEmpty, "words much longer than the text are not trusted either")
    check(AIFalVoices.timedWords([], text: "Hello", duration: 1).isEmpty && AIFalVoices.timedWords(hello, text: "Hello world.", duration: 0).isEmpty, "nothing to convert")
    check(AIFalVoices.timedWords(hello, text: "...", duration: 1).isEmpty, "a text without letters has nothing to match")

    // ---- 参考音频的 WAV
    let samples: [Int16] = [0, 1, -1, 32767, -32768, 1234]
    let wav = AIFalVoices.wavData(samples: samples, sampleRate: 16_000)
    checkEqual(wav.count, 44 + samples.count * 2, "a 44-byte header and the samples")
    checkEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF", "RIFF")
    checkEqual(String(decoding: wav[8..<16], as: UTF8.self), "WAVEfmt ", "WAVE fmt")
    checkEqual(String(decoding: wav[36..<40], as: UTF8.self), "data", "data chunk")
    func le32(_ offset: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(wav[wav.startIndex + offset + $1]) << (8 * UInt32($1)) } }
    func le16(_ offset: Int) -> UInt16 { UInt16(wav[wav.startIndex + offset]) | UInt16(wav[wav.startIndex + offset + 1]) << 8 }
    checkEqual(le32(4), UInt32(36 + samples.count * 2), "the RIFF size")
    checkEqual(le16(20), 1, "PCM")
    checkEqual(le16(22), 1, "mono")
    checkEqual(le32(24), 16_000, "the sample rate")
    checkEqual(le32(28), 32_000, "bytes per second")
    checkEqual(le16(34), 16, "16 bits")
    checkEqual(le32(40), UInt32(samples.count * 2), "the data size")
    let back = (0..<samples.count).map { Int16(bitPattern: le16(44 + $0 * 2)) }
    checkEqual(back, samples, "the samples come back unchanged, including the extremes")
    checkEqual(AIFalVoices.wavData(samples: [], sampleRate: 16_000).count, 44, "an empty sample is just a header")
}
