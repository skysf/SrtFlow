import Foundation

// 字幕分段器（docs/plans/2026-08-06-native-subtitle-generation.md 第 5、6 节；
// 2026-09-26 起断句和显示时间按主流规范，docs/architecture/subtitle-generation-style.md）。
//
// 输入是**素材源时间**的词流（sidecar 缓存的形态，与时间线解耦）；
// 每个 clip 实例先按边界合同截取词，映射到时间线，然后**全部约束在时间线
// 时间上评估** —— 同一素材在不同 speed 的 clip 上产生不同分段是预期行为；
// 极端变速下 CPS 无解时打 readingSpeedWarning，不假装满足。
//
// 分两步：
// - `segment`：一段素材的词切成一条条字幕（在哪断：`SubtitleBreaks`；去标点：`SubtitlePunctuation`）。
//   每条的开始 = 第一个词开口，结束 = 最后一个词说完。
// - `assemble`：几段素材的字幕合成一条轨 —— 同时有字的只留一条（`SubtitleSourceOverlap`，主流剪辑软件
//   出来的都是一条不重叠的字幕），再统一排显示时间（`SubtitleCueTiming`）：两条之间留多少、说完延多久
//   要看整条轨上的前后邻居，不看它是哪段素材来的。
// 全部纯函数，SrtFlowCoreChecks 有变速、边界、断句、显示时间的用例。

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

    /// 这段素材在时间线上的结尾 —— 它的字幕最晚收到这里。
    public var timelineEnd: Double { timelineTime(atSource: sourceEnd) }
}

/// 一个窗口的分段产物：cue + 旁表 meta（置信度、provenance 已填好；
/// 显示时间和阅读速度告警在 `assemble` 里定）。
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

    // MARK: 分段

    /// 源时间词流 → 本窗口的字幕（显示时间在 `assemble` 里排）。
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
        // ③ 成句，④ 句内按逗号分小句、太短的并、放不下的在最好的地方切，⑤ 去标点成字幕。
        var result = SegmentedSubtitles()
        for sentence in SubtitleBreaks.sentences(placed, pauseThreshold: config.pauseThreshold) {
            for range in SubtitleBreaks.pieces(of: sentence, config: config) {
                appendCue(sentence[range], window: window, config: config, into: &result)
            }
        }
        for i in result.cues.indices { result.cues[i].index = i + 1 }
        return result
    }

    /// 几段素材的字幕合成一条轨：同时有字的只留一条，按排序合同排好，再统一排显示时间、标阅读速度告警。
    /// - Parameter windows: 这几段素材（轨道秩给排序合同；时间线上的结尾是它的字幕最晚收到哪）。
    public static func assemble(
        _ parts: [SegmentedSubtitles],
        windows: [SubtitleClipWindow],
        config: SubtitleSegmentationConfig = SubtitleSegmentationConfig()
    ) -> (document: SubtitleDocumentModel, meta: [UUID: CueMeta]) {
        var meta: [UUID: CueMeta] = [:]
        var cues: [SubtitleCue] = []
        for part in parts {
            cues.append(contentsOf: part.cues)
            meta.merge(part.meta) { a, _ in a }
        }
        let windowByClip = Dictionary(windows.map { ($0.clipID, $0) }, uniquingKeysWith: { a, _ in a })
        func window(of cue: SubtitleCue) -> SubtitleClipWindow? {
            meta[cue.id]?.provenance?.clipID.flatMap { windowByClip[$0] }
        }
        let laneRank: (UUID?) -> Int = { clipID in clipID.flatMap { windowByClip[$0]?.laneRank } ?? -1 }
        // 几段素材同时有字：只留一条（谁识别得更清楚留谁）；丢掉的连旁表一起丢。
        cues = SubtitleSourceOverlap.resolve(cues, meta: meta, laneRank: laneRank, config: config)
        let keptIDs = Set(cues.map(\.id))
        meta = meta.filter { keptIDs.contains($0.key) }
        cues = SubtitleOverlap.ordered(cues, meta: meta, laneRank: laneRank)
        var limits: [UUID: Double] = [:]
        for cue in cues {
            if let window = window(of: cue) { limits[cue.id] = window.timelineEnd }
        }
        SubtitleCueTiming.apply(to: &cues, limits: limits, config: config)
        SubtitleCueTiming.markReadingSpeed(cues, meta: &meta, config: config)
        for i in cues.indices { cues[i].index = i + 1 }
        var document = SubtitleDocumentModel(cues: cues)
        document.reindex()
        return (document, meta)
    }

    // MARK: 内部

    struct PlacedWord {
        var text: String
        var sourceStart: Double
        var sourceEnd: Double
        var start: Double
        var end: Double
        var confidence: Double?
    }

    private static func appendCue(
        _ chunk: ArraySlice<PlacedWord>,
        window: SubtitleClipWindow,
        config: SubtitleSegmentationConfig,
        into result: inout SegmentedSubtitles
    ) {
        guard let first = chunk.first, let last = chunk.last else { return }
        // 断完句、切完条才去标点（断句要看标点）；排成几行也按去完标点的字量。
        let lines = SubtitleBreaks.lines(for: chunk, config: config)
            ?? [SubtitlePunctuation.strip(chunk.map(\.text).joined())]
        let text = lines.joined(separator: "\n")
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
