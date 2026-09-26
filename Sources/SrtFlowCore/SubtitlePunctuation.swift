import Foundation

// 生成、翻译出来的字幕去标点（2026-09-26 用户拍板：「正常字幕是没有标点符号的」）。
//
// 管什么：一行字幕去掉停顿类标点 —— 逗号、句号、分号、冒号（全角、半角都算）：
// 在句中的换成一个半角空格，在行尾的直接删，不留两个连着的空格。
// 留着的：问号、叹号、引号、书名号、括号、省略号（半角的「...」统一成「…」）、外国人名的间隔号「·」、
// 列举中间的顿号「、」（行尾的删）；数字里的点、逗号、冒号（89.2、1,000、10:30）、英文缩写的点
// （U.S.、e.g.、a.m.）、单词里的撇号（you're）不动。
// 依据：Netflix 简体中文字幕规范第 12 节 "Do not use commas or periods. Use one single space instead."，
// 国内字幕规范同一口径；英文那行也去，是用户拍板（两行看着一致）。
// 出处与取舍：docs/architecture/subtitle-generation-style.md。
//
// 不管什么：什么时候去 —— 只在生成（`SubtitleSegmenter`）和机器翻译落字（`SubtitleRetranslation`）的
// 那一刻，用户手打、外挂导入的字一律不碰。断句要看标点，所以分段器先断句、切完才去。

public enum SubtitlePunctuation {

    /// 去掉的停顿类标点。
    static let pauseMarks: Set<Character> = [",", ".", ";", ":", "，", "。", "；", "：", "．", "｡", "､"]
    /// 顿号：列举中间留着，行尾删（Netflix 简体中文规范：可以用在列举里，不许在行尾）。
    static let enumerationComma: Character = "、"
    /// 去掉的标点后面紧跟着它们时，不补空格（右引号、右括号）。
    static let closers: Set<Character> = ["”", "’", "」", "』", "）", ")", "》", "〉", "】", "]", "\"", "'"]
    /// 去掉的标点前面刚好是它们时，不补空格（左引号、左括号）。
    static let openers: Set<Character> = ["“", "‘", "「", "『", "（", "(", "《", "〈", "【", "["]

    /// 去掉一段字幕文字里的停顿类标点。逐行处理，去空了的行不留。
    public static func strip(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .map(stripLine)
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// 这个词是不是英文缩写（U.S.、e.g.、a.m.、Ph.D.）：一两个字母一段、至少两段、每段后面带点。
    /// 分段器也用它 —— 缩写末尾的点不是句号。
    public static func isAcronym(_ word: String) -> Bool {
        let core = word.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: ",;:!?\"')]”’」』）》"))
        guard core.hasSuffix(".") else { return false }
        let segments = core.dropLast().split(separator: ".", omittingEmptySubsequences: false)
        return segments.count >= 2 && segments.allSatisfy { segment in
            (1...2).contains(segment.count) && segment.allSatisfy { $0.isASCII && $0.isLetter }
        }
    }

    // MARK: 内部

    static func stripLine(_ line: String) -> String {
        let chars = Array(line)
        var out: [Character] = []
        var index = 0
        while index < chars.count {
            let char = chars[index]
            // 半角省略号：连着三个及以上的点 → 「…」，留着。
            if char == "." {
                var end = index
                while end < chars.count, chars[end] == "." { end += 1 }
                if end - index >= 3 {
                    out.append("…")
                    index = end
                    continue
                }
            }
            if pauseMarks.contains(char) || char == enumerationComma {
                appendReplacement(for: char, at: index, in: chars, to: &out)
            } else {
                out.append(char)
            }
            index += 1
        }
        return collapsingSpaces(out)
    }

    /// 一个停顿类标点换成什么：留原样 / 一个空格 / 什么都不留。
    private static func appendReplacement(
        for char: Character, at index: Int, in chars: [Character], to out: inout [Character]
    ) {
        if keepsInPlace(chars, at: index) {
            out.append(char)
            return
        }
        // 行尾（后面只剩空格、别的停顿标点、右引号右括号）：直接删。
        if isLineEnd(chars, after: index) { return }
        if char == enumerationComma {
            out.append(char)                        // 列举中间的顿号留着
        } else if let next = nextVisible(chars, after: index), closers.contains(next) {
            return                                  // 右引号、右括号前面不补空格
        } else if let last = out.last, last == " " || openers.contains(last) {
            return                                  // 已经有空格，或者刚开了引号、括号
        } else if !out.isEmpty {
            out.append(" ")
        }
    }

    /// 不算停顿的点、逗号、冒号：数字里的（89.2、1,000、10:30），缩写和网址里的（U.S.、apple.com）。
    private static func keepsInPlace(_ chars: [Character], at index: Int) -> Bool {
        let char = chars[index]
        let previous = index > 0 ? chars[index - 1] : nil
        let next = index + 1 < chars.count ? chars[index + 1] : nil
        if [".", ",", ":", "：", "．"].contains(char),
           let previous, let next, isDigit(previous), isDigit(next) {
            return true
        }
        guard char == "." else { return false }
        if let previous, let next, isASCIIAlphanumeric(previous), isASCIIAlphanumeric(next) {
            return true
        }
        return isAcronym(token(around: index, in: chars))
    }

    private static func isLineEnd(_ chars: [Character], after index: Int) -> Bool {
        chars[(index + 1)...].allSatisfy { char in
            char.isWhitespace || pauseMarks.contains(char) || char == enumerationComma
                || closers.contains(char)
        }
    }

    private static func nextVisible(_ chars: [Character], after index: Int) -> Character? {
        chars[(index + 1)...].first { !$0.isWhitespace }
    }

    /// 包含这个位置的那个「词」（前后到空白为止）。
    private static func token(around index: Int, in chars: [Character]) -> String {
        var start = index
        while start > 0, !chars[start - 1].isWhitespace { start -= 1 }
        var end = index
        while end + 1 < chars.count, !chars[end + 1].isWhitespace { end += 1 }
        return String(chars[start...end])
    }

    private static func isDigit(_ char: Character) -> Bool {
        ("0"..."9").contains(char) || ("０"..."９").contains(char)
    }

    private static func isASCIIAlphanumeric(_ char: Character) -> Bool {
        char.isASCII && (char.isLetter || char.isNumber)
    }

    /// 连着的空格并成一个，去掉首尾空白（Netflix：不许出现两个连着的空格）。
    private static func collapsingSpaces(_ chars: [Character]) -> String {
        var result = ""
        for char in chars {
            if char == " " || char == "\t" {
                if result.last != " " { result.append(" ") }
            } else {
                result.append(char)
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }
}
