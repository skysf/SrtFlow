import Foundation
import NaturalLanguage

// 一句话在哪断成几条字幕（2026-09-26 按主流规范重写，docs/architecture/subtitle-generation-style.md）。
//
// 管什么（输入是已经映射到时间线的词，按时间排好）：
// 1. 成句：句号、问号、叹号、省略号，或词间停顿超过阈值；缩写（U.S.）的点不算句号。
// 2. 句内在逗号类标点（， , ； ; ： :）后面分成小句 —— 一条一个小句，译文也跟着顺。
//    小句太短（不到 1 秒、或只有一个词 / 不到三个字）就并到旁边：优先并给同样太短的邻居，
//    其次并给更短的那边（「Even a gym, to me,」并成一条，「Oh,」并进后面那句）。
// 3. 还放不下的（超字数、超画面宽度、超 7 秒）：先找最少切几段能全放下，再在这个段数下挑总代价最小的切法
//    （动态规划；贪心先切第一刀会把后半截逼进死角）。代价 = 各段长短偏离平均 + 断在不好的地方：
//    停顿后面、连词 / 关系词 / 介词前面好断；a / the / to / that 这类词不留在一条末尾；
//    中文、日文用系统自带的分词（NLTokenizer），不在「如果」「大幅度」中间切，也不让「的」「了」起头。
// 不管什么：显示时间（`SubtitleCueTiming`）、去标点（`SubtitlePunctuation`，量宽度时按去完的算）。

enum SubtitleBreaks {
    typealias Word = SubtitleSegmenter.PlacedWord

    static let sentenceTerminators: Set<Character> = [".", "!", "?", "…", "。", "！", "？"]
    static let clauseMarks: Set<Character> = [",", ";", ":", "，", "；", "："]

    // MARK: ① 成句

    static func sentences(_ words: [Word], pauseThreshold: Double) -> [[Word]] {
        var sentences: [[Word]] = []
        var current: [Word] = []
        for (index, word) in words.enumerated() {
            current.append(word)
            let pause = index + 1 < words.count ? words[index + 1].start - word.end : 0
            if endsSentence(word.text) || pause > pauseThreshold {
                sentences.append(current)
                current = []
            }
        }
        if !current.isEmpty { sentences.append(current) }
        return sentences
    }

    static func endsSentence(_ text: String) -> Bool {
        guard let last = lastVisible(text), sentenceTerminators.contains(last) else { return false }
        return !(last == "." && SubtitlePunctuation.isAcronym(text))
    }

    static func endsClause(_ text: String) -> Bool {
        lastVisible(text).map { clauseMarks.contains($0) } ?? false
    }

    // MARK: ② 一句 → 几条

    /// 一句话切成几条（每条是这句话里一段连续的词）。
    static func pieces(of sentence: [Word], config: SubtitleSegmentationConfig) -> [Range<Int>] {
        guard !sentence.isEmpty else { return [] }
        let allowed = wordBoundaries(sentence)
        let merged = mergeShortClauses(clauseRanges(sentence), in: sentence, config: config)
        return merged.flatMap { splitToFit($0, in: sentence, allowed: allowed, config: config) }
    }

    /// 在逗号类标点后面分开的小句。
    static func clauseRanges(_ words: [Word]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start = 0
        for (index, word) in words.enumerated() where endsClause(word.text) && index + 1 < words.count {
            ranges.append(start ..< index + 1)
            start = index + 1
        }
        ranges.append(start ..< words.count)
        return ranges
    }

    /// 太短的小句并到旁边（并了放不下就不并）。
    static func mergeShortClauses(
        _ ranges: [Range<Int>], in words: [Word], config: SubtitleSegmentationConfig
    ) -> [Range<Int>] {
        var pieces = ranges
        var index = 0
        while index < pieces.count {
            guard pieces.count > 1, isTiny(pieces[index], in: words, config: config) else {
                index += 1
                continue
            }
            let partners = [index - 1, index + 1].filter { neighbor in
                pieces.indices.contains(neighbor)
                    && fits(joined(pieces[index], pieces[neighbor]), in: words, config: config)
            }
            // 优先并给同样太短的邻居，其次给更短的那边；一样就给前面那条。
            let partner = partners.min { a, b in
                let tinyA = isTiny(pieces[a], in: words, config: config)
                let tinyB = isTiny(pieces[b], in: words, config: config)
                if tinyA != tinyB { return tinyA }
                return duration(pieces[a], in: words) < duration(pieces[b], in: words)
            }
            guard let partner else {
                index += 1
                continue
            }
            let low = min(index, partner)
            pieces[low] = joined(pieces[low], pieces[low + 1])
            pieces.remove(at: low + 1)
            index = low
        }
        return pieces
    }

