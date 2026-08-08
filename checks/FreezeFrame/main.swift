import CoreGraphics
import Foundation
import SrtFlowCore

// 定格（Freeze Frame）的时间线自检：分割 + 让位 + 音轨波纹 + 关键帧烘焙。
// 全是纯值变换，不碰 AVFoundation / ffmpeg / 磁盘。编译方式见
// scripts/check-freeze-frame.sh。

var failures = 0
var checks = 0

func check(_ condition: Bool, _ message: String, line: Int = #line) {
    checks += 1
    if !condition {
        failures += 1
        print("FAIL [line \(line)] \(message)")
    }
}

func checkClose(_ actual: Double, _ expected: Double, _ message: String, line: Int = #line) {
    checks += 1
    if abs(actual - expected) > 0.001 {
        failures += 1
        print("FAIL [line \(line)] \(message): got \(actual), expected \(expected)")
    }
}

let media = URL(fileURLWithPath: "/tmp/srtflow-freeze-check/source.mp4")
let png = URL(fileURLWithPath: "/tmp/srtflow-freeze-check/source-freeze-00m03s00.png")
let still = URL(fileURLWithPath: "/tmp/srtflow-freeze-check/still.mp4")
let canvas = CGSize(width: 1920, height: 1080)

func videoClip(start: Double, duration: Double, url: URL = media) -> EditClip {
    EditClip(sourceURL: url, sourceDuration: duration, timelineStart: start)
}

/// 造一条主轨：三段各 10 秒，首尾相接。
func mainTimeline() -> TimelineState {
    var state = TimelineState()
    state.mainClips = [
        videoClip(start: 0, duration: 10),
        videoClip(start: 10, duration: 10),
        videoClip(start: 20, duration: 10)
    ]
    return state
}

func freeze(of clip: EditClip, at time: Double) -> EditClip {
    clip.makeFreezeClip(image: png, still: still, info: nil, at: time, canvas: canvas, isOverlay: false)
}

// MARK: - 1. 主轨定格（磁吸开着）

do {
    var state = mainTimeline()
    let target = state.mainClips[1]
    state.insertFreeze(freeze(of: target, at: 15), splitting: target.id, at: 15)
    // 磁吸开着时 perform 会跟一次 packMain，这里照做。
    state.packMain()

    // 3 段 → 中间那段切成两半（4 段）→ 再插进定格段（5 段）。
    check(state.mainClips.count == 5, "主轨应该变成 5 段，实得 \(state.mainClips.count)")
    checkClose(state.duration, 32, "总长应该是 30 + 2")
    checkClose(state.mainClips[0].timelineDuration, 10, "第一段不受影响")
    checkClose(state.mainClips[1].timelineDuration, 5, "左半是 10s 里的前 5s")
    checkClose(state.mainClips[2].timelineDuration, 2, "定格段 2 秒")
    checkClose(state.mainClips[3].timelineDuration, 5, "右半是后 5s")
    check(state.mainClips[2].stillImageURL == png, "定格段要认原图，不能只认静帧缓存")
    check(state.mainClips[2].isStillImage, "定格段是图片段")
    checkClose(state.mainClips[2].timelineStart, 15, "定格段落在切口上")
    checkClose(state.mainClips[3].timelineStart, 17, "右半接在定格段后面")
    // 原来的第三段整体后移 2 秒。
    checkClose(state.mainClips[4].timelineStart, 22, "后面那段整体后移 2 秒")
    check(state.mainClips[3].sourceStart == 5, "右半的源起点接着左半")
}

// MARK: - 2. 磁吸关着：insertFreeze 自己就得把右边推开

do {
    var state = mainTimeline()
    let target = state.mainClips[1]
    state.insertFreeze(freeze(of: target, at: 15), splitting: target.id, at: 15)
    // 不调 packMain。

    checkClose(state.mainClips[2].timelineStart, 15, "定格段落在切口上")
    checkClose(state.mainClips[3].timelineStart, 17, "右半让开 2 秒")
    checkClose(state.mainClips[4].timelineStart, 22, "后面那段也让开 2 秒")
    checkClose(state.duration, 32, "磁吸关着总长同样 +2")
}

