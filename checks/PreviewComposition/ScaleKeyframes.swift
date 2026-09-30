import AVFoundation
import CoreGraphics
import Foundation

// 缩放关键帧的真合成：线性一片不多、按帧加密的缓动四分之一处按曲线（KeyframeSliceTimes）。
// 从 main.swift 拆出来（那个文件登记在基线里只许降）。编法见 scripts/check-preview-composition.sh。

func checkScaleKeyframes(white1: URL) async {
    // B. 缩放关键帧：白块从 0.2 长到满幅，画面平均亮度就是面积占比曲线
    //    （验证 setTransformRamp 的端点取值和切片）。
    do {
        var state = TimelineState()
        let info = MediaInfo(
            duration: 4, displaySize: CGSize(width: 64, height: 36), frameRate: 10,
            videoCodec: "h264", audioCodec: nil, hasAudio: false,
            audioCanCopyToMP4: false, fileBytes: 1
        )
        var clip = EditClip(sourceURL: white1, sourceDuration: 4, timelineStart: 0, info: info)
        var animation = ClipAnimation()
        animation.width.set(0.2, atSourceTime: 0, tolerance: kfTol)
        animation.width.set(1.0, atSourceTime: 4, tolerance: kfTol)
        animation.height.set(0.2, atSourceTime: 0, tolerance: kfTol)
        animation.height.set(1.0, atSourceTime: 4, tolerance: kfTol)
        clip.animation = animation
        state.mainClips = [clip]
        if let built = await VideoEditCompositionBuilder.build(from: state) {
            let mid = await averageBrightness(built, at: 2)
            check(mid > 0.26 && mid < 0.46, "缩放动画中点面积占比应≈0.36，实测 \(mid)")
            let tail = await averageBrightness(built, at: 3.9)
            check(tail > 0.85, "缩放动画结尾应近满幅，实测 \(tail)")
            let quarter = await averageBrightness(built, at: 1)
            check(quarter > 0.10 && quarter < 0.22, "线性：四分之一处面积 ≈ 0.16，实测 \(quarter)")
            let count = built.videoComposition?.instructions.count ?? 0
            check(count <= 3, "线性段一片不多（两个关键帧在段的两端，最多 3 片），实测 \(count)")
        } else {
            check(false, "缩放动画场景合成失败")
        }

        // B2. 同一条动画带缓动（easeInOut）：按帧加密（KeyframeSliceTimes），四分之一处按曲线只长到 0.0625 → 面积 ≈ 0.0625，
        //     中点照旧一半、结尾照旧满幅。反向验证：切片不加密的话四分之一处仍是 0.16。
        var easedAnimation = ClipAnimation()
        easedAnimation.width.set(0.2, atSourceTime: 0, tolerance: kfTol, easing: .easeInOut)
        easedAnimation.width.set(1.0, atSourceTime: 4, tolerance: kfTol)
        easedAnimation.height.set(0.2, atSourceTime: 0, tolerance: kfTol, easing: .easeInOut)
        easedAnimation.height.set(1.0, atSourceTime: 4, tolerance: kfTol)
        clip.animation = easedAnimation
        state.mainClips = [clip]
        if let built = await VideoEditCompositionBuilder.build(from: state) {
            let frames = 4 * state.frameRate.fps
            let count = built.videoComposition?.instructions.count ?? 0
            check(count >= frames - 1 && count <= frames + 2, "缓动 4 秒按帧加密：≈ \(frames) 片，实测 \(count)")
            let quarter = await averageBrightness(built, at: 1)
            check(quarter > 0.03 && quarter < 0.10, "缓动：四分之一处面积 ≈ 0.0625（线性是 0.16），实测 \(quarter)")
            let mid = await averageBrightness(built, at: 2)
            check(mid > 0.26 && mid < 0.46, "缓动中点仍 ≈ 0.36，实测 \(mid)")
            let tail = await averageBrightness(built, at: 3.9)
            check(tail > 0.85, "缓动结尾近满幅，实测 \(tail)")
        } else {
            check(false, "缓动缩放动画场景合成失败")
        }
    }
}
