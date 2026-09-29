import Foundation

// MARK: - 一句字幕里每个词什么时候说（逐词高亮用）
//
// 管什么：
// - 词的时间怎么记在句子上（`SubtitleCue.words`）：在这句字里的位置（UTF-16）+ 相对这句开头的秒。
// - 生成的时候，带时间的词怎么对到最后显示的字上（去完标点、排成几行之后，`align`）。
// - 此刻正在说哪个词（`activeRange`），以及烧录要在哪些时刻切一刀（`changeTimes`）。
// - 改时间、改字、拆、合并之后，词的时间怎么跟着（`SubtitleTrackEditing` 调这里）。
// 为什么相对这句开头：整句挪动（拖、粘贴、AI 平移）时词跟着走，不用改；只有「裁」（只动一头）要把
// 相对时间换回原来那一刻 —— 声音没动。
// 只有 SrtFlow 自己生成的字幕（转写、配音）带词的时间；导入的、手打的没有，不高亮。
// 不管什么：高亮画成什么样（`SubtitleWordHighlight`）、此刻屏上有哪几句（`SubtitleTimeSlicing`）。
// 方案第 38、54 条（docs/plans/2026-09-27-mcp.md）。

/// 一句字幕里的一个词。
public struct SubtitleCueWord: Codable, Hashable, Sendable {
    /// 在这句字（`SubtitleCue.text`）里的位置：UTF-16 偏移（NSRange 的口径）。
    public var location: Int
    public var length: Int
    /// 相对这句开头的秒。
    public var start: Double
    public var end: Double

    public init(location: Int, length: Int, start: Double, end: Double) {
        self.location = location
        self.length = length
        self.start = start
        self.end = end
    }
}

/// 一段字在一行字幕里的位置（UTF-16）。
public struct SubtitleTextRange: Hashable, Sendable {
    public var location: Int
    public var length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }
}

public enum SubtitleCueWords {

    /// 生成时：带时间的词（按说的顺序，时间线上的秒）对到这句最后显示的字上。每个词只认它的字母和数字，
    /// 按顺序在字里找（标点、空格、换行跳过）；纯标点的词不记。有一个词找不到就整句不记 —— 宁可不亮，也不亮错地方。
    public static func align(
        _ words: [(text: String, start: Double, end: Double)], in text: String, cueStart: Double
    ) -> [SubtitleCueWord]? {
        let characters = Array(text)
        let offsets = utf16Offsets(characters)
        var cursor = 0
        var result: [SubtitleCueWord] = []
        for word in words {
            let core = Array(word.text.filter(isWordCharacter))
            guard !core.isEmpty else { continue }
            var matched = 0
            var first: Int?
            var last = cursor
            var index = cursor
            while index < characters.count, matched < core.count {
                if isWordCharacter(characters[index]) {
                    guard same(characters[index], core[matched]) else { return nil }
                    if first == nil { first = index }
                    last = index
                    matched += 1
                }
                index += 1
            }
            guard matched == core.count, let first else { return nil }
            cursor = last + 1
            let location = offsets[first]
            result.append(SubtitleCueWord(
                location: location, length: offsets[last + 1] - location,
                start: word.start - cueStart, end: word.end - cueStart
            ))
        }
        return result.isEmpty ? nil : result
    }

    /// 此刻（时间线上的秒）这句里正在说的那个词在字里的位置：最后一个已经开口的词；第一个词开口之前、
    /// 最后一个词说完之后都没有。字里带着 ASS 的标签（`plainText` 会改掉它）时不亮 —— 位置对不上。
    public static func activeRange(of cue: SubtitleCue, at time: Double) -> SubtitleTextRange? {
        guard let words = cue.words, !words.isEmpty, SubtitleSerializer.plainText(cue.text) == cue.text else { return nil }
        let offset = time - cue.start
        guard let index = words.lastIndex(where: { $0.start <= offset }) else { return nil }
        if index == words.count - 1, offset >= words[index].end { return nil }
        let word = words[index]
        guard word.length > 0, word.location >= 0, word.location + word.length <= cue.text.utf16.count else { return nil }
        return SubtitleTextRange(location: word.location, length: word.length)
    }

    /// 这句的高亮在哪些时刻换（时间线上的秒，只算落在这句里面的）：每个词开口、最后一个词说完。
    public static func changeTimes(of cue: SubtitleCue) -> [Double] {
        guard let words = cue.words, let last = words.last else { return [] }
        return (words.map { cue.start + $0.start } + [cue.start + last.end]).filter { $0 > cue.start && $0 < cue.end }
    }

    /// 这句的开头从 `oldStart` 挪到了现在的 `cue.start`、声音没动（裁掉开头、生成时给别的素材让开）：
    /// 相对时间换回原来那一刻。
    public static func keepInPlace(_ cue: inout SubtitleCue, oldStart: Double) {
        let shift = cue.start - oldStart
        guard shift != 0, let words = cue.words else { return }
        cue.words = words.map { word in
            var moved = word
            moved.start -= shift
            moved.end -= shift
            return moved
        }
    }