// MARK: - 3. 音频轨跟着让位（跨切口的先切开）

do {
    var state = mainTimeline()
    state.audioTracks = [
        // 跨切口：4s→20s，切点 15s 落在里面。
        EditLane(clips: [EditClip(
            sourceURL: media, isAudioOnly: true, sourceDuration: 16,
            timelineStart: 4, audioAssetDuration: 16
        )]),
        // 切口之后：整段右移。
        EditLane(clips: [EditClip(
            sourceURL: media, isAudioOnly: true, sourceDuration: 3,
            timelineStart: 18, audioAssetDuration: 3
        )]),
        // 切口之前：一动不动。
        EditLane(clips: [EditClip(
            sourceURL: media, isAudioOnly: true, sourceDuration: 3,
            timelineStart: 1, audioAssetDuration: 3
        )])
    ]
    let target = state.mainClips[1]
    state.insertFreeze(freeze(of: target, at: 15), splitting: target.id, at: 15)

    check(state.audioTracks[0].clips.count == 2, "跨切口的音频段要被切开")
    checkClose(state.audioTracks[0].clips[0].timelineStart, 4, "左半不动")
    checkClose(state.audioTracks[0].clips[0].timelineEnd, 15, "左半在切口处收口")
    checkClose(state.audioTracks[0].clips[1].timelineStart, 17, "右半让开 2 秒")
    checkClose(state.audioTracks[1].clips[0].timelineStart, 20, "切口之后的音频右移 2 秒")
    checkClose(state.audioTracks[2].clips[0].timelineStart, 1, "切口之前的音频不动")
}

// MARK: - 4. 画中画定格只动自己那条轨

do {
    var state = mainTimeline()
    state.overlayTracks = [EditLane(clips: [
        videoClip(start: 2, duration: 8),
        videoClip(start: 12, duration: 4)
    ])]
    state.audioTracks = [EditLane(clips: [EditClip(
        sourceURL: media, isAudioOnly: true, sourceDuration: 5,
        timelineStart: 20, audioAssetDuration: 5
    )])]
    let target = state.overlayTracks[0].clips[0]
    state.insertFreeze(freeze(of: target, at: 6), splitting: target.id, at: 6)

    // 2 段 → 第一段切成两半（3 段）→ 再插进定格段（4 段）。
    check(state.overlayTracks[0].clips.count == 4, "画中画那条轨应该变 4 段")
    checkClose(state.overlayTracks[0].clips[1].timelineStart, 6, "定格段落在切口上")
    checkClose(state.overlayTracks[0].clips[2].timelineStart, 8, "同轨右半让开 2 秒")
    checkClose(state.overlayTracks[0].clips.last!.timelineStart, 14, "同轨后面那段也让开")
    checkClose(state.mainClips[0].timelineStart, 0, "主轨一动不动")
    check(state.mainClips.count == 3, "主轨段数不变")
    checkClose(state.audioTracks[0].clips[0].timelineStart, 20, "画中画定格不推全局音频")
}

// MARK: - 5. 叠化区里不给定格

do {
    var state = mainTimeline()
    state.mainClips[0].transitionAfter = .crossFade
    state.mainClips[0].transitionDuration = 1
    state.packMain()

    // 叠化区 = 第一段末尾往前 1 秒。
    check(state.isInsideMainTransition(time: 9.5), "叠化区里应判定为 true")
    check(!state.isInsideMainTransition(time: 5), "远离转场的地方应判定为 false")
    check(!state.isInsideMainTransition(time: 20), "没有转场的接缝应判定为 false")
}

// MARK: - 5b. 牵扯转场的主轨段不给定格（否则声画永久错开）
//
// 回归：转场时长有「不超过两边任一段 45%」的上限，定格把目标切短后那个上限会缩，
// 于是 packMain() 让后面的画面移动的距离 ≠ 定格时长，而音频只顺推固定 2 秒。
// 实测 A(0-10s, 1s 转场) 在 8.5s 定格：画面位移 2.325s、音频位移 2.0s，错位 0.325s。
// 现在这种段一律不给定格，本检查同时钉住「判据」和「不禁的话真的会错」。

