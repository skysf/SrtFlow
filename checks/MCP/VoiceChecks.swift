import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// add_voiceover（方案第 42、43 条）：挑声音（角色 → 同语言同性别里高级 > 增强 > 默认、两个女声角色各用一个、没有这个性别就退并
// 说一声、只有默认质量要提示去哪下载、按名字点、机器人味的几族不用）；标记 → 带时间的词（标点并进前一个词、词尾收掉后面的静音、
// 写法和识别器一样）；每一句放在哪；配音的字幕（走生成字幕的断句、不覆盖已有的、语言对不上一句不加、切不出句子不建空轨）。
// 真合成要 App 和系统声音，靠人工回归清单。编法见 scripts/check-mcp.sh。

func runVoiceChecks() {
    choiceChecks()
    wordChecks()
    placementChecks()
    subtitleChecks()
}

private func voice(_ name: String, _ language: String, _ gender: AIVoiceChoice.Voice.Gender, _ quality: Int,
                   id: String? = nil) -> AIVoiceChoice.Voice {
    AIVoiceChoice.Voice(identifier: id ?? "com.apple.voice.\(quality).\(language).\(name)", name: name,
                        language: language, gender: gender, quality: quality)
}

private func choiceChecks() {
    let tingting = voice("Tingting", "zh-CN", .female, 1)
    let lili = voice("Lili", "zh-CN", .female, 3)
    let yushu = voice("Yu-shu", "zh-CN", .female, 2)
    let eddy = voice("Eddy", "zh-CN", .unspecified, 1, id: "com.apple.eloquence.zh-CN.Eddy")
    let chinese = [tingting, eddy, yushu, lili]
    checkEqual((try? AIVoiceChoice.choose("zh_female_lively", textLanguage: "zh", from: chinese))?.voice.name, "Lili",
               "the best quality voice for the lively role")
    checkEqual((try? AIVoiceChoice.choose("zh_female_warm", textLanguage: "zh", from: chinese))?.voice.name, "Yu-shu",
               "the warm female role takes the second voice when there are two")
    let premium = try? AIVoiceChoice.choose("zh_female_lively", textLanguage: "zh", from: chinese)
    check(premium?.note == nil, "a Premium voice needs no note")
    checkEqual(premium?.pitch, 1.08, "lively is pitched a little higher")
    let male = try? AIVoiceChoice.choose("zh_male_steady", textLanguage: "zh", from: chinese)
    checkEqual(male?.voice.name, "Lili", "no male voice: fall back to the best other one")
    check(male?.note?.contains("No male Chinese voice") == true, "and say so")
    checkEqual(male?.pitch, 0.94, "steady is pitched a little lower")
    let basic = try? AIVoiceChoice.choose(nil, textLanguage: "zh", from: [tingting, eddy])
    checkEqual(basic?.voice.name, "Tingting", "the Eloquence voices are never picked")
    check(basic?.note?.contains("Manage Voices") == true, "a basic-quality voice comes with where to download a better one")
    checkEqual((try? AIVoiceChoice.choose("tingting", textLanguage: "en", from: chinese))?.voice.name, "Tingting",
               "an installed voice can be named, in any case")
    checkThrows("an unknown voice name is refused") { _ = try AIVoiceChoice.choose("Nobody", textLanguage: "zh", from: chinese) }
    checkThrows("no English voice at all is refused") {
        _ = try AIVoiceChoice.choose("en_female_warm", textLanguage: "en",
                                     from: [voice("Eddy", "en-US", .unspecified, 1, id: "com.apple.eloquence.en-US.Eddy"),
                                            voice("Fred", "en-US", .male, 1, id: "com.apple.speech.synthesis.voice.Fred")])
    }
    let english = [voice("Daniel", "en-GB", .male, 2), voice("Evan", "en-US", .male, 2), voice("Zoe", "en-US", .female, 3)]
    checkEqual((try? AIVoiceChoice.choose("en_male_steady", textLanguage: "en", from: english))?.voice.name, "Evan",
               "same quality: American English first")
    checkEqual((try? AIVoiceChoice.choose(nil, textLanguage: "ja", from: english + [voice("Kyoko", "ja-JP", .female, 2)]))?.voice.name,
               "Kyoko", "other languages get a voice of their own language")
    // 语速：rate 和实际倍数不是线性的（实测的表），1 倍就是系统的正常语速 0.5，越快 rate 越大，两头夹住。
    checkEqual(AIVoiceChoice.utteranceRate(forSpeed: 1), 0.5, "normal speed is the system's normal rate")
    check(abs(AIVoiceChoice.utteranceRate(forSpeed: 1.1) - 0.522) < 0.002, "1.1× sits between the measured 1.08× and 1.18×")
    let speeds = stride(from: 0.5, through: 2.0, by: 0.05).map { AIVoiceChoice.utteranceRate(forSpeed: $0) }
    check(zip(speeds, speeds.dropFirst()).allSatisfy { $0 < $1 }, "faster always means a higher rate")
    checkEqual(AIVoiceChoice.utteranceRate(forSpeed: 9), 0.7, "rates stop at the fastest measured point")
    for name in MCPVocabulary.voiceRoles {
        check(AIVoiceChoice.Role(name) != nil, "\(name) is a role the app understands")
    }
}

