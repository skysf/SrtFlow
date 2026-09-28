import Foundation

// MARK: - 按字 / 词切 token（SrtFlow 自己写的，不是从 speech-swift 搬来的）
//
// 管什么：一段文字 → 模型要的 token，外加每个「单位」（中文一个字、英文等拼音文字一个词、一串数字）在原文里的位置
// 和它占了哪几个 token。模型给每个 token 一个时长，按单位加起来就知道每个字、每个词在第几秒开口 —— 字幕和逐词高亮
// 靠它对上声音（2026-09-28 实测：时长一格正好 600 个采样）。原来的 `KokoroPhonemizer.tokenize` 只给整串 token，
// 分不出哪几个是哪个字的。
// 读音全部照原来那几个注音器（同一个口径），只多做三件事：
// - **数字换成读法**：原来的中文注音遇到阿拉伯数字直接跳过（「10,000」一个音都不出），英文也没处理；这里按语言
//   念出来（10,000 → 一万 / ten thousand，50% → 百分之五十），单位覆盖原文里那串数字。
// - **中文整段转拼音**：逐字转时多音字只能读最常见的音，整段转能读对一部分（「重庆」chóng qìng），对不齐字数才退回逐字。
// - **夹在中文里的英文词**按英语读，原来是一个字母一个字母往里塞。
// 日语没有按词切：整段一个单位（字幕按整句对齐）。
// 不管什么：切成 5 秒以内的几段、裁尾巴、拼起来（App 那一层 KokoroVoiceAssembly）。

/// 一个单位在原文里的位置（UTF-16 偏移）和它占的 token（`KokoroTokens.ids` 的下标，第 0 个是开头那个 token）。
public struct KokoroUnit: Equatable, Sendable {
    public var textRange: Range<Int>
    public var tokenRange: Range<Int>

    public init(textRange: Range<Int>, tokenRange: Range<Int>) {
        self.textRange = textRange
        self.tokenRange = tokenRange
    }
}

public struct KokoroTokens: Equatable, Sendable {
    /// 开头、结尾各有一个特殊 token。
    public var ids: [Int]
    public var units: [KokoroUnit]
}

public enum KokoroUnits {
    public static func tokens(for text: String, language: String, phonemizer: KokoroPhonemizer) -> KokoroTokens {
        var builder = KokoroTokenBuilder(phonemizer: phonemizer)
        switch language {
        case "zh": chinese(text, into: &builder, phonemizer: phonemizer)
        case "ja":
            let ipa = phonemizer.japanesePhonemes(KokoroNumberReading.replacingDigits(in: text, language: "ja"))
            builder.unit(ipa, textRange: 0..<text.utf16.count)
        default: words(text, language: language, into: &builder, phonemizer: phonemizer)
        }
        return builder.finish()
    }

    // MARK: 中文

    private static func chinese(_ text: String, into builder: inout KokoroTokenBuilder, phonemizer: KokoroPhonemizer) {
        let pieces = KokoroTextSegment.split(text, isWordCharacter: { $0.isHan })
        for piece in pieces {
            switch piece.kind {
            case .word:
                // 整段汉字一起转拼音（能读对一部分多音字），对不上字数就逐字。
                let characters = Array(piece.text)
                var syllables = KokoroPinyin.syllables(piece.text)
                if syllables.count != characters.count { syllables = characters.map { KokoroPinyin.syllables(String($0)).first ?? "" } }
                var offset = piece.range.lowerBound
                for (character, syllable) in zip(characters, syllables) {
                    let length = String(character).utf16.count
                    if !syllable.isEmpty {
                        builder.space()
                        builder.unit(ChinesePhonemizer.pinyinToIPA(syllable), textRange: offset..<(offset + length))
                    }
                    offset += length
                }
            case .number:
                let reading = KokoroNumberReading.words(for: piece.text, language: "zh")
                let ipa = KokoroPinyin.syllables(reading).map(ChinesePhonemizer.pinyinToIPA).joined(separator: " ")
                builder.space()
                builder.unit(ipa, textRange: piece.range)
            case .latin:
                builder.space()
                builder.unit(phonemizer.english.resolveWord(piece.text, pos: nil) ?? piece.text.lowercased(), textRange: piece.range)
            case .punctuation:
                if let mark = piece.text.first.flatMap({ ChinesePhonemizer.punctuationMap[$0] ?? asciiPunctuation($0) }) {
                    builder.separator(mark)
                }
            case .space:
                builder.markBreak()
            }
        }
    }

