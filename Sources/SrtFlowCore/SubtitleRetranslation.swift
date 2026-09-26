import Foundation

// MARK: - 重译：送哪几句、回来怎么落
//
// 管什么：两个翻译按钮各自把哪几句原文送去翻，翻回来的字怎么落进译文轨（换哪句、补哪句、删哪句、
// 时间跟不跟原文走）。纯函数，调用方（`SubtitleTranslationService` → `VideoEditProject.applyTranslations`）
// 在一次 perform 里调，一步撤销。
// 不管什么：真去翻译（Translation 框架）、翻译期间原文被改了怎么丢结果（服务那边按快照过滤）。
//
// 用户拍的板（2026-09-26，docs/plans/2026-09-26-hide-guides-independent-subtitles.md）：
// - 「全部翻译」= 清空译文轨、整条重建（有手改过的，界面上先确认 —— `hasManualTranslationEdits`）。
// - 「只翻缺的和改过的」= 只补还没有译文的句子、只换原文改过字的句子；**原文没改的句子，连手改过的
//   译文字也不动**；不动用户调过的时间，没动过时间的跟着原文的新时间走（原文拆句后，两句译文各跟各的，
//   不会叠在一起）；用户拆过 / 合并过 / 自己加的译文不再自动更新。

public enum SubtitleRetranslation {

    public enum Scope: Equatable, Sendable {
        /// 清空译文轨、整条重建。
        case all
        /// 只补缺的、只换原文改过字的。
        case missingAndStale
    }

    /// 这一轮要送去翻的原文句，按原文轨的顺序；空句不送。
    public static func sources(
        for scope: Scope, original: SubtitleDocumentModel?, companion: SubtitleCompanion?
    ) -> [SubtitleCue] {
        let cues = (original?.cues ?? []).filter { !SubtitleSerializer.plainText($0.text).isEmpty }
        guard scope == .missingAndStale, let companion else { return cues }
        let covered = companion.coveredSourceIDs
        var staleSources: Set<UUID> = []
        for cue in companion.translation?.cues ?? [] where companion.isTranslationStale(cue.id, original: original) {
            if let source = companion.translationLinks[cue.id]?.sourceIDs.first { staleSources.insert(source) }
        }
        return cues.filter { !covered.contains($0.id) || staleSources.contains($0.id) }
    }

    /// 把翻回来的字落进译文轨。
    ///
    /// - Parameters:
    ///   - results: 原文 cue 的 ID → 译文。调用方已经按快照滤掉了「翻译期间原文被改过」的句子。
    ///   - snapshot: 送去翻的时候那几句原文的字，记进来源表（之后原文再改，这句就现算成过期）。
    ///   - newID: 新建译文句的 ID（自检里要固定下来）。
    public static func apply(
        _ results: [UUID: String], snapshot: [UUID: String], scope: Scope,
        original: SubtitleDocumentModel, companion: inout SubtitleCompanion,
        newID: () -> UUID = { UUID() }
    ) {
        var doc = companion.translation ?? SubtitleDocumentModel(format: original.format)
        if scope == .all {
            doc.cues = []
            companion.translationLinks = [:]
        }
        let covered = companion.coveredSourceIDs
        for source in original.cues {
            guard let text = results[source.id] else { continue }
            let sourceText = snapshot[source.id] ?? source.text
            // 这句原文名下还会自动更新的译文，按时间先后。
            let followers = doc.cues
                .filter { cue in
                    guard let link = companion.translationLinks[cue.id] else { return false }
                    return link.followsSource && link.sourceIDs[0] == source.id
                }
                .sorted { $0.start < $1.start }
            if let first = followers.first, let i = doc.cues.firstIndex(where: { $0.id == first.id }) {
                var link = companion.translationLinks[first.id]!
                doc.cues[i].text = text
                if !link.timeEdited {
                    doc.cues[i].start = source.start
                    doc.cues[i].end = source.end
                }
                link.sourceText = sourceText
                link.textEdited = false
                companion.translationLinks[first.id] = link
                // 同一句原文底下还有别的会自动更新的译文（原文合并过）：收成一句。用户挪过 / 改过的留着。
                let extras = followers.dropFirst().filter { cue in
                    let link = companion.translationLinks[cue.id]
                    return link?.timeEdited != true && link?.textEdited != true
                }.map(\.id)
                doc.removeCues(ids: Set(extras))
                for id in extras { companion.translationLinks.removeValue(forKey: id) }
            } else if !covered.contains(source.id) || scope == .all {
                let id = newID()
                doc.cues.append(SubtitleCue(id: id, start: source.start, end: source.end, text: text))
                companion.translationLinks[id] = TranslationLink(sourceIDs: [source.id], sourceText: sourceText)
            }
            // 其余：这句原文只被拆合过 / 用户自己加的译文认领着 —— 不自动更新，什么也不做。
        }
        SubtitleTrackEditing.normalizeOrder(&doc)
        companion.translation = doc.cues.isEmpty ? nil : doc
    }
}
