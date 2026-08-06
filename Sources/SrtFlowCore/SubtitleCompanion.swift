import Foundation

// 关联字幕的伴随状态（docs/plans/2026-08-06-native-subtitle-generation.md 第 7、8 节）。
//
// canonical 原文轨永远是 `TimelineState.subtitle`；这里只存原文之外的关联数据：
// 译文轨、语言、每条 cue 的元数据（旁表）、生成参数快照。**不重复保存原文。**
// 译文 cue 与原文 cue 用同一个 `SubtitleCue.id` 关联 —— 关联身份即 ID 相等。
//
// 存盘格式是长期格式，全部手写宽容解码（缺字段取默认、坏枚举退兜底），
// 与 VideoEditModels.swift 的既有约定一致；本文件属 SrtFlowCore，
// 不依赖那边的 LenientCodableEnum 协议，枚举各自内联兜底。

// MARK: - cue 元数据

/// cue 的出处：哪个素材、哪个 clip、素材源时间的哪一段。
/// 用于重叠 cue 排序（计划第 9 节）、诊断与局部重新生成。
public struct CueProvenance: Hashable, Sendable {
    public var sourceAssetFingerprint: String?
    public var clipID: UUID?
    public var sourceStart: Double?
    public var sourceEnd: Double?

    public init(
        sourceAssetFingerprint: String? = nil,
        clipID: UUID? = nil,
        sourceStart: Double? = nil,
        sourceEnd: Double? = nil
    ) {
        self.sourceAssetFingerprint = sourceAssetFingerprint
        self.clipID = clipID
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
    }
}

public enum CueOrigin: String, Hashable, Sendable {
    case generated
    case editedManually
}

public struct CueMeta: Hashable, Sendable {
    /// 识别置信度（0–1）。人工改过原文后不再可靠，置 nil。
    public var recognitionConfidence: Double?
    /// 原文改动后译文过期的标记；人工修正译文时清掉。
    public var translationStale: Bool
    public var origin: CueOrigin
    /// 极端变速下阅读速度无解时的告警标记（分段器如实打标，不假装满足约束）。
    public var readingSpeedWarning: Bool
    public var provenance: CueProvenance?

    public init(
        recognitionConfidence: Double? = nil,
        translationStale: Bool = false,
        origin: CueOrigin = .generated,
        readingSpeedWarning: Bool = false,
        provenance: CueProvenance? = nil
    ) {
        self.recognitionConfidence = recognitionConfidence
        self.translationStale = translationStale
        self.origin = origin
        self.readingSpeedWarning = readingSpeedWarning
        self.provenance = provenance
    }
}

// MARK: - companion 本体

public enum SubtitleCompanionOrigin: String, Hashable, Sendable {
    /// 原文来自外挂/导入文件，companion 只是给它配的翻译。
    case imported
    /// 原文来自语音生成。
    case generated
}

/// 生成参数快照：重新生成时按它恢复设置；不含任务运行态。
public struct GenerationSnapshot: Hashable, Sendable {
    public var module: String?
    public var segmentationConfigVersion: Int?
    public var generatedAt: Date?

    public init(module: String? = nil, segmentationConfigVersion: Int? = nil, generatedAt: Date? = nil) {
        self.module = module
        self.segmentationConfigVersion = segmentationConfigVersion
        self.generatedAt = generatedAt
    }
}

public struct SubtitleCompanion: Hashable, Sendable {
    /// 译文轨。cue 与原文轨同 ID、同 start/end（硬约束，见 LinkedSubtitleEditing）。
    public var translation: SubtitleDocumentModel?
    /// BCP-47，如 "zh-Hans"。
    public var targetLanguage: String?
    public var sourceLanguage: String?
    public var origin: SubtitleCompanionOrigin
    public var generation: GenerationSnapshot?
    /// cue 元数据旁表，键 = 原文 cue 的 ID。不改动 SubtitleCue 的既有 Codable。
    public var cueMeta: [UUID: CueMeta]

    public init(
        translation: SubtitleDocumentModel? = nil,
        targetLanguage: String? = nil,
        sourceLanguage: String? = nil,
        origin: SubtitleCompanionOrigin = .generated,
        generation: GenerationSnapshot? = nil,
        cueMeta: [UUID: CueMeta] = [:]
    ) {
        self.translation = translation
        self.targetLanguage = targetLanguage
        self.sourceLanguage = sourceLanguage
        self.origin = origin
        self.generation = generation
        self.cueMeta = cueMeta
    }

