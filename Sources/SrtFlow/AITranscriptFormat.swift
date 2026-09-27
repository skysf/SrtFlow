import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - transcribe 的结果写给 AI 看（纯值）
//
// 管什么：几段素材的句子（`SpeechTranscript`）→ JSON：每段一组句子（开始、结束、原话），要逐词时每句再带
// [词, 开始, 结束]；从 `from` 读到 `to`，一次最多约 `maxChars` 个字，读不完回 `next_from`（下次从那儿接着读）。
// 时间保留两位小数（10 毫秒，切口用不着更细，还省 token）。
// 不管什么：转写和缓存（TranscriptionTask / TranscriptHarvester）、取哪几段、读哪份缓存（AITranscribeTool）。

enum AITranscriptFormat {
    struct Clip {
        /// 时间线上的片段：短 id 和轨道名。给的是文件时两个都是 nil，时间是文件里的秒。
        var id: String?
        var track: String?
        var name: String
        var start: Double
        var end: Double
        var sentences: [SpeechTranscript.Sentence]
    }

    static let defaultMaxChars = 12_000

    static func json(
        _ clips: [Clip], language: String, from: Double?, to: Double?, words: Bool, maxChars: Int
    ) -> JSONValue {
        var used = 0
        var nextFrom: Double?
        var listed: [JSONValue] = []
        clipLoop: for clip in clips.sorted(by: { $0.start < $1.start }) {
            var sentences: [JSONValue] = []
            for sentence in clip.sentences {
                if let from, sentence.end <= from { continue }
                if let to, sentence.start >= to { break }
                let cost = sentence.text.count + 40
                    + (words ? sentence.words.reduce(0) { $0 + $1.text.count + 24 } : 0)
                if used > 0, used + cost > maxChars {
                    nextFrom = sentence.start
                    if !sentences.isEmpty { listed.append(clipJSON(clip, sentences)) }
                    break clipLoop
                }
                used += cost
                sentences.append(sentenceJSON(sentence, words: words))
            }
            if !sentences.isEmpty { listed.append(clipJSON(clip, sentences)) }
        }
        var result: [String: JSONValue] = [
            "language": .string(language),
            "clips": .array(listed),
            "note": .string(
                "Times are timeline seconds (seconds in the file when you gave a file). To cut, pass sentence or word "
                    + "times to cut_speech as keep or remove ranges."
            )
        ]
        if listed.isEmpty { result["note"] = "Nothing was said in this range." }
        if let nextFrom {
            result["next_from"] = time(nextFrom)
            result["truncated"] = .string("Call transcribe again with from = next_from for the rest.")
        }
        return .object(result)
    }

    private static func clipJSON(_ clip: Clip, _ sentences: [JSONValue]) -> JSONValue {
        var object: [String: JSONValue] = [
            "name": .string(clip.name),
            "start": time(clip.start),
            "end": time(clip.end),
            "sentences": .array(sentences)
        ]
        if let id = clip.id { object["id"] = .string(id) }
        if let track = clip.track { object["track"] = .string(track) }
        return .object(object)
    }

    private static func sentenceJSON(_ sentence: SpeechTranscript.Sentence, words: Bool) -> JSONValue {
        var object: [String: JSONValue] = [
            "start": time(sentence.start), "end": time(sentence.end), "text": .string(sentence.text)
        ]
        if words {
            object["words"] = .array(sentence.words.map { .array([.string($0.text), time($0.start), time($0.end)]) })
        }
        return .object(object)
    }

    static func time(_ seconds: Double) -> JSONValue { .number((seconds * 100).rounded() / 100) }
}
