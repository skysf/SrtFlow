import Foundation

// 上层轨带缓动的关键帧（2026-10-05，docs/bugfixes/2026-10-05-overlay-matte-drops-keyframe-easing.md）：上层轨带关键帧的段
// 导出时走 fill + matte 预渲染。fill 带着曲线渲；matte 是白块素材，关键帧要换到它自己的源轴上重建 —— 重建时漏了曲线，
// matte 按直线走、画面按曲线走，动画中途边缘错开：该是画面的地方露出主轨，该是主轨的地方冒出 matte 底下的黑。
//
// 场景：白色主轨上，一块黑（画布宽 0.25、高 0.5）的中心 x 在 4 秒里从 0.25 走到 0.75，曲线 easeIn。
// 走到四分之一（1 秒）时按曲线在 0.258（像素 8.5–24.5），按直线在 0.375（像素 16–32）：
// x = 12 只落在曲线的位置里（该黑），x = 28 只落在直线的位置里（该白）。预览（和预览同一个函数）、成片都要对。
// 编法见 scripts/check-video-fade.sh。

func checkEasedOverlay(white: URL, black: URL, info: MediaInfo) async {
    var upper = EditClip(sourceURL: black, sourceDuration: 4, timelineStart: 0, info: info)
    upper.placement = ClipPlacement(centerX: 0.25, centerY: 0.5, width: 0.25, height: 0.5)
    var animation = ClipAnimation()
    animation.centerX = KeyframeTrack(keys: [
        Keyframe(time: 0, value: 0.25, easing: .easeIn), Keyframe(time: 4, value: 0.75)
    ])
    upper.animation = animation
    var state = TimelineState()
    state.mainClips = [EditClip(sourceURL: white, sourceDuration: 4, timelineStart: 0, info: info)]
    state.overlayTracks = [EditLane(clips: [upper])]
    check(upper.needsPerFrameRender, "带关键帧的上层段走 fill + matte 预渲染")

    let probes = [(x: 12, dark: true, place: "只在按曲线算的位置里"), (x: 28, dark: false, place: "只在按直线算的位置里")]
    for probe in probes {
        guard let level = await previewPixel(state, x: probe.x, y: 18, at: 1) else {
            check(false, "预览在 1 秒取不出帧")
            continue
        }
        check(probe.dark ? level < 0.3 : level > 0.7,
              "预览：x=\(probe.x)（\(probe.place)）应当是\(probe.dark ? "黑" : "白")，实测 \(level)")
    }
    guard let product = await export(state, name: "eased-overlay.mp4") else { return }
    for probe in probes {
        guard let level = pixel(product, x: probe.x, y: 18, at: 1, name: "eased-overlay") else { continue }
        check(probe.dark ? level < 0.3 : level > 0.7,
              "成片：x=\(probe.x)（\(probe.place)）应当是\(probe.dark ? "画面的黑" : "主轨的白")（matte 和画面同一条曲线），实测 \(level)")
    }
}
