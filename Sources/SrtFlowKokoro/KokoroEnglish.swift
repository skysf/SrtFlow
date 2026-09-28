// SrtFlowKokoro —— 从 speech-swift（https://github.com/soniqo/speech-swift，Apache License 2.0，Copyright 2025 Ivan Digital）
// 的 KokoroTTS 模块搬过来的代码，为 SrtFlow 改过。授权全文与署名见 Sources/SrtFlow/Resources/THIRD-PARTY-NOTICES.md（随 App 分发）。
// 这个文件：英语的读音 —— 金 / 银两份词典、词性区分同形异音词、去词尾再查、最后交给 BART 猜（KokoroBartG2P）。
// 改动：从 KokoroPhonemizer 里拆出来成了自己的类型（原文件超过 600 行）；`resolveWord` 等几个函数对模块内公开，
// 按词切的 KokoroUnits 要一个词一个词地问读音。函数体原样。

import Foundation
import NaturalLanguage

final class KokoroEnglish {
    /// Gold dictionary (high-confidence entries).
    private var goldDict: [String: DictEntry] = [:]

    /// Silver dictionary (lower-confidence entries).
    private var silverDict: [String: DictEntry] = [:]

    /// NL tagger for POS tagging (heteronym resolution).
    private let tagger = NLTagger(tagSchemes: [.lexicalClass])

    /// 词典里查不到的词交给它。
    let g2p = KokoroBartG2P()

    /// Dictionary entry: either a simple phoneme string or POS-tagged heteronym.
    enum DictEntry {
        case simple(String)
        case heteronym([String: String])
    }

    /// Load pronunciation dictionaries from directory.
    func loadDictionaries(from directory: URL, british: Bool = false) throws {
        let prefix = british ? "gb" : "us"
        let goldURL = directory.appendingPathComponent("\(prefix)_gold.json")
        let silverURL = directory.appendingPathComponent("\(prefix)_silver.json")

        if FileManager.default.fileExists(atPath: goldURL.path) {
            goldDict = try parseDictionary(from: goldURL)
            growDictionary(&goldDict)
        }
        if FileManager.default.fileExists(atPath: silverURL.path) {
            silverDict = try parseDictionary(from: silverURL)
            growDictionary(&silverDict)
        }
    }

    /// Injects custom `word -> IPA` pronunciations into the gold dictionary.
    ///
    /// `resolveWord` consults `goldDict` before the silver dict, stemming, and the
    /// neural `bartG2P` fallback, so entries added here take precedence over all
    /// three. Proper nouns absent from the shipped dictionaries are otherwise
    /// guessed from *English* spelling rules and come out badly wrong for
    /// non-Anglo names. The function words in `specialCase` — the, a, an, to, of,
    /// i — resolve earlier still and cannot be overridden this way.
    ///
    /// Keys are matched lowercased and must be single words: text is split on
    /// whitespace and punctuation before resolution, so a key containing a space,
    /// hyphen, or apostrophe is never looked up. Register the parts separately.
    ///
    /// IPA must use symbols present in the model vocabulary — unknown characters
    /// are silently dropped by `tokenize`.
    ///
    /// English only. `tokenize` routes zh, ja, it, fr, es, pt, and hi to their
    /// own phonemizers, none of which consult `goldDict`, so entries added here
    /// are a no-op for those languages.
    ///
    /// Not synchronized: `tokenize` reads `goldDict` without a lock, so register
    /// entries before synthesis starts running concurrently.
    ///
    /// Call this after `loadDictionaries(from:)`, which replaces the gold
    /// dictionary wholesale and would discard entries added before it.
    func addPronunciations(_ entries: [String: String]) {
        for (word, ipa) in entries {
            goldDict[word.lowercased()] = .simple(ipa)
        }
    }

    // MARK: - Text-to-Phoneme Pipeline

    func textToPhonemes(_ text: String) -> String {
        let normalized = normalizeText(text)
        let words = splitWords(normalized)
        let posTagged = tagPOS(normalized)

        var result = ""
        for word in words {
            if word.allSatisfy({ $0.isWhitespace }) {
                result += " "
                continue
            }
            if word.allSatisfy({ $0.isPunctuation || $0.isSymbol }) {
                if let mapped = punctuationToPhoneme(word) {
                    result += mapped
                }
                continue
            }
            let pos = posTagged[word.lowercased()]
            if let phonemes = resolveWord(word, pos: pos) {
                result += phonemes
            }
        }
        return result
    }

