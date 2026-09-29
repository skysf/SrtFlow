import Foundation
import SrtFlowCore

// 转写的数据：缓存的区间账本（TranscriptLedger / TranscriptCacheEntry，原来在 main.swift 里）和按句排好的转写结果
// （SpeechTranscript，AI 的 transcribe / cut_speech 读的就是它）。

func runTranscriptChecks() {
    checkTranscriptLedger()
    checkSpeechTranscript()
}

// MARK: - 转写缓存区间账本

private func checkTranscriptLedger() {
    typealias R = SourceRange
    checkEqual(
        TranscriptLedger.normalize([R(start: 3, end: 4), R(start: 0, end: 1), R(start: 0.9995, end: 2)]),
        [R(start: 0, end: 2), R(start: 3, end: 4)],
        "账本：排序合并、epsilon 吸毛刺"
    )
    checkEqual(
        TranscriptLedger.gaps(
            desired: [R(start: 0, end: 10)],
            covered: [R(start: 2, end: 3), R(start: 5, end: 7)]
        ),
        [R(start: 0, end: 2), R(start: 3, end: 5), R(start: 7, end: 10)],
        "账本：缺口 = desired − covered"
    )
    checkEqual(
        TranscriptLedger.gaps(desired: [R(start: 2.5, end: 2.9)], covered: [R(start: 2, end: 3)]),
        [],
        "账本：全覆盖无缺口"
    )
    checkEqual(
        TranscriptLedger.padded(
            [R(start: 2, end: 3), R(start: 3.5, end: 4)], padding: 0.5,
            within: R(start: 0, end: 4.2)
        ),
        [R(start: 1.5, end: 4.2)],
        "账本：padding 后夹回素材范围并合并"
    )

    // 固定窗口切分：长素材断点续跑的粒度（每窗转写完立即落盘）。
    checkEqual(
        TranscriptLedger.windows([R(start: 0, end: 300)], maxDuration: 120),
        [R(start: 0, end: 120), R(start: 120, end: 240), R(start: 240, end: 300)],
        "账本：大缺口切成固定窗口"
    )
    checkEqual(
        TranscriptLedger.windows([R(start: 5, end: 20), R(start: 100, end: 130)], maxDuration: 120),
        [R(start: 5, end: 20), R(start: 100, end: 130)],
        "账本：小缺口不切"
    )
    check(
        TranscriptLedger.windows([R(start: 0, end: 250)], maxDuration: 120)
            .reduce(0) { $0 + $1.duration } == 250,
        "账本：切窗后总时长不变"
    )

    var entry = TranscriptCacheEntry(
        fingerprint: "f1", localeIdentifier: "en_US",
        transcriber: "SpeechTranscriber", configVersion: 1
    )
    entry.merge(
        words: [TimedWord(text: "old", start: 1, end: 2)],
        analyzed: R(start: 0, end: 3)
    )
    // 无语音的区间也要记 covered。
    entry.merge(words: [], analyzed: R(start: 3, end: 5))
    checkEqual(entry.covered, [R(start: 0, end: 5)], "账本：无语音区间也记 covered")
    // 重转区间内旧词被新结果覆盖。
    entry.merge(
        words: [TimedWord(text: "new", start: 1.2, end: 1.8)],
        analyzed: R(start: 1, end: 2)
    )
    checkEqual(entry.words.map(\.text), ["new"], "账本：重转区间旧词被替换")
    check(
        entry.matches(fingerprint: "f1", localeIdentifier: "en_US", transcriber: "SpeechTranscriber", configVersion: 1),
        "账本：指纹配置齐同才命中"
    )
    check(
        !entry.matches(fingerprint: "f1", localeIdentifier: "en_US", transcriber: "SpeechTranscriber", configVersion: 2),
        "账本：配置变了要失效"
    )
}

// MARK: - 按句排好的转写结果

private func checkSpeechTranscript() {
    func near(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 - b) < 1e-9 } ?? false }
    // 源 10–20 秒这一段，从时间线 100 秒起放、两倍速。
    let window = SubtitleClipWindow(
        clipID: UUID(), assetFingerprint: "f", sourceStart: 10, sourceEnd: 20, timelineStart: 100, speed: 2
    )
    let words = [
        TimedWord(text: "Hello", start: 10.5, end: 10.9),
        TimedWord(text: " there.", start: 10.9, end: 11.3),
        TimedWord(text: " How", start: 12, end: 12.2),
        TimedWord(text: " are", start: 12.2, end: 12.4),
        TimedWord(text: " you", start: 12.4, end: 12.7),
        TimedWord(text: " outside", start: 25, end: 25.5)
    ]
    let sentences = SpeechTranscript.sentences(words: words, window: window)
    checkEqual(sentences.map(\.text), ["Hello there.", "How are you"], "转写：句号成句，片段外的词不算")
    checkEqual(sentences.first?.words.map(\.text), ["Hello", "there."], "转写：词去掉首尾空白、标点跟着")
    check(near(sentences.first?.start, 100.25), "转写：源 10.5 秒在时间线 100.25 秒（两倍速）")
    check(near(sentences.last?.end, 101.35), "转写：句尾换算到时间线")
    check(near(sentences.first?.words.first?.sourceStart, 10.5), "转写：源时间留着")

    // 停顿后面第一个词被识别器往前拉长了：按估出来的开口（和生成字幕同一份）。
    let plain = SubtitleClipWindow(clipID: UUID(), assetFingerprint: "f", sourceStart: 0, sourceEnd: 40, timelineStart: 0)
    let stretched = SpeechTranscript.sentences(words: [
        TimedWord(text: "box.", start: 0.2, end: 0.6),
        TimedWord(text: " At", start: 1.68, end: 2.94),
        TimedWord(text: " the", start: 2.94, end: 3.1)
    ], window: plain)
    check(near(stretched.last?.start, 2.62), "转写：停顿后面的词从估出来的开口算（2.94 − 0.32）")

    // 一口气说很久：超过 40 个词切开，优先切在逗号后面。
    let long = (0..<50).map { index in
        TimedWord(text: index == 29 ? " w29," : " w\(index)", start: Double(index) * 0.3, end: Double(index) * 0.3 + 0.25)
    }
    checkEqual(SpeechTranscript.sentences(words: long, window: plain).map(\.words.count), [30, 20], "转写：长句切在逗号后面")
    let longer = (0..<90).map { index in
        TimedWord(text: " w\(index)", start: Double(index) * 0.3, end: Double(index) * 0.3 + 0.25)
    }
    checkEqual(SpeechTranscript.sentences(words: longer, window: plain).map(\.words.count), [40, 40, 10],
               "转写：没有逗号就按 40 个词切")

    let chinese = SpeechTranscript.sentences(words: [
        TimedWord(text: "南极", start: 0, end: 0.4),
        TimedWord(text: "探险", start: 0.4, end: 0.8),
        TimedWord(text: "开始了。", start: 0.8, end: 1.4)
    ], window: plain)
    checkEqual(chinese.map(\.text), ["南极探险开始了。"], "转写：中文不加空格")
}