    /// 是否存有「旧版打开会被静默丢掉」的数据 —— formatVersion 按需写 4 的判据之一。
    /// origin 单独不算数据：没有任何实质字段时整个 companion 视同不存在。
    public var hasPersistentData: Bool {
        translation != nil || !cueMeta.isEmpty || generation != nil
            || sourceLanguage != nil || targetLanguage != nil
    }

    /// 规范化（读盘后调用）：
    /// - 译文轨只保留与原文同 ID 的 cue（关联身份即 ID，对不上的属坏数据）；
    /// - 删除两轨都没有对应 cue 的孤儿 meta；
    /// - 译文轨清空后归 nil。
    public mutating func normalize(originalCueIDs: Set<UUID>) {
        if var doc = translation {
            doc.cues.removeAll { !originalCueIDs.contains($0.id) }
            doc.reindex()
            translation = doc.cues.isEmpty ? nil : doc
        }
        cueMeta = cueMeta.filter { originalCueIDs.contains($0.key) }
    }
}

// MARK: - 关联编辑合同（计划第 8 节）

/// 双轨（原文 + 译文）与 cueMeta 的联动编辑，全部纯函数：
/// 调用方（VideoEditProject）在一次 perform 事务里调用，保证一步撤销。
/// meta 的维护规则集中在这里（计划 7.3），调用方不得散落手改。
public enum LinkedSubtitleEditing {

    /// 规则 1：改时间 —— 两轨同 ID cue 改成相同时间。
    public static func setTime(
        id: UUID, start: TimeInterval, end: TimeInterval,
        original: inout SubtitleDocumentModel, companion: inout SubtitleCompanion
    ) {
        guard let i = original.cues.firstIndex(where: { $0.id == id }) else { return }
        original.cues[i].start = start
        original.cues[i].end = end
        if var doc = companion.translation,
           let t = doc.cues.firstIndex(where: { $0.id == id }) {
            doc.cues[t].start = start
            doc.cues[t].end = end
            companion.translation = doc
        }
    }

    /// 规则 2：改原文文本 —— 同 ID 译文标过期；本条置信度不再可靠，置 nil。
    public static func setOriginalText(
        id: UUID, text: String,
        original: inout SubtitleDocumentModel, companion: inout SubtitleCompanion
    ) {
        guard let i = original.cues.firstIndex(where: { $0.id == id }),
              original.cues[i].text != text else { return }
        original.cues[i].text = text
        var meta = companion.cueMeta[id] ?? CueMeta()
        meta.translationStale = companion.translation?.cues.contains { $0.id == id } ?? false
        meta.recognitionConfidence = nil
        meta.origin = .editedManually
        companion.cueMeta[id] = meta
    }

    /// 规则 3：改译文文本 —— 清自己的 stale（视为人工修正）。
    /// 译文轨存在但缺这条 cue 时按原文时间补一条（人工补译）。译文轨不存在则不动。
    public static func setTranslationText(
        id: UUID, text: String,
        original: inout SubtitleDocumentModel, companion: inout SubtitleCompanion
    ) {
        guard var doc = companion.translation,
              let source = original.cues.first(where: { $0.id == id }) else { return }
        if let t = doc.cues.firstIndex(where: { $0.id == id }) {
            doc.cues[t].text = text
        } else {
            var cue = source
            cue.text = text
            let insertAt = doc.cues.firstIndex { $0.start > source.start } ?? doc.cues.count
            doc.cues.insert(cue, at: insertAt)
            doc.reindex()
        }
        companion.translation = doc
        var meta = companion.cueMeta[id] ?? CueMeta()
        meta.translationStale = false
        companion.cueMeta[id] = meta
    }

    /// 规则 4：删除 —— 两轨同删 + meta 同删。
    public static func removeCues(
        ids: Set<UUID>,
        original: inout SubtitleDocumentModel, companion: inout SubtitleCompanion
    ) {
        original.removeCues(ids: ids)
        if var doc = companion.translation {
            doc.removeCues(ids: ids)
            companion.translation = doc.cues.isEmpty ? nil : doc
        }
        for id in ids { companion.cueMeta.removeValue(forKey: id) }
    }

