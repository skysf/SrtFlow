import Foundation
import SrtFlowCore

// 两条字幕轨的编辑合同（`SubtitleTrackEditing`）、译文的来源表（`TranslationLink`：过期 / 缺译文 / 手改过）、
// 老工程拆开（`splitMirroredTranslation`）与规范化、宽容 Codable。
// 2026-09-26 字幕拆成两条独立轨（docs/plans/2026-09-26-hide-guides-independent-subtitles.md）：
// 以前这里测的是 `LinkedSubtitleEditing`「两轨一起动」，现在每一条都要反过来 —— 只动这句所在的那条轨。

/// 原文三句 + 各自一句译文（译文有自己的 ID，来源指着原文、翻的时候的原文 = 现在的原文）。
private struct TrackFixture {
    let a = SubtitleCue(index: 1, start: 0, end: 2, text: "hello there")
    let b = SubtitleCue(index: 2, start: 2, end: 4, text: "world")
    let c = SubtitleCue(index: 3, start: 4, end: 6, text: "again")
    let ta = SubtitleCue(index: 1, start: 0, end: 2, text: "你好")
    let tb = SubtitleCue(index: 2, start: 2, end: 4, text: "世界")
    let tc = SubtitleCue(index: 3, start: 4, end: 6, text: "再见")

    func make() -> (SubtitleDocumentModel, SubtitleCompanion) {
        let companion = SubtitleCompanion(
            translation: SubtitleDocumentModel(cues: [ta, tb, tc]),
            targetLanguage: "zh-Hans",
            cueMeta: [a.id: CueMeta(recognitionConfidence: 0.8), b.id: CueMeta(recognitionConfidence: 0.9),
                      c.id: CueMeta(recognitionConfidence: 0.7)],
            translationLinks: [ta.id: TranslationLink(sourceIDs: [a.id], sourceText: a.text),
                               tb.id: TranslationLink(sourceIDs: [b.id], sourceText: b.text),
                               tc.id: TranslationLink(sourceIDs: [c.id], sourceText: c.text)]
        )
        return (SubtitleDocumentModel(cues: [a, b, c]), companion)
    }
}

func runSubtitleTrackChecks() {
    let f = TrackFixture()
    checkTrackTimeAndText(f)
    checkTrackStructure(f)
    checkTrackMigration(f)
    checkTrackCodable(f)
    checkTrackHidden(f)
}

