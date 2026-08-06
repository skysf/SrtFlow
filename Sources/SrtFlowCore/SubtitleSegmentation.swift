import Foundation

// 字幕分段器（docs/plans/2026-08-06-native-subtitle-generation.md 第 5、6 节）。
//
// 输入是**素材源时间**的词流（sidecar 缓存的形态，与时间线解耦）；
// 每个 clip 实例先按边界合同截取词，映射到时间线，然后**全部约束在时间线
// 时间上评估** —— 同一素材在不同 speed 的 clip 上产生不同分段是预期行为；
// 极端变速下 CPS 无解时打 readingSpeedWarning，不假装满足。
// 全部纯函数，SrtFlowCoreChecks 有 0.1×/1×/2×/8× 与边界用例。

/// 一个带时间的词（素材源时间，秒）。text 保持识别器原样
/// （英文词自带前导空格、标点附着在词上），拼接时直接相连。
public struct TimedWord: Hashable, Sendable, Codable {
    public var text: String
    public var start: Double
    public var end: Double
    public var confidence: Double?

    public init(text: String, start: Double, end: Double, confidence: Double? = nil) {
        self.text = text
        self.start = start
        self.end = end
        self.confidence = confidence
    }
}

/// 分段约束。全部按**时间线时长**评估；默认值是可调的产品参数（计划 17.3），
/// 集中在这里，不散进逻辑。
public struct SubtitleSegmentationConfig: Hashable, Sendable {
    public var maxLineCount: Int
    /// 每行最大字符数（去掉空白后计）。
    public var maxLineLength: Int
    public var minCueDuration: Double
    public var maxCueDuration: Double
    /// 阅读速度上限：字符/秒（去空白）。
    public var maxCharactersPerSecond: Double
    /// 词间停顿超过它就断句（时间线秒）。
    public var pauseThreshold: Double

    /// 参数集版本：进 GenerationSnapshot，缓存/重现用。
    public static let version = 1

    public init(
        maxLineCount: Int = 2,
        maxLineLength: Int = 42,
        minCueDuration: Double = 0.7,
        maxCueDuration: Double = 7.0,
        maxCharactersPerSecond: Double = 17,
        pauseThreshold: Double = 0.6
    ) {
        self.maxLineCount = maxLineCount
        self.maxLineLength = maxLineLength
        self.minCueDuration = minCueDuration
        self.maxCueDuration = maxCueDuration
        self.maxCharactersPerSecond = maxCharactersPerSecond
        self.pauseThreshold = pauseThreshold
    }
}

/// 一个 clip 实例的转写窗口：素材源区间（**半开** [sourceStart, sourceEnd)）
/// 加上映射到时间线所需的一切。laneRank 供重叠排序（主轨 0、音频轨 1+序号）。
public struct SubtitleClipWindow: Hashable, Sendable {
    public var clipID: UUID
    public var assetFingerprint: String
    public var sourceStart: Double
    public var sourceEnd: Double
    public var timelineStart: Double
    public var speed: Double
    public var laneRank: Int

    public init(
        clipID: UUID,
        assetFingerprint: String,
        sourceStart: Double,
        sourceEnd: Double,
        timelineStart: Double,
        speed: Double = 1,
        laneRank: Int = 0
    ) {
        self.clipID = clipID
        self.assetFingerprint = assetFingerprint
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
        self.timelineStart = timelineStart
        self.speed = max(speed, 0.001)
        self.laneRank = laneRank
    }

    public func timelineTime(atSource source: Double) -> Double {
        timelineStart + (source - sourceStart) / speed
    }
}

/// 一个窗口的分段产物：cue + 旁表 meta（置信度/告警/provenance 已填好）。
public struct SegmentedSubtitles: Sendable {
    public var cues: [SubtitleCue]
    public var meta: [UUID: CueMeta]

    public init(cues: [SubtitleCue] = [], meta: [UUID: CueMeta] = [:]) {
        self.cues = cues
        self.meta = meta
    }
}

public enum SubtitleSegmenter {

    // MARK: 边界合同（计划 5.3）

