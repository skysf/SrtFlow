import Foundation
import SrtFlowCore

// 字幕分段：成句、约束、变速、边界合同。2026-09-26 从 main.swift 搬出来（那个文件只许降）。
// 分段规则见 docs/architecture/subtitle-generation-style.md。

func runSubtitleSegmentationChecks() {

    do {
        func window(
            src: ClosedRange<Double>, tlStart: Double = 0, speed: Double = 1, lane: Int = 0,
            clip: UUID = UUID()
        ) -> SubtitleClipWindow {
            SubtitleClipWindow(
                clipID: clip, assetFingerprint: "asset-a",
                sourceStart: src.lowerBound, sourceEnd: src.upperBound,
                timelineStart: tlStart, speed: speed, laneRank: lane
            )
        }
        // 识别器风格的词流：英文词自带前导空格、标点附着词尾。
        let speech: [TimedWord] = [
            TimedWord(text: "Hello,", start: 0.0, end: 0.4, confidence: 0.9),
            TimedWord(text: " world.", start: 0.5, end: 0.9, confidence: 0.7),
            TimedWord(text: " This", start: 2.0, end: 2.3, confidence: 0.95),
            TimedWord(text: " is", start: 2.3, end: 2.5, confidence: 1.0),
            TimedWord(text: " a", start: 2.5, end: 2.6, confidence: 1.0),
            TimedWord(text: " test.", start: 2.6, end: 3.0, confidence: 0.9)
        ]

        // 1×：两句 → 两条 cue，标点断句，置信度取均值。
        do {
            let out = SubtitleSegmenter.segment(words: speech, window: window(src: 0...10))
            checkEqual(out.cues.count, 2, "1×：两句两条 cue")
            checkEqual(out.cues.first?.text, "Hello world", "1×：句一文本（去了标点）")
            checkEqual(out.cues.last?.text, "This is a test", "1×：句二文本（去了标点）")
            checkEqual(out.cues.first?.start, 0, "1×：句一起点")
            checkEqual(out.cues.last?.start, 2.0, "1×：句二起点")
            if let id = out.cues.first?.id, let meta = out.meta[id] {
                check(abs((meta.recognitionConfidence ?? 0) - 0.8) < 0.0001, "1×：置信度均值")
                checkEqual(meta.readingSpeedWarning, false, "1×：正常语速无告警")
                checkEqual(meta.provenance?.sourceAssetFingerprint, "asset-a", "1×：provenance 带素材指纹")
                checkEqual(meta.provenance?.sourceStart, 0, "1×：provenance 源起点")
            }
        }

        // 2×：映射到时间线（timelineStart 5），时长减半后向后借位补最短时长。
        do {
            let out = SubtitleSegmenter.segment(words: speech, window: window(src: 0...10, tlStart: 5, speed: 2))
            checkEqual(out.cues.count, 2, "2×：仍是两条")
            checkEqual(out.cues.first?.start, 5, "2×：起点映射")
            checkEqual(out.cues.last?.start, 6.0, "2×：句二 2.0s→6.0s")
            check(abs((out.cues.first?.duration ?? 0) - 0.7) < 0.0001, "2×：短 cue 借位到最短时长")
        }

        // 0.1×：一句在时间线上被拉到 10s，超 maxCueDuration → 拆成多条 ——
        // 同一素材不同 speed 分段不同是合同行为。
        do {
            let out = SubtitleSegmenter.segment(
                words: Array(speech[2...]), window: window(src: 0...10, speed: 0.1)
            )
            check(out.cues.count > 1, "0.1×：超长句要按词边界拆条")
            for cue in out.cues {
                check(cue.duration <= 7.0 + 0.0001, "0.1×：每条不超 maxCueDuration")
            }
        }

        // 8×：两句背靠背，前句借不到空档 → CPS 无解，如实告警。
        do {
            let fast: [TimedWord] = [
                TimedWord(text: "Fast one.", start: 0.0, end: 1.0),
                TimedWord(text: " Two.", start: 1.0, end: 1.5)
            ]
            let out = SubtitleSegmenter.segment(words: fast, window: window(src: 0...10, speed: 8))
            checkEqual(out.cues.count, 2, "8×：两句两条")
            if let first = out.cues.first {
                check(first.duration < 0.2, "8×：前句被后句顶住借不到位")
                checkEqual(out.meta[first.id]?.readingSpeedWarning, true, "8×：无解要告警")
            }
            if let second = out.cues.last {
                checkEqual(out.meta[second.id]?.readingSpeedWarning, false, "8×：后句借到位就不告警")
            }
        }

        // 边界合同：半开区间中点归属，相邻分片不重复不遗漏；clamp 零时长丢弃。
        do {
            let a = window(src: 0...2.45)
            let b = window(src: 2.45...10, tlStart: 2.45)
            let outA = SubtitleSegmenter.segment(words: speech, window: a)
            let outB = SubtitleSegmenter.segment(words: speech, window: b)
            let textA = outA.cues.map(\.text).joined(separator: "|")
            let textB = outB.cues.map(\.text).joined(separator: "|")
            check(textA.contains("This is"), "边界：中点 2.4 的词归前片")
            check(!textA.contains("a test"), "边界：中点 2.55 的词不归前片")
            check(textB.contains("a test"), "边界：后片接住剩余词")
            check(!textB.contains("This"), "边界：前片的词不重复出现在后片")
            let wordsA = SubtitleSegmenter.attributeWords(speech, to: a).count
            let wordsB = SubtitleSegmenter.attributeWords(speech, to: b).count
            checkEqual(wordsA + wordsB, speech.count, "边界：两片词数合计 = 全量，无重复无遗漏")

            let degenerate = [TimedWord(text: "x", start: 2.45, end: 2.45)]
            check(
                SubtitleSegmenter.attributeWords(degenerate, to: b).isEmpty,
                "边界：clamp 后零时长要丢弃"
            )
        }

        // 折行：词边界贪心折行，不切词。
        do {
            let cfg = SubtitleSegmentationConfig(maxLineCount: 2, maxLineLength: 10)
            let words: [TimedWord] = [
                TimedWord(text: "aaaa", start: 0, end: 1),
                TimedWord(text: " bbbb", start: 1, end: 2),
                TimedWord(text: " cccc", start: 2, end: 3)
            ]
            let out = SubtitleSegmenter.segment(words: words, window: window(src: 0...10), config: cfg)
            checkEqual(out.cues.first?.text, "aaaa bbbb\ncccc", "折行：贪心塞行、词边界换行")
        }

        // 停顿断句：无标点也按停顿切。
        do {
            let words: [TimedWord] = [
                TimedWord(text: "无标点", start: 0, end: 0.5),
                TimedWord(text: "的话", start: 0.5, end: 1.0),
                TimedWord(text: "靠停顿", start: 2.5, end: 3.0)
            ]
            let out = SubtitleSegmenter.segment(words: words, window: window(src: 0...10))
            checkEqual(out.cues.count, 2, "停顿：超阈值断句")
            checkEqual(out.cues.first?.text, "无标点的话", "停顿：中文词直接相连")
        }
    }
}
