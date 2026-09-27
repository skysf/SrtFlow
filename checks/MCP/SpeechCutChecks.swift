import Foundation
import SrtFlowCore

// cut_speech（AISpeechCuts）：切口落在词和词之间空隙的中点（离词最多 0.3 秒，按词的中点判归属）；删 / 只留 / 停顿缩短 /
// 口头禅 / 说重了的词各自算对；合并时挨得太近的连成一刀、片段头尾剩一点点也剪掉、对齐到帧、不到两帧的不剪；
// 停顿门限从这一段自己量；真落到带链接声音的时间线上：画面和声音在同样的地方剪、后面的 V1 片段往前补、一对还是一对。
// 编法见 scripts/check-mcp.sh。

func runSpeechCutChecks() {
    checkCutPoints()
    checkCutKinds()
    checkMerging()
    checkApplyingCuts()
}

private func word(_ text: String, _ start: Double, _ end: Double) -> SpeechTranscript.Word {
    SpeechTranscript.Word(text: text, start: start, end: end, sourceStart: start, sourceEnd: end, confidence: nil)
}

/// 「So um I I think this works.」：词和词之间空 0.2 秒，um 后面停了 1 秒。
private let spoken = [
    word("So", 1.0, 1.3), word("um", 1.5, 1.8), word("I", 2.8, 2.9), word("I", 3.1, 3.2),
    word("think", 3.4, 3.7), word("this", 3.9, 4.1), word("works.", 4.3, 4.8)
]

private func near(_ value: Double, _ expected: Double) -> Bool { abs(value - expected) < 1e-9 }

private func checkCutPoints() {
    check(near(AISpeechCuts.startPoint(3.4, words: spoken), 3.3), "a range starting at 'think' starts in the gap before it (3.3)")
    check(near(AISpeechCuts.endPoint(3.7, words: spoken), 3.8), "and ending after 'think' ends in the gap after it (3.8)")
    check(near(AISpeechCuts.startPoint(3.6, words: spoken), 3.8), "starting in the second half of a word leaves that word out")
    check(near(AISpeechCuts.startPoint(3.45, words: spoken), 3.3), "starting in its first half takes the whole word")
    check(near(AISpeechCuts.startPoint(2.8, words: spoken), 2.5), "a long gap: at most 0.3 s before the word (2.5, not the middle 2.3)")
    check(near(AISpeechCuts.startPoint(0, words: spoken), 0), "a time far from any word stays where it is")
    check(near(AISpeechCuts.endPoint(4.8, words: spoken), 5.1), "after the last word: 0.3 s after it")
}

private func checkCutKinds() {
    let removed = AISpeechCuts.requested([3.4...4.1], words: spoken)
    check(removed.count == 1 && near(removed[0].start, 3.3) && near(removed[0].end, 4.2), "remove 'think this': 3.3–4.2")
    let outside = AISpeechCuts.outside([3.4...4.8], clip: 0...6, words: spoken)
    check(outside.count == 2 && near(outside[0].end, 3.3) && near(outside[1].start, 5.1), "keep only 'think this works.': cut before 3.3 and after 5.1")
    checkEqual(outside.first?.start, 0, "from the clip start")
    let pauses = AISpeechCuts.pauses([1.8...2.8, 3.2...3.4], longerThan: 0.6, leave: 0.2)
    check(pauses.count == 1 && near(pauses[0].start, 1.9) && near(pauses[0].end, 2.7), "a 1 s pause keeps 0.1 s at each end; a short gap is left alone")
    let fillers = AISpeechCuts.fillerWords(spoken)
    check(fillers.count == 1 && near(fillers[0].start, 1.4) && near(fillers[0].end, 2.1), "'um' goes, gap to gap (1.4–2.1)")
    checkEqual(fillers.first?.reason, "filler: um", "and says why")
    let repeats = AISpeechCuts.repeats(spoken)
    check(repeats.count == 1 && near(repeats[0].start, 2.5) && near(repeats[0].end, 3.0), "'I I': the first one goes (2.5–3.0)")
    let twice = [word("you", 0, 0.2), word("know", 0.3, 0.5), word("you", 0.6, 0.8), word("know", 0.9, 1.1), word("it", 1.3, 1.4)]
    let pair = AISpeechCuts.repeats(twice)
    checkEqual(pair.map(\.reason), ["repeat: you know"], "a two-word repeat goes as one")
    checkEqual(AISpeechCuts.repeats([word("very", 0, 0.3), word("very", 1.2, 1.5)]).count, 0, "said again after a long pause: not a stutter")
    checkEqual(AISpeechCuts.silenceThreshold(Array(repeating: -20, count: 50)), -30, "all speech: the threshold stays at -30 (no pauses found)")
    let quietRoom = Array(repeating: -65.0, count: 20) + Array(repeating: -20.0, count: 80)
    check(abs(AISpeechCuts.silenceThreshold(quietRoom) - (-65 + 0.35 * 45)) < 1e-9, "a quiet room: 35% of the way from the floor to speech")
}