    /// 放不下就切开：最少切几段能全放下，就切几段；这个段数下挑总代价最小的切法。
    static func splitToFit(
        _ range: Range<Int>, in words: [Word], allowed: Set<Int>, config: SubtitleSegmentationConfig
    ) -> [Range<Int>] {
        guard range.count > 1, !fits(range, in: words, config: config) else { return [range] }
        let positions = [range.lowerBound]
            + (range.lowerBound + 1 ..< range.upperBound).filter { allowed.contains($0) }
            + [range.upperBound]
        let table = PieceTable(positions: positions, words: words, config: config)
        // 按词边界切到最细都有一段放不下（一个词就超宽）：退到不看词边界的贪心。
        guard (1 ..< positions.count).allSatisfy({ table.fits[$0 - 1][$0] }) else {
            return greedySplit(range, in: words, config: config)
        }
        let total = SubtitleLineMeasure.units(shownText(range, in: words))
        let fewest = max(2, minimumPieces(range, in: words, config: config))
        // 最少能放下的段数，和多一段的切法比一比：多一段要多付 `extraPieceCost`，
        // 但能躲开「的」起头、「在」收尾这种坏断点时就值得。
        var best: (cuts: [Int], cost: Double)?
        var feasible: Int?
        for count in fewest ..< max(fewest, positions.count) {
            if let limit = feasible, count > limit + 1 { break }
            guard let found = table.bestCuts(pieces: count, target: total / Double(count)) else { continue }
            if feasible == nil { feasible = count }
            let cost = found.cost + Double(count - (feasible ?? count)) * extraPieceCost
            if best.map({ cost < $0.cost }) ?? true { best = (found.cuts, cost) }
        }
        guard let cuts = best?.cuts else {
            // 走不到：切到最细（positions.count - 1 段）一定放得下。
            return zip(positions, positions.dropFirst()).map { $0 ..< $1 }
        }
        return zip([range.lowerBound] + cuts, cuts + [range.upperBound]).map { $0 ..< $1 }
    }

    /// 比最少段数多切一段的代价（和一个坏断点的罚分同一个量级的一半）。
    static let extraPieceCost = 0.5

    /// 切法的动态规划：哪些段放得下、每段和每一刀的代价先算好。
    private struct PieceTable {
        let positions: [Int]
        /// fits[i][j]：从 positions[i] 到 positions[j] 这一段放不放得下。
        var fits: [[Bool]]
        var units: [[Double]]
        var shortPenalty: [[Double]]
        /// 在 positions[i] 前面切一刀的代价。
        var cutCost: [Double]

        init(positions: [Int], words: [Word], config: SubtitleSegmentationConfig) {
            self.positions = positions
            let count = positions.count
            fits = Array(repeating: Array(repeating: false, count: count), count: count)
            units = Array(repeating: Array(repeating: 0, count: count), count: count)
            shortPenalty = Array(repeating: Array(repeating: 0, count: count), count: count)
            for i in 0 ..< count {
                for j in (i + 1) ..< count {
                    let piece = positions[i] ..< positions[j]
                    // 越长越放不下：一段放不下，从同一处起更长的也不用看了。
                    guard SubtitleBreaks.fits(piece, in: words, config: config) else { break }
                    fits[i][j] = true
                    units[i][j] = SubtitleLineMeasure.units(SubtitleBreaks.shownText(piece, in: words))
                    shortPenalty[i][j] = SubtitleBreaks.duration(piece, in: words) < config.minCueDuration ? 0.5 : 0
                }
            }
            let boundaries = Set(positions)
            let fullWidth = SubtitleLineMeasure.isMostlyFullWidth(words.map(\.text).joined())
            cutCost = positions.enumerated().map { index, position in
                index == 0 || index == count - 1 ? 0 : SubtitleBreaks.cutCost(
                    at: position, in: words, boundaries: boundaries, fullWidth: fullWidth
                )
            }
        }

