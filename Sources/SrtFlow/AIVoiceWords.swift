import Foundation
import SrtFlowCore

// MARK: - 配音的词在哪一刻（纯值）
//
// 管什么：系统朗读时每个词报一个标记（字在原文里的范围 + 在音频里的第几帧），换成生成字幕那一套认的带时间的词
// （`TimedWord`，文件里的秒）：词的写法照识别器的 —— 英文词带着前面的空格、标点贴在词后面，于是断句、去标点、
// 排显示时间直接走 `SubtitleSegmenter`（同一条规则只有一处实现）。
// - 标点自己也会被报成一个「词」（「，」「。」）：并进前一个词，不单独占时间。
// - 词的开头 = 标记那一帧（2026-09-28 探针：停顿后第一个词的标记正好落在静音结束处，中英文都是）。
// - 词的结尾 = 下一个词的开头，再往回收掉中间的静音（句末的停顿不算进这个词）；最后一个词收到声音结束。
// 不管什么：怎么合成（AISpeechSynthesis）、字幕怎么落到轨上（AIVoiceoverSubtitles）。

enum AIVoiceWords {
    struct Marker: Equatable {
        /// 字在原文里的范围（UTF-16，NSRange 的口径）。
        var location: Int
        var length: Int
        /// 在音频里的第几帧（`byteSampleOffset / 每帧字节数`）。
        var frame: Int
    }

    /// 比这个轻的 10 毫秒算静音（-50 dBFS 左右）。
    static let silenceRMS: Float = 0.003

    static func words(text: String, markers: [Marker], samples: [Float], sampleRate: Double) -> [TimedWord] {
        let utf16 = Array(text.utf16)
        func slice(_ from: Int, _ to: Int) -> String {
            let lower = min(max(from, 0), utf16.count)
            let upper = min(max(to, lower), utf16.count)
            return String(decoding: utf16[lower..<upper], as: UTF16.self)
        }
        var pieces: [(text: String, frame: Int)] = []
        var consumed = 0
        for marker in markers.sorted(by: { $0.location < $1.location }) {
            let end = marker.location + marker.length
            guard end > consumed else { continue }
            let own = slice(marker.location, end)
            if own.unicodeScalars.allSatisfy({ CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines).union(.symbols).contains($0) }),
               !pieces.isEmpty {
                // 标点并进前一个词（「好，」「there.」）。
                pieces[pieces.count - 1].text += slice(consumed, end)
            } else {
                pieces.append((slice(consumed, end), marker.frame))
            }
            consumed = end
        }
        // 最后一个词后面还剩的（句号、引号）贴在它后面。
        if !pieces.isEmpty, consumed < utf16.count {
            let rest = slice(consumed, utf16.count)
            if !rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                pieces[pieces.count - 1].text += rest.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        guard sampleRate > 0 else { return [] }
        let lastSound = lastSoundFrame(samples, before: samples.count, sampleRate: sampleRate)
        return pieces.enumerated().compactMap { index, piece in
            let startFrame = min(max(piece.frame, 0), samples.count)
            let nextFrame = index + 1 < pieces.count ? min(pieces[index + 1].frame, samples.count) : lastSound
            let endFrame = max(lastSoundFrame(samples, before: max(nextFrame, startFrame), sampleRate: sampleRate), startFrame)
            let start = Double(startFrame) / sampleRate
            // 至少 20 毫秒：静音里开口的词（标记落在一小段静音上）也得有个长度。
            let end = max(Double(endFrame) / sampleRate, start + 0.02)
            guard !piece.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return TimedWord(text: piece.text, start: start, end: end)
        }
    }

    /// `before` 之前最后一个有声音的 10 毫秒窗的结尾（帧）；全是静音就是 0。
    static func lastSoundFrame(_ samples: [Float], before limit: Int, sampleRate: Double) -> Int {
        let window = max(1, Int(sampleRate * 0.01))
        var end = min(limit, samples.count)
        while end > 0 {
            let start = max(0, end - window)
            var sum: Float = 0
            for index in start..<end { sum += samples[index] * samples[index] }
            if (sum / Float(end - start)).squareRoot() >= silenceRMS { return end }
            end = start
        }
        return 0
    }
}
