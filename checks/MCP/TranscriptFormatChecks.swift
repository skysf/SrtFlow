import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// transcribe 的结果写给 AI 看（AITranscriptFormat）：几段按时间排；from / to 只取这一段（跨过 from 的那句照给）；
// 超过字数就停在一句开头、回 next_from，拿它再读正好接上；逐词是 [词, 开始, 结束]；文件没有 id 和轨道名；
// 这一段没人说话要说出来。编法见 scripts/check-mcp.sh。

func runTranscriptFormatChecks() {
    let plain = SubtitleClipWindow(clipID: UUID(), assetFingerprint: "f", sourceStart: 0, sourceEnd: 100, timelineStart: 0)
    // 每 2 秒一句：「Line 0.」「Line 1.」……
    let words = (0..<20).flatMap { index -> [TimedWord] in
        let start = Double(index) * 2
        return [TimedWord(text: " Line", start: start, end: start + 0.4), TimedWord(text: " \(index).", start: start + 0.4, end: start + 0.8)]
    }
    let clip = AITranscriptFormat.Clip(
        id: "a1b2c3d4", track: "V1", name: "Lesson", start: 0, end: 40,
        sentences: SpeechTranscript.sentences(words: words, window: plain)
    )
    let all = AITranscriptFormat.json([clip], language: "en_US", from: nil, to: nil, words: false, maxChars: 12_000)
    let first = all["clips"]?.arrayValue?.first
    checkEqual(first?["sentences"]?.arrayValue?.count, 20, "every sentence fits")
    checkEqual(first?["id"]?.stringValue, "a1b2c3d4", "the clip id")
    checkEqual(first?["sentences"]?.arrayValue?.dropFirst(3).first?["text"]?.stringValue, "Line 3.", "the sentence text")
    check(all["next_from"] == nil, "nothing left over")

    let range = AITranscriptFormat.json([clip], language: "en_US", from: 8.5, to: 15, words: false, maxChars: 12_000)
    checkEqual(range["clips"]?.arrayValue?.first?["sentences"]?.arrayValue?.compactMap { $0["start"]?.doubleValue },
               [8, 10, 12, 14], "from / to: the sentence across from is included, none from to on")

    // 一次只给得下几句：停在一句开头，next_from 正好是它，拿它再读接得上。
    let page = AITranscriptFormat.json([clip], language: "en_US", from: nil, to: nil, words: false, maxChars: 250)
    let shown = page["clips"]?.arrayValue?.first?["sentences"]?.arrayValue ?? []
    check(!shown.isEmpty && shown.count < 20, "a small budget shows only part (got \(shown.count))")
    let next = page["next_from"]?.doubleValue
    checkEqual(next, Double(shown.count) * 2, "next_from is the first sentence left out")
    let rest = AITranscriptFormat.json([clip], language: "en_US", from: next, to: nil, words: false, maxChars: 12_000)
    checkEqual(rest["clips"]?.arrayValue?.first?["sentences"]?.arrayValue?.first?["start"]?.doubleValue, next,
               "reading from next_from starts right there")

    let withWords = AITranscriptFormat.json([clip], language: "en_US", from: 0, to: 1, words: true, maxChars: 12_000)
    let firstWords = withWords["clips"]?.arrayValue?.first?["sentences"]?.arrayValue?.first?["words"]?.arrayValue
    checkEqual(firstWords?.first?.arrayValue?.compactMap(\.stringValue), ["Line"], "a word is [text, start, end]")
    checkEqual(firstWords?.last?.arrayValue?.compactMap(\.doubleValue), [0.4, 0.8], "with its times")

    var file = clip
    file.id = nil
    file.track = nil
    let fromFile = AITranscriptFormat.json([file], language: "en_US", from: nil, to: 3, words: false, maxChars: 12_000)
    let fileClip = fromFile["clips"]?.arrayValue?.first
    check(fileClip?["id"] == nil && fileClip?["track"] == nil, "a file has no clip id or track")

    let silent = AITranscriptFormat.json([clip], language: "en_US", from: 60, to: 70, words: false, maxChars: 12_000)
    checkEqual(silent["clips"]?.arrayValue?.count, 0, "nothing said in that range")
    checkEqual(silent["note"]?.stringValue, "Nothing was said in this range.", "and it says so")
}
