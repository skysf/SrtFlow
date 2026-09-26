import Foundation

// MARK: - 两条字幕轨的编辑合同
//
// 管什么：改时间、改字、删、加、整体平移、拆、合并 —— 每一样只动这句所在的那条轨，
// 外加各自那张旁表（原文的 `cueMeta`、译文的来源表 `translationLinks`）怎么跟着记。
// 不管什么：重译怎么落（`SubtitleRetranslation`）、「过期 / 缺译文」怎么算（SubtitleTranslationLink.swift）。
//
// 2026-09-26 起两条轨独立（docs/plans/2026-09-26-hide-guides-independent-subtitles.md）：
// 以前这里是 `LinkedSubtitleEditing`，改一条轨的时间 / 删 / 拆 / 合并都两轨一起动（译文是原文的镜像）。
// 现在原文、译文各自的身份和时间，**挪 / 裁 / 删 / 拆 / 合并互不影响**；唯一的联系是来源表。
//
// 全部是纯函数：调用方（VideoEditProject）在一次 perform 里调，保证一步撤销。
// 两条轨上的 ID 互不相同（`SubtitleCompanion.normalize` 兜底），所以「这句在哪条轨」按 ID 找得到。

/// 字幕的哪条轨。只有两条（多语言不做）。
public enum SubtitleTrack: String, Hashable, Sendable, CaseIterable {
    case original
    case translation
}

public enum SubtitleTrackEditing {

    /// 这句在哪条轨上；哪条都没有就是 nil。
    public static func track(
        of id: UUID, original: SubtitleDocumentModel?, companion: SubtitleCompanion?
    ) -> SubtitleTrack? {
        if original?.cues.contains(where: { $0.id == id }) == true { return .original }
        if companion?.translation?.cues.contains(where: { $0.id == id }) == true { return .translation }
        return nil
    }

    /// 改时间。**改完必须重排 + 重编号**：`cues` 的数组顺序就是时间顺序，下游全按顺序消费
    /// （`cue(at:)` 取第一条命中的、序列化按数组写、字幕表按数组显示）。译文记「时间手动改过」——
    /// 之后重译换字时不再动它的时间。
    public static func setTime(
        id: UUID, start: TimeInterval, end: TimeInterval,
        original: inout SubtitleDocumentModel, companion: inout SubtitleCompanion
    ) {
        if let i = original.cues.firstIndex(where: { $0.id == id }) {
            original.cues[i].start = start
            original.cues[i].end = end
            normalizeOrder(&original)
        } else if var doc = companion.translation, let t = doc.cues.firstIndex(where: { $0.id == id }) {
            let moved = doc.cues[t].start != start || doc.cues[t].end != end
            doc.cues[t].start = start
            doc.cues[t].end = end
            normalizeOrder(&doc)
            companion.translation = doc
            if moved { companion.translationLinks[id]?.timeEdited = true }
        }
    }

    /// 改字。
    /// - 原文：这句的识别置信度不再可靠（置 nil）、出处记成人工。它的译文会**现算成过期**（不用打标记）。
    /// - 译文：这句跟上了现在的原文（`sourceText` 换成原文现在的字，不再过期），并记「字手改过」。
    public static func setText(
        id: UUID, text: String,
        original: inout SubtitleDocumentModel, companion: inout SubtitleCompanion
    ) {
        if let i = original.cues.firstIndex(where: { $0.id == id }) {
            guard original.cues[i].text != text else { return }
            original.cues[i].text = text
            var meta = companion.cueMeta[id] ?? CueMeta()
            meta.recognitionConfidence = nil
            meta.origin = .editedManually
            companion.cueMeta[id] = meta
        } else if var doc = companion.translation, let t = doc.cues.firstIndex(where: { $0.id == id }) {
            guard doc.cues[t].text != text else { return }
            doc.cues[t].text = text
            companion.translation = doc
            guard var link = companion.translationLinks[id] else { return }
            link.textEdited = true
            if link.followsSource, let source = original.cues.first(where: { $0.id == link.sourceIDs[0] }) {
                link.sourceText = source.text
            }
            companion.translationLinks[id] = link
        }
    }