    // MARK: - Word Resolution

    func resolveWord(_ word: String, pos: String?) -> String? {
        let lower = word.lowercased()
        if let special = specialCase(lower, pos: pos) { return special }
        if let entry = lookupDict(lower, pos: pos) { return entry }
        if let stemmed = stemAndLookup(lower) { return stemmed }
        if let g2p = g2p.phonemize(lower) { return g2p }
        return lower
    }

    private func lookupDict(_ word: String, pos: String?) -> String? {
        if let entry = goldDict[word] { return resolveEntry(entry, pos: pos) }
        if let entry = silverDict[word] { return resolveEntry(entry, pos: pos) }
        return nil
    }

    private func resolveEntry(_ entry: DictEntry, pos: String?) -> String {
        switch entry {
        case .simple(let phonemes):
            return phonemes
        case .heteronym(let posMap):
            if let pos, let phonemes = posMap[pos] { return phonemes }
            return posMap["DEFAULT"] ?? posMap.values.first ?? ""
        }
    }

    // MARK: - Special Cases

    private func specialCase(_ word: String, pos: String?) -> String? {
        switch word {
        case "the": return "ðə"
        case "a":
            if pos == "Determiner" { return "ɐ" }
            return "eɪ"
        case "an": return "ən"
        case "to": return "tʊ"
        case "of": return "ʌv"
        case "i": return "aɪ"
        default: return nil
        }
    }

    // MARK: - Suffix Stemming

    private func stemAndLookup(_ word: String) -> String? {
        if let result = stemS(word) { return result }
        if let result = stemEd(word) { return result }
        if let result = stemIng(word) { return result }
        return nil
    }

    private func stemS(_ word: String) -> String? {
        guard word.hasSuffix("s") && word.count > 2 else { return nil }
        if word.hasSuffix("ies") {
            let stem = String(word.dropLast(3)) + "y"
            if let phonemes = lookupDict(stem, pos: nil) { return phonemes + "z" }
        }
        if word.hasSuffix("es") && word.count > 3 {
            let stem = String(word.dropLast(2))
            if let phonemes = lookupDict(stem, pos: nil) {
                let last = phonemes.last
                if last == "s" || last == "z" || last == "ʃ" || last == "ʒ" { return phonemes + "ɪz" }
                return phonemes + "z"
            }
        }
        let stem = String(word.dropLast(1))
        if let phonemes = lookupDict(stem, pos: nil) {
            let voiceless: Set<Character> = ["p", "t", "k", "f", "θ"]
            if let last = phonemes.last, voiceless.contains(last) { return phonemes + "s" }
            return phonemes + "z"
        }
        return nil
    }

    private func stemEd(_ word: String) -> String? {
        guard word.hasSuffix("ed") && word.count > 3 else { return nil }
        if word.hasSuffix("ied") {
            let stem = String(word.dropLast(3)) + "y"
            if let phonemes = lookupDict(stem, pos: nil) { return phonemes + "d" }
        }
        let stemEd = String(word.dropLast(2))
        if stemEd.count >= 2 {
            let chars = Array(stemEd)
            if chars[chars.count - 1] == chars[chars.count - 2] {
                let dedoubled = String(stemEd.dropLast(1))
                if let phonemes = lookupDict(dedoubled, pos: nil) {
                    return phonemes + edSuffix(phonemes)
                }
            }
        }
        if let phonemes = lookupDict(stemEd, pos: nil) {
            return phonemes + edSuffix(phonemes)
        }
        return nil
    }

    private func edSuffix(_ phonemes: String) -> String {
        let last = phonemes.last
        if last == "t" || last == "d" { return "ɪd" }
        let voiceless: Set<Character> = ["p", "k", "f", "θ", "s", "ʃ"]
        if let l = last, voiceless.contains(l) { return "t" }
        return "d"
    }

