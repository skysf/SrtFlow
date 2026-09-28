import Foundation
import SrtFlowCore

// 逐词高亮（方案第 38、54 条）：生成时词对到去完标点、排好行的字上；此刻亮哪个词；改时间 / 改字 / 拆 / 合并之后
// 词的时间怎么跟；按词切段、烧录的 ASS 标签；工程里存得回来。规则写在 SubtitleCueWords.swift / SubtitleWordHighlight.swift。

func runSubtitleWordChecks() {
    checkWordAlignment()
    checkActiveWord()
    checkWordsFollowEdits()
    checkHighlightedSlicing()
    checkHighlightASS()
}

private func window(_ range: ClosedRange<Double>, at timelineStart: Double = 0) -> SubtitleClipWindow {
    SubtitleClipWindow(clipID: UUID(), assetFingerprint: "asset-w", sourceStart: range.lowerBound, sourceEnd: range.upperBound,
                       timelineStart: timelineStart)
}

private func timed(_ list: [(String, Double, Double)]) -> [TimedWord] {
    list.map { TimedWord(text: $0.0, start: $0.1, end: $0.2, confidence: 0.9) }
}

/// 一句里第 i 个词对到的那几个字。
private func spoken(_ cue: SubtitleCue, _ index: Int) -> String? {
    guard let words = cue.words, words.indices.contains(index) else { return nil }
    let word = words[index]
    return (cue.text as NSString).substring(with: NSRange(location: word.location, length: word.length))
}

private func highlighted(_ cue: SubtitleCue, at time: Double) -> String? {
    SubtitleCueWords.activeRange(of: cue, at: time).map { (cue.text as NSString).substring(with: NSRange(location: $0.location, length: $0.length)) }
}