/// 单句藏起来（V）的名单：拆、合并、删、全部重译都要跟着记对（2026-09-26）。
private func checkTrackHidden(_ f: TrackFixture) {
    do {
        var (original, companion) = f.make()
        companion.hiddenCueIDs = [f.a.id, f.tb.id]
        let aHalf = UUID(), tHalf = UUID()
        SubtitleTrackEditing.splitCue(id: f.a.id, at: 1, newID: aHalf, original: &original, companion: &companion)
        SubtitleTrackEditing.splitCue(id: f.tb.id, at: 3, newID: tHalf, original: &original, companion: &companion)
        check(companion.hiddenCueIDs.isSuperset(of: [f.a.id, aHalf, f.tb.id, tHalf]), "拆：藏着的句子两半都藏着")
        SubtitleTrackEditing.splitCue(id: f.c.id, at: 5, newID: UUID(), original: &original, companion: &companion)
        checkEqual(companion.hiddenCueIDs.count, 4, "拆：没藏的句子拆完也没藏")

        SubtitleTrackEditing.mergeCues(ids: [f.a.id, aHalf], original: &original, companion: &companion)
        check(companion.hiddenCueIDs.contains(f.a.id) && !companion.hiddenCueIDs.contains(aHalf),
              "合并：全都藏着 → 合出来的藏着，被并掉的从名单里去掉")
        SubtitleTrackEditing.mergeCues(ids: [f.a.id, f.b.id], original: &original, companion: &companion)
        check(!companion.hiddenCueIDs.contains(f.a.id), "合并：有一句看得见 → 合出来的看得见")

        SubtitleTrackEditing.removeCues(ids: [tHalf], original: &original, companion: &companion)
        check(!companion.hiddenCueIDs.contains(tHalf), "删：从名单里去掉")

        var rebuilt = companion
        SubtitleRetranslation.apply([f.a.id: "新"], snapshot: [f.a.id: original.cues[0].text], scope: .all,
                                    original: original, companion: &rebuilt)
        check(!rebuilt.hiddenCueIDs.contains(f.tb.id), "全部重译：旧译文句连同藏着的记号一起清掉")
    }
    do {
        // 编解码：排好序的 uuidString 数组；坏 ID 丢掉；空的不落键。
        let (_, companion) = f.make()
        var hidden = companion
        hidden.hiddenCueIDs = [f.a.id, f.tc.id]
        let data = try JSONEncoder().encode(hidden)
        checkEqual(try JSONDecoder().decode(SubtitleCompanion.self, from: data).hiddenCueIDs, hidden.hiddenCueIDs, "藏着的名单往返无损")
        let raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(companion)) as? [String: Any]
        check(raw?["hiddenCueIDs"] == nil, "没藏过：不落 hiddenCueIDs 键")
        let json = #"{"hiddenCueIDs": ["bad", "6BA7B810-9DAD-11D1-80B4-00C04FD430C8"]}"#
        checkEqual(try JSONDecoder().decode(SubtitleCompanion.self, from: Data(json.utf8)).hiddenCueIDs.count, 1, "坏 ID 丢掉")
        var pruned = hidden
        pruned.hiddenCueIDs.insert(UUID())
        pruned.normalize(originalCueIDs: [f.a.id, f.b.id, f.c.id])
        checkEqual(pruned.hiddenCueIDs, [f.a.id, f.tc.id], "规范化：名单只留两条轨上还在的")
    } catch {
        check(false, "藏着的名单编解码抛错：\(error)")
    }
}