    /// 词归属：timeRange 中点落在窗口的半开源区间内才归本窗口；
    /// 归属后 clamp 到区间；clamp 出零时长的丢弃。
    public static func attributeWords(
        _ words: [TimedWord], to window: SubtitleClipWindow
    ) -> [TimedWord] {
        words.compactMap { word in
            let mid = (word.start + word.end) / 2
            guard mid >= window.sourceStart, mid < window.sourceEnd else { return nil }
            var clamped = word
            clamped.start = max(word.start, window.sourceStart)
            clamped.end = min(word.end, window.sourceEnd)
            guard clamped.end > clamped.start else { return nil }
            return clamped
        }
    }

    // MARK: 分段主流程

    /// 源时间词流 → 本窗口的时间线 cue。
    public static func segment(
        words: [TimedWord],
        window: SubtitleClipWindow,
        config: SubtitleSegmentationConfig = SubtitleSegmentationConfig()
    ) -> SegmentedSubtitles {
        // ① 截取归属本窗口的词，② 映射到时间线（保留源时间做 provenance）。
        let placed = attributeWords(words, to: window)
            .sorted { $0.start < $1.start }
            .map { word in
                PlacedWord(
                    text: word.text,
                    sourceStart: word.start,
                    sourceEnd: word.end,
                    start: window.timelineTime(atSource: word.start),
                    end: window.timelineTime(atSource: word.end),
                    confidence: word.confidence
                )
            }
        guard !placed.isEmpty else { return SegmentedSubtitles() }

        // ③ 语义成句：标点收尾或停顿超阈值就断句（时间线时间上判停顿）。
        var sentences: [[PlacedWord]] = []
        var current: [PlacedWord] = []
        for (index, word) in placed.enumerated() {
            current.append(word)
            let endsSentence = word.text.reversed().first(where: { !$0.isWhitespace })
                .map { Self.sentenceTerminators.contains($0) } ?? false
            let pause = index + 1 < placed.count
                ? placed[index + 1].start - word.end : 0
            if endsSentence || pause > config.pauseThreshold {
                sentences.append(current)
                current = []
            }
        }
        if !current.isEmpty { sentences.append(current) }

        // ④ 句内按时间线约束切 cue，⑤ 折行，告警如实打标。
        var result = SegmentedSubtitles()
        for sentence in sentences {
            for chunk in packCues(sentence, config: config) {
                appendCue(chunk, window: window, config: config, into: &result)
            }
        }

        // 最短时长：能借到下一条开始前的空档就借（不改变顺序、不重叠）。
        for i in result.cues.indices where result.cues[i].duration < config.minCueDuration {
            let limit = i + 1 < result.cues.count
                ? result.cues[i + 1].start
                : window.timelineTime(atSource: window.sourceEnd)
            result.cues[i].end = min(result.cues[i].start + config.minCueDuration, limit)
        }
        // 阅读速度告警按**借位后的最终时长**评定：借得到空档就是合法解，
        // 借不到（后面顶着下一条）才是真无解 —— 如实打标，不假装满足。
        for cue in result.cues {
            let speed = Double(visibleCount(cue.text)) / max(cue.duration, 0.001)
            if speed > config.maxCharactersPerSecond {
                result.meta[cue.id]?.readingSpeedWarning = true
            }
        }
        for i in result.cues.indices { result.cues[i].index = i + 1 }
        return result
    }

    /// 多窗口产物合成一份文档 + 旁表：按重叠排序合同排定顺序（SubtitleOverlap）。
    public static func assemble(
        _ parts: [SegmentedSubtitles],
        laneRank: (UUID?) -> Int
    ) -> (document: SubtitleDocumentModel, meta: [UUID: CueMeta]) {
        var meta: [UUID: CueMeta] = [:]
        var cues: [SubtitleCue] = []
        for part in parts {
            cues.append(contentsOf: part.cues)
            meta.merge(part.meta) { a, _ in a }
        }
        cues = SubtitleOverlap.ordered(cues, meta: meta, laneRank: laneRank)
        for i in cues.indices { cues[i].index = i + 1 }
        var document = SubtitleDocumentModel(cues: cues)
        document.reindex()
        return (document, meta)
    }

    // MARK: 内部

    static let sentenceTerminators: Set<Character> = [
        ".", "!", "?", "…", "。", "！", "？"
    ]

