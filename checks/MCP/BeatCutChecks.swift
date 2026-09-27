import Foundation

// cut_to_beat（AIBeatCuts）：拍子每 0.5 秒一个。不给拍数时每个切口挪到最近的拍；给了拍数每段正好那么多拍（第一段从最近的
// 那一拍数起）；素材不够长就用放得下的最多拍数；一拍都放不下、音乐放完了的保持原长；落到时间线上：入点不动、链接的声音
// 跟着挪和改出点、这一串后面的 V1 片段按总长的变化整体挪。编法见 scripts/check-mcp.sh。

func runBeatCutChecks() {
    checkBeatLayout()
    checkBeatApply()
}

private let everyHalfSecond = (1...40).map { Double($0) * 0.5 }

private func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

private func checkBeatLayout() {
    let ids = (0..<3).map { _ in UUID() }
    let clips = [
        AIBeatCuts.Clip(id: ids[0], start: 0, duration: 2.3, maxDuration: 10),
        AIBeatCuts.Clip(id: ids[1], start: 2.3, duration: 1.1, maxDuration: 10),
        AIBeatCuts.Clip(id: ids[2], start: 3.4, duration: 3.0, maxDuration: 10)
    ]
    let snapped = AIBeatCuts.layout(clips, beats: everyHalfSecond, beatsPerClip: nil)
    check(zip(snapped.map { $0.start + $0.duration }, [2.5, 3.5, 6.5]).allSatisfy(near), "each cut moves to the nearest beat (2.5, 3.5, 6.5)")
    check(near(snapped[1].start, 2.5) && near(snapped[2].start, 3.5), "each clip starts where the one before ends")
    checkEqual(snapped.map(\.beats), [4, 2, 6], "beats per clip (the lead-in before the first beat is not a beat)")

    let even = AIBeatCuts.layout(clips, beats: everyHalfSecond, beatsPerClip: 4)
    check(zip(even.map { $0.start + $0.duration }, [2.5, 4.5, 6.5]).allSatisfy(near), "beats_per_clip 4: every cut four beats on")
    checkEqual(even.map(\.beats), [4, 4, 4], "beats_per_clip 4 reports 4 for every clip, the first one too")

    // 2026-09-28 冒烟：128 BPM 的鼓点第一拍在 0.24 秒，每段 4 拍，第一段回了 5。
    let offBeat = (0..<16).map { 0.24 + Double($0) * 60 / 128 }
    let smoke = AIBeatCuts.layout([AIBeatCuts.Clip(id: ids[0], start: 0, duration: 10, maxDuration: 10)], beats: offBeat, beatsPerClip: 4)
    check(near(smoke[0].duration, offBeat[4]) && smoke[0].beats == 4, "a lead-in of half a beat: cut on the fifth beat, reported as 4 beats")

    let short = [
        AIBeatCuts.Clip(id: ids[0], start: 2.5, duration: 3, maxDuration: 1.2),
        AIBeatCuts.Clip(id: ids[1], start: 5.5, duration: 0.3, maxDuration: 0.3)
    ]
    let fitted = AIBeatCuts.layout(short, beats: everyHalfSecond, beatsPerClip: 4)
    check(near(fitted[0].duration, 1.0) && fitted[0].beats == 2, "media too short for four beats: the most that fit (two)")
    check(fitted[1].beats == nil && near(fitted[1].duration, 0.3), "shorter than one beat: keeps its length")

    let framed = AIBeatCuts.onFrames([0.24, 0.71, 2.113, 2.12], frame: 1.0 / 24)
    check(zip(framed, [0.25, 0.7083333333333333, 2.125]).allSatisfy(near) && framed.count == 3,
          "beats snap to the nearest frame, and two beats on one frame count once")

    let late = AIBeatCuts.layout([AIBeatCuts.Clip(id: ids[0], start: 19.8, duration: 3, maxDuration: 10)], beats: everyHalfSecond, beatsPerClip: nil)
    check(late[0].beats == nil && near(late[0].duration, 3), "after the music's last beat: keeps its length")
}

private func checkBeatApply() {
    let url = URL(fileURLWithPath: "/tmp/shots.mov")
    let group = UUID()
    let first = EditClip(sourceURL: url, sourceDuration: 2.3, timelineStart: 0, linkGroup: group)
    let sound = EditClip(sourceURL: url, isAudioOnly: true, sourceDuration: 2.3, timelineStart: 0, linkGroup: group, audioAssetDuration: 30)
    let second = EditClip(sourceURL: url, sourceStart: 5, sourceDuration: 1.1, timelineStart: 2.3)
    let third = EditClip(sourceURL: url, sourceStart: 9, sourceDuration: 3, timelineStart: 3.4)
    let after = EditClip(sourceURL: url, sourceStart: 20, sourceDuration: 4, timelineStart: 6.4)
    var state = TimelineState()
    state.mainClips = [first, second, third, after]
    state.audioTracks = [EditLane(clips: [sound])]
    let placed = AIBeatCuts.layout([first, second, third].map {
        AIBeatCuts.Clip(id: $0.id, start: $0.timelineStart, duration: $0.timelineDuration, maxDuration: 10)
    }, beats: everyHalfSecond, beatsPerClip: nil)
    AIBeatCuts.apply(placed, in: &state)
    check(zip(state.mainClips.map(\.timelineStart), [0, 2.5, 3.5, 6.5]).allSatisfy(near), "clips re-timed, the clip after the run moved 0.1 s")
    checkEqual(state.mainClips.map(\.sourceStart), [0, 5, 9, 20], "in points never move")
    check(near(state.mainClips[0].sourceDuration, 2.5), "the first clip now ends on the beat at 2.5")
    check(near(state.audioTracks[0].clips[0].timelineEnd, 2.5), "its linked sound ends there too")
}
