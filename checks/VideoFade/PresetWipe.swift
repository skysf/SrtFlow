import Foundation

// 预设入场动画：逐帧效果真的进了成片（从 main.swift 第 6 组原样搬来：那个文件在行数基线里只许降，
// 2026-10-05 给「上层轨的缓动关键帧」腾地方，见 docs/architecture/coding-standards.md）。
//
// 擦除是几何量，成片上一量就知道对不对：2s 的窗口走到半程时，
// 左半边该是这一段的画面、右半边还是垫在下面的黑底。编法见 scripts/check-video-fade.sh。

func checkPresetWipe(white: URL, info landscape: MediaInfo) async {
    var clip = EditClip(sourceURL: white, sourceDuration: 4, timelineStart: 0, info: landscape)
    clip.presetAnimation.entrance = .wipe
    clip.videoFadeInDuration = 2
    var state = TimelineState()
    state.mainClips = [clip]
    check(clip.needsPerFrameRender, "擦除入场必须走逐帧路径（否则 ffmpeg 的 fade 顶不了这活）")
    if let product = await export(state, name: "preset-wipe.mp4") {
        if let level = pixel(product, x: 8, y: 18, at: 1.0, name: "preset-wipe-left") {
            check(level > 0.7, "擦除半程时左侧应当已经揭开（白），实测 \(level)")
        }
        if let level = pixel(product, x: 56, y: 18, at: 1.0, name: "preset-wipe-right") {
            check(level < 0.3, "擦除半程时右侧还没揭开，应当是垫底的黑，实测 \(level)")
        }
        if let level = brightness(product, at: 3.0, name: "preset-wipe-end") {
            check(level > 0.9, "动画结束后应当是完整画面（白），实测 \(level)")
        }
    }
}
