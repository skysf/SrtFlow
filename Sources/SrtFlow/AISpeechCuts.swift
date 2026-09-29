import Foundation
import SrtFlowCore

// MARK: - cut_speech：要剪掉哪几截、怎么剪（纯值）
//
// 管什么：一段口播（V1 上的片段）要剪掉的区间 —— AI 点名要删 / 要留的（按文字剪：时间从 transcribe 来）、太长的停顿、
// 口头禅、说重了的词 —— 合并成一串切口，再落到时间线上。切口都落在**词和词之间的空隙中点**（离词最多 0.3 秒）：
// 不切半个词，两边各留一点气口。落到时间线上用的是手动那一套：从最后一刀往前，`LinkRegrouping.split` 切开、
// `AITimelineEdits.delete` 带波纹删掉中间那块 —— 后面的 V1 片段往前补，**链接的声音不管开关都跟着切**
// （剪口播剪到画面和声音对不上，不会是 AI 想要的）。
// 不管什么：量声音、读转写、参数（AISpeechCutTool）；说明文字（SrtFlowMCPKit/MCPSmartEditTools.swift）。

enum AISpeechCuts {
    /// 一刀：时间线秒（片段现在的位置），为什么剪。
    struct Cut: Equatable {
        var start: Double
        var end: Double
        var reason: String
    }

    /// 切口离词最多挪多远（秒）。
    static let maxShift = 0.3
    /// 两刀之间剩下的比这短，就一起剪掉（留一截零点几秒的碎片没意思）。
    static let minPiece = 0.2

    // MARK: 切口落在哪

    /// 一段的开头（要剪掉的、或者要留下的那段话从这里起）：一个词大半截在这一刻后面，就算在这段里（按词的中点判：
    /// 识别器给的相邻两个词偶尔重叠几毫秒，按词尾判会错到前一个词上）。这一刻落在词上、或者正好在词的边上，挪进这个词
    /// 前面那个空隙的中点（离词最多 `maxShift`；前面没有词就是词前 `maxShift`）；已经落在空隙中间（AI 特意挑的静音处）就不动。
    static func startPoint(_ time: Double, words: [SpeechTranscript.Word]) -> Double {
        guard let index = words.firstIndex(where: { ($0.start + $0.end) / 2 > time }) else { return time }
        let word = words[index]
        let previousEnd = index > 0 ? words[index - 1].end : nil
        let onWord = time >= word.start - 0.001 || previousEnd.map { time <= $0 + 0.001 } == true
        guard onWord else { return time }
        let bound = word.start - maxShift
        return previousEnd.map { max(($0 + word.start) / 2, bound) } ?? bound
    }

    /// 一段的结尾：同样的规则，挪进这个词后面那个空隙的中点（后面没有词就是词后 `maxShift`）。
    static func endPoint(_ time: Double, words: [SpeechTranscript.Word]) -> Double {
        guard let index = words.lastIndex(where: { ($0.start + $0.end) / 2 < time }) else { return time }
        let word = words[index]
        let nextStart = index + 1 < words.count ? words[index + 1].start : nil
        let onWord = time <= word.end + 0.001 || nextStart.map { time >= $0 - 0.001 } == true
        guard onWord else { return time }
        let bound = word.end + maxShift
        return nextStart.map { min((word.end + $0) / 2, bound) } ?? bound
    }

    // MARK: 几种要剪的

    /// AI 点名要剪掉的区间。
    static func requested(_ ranges: [ClosedRange<Double>], words: [SpeechTranscript.Word]) -> [Cut] {
        ranges.map { range in
            Cut(start: startPoint(range.lowerBound, words: words), end: endPoint(range.upperBound, words: words), reason: "requested")
        }
    }

    /// 只留这几段：片段里其余的都剪掉。
    static func outside(_ keep: [ClosedRange<Double>], clip: ClosedRange<Double>, words: [SpeechTranscript.Word]) -> [Cut] {
        let kept = keep.map { startPoint($0.lowerBound, words: words)...endPoint($0.upperBound, words: words) }
            .sorted { $0.lowerBound < $1.lowerBound }
        var cuts: [Cut] = []
        var cursor = clip.lowerBound
        for range in kept {
            if range.lowerBound > cursor { cuts.append(Cut(start: cursor, end: range.lowerBound, reason: "not kept")) }
            cursor = max(cursor, range.upperBound)
        }
        if cursor < clip.upperBound { cuts.append(Cut(start: cursor, end: clip.upperBound, reason: "not kept")) }
        return cuts
    }

    /// 比 `longerThan` 长的停顿缩到 `leave` 秒（两头各留一半）。
    static func pauses(_ silences: [ClosedRange<Double>], longerThan: Double, leave: Double) -> [Cut] {
        silences.compactMap { silence in
            guard silence.upperBound - silence.lowerBound >= longerThan else { return nil }
            let start = silence.lowerBound + leave / 2
            let end = silence.upperBound - leave / 2
            return end > start ? Cut(start: start, end: end, reason: "pause") : nil
        }
    }

    /// 口头禅（英文、中文、日文常见的几个，按整个词认）。
    static let fillers: Set<String> = [
        "um", "umm", "uh", "uhh", "uhm", "erm", "er", "hmm", "mm", "mhm",
        "嗯", "嗯嗯", "呃", "呃呃", "额", "唔",
        "えー", "えーと", "えっと", "えーっと", "あのー"
    ]