    /// 规则 5：拆分 —— 首条保留原 ID，次条用 `newID`；两轨一致。
    /// 原文文本默认整体留前半（可用 `originalTexts` 指定两半）；译文整体留前半、
    /// 后半置空（语义不可机械二分）；两条 meta 都标 stale、置信度置 nil。
    /// 拆分点必须严格落在 cue 内部，否则不动。
    @discardableResult
    public static func splitCue(
        id: UUID, at time: TimeInterval, newID: UUID = UUID(),
        originalTexts: (first: String, second: String)? = nil,
        original: inout SubtitleDocumentModel, companion: inout SubtitleCompanion
    ) -> Bool {
        guard let i = original.cues.firstIndex(where: { $0.id == id }),
              time > original.cues[i].start, time < original.cues[i].end else { return false }
        let sourceEnd = original.cues[i].end

        var second = original.cues[i]
        second.id = newID
        second.start = time
        second.end = sourceEnd
        original.cues[i].end = time
        if let texts = originalTexts {
            original.cues[i].text = texts.first
            second.text = texts.second
        } else {
            second.text = ""
        }
        original.cues.insert(second, at: i + 1)
        original.reindex()

        if var doc = companion.translation,
           let t = doc.cues.firstIndex(where: { $0.id == id }) {
            var tSecond = doc.cues[t]
            tSecond.id = newID
            tSecond.start = time
            tSecond.end = sourceEnd
            tSecond.text = ""
            doc.cues[t].end = time
            doc.cues.insert(tSecond, at: t + 1)
            doc.reindex()
            companion.translation = doc
        }

        var firstMeta = companion.cueMeta[id] ?? CueMeta()
        firstMeta.translationStale = true
        firstMeta.recognitionConfidence = nil
        companion.cueMeta[id] = firstMeta
        companion.cueMeta[newID] = firstMeta
        return true
    }

    /// 规则 6：合并 —— 沿用（文档顺序的）首条 ID，删其余 meta，标 stale。
    /// 文本按文档顺序以空格拼接（两轨同规则）；时间取并集。
    @discardableResult
    public static func mergeCues(
        ids: Set<UUID>,
        original: inout SubtitleDocumentModel, companion: inout SubtitleCompanion
    ) -> Bool {
        let picked = original.cues.enumerated().filter { ids.contains($0.element.id) }
        guard picked.count >= 2 else { return false }
        let keptID = picked[0].element.id
        let start = picked.map(\.element.start).min() ?? picked[0].element.start
        let end = picked.map(\.element.end).max() ?? picked[0].element.end
        let joined = picked.map(\.element.text)
            .filter { !$0.isEmpty }.joined(separator: " ")
        let dropped = Set(picked.dropFirst().map(\.element.id))

        let keptIndex = picked[0].offset
        original.cues[keptIndex].start = start
        original.cues[keptIndex].end = end
        original.cues[keptIndex].text = joined
        original.removeCues(ids: dropped)

        if var doc = companion.translation {
            let tPicked = doc.cues.filter { ids.contains($0.id) }
            let tJoined = tPicked.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
            if let t = doc.cues.firstIndex(where: { $0.id == keptID }) {
                doc.cues[t].start = start
                doc.cues[t].end = end
                doc.cues[t].text = tJoined
            } else if !tPicked.isEmpty {
                // 译文只存在于被并掉的条目上：并到 keptID 名下，不丢译文。
                var cue = tPicked[0]
                cue.id = keptID
                cue.start = start
                cue.end = end
                cue.text = tJoined
                let insertAt = doc.cues.firstIndex { $0.start > start } ?? doc.cues.count
                doc.cues.insert(cue, at: insertAt)
            }
            doc.removeCues(ids: dropped)
            companion.translation = doc.cues.isEmpty ? nil : doc
        }

        var meta = companion.cueMeta[keptID] ?? CueMeta()
        meta.translationStale = true
        meta.recognitionConfidence = nil
        companion.cueMeta[keptID] = meta
        for id in dropped { companion.cueMeta.removeValue(forKey: id) }
        return true
    }
}

// MARK: - 宽容 Codable