    /// 删除。两条轨上各删各的（这批 ID 在哪条轨上就从哪条删），旁表同删。
    /// 原文删了，指向它的译文**不跟着删**（来源悬空，重译不碰它）。
    public static func removeCues(
        ids: Set<UUID>,
        original: inout SubtitleDocumentModel, companion: inout SubtitleCompanion
    ) {
        original.removeCues(ids: ids)
        if var doc = companion.translation {
            doc.removeCues(ids: ids)
            companion.translation = doc.cues.isEmpty ? nil : doc
        }
        for id in ids {
            companion.cueMeta.removeValue(forKey: id)
            companion.translationLinks.removeValue(forKey: id)
        }
        companion.hiddenCueIDs.subtract(ids)
    }

    /// 新加一句到指定的轨，按时间顺序插入。返回新 cue 的 ID（时长不为正就是 nil）。
    ///
    /// - 原文轨：出处如实记成人工（不是识别出来的，没有置信度，也没有 provenance）。
    /// - 译文轨：来源记成此刻和它重叠最多的那句原文，并算「拆合过」—— 用户自己写的译文永远
    ///   不自动更新，但那句原文算「有译文了」，「只翻缺的」不会在它旁边再补一句机翻。
    ///   没有重叠的原文就不记来源。译文轨还不存在就新建一条。
    @discardableResult
    public static func insertCue(
        at time: TimeInterval, duration: TimeInterval, id: UUID = UUID(), into track: SubtitleTrack,
        original: inout SubtitleDocumentModel, companion: inout SubtitleCompanion
    ) -> UUID? {
        guard duration > 0 else { return nil }
        let start = max(0, time)
        return insertCue(
            SubtitleCue(id: id, start: start, end: start + duration, text: ""),
            into: track, original: &original, companion: &companion
        )
    }

    /// 同上，但加的是一句现成的字幕（字、样式都带着）—— 时间线上粘贴走这里（上面那个是它的空文本特例）。
    /// 旁表的记法一模一样：原文轨记成人工；译文轨的来源记成重叠最多的那句原文并算「拆合过」，
    /// 粘过来的译文永远不自动更新。时长不为正就不加（nil）；ID 由调用方给（粘贴时已换成新的）。
    @discardableResult
    public static func insertCue(
        _ cue: SubtitleCue, into track: SubtitleTrack,
        original: inout SubtitleDocumentModel, companion: inout SubtitleCompanion
    ) -> UUID? {
        guard cue.end > cue.start else { return nil }
        let id = cue.id
        switch track {
        case .original:
            insert(cue, into: &original)
            companion.cueMeta[id] = CueMeta(origin: .editedManually)
        case .translation:
            var doc = companion.translation ?? SubtitleDocumentModel(format: original.format)
            insert(cue, into: &doc)
            companion.translation = doc
            if let source = mostOverlapping(cue, in: original.cues) {
                companion.translationLinks[id] = TranslationLink(
                    sourceIDs: [source.id], sourceText: source.text, restructured: true
                )
            }
        }
        return id
    }

    /// 整体平移：把这批 cue 挪到指定的起点（时长不变），两条轨上各挪各的。
    ///
    /// 时间线上框选一片再拖动时走这里。**参数是绝对起点，不是增量**：拖动落地那条路径上同一批成员
    /// 可能被写两次（磁吸主轨插空之后要按实际落点再平一次），绝对起点天然幂等。挪完重排。
    /// 真挪动了的译文记「时间手动改过」。
    public static func setStarts(
        _ starts: [UUID: TimeInterval],
        original: inout SubtitleDocumentModel, companion: inout SubtitleCompanion
    ) {
        guard !starts.isEmpty else { return }
        _ = setStarts(starts, in: &original)
        if var doc = companion.translation {
            for id in setStarts(starts, in: &doc) { companion.translationLinks[id]?.timeEdited = true }
            companion.translation = doc
        }
    }

