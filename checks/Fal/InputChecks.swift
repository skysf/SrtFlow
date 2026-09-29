import Foundation
import SrtFlowMCPKit

// 第三组：给 fal 的请求体。
// 每个登记的端点把「我们造出来的请求体」逐条对着它的接口定义快照验（必填、取值、范围、有没有多余的字段）——
// 请求体写错是第一次拿真的 Key 才会露馅的那类错，这里让它在没有 Key 的地方就红。

private let seedream = "bytedance/seedream/v5/flash/text-to-image"
private let h3Text = "minimax/h3-max/text-to-video"
private let h3Image = "minimax/h3-max/image-to-video"
private let elevenVoice = "elevenlabs/tts/eleven-v4"
private let zonos = "fal-ai/zonos2"
private let elevenMusic = "elevenlabs/music/v2.5"
private let soundEffects = "sonilo/v1.1/text-to-sound-effects"

private func body(_ endpoint: String, _ request: FalRequest) -> JSONValue {
    do {
        return try FalInputs.body(request, dialect: FalDialect(endpoint: endpoint))
    } catch {
        check(false, "\(endpoint): building the request failed: \(error)")
        return .null
    }
}

func runInputChecks() {
    // ---- 图片（Seedream）
    var image = FalRequest(kind: .image, prompt: "a lighthouse at dusk")
    checkValidInput(seedream, body(seedream, image), "image, default shape")
    checkEqual(body(seedream, image)["image_size"], "landscape_16_9", "an image without a shape is landscape 16:9")
    image.aspectRatio = "9:16"
    checkEqual(body(seedream, image)["image_size"], "portrait_16_9", "9:16 has a named size")
    for (aspect, name) in [("16:9", "landscape_16_9"), ("4:3", "landscape_4_3"), ("3:4", "portrait_4_3"), ("1:1", "square_hd")] {
        image.aspectRatio = aspect
        checkEqual(body(seedream, image)["image_size"], JSONValue.string(name), "\(aspect) maps to \(name)")
        checkValidInput(seedream, body(seedream, image), "image \(aspect)")
    }
    for aspect in ["21:9", "4:5", "5:4", "2:1"] {
        image.aspectRatio = aspect
        let size = body(seedream, image)["image_size"]
        let width = size?["width"]?.doubleValue ?? 0, height = size?["height"]?.doubleValue ?? 0
        checkClose(width / max(height, 1), FalInputs.aspectValue(aspect) ?? 0, "\(aspect) is written as a width and a height", tolerance: 0.02)
        check(width * height >= 1_048_576 && width * height <= 4_194_304, "\(aspect): the area is between 1024² and 2048²")
        check(width.truncatingRemainder(dividingBy: 16) == 0 && height.truncatingRemainder(dividingBy: 16) == 0, "\(aspect): multiples of 16")
        checkValidInput(seedream, body(seedream, image), "image \(aspect)")
    }
    image.aspectRatio = "wide"
    checkInputError("a shape that is not width:height", contains: ["aspect_ratio"]) { _ = try FalInputs.body(image, dialect: .seedreamImage) }
    checkInputError("an image needs a prompt", contains: ["prompt"]) {
        _ = try FalInputs.body(FalRequest(kind: .image, prompt: "   "), dialect: .seedreamImage)
    }

    // ---- 文生视频（H3 Max）
    var text = FalRequest(kind: .textToVideo, prompt: "a fox runs through snow, low camera")
    checkValidInput(h3Text, body(h3Text, text), "text_to_video, defaults")
    checkEqual(body(h3Text, text)["duration"], 5, "the default is 5 seconds")
    checkEqual(body(h3Text, text)["resolution"], "768P", "the default is 768P")
    checkEqual(body(h3Text, text)["aspect_ratio"], "16:9", "the default shape is 16:9")
    checkEqual(body(h3Text, text)["prompt_expansion_mode"], "balanced", "prompt_expansion_mode is always sent (fal marks it required)")
    text.seconds = 3
    checkEqual(body(h3Text, text)["duration"], 5, "shorter than 5 s is raised to 5")
    text.seconds = 40
    checkEqual(body(h3Text, text)["duration"], 15, "longer than 15 s is lowered to 15")
    text.seconds = 7.6
    checkEqual(body(h3Text, text)["duration"], 8, "seconds are whole numbers")
    for resolution in ["480p", "480P", "1080", " 768p "] {
        text.resolution = resolution
        checkValidInput(h3Text, body(h3Text, text), "text_to_video at \(resolution)")
    }
    text.resolution = "480p"
    checkEqual(body(h3Text, text)["resolution"], "480P", "resolution is normalised")
    text.resolution = "720p"
    checkInputError("720p is not a resolution of this model", contains: ["resolution", "480p"]) { _ = try FalInputs.body(text, dialect: .h3MaxTextToVideo) }
    text.resolution = nil
    for aspect in FalInputs.h3MaxTextAspects {
        text.aspectRatio = aspect
        checkValidInput(h3Text, body(h3Text, text), "text_to_video \(aspect)")
    }
    text.aspectRatio = "5:4"
    checkInputError("5:4 is not an aspect ratio of this model", contains: ["aspect_ratio", "16:9"]) { _ = try FalInputs.body(text, dialect: .h3MaxTextToVideo) }

    // ---- 图生视频（H3 Max）
    var picture = FalRequest(kind: .imageToVideo, prompt: "the camera slowly pushes in")
    checkInputError("image_to_video needs the first frame", contains: ["image"]) { _ = try FalInputs.body(picture, dialect: .h3MaxImageToVideo) }
    picture.imageURL = "data:image/png;base64,iVBORw0KGgo="
    picture.aspectRatio = "9:16"
    let pictureBody = body(h3Image, picture)
    checkValidInput(h3Image, pictureBody, "image_to_video")
    check(pictureBody["aspect_ratio"] == nil, "image_to_video keeps the picture's shape: no aspect_ratio is sent")
    checkEqual(pictureBody["image_url"], "data:image/png;base64,iVBORw0KGgo=", "the first frame goes in image_url")

    // ---- 旁白（Eleven v4）
    var voice = FalRequest(kind: .voice, prompt: "[warmly] Welcome back to the show.")
    checkValidInput(elevenVoice, body(elevenVoice, voice), "voice, defaults")
    checkEqual(body(elevenVoice, voice)["voice"], "Rachel", "the default voice")
    check(body(elevenVoice, voice)["timestamps"] == nil, "word times are only asked for when wanted")
    voice.voice = "Brian"
    voice.wantsWordTimes = true
    voice.language = "zh-CN"
    let voiceBody = body(elevenVoice, voice)
    checkValidInput(elevenVoice, voiceBody, "voice with word times and a language")
    checkEqual(voiceBody["voice"], "Brian", "the named voice")
    checkEqual(voiceBody["timestamps"], true, "word times are asked for")
    checkEqual(voiceBody["language_code"], "zh", "a two-letter language code")
    voice.language = "und"
    check(body(elevenVoice, voice)["language_code"] == nil, "only ISO 639-1 (two-letter) codes are sent; \"und\" is not one")
    voice.prompt = String(repeating: "a", count: 5_001)
    checkInputError("more than 5000 characters", contains: ["5000"]) { _ = try FalInputs.body(voice, dialect: .elevenV4Voice) }

    // ---- 克隆（Zonos2）
    var clone = FalRequest(kind: .voiceClone, prompt: "Hello there.")
    checkInputError("cloning needs a sample", contains: ["sample"]) { _ = try FalInputs.body(clone, dialect: .zonos2Clone) }
    clone.referenceAudioURL = "data:audio/wav;base64,UklGRg=="
    clone.language = "zh"
    let cloneBody = body(zonos, clone)
    checkValidInput(zonos, cloneBody, "clone")
    checkEqual(cloneBody["language"], "cmn", "Chinese text is normalised as cmn")
    clone.language = nil
    check(body(zonos, clone)["language"] == nil, "no language: fal's default applies")
    for (language, code) in [("en", "en_us"), ("en-GB", "en_gb"), ("ja", "ja"), ("ko-KR", "ko"), ("fr", "fr_fr"), ("pt", "pt_br"), ("de", "de")] {
        checkEqual(FalInputs.zonosLanguage(language), code, "\(language) → \(code)")
    }
    check(FalInputs.zonosLanguage("hi") == nil, "a language Zonos2 does not list is left to its default")

    // ---- 音乐（Eleven Music v2.5）
    var song = FalRequest(kind: .music, prompt: "warm lo-fi beat, soft piano, vinyl crackle")
    let songBody = body(elevenMusic, song)
    checkValidInput(elevenMusic, songBody, "music, defaults")
    checkEqual(songBody["music_length_ms"], 30_000, "the default is 30 seconds")
    checkEqual(songBody["force_instrumental"], true, "instrumental by default (background music)")
    song.instrumental = false
    checkEqual(body(elevenMusic, song)["force_instrumental"], false, "vocals when asked")
    song.seconds = 1
    checkEqual(body(elevenMusic, song)["music_length_ms"], 3_000, "at least 3 seconds")
    song.seconds = 9_999
    checkEqual(body(elevenMusic, song)["music_length_ms"], 600_000, "at most 10 minutes")
    checkValidInput(elevenMusic, body(elevenMusic, song), "music, longest")
    song.prompt = String(repeating: "b", count: 4_101)
    checkInputError("a music description over 4100 characters", contains: ["4100"]) { _ = try FalInputs.body(song, dialect: .elevenMusic) }

    // ---- 音效（Sonilo）
    var effect = FalRequest(kind: .soundEffect, prompt: "a wooden door creaks open")
    let effectBody = body(soundEffects, effect)
    checkValidInput(soundEffects, effectBody, "sound effect, defaults")
    checkEqual(effectBody["duration"], 5, "the default is 5 seconds")
    checkEqual(effectBody["audio_format"], "wav", "short effects are lossless")
    effect.seconds = 90
    checkEqual(body(soundEffects, effect)["audio_format"], "mp3", "long ones are mp3")
    checkValidInput(soundEffects, body(soundEffects, effect), "sound effect, long")
    effect.seconds = 0.1
    checkEqual(body(soundEffects, effect)["duration"], 0.5, "at least half a second")
    effect.seconds = 999
    checkEqual(body(soundEffects, effect)["duration"], 180, "at most three minutes")

    // ---- options：盖在上面，AI 点名的字段照发
    var seeded = FalRequest(kind: .textToVideo, prompt: "waves")
    seeded.options = ["seed": 7, "resolution": "480P"]
    let seededBody = body(h3Text, seeded)
    checkEqual(seededBody["seed"], 7, "options are added")
    checkEqual(seededBody["resolution"], "480P", "options win over what SrtFlow filled in")
    checkValidInput(h3Text, seededBody, "options that belong to the model")
    seeded.options = ["not_a_field": true]
    check(!(FalSchema(endpoint: h3Text)?.inputProblems(body(h3Text, seeded)).isEmpty ?? true), "the validator notices a field the model does not have")

    // ---- 没登记的端点：只写最基本的，别的靠 options
    checkEqual(FalDialect(endpoint: "acme/whatever"), .generic, "an unregistered endpoint is generic")
    let generic = try? FalInputs.body(FalRequest(kind: .image, prompt: "x"), dialect: .generic)
    checkEqual(generic, .object(["prompt": "x"]), "generic image: just the prompt")
    var genericVideo = FalRequest(kind: .imageToVideo, prompt: "move")
    genericVideo.imageURL = "https://example.com/a.png"
    checkEqual(try? FalInputs.body(genericVideo, dialect: .generic), .object(["prompt": "move", "image_url": "https://example.com/a.png"]), "generic image_to_video")
    var genericVoice = FalRequest(kind: .voice, prompt: "hi")
    genericVoice.voice = "Aria"
    checkEqual(try? FalInputs.body(genericVoice, dialect: .generic), .object(["text": "hi", "voice": "Aria"]), "generic voice speaks `text`")
    var genericOptions = FalRequest(kind: .music, prompt: "song")
    genericOptions.options = ["lyrics": "la la"]
    checkEqual(try? FalInputs.body(genericOptions, dialect: .generic), .object(["prompt": "song", "lyrics": "la la"]), "generic + options")

    // ---- 用量（估价用）从请求里读
    var usageRequest = FalRequest(kind: .textToVideo, prompt: "x")
    usageRequest.seconds = 12
    usageRequest.resolution = "1080p"
    checkEqual(FalInputs.usage(for: usageRequest), FalUsage(images: 1, seconds: 12, characters: 0, tier: "1080P"), "video usage: seconds and tier")
    usageRequest.seconds = 99
    checkEqual(FalInputs.usage(for: usageRequest).seconds, 15, "usage follows the clamped duration")
    checkEqual(FalInputs.usage(for: FalRequest(kind: .music, prompt: "x")).seconds, 30, "music usage defaults to 30 s")
    checkEqual(FalInputs.usage(for: FalRequest(kind: .soundEffect, prompt: "x")).seconds, 5, "effect usage defaults to 5 s")
    checkEqual(FalInputs.usage(for: FalRequest(kind: .voice, prompt: "hello")).characters, 5, "voice usage counts characters")

    // ---- 画幅、分辨率的小工具
    checkEqual(FalInputs.nearestAspect(to: 1920.0 / 1080, in: FalInputs.h3MaxTextAspects), "16:9", "1920×1080 → 16:9")
    checkEqual(FalInputs.nearestAspect(to: 1080.0 / 1920, in: FalInputs.h3MaxTextAspects), "9:16", "1080×1920 → 9:16")
    checkEqual(FalInputs.nearestAspect(to: 1, in: FalInputs.h3MaxTextAspects), "1:1", "square")
    checkEqual(FalInputs.nearestAspect(to: 2.39, in: FalInputs.h3MaxTextAspects), "21:9", "cinemascope → 21:9")
    checkEqual(FalInputs.nearestAspect(to: 0.8, in: FalInputs.h3MaxTextAspects), "3:4", "4:5 → the closest is 3:4")
    checkEqual(FalInputs.nearestAspect(to: 0, in: FalInputs.h3MaxTextAspects), "21:9", "no ratio: the first option")
    check(FalInputs.aspectValue("16:0") == nil && FalInputs.aspectValue("wide") == nil && FalInputs.aspectValue("16:9:1") == nil, "bad aspect texts are refused")
    checkEqual(try? FalInputs.normalizedResolution(nil), "768P", "no resolution: the default")
    checkEqual(FalInputs.isoLanguage("zh-Hans"), "zh", "zh-Hans → zh")
    check(FalInputs.isoLanguage("fil") == nil, "three-letter codes are not ISO 639-1")
}