    private func stemIng(_ word: String) -> String? {
        guard word.hasSuffix("ing") && word.count > 4 else { return nil }
        let stem = String(word.dropLast(3))
        if stem.count >= 2 {
            let chars = Array(stem)
            if chars[chars.count - 1] == chars[chars.count - 2] {
                let dedoubled = String(stem.dropLast(1))
                if let phonemes = lookupDict(dedoubled, pos: nil) { return phonemes + "ɪŋ" }
            }
        }
        if let phonemes = lookupDict(stem, pos: nil) { return phonemes + "ɪŋ" }
        let stemE = stem + "e"
        if let phonemes = lookupDict(stemE, pos: nil) { return phonemes + "ɪŋ" }
        return nil
    }

    // MARK: - Text Normalization

    func normalizeText(_ text: String) -> String {
        var result = text
        let contractions: [(String, String)] = [
            ("can't", "can not"), ("won't", "will not"), ("don't", "do not"),
            ("doesn't", "does not"), ("didn't", "did not"), ("isn't", "is not"),
            ("aren't", "are not"), ("wasn't", "was not"), ("weren't", "were not"),
            ("couldn't", "could not"), ("wouldn't", "would not"), ("shouldn't", "should not"),
            ("haven't", "have not"), ("hasn't", "has not"), ("hadn't", "had not"),
            ("i'm", "i am"), ("i've", "i have"), ("i'll", "i will"), ("i'd", "i would"),
            ("you're", "you are"), ("you've", "you have"), ("you'll", "you will"),
            ("he's", "he is"), ("she's", "she is"), ("it's", "it is"),
            ("we're", "we are"), ("we've", "we have"), ("we'll", "we will"),
            ("they're", "they are"), ("they've", "they have"), ("they'll", "they will"),
            ("that's", "that is"), ("there's", "there is"), ("let's", "let us"),
        ]
        let lower = result.lowercased()
        for (contraction, expansion) in contractions {
            if lower.contains(contraction) {
                result = result.replacingOccurrences(of: contraction, with: expansion, options: .caseInsensitive)
            }
        }
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    func splitWords(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        for char in text {
            if char.isWhitespace {
                if !current.isEmpty { words.append(current); current = "" }
                words.append(" ")
            } else if char.isPunctuation || char.isSymbol {
                if !current.isEmpty { words.append(current); current = "" }
                words.append(String(char))
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    func punctuationToPhoneme(_ text: String) -> String? {
        switch text {
        case ",": return ","
        case ".": return "."
        case "!": return "!"
        case "?": return "?"
        case ";": return ";"
        case ":": return ":"
        case "-": return "-"
        case "'": return "'"
        default: return nil
        }
    }

    // MARK: - POS Tagging

    func tagPOS(_ text: String) -> [String: String] {
        var result = [String: String]()
        tagger.string = text
        let range = text.startIndex..<text.endIndex
        tagger.enumerateTags(in: range, unit: .word, scheme: .lexicalClass) { tag, tokenRange in
            let word = String(text[tokenRange]).lowercased()
            if let tag { result[word] = tag.rawValue }
            return true
        }
        return result
    }

    // MARK: - Dictionary Parsing

    private func parseDictionary(from url: URL) throws -> [String: DictEntry] {
        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var dict = [String: DictEntry]()
        for (key, value) in json {
            if let phonemes = value as? String {
                dict[key] = .simple(phonemes)
            } else if let posMap = value as? [String: String?] {
                var resolved = [String: String]()
                for (pos, pron) in posMap {
                    if let p = pron { resolved[pos] = p }
                }
                if !resolved.isEmpty { dict[key] = .heteronym(resolved) }
            }
        }
        return dict
    }

    private func growDictionary(_ dict: inout [String: DictEntry]) {
        var additions = [String: DictEntry]()
        for (key, entry) in dict {
            if key == key.lowercased() && !key.isEmpty {
                let capitalized = key.prefix(1).uppercased() + key.dropFirst()
                if dict[capitalized] == nil { additions[capitalized] = entry }
            }
            if key.first?.isUppercase == true {
                let lower = key.lowercased()
                if dict[lower] == nil { additions[lower] = entry }
            }
        }
        for (key, entry) in additions { dict[key] = entry }
    }
}
