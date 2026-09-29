import Foundation
import SrtFlowMCPKit

// MARK: - fal 回来的东西怎么读（纯值）
//
// 管什么：一次生成做完，fal 回的 JSON 里哪个字段是成品的下载地址（图 / 视频 / 音频各在各的地方）、文件该叫什么后缀，
// 以及旁白模型报的「每个词在第几秒」（ElevenLabs 的 `timestamps`）读成 `FalWordTime`。
// 每个登记端点的输出形状也是 2026-09-29 从 fal 的接口定义读的（`checks/Fal/schemas/` 的快照）：
// 图在 `images[0].url`、视频在 `video.url`、音频在 `audio.url`。没登记的端点按这几个常见的位置找。
// **`timestamps` 的形状 fal 没写**（定义里只说「每个词的时间」、元素是空定义）：这里认三种常见写法，读不出来就当没有词时间，
// 字幕退回按整句排 —— 拿真的 Key 跑第一次时要对一遍（docs/architecture/fal-generation.md 的人工清单）。
// 不管什么：下载（FalClient）、放到哪（FalGenerateTool）。

struct FalMedia: Equatable {
    var url: URL
    /// 不带点：`mp4`、`png`、`mp3`……
    var fileExtension: String
    var contentType: String?
    /// 图片给的宽高（fal 有的模型回）。
    var width: Int?
    var height: Int?
    /// 音频 / 视频给的时长（秒）；没给就是 nil。
    var duration: Double?
}

struct FalWordTime: Equatable {
    var text: String
    var start: Double
    var end: Double
}

enum FalOutputs {

    // MARK: 成品在哪

    /// 这些键里第一个能读出下载地址的就是成品。
    private static let mediaKeys = ["video", "videos", "audio", "audios", "audio_url", "audio_file", "images", "image", "file", "output"]

