import Foundation

// 一段素材里说了什么：按句排好、带时间线时间的词（2026-09-27，AI 的 transcribe / cut_speech 用）。
//
// 管什么：一个素材的源时间词流（转写缓存里的那份）+ 一个片段实例（`SubtitleClipWindow`）→ 这个片段里的句子和词。
// 词归哪段、从哪儿开口和生成字幕是同一份（`SubtitleSegmenter.placed`：说话中点落在片段里才算，停顿后面第一个词按
// 估出来的开口，docs/bugfixes/2026-09-26-pause-stretches-next-word.md）；成句也是同一个函数（`SubtitleBreaks.sentences`：
// 句号问号叹号，或者停顿超过阈值）。口播常常一口气说很久，一句超过 `maxWordsPerSentence` 个词再切开，
// 优先切在逗号类后面 —— 免得一句占掉 AI 一大截，也好按句挑。
// 不管什么：去标点、一行多长、显示时间（那是字幕的事）；转写和缓存（App 里的 TranscriptHarvester）。

public enum SpeechTranscript {
    public struct Word: Hashable, Sendable {
        /// 去掉首尾空白的词（标点照原样跟着）。
        public var text: String
        /// 时间线秒（给文件时就是文件里的秒）。
        public var start: Double
        public var end: Double
        public var sourceStart: Double
        public var sourceEnd: Double
        public var confidence: Double?

        public init(text: String, start: Double, end: Double, sourceStart: Double, sourceEnd: Double, confidence: Double?) {
            self.text = text
            self.start = start
            self.end = end
            self.sourceStart = sourceStart
            self.sourceEnd = sourceEnd
            self.confidence = confidence
        }
    }

    public struct Sentence: Hashable, Sendable {
        public var words: [Word]
        /// 照说的原样拼起来（带标点；中文不加空格）。
        public var text: String
        public var start: Double { words.first?.start ?? 0 }
        public var end: Double { words.last?.end ?? 0 }
    }

    public static let maxWordsPerSentence = 40

    public static func sentences(
        words: [TimedWord], window: SubtitleClipWindow, pauseThreshold: Double = 0.6
    ) -> [Sentence] {
        let placed = SubtitleSegmenter.placed(words, in: window)
        return SubtitleBreaks.sentences(placed, pauseThreshold: pauseThreshold)
            .flatMap(split)
            .compactMap { chunk in
                let kept = chunk.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                guard !kept.isEmpty else { return nil }
                return Sentence(
                    words: kept.map { word in
                        Word(
                            text: word.text.trimmingCharacters(in: .whitespacesAndNewlines),
                            start: word.start, end: word.end,
                            sourceStart: word.sourceStart, sourceEnd: word.sourceEnd, confidence: word.confidence
                        )
                    },
                    text: chunk.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
    }

    /// 超过 `maxWordsPerSentence` 个词的句子切开：在前 max 个词里、从三分之一处往后找最后一个逗号类收尾的词，
    /// 切在它后面；找不到就切在第 max 个词后面。
    static func split(_ sentence: [SubtitleSegmenter.PlacedWord]) -> [[SubtitleSegmenter.PlacedWord]] {
        var rest = sentence[...]
        var pieces: [[SubtitleSegmenter.PlacedWord]] = []
        while rest.count > maxWordsPerSentence {
            let window = rest.prefix(maxWordsPerSentence)
            let earliest = window.startIndex + maxWordsPerSentence / 3
            let cut = window.indices.last { $0 >= earliest && SubtitleBreaks.endsClause(rest[$0].text) }
                .map { $0 + 1 } ?? window.endIndex
            pieces.append(Array(rest[rest.startIndex..<cut]))
            rest = rest[cut...]
        }
        if !rest.isEmpty { pieces.append(Array(rest)) }
        return pieces
    }
}