extension CueOrigin: Codable {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = CueOrigin(rawValue: raw) ?? .generated
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

extension SubtitleCompanionOrigin: Codable {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SubtitleCompanionOrigin(rawValue: raw) ?? .generated
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

extension CueProvenance: Codable {
    private enum CodingKeys: String, CodingKey {
        case sourceAssetFingerprint, clipID, sourceStart, sourceEnd
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            sourceAssetFingerprint: try c.decodeIfPresent(String.self, forKey: .sourceAssetFingerprint),
            clipID: try c.decodeIfPresent(UUID.self, forKey: .clipID),
            sourceStart: try c.decodeIfPresent(Double.self, forKey: .sourceStart),
            sourceEnd: try c.decodeIfPresent(Double.self, forKey: .sourceEnd)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(sourceAssetFingerprint, forKey: .sourceAssetFingerprint)
        try c.encodeIfPresent(clipID, forKey: .clipID)
        try c.encodeIfPresent(sourceStart, forKey: .sourceStart)
        try c.encodeIfPresent(sourceEnd, forKey: .sourceEnd)
    }
}

extension CueMeta: Codable {
    private enum CodingKeys: String, CodingKey {
        case recognitionConfidence, translationStale, origin, readingSpeedWarning, provenance
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            recognitionConfidence: try c.decodeIfPresent(Double.self, forKey: .recognitionConfidence),
            translationStale: try c.decodeIfPresent(Bool.self, forKey: .translationStale) ?? false,
            origin: try c.decodeIfPresent(CueOrigin.self, forKey: .origin) ?? .generated,
            readingSpeedWarning: try c.decodeIfPresent(Bool.self, forKey: .readingSpeedWarning) ?? false,
            provenance: try c.decodeIfPresent(CueProvenance.self, forKey: .provenance)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(recognitionConfidence, forKey: .recognitionConfidence)
        try c.encode(translationStale, forKey: .translationStale)
        try c.encode(origin, forKey: .origin)
        try c.encode(readingSpeedWarning, forKey: .readingSpeedWarning)
        try c.encodeIfPresent(provenance, forKey: .provenance)
    }
}

extension GenerationSnapshot: Codable {
    private enum CodingKeys: String, CodingKey {
        case module, segmentationConfigVersion, generatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            module: try c.decodeIfPresent(String.self, forKey: .module),
            segmentationConfigVersion: try c.decodeIfPresent(Int.self, forKey: .segmentationConfigVersion),
            generatedAt: try c.decodeIfPresent(Date.self, forKey: .generatedAt)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(module, forKey: .module)
        try c.encodeIfPresent(segmentationConfigVersion, forKey: .segmentationConfigVersion)
        try c.encodeIfPresent(generatedAt, forKey: .generatedAt)
    }
}

extension SubtitleCompanion: Codable {
    private enum CodingKeys: String, CodingKey {
        case translation, targetLanguage, sourceLanguage, origin, generation, cueMeta
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // cueMeta 用 uuidString 作键存成 JSON 对象（[UUID: _] 会被合成编码成
        // 键值交替的数组，既难读也容易被别的工具改坏）；解不出的键直接丢。
        let rawMeta = try c.decodeIfPresent([String: CueMeta].self, forKey: .cueMeta) ?? [:]
        var meta: [UUID: CueMeta] = [:]
        for (key, value) in rawMeta {
            if let id = UUID(uuidString: key) { meta[id] = value }
        }
        self.init(
            translation: try c.decodeIfPresent(SubtitleDocumentModel.self, forKey: .translation),
            targetLanguage: try c.decodeIfPresent(String.self, forKey: .targetLanguage),
            sourceLanguage: try c.decodeIfPresent(String.self, forKey: .sourceLanguage),
            origin: try c.decodeIfPresent(SubtitleCompanionOrigin.self, forKey: .origin) ?? .generated,
            generation: try c.decodeIfPresent(GenerationSnapshot.self, forKey: .generation),
            cueMeta: meta
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(translation, forKey: .translation)
        try c.encodeIfPresent(targetLanguage, forKey: .targetLanguage)
        try c.encodeIfPresent(sourceLanguage, forKey: .sourceLanguage)
        try c.encode(origin, forKey: .origin)
        try c.encodeIfPresent(generation, forKey: .generation)
        if !cueMeta.isEmpty {
            let raw = Dictionary(uniqueKeysWithValues: cueMeta.map { ($0.key.uuidString, $0.value) })
            try c.encode(raw, forKey: .cueMeta)
        }
    }
}