    // MARK: 英语和其余拼音文字（法、西、葡、意、印地）

    private static func words(_ text: String, language: String, into builder: inout KokoroTokenBuilder, phonemizer: KokoroPhonemizer) {
        let tags = language == "en" ? phonemizer.english.tagPOS(text) : [:]
        for piece in KokoroTextSegment.split(text, isWordCharacter: { $0.isLetter || $0 == "'" || $0 == "’" }) {
            switch piece.kind {
            case .word, .latin:
                builder.space()
                builder.unit(wordPhonemes(piece.text, language: language, tag: tags[piece.text.lowercased()],
                                          phonemizer: phonemizer), textRange: piece.range)
            case .number:
                let spoken = KokoroNumberReading.words(for: piece.text, language: language)
                let ipa = spoken.split(whereSeparator: { $0 == " " || $0 == "-" })
                    .map { wordPhonemes(String($0), language: language, tag: nil, phonemizer: phonemizer) }
                    .joined(separator: " ")
                builder.space()
                builder.unit(ipa, textRange: piece.range)
            case .punctuation:
                if let mark = piece.text.first.flatMap({ asciiPunctuation($0) ?? ChinesePhonemizer.punctuationMap[$0] }) {
                    builder.separator(mark)
                }
            case .space:
                builder.markBreak()
            }
        }
    }

    private static func wordPhonemes(_ word: String, language: String, tag: String?, phonemizer: KokoroPhonemizer) -> String {
        guard language == "en" else { return phonemizer.dictionaryWordPhonemes(word, language: language) }
        // 缩写原来是整句先展开（don't → do not）再查；这里一个词一个词地展开，单位仍然是原文里那个词。
        let lower = word.lowercased().replacingOccurrences(of: "’", with: "'")
        if let expansion = contractions[lower] {
            return expansion.split(separator: " ").map { phonemizer.english.resolveWord(String($0), pos: nil) ?? String($0) }
                .joined(separator: " ")
        }
        return phonemizer.english.resolveWord(word, pos: tag) ?? lower
    }

    /// 和 `KokoroEnglish.normalizeText` 同一张表。
    private static let contractions: [String: String] = [
        "can't": "can not", "won't": "will not", "don't": "do not", "doesn't": "does not", "didn't": "did not",
        "isn't": "is not", "aren't": "are not", "wasn't": "was not", "weren't": "were not", "couldn't": "could not",
        "wouldn't": "would not", "shouldn't": "should not", "haven't": "have not", "hasn't": "has not",
        "hadn't": "had not", "i'm": "i am", "i've": "i have", "i'll": "i will", "i'd": "i would", "you're": "you are",
        "you've": "you have", "you'll": "you will", "he's": "he is", "she's": "she is", "it's": "it is",
        "we're": "we are", "we've": "we have", "we'll": "we will", "they're": "they are", "they've": "they have",
        "they'll": "they will", "that's": "that is", "there's": "there is", "let's": "let us"
    ]

    private static func asciiPunctuation(_ character: Character) -> String? {
        switch character {
        case ",", ".", "!", "?", ";", ":": return String(character)
        case "-", "—": return "-"
        default: return nil
        }
    }
}

// MARK: - 拼 token

/// 一边往 token 串后面接、一边记每个单位占哪几个 token。
struct KokoroTokenBuilder {
    private let phonemizer: KokoroPhonemizer
    private(set) var ids: [Int]
    private(set) var units: [KokoroUnit] = []
    /// 上一个接进去的是单位（下一个单位前要隔一个空格，和原来的注音器一样）。
    private var lastWasUnit = false

    init(phonemizer: KokoroPhonemizer) {
        self.phonemizer = phonemizer
        ids = [phonemizer.bosId]
    }

    mutating func space() {
        if lastWasUnit { ids += phonemizer.ids(forIPA: " ") }
    }

    mutating func markBreak() { lastWasUnit = false }

    mutating func separator(_ ipa: String) {
        ids += phonemizer.ids(forIPA: ipa)
        lastWasUnit = false
    }

    mutating func unit(_ ipa: String, textRange: Range<Int>) {
        let tokens = phonemizer.ids(forIPA: ipa)
        guard !tokens.isEmpty else { return }
        let start = ids.count
        ids += tokens
        units.append(KokoroUnit(textRange: textRange, tokenRange: start..<ids.count))
        lastWasUnit = true
    }

    func finish() -> KokoroTokens {
        KokoroTokens(ids: ids + [phonemizer.eosId], units: units)
    }
}

