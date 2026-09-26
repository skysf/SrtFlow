import Foundation

// 几段素材同时有人说话时只留一条字幕（2026-09-26，docs/architecture/subtitle-generation-style.md）。
//
// 主流剪辑软件出来的都是一条不重叠的字幕：Premiere 同一时刻只取最靠上、没静音的那条轨，Final Cut Pro
// 把重叠的字幕标红、用「Resolve Overlaps」截开，CapCut 要求两条字幕不能占同一段时间。
// 我们的轨道语义和它们不一样 —— 主轨是视频自带的声音，旁白多半在音频轨上 —— 按轨道先后定谁留，
// 录屏里的杂音会压过旁白，所以按「谁识别得更清楚」定：
// 1. 一两个词、置信度低于 0.3 的零碎字幕直接不要（实测：录屏收进来的「我」「you」置信度 0.07–0.27，
//    正常旁白在 0.8 以上）；
// 2. 置信度高的先占位；后来的跟已经占住的撞上了，只留它没被占的最长一段 —— 剩下不到原来的一半就整条不要
//    （字没法跟着截，只截时间的话一句话挤在半截时间里读不完）。
// 不管什么：同一段素材里前后相接的字（不算撞上，它们之间留的 2 帧归 `SubtitleCueTiming`）；手打、导入的字幕
// （不走生成）；显示时间（`SubtitleCueTiming`）。

public enum SubtitleSourceOverlap {

    /// 低于它的一两个词算零碎的杂音。
    public static let fragmentConfidence = 0.3
    /// 撞上之后截短，至少要留原来的多少。
    public static let minimumKeptFraction = 0.5

    /// - Parameters:
    ///   - cues: 各段素材切好的字幕（开始 = 开口、结束 = 说完），可以互相重叠。
    ///   - laneRank: 置信度一样时，轨道秩小的先留。
    /// - Returns: 互不重叠（两条之间至少留 `config.gap`）的那些，按开始时间排好。
    public static func resolve(
        _ cues: [SubtitleCue],
        meta: [UUID: CueMeta],
        laneRank: (UUID?) -> Int,
        config: SubtitleSegmentationConfig
    ) -> [SubtitleCue] {
        func confidence(_ cue: SubtitleCue) -> Double { meta[cue.id]?.recognitionConfidence ?? 0.5 }
        let clearestFirst = cues
            .filter { !isFragment($0, confidence: confidence($0)) }
            .sorted { a, b in
                if confidence(a) != confidence(b) { return confidence(a) > confidence(b) }
                let rankA = laneRank(meta[a.id]?.provenance?.clipID)
                let rankB = laneRank(meta[b.id]?.provenance?.clipID)
                if rankA != rankB { return rankA < rankB }
                if a.duration != b.duration { return a.duration > b.duration }
                return a.start < b.start
            }
        func source(_ cue: SubtitleCue) -> UUID? { meta[cue.id]?.provenance?.clipID }
        var kept: [SubtitleCue] = []
        for cue in clearestFirst {
            // 只跟别的素材比：同一段素材里前后相接的两条是正常的，它们之间的 2 帧交给 `SubtitleCueTiming`。
            let others = kept.filter { source($0) != source(cue) }
            guard let free = longestFreeSpan(of: cue, avoiding: others, gap: config.gap) else { continue }
            if free.lowerBound == cue.start, free.upperBound == cue.end {
                kept.append(cue)                    // 没撞上
                continue
            }
            guard free.upperBound - free.lowerBound >= cue.duration * minimumKeptFraction else { continue }
            var trimmed = cue
            trimmed.start = free.lowerBound
            trimmed.end = free.upperBound
            kept.append(trimmed)
        }
        return kept.sorted { $0.start < $1.start }
    }

    /// 一两个词（中文两个字以内）、置信度又低：杂音。
    static func isFragment(_ cue: SubtitleCue, confidence: Double) -> Bool {
        guard confidence < fragmentConfidence else { return false }
        if SubtitleLineMeasure.isMostlyFullWidth(cue.text) {
            return cue.text.filter { !$0.isWhitespace }.count <= 2
        }
        return cue.text.split(whereSeparator: \.isWhitespace).count <= 2
    }

    /// 这条字幕的时间里，没被已经留下的那些（前后各让 `gap`）占住的最长一段；全被占了就是 nil。
    static func longestFreeSpan(of cue: SubtitleCue, avoiding kept: [SubtitleCue], gap: Double) -> ClosedRange<Double>? {
        var spans: [ClosedRange<Double>] = [cue.start ... cue.end]
        for other in kept where other.start - gap < cue.end && cue.start < other.end + gap {
            let blocked = (other.start - gap) ... (other.end + gap)
            spans = spans.flatMap { span -> [ClosedRange<Double>] in
                guard span.lowerBound < blocked.upperBound, blocked.lowerBound < span.upperBound else { return [span] }
                var rest: [ClosedRange<Double>] = []
                if span.lowerBound < blocked.lowerBound { rest.append(span.lowerBound ... blocked.lowerBound) }
                if blocked.upperBound < span.upperBound { rest.append(blocked.upperBound ... span.upperBound) }
                return rest
            }
        }
        return spans.max { ($0.upperBound - $0.lowerBound) < ($1.upperBound - $1.lowerBound) }
    }
}