private func wordChecks() {
    let rate = 22050.0
    // 响 0–0.5 秒，静 0.5–0.8，响 0.8–1.5，之后静到 1.7。
    var samples = [Float](repeating: 0, count: Int(1.7 * rate))
    for index in samples.indices where Double(index) / rate < 0.5 || (0.8..<1.5).contains(Double(index) / rate) {
        samples[index] = index % 2 == 0 ? 0.2 : -0.2
    }
    let text = "Hello there. This works."
    let markers: [AIVoiceWords.Marker] = [
        .init(location: 0, length: 5, frame: 0), .init(location: 6, length: 6, frame: Int(0.25 * rate)),
        .init(location: 13, length: 4, frame: Int(0.8 * rate)), .init(location: 18, length: 6, frame: Int(1.1 * rate))
    ]
    let words = AIVoiceWords.words(text: text, markers: markers, samples: samples, sampleRate: rate)
    checkEqual(words.map(\.text), ["Hello", " there.", " This", " works."], "words are written like the recognizer's")
    check(abs((words.dropFirst().first?.end ?? 0) - 0.5) < 0.011, "a word before a pause ends where the sound ends, not at the next word")
    check(abs((words.last?.end ?? 0) - 1.5) < 0.011, "the last word ends where the sound ends")
    checkEqual(words.map { ($0.start * 100).rounded() / 100 }, [0, 0.25, 0.8, 1.1], "each word starts at its marker")
    let chinese = AIVoiceWords.words(
        text: "好，这", markers: [.init(location: 0, length: 1, frame: 0), .init(location: 1, length: 1, frame: 100),
                                .init(location: 2, length: 1, frame: 200)],
        samples: [Float](repeating: 0.2, count: 400), sampleRate: 1000
    )
    checkEqual(chinese.map(\.text), ["好，", "这"], "a punctuation mark reported as a word joins the word before it")
}

private func placementChecks() {
    checkEqual(AIVoiceoverPlacement.starts(given: [nil, nil, 5, nil], durations: [2, 1, 3, 1], playhead: 1),
               [1, 3.3, 5, 8.3], "lines without a start follow the previous one with a short gap; the first is at the playhead")
}

private func subtitleChecks() {
    let config = SubtitleSegmentationConfig.generation(languageCode: "en", frameDuration: 1.0 / 30, maxLineEms: .infinity)
    let words = [TimedWord(text: "Welcome", start: 0.1, end: 0.6), TimedWord(text: " to", start: 0.6, end: 0.8),
                 TimedWord(text: " the", start: 0.8, end: 0.95), TimedWord(text: " course.", start: 0.95, end: 1.6)]
    let piece = AIVoiceoverSubtitles.Piece(clipID: UUID(), timelineStart: 10, duration: 2, laneRank: 1, words: words)

    var empty = TimelineState()
    let added = AIVoiceoverSubtitles.add([piece], language: "en", config: config, to: &empty)
    checkEqual(added.added.count, 1, "the voiceover becomes one subtitle line")
    let cue = empty.subtitleCues(of: .original).first
    checkEqual(cue?.text, "Welcome to the course", "subtitles lose their punctuation like generated ones")
    check((cue?.start ?? 0) >= 10.1 - 0.001 && (cue?.start ?? 0) < 10.2, "the line starts when the voice starts on the timeline")
    checkEqual(empty.subtitleCompanion?.sourceLanguage, "en", "a new subtitle track is marked with the voice's language")

    var taken = TimelineState()
    taken.editSubtitleTracks(creatingOriginal: true) { original, companion in
        SubtitleTrackEditing.insertCue(SubtitleCue(start: 10.5, end: 11, text: "Mine"), into: .original,
                                       original: &original, companion: &companion)
    }
    let overlapping = AIVoiceoverSubtitles.add([piece], language: "en", config: config, to: &taken)
    checkEqual(overlapping.skipped, 1, "a line over an existing subtitle is left out")
    check(overlapping.refusal == nil, "a one-word subtitle is too short to guess its language, so nothing is refused")
    checkEqual(taken.subtitleCues(of: .original).map(\.text), ["Mine"], "the user's subtitle stays")

    var chinese = TimelineState()
    chinese.editSubtitleTracks(creatingOriginal: true) { original, companion in
        SubtitleTrackEditing.insertCue(SubtitleCue(start: 0, end: 1, text: "你好"), into: .original,
                                       original: &original, companion: &companion)
        companion.sourceLanguage = "zh"
    }
    let refused = AIVoiceoverSubtitles.add([piece], language: "en", config: config, to: &chinese)
    check(refused.refusal != nil && refused.added.isEmpty, "an English voiceover adds nothing to a Chinese subtitle track")
    var unmarked = TimelineState()
    unmarked.editSubtitleTracks(creatingOriginal: true) { original, companion in
        SubtitleTrackEditing.insertCue(SubtitleCue(start: 0, end: 3, text: "这是我自己写的一句很长很长的中文字幕，用来判断语言。"),
                                       into: .original, original: &original, companion: &companion)
    }
    check(AIVoiceoverSubtitles.add([piece], language: "en", config: config, to: &unmarked).refusal != nil,
          "a track without a language but with enough Chinese text is recognised as Chinese")

    var untouched = TimelineState()
    let nothing = AIVoiceoverSubtitles.add(
        [AIVoiceoverSubtitles.Piece(clipID: UUID(), timelineStart: 0, duration: 1, laneRank: 1,
                                    words: [TimedWord(text: "。", start: 0, end: 0.5)])],
        language: "zh", config: config, to: &untouched
    )
    check(nothing.added.isEmpty && untouched.subtitle == nil, "no lines: no empty subtitle track is created")
}
