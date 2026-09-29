// SrtFlowKokoro —— 从 speech-swift（https://github.com/soniqo/speech-swift，Apache License 2.0，Copyright 2025 Ivan Digital）
// 的 KokoroTTS 模块搬过来的代码，为 SrtFlow 改过。授权全文与署名见 Sources/SrtFlow/Resources/THIRD-PARTY-NOTICES.md（随 App 分发）。
// 这个文件：多语言的总入口 —— 按语言把文字交给对应的注音（英、中、日、法、西、葡、意、印地），再按词表换成 token。
// 改动：英语那一套拆成 KokoroEnglish / KokoroBartG2P（原文件 704 行，超过仓库 600 行的上限）；法、葡、印地的词典从
// 模型目录读（`loadDictionaries`）；加了 `ids(forIPA:)`，给按词切的 KokoroUnits 用。其余原样。

import CoreML
import Foundation

/// Multilingual phonemizer for Kokoro TTS.
///
/// English: dictionary lookup → suffix stemming → CoreML BART G2P fallback.
/// Chinese/Japanese/Italian: dedicated language-specific phonemizers.
/// French/Spanish/Portuguese/Hindi: pronunciation dictionary + rule-based G2P.
public final class KokoroPhonemizer {

    /// IPA symbol → token ID mapping (from vocab_index.json).
    private let vocab: [String: Int]

    /// Reverse mapping for debugging.
    private let idToToken: [Int: String]

    /// Pad token ID (0).
    public let padId: Int = 0

    /// Start-of-sequence token ID.
    public let bosId: Int = 1

    /// End-of-sequence token ID.
    public let eosId: Int = 2

    /// Initialize with a vocabulary mapping.
    public init(vocab: [String: Int]) {
        self.vocab = vocab
        self.idToToken = Dictionary(uniqueKeysWithValues: vocab.map { ($1, $0) })
    }

    /// Load vocabulary from vocab_index.json.
    ///
    /// Format: `{"vocab": {"symbol": id, ...}, "metadata": {...}}`
    public static func loadVocab(from url: URL) throws -> KokoroPhonemizer {
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data)

