import CoreGraphics
import Foundation
import SrtFlowMCPKit

// set_track（AITrackSettings）：轨道名只认现有的轨和 master、推子 dB 换算、藏起来写绝对值、总推子不能藏；
// set_keyframes（AIKeyframes）：时间线秒换源时间（变速的段也对）、大小按默认布局换算、来回写一遍不变、空列表去掉那一行、
// 全去掉回到没动画、段外的时间和纯音频的段报错。编法见 scripts/check-mcp.sh。

func runTrackKeyframeChecks() {
    checkTrackSettings()
    checkKeyframes()
}

private func checkTrackSettings() {
    var state = TimelineState()
    state.mainClips = [videoClip(0, 5)]
    state.audioTracks = [EditLane(clips: [audioClip(0, 5)])]
    checkEqual(try? AITrackSettings.target("master", in: state), .master, "master")
    checkEqual(try? AITrackSettings.target("a1", in: state), .track(.audio(0)), "A1 (any case)")
    checkThrows("a track that does not exist yet is refused") { _ = try AITrackSettings.target("A2", in: state) }
    checkThrows("V2 does not exist yet either") { _ = try AITrackSettings.target("V2", in: state) }

    var ducked = state
    try? AITrackSettings.apply(.track(.audio(0)), volumeDB: -12, hidden: nil, in: &ducked)
    check(abs(ducked.audioTracks[0].volume - 0.2512) < 0.001, "A1 at −12 dB (got \(ducked.audioTracks[0].volume))")
    try? AITrackSettings.apply(.track(.main), volumeDB: nil, hidden: true, in: &ducked)
    check(ducked.mainHidden, "V1 hidden")
    try? AITrackSettings.apply(.master, volumeDB: 20, hidden: nil, in: &ducked)
    checkEqual(ducked.masterVolume, AudioGain.maximumLinear, "the master fader is clamped at +6 dB")
    checkThrows("the master cannot be hidden") { try AITrackSettings.apply(.master, volumeDB: nil, hidden: true, in: &ducked) }
    checkEqual(AITrackSettings.decibels(0.5), .number(-6), "faders are reported in dB")
}

private func checkKeyframes() {
    let canvas = CGSize(width: 1080, height: 1920)
    var clip = videoClip(10, 3, sourceStart: 4)
    clip.speed = 2
    clip.sourceDuration = 6
    let request = try? AIKeyframes.parse(args([
        "scale": [["time": 10, "value": 1], ["time": 13, "value": 1.2]],
        "position": [["time": 11, "x": 0.4, "y": 0.5]],
        "opacity": [["time": 10, "value": 0], ["time": 10.5, "value": 1]]
    ]))
    guard let request else {
        check(false, "the keyframe request did not parse")
        return
    }
    var animated = clip
    do {
        try AIKeyframes.apply(request, to: &animated, canvas: canvas, frameRate: .fps30)
    } catch {
        check(false, "keyframes were refused: \(error)")
        return
    }
    let base = clip.defaultPlacement(canvas: canvas)
    checkEqual(animated.animation?.width.keys.map(\.time), [4, 10], "scale keys in source time (speed 2)")
    check(abs((animated.animation?.width.keys.last?.value ?? 0) - base.width * 1.2) < 1e-9, "scale 1.2 is 1.2 × the default width")
    check(abs((animated.animation?.height.keys.last?.value ?? 0) - base.height * 1.2) < 1e-9, "and 1.2 × the default height")
    let summary = AIKeyframes.summary(animated, canvas: canvas)
    checkEqual(summary?["scale"]?.arrayValue?.last?.arrayValue?.map(\.doubleValue), [13, 1.2], "read back: timeline time and the same scale")
    checkEqual(summary?["position"]?.arrayValue?.first?.arrayValue?.map(\.doubleValue), [11, 0.4, 0.5], "position reads back")

    var cleared = animated
    try? AIKeyframes.apply(AIKeyframes.Request(scale: [], opacity: []), to: &cleared, canvas: canvas, frameRate: .fps30)
    check(cleared.animation?.width.isEmpty == true && cleared.animation?.centerX.isEmpty == false,
          "[] removes only that property")
    try? AIKeyframes.apply(AIKeyframes.Request(position: []), to: &cleared, canvas: canvas, frameRate: .fps30)
    check(cleared.animation == nil, "nothing left: the clip has no animation at all")

    checkThrows("a keyframe outside the clip is refused") {
        var copy = clip
        try AIKeyframes.apply(AIKeyframes.Request(rotation: [(time: 30, value: 10)]), to: &copy, canvas: canvas, frameRate: .fps30)
    }
    checkThrows("an audio clip cannot be animated") {
        var sound = audioClip(0, 5)
        try AIKeyframes.apply(AIKeyframes.Request(opacity: [(time: 1, value: 0.5)]), to: &sound, canvas: canvas, frameRate: .fps30)
    }
    checkThrows("a request with nothing in it is refused") { _ = try AIKeyframes.parse(args(["clip_id": "x"])) }
    checkThrows("a position point needs y") { _ = try AIKeyframes.parse(args(["position": [["time": 1, "x": 0.5]]])) }
}
