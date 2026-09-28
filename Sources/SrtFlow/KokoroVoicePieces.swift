import Foundation

// MARK: - 一句旁白切成 Kokoro 读得下的几段（纯值）
//
// 管什么：Kokoro 一次最多 128 个 token、5 秒声音（`KokoroEngine`）。一句旁白先按句末标点（。！？.!?）切成几句，读不下的
// 再按逗号类（，、,；;：:）切，还读不下就在正中间那个字 / 词的空隙切成两半。每段带着它后面该停多久。
// 标点留在段里（句末的问号、逗号的语气要它）；读完之后冒出来的杂音由拼接那一步按最后一个字的结束时刻裁掉
// （KokoroVoiceAssembly）—— 2026-09-28 用户听出来：段尾留着逗号时 Kokoro 读完那个字后又冒出约 80 毫秒的杂音。
// 不管什么：怎么读（KokoroVoiceSpeech）、怎么拼（KokoroVoiceAssembly）。

enum KokoroVoicePieces {
    struct Piece: Equatable {
        /// 在整句里的 UTF-16 位置（不含两头的空白）。
        var range: Range<Int>
        /// 读完这一段停多久（秒）。
        var pauseAfter: Double
    }

    /// 句末（。！？.!?）后面停的比逗号类后面长；硬切开的两半之间几乎不停。
    static let sentencePause = 0.35
    static let clausePause = 0.2
    static let hardSplitPause = 0.05

    private static let sentenceEnds: Set<Character> = ["。", "！", "？", ".", "!", "?", "…"]
    private static let clauseEnds: Set<Character> = ["，", "、", ",", "；", ";", "：", ":"]

    /// 按句末标点切。最后一段后面不停（下一句旁白自己有空）。
    static func sentences(_ text: String) -> [Piece] {
        pieces(text, in: 0..<text.utf16.count, cuttingAt: sentenceEnds, pause: sentencePause, lastPause: 0)
    }

    /// 一段读不下时再切：有逗号类就按逗号切，没有就在正中间的空隙切成两半；切不开（只有一个字）就是 nil。
    static func split(_ piece: Piece, in text: String) -> [Piece]? {
        let byClause = pieces(text, in: piece.range, cuttingAt: clauseEnds, pause: clausePause, lastPause: piece.pauseAfter)
        if byClause.count > 1 { return byClause }
        let units = Array(text.utf16)
        let boundaries = cutPoints(units, in: piece.range)
        guard !boundaries.isEmpty else { return nil }
        let middle = (piece.range.lowerBound + piece.range.upperBound) / 2
        let cut = boundaries.min { abs($0 - middle) < abs($1 - middle) } ?? middle
        let left = trimmed(units, cut: piece.range.lowerBound..<cut)
        let right = trimmed(units, cut: cut..<piece.range.upperBound)
        guard !left.isEmpty, !right.isEmpty else { return nil }
        return [Piece(range: left, pauseAfter: hardSplitPause), Piece(range: right, pauseAfter: piece.pauseAfter)]
    }

    // MARK: 内部

    /// 按一组标点切：标点留在前一段里；空段不要；两头的空白去掉。
    private static func pieces(_ text: String, in range: Range<Int>, cuttingAt marks: Set<Character>,
                               pause: Double, lastPause: Double) -> [Piece] {
        let units = Array(text.utf16)
        var result: [Piece] = []
        var start = range.lowerBound
        var offset = 0
        for character in text {
            let length = String(character).utf16.count
            defer { offset += length }
            guard offset >= range.lowerBound, offset + length <= range.upperBound, marks.contains(character) else { continue }
            let piece = trimmed(units, cut: start..<(offset + length))
            if !piece.isEmpty, hasSpeakable(units, in: piece) { result.append(Piece(range: piece, pauseAfter: pause)) }
            start = offset + length
        }
        let tail = trimmed(units, cut: start..<range.upperBound)
        if !tail.isEmpty, hasSpeakable(units, in: tail) {
            result.append(Piece(range: tail, pauseAfter: lastPause))
        } else if var last = result.popLast() {
            last.pauseAfter = lastPause
            result.append(last)
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