private func checkTrackTimeAndText(_ f: TrackFixture) {
    // 改时间：只动这句所在的那条轨；改完重排 + 重编号（稳定排序）。
    do {
        var (original, companion) = f.make()
        SubtitleTrackEditing.setTime(id: f.a.id, start: 0.5, end: 1.5, original: &original, companion: &companion)
        checkEqual(original.cues[0].start, 0.5, "改原文时间：原文落盘")
        checkEqual(companion.translation?.cues[0].start, 0, "改原文时间：译文不跟（两条轨独立）")
        checkEqual(companion.translationLinks[f.ta.id]?.timeEdited, false, "改原文时间：译文没被动过")

        SubtitleTrackEditing.setTime(id: f.tc.id, start: 0.1, end: 0.5, original: &original, companion: &companion)
        checkEqual(companion.translation?.cues.map(\.id), [f.ta.id, f.tc.id, f.tb.id], "改译文时间：译文轨按时间重排")
        checkEqual(companion.translation?.cues.map(\.index), [1, 2, 3], "改译文时间：重编号")
        checkEqual(original.cues.map(\.id), [f.a.id, f.b.id, f.c.id], "改译文时间：原文轨不动")
        checkEqual(companion.translationLinks[f.tc.id]?.timeEdited, true, "改译文时间：记「时间手动改过」")
        // 同起点保持原有先后：把 tb 也挪到 tc 的起点上，tc 本来在前，排完还在前。
        SubtitleTrackEditing.setTime(id: f.tb.id, start: 0.1, end: 0.4, original: &original, companion: &companion)
        checkEqual(companion.translation?.cues.map(\.id), [f.ta.id, f.tc.id, f.tb.id], "改时间：同起点保持原有先后")
    }

    // 改原文的字：置信度作废、出处转人工，它的译文现算成过期；同文本不动。
    do {
        var (original, companion) = f.make()
        check(!companion.isTranslationStale(f.ta.id, original: original), "刚翻好的译文不过期")
        SubtitleTrackEditing.setText(id: f.a.id, text: "hi", original: &original, companion: &companion)
        checkEqual(original.cues[0].text, "hi", "改原文：文本落盘")
        checkEqual(companion.cueMeta[f.a.id]?.recognitionConfidence, nil, "改原文：置信度作废")
        checkEqual(companion.cueMeta[f.a.id]?.origin, .editedManually, "改原文：出处转人工")
        check(companion.isTranslationStale(f.ta.id, original: original), "改原文：它的译文现算成过期")
        check(!companion.isTranslationStale(f.tb.id, original: original), "改原文：别句的译文不受影响")
        var before = companion
        SubtitleTrackEditing.setText(id: f.b.id, text: "world", original: &original, companion: &before)
        checkEqual(before.cueMeta[f.b.id]?.recognitionConfidence, 0.9, "改原文：同文本不动 meta")

        // 手改译文：跟上现在的原文（不再过期），记「字手改过」。
        SubtitleTrackEditing.setText(id: f.ta.id, text: "嗨", original: &original, companion: &companion)
        checkEqual(companion.translation?.cues[0].text, "嗨", "改译文：文本落盘")
        check(!companion.isTranslationStale(f.ta.id, original: original), "改译文：跟上现在的原文，不再过期")
        checkEqual(companion.translationLinks[f.ta.id]?.textEdited, true, "改译文：记「字手改过」")
        checkEqual(original.cues[0].text, "hi", "改译文：原文不动")
        check(companion.hasManualTranslationEdits, "手改过译文 = 有手改（全部重译前要确认）")
    }

    // 整体平移：两条轨各挪各的，真挪动了的译文才记「时间改过」。
    do {
        var (original, companion) = f.make()
        SubtitleTrackEditing.setStarts([f.a.id: 10, f.tb.id: 12, f.tc.id: 4], original: &original, companion: &companion)
        checkEqual(original.cues.first { $0.id == f.a.id }?.start, 10, "平移：原文挪到绝对起点")
        checkEqual(original.cues.first { $0.id == f.a.id }?.end, 12, "平移：时长不变")
        checkEqual(companion.translation?.cues.first { $0.id == f.ta.id }?.start, 0, "平移：没选中的译文不跟")
        checkEqual(companion.translation?.cues.first { $0.id == f.tb.id }?.start, 12, "平移：译文挪到绝对起点")
        checkEqual(companion.translationLinks[f.tb.id]?.timeEdited, true, "平移：挪动了的译文记时间改过")
        checkEqual(companion.translationLinks[f.tc.id]?.timeEdited, false, "平移：起点没变的不算改过")
        checkEqual(original.cues.map(\.id), [f.b.id, f.c.id, f.a.id], "平移：挪完按时间重排")
    }
}