private func checkMerging() {
    let frame = 1.0 / 30
    let cuts = [
        AISpeechCuts.Cut(start: 0.05, end: 1.0, reason: "pause"),
        AISpeechCuts.Cut(start: 1.1, end: 2.0, reason: "filler: um"),
        AISpeechCuts.Cut(start: 5.0, end: 5.04, reason: "pause"),
        AISpeechCuts.Cut(start: 8.0, end: 9.9, reason: "requested")
    ]
    let merged = AISpeechCuts.merged(cuts, clip: 0...10, frame: frame)
    checkEqual(merged.count, 2, "close cuts join, a one-frame cut is dropped")
    checkEqual(merged.first?.start, 0, "a sliver at the clip start goes too")
    checkEqual(merged.first?.reason, "pause, filler: um", "joined cuts keep both reasons")
    checkEqual(merged.last?.end, 10, "a sliver at the clip end goes too")
    check(merged.allSatisfy { abs(($0.start / frame).rounded() * frame - $0.start) < 1e-9 }, "cut points land on frames")
}

private func checkApplyingCuts() {
    let url = URL(fileURLWithPath: "/tmp/talk.mov")
    let group = UUID()
    let talk = EditClip(sourceURL: url, sourceDuration: 20, timelineStart: 0, linkGroup: group)
    let voice = EditClip(sourceURL: url, isAudioOnly: true, sourceDuration: 20, timelineStart: 0, linkGroup: group, audioAssetDuration: 20)
    let next = EditClip(sourceURL: url, sourceStart: 20, sourceDuration: 10, timelineStart: 20)
    var state = TimelineState()
    state.mainClips = [talk, next]
    state.audioTracks = [EditLane(clips: [voice])]
    let pieces = AISpeechCuts.apply([
        AISpeechCuts.Cut(start: 5, end: 7, reason: "pause"), AISpeechCuts.Cut(start: 12, end: 15, reason: "requested")
    ], to: talk.id, in: &state)
    checkEqual(pieces.count, 3, "two cuts: three pieces left")
    checkEqual(state.mainClips.map(\.timelineStart), [0, 5, 10, 15], "pieces back to back, the next V1 clip moved left by 5 s")
    checkEqual(state.mainClips.map(\.sourceStart), [0, 7, 15, 20], "each piece plays the right part of the source")
    checkEqual(state.audioTracks[0].clips.map(\.timelineStart), [0, 5, 10], "the linked voice is cut in the same places")
    checkEqual(state.audioTracks[0].clips.map(\.sourceStart), [0, 7, 15], "and plays the same parts")
    let middle = state.mainClips[1]
    checkEqual(state.linkedClipIDs(of: middle.id).count, 2, "each picture piece is linked only with its own voice piece")
    var whole = TimelineState()
    whole.mainClips = [EditClip(sourceURL: url, sourceDuration: 10, timelineStart: 0)]
    let first = whole.mainClips[0].id
    _ = AISpeechCuts.apply([AISpeechCuts.Cut(start: 0, end: 2, reason: "pause")], to: first, in: &whole)
    checkEqual(whole.mainClips.map(\.sourceStart), [2], "a cut at the very start trims the head")
    checkEqual(whole.mainClips.map(\.timelineStart), [0], "and the rest starts at 0")
}