    static func fillerWords(_ words: [SpeechTranscript.Word]) -> [Cut] {
        words.indices.compactMap { index in
            let word = words[index]
            guard fillers.contains(normalized(word.text)) else { return nil }
            return Cut(
                start: startPoint(word.start, words: words), end: endPoint(word.end, words: words),
                reason: "filler: \(word.text)"
            )
        }
    }

    /// 说重了：同一个词（或两个词）紧接着又说了一遍（中间不到 0.6 秒），剪掉前面那遍。前一遍以句号、问号、叹号收尾的不算
    /// （「…do this. This is…」是两句话，2026-09-28 冒烟时被当成了口吃）。
    static func repeats(_ words: [SpeechTranscript.Word]) -> [Cut] {
        let keys = words.map { normalized($0.text) }
        var cuts: [Cut] = []
        var index = 0
        while index < words.count {
            var matched = false
            for length in [2, 1] where index + 2 * length <= words.count {
                let first = keys[index..<(index + length)]
                let second = keys[(index + length)..<(index + 2 * length)]
                guard first.allSatisfy({ !$0.isEmpty }), Array(first) == Array(second),
                      !endsSentence(words[index + length - 1].text),
                      words[index + length].start - words[index + length - 1].end < 0.6 else { continue }
                cuts.append(Cut(
                    start: startPoint(words[index].start, words: words),
                    end: startPoint(words[index + length].start, words: words),
                    reason: "repeat: " + words[index..<(index + length)].map(\.text).joined(separator: " ")
                ))
                index += length
                matched = true
                break
            }
            if !matched { index += 1 }
        }
        return cuts
    }

    private static func endsSentence(_ text: String) -> Bool {
        text.last { !$0.isWhitespace }.map { ".!?…。！？".contains($0) } ?? false
    }

    static func normalized(_ text: String) -> String {
        text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols))
    }

    // MARK: 合并

    /// 排好、夹进片段、合并重叠的和挨得太近的（中间剩不到 `minPiece`）、对齐到帧；太短（不到两帧）的不剪。
    static func merged(_ cuts: [Cut], clip: ClosedRange<Double>, frame: Double) -> [Cut] {
        let snap = { (time: Double) in frame > 0 ? (time / frame).rounded() * frame : time }
        var result: [Cut] = []
        for cut in cuts.sorted(by: { $0.start < $1.start }) {
            let start = max(clip.lowerBound, snap(cut.start))
            let end = min(clip.upperBound, snap(cut.end))
            guard end > start else { continue }
            if var last = result.last, start - last.end < minPiece {
                last.end = max(last.end, end)
                if !last.reason.contains(cut.reason) { last.reason += ", " + cut.reason }
                result[result.count - 1] = last
            } else {
                result.append(Cut(start: start, end: end, reason: cut.reason))
            }
        }
        // 片段头尾剩下一点点：一起剪掉。
        if var first = result.first, first.start - clip.lowerBound < minPiece, first.start > clip.lowerBound {
            first.start = clip.lowerBound
            result[0] = first
        }
        if var last = result.last, clip.upperBound - last.end < minPiece, last.end < clip.upperBound {
            last.end = clip.upperBound
            result[result.count - 1] = last
        }
        return result.filter { $0.end - $0.start >= 2 * frame - 1e-9 }
    }

    /// 停顿的门限（dB）没给时从这一段自己量：底噪（10 分位）往说话（70 分位）走 35%，夹在 −60…−30。
    /// 整段都在说话时算出来会高过 −30，夹回来之后就找不到停顿（对的）。
    static func silenceThreshold(_ decibels: [Double]) -> Double {
        guard decibels.count >= 10 else { return -45 }
        let sorted = decibels.sorted()
        let floor = sorted[sorted.count / 10]
        let speech = sorted[sorted.count * 7 / 10]
        return min(-30, max(-60, floor + 0.35 * (speech - floor)))
    }

    // MARK: 落到时间线上

    /// 从最后一刀往前：切开、删掉中间那块（带波纹、带链接的声音）。返回剩下的那几块（V1 上，按时间排）。
    static func apply(_ cuts: [Cut], to clipID: UUID, in state: inout TimelineState) -> [UUID] {
        let before = Set(state.allClips.map(\.id))
        for cut in cuts.sorted(by: { $0.start > $1.start }) {
            guard let clip = state.clip(with: clipID) else { break }
            if cut.end < clip.timelineEnd - epsilon {
                LinkRegrouping.split(Array(state.linkedClipIDs(of: clipID)), at: cut.end, in: &state)
            }
            let middle: [UUID]
            if cut.start > clip.timelineStart + epsilon {
                middle = LinkRegrouping.split(Array(state.linkedClipIDs(of: clipID)), at: cut.start, in: &state)
            } else {
                middle = Array(state.linkedClipIDs(of: clipID))
            }
            AITimelineEdits.delete(.init(clips: Set(middle)), ripple: true, linkage: true, in: &state)
        }
        return state.mainClips
            .filter { !before.contains($0.id) || $0.id == clipID }
            .sorted { $0.timelineStart < $1.timelineStart }
            .map(\.id)
    }

    private static let epsilon = 0.000_5
}
