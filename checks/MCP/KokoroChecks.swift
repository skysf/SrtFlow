import Foundation
import SrtFlowKokoro
import SrtFlowMCPKit

// SrtFlow 自己的声音（本机的 Kokoro，方案第 48–51 条）：装了就用它、角色对应的音色、没装时的提示、点名的音色；一句旁白怎么切段
// （句末、逗号、正中间）、几段怎么拼（按字的时刻裁、在第一段安静处切掉尾巴杂音、词的开口和结束）；R2 清单的校验（路径不许跳出
// 模型目录）；按字 / 词切 token（中文一个字一个单位、数字换成读法、夹在中文里的英文词、英文按词、开头结尾的特殊 token）。
// 真的下载和推理要网络和模型，靠人工回归清单和测试版冒烟。编法见 scripts/check-mcp.sh。

func runKokoroChecks() {
    kokoroChoiceChecks()
    pieceChecks()
    paddingChecks()
    assemblyChecks()
    manifestChecks()
    unitChecks()
}

private func kokoroChoiceChecks() {
    let installed = ["af_heart", "af_bella", "am_fenrir", "bf_emma", "bm_george", "zf_xiaoyi", "zf_xiaoxiao", "zm_yunxi", "jf_alpha"]
    func engine(_ requested: String?, _ language: String) -> AIVoiceChoice.Engine? {
        (try? AIVoiceChoice.choose(requested, textLanguage: language, kokoroVoices: installed, installed: []))?.engine
    }
    checkEqual(engine("zh_male", "zh"), .kokoro(voice: "zm_yunxi", language: "zh"), "zh_male is the young male Kokoro voice")
    checkEqual(engine("en_male", "en"), .kokoro(voice: "am_fenrir", language: "en"), "en_male is am_fenrir, not am_michael")
    checkEqual(engine("en_male_british", "en"), .kokoro(voice: "bm_george", language: "en"), "the British roles")
    checkEqual(engine(nil, "zh"), .kokoro(voice: "zf_xiaoxiao", language: "zh"), "no voice given: the warm female voice of the text's language")
    checkEqual(engine(nil, "ja"), .kokoro(voice: "jf_alpha", language: "ja"), "other Kokoro languages have their own default voice")
    checkEqual(engine("bf_emma", "zh"), .kokoro(voice: "bf_emma", language: "zh"), "a named voice reads the text's language")
    checkThrows("a Kokoro voice that is not in the model is refused") {
        _ = try AIVoiceChoice.choose("zf_nobody", textLanguage: "zh", kokoroVoices: installed, installed: [])
    }
    do {
        _ = try AIVoiceChoice.choose("af_heart", textLanguage: "en", kokoroVoices: nil, installed: [])
        check(false, "a Kokoro voice before the download must be refused")
    } catch let error as AIToolError {
        check(error.message.contains("download_voices"), "and the AI is told to download them")
    } catch {
        check(false, "unexpected error \(error)")
    }
    let korean = AIVoiceChoice.Voice(identifier: "com.apple.voice.2.ko-KR.Yuna", name: "Yuna", language: "ko-KR", gender: .female, quality: 2)
    let fallback = try? AIVoiceChoice.choose(nil, textLanguage: "ko", kokoroVoices: installed, installed: [korean])
    checkEqual(fallback?.engine, .system(korean), "a language Kokoro cannot read uses the Mac's voice")
    check(fallback?.note == nil, "and does not pretend SrtFlow's voices would help")
    check(AIVoiceRole.isKokoroName("af_heart") && !AIVoiceRole.isKokoroName("zh_male") && !AIVoiceRole.isKokoroName("Tingting"),
          "Kokoro voice names are told apart from roles and Mac voices")
    checkEqual(AIVoiceRole.kokoroLanguage(ofVoice: "bm_george"), "en", "b… is British English")
}

