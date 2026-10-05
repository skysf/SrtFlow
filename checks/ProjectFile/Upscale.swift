import Foundation

// 第 41 组：片段换成 upscale 文件、换回原片（VideoEditClipUpscale.swift）。
// 换源时入点、关键帧、标记、音量曲线一起平移；新文件盖不住的不换；差一帧以内算盖住；再次 upscale 仍按原片算；
// 换回去逐字段还原；分割把记录抄给右半；工程里用同一个原片的段一起换、分离出来的音频不算；存盘往返、v29 按需登记、
// 原片进素材表配书签但不进 mediaURLs；重链接把原片的记录一起改；账单查到实收按文件补进记录。合同：docs/architecture/video-edit-project-file.md「四之五」。

/// 浮点差一点点不算（这一组自己的小件，别的组用 checkEqual 比整数）。
private func checkClose(_ actual: Double?, _ expected: Double, _ message: String, line: Int = #line) {
    guard let actual, abs(actual - expected) <= 1e-9 else {
        check(false, "\(message)：得到 \(String(describing: actual))，期望 \(expected)", line: line)
        return
    }
    check(true, message, line: line)
}

private func info(duration: Double, width: Double, height: Double) -> MediaInfo {
    MediaInfo(
        duration: duration, displaySize: CGSize(width: width, height: height), frameRate: 24, videoCodec: "avc1", audioCodec: "aac",
        hasAudio: true, audioCanCopyToMP4: true, fileBytes: 1_000, keyframeInterval: nil
    )
}