        /// 切成 `pieces` 段、总代价最小的那几刀（每一刀是第几个词前面）和总代价；切不出放得下的就是 nil。
        func bestCuts(pieces: Int, target: Double) -> (cuts: [Int], cost: Double)? {
            let count = positions.count
            var cost = Array(repeating: Array(repeating: Double.infinity, count: count), count: pieces + 1)
            var from = Array(repeating: Array(repeating: -1, count: count), count: pieces + 1)
            cost[0][0] = 0
            for piece in 1 ... pieces {
                for end in 1 ..< count {
                    for start in 0 ..< end where fits[start][end] && cost[piece - 1][start].isFinite {
                        let deviation = (units[start][end] - target) / max(target, 1)
                        let value = cost[piece - 1][start] + deviation * deviation
                            + shortPenalty[start][end] + cutCost[start]
                        if value < cost[piece][end] {
                            cost[piece][end] = value
                            from[piece][end] = start
                        }
                    }
                }
            }
            guard cost[pieces][count - 1].isFinite else { return nil }
            var cuts: [Int] = []
            var end = count - 1
            for piece in stride(from: pieces, to: 0, by: -1) {
                let start = from[piece][end]
                if piece > 1 { cuts.append(positions[start]) }
                end = start
            }
            return (cuts.reversed(), cost[pieces][count - 1])
        }
    }

    /// 至少要切几段：字数、画面宽度、时长三样里最紧的那样说了算。
    static func minimumPieces(_ range: Range<Int>, in words: [Word], config: SubtitleSegmentationConfig) -> Int {
        let text = shownText(range, in: words)
        let lines = Double(config.maxLineCount)
        var pieces = SubtitleLineMeasure.units(text) / (config.maxLineUnits * lines)
        if config.maxLineEms.isFinite {
            pieces = max(pieces, SubtitleLineMeasure.ems(text) / (config.maxLineEms * lines))
        }
        pieces = max(pieces, duration(range, in: words) / config.maxCueDuration)
        return Int(pieces.rounded(.up))
    }

