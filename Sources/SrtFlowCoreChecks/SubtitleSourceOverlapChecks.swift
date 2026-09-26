import Foundation
import SrtFlowCore

// 几段素材同时有人说话时只留一条字幕（SubtitleSourceOverlap）。用例是用户两个老工程里真实叠在一起的字幕：
// 录屏自带的声音转出来的「我」「you」压在旁白上、录屏里放的歌转出来的歌词压在旁白上。
// 规则与出处：docs/architecture/subtitle-generation-style.md「几段素材同时有字」一节。

func checkSourceOverlap() {
    let voice = UUID()      // 音频轨上的旁白
    let recording = UUID()  // 主轨录屏自带的声音
    let rank: (UUID?) -> Int = { $0 == recording ? 0 : 1 }
    var meta: [UUID: CueMeta] = [:]
    func cue(_ start: Double, _ end: Double, _ text: String, from clip: UUID, confidence: Double?) -> SubtitleCue {
        let cue = SubtitleCue(start: start, end: end, text: text)
        meta[cue.id] = CueMeta(recognitionConfidence: confidence, provenance: CueProvenance(clipID: clip))
        return cue
    }
    let config = SubtitleSegmentationConfig(frameDuration: 1.0 / 30)

    // B站那个工程：录屏收进来的「我」（置信度 0.07）压在旁白正中间 → 零碎杂音，直接不要。
    let narration = cue(42.14, 49.10, "现在我可以利用苹果电脑", from: voice, confidence: 0.95)
    let stray = cue(42.54, 43.24, "我", from: recording, confidence: 0.07)
    let strayEnglish = cue(60, 60.7, "you", from: recording, confidence: 0.27)
    let kept = SubtitleSourceOverlap.resolve([narration, stray, strayEnglish], meta: meta, laneRank: rank, config: config)
    checkEqual(kept.map(\.id), [narration.id], "重叠：一两个词、置信度低于 0.3 的零碎字幕不要（撞不撞上都不要）")

    // AI 音乐那一课：录屏里放的歌，歌词（0.73）和旁白（0.95）叠了 2.8 秒 → 剩下不到一半，整条不要；
    // 前面那句只蹭到 0.13 秒的歌词（0.77），截掉蹭到的那一截留下。
    let lyricTail = cue(135.88, 136.68, "Your fingers", from: recording, confidence: 0.77)
    let bad = cue(136.55, 136.97, "bad", from: voice, confidence: 0.88)
    let goAhead = cue(136.97, 139.91, "Go ahead and create some music for your AI videos", from: voice, confidence: 0.95)
    let lyric = cue(137.08, 140.26, "fingers tracing circles on my head", from: recording, confidence: 0.73)
    let lonelyLyric = cue(119.08, 121.90, "Just you and me tonight", from: recording, confidence: 0.93)
    let song = SubtitleSourceOverlap.resolve([lyricTail, bad, goAhead, lyric, lonelyLyric], meta: meta,
                                             laneRank: rank, config: config)
    checkEqual(song.map(\.text), ["Just you and me tonight", "Your fingers", "bad", "Go ahead and create some music for your AI videos"],
               "重叠：谁识别得更清楚留谁；大半被占的整条不要；没撞上的歌词照留")
    if let trimmed = song.first(where: { $0.id == lyricTail.id }) {
        check(abs(trimmed.end - (136.55 - config.gap)) < 1e-9, "重叠：蹭到一点的只截掉蹭到的那一截（让出 2 帧）")
        checkEqual(trimmed.start, 135.88, "重叠：截的是尾巴，开头不动")
    }
    // 不同素材留下的互不重叠、至少隔 2 帧；同一段素材前后相接的归显示时间那一步去隔开。
    func source(_ cue: SubtitleCue) -> UUID? { meta[cue.id]?.provenance?.clipID }
    check(zip(song, song.dropFirst()).allSatisfy { a, b in source(a) == source(b) || b.start - a.end >= config.gap - 1e-9 },
          "重叠：不同素材留下的互不重叠")

    // 置信度一样：轨道秩小的先留；没有置信度的按 0.5 算，不算杂音。
    let even = cue(10, 12, "same clarity here", from: recording, confidence: 0.8)
    let evenVoice = cue(10.5, 12.5, "same clarity there", from: voice, confidence: 0.8)
    let unknown = cue(20, 21, "no score", from: voice, confidence: nil)
    let tie = SubtitleSourceOverlap.resolve([evenVoice, even, unknown], meta: meta, laneRank: rank, config: config)
    checkEqual(tie.map(\.id), [even.id, unknown.id], "重叠：一样清楚时轨道秩小的留；没有置信度的不算杂音")

    // 接进合成：两段素材各切各的，合出来的一条轨没有任何两条重叠，丢掉的连旁表一起丢。
    let voiceWindow = SubtitleClipWindow(clipID: voice, assetFingerprint: "voice", sourceStart: 0, sourceEnd: 10,
                                         timelineStart: 0, laneRank: 1)
    let recordingWindow = SubtitleClipWindow(clipID: recording, assetFingerprint: "rec", sourceStart: 0, sourceEnd: 10,
                                             timelineStart: 0, laneRank: 0)
    let spoken = SubtitleSegmenter.segment(words: [
        TimedWord(text: "Go", start: 1.0, end: 1.3, confidence: 0.95),
        TimedWord(text: " ahead", start: 1.3, end: 1.8, confidence: 0.95),
        TimedWord(text: " and", start: 1.8, end: 2.0, confidence: 0.95),
        TimedWord(text: " create.", start: 2.0, end: 2.9, confidence: 0.95)
    ], window: voiceWindow, config: config)
    let sung = SubtitleSegmenter.segment(words: [
        TimedWord(text: "Candlelight", start: 1.2, end: 1.9, confidence: 0.57),
        TimedWord(text: " is", start: 1.9, end: 2.1, confidence: 0.57),
        TimedWord(text: " dancing.", start: 2.1, end: 3.0, confidence: 0.57),
        TimedWord(text: "我", start: 5.0, end: 5.7, confidence: 0.07)
    ], window: recordingWindow, config: config)
    let assembled = SubtitleSegmenter.assemble([spoken, sung], windows: [voiceWindow, recordingWindow], config: config)
    checkEqual(assembled.document.cues.map(\.text), ["Go ahead and create"], "合成：旁白留下，被压住的歌词和零碎的「我」都不要")
    checkEqual(Set(assembled.meta.keys), Set(assembled.document.cues.map(\.id)), "合成：丢掉的字幕旁表也一起丢")
}
