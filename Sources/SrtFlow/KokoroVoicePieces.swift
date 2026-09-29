import Foundation

// MARK: - 一句旁白切成 Kokoro 读得下的几段（纯值）
//
// 管什么：Kokoro 一次最多 128 个 token、5 秒声音（`KokoroEngine`）。**放得下就整句读**（`whole`）；读不下再切成两半
// （`split`）：先找句末标点（。！？.!?），没有找逗号类（，、,；;：:），都没有就在字 / 词的空隙切；有几处就挑离正中最近的那一处，
// 两半都尽量长。每段带着它后面该停多久。标点留在段里（句末的问号、逗号的语气要它）。
// 为什么不一句一句切（2026-09-28 以前是）：短的一段单独读会炸（「Two.」+39 dB，见 KokoroVoicePadding），而一句旁白里
// 「One. / Two.」这种一两个字的句子很常见；整句读模型自己会在句号处停，不用我们补停顿。
// 读完之后冒出来的杂音由拼接那一步按最后一个字的结束时刻裁掉（KokoroVoiceAssembly）。
// 不管什么：怎么读（KokoroPieceReader）、怎么拼（KokoroVoiceAssembly）。

enum KokoroVoicePieces {
    struct Piece: Equatable {
        /// 在整句里的 UTF-16 位置（不含两头的空白）。
        var range: Range<Int>
        /// 读完这一段停多久（秒）。
        var pauseAfter: Double
    }

    /// 在句末后面切开停的比逗号类后面长；硬切开的两半之间几乎不停。
    static let sentencePause = 0.35
    static let clausePause = 0.2
    static let hardSplitPause = 0.05

    private static let sentenceEnds: Set<Character> = ["。", "！", "？", ".", "!", "?", "…"]
    private static let clauseEnds: Set<Character> = ["，", "、", ",", "；", ";", "：", ":"]

    /// 整句一段（两头的空白去掉）；全是标点、没有能读的字就是空的。最后一段后面不停（下一句旁白自己有空）。
    static func whole(_ text: String) -> [Piece] {
        let units = Array(text.utf16)
        let range = trimmed(units, cut: 0..<units.count)
        guard !range.isEmpty, hasSpeakable(units, in: range) else { return [] }
        return [Piece(range: range, pauseAfter: 0)]
    }

    /// 一段读不下时切成两半：句末 → 逗号类 → 空隙，各挑离正中最近的一处（两边都得有能读的字）。切不开（只有一个字）就是 nil。
    /// 紧跟在很短的一句（「Two.」「第二。」，不到 `labelLength` 个字母数字）后面的那一刀排在最后：那是后面那句的标号，
    /// 留在后面那一半里读（不然「Three.」挂在前一半的末尾）。
    static func split(_ piece: Piece, in text: String) -> [Piece]? {
        let units = Array(text.utf16)
        let middle = (piece.range.lowerBound + piece.range.upperBound) / 2
        for (marks, pause) in [(sentenceEnds, sentencePause), (clauseEnds, clausePause)] {
            let all = cuts(after: marks, in: text, range: piece.range)
            let preferred = all.enumerated().filter { index, cut in
                speakableCount(units, in: (index == 0 ? piece.range.lowerBound : all[index - 1])..<cut) >= labelLength
            }.map(\.element)
            for cuts in [preferred, all] {
                if let halves = halves(units, piece: piece, cuts: cuts, middle: middle, pause: pause) { return halves }
            }
        }
        return halves(units, piece: piece, cuts: cutPoints(units, in: piece.range), middle: middle, pause: hardSplitPause)
    }

    /// 比这少的字母数字算「标号」那么短的一句。
    static let labelLength = 8

    // MARK: 内部

    /// 在 `cuts` 里挑离正中最近、两边都有能读的字的那一处切开。
    private static func halves(_ units: [UInt16], piece: Piece, cuts: [Int], middle: Int, pause: Double) -> [Piece]? {
        for cut in cuts.sorted(by: { abs($0 - middle) < abs($1 - middle) }) {
            let left = trimmed(units, cut: piece.range.lowerBound..<cut)
            let right = trimmed(units, cut: cut..<piece.range.upperBound)
            if !left.isEmpty, !right.isEmpty, hasSpeakable(units, in: left), hasSpeakable(units, in: right) {
                return [Piece(range: left, pauseAfter: pause), Piece(range: right, pauseAfter: piece.pauseAfter)]
            }
        }
        return nil
    }

    /// 这一段里每个 `marks` 标点**后面**的位置（标点留在前一半里）。
    private static func cuts(after marks: Set<Character>, in text: String, range: Range<Int>) -> [Int] {
        var result: [Int] = []
        var offset = 0
        for character in text {
            let length = String(character).utf16.count
            defer { offset += length }
            if offset >= range.lowerBound, offset + length < range.upperBound, marks.contains(character) {
                result.append(offset + length)
            }
        }
        return result
    }

    /// 去掉两头的空白（UTF-16 下标）。
    private static func trimmed(_ units: [UInt16], cut: Range<Int>) -> Range<Int> {
        var lower = cut.lowerBound
        var upper = cut.upperBound
        while lower < upper, isSpace(units[lower]) { lower += 1 }
        while upper > lower, isSpace(units[upper - 1]) { upper -= 1 }
        return lower..<upper
    }

    /// 有几个字母、汉字、数字。
    private static func speakableCount(_ units: [UInt16], in range: Range<Int>) -> Int {
        String(decoding: units[range], as: UTF16.self).unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count
    }

    /// 这一段里有没有能读出来的东西（字母、汉字、数字），全是标点的不算一段。
    private static func hasSpeakable(_ units: [UInt16], in range: Range<Int>) -> Bool {
        String(decoding: units[range], as: UTF16.self).unicodeScalars.contains {
            CharacterSet.alphanumerics.contains($0)
        }
    }

    /// 能在哪儿切：空白处（拼音文字的词之间），以及两个汉字之间。
    private static func cutPoints(_ units: [UInt16], in range: Range<Int>) -> [Int] {
        guard range.count > 1 else { return [] }
        var result: [Int] = []
        for index in (range.lowerBound + 1)..<range.upperBound {
            let previous = units[index - 1]
            let current = units[index]
            if isSpace(current) && !isSpace(previous) { result.append(index) }
            if isHan(previous) && isHan(current) { result.append(index) }
        }
        return result
    }

    private static func isSpace(_ unit: UInt16) -> Bool { unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x3000 }

    /// 常用汉字都在基本多文种平面（一个 UTF-16 单元），够切句用。
    private static func isHan(_ unit: UInt16) -> Bool { (0x4E00...0x9FFF).contains(unit) || (0x3400...0x4DBF).contains(unit) }
}