private func checkTrackStructure(_ f: TrackFixture) {
    // 删除：各删各的；原文删了译文不跟着删（来源悬空）。
    do {
        var (original, companion) = f.make()
        SubtitleTrackEditing.removeCues(ids: [f.b.id], original: &original, companion: &companion)
        checkEqual(original.cues.map(\.id), [f.a.id, f.c.id], "删原文：原文轨删掉")
        checkEqual(original.cues.map(\.index), [1, 2], "删原文：重编号")
        checkEqual(companion.translation?.cues.count, 3, "删原文：译文不跟着删")
        checkEqual(companion.cueMeta[f.b.id], nil, "删原文：meta 同删")
        check(!companion.isTranslationStale(f.tb.id, original: original), "来源悬空的译文不算过期（重译不碰它）")
        SubtitleTrackEditing.removeCues(ids: [f.ta.id, f.tb.id, f.tc.id], original: &original, companion: &companion)
        checkEqual(companion.translation, nil, "译文删光：译文轨归 nil")
        check(companion.translationLinks.isEmpty, "译文删光：来源表同删")
    }

    // 新加一句：原文轨按时间落位、出处人工；译文轨来源记成重叠最多的原文、算拆合过（不自动更新）。
    do {
        var (original, companion) = f.make()
        let newID = SubtitleTrackEditing.insertCue(at: 3, duration: 1, into: .original, original: &original, companion: &companion)
        checkEqual(original.cues.map(\.id), [f.a.id, f.b.id, newID!, f.c.id], "加原文：按时间顺序落位")
        checkEqual(companion.cueMeta[newID!]?.origin, .editedManually, "加原文：出处人工")
        checkEqual(companion.translation?.cues.count, 3, "加原文：译文轨不跟着加")
        let untranslated = companion.untranslatedSources(in: original).map(\.id)
        checkEqual(untranslated, [], "加原文：空句不算缺译文（没什么可翻）")
        original.cues[2].text = "new line"
        checkEqual(companion.untranslatedSources(in: original).map(\.id), [newID!], "有字的新原文 = 缺译文")

        let tID = SubtitleTrackEditing.insertCue(at: 2.5, duration: 1, into: .translation, original: &original, companion: &companion)
        checkEqual(companion.translationLinks[tID!]?.sourceIDs, [f.b.id], "加译文：来源 = 重叠最多的那句原文（b 2–4）")
        checkEqual(companion.translationLinks[tID!]?.restructured, true, "加译文：自己写的永远不自动更新")
        checkEqual(original.cues.count, 4, "加译文：原文轨不动")
        check(SubtitleTrackEditing.insertCue(at: 3, duration: 0, into: .original, original: &original, companion: &companion) == nil,
              "加一句：零时长拒绝")
    }

    // 粘贴一句现成的（2026-09-26 时间线复制粘贴）：字和样式照带、用给的 ID，旁表同「新加一句」。
    do {
        var (original, companion) = f.make()
        var pasted = f.b
        pasted.id = UUID()
        pasted.start = 10
        pasted.end = 11.5
        let id = SubtitleTrackEditing.insertCue(pasted, into: .original, original: &original, companion: &companion)
        checkEqual(id, pasted.id, "粘原文：用给的 ID（调用方已经换成新的）")
        checkEqual(original.cues.last?.text, f.b.text, "粘原文：字照带")
        checkEqual(original.cues.last?.id, pasted.id, "粘原文：按时间顺序落位（10 秒在最后）")
        checkEqual(companion.cueMeta[pasted.id]?.origin, .editedManually, "粘原文：出处人工")
        var translated = f.tb
        translated.id = UUID()
        translated.start = 2.5
        translated.end = 3.5
        SubtitleTrackEditing.insertCue(translated, into: .translation, original: &original, companion: &companion)
        checkEqual(companion.translation?.cues.first { $0.id == translated.id }?.text, f.tb.text, "粘译文：字照带")
        checkEqual(companion.translationLinks[translated.id]?.sourceIDs, [f.b.id], "粘译文：来源 = 重叠最多的那句原文")
        checkEqual(companion.translationLinks[translated.id]?.restructured, true, "粘译文：粘过来的永远不自动更新")
        var empty = f.a
        empty.id = UUID()
        empty.end = empty.start
        check(SubtitleTrackEditing.insertCue(empty, into: .original, original: &original, companion: &companion) == nil,
              "粘一句：零时长拒绝")
    }

    // 拆：只拆这句所在的那条轨。
    do {
        var (original, companion) = f.make()
        let newID = UUID()
        check(SubtitleTrackEditing.splitCue(id: f.a.id, at: 1, newID: newID, texts: ("hello", "there"),
                                            original: &original, companion: &companion), "拆原文：合法拆分点要成功")
        checkEqual(original.cues.map(\.id), [f.a.id, newID, f.b.id, f.c.id], "拆原文：首句留原 ID、次句新 ID")
        checkEqual(original.cues[1].start, 1, "拆原文：后半从拆分点开始")
        checkEqual(companion.translation?.cues.count, 3, "拆原文：译文轨不跟着拆")
        checkEqual(companion.cueMeta[newID]?.recognitionConfidence, nil, "拆原文：后半的置信度作废")
        check(companion.isTranslationStale(f.ta.id, original: original), "拆原文（字变了）：前半的译文过期")
        checkEqual(companion.untranslatedSources(in: original).map(\.id), [newID], "拆原文：后半缺译文")
        check(!SubtitleTrackEditing.splitCue(id: f.b.id, at: 2, original: &original, companion: &companion), "拆：边界上拒绝")

        let tNew = UUID()
        check(SubtitleTrackEditing.splitCue(id: f.tb.id, at: 3, newID: tNew, original: &original, companion: &companion),
              "拆译文：要成功")
        checkEqual(companion.translation?.cues.map(\.text), ["你好", "世界", "", "再见"], "拆译文：字留前半、后半空着")
        checkEqual(companion.translationLinks[f.tb.id]?.restructured, true, "拆译文：前半算拆合过")
        checkEqual(companion.translationLinks[tNew]?.sourceIDs, [f.b.id], "拆译文：后半照样认 b 这句原文")
        checkEqual(original.cues.count, 4, "拆译文：原文轨不动")
    }

    // 合并：只合同一条轨上的；原文合并后，指向被并掉的那句的译文改指向留下的这句。
    do {
        var (original, companion) = f.make()
        check(!SubtitleTrackEditing.mergeCues(ids: [f.a.id, f.tb.id], original: &original, companion: &companion),
              "合并：跨两条轨拒绝")
        check(SubtitleTrackEditing.mergeCues(ids: [f.b.id, f.a.id], original: &original, companion: &companion),
              "合并原文：两句要能合")
        checkEqual(original.cues.map(\.id), [f.a.id, f.c.id], "合并原文：沿用文档序首句的 ID")
        checkEqual(original.cues[0].text, "hello there world", "合并原文：字拼起来")
        checkEqual(original.cues[0].end, 4, "合并原文：时间取并集")
        checkEqual(companion.translation?.cues.count, 3, "合并原文：译文轨不跟着合")
        checkEqual(companion.translationLinks[f.tb.id]?.sourceIDs, [f.a.id], "合并原文：tb 的来源改指向留下的 a")

        check(SubtitleTrackEditing.mergeCues(ids: [f.ta.id, f.tb.id], original: &original, companion: &companion),
              "合并译文：两句要能合")
        checkEqual(companion.translation?.cues.first?.text, "你好 世界", "合并译文：字拼起来")
        checkEqual(companion.translationLinks[f.ta.id]?.restructured, true, "合并译文：算拆合过")
        checkEqual(companion.translationLinks[f.tb.id], nil, "合并译文：被并掉的来源删掉")
        checkEqual(original.cues.count, 2, "合并译文：原文轨不动")
    }
}

