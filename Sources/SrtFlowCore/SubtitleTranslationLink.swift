import Foundation

// MARK: - 译文从哪来：来源表
//
// 管什么：译文轨上每一句「是从哪几句原文翻来的、翻的时候原文是什么字、用户动过它什么」，
// 以及由此现算的三件事 —— 这句译文过期没有、哪几句原文还没有译文、有没有手改过的译文；
// 还有老工程（译文与原文同 ID 的镜像对）打开时怎么拆开。
// 不管什么：怎么编辑（`SubtitleTrackEditing`）、重译怎么落（`SubtitleRetranslation`）。
//
// 2026-09-26 字幕拆成两条独立轨（docs/plans/2026-09-26-hide-guides-independent-subtitles.md）：
// 译文 cue 有了自己的 ID 和时间，「这句译文对应哪句原文」不能再靠 ID 相等，改记在这张旁表里
// （键是**译文** cue 的 ID）。放旁表是为了不动 `SubtitleCue` 的存盘格式 —— `cueMeta` 同一个做法。

/// 一句译文的来源。
public struct TranslationLink: Hashable, Sendable {
    /// 从哪几句原文翻来的（原文 cue 的 ID）。一般一句；合并过的译文可能不止一句。
    /// 原文被删了这里就悬空（译文不跟着删，重译也不碰它）。
    public var sourceIDs: [UUID]
    /// 翻的时候（或手改译文的时候）那句原文是什么字。和现在的原文不一样 = 原文改过、这句过期。
    /// nil = 不知道（老工程里标过「过期」的），按过期算。
    public var sourceText: String?
    /// 用户拆过 / 合并过这句，或者它是用户自己在译文轨上加的：**不再自动更新**（重译不碰它），
    /// 但它的来源仍算「有译文了」（不然「只翻缺的」会在它旁边再补一句机翻叠在一起）。
    public var restructured: Bool
    /// 用户挪过 / 裁过它的时间：重译换字时不动它的时间。没动过的跟着原文的新时间走。
    public var timeEdited: Bool
    /// 用户手改过它的字。只用来判断「全部重译」之前要不要先确认。
    public var textEdited: Bool

    public init(
        sourceIDs: [UUID],
        sourceText: String?,
        restructured: Bool = false,
        timeEdited: Bool = false,
        textEdited: Bool = false
    ) {
        self.sourceIDs = sourceIDs
        self.sourceText = sourceText
        self.restructured = restructured
        self.timeEdited = timeEdited
        self.textEdited = textEdited
    }

    /// 会跟着原文自动更新吗：来源正好一句、没被拆合过。
    public var followsSource: Bool { sourceIDs.count == 1 && !restructured }

    /// 用户动过它没有（拆合、挪时间、改字任何一样）。
    public var isManual: Bool { restructured || timeEdited || textEdited }
}

extension SubtitleCompanion {

    /// 译文 cue `id` 过期了吗：会自动更新、来源那句原文还在、翻的时候的字和现在不一样（或不知道）。
    /// 「过期」不存标记、每次现算 —— 存标记要在每个改原文的入口记得打，现算只有这一处。
    public func isTranslationStale(_ id: UUID, original: SubtitleDocumentModel?) -> Bool {
        guard let link = translationLinks[id], link.followsSource,
              let source = original?.cues.first(where: { $0.id == link.sourceIDs[0] }) else { return false }
        return link.sourceText != source.text
    }

    /// 被某句译文「认领」了的原文 ID（不管那句译文还会不会自动更新）。
    public var coveredSourceIDs: Set<UUID> {
        let live = Set((translation?.cues ?? []).map(\.id))
        var covered: Set<UUID> = []
        for (id, link) in translationLinks where live.contains(id) {
            covered.formUnion(link.sourceIDs)
        }
        return covered
    }

    /// 还没有任何译文认领的原文句（有字的才算：空句没什么可翻）。按原文轨的顺序。
    public func untranslatedSources(in original: SubtitleDocumentModel?) -> [SubtitleCue] {
        let covered = coveredSourceIDs
        return (original?.cues ?? []).filter {
            !covered.contains($0.id) && !SubtitleSerializer.plainText($0.text).isEmpty
        }
    }

    /// 有没有用户动过的译文：自己加的（没有来源）、拆合过、挪过时间、改过字。
    /// 「全部重译」会把整条译文轨清空重建，有这些就要先问一声。
    public var hasManualTranslationEdits: Bool {
        (translation?.cues ?? []).contains { cue in
            guard let link = translationLinks[cue.id] else { return true }
            return link.isManual
        }
    }

    // MARK: - 老工程：镜像对拆开

    /// v22 及更早的工程里，译文 cue 与原文**同 ID、同时间**（镜像对）。打开时拆成两条独立轨：
    /// 每句译文换一个新 ID，来源记成原来那句原文，「翻的时候的原文」记成现在的原文 ——
    /// 当年标过「过期」的记成 nil（不知道），照样算过期。`cueMeta` 里的过期标记随之清掉。
    ///
    /// 先按老规矩清坏数据：译文轨上对不上原文 ID 的句子本来就是坏数据（老规矩是当场丢）。
    public mutating func splitMirroredTranslation(
        original: SubtitleDocumentModel?, newID: () -> UUID = { UUID() }
    ) {
        let originals = Dictionary((original?.cues ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        if var doc = translation {
            doc.cues.removeAll { originals[$0.id] == nil }
            translationLinks = [:]
            for i in doc.cues.indices {
                let sourceID = doc.cues[i].id
                let stale = cueMeta[sourceID]?.translationStale ?? false
                let fresh = newID()
                doc.cues[i].id = fresh
                translationLinks[fresh] = TranslationLink(
                    sourceIDs: [sourceID], sourceText: stale ? nil : originals[sourceID]?.text
                )
            }
            doc.reindex()
            translation = doc.cues.isEmpty ? nil : doc
        }
        for id in cueMeta.keys { cueMeta[id]?.translationStale = false }
    }
}

// MARK: - 宽容 Codable

extension TranslationLink: Codable {
    private enum CodingKeys: String, CodingKey {
        case sourceIDs, sourceText, restructured, timeEdited, textEdited
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // 解不出的 ID 直接丢（和 cueMeta 的键同一个宽容口径）。
        let raw = try c.decodeIfPresent([String].self, forKey: .sourceIDs) ?? []
        self.init(
            sourceIDs: raw.compactMap(UUID.init(uuidString:)),
            sourceText: try c.decodeIfPresent(String.self, forKey: .sourceText),
            restructured: try c.decodeIfPresent(Bool.self, forKey: .restructured) ?? false,
            timeEdited: try c.decodeIfPresent(Bool.self, forKey: .timeEdited) ?? false,
            textEdited: try c.decodeIfPresent(Bool.self, forKey: .textEdited) ?? false
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sourceIDs.map(\.uuidString), forKey: .sourceIDs)
        try c.encodeIfPresent(sourceText, forKey: .sourceText)
        // 布尔只在为真时落键：大多数译文一样都没动过。
        if restructured { try c.encode(true, forKey: .restructured) }
        if timeEdited { try c.encode(true, forKey: .timeEdited) }
        if textEdited { try c.encode(true, forKey: .textEdited) }
    }
}