/// 生成：词对到去完标点的字上（英文带前导空格和标点、中文逗号换成空格），时间是相对这句开头的秒。
private func checkWordAlignment() {
    let english = SubtitleSegmenter.segment(words: timed([
        ("Don't", 1.0, 1.3), (" miss,", 1.3, 1.6), (" this", 1.8, 2.0), (" course.", 2.0, 2.6)
    ]), window: window(0...5, at: 10))
    let cue = english.cues[0]
    checkEqual(cue.text, "Don't miss this course", "逐词：英文去完标点")
    checkEqual((0..<4).map { spoken(cue, $0) ?? "" }, ["Don't", "miss", "this", "course"], "逐词：每个词对到它自己的字（撇号在词里）")
    checkEqual(cue.words?.first?.start, 0, "逐词：第一个词从这句开头说")
    check(abs((cue.words?[2].start ?? 0) - 0.8) < 1e-9, "逐词：时间相对这句开头（时间线 11.8 秒开口 → 0.8）")

    let chinese = SubtitleSegmenter.segment(words: timed([
        ("学完", 0.0, 0.4), ("这门课", 0.4, 0.9), ("，", 0.9, 1.0), ("你", 1.2, 1.3), ("十分钟", 1.3, 1.8), ("就能剪。", 1.8, 2.4)
    ]), window: window(0...5))
    checkEqual(chinese.cues.map(\.text), ["学完这门课", "你十分钟就能剪"], "逐词：中文在逗号处断开、标点去掉")
    checkEqual((0..<2).map { spoken(chinese.cues[0], $0) ?? "" } + (0..<3).map { spoken(chinese.cues[1], $0) ?? "" },
               ["学完", "这门课", "你", "十分钟", "就能剪"], "逐词：中文按识别器给的词")
    check(abs((chinese.cues[1].words?[1].start ?? 0) - 0.1) < 1e-9, "逐词：后一句的词相对它自己的开头")
    let short = SubtitleSegmenter.segment(words: timed([("好，", 0.0, 0.3), ("走吧。", 0.5, 1.0)]), window: window(0...5))
    checkEqual(short.cues.map(\.text), ["好 走吧"], "逐词：太短的小句并成一句、句中逗号换成空格")
    checkEqual([spoken(short.cues[0], 0), spoken(short.cues[0], 1)], ["好", "走吧"], "逐词：空格两边各是各的词")

    check(SubtitleCueWords.align([("hello", 0, 1), ("there", 1, 2)], in: "hello world", cueStart: 0) == nil,
          "逐词：有一个词在字里找不到（字被改写过）就整句不记，不亮错地方")
    checkEqual(SubtitleCueWords.align([("…", 0, 1)], in: "…", cueStart: 0), nil, "逐词：纯标点不算词")

    let stored = SubtitleCue(start: 1, end: 3, text: "Hi there", words: [SubtitleCueWord(location: 3, length: 5, start: 0.4, end: 0.9)])
    let data = try? JSONEncoder().encode(stored)
    checkEqual(data.flatMap { try? JSONDecoder().decode(SubtitleCue.self, from: $0) }, stored, "逐词：词的时间存得回来")
    let old = try? JSONDecoder().decode(SubtitleCue.self, from: Data(#"{"id":"\#(UUID())","index":1,"start":0,"end":1,"text":"a","styleName":"Default","layer":0,"name":"","effect":""}"#.utf8))
    check(old != nil && old?.words == nil, "逐词：以前存的句子没有这一项，照样读得出来")
}

/// 此刻亮哪个词：最后一个开了口的；词和词中间的停顿里前一个接着亮；第一个词之前、最后一个说完之后不亮。
private func checkActiveWord() {
    let cue = SubtitleCue(start: 10, end: 14, text: "one two three", words: [
        SubtitleCueWord(location: 0, length: 3, start: 0.2, end: 0.6),
        SubtitleCueWord(location: 4, length: 3, start: 0.8, end: 1.2),
        SubtitleCueWord(location: 8, length: 5, start: 1.2, end: 2.0)
    ])
    checkEqual(highlighted(cue, at: 10.1), nil, "高亮：第一个词开口前不亮")
    checkEqual(highlighted(cue, at: 10.3), "one", "高亮：说「one」时亮它")
    checkEqual(highlighted(cue, at: 10.7), "one", "高亮：停顿里前一个接着亮")
    checkEqual(highlighted(cue, at: 11.5), "three", "高亮：最后一个词")
    checkEqual(highlighted(cue, at: 12.5), nil, "高亮：最后一个词说完就不亮了（字还在屏上）")
    checkEqual(SubtitleCueWords.changeTimes(of: cue), [10.2, 10.8, 11.2, 12.0], "高亮：每个词开口、最后一个说完各切一刀")
    var tagged = cue
    tagged.text = "{\\i1}one{\\i0} two three"
    checkEqual(highlighted(tagged, at: 10.3), nil, "高亮：字里带 ASS 标签（位置对不上）不亮")
}

/// 改时间 / 改字 / 拆 / 合并：词留在该在的那一刻、该在的那几个字上。
private func checkWordsFollowEdits() {
    let cue = SubtitleCue(start: 10, end: 14, text: "Hello wrold again", words: [
        SubtitleCueWord(location: 0, length: 5, start: 0.0, end: 0.4),
        SubtitleCueWord(location: 6, length: 5, start: 0.5, end: 0.9),
        SubtitleCueWord(location: 12, length: 5, start: 1.0, end: 1.6)
    ])
    func edited(_ body: (inout SubtitleDocumentModel, inout SubtitleCompanion) -> Void) -> SubtitleCue {
        var original = SubtitleDocumentModel(cues: [cue])
        var companion = SubtitleCompanion(origin: .generated)
        body(&original, &companion)
        return original.cues[0]
    }
    let trimmed = edited { SubtitleTrackEditing.setTime(id: cue.id, start: 10.45, end: 14, original: &$0, companion: &$1) }
    checkEqual(highlighted(trimmed, at: 10.6), highlighted(cue, at: 10.6), "跟着改：裁掉开头，声音没动，同一刻亮同一个词")
    let moved = edited { SubtitleTrackEditing.setStarts([cue.id: 12], original: &$0, companion: &$1) }
    checkEqual(highlighted(moved, at: 12.6), "wrold", "跟着改：整句挪动，词跟着走")
    let shifted = edited { SubtitleTrackEditing.setTime(id: cue.id, start: 11, end: 15, original: &$0, companion: &$1) }
    checkEqual(highlighted(shifted, at: 11.6), "wrold", "跟着改：两头改一样多 = 挪动，词跟着走")
    let fixed = edited { SubtitleTrackEditing.setText(id: cue.id, text: "Hello world again", original: &$0, companion: &$1) }
    checkEqual(highlighted(fixed, at: 10.6), "world", "跟着改：改错字，这个词照旧亮、亮的是改好的字")
    checkEqual(highlighted(fixed, at: 11.2), "again", "跟着改：没改的词照旧")
    let longer = edited { SubtitleTrackEditing.setText(id: cue.id, text: "Oh hello wrold again", original: &$0, companion: &$1) }
    checkEqual(highlighted(longer, at: 11.2), "again", "跟着改：前面加了字，后面的词挪到新位置")

    var halves = SubtitleDocumentModel(cues: [cue])
    var companion = SubtitleCompanion(origin: .generated)
    let secondID = UUID()
    SubtitleTrackEditing.splitCue(id: cue.id, at: 10.95, newID: secondID, texts: ("Hello wrold", "again"),
                                  original: &halves, companion: &companion)
    checkEqual(highlighted(halves.cues[0], at: 10.6), "wrold", "拆：前一半留前面的词")
    checkEqual(halves.cues[1].words?.count, 1, "拆：后一半只有它自己的词")
    checkEqual(highlighted(halves.cues[1], at: 11.2), "again", "拆：后一半换到自己的开头，同一刻亮同一个词")
    let plainSplit = edited { SubtitleTrackEditing.splitCue(id: cue.id, at: 11, original: &$0, companion: &$1) }
    checkEqual(plainSplit.words, cue.words, "拆（不给字）：字整句留在前半，词照旧")

    SubtitleTrackEditing.mergeCues(ids: [cue.id, secondID], original: &halves, companion: &companion)
    checkEqual(halves.cues[0].text, "Hello wrold again", "合并：字拼回去")
    checkEqual((0..<3).map { highlighted(halves.cues[0], at: 10 + [0.1, 0.6, 1.2][$0]) ?? "" }, ["Hello", "wrold", "again"],
               "合并：词回到合起来的字上、原来那一刻")
    var noWords = SubtitleDocumentModel(cues: [cue, SubtitleCue(start: 14, end: 15, text: "typed by hand")])
    SubtitleTrackEditing.mergeCues(ids: Set(noWords.cues.map(\.id)), original: &noWords, companion: &companion)
    checkEqual(noWords.cues[0].words, nil, "合并：有一句没有词的时间，整句不亮（一半亮一半不亮更怪）")
}

/// 切段：打开高亮时每个词开口切一刀、每段带上此刻亮的词；关着时和以前逐段一样。叠在一起时位置按整块的字算。
private func checkHighlightedSlicing() {
    let original = SubtitleCue(start: 0, end: 2, text: "big news", words: [
        SubtitleCueWord(location: 0, length: 3, start: 0.1, end: 0.5),
        SubtitleCueWord(location: 4, length: 4, start: 0.6, end: 1.2)
    ])
    let translation = SubtitleCue(start: 0, end: 2, text: "大新闻")
    let plain = SubtitleTimeSlicing.timeline([[original], [translation]])
    checkEqual(plain.count, 1, "切段：不高亮时整句一段")
    let lit = SubtitleTimeSlicing.timeline([[original], [translation]], highlighting: true)
    checkEqual(lit.map(\.start), [0, 0.1, 0.6, 1.2], "切段：高亮时每个词开口、说完各切一刀")
    checkEqual(lit.map { $0.display.highlights.map(\.location) }, [[], [0], [4], []], "切段：每段亮的是那一刻的词")
    checkEqual(lit[1].display.text, "big news\n大新闻", "切段：叠在一起时字照旧是原文在上")
    let stacked = SubtitleTimeSlicing.display(at: 0.7, layers: [[translation], [original]], highlighting: true)
    checkEqual(stacked?.highlights, [SubtitleTextRange(location: 8, length: 4)], "切段：词在下面那层时位置按整块的字算")
    let block = SubtitleRenderBlock(layers: [[original]], layout: nil, highlight: SubtitleWordHighlight())
    checkEqual(block.cues.count, 4, "切段：一块字幕按词切成四个事件（开口前、big、news、说完后）")
    checkEqual(block.highlights.count, 2, "切段：两个事件里有亮着的词")
}

/// 烧录：亮着的词前后加换色、放大的标签，之后回到本来的样式；没打开高亮的一块逐字和以前一样。
private func checkHighlightASS() {
    let highlight = SubtitleWordHighlight(color: .yellow, scale: 1.1)
    checkEqual(highlight.assText("big news", ranges: [SubtitleTextRange(location: 4, length: 4)]),
               "big {\\1c&H1AD9FF&\\1a&H00&\\fscx110\\fscy110}news{\\r}", "ASS：黄色是 BGR 字节序、不透明、放大 110%")
    checkEqual(SubtitleWordHighlight(color: .white, scale: 1).assText("a\nb", ranges: [SubtitleTextRange(location: 2, length: 1)]),
               "a\\N{\\1c&HFFFFFF&\\1a&H00&}b{\\r}", "ASS：不放大时不写 fscx；换行照旧写成 \\N")
    checkEqual(SubtitleWordHighlight(scale: 2).scale, 1.3, "ASS：放大最多 1.3 倍")
    let cue = SubtitleCue(start: 0, end: 2, text: "big news", words: [SubtitleCueWord(location: 4, length: 4, start: 0, end: 1)])
    let lit = BurnInStyle.default.assDocument(
        blocks: [SubtitleRenderBlock(layers: [[cue]], layout: nil, highlight: highlight)], aspectRatio: 16.0 / 9
    )
    check(lit.contains("big {\\1c&H1AD9FF&\\1a&H00&\\fscx110\\fscy110}news{\\r}"), "ASS：成片里说「news」那一段它是黄的")
    check(lit.contains(",big news\n") || lit.contains(",big news\r\n"), "ASS：说完之后那一段不亮")
    let unlit = BurnInStyle.default.assDocument(
        blocks: [SubtitleRenderBlock(layers: [[cue]], layout: nil, highlight: nil)], aspectRatio: 16.0 / 9
    )
    checkEqual(unlit, BurnInStyle.default.assDocument(cues: SubtitleTimeSlicing.slices([[cue]]), aspectRatio: 16.0 / 9),
               "ASS：没打开高亮，产物和以前逐字一样")
}