private func checkTrackMigration(_ f: TrackFixture) {
    // 老工程：译文与原文同 ID 的镜像对 → 拆开。
    let original = SubtitleDocumentModel(cues: [f.a, f.b])
    var mirror = SubtitleDocumentModel(cues: [f.a, f.b, SubtitleCue(start: 9, end: 10, text: "坏数据")])
    mirror.cues[0].text = "你好"
    mirror.cues[1].text = "世界"
    var legacy = SubtitleCompanion(
        translation: mirror, cueMeta: [f.a.id: CueMeta(), f.b.id: CueMeta(translationStale: true)]
    )
    let fresh = [UUID(), UUID()]
    var feed = fresh.makeIterator()
    legacy.splitMirroredTranslation(original: original, newID: { feed.next()! })
    checkEqual(legacy.translation?.cues.map(\.id), fresh, "老工程：每句译文换新 ID（对不上原文的坏数据丢掉）")
    checkEqual(legacy.translationLinks[fresh[0]]?.sourceIDs, [f.a.id], "老工程：来源记成原来那句原文")
    checkEqual(legacy.translationLinks[fresh[0]]?.sourceText, f.a.text, "老工程：翻的时候的原文 = 现在的原文")
    check(!legacy.isTranslationStale(fresh[0], original: original), "老工程：没标过期的照旧不过期")
    check(legacy.isTranslationStale(fresh[1], original: original), "老工程：标过过期的照样过期")
    checkEqual(legacy.cueMeta[f.b.id]?.translationStale, false, "老工程：旧的过期标记清掉")
    check(!legacy.hasManualTranslationEdits, "老工程：迁移出来的不算手改")

    // 规范化：译文 ID 撞原文的换新；来源表 / meta 只留还在的；空译文轨归 nil。
    var collided = SubtitleCompanion(
        translation: SubtitleDocumentModel(cues: [SubtitleCue(id: f.a.id, start: 0, end: 1, text: "撞了")]),
        cueMeta: [UUID(): CueMeta()],
        translationLinks: [f.a.id: TranslationLink(sourceIDs: [f.a.id], sourceText: "x"), UUID(): TranslationLink(sourceIDs: [], sourceText: nil)]
    )
    let replacement = UUID()
    collided.normalize(originalCueIDs: [f.a.id], newID: { replacement })
    checkEqual(collided.translation?.cues.first?.id, replacement, "规范化：撞了原文 ID 的译文换新 ID")
    checkEqual(collided.translationLinks.keys.sorted { $0.uuidString < $1.uuidString }, [replacement], "规范化：来源表跟着换键、孤儿清掉")
    check(collided.cueMeta.isEmpty, "规范化：孤儿 meta 清掉")
    var emptied = SubtitleCompanion(translation: SubtitleDocumentModel(cues: []))
    emptied.normalize(originalCueIDs: [])
    checkEqual(emptied.translation, nil, "规范化：空译文轨归 nil")
    check(!SubtitleCompanion().hasPersistentData, "空 companion 不算持久数据")
    check(SubtitleCompanion(translationLinks: [UUID(): TranslationLink(sourceIDs: [], sourceText: nil)]).hasPersistentData,
          "只有来源表也算持久数据")
}

