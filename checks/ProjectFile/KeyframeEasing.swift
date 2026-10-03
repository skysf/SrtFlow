import Foundation

// MARK: - 39. 关键帧的缓动（VideoEditKeyframeEasing.swift、Keyframe.easing）
//
// 插值：每种曲线在 t = 0 / 0.25 / 0.5 / 0.75 / 1 的值、两端夹紧、linear 和以前那条式子逐位一致；
// set 的规矩（已有的帧只改值曲线留着、给了才换；新帧默认线性）；clipped / stretched 带着曲线走；
// 存盘：linear 不落键、往返不变、老文件读出来是 linear、不认识的值回落 linear、只有真有曲线才抬 v27；
// 切片：带缓动的段按帧加密、线性段一片不多、旋转照旧 ≤ 6°/片（KeyframeSliceTimes）。
// 方案：docs/plans/2026-09-30-export-limiter-and-easing.md；长期约束：docs/architecture/keyframe-animation.md「缓动」。

func checkKeyframeEasing(root: URL) throws {
    let tol = KeyframeTrack.sourceTolerance(frameRate: .fps30, speed: 1)

    // ---- 曲线本身 ----
    checkEqual(KeyframeEasing.allCases.map(\.rawValue), ["linear", "easeIn", "easeOut", "easeInOut"], "四种曲线的名字（AI 词表对账用）")
    let samples: [(KeyframeEasing, [Double])] = [
        (.linear, [0, 0.25, 0.5, 0.75, 1]),
        (.easeIn, [0, 0.015625, 0.125, 0.421875, 1]),
        (.easeOut, [0, 0.578125, 0.875, 0.984375, 1]),
        (.easeInOut, [0, 0.0625, 0.5, 0.9375, 1]),
    ]
    for (easing, expected) in samples {
        let got = [0, 0.25, 0.5, 0.75, 1].map { easing.apply($0) }
        check(zip(got, expected).allSatisfy { abs($0 - $1) < 1e-12 }, "\(easing.rawValue) 在 0 / ¼ / ½ / ¾ / 1 的值：\(got)")
    }
    check(KeyframeEasing.easeInOut.apply(0.5) == 0.5 && KeyframeEasing.easeIn.apply(0.999) < 1 && KeyframeEasing.easeOut.apply(0.001) > 0,
          "缓入缓出正中间正好一半、缓入到最后才追上、缓出一起步就领先")

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
    checkEqual(VideoEditProjectFile.latestFormatVersion, 31, "reader 认到 v31")

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