func checkUpscaleSwap(root: URL) throws {
    let original = root.appendingPathComponent("Shot_原片.mp4")
    let upscaled = root.appendingPathComponent("Shot_原片_1920x1080_topaz-precision.mp4")
    let tol = 1.0 / 24
    // 原片 12 秒 720p；这段用 3.0–6.0；upscale 文件是原片的 2.0–7.0（5 秒）。
    var clip = EditClip(sourceURL: original, sourceStart: 3, sourceDuration: 3, timelineStart: 10, info: info(duration: 12, width: 1280, height: 720))
    clip.remoteKey = "lib-123"
    clip.animation = ClipAnimation(centerX: KeyframeTrack(keys: [Keyframe(time: 3, value: 0.2), Keyframe(time: 6, value: 0.8)]))
    clip.markers = [ClipMarker(sourceTime: 4.5, color: .red, text: "鲸")]
    clip.volumeCurve = KeyframeTrack(keys: [Keyframe(time: 3, value: 0), Keyframe(time: 5, value: -6)])
    let record = ClipUpscaleRecord(originalURL: upscaled, sourceOffset: 2, tier: "topaz-precision", costUSD: 0.1)
    let replacement = ClipSourceSwap.Replacement(url: upscaled, info: info(duration: 5, width: 1920, height: 1080), record: record)

    // ---- 换源：整体平移 ----
    var swapped = clip
    check(ClipSourceSwap.apply(replacement, to: &swapped), "范围被盖住：换")
    checkEqual(swapped.sourceURL, upscaled, "指向 upscale 文件")
    checkClose(swapped.sourceStart, 1, "入点 3.0 → 新文件里的 1.0（新文件从原片 2.0 起）")
    checkClose(swapped.sourceDuration, 3, "用到的长度不变")
    checkClose(swapped.timelineStart, 10, "时间线位置不变")
    checkEqual(swapped.info?.displaySize.width, 1920, "探测信息换成新文件的")
    checkEqual(swapped.animation?.centerX.keys.map(\.time), [1, 4], "关键帧跟着平移")
    checkEqual(swapped.animation?.centerX.keys.map(\.value), [0.2, 0.8], "关键帧的值不变")
    checkEqual(swapped.markers.map(\.sourceTime), [2.5], "标记跟着平移")
    checkEqual(swapped.volumeCurve.keys.map(\.time), [1, 3], "音量曲线跟着平移")
    check(swapped.remoteKey == nil, "换源之后段上不留音频库的键（不然重链接会按键换回库里的原片）")
    checkEqual(swapped.upscale?.originalURL, original, "记录里的原片是换源前的文件（不是传进来的）")
    checkEqual(swapped.upscale?.originalRemoteKey, "lib-123", "原片的库键记在记录里")
    checkEqual(swapped.upscale?.originalInfo?.displaySize.width, 1280, "原片的探测信息记在记录里")
    checkClose(swapped.upscale?.sourceOffset, 2, "偏移照记")
    checkEqual(swapped.upscale?.tier, "topaz-precision", "档位照记")
    checkClose(swapped.upscale?.costUSD, 0.1, "扣费照记")
    checkClose(ClipSourceSwap.originalStart(of: swapped), 3, "换源之后仍能算回原片的入点")

    // ---- 盖不住的不换 ----
    var outside = clip
    outside.sourceStart = 0.5
    check(!ClipSourceSwap.fits(outside, replacement), "用到的范围在新文件之前：盖不住")
    check(!ClipSourceSwap.apply(replacement, to: &outside), "盖不住就不换")
    checkEqual(outside.sourceURL, original, "没换的段原样不动")
    check(outside.upscale == nil, "没换的段没有记录")
    var tail = clip
    tail.sourceStart = 5
    tail.sourceDuration = 2.5
    check(!ClipSourceSwap.fits(tail, replacement), "用到 7.5，新文件到 7.0：盖不住")
    var oneFrame = clip
    oneFrame.sourceStart = 2 - tol * 0.5
    check(ClipSourceSwap.fits(oneFrame, replacement), "早半帧算盖住（FLUX 会少一帧）")
    check(ClipSourceSwap.apply(replacement, to: &oneFrame), "换")
    checkClose(oneFrame.sourceStart, 0, "入点不许小于 0")
    checkClose(oneFrame.sourceDuration, 3, "长度照旧，零头由合成 / 导出夹")
    var audio = clip
    audio.isAudioOnly = true
    check(!ClipSourceSwap.fits(audio, replacement), "分离出来的音频不换源")
    var still = clip
    still.stillImageURL = root.appendingPathComponent("a.png")
    check(!ClipSourceSwap.fits(still, replacement), "图片段不换源")

    // ---- 再次 upscale：仍按原片算 ----
    let again = root.appendingPathComponent("Shot_原片_1920x1080_bytedance-standard.mp4")
    let secondRecord = ClipUpscaleRecord(originalURL: again, sourceOffset: 0, tier: "bytedance-standard")
    let second = ClipSourceSwap.Replacement(url: again, info: info(duration: 12, width: 1920, height: 1080), record: secondRecord)
    var twice = swapped
    check(ClipSourceSwap.apply(second, to: &twice), "在 upscale 过的段上再换一个整文件的版本")
    checkClose(twice.sourceStart, 3, "整个文件的版本：入点回到原片的 3.0")
    checkEqual(twice.animation?.centerX.keys.map(\.time), [3, 6], "关键帧跟着回到原片的时间")
    checkEqual(twice.upscale?.originalURL, original, "原片仍是第一次的原片")
    checkEqual(twice.upscale?.originalRemoteKey, "lib-123", "原片的库键仍在")
    checkEqual(twice.upscale?.tier, "bytedance-standard", "档位是这一次的")

    // ---- 换回原片：逐字段还原 ----
    var back = swapped
    check(ClipSourceSwap.revert(&back), "换回去")
    checkEqual(back, clip, "换回去之后和换源前一模一样（入点、关键帧、标记、曲线、探测信息、库键）")
    var twiceBack = twice
    check(ClipSourceSwap.revert(&twiceBack), "换过两次也一步换回原片")
    checkEqual(twiceBack, clip, "两次之后换回去也一模一样")
    var never = clip
    check(!ClipSourceSwap.revert(&never), "没换过的没得换回")

    // ---- 分割：记录抄给右半 ----
    var state = TimelineState()
    state.mainClips = [swapped]
    state.split(clipID: swapped.id, at: 11.5)
    checkEqual(state.mainClips.count, 2, "切成两半")
    checkEqual(state.mainClips[1].upscale, swapped.upscale, "右半带着 upscale 的记录")
    var rightBack = state.mainClips[1]
    check(ClipSourceSwap.revert(&rightBack), "右半能换回原片")
    checkClose(rightBack.sourceStart, 4.5, "右半换回去的入点 = 原片的 4.5")
    checkEqual(rightBack.sourceURL, original, "右半换回原片")

    // ---- 工程里用同一个原片的段一起换；分离出来的音频不算 ----
    var project = TimelineState()
    let a = EditClip(sourceURL: original, sourceStart: 3, sourceDuration: 3, timelineStart: 0, info: info(duration: 12, width: 1280, height: 720))
    let b = EditClip(sourceURL: original, sourceStart: 2, sourceDuration: 4, timelineStart: 20, info: info(duration: 12, width: 1280, height: 720))
    let far = EditClip(sourceURL: original, sourceStart: 8, sourceDuration: 2, timelineStart: 40, info: info(duration: 12, width: 1280, height: 720))
    let other = EditClip(sourceURL: root.appendingPathComponent("别的.mp4"), sourceStart: 0, sourceDuration: 2, timelineStart: 50, info: info(duration: 2, width: 1280, height: 720))
    var detached = EditClip(sourceURL: original, sourceStart: 3, sourceDuration: 3, timelineStart: 0)
    detached.isAudioOnly = true
    project.mainClips = [a, b, far, other]
    project.overlayTracks = [EditLane(clips: [swapped])]
    project.audioTracks = [EditLane(clips: [detached])]
    checkEqual(Set(project.clipIDs(usingPicture: original)), Set([a.id, b.id, far.id, swapped.id]), "用这个原片的画面段：直接用的三段 + 已经换成它的 upscale 文件的那段；音频不算")
    let changed = project.applyUpscale(second, to: project.clipIDs(usingPicture: original))
    checkEqual(Set(changed), Set([a.id, b.id, far.id, swapped.id]), "整个文件的版本盖住全部四段")
    check(project.allClips.first { $0.id == detached.id }?.sourceURL == original, "分离出来的音频留在原片上")
    check(project.allClips.first { $0.id == other.id }?.upscale == nil, "别的素材不动")
    var partial = TimelineState()
    partial.mainClips = [a, far]
    checkEqual(partial.applyUpscale(replacement, to: [a.id, far.id]), [a.id], "只做了原片 2.0–7.0 的版本：用到 8–10 的那段盖不住，不换")
    checkEqual(partial.revertUpscale([a.id, far.id]), [a.id], "换回去：只有换过的那段")
    check(partial.mainClips.allSatisfy { $0.upscale == nil && $0.sourceURL == original }, "都回到原片上")

    // ---- 账单几分钟后才查到实收：按文件补进此刻用着它的段的记录（换源早就做完了也补得上）----
    check(project.allClips.filter { $0.sourceURL == second.url }.allSatisfy { $0.upscale?.costUSD == nil }, "刚换源时记录里没有钱（账单还没出）")
    let billed = project.recordUpscaleCost(file: second.url, costUSD: 0.0432)
    checkEqual(Set(billed), Set([a.id, b.id, far.id, swapped.id]), "用着这个 upscale 文件的四段都补上了钱")
    check(project.allClips.filter { $0.sourceURL == second.url }.allSatisfy { $0.upscale?.costUSD == 0.0432 }, "记录里是账单的数")
    check(project.allClips.first { $0.id == other.id }?.upscale == nil, "别的素材不动")
    checkEqual(project.recordUpscaleCost(file: second.url, costUSD: 0.0432), [], "同一个数再记一次什么都不改（applyDocumentRepair 据此不标脏）")
    checkEqual(project.recordUpscaleCost(file: root.appendingPathComponent("没人用.mp4"), costUSD: 1), [], "没人用的文件改不到任何段")

    // ---- 存盘往返、v29 按需登记、原片进素材表 ----
    let file = root.appendingPathComponent("upscale.srtflowproj")
    var save = TimelineState()
    save.mainClips = [clip]
    check(!save.requiresFormatVersion29, "没换过源：不是 v29 数据（按需）")
    try VideoEditProjectIO.save(save, to: file)
    let plainJSON = try String(contentsOf: file, encoding: .utf8)
    check(!plainJSON.contains("\"upscale\""), "没换过源的段不写 upscale 键")
    checkEqual(save.upscaleOriginalURLs, [], "没换过源：没有原片要配书签")
    save.mainClips = [swapped]
    check(save.requiresFormatVersion29, "换过源 → v29 判据为真（旧版打开会把记录抹掉）")
    checkEqual(save.mediaURLs, [upscaled], "mediaURLs 只有此刻播的文件（原片删了不该亮缺素材）")
    checkEqual(save.upscaleOriginalURLs, [original], "原片单独列出来配书签")
    let records = try VideoEditProjectIO.save(save, to: file)
    check(records[original.path] != nil && records[upscaled.path] != nil, "存盘的素材表里原片和 upscale 文件都有记录")
    let json = try String(contentsOf: file, encoding: .utf8)
    check(json.range(of: #""formatVersion"\s*:\s*32"#, options: .regularExpression) != nil, "写出去的是 latest（v32）")
    let loaded = try VideoEditProjectIO.load(from: file).timeline
    checkEqual(loaded.mainClips.first?.upscale?.originalURL, original, "读回来：原片路径在")
    checkClose(loaded.mainClips.first?.upscale?.sourceOffset, 2, "读回来：偏移在")
    checkEqual(loaded.mainClips.first?.upscale?.tier, "topaz-precision", "读回来：档位在")
    checkEqual(loaded.mainClips.first?.upscale?.originalRemoteKey, "lib-123", "读回来：库键在")
    checkEqual(loaded.mainClips.first?.upscale?.originalInfo?.displaySize.height, 720, "读回来：原片的探测信息在")
    checkClose(loaded.mainClips.first?.upscale?.costUSD, 0.1, "读回来：扣费在")
    var reloaded = loaded.mainClips[0]
    check(ClipSourceSwap.revert(&reloaded), "读回来的段能换回原片")
    checkEqual(reloaded.sourceURL, original, "换回原片")
    checkClose(reloaded.sourceStart, 3, "入点回到 3.0")
    // 记录读得宽：只有原片路径是必需的
    let lean = try JSONDecoder().decode(ClipUpscaleRecord.self, from: Data(#"{"originalURL":"file:///tmp/a.mp4"}"#.utf8))
    checkClose(lean.sourceOffset, 0, "缺偏移 = 0")
    checkEqual(lean.tier, "", "缺档位 = 空")
    check((try? JSONDecoder().decode(ClipUpscaleRecord.self, from: Data(#"{"tier":"x"}"#.utf8))) == nil, "没有原片路径的记录不成立")

    // ---- 重链接：原片的记录一起改 ----
    let movedOriginal = root.appendingPathComponent("搬走/Shot_原片.mp4")
    var relinked = save
    relinked.replaceMedia(original, with: movedOriginal)
    checkEqual(relinked.mainClips.first?.upscale?.originalURL, movedOriginal, "原片挪了，记录跟着改")
    checkEqual(relinked.mainClips.first?.sourceURL, upscaled, "段本身仍指向 upscale 文件")
    relinked.replaceMedia(upscaled, with: root.appendingPathComponent("搬走/up.mp4"))
    checkEqual(relinked.mainClips.first?.sourceURL.lastPathComponent, "up.mp4", "upscale 文件挪了，段跟着改")
}