    /// 不看词边界的贪心：每段塞到放不下为止（一个词就超宽时，那个词自己一段）。
    static func greedySplit(_ range: Range<Int>, in words: [Word], config: SubtitleSegmentationConfig) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var start = range.lowerBound
        while start < range.upperBound {
            var end = start + 1
            while end < range.upperBound, fits(start ..< end + 1, in: words, config: config) { end += 1 }
            result.append(start ..< end)
            start = end
        }
        return result
    }

    // MARK: ③ 放不放得下、排成几行

    static func fits(_ range: Range<Int>, in words: [Word], config: SubtitleSegmentationConfig) -> Bool {
        guard !range.isEmpty else { return true }
        if duration(range, in: words) > config.maxCueDuration + 1e-9 { return false }
        return lines(for: words[range], config: config) != nil
    }

    /// 这几个词排成的行（已去标点，贪心、只在词边界换行）；排不进 `maxLineCount` 行就是 nil。
    static func lines(for words: ArraySlice<Word>, config: SubtitleSegmentationConfig) -> [String]? {
        var lines: [String] = []
        var line = ""
        for word in words {
            let candidate = line + word.text
            if !SubtitlePunctuation.strip(line).isEmpty, !lineFits(candidate, config: config) {
                lines.append(SubtitlePunctuation.strip(line))
                line = word.text
            } else {
                line = candidate
            }
        }
        let tail = SubtitlePunctuation.strip(line)
        if !tail.isEmpty { lines.append(tail) }
        guard lines.count <= config.maxLineCount,
              lines.allSatisfy({ lineFits($0, config: config) }) else { return nil }
        return lines
    }

    /// 一行放不放得下：量的是去完标点之后真正显示的字。
    static func lineFits(_ line: String, config: SubtitleSegmentationConfig) -> Bool {
        let shown = SubtitlePunctuation.strip(line)
        return SubtitleLineMeasure.units(shown) <= config.maxLineUnits + 1e-9
            && SubtitleLineMeasure.ems(shown) <= config.maxLineEms + 1e-9
    }

    // MARK: ④ 断在哪好

    /// 英文里适合当一条开头的词：连词、关系词，以及不紧贴前面那个词的介词（Netflix：在连词、介词前面断）。
    /// 「of」「to」不算：「bottom / of the world」「going / to walk」反而拆散了一个意思。
    static let goodStarts: Set<String> = [
        "and", "but", "or", "so", "because", "that", "which", "who", "whom", "whose", "when", "where",
        "while", "if", "unless", "until", "since", "although", "though", "as", "than", "whether",
        "in", "on", "at", "for", "with", "from", "into", "onto", "about", "after", "before",
        "between", "through", "during", "without", "like"
    ]
    /// 英文里不许留在一条末尾的词：冠词、限定词、介词、连词、物主代词、助动词、主语代词。
    static let danglingEnds: Set<String> = [
        "all", "each", "every", "some", "any", "no", "such",
        "a", "an", "the", "to", "of", "in", "on", "at", "for", "with", "from", "into", "onto", "about",
        "by", "as", "and", "or", "but", "so", "that", "which", "who", "my", "your", "his", "her", "its",
        "our", "their", "this", "these", "those", "is", "are", "was", "were", "be", "been", "am", "will",
        "would", "can", "could", "should", "have", "has", "had", "do", "does", "did", "not", "very",
        "i", "you", "he", "she", "we", "they", "i'm", "you're", "we're", "they're", "it's", "there's"
    ]
    /// 中文里不许起头的字（助词、语气词）。
    static let particles: Set<Character> = ["的", "了", "吗", "呢", "吧", "啊", "着", "过", "们", "地", "得", "么", "呀", "嘛"]
    /// 中文的句末语气词：转写常常不给标点，它后面就是句号该在的地方。
    static let sentenceFinalParticles: Set<Character> = ["呢", "吗", "吧", "啊", "呀", "嘛"]
    /// 中文里适合当一条开头的词（连词、话题转换的词）。
    static let chineseGoodStarts = [
        "如果", "因为", "所以", "但是", "而且", "然后", "虽然", "可是", "不过", "并且", "或者", "于是",
        "同时", "无论", "只要", "只有", "即使", "就算", "最后", "首先", "其次", "接着", "另外", "其实",
        "现在", "然而", "因此"
    ]
    /// 中文里不许留在一条末尾的词（连词、介词：开了头、话没说完）。只认整词 —— 「现在」不算「在」。
    static let chineseDanglingEnds = [
        "如果", "因为", "所以", "但是", "而且", "然后", "虽然", "可是", "不过", "并且", "或者", "于是",
        "就是", "还是", "只是", "在", "把", "被", "和", "跟", "与", "对", "从", "向", "给", "让", "为", "将", "比",
        "我", "你", "他", "她", "它", "我们", "你们", "他们", "她们", "这", "那", "这个", "那个", "这些", "那些", "一个"
    ]

    /// 在第 `cut` 个词前面切一刀的代价（负的是奖励）。
    /// - Parameters:
    ///   - boundaries: 能切的位置（中文的词边界）—— 判「整词」用。
    ///   - fullWidth: 这句话是不是中文、日文这类（按整句判：「电脑 MC | 的芯片」这一刀两边的字母
    ///     比汉字多，按两边判会当成英文，「的」起头就漏罚了）。
    static func cutCost(at cut: Int, in words: [Word], boundaries: Set<Int>, fullWidth: Bool) -> Double {
        let previous = words[cut - 1]
        let next = words[cut]
        var cost = 0.0
        // 说话停了一下：词间有空；中文的字首尾相接，停顿藏在拖得特别长的那个字里。
        if next.start - previous.end >= 0.25 {
            cost -= 0.35
        } else if fullWidth, previous.end - previous.start >= 0.45 {
            cost -= 0.25
        }
        if fullWidth {
            cost += chineseCutCost(at: cut, in: words, boundaries: boundaries)
        } else {
            if goodStarts.contains(normalized(next.text)) { cost -= 0.3 }
            if danglingEnds.contains(normalized(previous.text)) { cost += 1 }
        }
        return cost
    }

    /// 中文那一半：助词不起头、「的」不收尾、连词介词不收尾、连词前面好断、句末语气词后面好断。
    private static func chineseCutCost(at cut: Int, in words: [Word], boundaries: Set<Int>) -> Double {
        var cost = 0.0
        let nextShown = SubtitlePunctuation.strip(words[cut].text)
        let previousShown = SubtitlePunctuation.strip(words[cut - 1].text)
        if let first = nextShown.first, particles.contains(first) { cost += 1 }
        if previousShown.last == "的" { cost += 0.4 }
        if let last = previousShown.last, sentenceFinalParticles.contains(last) { cost -= 0.35 }
        // 整词：这几个字前后都是词边界（中文一个字一个词）。
        func wholeWord(_ word: String, from start: Int) -> Bool {
            let end = start + word.count
            guard start >= 0, end <= words.count,
                  start == 0 || boundaries.contains(start), end == words.count || boundaries.contains(end)
            else { return false }
            return SubtitlePunctuation.strip(words[start ..< end].map(\.text).joined()) == word
        }
        if chineseDanglingEnds.contains(where: { wholeWord($0, from: cut - $0.count) }) { cost += 1 }
        if chineseGoodStarts.contains(where: { wholeWord($0, from: cut) }) { cost -= 0.3 }
        return cost
    }

    /// 句子里哪些位置可以切（第 k 个词前面）。拉丁文字一个词就是一个词；中文、日文的「词」是一个个字，
    /// 用系统自带的分词找词边界 —— 不切在词中间。
    static func wordBoundaries(_ words: [Word]) -> Set<Int> {
        let all = Set(1 ..< max(words.count, 1))
        let text = words.map(\.text).joined()
        guard words.count > 1, SubtitleLineMeasure.isMostlyFullWidth(text) else { return all }
        var starts: [Int] = []
        var offset = 0
        for word in words {
            starts.append(offset)
            offset += word.text.utf16.count
        }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        if let language = NLLanguageRecognizer.dominantLanguage(for: text) { tokenizer.setLanguage(language) }
        var inside: Set<Int> = []
        tokenizer.enumerateTokens(in: text.startIndex ..< text.endIndex) { range, _ in
            let low = range.lowerBound.utf16Offset(in: text)
            let high = range.upperBound.utf16Offset(in: text)
            if high - low > 1 { inside.formUnion((low + 1) ..< high) }
            return true
        }
        return all.filter { !inside.contains(starts[$0]) }
    }

    // MARK: 小工具

    static func isTiny(_ range: Range<Int>, in words: [Word], config: SubtitleSegmentationConfig) -> Bool {
        if duration(range, in: words) < config.minClauseDuration { return true }
        let text = shownText(range, in: words)
        if SubtitleLineMeasure.isMostlyFullWidth(text) {
            return text.filter { !$0.isWhitespace }.count < 3
        }
        return text.split(whereSeparator: \.isWhitespace).count < 2
    }

    static func duration(_ range: Range<Int>, in words: [Word]) -> Double {
        guard let first = range.first, let last = range.last else { return 0 }
        return words[last].end - words[first].start
    }

    static func joined(_ a: Range<Int>, _ b: Range<Int>) -> Range<Int> {
        min(a.lowerBound, b.lowerBound) ..< max(a.upperBound, b.upperBound)
    }

    /// 显示出来的字（去了标点）。
    static func shownText(_ range: Range<Int>, in words: [Word]) -> String {
        SubtitlePunctuation.strip(words[range].map(\.text).joined())
    }

    static func lastVisible(_ text: String) -> Character? {
        text.last { !$0.isWhitespace }
    }

    /// 比较用的词：小写、去掉首尾空白和标点（「 That,」→「that」）。
    static func normalized(_ text: String) -> String {
        text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }
}
