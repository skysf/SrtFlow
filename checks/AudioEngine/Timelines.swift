import Foundation
import SrtFlowCore

// 自检用的时间线：都是现造的恒定振幅正弦（和 check-audio-fade 同一套做法），
// 这样两条管线的差只能来自混音本身。编译方式见 scripts/check-audio-engine.sh。

/// 带画面的素材要 info（主轨 / 上层轨的段按它判有没有声音）；纯音频段的 info 是 nil。
let videoInfo = MediaInfo(
    duration: 4, displaySize: CGSize(width: 320, height: 180), frameRate: 30,
    videoCodec: "h264", audioCodec: "aac", hasAudio: true,
    audioCanCopyToMP4: true, fileBytes: 1
)

func audioClip(_ source: URL, start: Double = 0, sourceStart: Double = 0, duration: Double = 4) -> EditClip {
    EditClip(
        sourceURL: source, isAudioOnly: true, sourceStart: sourceStart, sourceDuration: duration,
        timelineStart: start, audioAssetDuration: 4
    )
}

func baseState() -> TimelineState {
    var state = TimelineState()
    state.frameRate = .fps30
    state.canvasRatio = .wide16x9
    return state
}

/// 一条音频轨一段，轨道推子 0.5、总推子 0.8。
func plainLane(_ tone: URL) -> TimelineState {
    var state = baseState()
    state.audioTracks = [EditLane(clips: [audioClip(tone)], volume: 0.5)]
    state.masterVolume = 0.8
    return state
}

/// 渐入 1 秒、渐出 1.5 秒，音量 0.7。
func fadedLane(_ tone: URL) -> TimelineState {
    var clip = audioClip(tone)
    clip.volume = 0.7
    clip.fadeInDuration = 1.0
    clip.fadeOutDuration = 1.5
    var state = baseState()
    state.audioTracks = [EditLane(clips: [clip])]
    return state
}

/// 画了音量曲线（0 → −20 → −20 → 0 dB）再加 0.5 秒渐入。
func curvedLane(_ tone: URL) -> TimelineState {
    var clip = audioClip(tone)
    clip.volumeCurve = KeyframeTrack(keys: [
        Keyframe(time: 0.5, value: 0), Keyframe(time: 1.5, value: -20),
        Keyframe(time: 2.5, value: -20), Keyframe(time: 3.5, value: 0),
    ])
    clip.fadeInDuration = 0.5
    var state = baseState()
    state.audioTracks = [EditLane(clips: [clip])]
    return state
}

/// 主轨两段带画面的素材，中间 1 秒叠化；两段各留了 0.5 秒余料。
func crossfadedMain(_ toneA: URL, _ toneB: URL) -> TimelineState {
    var first = EditClip(sourceURL: toneA, sourceStart: 0.5, sourceDuration: 3, timelineStart: 0, info: videoInfo)
    first.transitionAfter = .crossFade
    first.transitionDuration = 1.0
    let second = EditClip(sourceURL: toneB, sourceStart: 0.5, sourceDuration: 3, timelineStart: 3, info: videoInfo)
    var state = baseState()
    state.mainClips = [first, second]
    return state
}

/// 主轨两段相接、接缝有 5 毫秒的零头（不到 mainGapTolerance，接在上一段末尾）。
func mainWithSliverGap(_ toneA: URL, _ toneB: URL) -> TimelineState {
    let first = EditClip(sourceURL: toneA, sourceStart: 0, sourceDuration: 2, timelineStart: 0, info: videoInfo)
    let second = EditClip(sourceURL: toneB, sourceStart: 0, sourceDuration: 2, timelineStart: 2.005, info: videoInfo)
    var state = baseState()
    state.mainClips = [first, second]
    return state
}

/// 静音的段 + 隐藏的轨 + 主轨推子：只有主轨那一段该响。
func mutedAndHidden(_ toneA: URL, _ toneB: URL, _ toneC: URL) -> TimelineState {
    var muted = audioClip(toneB)
    muted.isMuted = true
    var state = baseState()
    state.mainClips = [EditClip(sourceURL: toneA, sourceStart: 0, sourceDuration: 3, timelineStart: 0, info: videoInfo)]
    state.mainVolume = 0.6
    state.audioTracks = [
        EditLane(clips: [muted]),
        EditLane(clips: [audioClip(toneC)], isHidden: true),
    ]
    return state
}

/// 上层视频轨一段（推子 0.7）叠在主轨上，错开 1 秒。
func overlayOverMain(_ toneA: URL, _ toneB: URL) -> TimelineState {
    var state = baseState()
    state.mainClips = [EditClip(sourceURL: toneA, sourceStart: 0, sourceDuration: 4, timelineStart: 0, info: videoInfo)]
    state.overlayTracks = [EditLane(
        clips: [EditClip(sourceURL: toneB, sourceStart: 0, sourceDuration: 2, timelineStart: 1, info: videoInfo)],
        volume: 0.7
    )]
    return state
}

/// 44.1 kHz 单声道的素材：要重采样、单声道要铺到两边。
func monoLane(_ tone: URL) -> TimelineState {
    var state = baseState()
    state.audioTracks = [EditLane(clips: [audioClip(tone, start: 0.5, sourceStart: 0.25, duration: 3)])]
    return state
}
