import CoreGraphics
import Foundation

// 铺满时跟着主体走（AIFollowSubject + AIClipEdit 写关键帧）：要不要跟、平滑与精简、只有一个点时就是固定的那扇窗，
// 以及**每个关键帧那一刻，窗的四边正好落在画布四边**（照合同自己算，不借被测代码）。编法见 scripts/check-mcp.sh。

func runFollowChecks() {
    checkFollowDecision()
    checkFollowPath()
    checkFollowFraming()
    checkFollowWrittenAsKeyframes()
}

private let wide = CGSize(width: 1920, height: 1080)
private let tall = CGSize(width: 1080, height: 1920)

private func pictureClip(_ display: CGSize) -> EditClip {
    let info = MediaInfo(
        duration: 30, displaySize: display, frameRate: 30,
        videoCodec: "h264", audioCodec: "aac", hasAudio: true, audioCanCopyToMP4: true, fileBytes: 1
    )
    return EditClip(sourceURL: media, sourceDuration: 10, timelineStart: 0, info: info)
}

/// 一帧里一张脸，中心在 (x, y)。
private func face(_ x: Double, _ y: Double = 0.4) -> AISubjectFocus.FrameFindings {
    AISubjectFocus.FrameFindings(faces: [CGRect(x: x - 0.03, y: y - 0.05, width: 0.06, height: 0.1)])
}

/// 16:9 素材铺进 9:16 画布的那扇窗（大小不随焦点变）。
private let window = AIFrameFit.fillWindow(display: wide, canvas: tall, active: AIFrameFit.wholePicture, focus: CGPoint(x: 0.5, y: 0.5)).size

private func checkFollowDecision() {
    let still = (0..<10).map { AIFollowSubject.Sample(time: Double($0), findings: face(0.5 + 0.01 * Double($0 % 2))) }
    check(!AIFollowSubject.needsFollow(AIFollowSubject.targets(still, window: window), window: window),
          "a subject that stays put: one fixed window is enough")
    let walking = (0..<10).map { AIFollowSubject.Sample(time: Double($0), findings: face(0.2 + 0.06 * Double($0))) }
    check(AIFollowSubject.needsFollow(AIFollowSubject.targets(walking, window: window), window: window),
          "a subject walking across the frame: follow it")
    var gappy = walking
    gappy[3].findings = AISubjectFocus.FrameFindings()
    let targets = AIFollowSubject.targets(gappy, window: window).points
    checkEqual(targets.count, 10, "a frame where nobody was found still gets a target")
    check(abs(targets[3].center.x - targets[2].center.x) < 1e-9 || abs(targets[3].center.x - targets[4].center.x) < 1e-9,
          "…the nearest frame's")
    check(AIFollowSubject.targets([AIFollowSubject.Sample(time: 0, findings: .init())], window: window).points.isEmpty,
          "nothing found at all: no targets")
    let salient = (0..<10).map { index in
        AIFollowSubject.Sample(time: Double(index), findings: AISubjectFocus.FrameFindings(
            salient: [CGRect(x: 0.05 + 0.08 * Double(index), y: 0.3, width: 0.1, height: 0.1)]
        ))
    }
    check(!AIFollowSubject.needsFollow(AIFollowSubject.targets(salient, window: window), window: window),
          "only 'whatever stands out' (no face, no person): no following, it jumps from frame to frame")
    var few = walking
    for index in 0..<6 { few[index].findings = AISubjectFocus.FrameFindings() }
    check(!AIFollowSubject.needsFollow(AIFollowSubject.targets(few, window: window), window: window),
          "a person seen in only 4 of 10 frames: no following")
}

private func checkFollowPath() {
    let pan = (0..<20).map { AIFollowSubject.Point(time: Double($0) * 0.5, center: CGPoint(x: 0.3 + 0.02 * Double($0), y: 0.5)) }
    let straight = AIFollowSubject.simplify(pan, tolerance: AIFollowSubject.simplifyTolerance)
    checkEqual(straight.count, 2, "a steady pan needs only its two ends")
    let turn = (0..<21).map { index -> AIFollowSubject.Point in
        let x = index <= 10 ? 0.3 + 0.03 * Double(index) : 0.6 - 0.03 * Double(index - 10)
        return AIFollowSubject.Point(time: Double(index) * 0.5, center: CGPoint(x: x, y: 0.5))
    }
    let kept = AIFollowSubject.simplify(turn, tolerance: AIFollowSubject.simplifyTolerance)
    check(kept.count == 3 && abs(kept[1].time - 5) < 1e-9, "walking there and back: the turn is kept")
    let targets = (0..<20).map { AIFollowSubject.Point(time: Double($0) * 0.5, center: CGPoint(x: $0 % 2 == 0 ? 0.02 : 0.98, y: 0.5)) }
    let path = AIFollowSubject.path(targets, window: window, active: AIFrameFit.wholePicture)
    check(path.allSatisfy { $0.center.x >= window.width / 2 - 1e-9 && $0.center.x <= 1 - window.width / 2 + 1e-9 },
          "the window never leaves the picture")
    check(path.allSatisfy { abs($0.center.x - 0.5) < 0.2 }, "frame-to-frame jitter is smoothed away")

    let before = (0..<8).map { AIFollowSubject.Point(time: Double($0) * 0.5, center: CGPoint(x: 0.3, y: 0.5)) }
    let after = (8..<16).map { AIFollowSubject.Point(time: Double($0) * 0.5, center: CGPoint(x: 0.7, y: 0.5)) }
    let jumped = AIFollowSubject.path(before + after, window: window, active: AIFrameFit.wholePicture, cuts: [3.8], frame: 1.0 / 24)
    check(jumped.contains { abs($0.time - (3.8 - 1.0 / 24)) < 1e-9 && abs($0.center.x - 0.3) < 0.01 }
          && jumped.contains { abs($0.time - 3.8) < 1e-9 && abs($0.center.x - 0.7) < 0.01 },
          "a shot change inside the clip: the window jumps there within one frame")
    check(!jumped.contains { $0.center.x > 0.35 && $0.center.x < 0.65 }, "…and neither shot is smoothed into the other")
}

