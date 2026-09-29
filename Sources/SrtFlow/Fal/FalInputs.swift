import Foundation
import SrtFlowMCPKit

// MARK: - 给 fal 的请求怎么写（纯值）
//
// 管什么：一次生成的参数（`FalRequest`）→ 每个登记过的端点各自认的请求体（`FalDialect`）。每个端点的字段名、取值范围、
// 必填项，是 2026-09-29 从 fal 公开的接口定义（`https://fal.ai/api/openapi/queue/openapi.json?endpoint_id=…`）读的，
// 定义的快照放在 `checks/Fal/schemas/`，自检把这里造出来的请求体逐条对着快照验（必填、取值、范围、有没有多余的字段）。
// 没登记的端点（用户在设置里填的、AI 在对话里点名的）走 `.generic`：只写最基本的一两个字段，其余全由 AI 用 `options` 传 ——
// 它点名了这个模型，就该知道它的参数。
// 不管什么：读文件转 data URI、问用户、调 HTTP（FalGenerateTool / FalClient）；返回结果怎么读（FalOutputs）。

struct FalInputError: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
}

/// 一次生成要的东西。不用的字段留 nil；工具把 AI 传来的参数读成这个样子。
struct FalRequest: Equatable {
    var kind: FalModel.Kind
    /// 图 / 视频 / 音乐 / 音效：描述；旁白和克隆：要读的话。
    var prompt: String
    /// 图生视频的首帧：URL 或 data URI。
    var imageURL: String?
    /// 视频 / 音乐 / 音效想要的时长（秒）。
    var seconds: Double?
    /// 视频分辨率档：`480P` / `768P` / `1080P`（大小写都收）。
    var resolution: String?
    /// 画幅：`16:9`、`9:16`……
    var aspectRatio: String?
    /// 音乐：只要纯音乐（视频配乐几乎都是）。
    var instrumental = true
    /// 旁白的音色名（ElevenLabs 的预制音色，如 `Rachel`）。
    var voice: String?
    /// 文字的语言（zh / en / ja……，克隆用它选文本规整的语言）。
    var language: String?
    /// 克隆：参考音频（URL 或 data URI）。
    var referenceAudioURL: String?
    /// 要词的时间（旁白配字幕用）。
    var wantsWordTimes = false
    /// AI 直接传给 fal 的其余字段，盖在上面这些之上。
    var options: [String: JSONValue] = [:]

    init(kind: FalModel.Kind, prompt: String) {
        self.kind = kind
        self.prompt = prompt
    }
}

/// 登记过的端点各有一种写法。
enum FalDialect: Equatable, Sendable {
    case seedreamImage
    case h3MaxTextToVideo
    case h3MaxImageToVideo
    case elevenV4Voice
    case zonos2Clone
    case elevenMusic
    case soniloSoundEffects
    case generic

    static let byEndpoint: [String: FalDialect] = [
        "bytedance/seedream/v5/flash/text-to-image": .seedreamImage,
        "minimax/h3-max/text-to-video": .h3MaxTextToVideo,
        "minimax/h3-max/image-to-video": .h3MaxImageToVideo,
        "elevenlabs/tts/eleven-v4": .elevenV4Voice,
        "fal-ai/zonos2": .zonos2Clone,
        "elevenlabs/music/v2.5": .elevenMusic,
        "sonilo/v1.1/text-to-sound-effects": .soniloSoundEffects
    ]

    init(endpoint: String) {
        self = Self.byEndpoint[endpoint.trimmingCharacters(in: .whitespaces).lowercased()] ?? .generic
    }
}

enum FalInputs {

    // MARK: 各种取值

    static let videoResolutions = ["480P", "768P", "1080P"]
    static let defaultResolution = "768P"
    static let h3MaxDurations = 5...15
    static let h3MaxTextAspects = ["21:9", "16:9", "4:3", "1:1", "3:4", "9:16"]
    static let elevenMusicLength = 3.0...600.0
    static let soundEffectLength = 0.5...180.0
    static let elevenPromptLimit = 5_000
    static let musicPromptLimit = 4_100

