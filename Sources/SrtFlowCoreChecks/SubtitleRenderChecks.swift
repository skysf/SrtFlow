import Foundation
import SrtFlowCore

// 重译（`SubtitleRetranslation`：两个按钮各自送哪几句、回来怎么落），以及画面上的字幕块
// （`SubtitleTimeSlicing`：某一刻显示什么、烧录怎么切；`assDocument(blocks:)`：几块各一个样式）。
// 用户拍的板见 docs/plans/2026-09-26-hide-guides-independent-subtitles.md。

func runSubtitleRenderChecks() {
    checkRetranslationScopes()
    checkRetranslationAfterSplitAndMerge()
    checkTimeSlicing()
    checkMultiBlockASS()
}

/// 一句原文 + 一句跟着它的译文。
private func pair(_ start: Double, _ end: Double, _ text: String, _ translated: String)
    -> (source: SubtitleCue, translation: SubtitleCue, link: TranslationLink) {
    let source = SubtitleCue(start: start, end: end, text: text)
    return (source, SubtitleCue(start: start, end: end, text: translated), TranslationLink(sourceIDs: [source.id], sourceText: text))
}

private func checkRetranslationScopes() {
    let a = pair(0, 2, "alpha", "阿"), b = pair(2, 4, "beta", "贝"), c = pair(4, 6, "gamma", "伽")
    let d = SubtitleCue(start: 6, end: 8, text: "delta")      // 新写的原文：缺译文
    let e = SubtitleCue(start: 8, end: 9, text: "")           // 空句：不送
    var original = SubtitleDocumentModel(cues: [a.source, b.source, c.source, d, e])
    var companion = SubtitleCompanion(
        translation: SubtitleDocumentModel(cues: [a.translation, b.translation, c.translation]),
        translationLinks: [a.translation.id: a.link, b.translation.id: b.link, c.translation.id: c.link]
    )
    // a：原文改了字、时间也挪了（译文没动过时间 → 重译后跟着原文的新时间走）。
    original.cues[0].text = "alpha!"
    original.cues[0].start = 0.5
    original.cues[0].end = 1.5
    // b：译文手改过字，原文没改 → 「只翻缺的和改过的」连它的字也不动。
    SubtitleTrackEditing.setText(id: b.translation.id, text: "贝贝", original: &original, companion: &companion)
    // c：原文改了字，但译文被用户挪过时间 → 换字、不动时间。
    original.cues[2].text = "gamma!"
    SubtitleTrackEditing.setTime(id: c.translation.id, start: 4.2, end: 5.8, original: &original, companion: &companion)

    checkEqual(SubtitleRetranslation.sources(for: .all, original: original, companion: companion).map(\.id),
               [a.source.id, b.source.id, c.source.id, d.id], "全部翻译：有字的原文全送（空句不送）")
    let asked = SubtitleRetranslation.sources(for: .missingAndStale, original: original, companion: companion)
    checkEqual(asked.map(\.id), [a.source.id, c.source.id, d.id], "只翻缺的和改过的：改过字的 a、c + 缺的 d")

    let snapshot = Dictionary(uniqueKeysWithValues: asked.map { ($0.id, $0.text) })
    let dNew = UUID()
    var next = companion
    SubtitleRetranslation.apply([a.source.id: "阿！", c.source.id: "伽！", d.id: "德"], snapshot: snapshot,
                                scope: .missingAndStale, original: original, companion: &next, newID: { dNew })
    let cues = Dictionary(uniqueKeysWithValues: (next.translation?.cues ?? []).map { ($0.id, $0) })
    checkEqual(cues[a.translation.id]?.text, "阿！", "换字：过期的 a 换成新译文")
    checkEqual(cues[a.translation.id]?.start, 0.5, "换字：没动过时间的跟着原文的新时间走")
    checkEqual(cues[b.translation.id]?.text, "贝贝", "原文没改的句子：手改过的译文字不动")
    checkEqual(cues[c.translation.id]?.text, "伽！", "换字：挪过时间的也换字")
    checkEqual(cues[c.translation.id]?.start, 4.2, "换字：用户挪过的时间不动")
    checkEqual(cues[dNew]?.start, 6, "补缺：新译文按原文的时间放")
    checkEqual(next.translationLinks[dNew]?.sourceIDs, [d.id], "补缺：来源记成那句原文")
    check(!next.isTranslationStale(a.translation.id, original: original), "换过字之后不再过期")
    checkEqual(next.translation?.cues.map(\.index), [1, 2, 3, 4], "落完按时间重排、重编号")

    // 全部翻译：清空重建 —— 手改的、挪过的一起换掉，每句原文一条新译文、跟原文的时间。
    let all = SubtitleRetranslation.sources(for: .all, original: original, companion: companion)
    var ids = (0..<all.count).map { _ in UUID() }.makeIterator()
    var rebuilt = companion
    SubtitleRetranslation.apply(Dictionary(uniqueKeysWithValues: all.map { ($0.id, "译" + $0.text) }),
                                snapshot: Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0.text) }),
                                scope: .all, original: original, companion: &rebuilt, newID: { ids.next()! })
    checkEqual(rebuilt.translation?.cues.map(\.text), ["译alpha!", "译beta", "译gamma!", "译delta"], "全部翻译：整条重建")
    checkEqual(rebuilt.translation?.cues.map(\.start), [0.5, 2, 4, 6], "全部翻译：时间一律跟原文")
    check(!rebuilt.hasManualTranslationEdits, "全部翻译：重建出来的都不算手改")
    check(companion.hasManualTranslationEdits, "重建之前：有手改（按钮要先确认）")
}

