import Foundation

// 关联字幕的伴随状态（docs/plans/2026-08-06-native-subtitle-generation.md 第 7、8 节）。
//
// canonical 原文轨永远是 `TimelineState.subtitle`；这里只存原文之外的关联数据：
// 译文轨、语言、每条 cue 的元数据（旁表）、生成参数快照。**不重复保存原文。**
// 2026-09-26 起两条轨独立：译文 cue 有自己的 ID 和时间，从哪句原文翻来记在来源表
// `translationLinks`（SubtitleTranslationLink.swift）；编辑合同在 SubtitleTrackEditing.swift。
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
    /// 老工程（v22 及更早，译文是原文的镜像）里「原文改过、译文过期」的标记。**只在读老工程时有意义**：
    /// 打开时迁移进来源表（`splitMirroredTranslation`）后恒为 false。现在的「过期」是现算的
    /// （`SubtitleCompanion.isTranslationStale`）。
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
    /// 译文轨。cue 有自己的 ID 和时间（2026-09-26 起与原文轨独立），从哪句原文翻来见 `translationLinks`。
    public var translation: SubtitleDocumentModel?
    /// BCP-47，如 "zh-Hans"。
    public var targetLanguage: String?
    public var sourceLanguage: String?
    public var origin: SubtitleCompanionOrigin
    public var generation: GenerationSnapshot?
    /// cue 元数据旁表，键 = 原文 cue 的 ID。不改动 SubtitleCue 的既有 Codable。
    public var cueMeta: [UUID: CueMeta]
    /// 译文的来源表，键 = **译文** cue 的 ID（v23，SubtitleTranslationLink.swift）。
    public var translationLinks: [UUID: TranslationLink]

    public init(
        translation: SubtitleDocumentModel? = nil,
        targetLanguage: String? = nil,
        sourceLanguage: String? = nil,
        origin: SubtitleCompanionOrigin = .generated,
        generation: GenerationSnapshot? = nil,
        cueMeta: [UUID: CueMeta] = [:],
        translationLinks: [UUID: TranslationLink] = [:]
    ) {
        self.translation = translation
        self.targetLanguage = targetLanguage
        self.sourceLanguage = sourceLanguage
        self.origin = origin
        self.generation = generation
        self.cueMeta = cueMeta
        self.translationLinks = translationLinks
    }

    /// 是否存有「旧版打开会被静默丢掉」的数据 —— formatVersion 按需写 4 的判据之一。
    /// origin 单独不算数据：没有任何实质字段时整个 companion 视同不存在。
    public var hasPersistentData: Bool {
        translation != nil || !cueMeta.isEmpty || !translationLinks.isEmpty || generation != nil
            || sourceLanguage != nil || targetLanguage != nil
    }

    /// 规范化（读盘后、老工程拆开之后调用）：
    /// - 译文 cue 的 ID 撞上原文 ID 的（外部改动、半截迁移）换一个新 ID —— 选择按 ID 认，
    ///   两条轨上同一个 ID 会让点一句选中两句；
    /// - 来源表只留译文轨上还在的句子，`cueMeta` 只留原文轨上还在的；
    /// - 译文轨清空后归 nil。
    /// 来源表里指向已删原文的 ID **不清**：原文删了译文不跟着删（悬空，重译不碰它）。
    public mutating func normalize(originalCueIDs: Set<UUID>, newID: () -> UUID = { UUID() }) {
        if var doc = translation {
            for i in doc.cues.indices where originalCueIDs.contains(doc.cues[i].id) {
                let old = doc.cues[i].id
                let fresh = newID()
                doc.cues[i].id = fresh
                translationLinks[fresh] = translationLinks.removeValue(forKey: old)
            }
            translation = doc.cues.isEmpty ? nil : doc
        }
        let translationIDs = Set((translation?.cues ?? []).map(\.id))
        translationLinks = translationLinks.filter { translationIDs.contains($0.key) }
        cueMeta = cueMeta.filter { originalCueIDs.contains($0.key) }
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
        case translation, targetLanguage, sourceLanguage, origin, generation, cueMeta, translationLinks
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
        // 来源表同一个存法（键是译文 cue 的 uuidString）。
        let rawLinks = try c.decodeIfPresent([String: TranslationLink].self, forKey: .translationLinks) ?? [:]
        var links: [UUID: TranslationLink] = [:]
        for (key, value) in rawLinks {
            if let id = UUID(uuidString: key) { links[id] = value }
        }
        self.init(
            translation: try c.decodeIfPresent(SubtitleDocumentModel.self, forKey: .translation),
            targetLanguage: try c.decodeIfPresent(String.self, forKey: .targetLanguage),
            sourceLanguage: try c.decodeIfPresent(String.self, forKey: .sourceLanguage),
            origin: try c.decodeIfPresent(SubtitleCompanionOrigin.self, forKey: .origin) ?? .generated,
            generation: try c.decodeIfPresent(GenerationSnapshot.self, forKey: .generation),
            cueMeta: meta,
            translationLinks: links
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
        if !translationLinks.isEmpty {
            let raw = Dictionary(uniqueKeysWithValues: translationLinks.map { ($0.key.uuidString, $0.value) })
            try c.encode(raw, forKey: .translationLinks)
        }
    }
}