    /// 只把 H3 Max 的三档认出来：`768p`、`768P`、`768` 都算。
    static func normalizedResolution(_ text: String?) throws -> String {
        guard let text, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return defaultResolution }
        let key = text.trimmingCharacters(in: .whitespaces).uppercased()
        let withP = key.hasSuffix("P") ? key : key + "P"
        guard videoResolutions.contains(withP) else {
            throw FalInputError("resolution must be one of: 480p, 768p, 1080p.")
        }
        return withP
    }

    /// 一个画幅在给定的几个选项里离谁最近（按宽高比取对数差）。
    static func nearestAspect(to ratio: Double, in options: [String]) -> String {
        guard ratio > 0 else { return options.first ?? "16:9" }
        var best = options.first ?? "16:9"
        var bestGap = Double.infinity
        for option in options {
            guard let value = aspectValue(option) else { continue }
            let gap = abs(log(value / ratio))
            if gap < bestGap { best = option; bestGap = gap }
        }
        return best
    }

    /// `16:9` → 1.777…；写不对就是 nil。
    static func aspectValue(_ text: String) -> Double? {
        let parts = text.split(separator: ":")
        guard parts.count == 2, let width = Double(parts[0]), let height = Double(parts[1]), width > 0, height > 0 else { return nil }
        return width / height
    }

    // MARK: 用量（估价用）

    static func usage(for request: FalRequest) -> FalUsage {
        var usage = FalUsage()
        switch request.kind {
        case .image:
            usage.images = 1
        case .imageToVideo, .textToVideo:
            usage.seconds = Double(clampedVideoSeconds(request.seconds))
            usage.tier = (try? normalizedResolution(request.resolution)) ?? defaultResolution
        case .voice:
            usage.characters = request.prompt.count
        case .voiceClone:
            usage.characters = request.prompt.count
            usage.seconds = FalUsage.speechSeconds(characters: request.prompt.count)
        case .music:
            usage.seconds = clampedMusicSeconds(request.seconds)
        case .soundEffect:
            usage.seconds = clampedEffectSeconds(request.seconds)
        }
        return usage
    }

    static func clampedVideoSeconds(_ seconds: Double?) -> Int {
        let wanted = Int((seconds ?? 5).rounded())
        return min(max(wanted, h3MaxDurations.lowerBound), h3MaxDurations.upperBound)
    }

    static func clampedMusicSeconds(_ seconds: Double?) -> Double {
        min(max(seconds ?? 30, elevenMusicLength.lowerBound), elevenMusicLength.upperBound)
    }

    static func clampedEffectSeconds(_ seconds: Double?) -> Double {
        min(max(seconds ?? 5, soundEffectLength.lowerBound), soundEffectLength.upperBound)
    }

    // MARK: 请求体

    /// 给这个端点的请求体。写错了（参数超出这个模型认的范围）抛 `FalInputError`，话是写给 AI 看的。
    static func body(_ request: FalRequest, dialect: FalDialect) throws -> JSONValue {
        var body: [String: JSONValue]
        switch dialect {
        case .seedreamImage: body = try seedream(request)
        case .h3MaxTextToVideo: body = try h3Max(request, image: false)
        case .h3MaxImageToVideo: body = try h3Max(request, image: true)
        case .elevenV4Voice: body = try elevenVoice(request)
        case .zonos2Clone: body = try zonos(request)
        case .elevenMusic: body = try elevenMusic(request)
        case .soniloSoundEffects: body = try soundEffects(request)
        case .generic: body = try generic(request)
        }
        body.merge(request.options) { _, mine in mine }
        return .object(body)
    }

    private static func requirePrompt(_ request: FalRequest, what: String) throws -> String {
        let text = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw FalInputError("\(what) is required.") }
        return text
    }

    private static func seedream(_ request: FalRequest) throws -> [String: JSONValue] {
        var body: [String: JSONValue] = [
            "prompt": .string(try requirePrompt(request, what: "prompt")),
            "num_images": 1,
            "output_format": "png"
        ]
        body["image_size"] = try seedreamSize(aspect: request.aspectRatio)
        return body
    }

    /// Seedream 的 `image_size`：常见画幅有现成的名字，别的按宽高写（总像素 1024² 到 2048²、宽高比 1/16 到 16 之间）。
    static func seedreamSize(aspect: String?) throws -> JSONValue {
        guard let aspect, !aspect.isEmpty else { return "landscape_16_9" }
        let named: [String: String] = [
            "16:9": "landscape_16_9", "9:16": "portrait_16_9", "4:3": "landscape_4_3", "3:4": "portrait_4_3", "1:1": "square_hd"
        ]
        if let name = named[aspect] { return .string(name) }
        guard let ratio = aspectValue(aspect), ratio >= 1.0 / 16, ratio <= 16 else {
            throw FalInputError("aspect_ratio must look like 16:9 (width:height).")
        }
        // 约 250 万像素：落在 1024² 和 2048² 之间；宽高取 16 的倍数。
        let area = 2_359_296.0
        let height = (sqrt(area / ratio) / 16).rounded() * 16
        let width = (height * ratio / 16).rounded() * 16
        return ["width": .number(width), "height": .number(height)]
    }

    private static func h3Max(_ request: FalRequest, image: Bool) throws -> [String: JSONValue] {
        var body: [String: JSONValue] = [
            "prompt": .string(try requirePrompt(request, what: "prompt")),
            // fal 的定义里这一项是必填（虽然有默认值）。
            "prompt_expansion_mode": "balanced",
            "duration": .number(Double(clampedVideoSeconds(request.seconds))),
            "resolution": .string(try normalizedResolution(request.resolution))
        ]
        if image {
            guard let url = request.imageURL, !url.isEmpty else { throw FalInputError("image is required for image_to_video.") }
            body["image_url"] = .string(url)
        } else {
            let aspect = request.aspectRatio ?? "16:9"
            guard h3MaxTextAspects.contains(aspect) else {
                throw FalInputError("aspect_ratio for text_to_video must be one of: \(h3MaxTextAspects.joined(separator: ", ")).")
            }
            body["aspect_ratio"] = .string(aspect)
        }
        return body
    }

    private static func elevenVoice(_ request: FalRequest) throws -> [String: JSONValue] {
        let text = try requirePrompt(request, what: "text")
        guard text.count <= elevenPromptLimit else {
            throw FalInputError("Keep one spoken line under \(elevenPromptLimit) characters.")
        }
        var body: [String: JSONValue] = ["text": .string(text), "voice": .string(request.voice ?? "Rachel"), "output_format": "mp3_44100_128"]
        if request.wantsWordTimes { body["timestamps"] = true }
        if let code = request.language.flatMap(isoLanguage) { body["language_code"] = .string(code) }
        return body
    }

    private static func zonos(_ request: FalRequest) throws -> [String: JSONValue] {
        guard let reference = request.referenceAudioURL, !reference.isEmpty else {
            throw FalInputError("A sample of the voice to clone is required.")
        }
        var body: [String: JSONValue] = ["text": .string(try requirePrompt(request, what: "text")), "reference_audio_url": .string(reference)]
        if let code = request.language.flatMap(zonosLanguage) { body["language"] = .string(code) }
        return body
    }

    private static func elevenMusic(_ request: FalRequest) throws -> [String: JSONValue] {
        let text = try requirePrompt(request, what: "prompt")
        guard text.count <= musicPromptLimit else { throw FalInputError("Keep the music description under \(musicPromptLimit) characters.") }
        return [
            "prompt": .string(text),
            "music_length_ms": .number((clampedMusicSeconds(request.seconds) * 1000).rounded()),
            "force_instrumental": .bool(request.instrumental)
        ]
    }

    private static func soundEffects(_ request: FalRequest) throws -> [String: JSONValue] {
        let seconds = clampedEffectSeconds(request.seconds)
        return [
            "prompt": .string(try requirePrompt(request, what: "prompt")),
            "duration": .number((seconds * 10).rounded() / 10),
            // 短的用无损的，长的用 mp3（三分钟的 wav 有三十多 MB）。
            "audio_format": .string(seconds <= 30 ? "wav" : "mp3")
        ]
    }

    /// 没登记的端点：只写最基本的字段，别的靠 `options`。
    private static func generic(_ request: FalRequest) throws -> [String: JSONValue] {
        switch request.kind {
        case .voice, .voiceClone:
            var body: [String: JSONValue] = ["text": .string(try requirePrompt(request, what: "text"))]
            if let voice = request.voice { body["voice"] = .string(voice) }
            if let reference = request.referenceAudioURL { body["reference_audio_url"] = .string(reference) }
            return body
        case .imageToVideo:
            var body: [String: JSONValue] = ["prompt": .string(try requirePrompt(request, what: "prompt"))]
            if let url = request.imageURL { body["image_url"] = .string(url) }
            return body
        default:
            return ["prompt": .string(try requirePrompt(request, what: "prompt"))]
        }
    }

    // MARK: 语言

    /// ISO 639-1 两个字母（ElevenLabs 的 `language_code`）。
    static func isoLanguage(_ language: String) -> String? {
        let base = language.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
        return base.count == 2 ? base : nil
    }

    /// Zonos2 的文本规整语言（定义里写着：en_us、en_gb、fr_fr、de、es、it、pt_br、ja、cmn、ko）。
    static func zonosLanguage(_ language: String) -> String? {
        let lowered = language.lowercased()
        if lowered == "en-gb" || lowered == "en_gb" { return "en_gb" }
        switch lowered.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? "" {
        case "en": return "en_us"
        case "zh": return "cmn"
        case "ja": return "ja"
        case "ko": return "ko"
        case "fr": return "fr_fr"
        case "de": return "de"
        case "es": return "es"
        case "it": return "it"
        case "pt": return "pt_br"
        default: return nil
        }
    }
}