    /// 拆成两句：首句保留原 ID，次句用 `newID`，只拆这句所在的那条轨。拆分点必须严格落在句子内部。
    /// 文字默认整句留在前半、后半空着（可用 `texts` 指定两半）。
    /// - 原文：两半的置信度都作废（`cueMeta` 抄一份给后半）；它们的译文照样各自现算过期 / 缺。
    /// - 译文：两半都算「拆合过」，从此不自动更新（来源照留，那句原文仍算有译文）。
    /// 藏起来的句子拆完两半都藏着。
    @discardableResult
    public static func splitCue(
        id: UUID, at time: TimeInterval, newID: UUID = UUID(),
        texts: (first: String, second: String)? = nil,
        original: inout SubtitleDocumentModel, companion: inout SubtitleCompanion
    ) -> Bool {
        if original.cues.contains(where: { $0.id == id }) {
            guard split(id: id, at: time, newID: newID, texts: texts, in: &original) else { return false }
            var meta = companion.cueMeta[id] ?? CueMeta()
            meta.recognitionConfidence = nil
            companion.cueMeta[id] = meta
            companion.cueMeta[newID] = meta
            if companion.hiddenCueIDs.contains(id) { companion.hiddenCueIDs.insert(newID) }
            return true
        }
        guard var doc = companion.translation,
              split(id: id, at: time, newID: newID, texts: texts, in: &doc) else { return false }
        companion.translation = doc
        if var link = companion.translationLinks[id] {
            link.restructured = true
            companion.translationLinks[id] = link
            companion.translationLinks[newID] = link
        }
        if companion.hiddenCueIDs.contains(id) { companion.hiddenCueIDs.insert(newID) }
        return true
    }

    /// 合并：**只合同一条轨上的**（跨两条轨返回 false）。沿用文档顺序的第一句的 ID，文字按顺序以空格拼、
    /// 时间取并集。
    /// - 原文：被并掉的那几句原文，指向它们的译文来源改指向留下的这句（重译时它们会被收成一句，
    ///   见 `SubtitleRetranslation`）；留下这句的置信度作废。
    /// - 译文：来源取并集、算「拆合过」，从此不自动更新。
    /// 合出来的这句只有在并进来的全都藏着时才藏着（有一句看得见，合完就看得见）。
    @discardableResult
    public static func mergeCues(
        ids: Set<UUID>,
        original: inout SubtitleDocumentModel, companion: inout SubtitleCompanion
    ) -> Bool {
        let inOriginal = original.cues.filter { ids.contains($0.id) }.count
        let inTranslation = (companion.translation?.cues ?? []).filter { ids.contains($0.id) }.count
        if inOriginal >= 2, inTranslation == 0 {
            guard let (kept, dropped) = merge(ids: ids, in: &original) else { return false }
            mergeHidden(kept: kept, dropped: dropped, companion: &companion)
            var meta = companion.cueMeta[kept] ?? CueMeta()
            meta.recognitionConfidence = nil
            companion.cueMeta[kept] = meta
            for id in dropped { companion.cueMeta.removeValue(forKey: id) }
            for (key, var link) in companion.translationLinks where link.sourceIDs.contains(where: { dropped.contains($0) }) {
                link.sourceIDs = uniqued(link.sourceIDs.map { dropped.contains($0) ? kept : $0 })
                companion.translationLinks[key] = link
            }
            return true
        }
        guard inTranslation >= 2, inOriginal == 0, var doc = companion.translation,
              let (kept, dropped) = merge(ids: ids, in: &doc) else { return false }
        companion.translation = doc
        mergeHidden(kept: kept, dropped: dropped, companion: &companion)
        let links = ([kept] + dropped).compactMap { companion.translationLinks[$0] }
        for id in dropped { companion.translationLinks.removeValue(forKey: id) }
        if !links.isEmpty {
            companion.translationLinks[kept] = TranslationLink(
                sourceIDs: uniqued(links.flatMap(\.sourceIDs)), sourceText: nil,
                restructured: true, timeEdited: links.contains(where: \.timeEdited),
                textEdited: links.contains(where: \.textEdited)
            )
        }
        return true
    }

    // MARK: - 共用的小件