private func pieceChecks() {
    let text = "学完这门课，你十分钟就能剪出短视频！已经有一万名学员。"
    let whole = KokoroVoicePieces.whole(text)
    checkEqual(whole.map { slice(text, $0.range) }, [text], "a line that fits is read whole (short sentences alone blow up)")
    checkEqual(whole.map(\.pauseAfter), [0], "no pause after the last piece")
    let halves = KokoroVoicePieces.split(whole[0], in: text)
    checkEqual(halves?.map { slice(text, $0.range) }, ["学完这门课，你十分钟就能剪出短视频！", "已经有一万名学员。"],
               "too long: cut at the sentence end nearest the middle, punctuation stays with its sentence")
    checkEqual(halves?.map(\.pauseAfter), [KokoroVoicePieces.sentencePause, 0], "a sentence pause between the halves")
    let clauses = KokoroVoicePieces.split(halves![0], in: text)
    checkEqual(clauses?.map { slice(text, $0.range) }, ["学完这门课，", "你十分钟就能剪出短视频！"], "no sentence end inside: cut at the comma")
    checkEqual(clauses?.map(\.pauseAfter), [KokoroVoicePieces.clausePause, KokoroVoicePieces.sentencePause],
               "the second half keeps the piece's own pause")
    let numbered = "One. Two. Keep your prompts short. Three. Build character sheets before you shoot."
    let middle = KokoroVoicePieces.split(KokoroVoicePieces.whole(numbered)[0], in: numbered)
    checkEqual(middle?.map { slice(numbered, $0.range) }, ["One. Two. Keep your prompts short.", "Three. Build character sheets before you shoot."],
               "several sentence ends: the one nearest the middle, so neither half is a lone word")
    let plain = "一二三四五六"
    let split = KokoroVoicePieces.split(.init(range: 0..<6, pauseAfter: 0), in: plain)
    checkEqual(split?.map { slice(plain, $0.range) }, ["一二三", "四五六"], "no punctuation: cut in the middle between two characters")
    check(KokoroVoicePieces.split(.init(range: 0..<1, pauseAfter: 0), in: "一") == nil, "one character cannot be cut")
    let english = "  Hello there.  "
    checkEqual(KokoroVoicePieces.whole(english).map { slice(english, $0.range) }, ["Hello there."], "spaces around the line are dropped")
    checkEqual(KokoroVoicePieces.whole("。。。").count, 0, "punctuation on its own is nothing to read")
    checkEqual(KokoroVoicePieces.split(KokoroVoicePieces.whole("好。。。")[0], in: "好。。。"), nil,
               "a cut that leaves only punctuation on one side is no cut")
}

/// 太短的一段后面垫一句再读（KokoroVoicePadding）：垫法的顺序、算不算炸、切口不越过垫的那句。
private func paddingChecks() {
    let short = KokoroVoicePadding.attempts(ownTokens: 6, language: "en")
    check(short.count == 2 && short.allSatisfy { $0 != nil }, "a short piece is always padded, first one tail then the other")
    let long = KokoroVoicePadding.attempts(ownTokens: 90, language: "en")
    check(long.count == 3 && long[0] == nil, "a long piece is read as it is first, padded only if it blows up")
    check(everyKokoroLanguageHasTails(), "every language Kokoro reads has two tails")
    check(KokoroVoicePadding.exploded([0.2, -3.0, 0.1][...]), "over twice full scale is blown up")
    check(KokoroVoicePadding.exploded([0.2, .nan][...]), "not-a-number is blown up")
    check(!KokoroVoicePadding.exploded([0.9, -1.2, 0.3][...]), "ordinary speech peaks are not")
    // 垫了一句：后一个字说完之后声音接着不停（垫的那句），切口不许越过它开口的地方。
    var voiced = [Float](repeating: 0, count: 400)
    for index in 30..<400 { voiced[index] = 0.3 }
    let padded = KokoroVoiceAssembly.speechEnd(voiced, nominal: 120, rate: 1000, limit: 150)
    checkEqual(padded, 150, "the cut stops where the padding starts to speak")
    checkEqual(KokoroVoiceAssembly.speechEnd(voiced, nominal: 120, rate: 1000), 320, "without padding it searches the full 0.2 s")
}

private func everyKokoroLanguageHasTails() -> Bool {
    AIVoiceRole.kokoroLanguages.allSatisfy { (KokoroVoicePadding.tails[$0] ?? []).count == 2 }
}

