import Foundation

// MARK: - 39. 关键帧的缓动（VideoEditKeyframeEasing.swift、Keyframe.easing）
//
// 插值：每种曲线在 t = 0 / 0.25 / 0.5 / 0.75 / 1 的值、两端夹紧、linear 和以前那条式子逐位一致；
// set 的规矩（已有的帧只改值曲线留着、给了才换；新帧默认线性）；clipped / stretched 带着曲线走；
// 存盘：linear 不落键、往返不变、老文件读出来是 linear、不认识的值回落 linear、只有真有曲线才抬 v27、用了急停 / 回弹 / 弹簧才是 v32；
// 冲过头（回弹、弹簧）：摆放的宽高留下限、最低不透明度算上冲过头的那一下；
// 切片：带缓动的段按帧加密、线性段一片不多、旋转照旧 ≤ 6°/片（KeyframeSliceTimes）。
// 方案：docs/plans/2026-09-30-export-limiter-and-easing.md；长期约束：docs/architecture/keyframe-animation.md「缓动」。

func checkKeyframeEasing(root: URL) throws {
    let tol = KeyframeTrack.sourceTolerance(frameRate: .fps30, speed: 1)

    // ---- 曲线本身 ----
    checkEqual(KeyframeEasing.allCases.map(\.rawValue), ["linear", "easeIn", "easeOut", "easeInOut", "snap", "overshoot", "spring"],
               "七种曲线的名字（AI 词表对账用）")
    let samples: [(KeyframeEasing, [Double])] = [
        (.linear, [0, 0.25, 0.5, 0.75, 1]),
        (.easeIn, [0, 0.015625, 0.125, 0.421875, 1]),
        (.easeOut, [0, 0.578125, 0.875, 0.984375, 1]),
        (.easeInOut, [0, 0.0625, 0.5, 0.9375, 1]),
        (.snap, [0, 0.824028019566, 0.969696969697, 0.995447845308, 1]),
        (.overshoot, [0, 0.8174096875, 1.0876975, 1.0641365625, 1]),
        (.spring, [0, 1.206145388047, 0.964795226342, 1.004251228925, 1]),
    ]
    for (easing, expected) in samples {
        let got = [0, 0.25, 0.5, 0.75, 1].map { easing.apply($0) }
        check(zip(got, expected).allSatisfy { abs($0 - $1) < 1e-9 }, "\(easing.rawValue) 在 0 / ¼ / ½ / ¾ / 1 的值：\(got)")
    }
    check(KeyframeEasing.easeInOut.apply(0.5) == 0.5 && KeyframeEasing.easeIn.apply(0.999) < 1 && KeyframeEasing.easeOut.apply(0.001) > 0,
          "缓入缓出正中间正好一半、缓入到最后才追上、缓出一起步就领先")
    // 2026-10-05 的三条（v32）：急停一出手就过半；回弹、弹簧冲过头再回来；三条在 t = 1 都正好是 1（到下一帧不跳）。
    let fine = (0...10_000).map { Double($0) / 10_000 }
    check(KeyframeEasing.snap.apply(0.1) > 0.5, "急停：走了一成时间已经过半")
    let backPeak = fine.map { KeyframeEasing.overshoot.apply($0) }.max() ?? 0
    let springPeak = fine.map { KeyframeEasing.spring.apply($0) }.max() ?? 0
    check(backPeak > 1.09 && backPeak <= 1 + KeyframeEasing.maximumOvershoot, "回弹冲过头约 10%（不超 maximumOvershoot）：\(backPeak)")
    check(springPeak > 1.2 && springPeak <= 1 + KeyframeEasing.maximumOvershoot, "弹簧冲过头约 21%（不超 maximumOvershoot）：\(springPeak)")
    check([KeyframeEasing.snap, .overshoot, .spring].allSatisfy { $0.apply(1) == 1 && abs($0.apply(0.9999) - 1) < 1e-3 },
          "三条新曲线在终点正好是 1、贴近终点时也不跳")
    checkEqual(KeyframeEasing.allCases.filter(\.overshoots), [.overshoot, .spring], "只有回弹、弹簧会冲过头")
    checkEqual(KeyframeEasing.allCases.filter(\.isVersion32), [.snap, .overshoot, .spring], "v32 才认识的是新加的三条")

    // ---- 插值 ----
    var linear = KeyframeTrack()
    linear.set(10, atSourceTime: 1, tolerance: tol)
    linear.set(30, atSourceTime: 3, tolerance: tol)
    for t in stride(from: 0.9, through: 3.1, by: 0.037) {
        let old = 10 + (30 - 10) * (t - 1) / 2   // 以前那条式子
        let expected = t <= 1 ? 10 : (t >= 3 ? 30 : old)
        check(linear.value(atSourceTime: t) == expected, "linear 和以前逐位一致（t = \(t)）")
    }
    check(!linear.hasEasing, "都是线性：hasEasing 假")
    var eased = KeyframeTrack()
    eased.set(10, atSourceTime: 1, tolerance: tol, easing: .easeInOut)
    eased.set(30, atSourceTime: 3, tolerance: tol)
    check(eased.hasEasing, "有一段缓动：hasEasing 真")
    checkEqual(eased.value(atSourceTime: 2), 20, "缓入缓出正中间还是中点")
    check(abs((eased.value(atSourceTime: 1.5) ?? 0) - (10 + 20 * 0.0625)) < 1e-12, "四分之一处按曲线（0.0625）")
    check(abs((eased.value(atSourceTime: 2.5) ?? 0) - (10 + 20 * 0.9375)) < 1e-12, "四分之三处按曲线（0.9375）")
    checkEqual(eased.value(atSourceTime: 0), 10, "首帧之前夹紧")
    checkEqual(eased.value(atSourceTime: 9), 30, "末帧之后夹紧")
    checkEqual(eased.easing(atSourceTime: 2), .easeInOut, "播到中间：处在缓动那一段")
    checkEqual(eased.easing(atSourceTime: 0.5), .easeInOut, "首帧之前算第一段")
    checkEqual(eased.easing(atSourceTime: 3.5), .easeInOut, "末帧之后算最后一段（不是末帧自己那个没用的）")
    check(KeyframeTrack().easing(atSourceTime: 1) == nil, "空轨 nil")
    var single = KeyframeTrack()
    single.set(1, atSourceTime: 1, tolerance: tol, easing: .easeIn)
    check(single.easing(atSourceTime: 1) == nil && single.segmentIndex(atSourceTime: 1) == nil, "只有一帧没有「段」")

    // ---- set 的规矩 ----
    eased.set(11, atSourceTime: 1.001, tolerance: tol)
    checkEqual(eased.keys.first?.easing, .easeInOut, "半帧内改值，曲线留着")
    checkEqual(eased.keys.first?.value, 11, "值改了")
    eased.set(12, atSourceTime: 1, tolerance: tol, easing: .easeOut)
    checkEqual(eased.keys.first?.easing, .easeOut, "给了 easing 才换")
    eased.set(20, atSourceTime: 2, tolerance: tol)
    checkEqual(eased.keys[1].easing, .linear, "新帧默认线性")
    eased.setEasing(.easeIn, atSourceTime: 2, tolerance: tol)
    checkEqual(eased.keys[1].easing, .easeIn, "setEasing 只换曲线")
    eased.setEasing(.easeIn, atSourceTime: 7, tolerance: tol)
    checkEqual(eased.keys.count, 3, "setEasing 在没有帧的地方不加帧")
    // 检查器的菜单按「段」改：播放头在哪一段就改那一段的起点那帧
    eased.setEasing(.easeOut, forSegmentAtSourceTime: 2.5)
    checkEqual(eased.keys.map(\.easing), [.easeOut, .easeOut, .linear], "播放头在第二段：改第二段（keys[1]）")
    eased.setEasing(.easeInOut, forSegmentAtSourceTime: 9)
    checkEqual(eased.keys.map(\.easing), [.easeOut, .easeInOut, .linear], "末帧之后：改最后一段")
    eased.setEasing(.linear, forSegmentAtSourceTime: -1)
    checkEqual(eased.keys.map(\.easing), [.linear, .easeInOut, .linear], "首帧之前：改第一段")
    single.setEasing(.linear, forSegmentAtSourceTime: 1)
    checkEqual(single.keys.first?.easing, .easeIn, "只有一帧：不动")

    // ---- clipped / stretched 带着曲线走 ----
    var shape = KeyframeTrack()
    shape.set(0, atSourceTime: 0, tolerance: tol, easing: .easeInOut)
    shape.set(100, atSourceTime: 4, tolerance: tol, easing: .easeIn)
    shape.set(50, atSourceTime: 8, tolerance: tol)
    let clipped = shape.clipped(from: 2, to: 6, tolerance: tol)
    checkEqual(clipped.keys.map(\.time), [2, 4, 6], "裁到 2–6：两头补帧")
    checkEqual(clipped.keys.map(\.easing), [.easeInOut, .easeIn, .linear], "补出来的头帧接着用被切开那段的曲线，中间的帧原样")
    check(abs((clipped.keys.first?.value ?? -1) - 50) < 1e-12, "头帧的值 = 那一刻的插值（缓入缓出正中间 = 50）")
    let stretched = shape.stretched(from: 0...8, to: 10...14)
    checkEqual(stretched.keys.map(\.easing), [.easeInOut, .easeIn, .linear], "stretched 保曲线")
    checkEqual(stretched.keys.map(\.time), [10, 12, 14], "stretched 等比挪时刻")
    checkEqual(shape.stretched(from: 3...3, to: 5...6).keys.map(\.easing), [.easeInOut, .easeIn, .linear], "旧范围为零那条路也保曲线")
    // 预渲染的 matte 换到白块素材的源轴上（2026-10-05：重建时漏了曲线，matte 按直线走、画面按曲线走，成片边缘错开）。
    var moving = ClipAnimation()
    moving.centerX = shape
    moving.opacity = shape
    let remapped = moving.remapped { $0 / 8 }
    checkEqual(remapped.centerX.keys.map(\.easing), [.easeInOut, .easeIn, .linear], "remapped 换轴保曲线（matte 和画面同一条曲线）")
    checkEqual(remapped.opacity.keys.map(\.easing), [.easeInOut, .easeIn, .linear], "remapped 每条轨都保曲线")
    checkEqual(remapped.centerX.keys.map(\.time), [0, 0.5, 1], "remapped 按给的换算挪时刻")
    checkEqual(remapped.centerX.keys.map(\.value), [0, 100, 50], "remapped 值原样")
    // 取四分之一处：缓入缓出在正中间和直线一样是 50，量不出曲线丢没丢（这一条第一版取了 2 秒，反向验证时照样绿）。
    check(abs((remapped.centerX.value(atSourceTime: 0.125) ?? -1) - (shape.value(atSourceTime: 1) ?? -2)) < 1e-12,
          "remapped 之后同一个时间线时刻取到同一个值（缓入缓出四分之一处 6.25，丢了曲线是 25）")

    // ---- 存盘 ----
    let encoder = JSONEncoder()
    let plainJSON = String(decoding: try encoder.encode(Keyframe(time: 1, value: 2)), as: UTF8.self)
    check(!plainJSON.contains("easing"), "线性不落键：\(plainJSON)")
    let easedJSON = String(decoding: try encoder.encode(Keyframe(time: 1, value: 2, easing: .easeOut)), as: UTF8.self)
    check(easedJSON.contains("\"easing\":\"easeOut\""), "有曲线才写：\(easedJSON)")
    let decoder = JSONDecoder()
    checkEqual(try decoder.decode(Keyframe.self, from: Data(#"{"time":1,"value":2}"#.utf8)).easing, .linear, "老文件没有 easing = linear")
    checkEqual(try decoder.decode(Keyframe.self, from: Data(#"{"time":1,"value":2,"easing":"bouncy"}"#.utf8)).easing, .linear, "不认识的值回落 linear")
    checkEqual(try decoder.decode(KeyframeTrack.self, from: try encoder.encode(shape)), shape, "整条轨往返不变（含曲线）")

    var clip = EditClip(sourceURL: URL(fileURLWithPath: "/m/eased.mp4"), sourceDuration: 8, timelineStart: 0)
    var animation = ClipAnimation()
    animation.width = shape
    clip.animation = animation
    var state = TimelineState()
    state.mainClips = [clip]
    check(state.requiresFormatVersion27, "有缓动 → v27 判据为真")
    check(state.allClips.contains { $0.animation?.hasEasing == true }, "ClipAnimation.hasEasing 看六条轨")
    var plain = state
    plain.mainClips[0].animation?.width = linear
    check(!plain.requiresFormatVersion27, "都是线性：不是 v27 数据（按需）")
    checkEqual(VideoEditProjectFile.latestFormatVersion, 32, "reader 认到 v32")
    check(!state.requiresFormatVersion32, "只用了缓入缓出这些（v27 的）：不是 v32 数据")
    var bouncy = state
    bouncy.mainClips[0].animation?.width.setEasing(.spring, atSourceTime: 4, tolerance: tol)
    check(bouncy.requiresFormatVersion32 && bouncy.requiresFormatVersion27, "用了弹簧 → v32 判据为真（v27 的也真）")
    let springJSON = String(decoding: try encoder.encode(Keyframe(time: 1, value: 2, easing: .spring)), as: UTF8.self)
    check(springJSON.contains("\"easing\":\"spring\""), "新曲线照样按名字写：\(springJSON)")
    checkEqual(try decoder.decode(Keyframe.self, from: Data(#"{"time":1,"value":2,"easing":"snap"}"#.utf8)).easing, .snap, "急停读得回来")

    // ---- 冲过头：宽高留下限、最低不透明度放宽 ----
    var shrink = KeyframeTrack()
    shrink.set(1.0, atSourceTime: 0, tolerance: tol, easing: .spring)
    shrink.set(0.01, atSourceTime: 1, tolerance: tol)
    let rawLowest = fine.compactMap { shrink.value(atSourceTime: $0) }.min() ?? 1
    check(rawLowest < 0, "弹簧从 1 缩到 0.01 不夹的话会冲成负的（这才需要下限）：\(rawLowest)")
    var shrinking = EditClip(sourceURL: URL(fileURLWithPath: "/m/shrink.mp4"), sourceDuration: 1, timelineStart: 0)
    var shrinkAnimation = ClipAnimation()
    shrinkAnimation.width = shrink
    shrinkAnimation.height = shrink
    shrinking.animation = shrinkAnimation
    let canvas = CGSize(width: 1920, height: 1080)
    let placedSizes = fine.map { shrinking.animatedPlacement(atTimeline: $0, canvas: canvas) }
    check(placedSizes.allSatisfy { $0.width >= ClipAnimation.minimumAnimatedSize && $0.height >= ClipAnimation.minimumAnimatedSize },
          "摆放的宽高夹在下限以上（不会整个消失或翻过来）")
    checkEqual(shrinking.animatedPlacement(atTimeline: 1, canvas: canvas).width, 0.01, "到了下一帧还是原值（下限只管冲过头的那一下）")
    var fading = shrinking
    var fade = ClipAnimation()
    fade.opacity.set(1, atSourceTime: 0, tolerance: tol, easing: .spring)
    fade.opacity.set(0.5, atSourceTime: 1, tolerance: tol)
    fading.animation = fade
    let realLowest = fine.compactMap { fade.opacity.value(atSourceTime: $0) }.min() ?? 1
    check(fading.minimumOpacity <= realLowest && realLowest < 0.5, "最低不透明度算上冲过头的那一下（实际 \(realLowest)、算的 \(fading.minimumOpacity)）")
    fade.opacity.setEasing(.easeInOut, atSourceTime: 0, tolerance: tol)
    fading.animation = fade
    checkEqual(fading.minimumOpacity, 0.5, "不冲过头的曲线：还是最小的那一帧，和以前一样")

    let file = root.appendingPathComponent("eased.srtflowproj")
    try VideoEditProjectIO.save(state, to: file)
    let back = try VideoEditProjectIO.load(from: file).timeline
    checkEqual(back.mainClips.first?.animation?.width, shape, "工程文件往返：曲线不丢")
    let text = try String(contentsOf: file, encoding: .utf8)
    checkEqual(text.components(separatedBy: "\"easing\"").count - 1, 2, "文件里只有两个 easing 键（线性那一帧不写）")

    // ---- 切片 ----
    var slow = EditClip(sourceURL: URL(fileURLWithPath: "/m/slow.mp4"), sourceDuration: 4, timelineStart: 10)
    var push = ClipAnimation()
    push.width.set(0.5, atSourceTime: 0, tolerance: tol, easing: .easeInOut)
    push.width.set(0.6, atSourceTime: 4, tolerance: tol)
    slow.animation = push
    let easedTimes = KeyframeSliceTimes.times(animation: push, clip: slow, frameRate: .fps30, fadeWindows: [])
    checkEqual(easedTimes.count, 2 + 119, "缓动 4 秒 × 30 fps：两个关键帧 + 119 个帧边界")
    var onFrames = true
    for (index, t) in easedTimes.dropFirst(2).enumerated() {
        let expected = 10 + Double(index + 1) / 30
        if abs(t - expected) > 1e-9 { onFrames = false }
    }
    check(onFrames, "帧边界正好落在每一帧上（时间线秒）")
    var linearPush = push
    linearPush.width = KeyframeTrack(keys: push.width.keys.map { Keyframe(time: $0.time, value: $0.value) })
    slow.animation = linearPush
    checkEqual(KeyframeSliceTimes.times(animation: linearPush, clip: slow, frameRate: .fps30, fadeWindows: []).count, 2, "线性段一片不多：只有两个关键帧")
    var spin = ClipAnimation()
    spin.rotation.set(0, atSourceTime: 0, tolerance: tol)
    spin.rotation.set(90, atSourceTime: 4, tolerance: tol)
    checkEqual(KeyframeSliceTimes.times(animation: spin, clip: slow, frameRate: .fps30, fadeWindows: []).count, 2 + 14, "旋转 90° 照旧 ≤ 6°/片：15 片")
    spin.rotation.set(0, atSourceTime: 0, tolerance: tol, easing: .easeOut)
    checkEqual(KeyframeSliceTimes.times(animation: spin, clip: slow, frameRate: .fps30, fadeWindows: []).count, 2 + 119, "旋转带缓动：按帧（比 6°/片 更密）")
    var springPush = push
    springPush.width.setEasing(.spring, atSourceTime: 0, tolerance: tol)
    slow.animation = springPush
    checkEqual(KeyframeSliceTimes.times(animation: springPush, clip: slow, frameRate: .fps30, fadeWindows: []).count, 2 + 119,
               "弹簧也按帧加密（每片两端落在曲线上，冲过头的那一下逐帧都在）")
    slow.animation = linearPush
    var fast = slow
    fast.speed = 2   // 源 4 秒在时间线上只有 2 秒 → 60 帧
    checkEqual(KeyframeSliceTimes.times(animation: push, clip: fast, frameRate: .fps30, fadeWindows: []).count, 2 + 59, "变速：按时间线上的帧数加密")
    var long = slow
    long.sourceDuration = 40
    var longPush = ClipAnimation()
    longPush.width.set(0.5, atSourceTime: 0, tolerance: tol, easing: .easeInOut)
    longPush.width.set(0.6, atSourceTime: 40, tolerance: tol)
    checkEqual(KeyframeSliceTimes.times(animation: longPush, clip: long, frameRate: .fps30, fadeWindows: []).count, 2 + 399, "一段最多 400 片")
}