    static func media(from result: JSONValue, kind: FalModel.Kind) throws -> FalMedia {
        for key in mediaKeys {
            guard let value = result[key], let entry = firstFile(in: value) else { continue }
            guard let text = entry["url"]?.stringValue, let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased()) else {
                continue
            }
            let contentType = entry["content_type"]?.stringValue
            return FalMedia(
                url: url,
                fileExtension: fileExtension(name: entry["file_name"]?.stringValue, contentType: contentType, url: url, kind: kind),
                contentType: contentType,
                width: entry["width"]?.intValue,
                height: entry["height"]?.intValue,
                duration: entry["duration"]?.doubleValue ?? result["duration"]?.doubleValue
            )
        }
        throw FalOutputError("fal.ai finished but its answer had no file to download.")
    }

    /// 一个文件对象，或文件对象的列表里的第一个。
    private static func firstFile(in value: JSONValue) -> JSONValue? {
        switch value {
        case .object: return value["url"] != nil ? value : nil
        case .array(let items): return items.first.flatMap(firstFile)
        default: return nil
        }
    }

    static func fileExtension(name: String?, contentType: String?, url: URL, kind: FalModel.Kind) -> String {
        let known: [String: String] = [
            "video/mp4": "mp4", "video/quicktime": "mov", "video/webm": "webm",
            "image/png": "png", "image/jpeg": "jpg", "image/webp": "webp",
            "audio/mpeg": "mp3", "audio/mp3": "mp3", "audio/wav": "wav", "audio/x-wav": "wav", "audio/wave": "wav",
            "audio/aac": "aac", "audio/mp4": "m4a", "audio/x-m4a": "m4a", "audio/flac": "flac", "audio/ogg": "ogg"
        ]
        let allowed: Set<String> = ["mp4", "mov", "webm", "png", "jpg", "jpeg", "webp", "mp3", "wav", "aac", "m4a", "flac", "ogg"]
        if let name, case let ext = (name as NSString).pathExtension.lowercased(), allowed.contains(ext) { return ext }
        if let type = contentType?.lowercased().split(separator: ";").first.map(String.init), let ext = known[type] { return ext }
        let fromURL = url.pathExtension.lowercased()
        if allowed.contains(fromURL) { return fromURL }
        switch kind {
        case .image: return "png"
        case .imageToVideo, .textToVideo: return "mp4"
        case .voice, .voiceClone, .music, .soundEffect: return "mp3"
        }
    }

    // MARK: 每个词在第几秒

    /// 旁白模型报的词时间（秒）。读不出来 / 读出来不像样就是空数组。
    static func wordTimes(from result: JSONValue) -> [FalWordTime] {
        guard let raw = result["timestamps"] else { return [] }
        let words = parseWords(raw)
        return sane(words) ? words : []
    }

    private static func parseWords(_ raw: JSONValue) -> [FalWordTime] {
        // 三种写法：一：`{characters, character_start_times_seconds, character_end_times_seconds}`（ElevenLabs 的对齐，可能包在 alignment 里）；
        // 二：`[{word|text, start, end}, …]`；三：`[[text, start, end], …]`。
        if let alignment = alignmentObject(in: raw) { return words(fromCharacters: alignment) }
        guard case .array(let items) = raw else { return [] }
        var entries: [FalWordTime] = []
        for item in items {
            switch item {
            case .object(let object):
                guard let text = firstString(object, ["word", "text", "token", "char", "character"]),
                      let start = firstNumber(object, ["start", "start_time", "start_s", "startTime", "begin"]),
                      let end = firstNumber(object, ["end", "end_time", "end_s", "endTime", "stop"]) else { return [] }
                entries.append(FalWordTime(text: text, start: start, end: end))
            case .array(let triple):
                guard triple.count >= 3, let text = triple[0].stringValue, let start = triple[1].doubleValue,
                      let end = triple[2].doubleValue else { return [] }
                entries.append(FalWordTime(text: text, start: start, end: end))
            default:
                return []
            }
        }
        // 每一项只有一个字符、中间还有空白项（按字对齐）：拼成词。（没有空白项时不拼：可能就是「a」「I」这样的单字母词，
        // 或者中日文按字报的 —— 一个字一个词正好当字幕的词用。）
        if entries.count > 1, entries.allSatisfy({ $0.text.count == 1 }),
           entries.contains(where: { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return group(characters: entries.map { ($0.text, $0.start, $0.end) })
        }
        return entries.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private static func alignmentObject(in raw: JSONValue) -> [String: JSONValue]? {
        func isAlignment(_ object: [String: JSONValue]) -> Bool {
            object["characters"] != nil && object["character_start_times_seconds"] != nil
        }
        if case .object(let object) = raw {
            if isAlignment(object) { return object }
            for key in ["alignment", "normalized_alignment"] {
                if case .object(let inner)? = object[key], isAlignment(inner) { return inner }
            }
        }
        if case .array(let items) = raw, case .object(let first)? = items.first {
            if isAlignment(first) { return first }
            if case .object(let inner)? = first["alignment"], isAlignment(inner) { return inner }
        }
        return nil
    }

    private static func words(fromCharacters alignment: [String: JSONValue]) -> [FalWordTime] {
        guard case .array(let characters)? = alignment["characters"],
              case .array(let starts)? = alignment["character_start_times_seconds"],
              case .array(let ends)? = alignment["character_end_times_seconds"],
              characters.count == starts.count, starts.count == ends.count else { return [] }
        var triples: [(String, Double, Double)] = []
        for index in characters.indices {
            guard let text = characters[index].stringValue, let start = starts[index].doubleValue, let end = ends[index].doubleValue else { return [] }
            triples.append((text, start, end))
        }
        return group(characters: triples)
    }

    /// 一个字符一项 → 按空白断成词。整段没有空白、又是中日韩的字：一个字一个词（不然整句拼成一个词，字幕就没法断了）。
    private static func group(characters: [(String, Double, Double)]) -> [FalWordTime] {
        if let first = characters.first?.0.unicodeScalars.first, isCJK(first),
           !characters.contains(where: { $0.0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return characters.map { FalWordTime(text: $0.0, start: $0.1, end: $0.2) }
        }
        var words: [FalWordTime] = []
        var current: FalWordTime?
        for (text, start, end) in characters {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let done = current { words.append(done); current = nil }
                continue
            }
            if var word = current {
                word.text += text
                word.end = end
                current = word
            } else {
                current = FalWordTime(text: text, start: start, end: end)
            }
        }
        if let done = current { words.append(done) }
        return words
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        (0x3040...0x30FF).contains(scalar.value) || (0x3400...0x9FFF).contains(scalar.value) || (0xAC00...0xD7AF).contains(scalar.value)
    }

    /// 像样的词时间：非空、不倒退、都是有限的数、每个词至少有一点长度。
    static func sane(_ words: [FalWordTime]) -> Bool {
        guard !words.isEmpty else { return false }
        var previousStart = -Double.infinity
        for word in words {
            guard word.start.isFinite, word.end.isFinite, word.start >= 0, word.end >= word.start, word.start >= previousStart else { return false }
            previousStart = word.start
        }
        return true
    }

    private static func firstString(_ object: [String: JSONValue], _ keys: [String]) -> String? {
        keys.lazy.compactMap { object[$0]?.stringValue }.first
    }

    private static func firstNumber(_ object: [String: JSONValue], _ keys: [String]) -> Double? {
        keys.lazy.compactMap { object[$0]?.doubleValue }.first
    }
}

struct FalOutputError: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
}