private func checkTrackCodable(_ f: TrackFixture) {
    do {
        // 来源表：键是 uuidString；坏 ID 丢掉；缺的布尔取 false；为真的布尔才落键。
        let json = """
        {"translationLinks": {"not-a-uuid": {"sourceIDs": []},
          "6BA7B810-9DAD-11D1-80B4-00C04FD430C8": {"sourceIDs": ["bad", "6BA7B811-9DAD-11D1-80B4-00C04FD430C8"], "timeEdited": true}}}
        """
        let decoded = try JSONDecoder().decode(SubtitleCompanion.self, from: Data(json.utf8))
        checkEqual(decoded.translationLinks.count, 1, "来源表：坏 UUID 键丢掉")
        let link = decoded.translationLinks[UUID(uuidString: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8")!]
        checkEqual(link?.sourceIDs.map(\.uuidString), ["6BA7B811-9DAD-11D1-80B4-00C04FD430C8"], "来源表：坏的来源 ID 丢掉")
        checkEqual(link?.timeEdited, true, "来源表：认识的字段照常解")
        checkEqual(link?.restructured, false, "来源表：缺的布尔取 false")
        checkEqual(link?.sourceText, nil, "来源表：缺的原文 = 不知道")

        let (_, companion) = f.make()
        var edited = companion
        edited.translationLinks[f.ta.id]?.textEdited = true
        let data = try JSONEncoder().encode(edited)
        checkEqual(try JSONDecoder().decode(SubtitleCompanion.self, from: data), edited, "companion（含来源表）往返无损")
        let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let links = raw?["translationLinks"] as? [String: [String: Any]]
        check(links?[f.ta.id.uuidString]?["textEdited"] as? Bool == true, "来源表：为真的布尔落键")
        check(links?[f.tb.id.uuidString]?["textEdited"] == nil, "来源表：为假的布尔不落键")
    } catch {
        check(false, "来源表编解码抛错：\(error)")
    }
}