    /// 按时间稳定排序 + 重编号。**稳定**很重要：起点相同的两条要保持原有先后，
    /// 不然每挪一次顺序都可能翻个个儿。
    static func normalizeOrder(_ doc: inout SubtitleDocumentModel) {
        doc.cues = doc.cues.enumerated()
            .sorted { $0.element.start == $1.element.start ? $0.offset < $1.offset : $0.element.start < $1.element.start }
            .map(\.element)
        doc.reindex()
    }

    static func insert(_ cue: SubtitleCue, into doc: inout SubtitleDocumentModel) {
        let insertAt = doc.cues.firstIndex { $0.start > cue.start } ?? doc.cues.count
        doc.cues.insert(cue, at: insertAt)
        doc.reindex()
    }

    /// 和 `cue` 在时间上重叠最多的那句（没有重叠就是 nil）。
    static func mostOverlapping(_ cue: SubtitleCue, in cues: [SubtitleCue]) -> SubtitleCue? {
        var best: (cue: SubtitleCue, overlap: TimeInterval)?
        for other in cues {
            let overlap = min(cue.end, other.end) - max(cue.start, other.start)
            if overlap > 0, overlap > (best?.overlap ?? 0) { best = (other, overlap) }
        }
        return best?.cue
    }

    /// 返回真挪动了的 ID。
    private static func setStarts(_ starts: [UUID: TimeInterval], in doc: inout SubtitleDocumentModel) -> [UUID] {
        var moved: [UUID] = []
        for i in doc.cues.indices {
            guard let start = starts[doc.cues[i].id] else { continue }
            let duration = doc.cues[i].end - doc.cues[i].start
            let next = max(0, start)
            if next != doc.cues[i].start { moved.append(doc.cues[i].id) }
            doc.cues[i].start = next
            doc.cues[i].end = next + duration
        }
        if !moved.isEmpty { normalizeOrder(&doc) }
        return moved
    }

    private static func split(
        id: UUID, at time: TimeInterval, newID: UUID, texts: (first: String, second: String)?,
        in doc: inout SubtitleDocumentModel
    ) -> Bool {
        guard let i = doc.cues.firstIndex(where: { $0.id == id }),
              time > doc.cues[i].start, time < doc.cues[i].end else { return false }
        var second = doc.cues[i]
        second.id = newID
        second.start = time
        doc.cues[i].end = time
        if let texts {
            doc.cues[i].text = texts.first
            second.text = texts.second
        } else {
            second.text = ""
        }
        doc.cues.insert(second, at: i + 1)
        doc.reindex()
        return true
    }

    /// 合并这条轨上的这批句子。返回（留下的 ID，被并掉的 ID）；不足两句就是 nil。
    private static func merge(ids: Set<UUID>, in doc: inout SubtitleDocumentModel) -> (UUID, [UUID])? {
        let picked = doc.cues.enumerated().filter { ids.contains($0.element.id) }
        guard picked.count >= 2 else { return nil }
        let keptIndex = picked[0].offset
        let kept = picked[0].element.id
        doc.cues[keptIndex].start = picked.map(\.element.start).min() ?? picked[0].element.start
        doc.cues[keptIndex].end = picked.map(\.element.end).max() ?? picked[0].element.end
        doc.cues[keptIndex].text = picked.map(\.element.text).filter { !$0.isEmpty }.joined(separator: " ")
        let dropped = picked.dropFirst().map(\.element.id)
        doc.removeCues(ids: Set(dropped))
        normalizeOrder(&doc)
        return (kept, dropped)
    }

    private static func mergeHidden(kept: UUID, dropped: [UUID], companion: inout SubtitleCompanion) {
        let allHidden = ([kept] + dropped).allSatisfy { companion.hiddenCueIDs.contains($0) }
        companion.hiddenCueIDs.subtract(dropped)
        if !allHidden { companion.hiddenCueIDs.remove(kept) }
    }

    private static func uniqued(_ ids: [UUID]) -> [UUID] {
        var seen: Set<UUID> = []
        return ids.filter { seen.insert($0).inserted }
    }
}