private func checkRetranslationAfterSplitAndMerge() {
    // 用户点名的场景：原文拆句后，两句译文各跟各的，不叠在一起。
    do {
        let s = pair(0, 4, "one two", "一二")
        var original = SubtitleDocumentModel(cues: [s.source])
        var companion = SubtitleCompanion(translation: SubtitleDocumentModel(cues: [s.translation]),
                                          translationLinks: [s.translation.id: s.link])
        let s2 = UUID()
        SubtitleTrackEditing.splitCue(id: s.source.id, at: 2, newID: s2, texts: ("one", "two"),
                                      original: &original, companion: &companion)
        let asked = SubtitleRetranslation.sources(for: .missingAndStale, original: original, companion: companion)
        checkEqual(asked.map(\.id), [s.source.id, s2], "拆句后：前半过期、后半缺译文")
        let t2 = UUID()
        SubtitleRetranslation.apply([s.source.id: "一", s2: "二"],
                                    snapshot: Dictionary(uniqueKeysWithValues: asked.map { ($0.id, $0.text) }),
                                    scope: .missingAndStale, original: original, companion: &companion, newID: { t2 })
        let spans = (companion.translation?.cues ?? []).map { [$0.start, $0.end] }
        checkEqual(spans, [[0, 2], [2, 4]], "拆句后重译：两句译文首尾相接、不叠在一起")
        checkEqual(companion.translation?.cues.map(\.text), ["一", "二"], "拆句后重译：各是各的字")
    }
    // 原文合并：几句译文都指向留下的那句，重译时收成一句（没手动改过的删掉）。
    do {
        let x = pair(0, 2, "a", "甲"), y = pair(2, 4, "b", "乙")
        var original = SubtitleDocumentModel(cues: [x.source, y.source])
        var companion = SubtitleCompanion(translation: SubtitleDocumentModel(cues: [x.translation, y.translation]),
                                          translationLinks: [x.translation.id: x.link, y.translation.id: y.link])
        SubtitleTrackEditing.mergeCues(ids: [x.source.id, y.source.id], original: &original, companion: &companion)
        let asked = SubtitleRetranslation.sources(for: .missingAndStale, original: original, companion: companion)
        checkEqual(asked.map(\.id), [x.source.id], "合并后：留下的那句过期")
        SubtitleRetranslation.apply([x.source.id: "甲乙"], snapshot: [x.source.id: "a b"], scope: .missingAndStale,
                                    original: original, companion: &companion)
        checkEqual(companion.translation?.cues.map(\.text), ["甲乙"], "合并后重译：收成一句")
        checkEqual(companion.translation?.cues.first?.end, 4, "合并后重译：跟着合并后的时间")
    }
    // 拆合过的译文：不自动更新（不过期、也不算缺）。
    do {
        let z = pair(0, 4, "z", "泽")
        var original = SubtitleDocumentModel(cues: [z.source])
        var companion = SubtitleCompanion(translation: SubtitleDocumentModel(cues: [z.translation]),
                                          translationLinks: [z.translation.id: z.link])
        SubtitleTrackEditing.splitCue(id: z.translation.id, at: 2, original: &original, companion: &companion)
        original.cues[0].text = "z!"
        check(SubtitleRetranslation.sources(for: .missingAndStale, original: original, companion: companion).isEmpty,
              "拆过的译文：原文改了也不自动更新、那句原文也不算缺")
    }
}