private func assemblyChecks() {
    // 一格 = 10 个采样、采样率 1000（好算）。开头 3 格，字 A 占 token 1..<3（4 格），字 B 占 token 4..<5（4 格），结尾 5 格。
    let rate = 1000
    var samples = [Float](repeating: 0, count: 300)
    for index in 30..<110 { samples[index] = 0.3 }          // 两个字的声音 0.03–0.11 秒
    for index in 190..<200 { samples[index] = 0.3 }         // 安静 0.08 秒之后冒出来的一截杂音
    let piece = KokoroVoiceAssembly.SpokenPiece(
        range: 0..<2, samples: samples, frames: [3, 2, 2, 1, 4, 4], units: [
            KokoroUnit(textRange: 0..<1, tokenRange: 1..<3), KokoroUnit(textRange: 1..<2, tokenRange: 4..<5)
        ], pauseAfter: 0.02
    )
    let (output, markers) = KokoroVoiceAssembly.assemble([piece, piece], sampleRate: rate, samplesPerFrame: 10)
    // from = 30 − 50（leadIn 0.05 秒）→ 0；时长上 B 在 120 结束，往后找安静：110 起安静，切在 110 + 10 = 120。
    checkEqual(output.count, (120 + 20) * 2, "each piece is cut at the first quiet after its last word, then its pause")
    check(output[110..<140].allSatisfy { abs($0) < 0.0001 }, "the burst after the quiet is not in the voiceover")
    checkEqual(markers.map(\.frame), [30, 80, 170, 220], "words start where their tokens start, the second piece after the first")
    checkEqual(markers.map(\.location), [0, 1, 0, 1], "and point at their characters")
    checkEqual(markers.first?.endFrame, 80, "a word ends at its own last token plus one frame")
    let lonely = KokoroVoiceAssembly.speechEnd([Float](repeating: 0.3, count: 300), nominal: 100, rate: 1000)
    checkEqual(lonely, 300, "no quiet within reach: cut at the search limit")
}

private func manifestChecks() {
    func manifest(_ path: String, sha: String = String(repeating: "a", count: 64)) -> Data {
        Data(#"{"name":"Kokoro","version":1,"files":[{"path":"\#(path)","size":3,"sha256":"\#(sha)"}]}"#.utf8)
    }
    check((try? KokoroVoiceManifest.decode(manifest("voices/af_heart.json"))) != nil, "a normal manifest is accepted")
    for bad in ["../evil", "/etc/passwd", "a/./b", "a/../../b", "a\\\\b", ""] {
        checkThrows("the path \(bad) must be refused") { _ = try KokoroVoiceManifest.decode(manifest(bad)) }
    }
    checkThrows("a short checksum is refused") { _ = try KokoroVoiceManifest.decode(manifest("x", sha: "abc")) }
    checkThrows("an empty list is refused") {
        _ = try KokoroVoiceManifest.decode(Data(#"{"name":"K","version":1,"files":[]}"#.utf8))
    }
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("srtflow-sha-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: file) }
    try? Data("abc".utf8).write(to: file)
    checkEqual(try? KokoroVoiceManifest.sha256(of: file), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
               "SHA-256 of a file")
}

private func unitChecks() {
    // 假词表：常见的 IPA 符号、字母、标点、空格都给一个 id（真词表在下载的模型里）。
    let symbols = Array(" abcdefghijklmnopqrstuvwxyzɐɑɒæɓʙβɔɕçɗɖðʤəɘɚɛɜɝɞɟʄɡɠɢʛɦɧħɥʜɨɪʝɭɬɫɮʟɱɯɰŋɳɲɴøɵɸθœɶʘɹɺɾɻʀʁɽʂʃʈʧʉʊʋⱱʌɣɤʍχʎʏʑʐʒʔʡʕʢǀǁǂǃˈˌːˑʼʴʰʱʲʷˠˤ˞↓↑→↗↘ᵻ,.!?;:-'\"()")
    var vocab: [String: Int] = [:]
    for (index, symbol) in symbols.enumerated() { vocab[String(symbol)] = index + 3 }
    let phonemizer = KokoroPhonemizer(vocab: vocab)
    let text = "学完课，有10,000名学员，用SrtFlow剪"
    let tokens = KokoroUnits.tokens(for: text, language: "zh", phonemizer: phonemizer)
    checkEqual(tokens.units.map { slice(text, $0.textRange) }, ["学", "完", "课", "有", "10,000", "名", "学", "员", "用", "SrtFlow", "剪"],
               "Chinese: one unit per character, a number as one unit, an English word inside as one unit")
    checkEqual(tokens.ids.first, phonemizer.bosId, "starts with the start token")
    checkEqual(tokens.ids.last, phonemizer.eosId, "ends with the end token")
    check(tokens.units.allSatisfy { !$0.tokenRange.isEmpty }, "every unit has tokens (the number is read, not skipped)")
    check(zip(tokens.units, tokens.units.dropFirst()).allSatisfy { $0.tokenRange.upperBound <= $1.tokenRange.lowerBound },
          "units follow each other without overlapping")
    let english = "Don't miss 10 videos."
    let words = KokoroUnits.tokens(for: english, language: "en", phonemizer: phonemizer)
    checkEqual(words.units.map { slice(english, $0.textRange) }, ["Don't", "miss", "10", "videos"], "English: one unit per word")
}

private func slice(_ text: String, _ range: Range<Int>) -> String {
    String(decoding: Array(text.utf16)[range], as: UTF16.self)
}