    /// 改了字：没改的字母、数字保住原来的时间（按字符对齐，最长公共子序列）；一个词里改掉的几个字母跟着这个词
    /// （往两边扩到挨着的、没被别的词占住的字母）；整个换掉的词不再记（它说的时候前一个词接着亮）。
    /// 一个都对不上就是 nil。
    public static func realigned(_ words: [SubtitleCueWord]?, from oldText: String, to newText: String) -> [SubtitleCueWord]? {
        guard let words, !words.isEmpty else { return nil }
        guard oldText != newText else { return words }
        let old = Array(oldText)
        let new = Array(newText)
        let oldOffsets = utf16Offsets(old)
        let newOffsets = utf16Offsets(new)
        let match = matchedCharacters(old, new)
        var taken = Set<Int>(match.values)
        var result: [SubtitleCueWord] = []
        for word in words {
            let oldIndices = old.indices.filter { oldOffsets[$0] >= word.location && oldOffsets[$0] < word.location + word.length }
            let mapped = oldIndices.compactMap { match[$0] }
            guard var low = mapped.min(), var high = mapped.max() else { continue }
            while low > 0, isWordCharacter(new[low - 1]), !taken.contains(low - 1) { low -= 1; taken.insert(low) }
            while high + 1 < new.count, isWordCharacter(new[high + 1]), !taken.contains(high + 1) { high += 1; taken.insert(high) }
            result.append(SubtitleCueWord(
                location: newOffsets[low], length: newOffsets[high + 1] - newOffsets[low], start: word.start, end: word.end
            ))
        }
        return result.isEmpty ? nil : result
    }

    /// 拆成两句、两半各给了字（`time` 是时间线上的拆分点）：前一半是原来的字开头、后一半是结尾时按位置分，
    /// 后一半的词换到它自己的开头；对不上位置就都不记。
    public static func split(
        _ cue: SubtitleCue, firstText: String, secondText: String, at time: Double
    ) -> (first: [SubtitleCueWord]?, second: [SubtitleCueWord]?) {
        guard let words = cue.words, !words.isEmpty else { return (nil, nil) }
        let whole = cue.text.utf16.count
        let firstLength = firstText.utf16.count
        let secondStart = whole - secondText.utf16.count
        guard cue.text.hasPrefix(firstText), cue.text.hasSuffix(secondText), firstLength <= secondStart else { return (nil, nil) }
        let shift = time - cue.start
        let first = words.filter { $0.location + $0.length <= firstLength }
        let second = words.filter { $0.location >= secondStart }.map { word in
            SubtitleCueWord(location: word.location - secondStart, length: word.length, start: word.start - shift, end: word.end - shift)
        }
        return (first.isEmpty ? nil : first, second.isEmpty ? nil : second)
    }

    /// 几句并成一句（字按顺序以空格拼、开头取最早的）：每句的词挪到合起来的字里、换到新的开头。
    /// 有一句（有字的）没有词的时间就整句不记 —— 一半亮一半不亮更怪。
    public static func merged(_ cues: [SubtitleCue], start: Double) -> [SubtitleCueWord]? {
        var result: [SubtitleCueWord] = []
        var offset = 0
        for cue in cues where !cue.text.isEmpty {
            guard let words = cue.words, !words.isEmpty else { return nil }
            if offset > 0 { offset += 1 }
            result += words.map { word in
                SubtitleCueWord(
                    location: word.location + offset, length: word.length,
                    start: word.start + cue.start - start, end: word.end + cue.start - start
                )
            }
            offset += cue.text.utf16.count
        }
        return result.isEmpty ? nil : result.sorted { $0.start < $1.start }
    }

    // MARK: 小件

    static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    private static func same(_ a: Character, _ b: Character) -> Bool {
        a == b || String(a).lowercased() == String(b).lowercased()
    }

    /// 每个字从第几个 UTF-16 单元开始，末尾多一格 = 总长。
    private static func utf16Offsets(_ characters: [Character]) -> [Int] {
        var offsets: [Int] = [0]
        offsets.reserveCapacity(characters.count + 1)
        for character in characters { offsets.append(offsets[offsets.count - 1] + character.utf16.count) }
        return offsets
    }

    /// 两段字里的字母、数字按最长公共子序列对上：旧的第几个字 → 新的第几个字。
    private static func matchedCharacters(_ old: [Character], _ new: [Character]) -> [Int: Int] {
        let a = old.indices.filter { isWordCharacter(old[$0]) }
        let b = new.indices.filter { isWordCharacter(new[$0]) }
        guard !a.isEmpty, !b.isEmpty else { return [:] }
        let lowerA = a.map { String(old[$0]).lowercased() }
        let lowerB = b.map { String(new[$0]).lowercased() }
        var table = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = lowerA[i] == lowerB[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var match: [Int: Int] = [:]
        var i = 0
        var j = 0
        while i < a.count, j < b.count {
            if lowerA[i] == lowerB[j] {
                match[a[i]] = b[j]
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return match
    }
}