private func checkTimeSlicing() {
    let big = SubtitleCue(start: 0, end: 4, text: "BIG")
    let t1 = SubtitleCue(start: 0, end: 2, text: "t1"), t2 = SubtitleCue(start: 2, end: 4, text: "t2")
    let slices = SubtitleTimeSlicing.slices([[big], [t1, t2]])
    checkEqual(slices.map { [$0.start, $0.end] }, [[0, 2], [2, 4]], "切块：原文横跨两句译文 → 切成两段")
    checkEqual(slices.map(\.text), ["BIG\nt1", "BIG\nt2"], "切块：原文行永远在上、译文行在下")
    for slice in slices {
        checkEqual(SubtitleTimeSlicing.text(at: slice.start, layers: [[big], [t1, t2]]), slice.text, "切块：段的字 = 段起点那一刻的字")
        checkEqual(SubtitleTimeSlicing.text(at: (slice.start + slice.end) / 2, layers: [[big], [t1, t2]]), slice.text,
                   "切块：段中间任一刻也是这些字（预览和烧录对得上）")
    }
    let gap = SubtitleTimeSlicing.slices([[SubtitleCue(start: 0, end: 1, text: "x"), SubtitleCue(start: 2, end: 3, text: "y")]])
    checkEqual(gap.map { [$0.start, $0.end] }, [[0, 1], [2, 3]], "切块：没有字的时间不出段")
    let same = SubtitleTimeSlicing.slices([[SubtitleCue(start: 0, end: 1, text: "x"), SubtitleCue(start: 1, end: 2, text: "x")]])
    checkEqual(same.map { [$0.start, $0.end] }, [[0, 2]], "切块：首尾相接、字一样的并成一段")
    // 同一层里重叠的几句：排在前面的在最下面（与 libass 叠重叠事件的方向一致）。
    let p = SubtitleCue(start: 0, end: 4, text: "p"), q = SubtitleCue(start: 1, end: 3, text: "q")
    checkEqual(SubtitleTimeSlicing.text(at: 2, layers: [[p, q]]), "q\np", "同层重叠：先来的在底下")
    checkEqual(SubtitleTimeSlicing.text(at: 5, layers: [[p, q]]), nil, "没有字就是 nil")
    checkEqual(SubtitleTimeSlicing.text(at: 0.5, layers: [[SubtitleCue(start: 0, end: 1, text: "")], [t1]]), "t1",
               "空句不占一行")
}

private func checkMultiBlockASS() {
    let style = BurnInStyle.default
    let layout = SubtitleLayout(marginLeft: 10, marginRight: 10, marginBottom: 700, fontScale: 0.8)
    let ass = style.assDocument(
        blocks: [SubtitleRenderBlock(cues: [SubtitleCue(start: 0, end: 1, text: "orig")], layout: nil),
                 SubtitleRenderBlock(cues: [SubtitleCue(start: 0, end: 1, text: "trans")], layout: layout)],
        aspectRatio: 16.0 / 9.0
    )
    check(ass.contains("Style: \(BurnInStyle.assStyleName),"), "两块：第一块沿用老样式名")
    check(ass.contains("Style: \(BurnInStyle.assStyleName)2,"), "两块：第二块自己一个样式")
    check(ass.contains(",0700,"), "两块：第二块的布局进它自己的样式（MarginV 700）")
    check(ass.contains("Dialogue: 1,") && ass.contains("\(BurnInStyle.assStyleName)2,,"), "两块：第二块的事件在 Layer 1、用它的样式")
    check(ass.contains("Dialogue: 0,"), "两块：第一块的事件在 Layer 0")
    // 只有一块：产物和以前逐字一样（外挂 ASS 自带的 Layer 照旧）。
    var layered = SubtitleCue(start: 0, end: 1, text: "x")
    layered.layer = 3
    let single = style.assDocument(cues: [layered], aspectRatio: 16.0 / 9.0)
    checkEqual(single, style.assDocument(blocks: [SubtitleRenderBlock(cues: [layered], layout: nil)], aspectRatio: 16.0 / 9.0),
               "一块：两个入口产物一样")
    check(single.contains("Dialogue: 3,"), "一块：原来的 Layer 不动")
    check(!single.contains("Style: \(BurnInStyle.assStyleName)2,"), "一块：只有一个样式")
}