    struct PlacedWord {
        var text: String
        var sourceStart: Double
        var sourceEnd: Double
        var start: Double
        var end: Double
        var confidence: Double?
    }

    private static func visibleCount(_ text: String) -> Int {
        text.unicodeScalars.lazy.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.count
    }

    /// 句子 → 若干 cue 的词块。加词会超（容量/最长时长）就在词边界收束，
    /// 绝不切词。**CPS 不在这里管**：拆条不改变「字符/秒」，只有向后借位
    /// 能救 —— 借位在 segment 的收尾做，救不回来的按最终时长如实告警。
    private static func packCues(
        _ sentence: [PlacedWord], config: SubtitleSegmentationConfig
    ) -> [[PlacedWord]] {
        let capacity = config.maxLineCount * config.maxLineLength
        var chunks: [[PlacedWord]] = []
        var current: [PlacedWord] = []
        var currentChars = 0

        for word in sentence {
            let wordChars = visibleCount(word.text)
            if !current.isEmpty {
                let duration = word.end - current[0].start
                if currentChars + wordChars > capacity || duration > config.maxCueDuration {
                    chunks.append(current)
                    current = []
                    currentChars = 0
                }
            }
            current.append(word)
            currentChars += wordChars
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private static func appendCue(
        _ chunk: [PlacedWord],
        window: SubtitleClipWindow,
        config: SubtitleSegmentationConfig,
        into result: inout SegmentedSubtitles
    ) {
        guard let first = chunk.first, let last = chunk.last else { return }
        let text = wrapLines(chunk, config: config)
        guard !text.isEmpty else { return }

        let confidences = chunk.compactMap(\.confidence)
        let cue = SubtitleCue(start: first.start, end: last.end, text: text)
        result.cues.append(cue)
        result.meta[cue.id] = CueMeta(
            recognitionConfidence: confidences.isEmpty
                ? nil : confidences.reduce(0, +) / Double(confidences.count),
            origin: .generated,
            provenance: CueProvenance(
                sourceAssetFingerprint: window.assetFingerprint,
                clipID: window.clipID,
                sourceStart: first.sourceStart,
                sourceEnd: last.sourceEnd
            )
        )
    }

    /// 词边界折行：贪心塞满每行，超行数就不再折（容量在 packCues 已经保证，
    /// 这里只处理排版）。
    private static func wrapLines(_ chunk: [PlacedWord], config: SubtitleSegmentationConfig) -> String {
        var lines: [String] = []
        var line = ""
        for word in chunk {
            let candidate = line + word.text
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if visibleCount(trimmed) > config.maxLineLength,
               !line.isEmpty, lines.count + 1 < config.maxLineCount {
                lines.append(line.trimmingCharacters(in: .whitespacesAndNewlines))
                line = word.text
            } else {
                line = candidate
            }
        }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { lines.append(trimmed) }
        return lines.joined(separator: "\n")
    }
}

// MARK: - 重叠 cue 排序合同（计划第 9 节）

/// 预览与烧录共用的**唯一**排序实现 —— 一致性靠共享代码保证。
public enum SubtitleOverlap {

    /// 时刻 t 的全部活动 cue（半开区间 start <= t < end）。
    public static func active(at time: Double, in cues: [SubtitleCue]) -> [SubtitleCue] {
        cues.filter { $0.start <= time && time < $0.end }
    }

    /// 稳定全序：(start, 轨道秩, clipID, cue.id)。
    /// 无 provenance 的（外挂/手工 cue）laneRank 传 -1 排最前。
    public static func ordered(
        _ cues: [SubtitleCue],
        meta: [UUID: CueMeta],
        laneRank: (UUID?) -> Int
    ) -> [SubtitleCue] {
        cues.sorted { a, b in
            if a.start != b.start { return a.start < b.start }
            let clipA = meta[a.id]?.provenance?.clipID
            let clipB = meta[b.id]?.provenance?.clipID
            let rankA = laneRank(clipA)
            let rankB = laneRank(clipB)
            if rankA != rankB { return rankA < rankB }
            let clipKeyA = clipA?.uuidString ?? ""
            let clipKeyB = clipB?.uuidString ?? ""
            if clipKeyA != clipKeyB { return clipKeyA < clipKeyB }
            return a.id.uuidString < b.id.uuidString
        }
    }
}