        // Support both flat {sym: id} and nested {vocab: {sym: id}} formats
        let vocab: [String: Int]
        if let nested = json as? [String: Any], let v = nested["vocab"] as? [String: Int] {
            vocab = v
        } else if let flat = json as? [String: Int] {
            vocab = flat
        } else {
            throw KokoroError.modelMissing("vocab_index.json has an unknown format")
        }
        return KokoroPhonemizer(vocab: vocab)
    }

    /// 英语那一套（词典、词性、去词尾、BART）。
    let english = KokoroEnglish()

    /// 法、葡、印地的大词典（和模型放在一起，`loadDictionaries` 读进来）。
    private var french: [String: String] = [:]
    private var portuguese: [String: String] = [:]
    private var hindi: [String: String] = [:]

    /// 读模型目录里的词典：英语的金 / 银两份，法、葡、印地各一份。
    public func loadDictionaries(from directory: URL) throws {
        try english.loadDictionaries(from: directory)
        french = PronunciationDicts.loadJSON("dict_fr", from: directory)
        portuguese = PronunciationDicts.loadJSON("dict_pt", from: directory)
        hindi = PronunciationDicts.loadJSON("dict_hi", from: directory)
    }

    /// 英语词典查不到的词用的 BART 模型。
    public func loadG2PModels(encoderURL: URL, decoderURL: URL, vocabURL: URL) throws {
        try english.g2p.load(encoderURL: encoderURL, decoderURL: decoderURL, vocabURL: vocabURL)
    }

    // MARK: - Multilingual Phonemizers

    private lazy var chinesePhonemizer = ChinesePhonemizer()
    private lazy var japanesePhonemizer = JapanesePhonemizer()
    private lazy var hindiPhonemizer = HindiPhonemizer()
    private lazy var frenchPhonemizer = LatinPhonemizer(language: .french)
    private lazy var spanishPhonemizer = LatinPhonemizer(language: .spanish)
    private lazy var portuguesePhonemizer = LatinPhonemizer(language: .portuguese)
    private lazy var italianPhonemizer = LatinPhonemizer(language: .italian)

    // MARK: - Tokenization

    /// Convert text to phoneme token IDs using language-appropriate phonemizer.
    public func tokenize(_ text: String, maxLength: Int = 510, language: String = "en") -> [Int] {
        let phonemes: String
        switch language {
        case "zh", "cmn", "chinese", "mandarin":
            phonemes = chinesePhonemizer.phonemize(text)
        case "ja", "japanese":
            phonemes = japanesePhonemizer.phonemize(text)
        case "it", "italian":
            phonemes = phonemizeWithDict(text, dict: PronunciationDicts.it, fallback: italianPhonemizer)
        case "fr", "french":
            phonemes = phonemizeWithDict(text, dict: french, fallback: frenchPhonemizer)
        case "es", "spanish":
            phonemes = phonemizeWithDict(text, dict: PronunciationDicts.es, fallback: spanishPhonemizer)
        case "pt", "portuguese":
            phonemes = phonemizeWithDict(text, dict: portuguese, fallback: portuguesePhonemizer)
        case "hi", "hindi":
            phonemes = phonemizeWithDict(text, dict: hindi, fallback: hindiPhonemizer)
        default:
            phonemes = english.textToPhonemes(text)
        }

        var ids = [bosId]

        // Tokenize IPA string character by character
        for char in phonemes {
            let s = String(char)
            if let id = vocab[s] {
                ids.append(id)
            }
            // Unknown chars silently dropped
        }

        ids.append(eosId)

        if ids.count > maxLength {
            ids = Array(ids.prefix(maxLength - 1)) + [eosId]
        }

        return ids
    }

    /// Pad token IDs to a fixed length.
    public func pad(_ ids: [Int], to length: Int) -> [Int] {
        if ids.count >= length { return Array(ids.prefix(length)) }
        return ids + [Int](repeating: padId, count: length - ids.count)
    }

    /// 一段 IPA 换成 token（词表里没有的符号丢掉，和 `tokenize` 同一个口径）。
    func ids(forIPA phonemes: String) -> [Int] {
        phonemes.compactMap { vocab[String($0)] }
    }

    /// 一个词的读音（法、西、葡、意、印地：先查词典，查不到按拼写规则；和 `phonemizeWithDict` 同一个口径）。
    /// KokoroUnits 一个词一个词地问，才知道每个词占哪几个 token。
    func dictionaryWordPhonemes(_ word: String, language: String) -> String {
        let clean = language == "hi" ? word : word.lowercased()
        switch language {
        case "it": return PronunciationDicts.it[clean] ?? italianPhonemizer.phonemizeWord(clean)
        case "fr": return french[clean] ?? frenchPhonemizer.phonemizeWord(clean)
        case "es": return PronunciationDicts.es[clean] ?? spanishPhonemizer.phonemizeWord(clean)
        case "pt": return portuguese[clean] ?? portuguesePhonemizer.phonemizeWord(clean)
        case "hi": return hindi[clean] ?? hindiPhonemizer.phonemizeWord(clean)
        default: return english.resolveWord(clean, pos: nil) ?? clean
        }
    }

    /// 整段日语的读音（日语没有按词切，整段一个单位）。
    func japanesePhonemes(_ text: String) -> String {
        japanesePhonemizer.phonemize(text)
    }

    // MARK: - Dictionary-Based Phonemization

    /// Phonemize text using dictionary lookup with rule-based fallback.
    /// Words found in the dictionary use pre-computed IPA with correct stress placement.
    /// Unknown words fall back to the language-specific rule-based G2P.
    private func phonemizeWithDict(_ text: String, dict: [String: String], fallback: LatinPhonemizer) -> String {
        var result = ""
        var lastWasWord = false

        for ch in text {
            if ch.isWhitespace {
                if lastWasWord { result += " " }
                lastWasWord = false
            } else if ch.isPunctuation || ch.isSymbol {
                if let mapped = english.punctuationToPhoneme(String(ch)) {
                    result += mapped
                }
                lastWasWord = false
            } else if ch.isLetter || ch == "'" || ch == "'" {
                // Accumulate word characters — handled below
                continue
            }
        }

        // Split into words and look up each one
        let words = text.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        result = ""
        lastWasWord = false

        for word in words {
            // Strip trailing punctuation
            var clean = word.lowercased()
            var trailing = ""
            while let last = clean.last, last.isPunctuation || last.isSymbol {
                trailing = String(last) + trailing
                clean = String(clean.dropLast())
            }
            var leading = ""
            while let first = clean.first, first.isPunctuation || first.isSymbol {
                leading += String(first)
                clean = String(clean.dropFirst())
            }

            // Leading punctuation
            for ch in leading {
                if let mapped = mapPunctuation(ch) { result += mapped }
            }

            if !clean.isEmpty {
                if lastWasWord { result += " " }
                // Dictionary lookup, then fallback
                if let ipa = dict[clean] {
                    result += ipa
                } else {
                    result += fallback.phonemizeWord(clean)
                }
                lastWasWord = true
            }

            // Trailing punctuation
            for ch in trailing {
                if let mapped = mapPunctuation(ch) { result += mapped }
                lastWasWord = false
            }
        }

        return result
    }

    /// Dictionary-based phonemization for Hindi (uses HindiPhonemizer as fallback).
    private func phonemizeWithDict(_ text: String, dict: [String: String], fallback: HindiPhonemizer) -> String {
        let words = text.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        var result = ""
        var lastWasWord = false

        for word in words {
            var clean = word
            var trailing = ""
            while let last = clean.last, last.isPunctuation || last.isSymbol {
                trailing = String(last) + trailing
                clean = String(clean.dropLast())
            }

            if !clean.isEmpty {
                if lastWasWord { result += " " }
                if let ipa = dict[clean] {
                    result += ipa
                } else {
                    result += fallback.phonemizeWord(clean)
                }
                lastWasWord = true
            }

            for ch in trailing {
                if let mapped = mapPunctuation(ch) { result += mapped }
                lastWasWord = false
            }
        }

        return result
    }

    private func mapPunctuation(_ ch: Character) -> String? {
        switch ch {
        case ",", "，": return ","
        case ".", "。": return "."
        case "!", "！": return "!"
        case "?", "？": return "?"
        case ";", "；": return ";"
        case ":": return ":"
        case "।": return "."
        default: return nil
        }
    }
}