/// 这一刻源画面上归一化的一点落在画布的哪儿（照合同：裁切 → 缩放进这一刻的摆放框）。
private func canvasX(_ sourceX: Double, crop: ClipCrop?, placement: ClipPlacement, canvas: CGSize) -> Double {
    let crop = crop ?? ClipCrop()
    let keptX = crop.leading, keptW = 1 - crop.leading - crop.trailing
    let frame = placement.frame(in: canvas)
    return frame.minX + (sourceX - keptX) / keptW * frame.width
}

private func checkFollowFraming() {
    let clip = pictureClip(wide)
    let single = AIFollowSubject.framing([AIFollowSubject.Point(time: 0, center: CGPoint(x: 0.3, y: 0.5))], window: window)
    let fixed = AIFrameFit.fill(clip, canvas: tall, active: AIFrameFit.wholePicture, focus: CGPoint(x: 0.3, y: 0.5))
    let singleFrame = single?.placement?.frame(in: tall) ?? .zero
    let fixedFrame = (fixed?.placement ?? clip.defaultPlacement(canvas: tall)).frame(in: tall)
    check(single?.crop == fixed?.crop && abs(singleFrame.minX - fixedFrame.minX) < 0.5 && abs(singleFrame.width - fixedFrame.width) < 0.5,
          "one point: the same fixed window as fill")

    let path = [0.25, 0.4, 0.7, 0.75].enumerated().map { AIFollowSubject.Point(time: Double($0.offset) * 2, center: CGPoint(x: $0.element, y: 0.5)) }
    guard let moving = AIFollowSubject.framing(path, window: window), let base = moving.placement else {
        check(false, "a moving path gives a framing")
        return
    }
    checkEqual(moving.follow.count, path.count, "one keyframe per path point")
    check(moving.replacesMotion, "following replaces the clip's own position keyframes")
    var worst = 0.0
    for (point, key) in zip(path, moving.follow) {
        var placement = base
        placement.centerX = Double(key.center.x)
        placement.centerY = Double(key.center.y)
        let left = canvasX(point.center.x - window.width / 2, crop: moving.crop, placement: placement, canvas: tall)
        let right = canvasX(point.center.x + window.width / 2, crop: moving.crop, placement: placement, canvas: tall)
        worst = max(worst, abs(left), abs(right - tall.width))
    }
    check(worst < 0.5, "at every keyframe the window's left and right edges land on the canvas edges (worst \(worst) px)")
}

private func checkFollowWrittenAsKeyframes() {
    var state = TimelineState()
    var clip = pictureClip(wide)
    clip.speed = 2
    state.mainClips = [clip]
    let path = [AIFollowSubject.Point(time: 2, center: CGPoint(x: 0.3, y: 0.5)), AIFollowSubject.Point(time: 8, center: CGPoint(x: 0.7, y: 0.5))]
    guard let framing = AIFollowSubject.framing(path, window: window) else { return check(false, "framing") }
    var change = AIClipChange()
    change.framing = framing
    let next = try? AIClipEdit.apply(change, to: clip.id, linkage: false, stillDuration: 5, in: state)
    let animation = next?.clip(with: clip.id)?.animation
    checkEqual(animation?.centerX.keys.map(\.time), [2, 8], "keyframes sit at the samples' source seconds (speed 2 does not shift them)")
    checkEqual(animation?.width.keys.count ?? 0, 0, "no size keyframes: the size stays fixed")

    var manual = clip
    var own = ClipAnimation()
    own.width.set(0.5, atSourceTime: 1, tolerance: 0.01)
    own.opacity.set(0.4, atSourceTime: 1, tolerance: 0.01)
    manual.animation = own
    state.mainClips = [manual]
    var fill = AIClipChange()
    fill.framing = AIFrameFit.fill(manual, canvas: tall, active: AIFrameFit.wholePicture, focus: CGPoint(x: 0.5, y: 0.5))
    let filled = (try? AIClipEdit.apply(fill, to: manual.id, linkage: false, stillDuration: 5, in: state))?.clip(with: manual.id)
    check(filled?.animation?.width.isEmpty == true && filled?.animation?.opacity.isEmpty == false,
          "fill replaces the size keyframes but keeps the opacity ones")
    var place = AIClipChange()
    place.framing = AIFrameFit.place(manual, canvas: tall, crop: nil, x: 0.2, y: 0.2, scale: 0.5)
    checkThrows("placing by x/y/scale still refuses a clip whose size is animated") {
        _ = try AIClipEdit.apply(place, to: manual.id, linkage: false, stillDuration: 5, in: state)
    }
}
