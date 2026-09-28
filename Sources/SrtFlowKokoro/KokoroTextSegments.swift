import Foundation

// MARK: - 一段文字切成字、词、数字、标点（SrtFlow 自己写的）
//
// 管什么：KokoroUnits 读音之前先把文字切开：一串汉字 / 一个拼音文字的词、夹在中文里的英文词、一串数字（带千分位、小数点、
// 百分号）、一个标点、空白；每一段记下它在原文里的 UTF-16 位置。以及数字怎么念（`KokoroNumberReading`）、汉字转拼音
// （`KokoroPinyin`）。都是纯函数。
// 不管什么：读音和 token（KokoroUnits）。

struct KokoroTextSegment: Equatable {
    enum Kind: Equatable { case word, latin, number, punctuation, space }

    var kind: Kind
    var text: String
    /// 在原文里的 UTF-16 位置。
    var range: Range<Int>

    /// `isWordCharacter`：中文传「是汉字」，拼音文字传「是字母」。中文里的英文字母单独成 `.latin`。
    static func split(_ text: String, isWordCharacter: (Character) -> Bool) -> [KokoroTextSegment] {
        let characters = Array(text)
        var result: [KokoroTextSegment] = []
        var index = 0
        var offset = 0
        func take(_ kind: Kind, while condition: (Int) -> Bool) {
            var end = index
            while end < characters.count, condition(end) { end += 1 }
            let piece = String(characters[index..<end])
            result.append(KokoroTextSegment(kind: kind, text: piece, range: offset..<(offset + piece.utf16.count)))
            offset += piece.utf16.count
            index = end
        }
        while index < characters.count {
            let character = characters[index]
            if character.isArabicDigit {
                take(.number) { position in
                    let current = characters[position]
                    if current.isArabicDigit { return true }
                    // 数字中间的千分位和小数点，后面还得跟着数字；最后可以带一个百分号。
                    if [",", ".", "，", "．"].contains(current), position + 1 < characters.count,
                       characters[position + 1].isArabicDigit, position > 0, characters[position - 1].isArabicDigit {
                        return true
                    }
                    return ["%", "％"].contains(current) && position > 0 && characters[position - 1].isArabicDigit
                }
            } else if character.isWhitespace {
                take(.space) { characters[$0].isWhitespace }
            } else if isWordCharacter(character) {
                take(.word) { isWordCharacter(characters[$0]) }
            } else if character.isASCII && character.isLetter {
                take(.latin) { characters[$0].isASCII && (characters[$0].isLetter || characters[$0] == "'") }
            } else {
                take(.punctuation) { $0 == index }
            }
        }
        return result
    }
}

extension Character {
    /// 汉字（CJK 表意文字，含「〇」）。
    var isHan: Bool { unicodeScalars.contains { $0.properties.isIdeographic } }

    /// 0–9，半角或全角。
    var isArabicDigit: Bool { ("0"..."9").contains(self) || ("０"..."９").contains(self) }
}

// MARK: - 汉字转拼音

enum KokoroPinyin {
    /// 用系统自带的普通话转写，整段一起转（能读对一部分多音字）；按空白分成一个个音节，带声调符号。
    static func syllables(_ text: String) -> [String] {
        let mutable = NSMutableString(string: text)
        CFStringTransform(mutable, nil, kCFStringTransformMandarinLatin, false)
        return (mutable as String).split(whereSeparator: { $0.isWhitespace }).map(String.init)
            .filter { $0.unicodeScalars.contains { CharacterSet.letters.contains($0) } }
    }
}

// MARK: - 数字怎么念

enum KokoroNumberReading {
    /// 一串数字（「10,000」「3.5」「50%」）按语言念出来。
    static func words(for digits: String, language: String) -> String {
        var text = String(digits.map { character -> Character in
            // 全角数字、全角标点换成半角。
            if let value = character.unicodeScalars.first?.value, (0xFF10...0xFF19).contains(value),
               let scalar = Unicode.Scalar(value - 0xFF10 + 0x30) {
                return Character(scalar)
            }
            switch character {
            case "，": return ","
            case "．": return "."
            case "％": return "%"
            default: return character
            }
        })
        let percent = text.hasSuffix("%")
        if percent { text.removeLast() }
        text = text.replacingOccurrences(of: ",", with: "")
        guard let number = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else { return digits }
        let formatter = NumberFormatter()
        formatter.numberStyle = .spellOut
        formatter.locale = Locale(identifier: locales[language] ?? "en_US")
        let spoken = formatter.string(from: number as NSDecimalNumber) ?? text
        guard percent else { return spoken }
        switch language {
        case "zh": return "百分之" + spoken
        case "ja": return spoken + "パーセント"
        case "fr": return spoken + " pour cent"
        case "es": return spoken + " por ciento"
        case "pt": return spoken + " por cento"
        case "it": return spoken + " per cento"
        default: return spoken + " percent"
        }
    }

    /// 整段文字里的每串数字都换成念法（日语整段读，用它）。
    static func replacingDigits(in text: String, language: String) -> String {
        KokoroTextSegment.split(text, isWordCharacter: { !$0.isArabicDigit && !$0.isWhitespace })
            .map { $0.kind == .number ? words(for: $0.text, language: language) : $0.text }
            .joined()
    }

    private static let locales = [
        "zh": "zh_CN", "en": "en_US", "ja": "ja_JP", "fr": "fr_FR", "es": "es_ES", "pt": "pt_BR", "it": "it_IT", "hi": "hi_IN"
    ]
}
