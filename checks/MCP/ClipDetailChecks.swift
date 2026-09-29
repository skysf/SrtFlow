import Foundation
import SrtFlowMCPKit

// edit_clip 的其余设置（AIClipDetails）：旋转 / 不透明度夹紧、做了关键帧的不改；入场出场种类和时长成对；音量曲线换到源时间
// （变速的段也对）、空列表去掉；有曲线时 volume_db 平移整条（以前写 volume、被曲线盖着听不出来）；声音场景的旋钮名
// 对不上报错；标记落在段外报错；纯音频的段不许改画面、没声音的段不许改声音。编法见 scripts/check-mcp.sh。

func runClipDetailChecks() {
    checkPictureDetails()
    checkEntranceAndExit()
    checkVolumeCurveDetails()
    checkSoundSceneDetails()
    checkMarkerDetails()
}

private func edited(_ clip: EditClip, _ fields: [String: JSONValue], track: TrackSlot = .main) throws -> EditClip? {
    var state = TimelineState()
    switch track {
    case .audio: state.audioTracks = [EditLane(clips: [clip])]
    default: state.mainClips = [clip]
    }
    var change = AIClipChange()
    change.volumeDB = try args(fields).double("volume_db")
    change.details = try AIClipDetails(args(fields))
    return try AIClipEdit.apply(change, to: clip.id, linkage: false, stillDuration: 20, in: state).clip(with: clip.id)
}

private func checkPictureDetails() {
    let clip = videoClip(0, 5)
    checkEqual((try? edited(clip, ["rotation": 400]))?.rotationDegrees, 360, "rotation is clamped to 360")
    checkEqual((try? edited(clip, ["rotation": 0.004]))?.rotationDegrees, 0, "a tiny rotation is none")
    checkEqual((try? edited(clip, ["opacity": 1.5]))?.opacity, 1, "opacity is clamped to 1")
    checkEqual((try? edited(clip, ["flip_horizontal": true]))?.flippedHorizontally, true, "flip")
    var keyed = clip
    var animation = ClipAnimation()
    animation.rotation.set(10, atSourceTime: 0, tolerance: 0.01)
    keyed.animation = animation
    checkThrows("a clip whose rotation has keyframes is not rotated statically") { _ = try edited(keyed, ["rotation": 20]) }
    checkThrows("an audio clip has no picture to rotate") { _ = try edited(audioClip(0, 5), ["rotation": 20], track: .audio(0)) }
}

private func checkEntranceAndExit() {
    let clip = videoClip(0, 5)
    let rise = try? edited(clip, ["entrance": "rise"])
    checkEqual(rise?.presetAnimation.entrance, .rise, "entrance kind")
    checkEqual(rise?.videoFadeInDuration, ClipPresetAnimation.defaultDuration, "a chosen entrance gets the default 0.6 s")
    let fadeOnly = try? edited(clip, ["entrance_duration": 1.2])
    checkEqual(fadeOnly?.presetAnimation.entrance, .fade, "a duration alone on no entrance is a plain fade")
    checkEqual(fadeOnly?.videoFadeInDuration, 1.2, "the given duration")
    var withExit = clip
    withExit.presetAnimation.exit = .zoom
    withExit.videoFadeOutDuration = 0.8
    let cleared = try? edited(withExit, ["exit": "none"])
    checkEqual(cleared?.presetAnimation.exit, ClipPresetKind.none, "exit none")
    checkEqual(cleared?.videoFadeOutDuration, 0, "none keeps the invariant: no duration")
    checkEqual((try? edited(clip, ["exit": "wipe", "exit_duration": 0.9]))?.videoFadeOutDuration, 0.9, "kind and duration together")
    checkEqual((try? edited(clip, ["animation_intensity": 2]))?.presetAnimation.intensity, 1, "intensity is clamped to 1")
}

private func checkVolumeCurveDetails() {
    var clip = videoClip(10, 3, sourceStart: 4)
    clip.speed = 2
    clip.sourceDuration = 6    // 时间线上 3 秒：10…13
    let curved = try? edited(clip, ["volume_curve": [["time": 11, "db": -6], ["time": 12.5, "db": 0]]])
    let keys = curved?.volumeCurve.keys ?? []
    checkEqual(keys.map(\.time), [6, 9], "curve points are stored in source time (speed 2, source starts at 4)")
    checkEqual(keys.map(\.value), [-6, 0], "curve values in dB")
    checkThrows("a curve point outside the clip is refused") { _ = try edited(clip, ["volume_curve": [["time": 20, "db": 0]]]) }
    checkThrows("volume_curve and volume_db together are refused") {
        _ = try edited(clip, ["volume_curve": [["time": 11, "db": 0]], "volume_db": -3])
    }
    guard let withCurve = curved else { return }
    let removed = try? edited(withCurve, ["volume_curve": []])
    check(removed?.hasVolumeCurve == false && removed?.volume == withCurve.volume, "[] removes the curve and leaves volume alone")
    // 有曲线时 volume_db 平移整条：段开头那一点（被夹在第一个点上，−6 dB）变成 −10，别的点跟着低 4 dB。
    let shifted = try? edited(withCurve, ["volume_db": -10])
    checkEqual(shifted?.volumeCurve.keys.map(\.value), [-10, -4], "volume_db on a curved clip moves the whole curve")
    checkEqual(shifted?.volume, withCurve.volume, "and does not write the hidden volume")
}

private func checkSoundSceneDetails() {
    let clip = videoClip(0, 5)
    let hall = try? edited(clip, ["sound_scene": ["kind": "hall", "intensity": 0.5, "room_size": 0.8]])
    checkEqual(hall?.soundScene?.kind, .hall, "scene kind")
    checkEqual(hall?.soundScene?.amount, 0.5, "intensity is the scene's amount")
    checkEqual(hall?.soundScene?.first, 0.8, "room_size is the first knob of a room scene")
    checkEqual(hall?.soundScene?.second, SoundSceneKind.hall.defaults.second, "an unset knob keeps the scene's default")
    checkThrows("a speaker knob on a room scene is refused") {
        _ = try edited(clip, ["sound_scene": ["kind": "hall", "distortion": 0.5]])
    }
    guard let withScene = hall else { return }
    check((try? edited(withScene, ["sound_scene": "none"]))?.soundScene == nil, "\"none\" removes the scene")
    var silent = clip
    silent.info?.hasAudio = false
    checkThrows("a clip without sound gets no scene") { _ = try edited(silent, ["sound_scene": ["kind": "radio"]]) }
}

private func checkMarkerDetails() {
    let clip = videoClip(10, 5, sourceStart: 2)
    let marked = try? edited(clip, ["markers": [["time": 12, "note": "漂亮的镜头", "color": "green"]]])
    checkEqual(marked?.markers.map(\.sourceTime), [4], "a marker at 12 s on the timeline sits at source 4 s")
    checkEqual(marked?.markers.first?.text, "漂亮的镜头", "the marker note")
    checkEqual(marked?.markers.first?.color, .green, "the marker colour")
    checkThrows("a marker outside the clip is refused") { _ = try edited(clip, ["markers": [["time": 30]]]) }
    guard let withMarker = marked else { return }
    checkEqual((try? edited(withMarker, ["markers": []]))?.markers.count, 0, "[] removes every marker")
    let summary = AIClipDetails.summary(withMarker)
    checkEqual(summary["markers"]?.arrayValue?.first?["time"]?.doubleValue, 12, "get_timeline shows markers in timeline seconds")
}