do {
    var state = mainTimeline()
    state.mainClips[0].transitionAfter = .crossFade
    state.mainClips[0].transitionDuration = 1
    state.packMain()

    check(state.participatesInMainTransition(clipID: state.mainClips[0].id),
          "自己往后叠的段算牵扯转场")
    check(state.participatesInMainTransition(clipID: state.mainClips[1].id),
          "被前一段叠上来的段也算牵扯转场")
    check(!state.participatesInMainTransition(clipID: state.mainClips[2].id),
          "离转场远的段不算")

    // 钉住「为什么要禁」：同样的时间线放行的话，声画会差 0.325 秒。
    var drifting = TimelineState()
    var a = videoClip(start: 0, duration: 10)
    a.transitionAfter = .crossFade
    a.transitionDuration = 1
    drifting.mainClips = [a, videoClip(start: 10, duration: 10)]
    drifting.audioTracks = [EditLane(clips: [EditClip(
        sourceURL: media, isAudioOnly: true, sourceDuration: 5,
        timelineStart: 9, audioAssetDuration: 5
    )])]
    drifting.packMain()
    let videoBefore = drifting.mainClips[1].timelineStart
    let audioBefore = drifting.audioTracks[0].clips[0].timelineStart
    let target = drifting.mainClips[0]
    drifting.insertFreeze(freeze(of: target, at: 8.5), splitting: target.id, at: 8.5)
    drifting.packMain()
    let videoShift = drifting.mainClips.last!.timelineStart - videoBefore
    let audioShift = drifting.audioTracks[0].clips.last!.timelineStart - audioBefore
    checkClose(videoShift, 2.325, "转场被重新限长后画面位移不是 2 秒")
    checkClose(audioShift, 2.0, "音频只会顺推固定的定格时长")
    check(abs(videoShift - audioShift) > 0.3,
          "这就是必须在入口禁掉牵扯转场的段的原因（真放行会错位 0.325s）")
}

// MARK: - 6. 定格段继承静态变换；有动画时烘成静态值

do {
    var source = videoClip(start: 0, duration: 10)
    source.crop = ClipCrop(top: 0.1, bottom: 0.2, leading: 0.05, trailing: 0)
    source.rotationDegrees = 30
    source.opacity = 0.5
    source.flippedHorizontally = true
    source.placement = ClipPlacement(centerX: 0.3, centerY: 0.7, width: 0.4, height: 0.25)

    let plain = freeze(of: source, at: 4)
    check(plain.crop == source.crop, "裁切要继承，否则画面在切口处跳一下")
    checkClose(plain.rotationDegrees, 30, "旋转要继承")
    checkClose(plain.opacity, 0.5, "不透明度要继承")
    check(plain.flippedHorizontally, "翻转要继承")
    check(plain.placement == source.placement, "自由摆放要继承")
    check(plain.transitionAfter == .none, "定格两边是硬切")
    check(plain.isMuted, "定格段静音")
    check(plain.animation == nil, "没动画就是没动画")

    // 关键帧：0s 时 opacity=0，10s 时 opacity=1，第 4 秒定格应该烘出 0.4。
    var animation = ClipAnimation()
    animation.opacity = KeyframeTrack(keys: [
        Keyframe(time: 0, value: 0),
        Keyframe(time: 10, value: 1)
    ])
    animation.rotation = KeyframeTrack(keys: [
        Keyframe(time: 0, value: 0),
        Keyframe(time: 10, value: 100)
    ])
    source.animation = animation

    let baked = freeze(of: source, at: 4)
    check(baked.animation == nil, "定格段只有一帧，动画必须烘掉")
    checkClose(baked.opacity, 0.4, "不透明度按那一刻烘")
    checkClose(baked.rotationDegrees, 40, "旋转按那一刻烘")
}

// MARK: - 7. 切点不在目标段里就什么都不做

do {
    var state = mainTimeline()
    let before = state
    let target = state.mainClips[1]
    state.insertFreeze(freeze(of: target, at: 25), splitting: target.id, at: 25)
    check(state == before, "切点落在别的段上时时间线不该有任何变化")
}

print("\(checks - failures)/\(checks) 项通过")
if failures > 0 {
    print("定格自检失败：\(failures) 项")
    exit(1)
}
print("定格自检通过")
