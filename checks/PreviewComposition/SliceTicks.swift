import AVFoundation
import CoreGraphics
import Foundation

// 视频合成的切片表按格子铺、首尾相接（Sources/SrtFlow/CompositionSlices.swift，
// docs/bugfixes/2026-09-29-preview-black-slice-boundaries-straddle-a-tick.md）。
//
// 复现用户婚礼工程里的两处零头：① 前一段变速 0.94 之后收在 19.9598 秒，AI 按报出来的三位小数把下一段放在
// 19.96 —— 两个边界差 0.2 毫秒，各自截断落在第 11975 / 11976 格；② 最后一段画面收在 32.2097、配乐收在
// 32.21，差 0.3 毫秒，落在第 19325 / 19326 格。修之前「差不到 0.5 毫秒的片不切」，指令表在这两处各空出一格，
// 视频合成判无效 → 整个预览黑屏；去掉关键帧、去掉转场都一样黑。这里把时间线缩到几秒，零头照旧：
// 0.98 + 1.861 / 0.94 = 2.9598（第 1775 格）对 2.96（第 1776 格）。
//
// 第二条：指令表接上之后，A/B 两条合成轨之间在第 1775 格还空着（前一段收在 1775、后一段从 1776 起）。
// 工程是 24 fps 时第 1775 格（71 × 25）正好是一帧的时刻（用户的工程：第 11975 格 = 第 479 帧）—— 接缝上一帧黑，
// 而成片的分节早就不给 0.01 秒以内的缝补黑场。预览把后一段接在前一段真正的末尾上（`TimelineState.mainGapTolerance`，
// 两条管线同一个数）。取帧要容差为零、时刻要落在帧的格子上：别的时刻合成器会渲邻近那一帧，看不出洞。
// 还要在后一段之后**再接一段**：主轨 A/B 交替，第三段让前一段那条轨在洞的位置上是空段（用户的工程就是这样）；
// 只有两段时那条轨到头了，AVFoundation 会保持它的最后一帧，洞照样看不见。

func checkSliceTicks(root: URL) async throws {
    // 纯值：边界各自落格，相邻两格之间一片，起点和总长两格一定在。
    let slices = CompositionSlices.make(boundaries: [0, 19.9598, 19.96, 32.2097, 32.21], totalDuration: 32.21)
    checkEqual(slices.map { $0.range.start.value }, [0, 11975, 11976, 19325], "每一格只留一个边界、按格子排")
    checkEqual(slices.map { $0.range.end.value }, [11975, 11976, 19325, 19326], "相邻两格之间一片、最后一片收在总长那一格")
    checkEqual(slices.map(\.start), [0, 19.9598, 19.96, 32.2097], "求值用的是边界本身的秒，不是格子换回来的")
    checkEqual(slices.last?.end, 32.21, "最后一片求值到总长")
    let same = CompositionSlices.make(boundaries: [0, 1.0001, 1.0009, 2], totalDuration: 2)
    checkEqual(same.map(\.start), [0, 1.0001], "同一格里只留最早的边界")
    let beyond = CompositionSlices.make(boundaries: [0, 1, 5], totalDuration: 2)
    checkEqual(beyond.map { $0.range.end.value }, [600, 1200], "总长之外的边界不要，最后一片照样收在总长")

    // 真合成 ①：变速段收在 2.9598，下一段从 2.96 起。
    let white = try await makeSolidVideo(white: 1, seconds: 4, name: "ticks-white.mp4")
    let gray = try await makeSolidVideo(white: 0.5, seconds: 4, name: "ticks-gray.mp4")
    let music = try makeToneWAV(seconds: 4, name: "ticks-music.wav")
    let info = MediaInfo(
        duration: 4, displaySize: CGSize(width: 64, height: 36), frameRate: 10,
        videoCodec: "h264", audioCodec: nil, hasAudio: false, audioCanCopyToMP4: false, fileBytes: 1
    )
    var first = EditClip(sourceURL: white, sourceDuration: 1.861, timelineStart: 0.98, info: info)
    first.speed = 0.94
    // 一道渐变让合成器垫黑底轨：用户的工程都有（转场、渐变、入出场动画随便哪样）。没有它，洞那一格上一个源都
    // 没有，取帧器会退回邻近的帧，洞看不见；有了它，洞那一格渲出来就是黑底。
    first.videoFadeInDuration = 0.2
    checkClose(first.timelineEnd, 2.9598, 0.0001, "变速段收在 2.9598（第 1775 格）")
    var seam = TimelineState()
    seam.frameRate = .fps24
    seam.mainClips = [
        first,
        EditClip(sourceURL: gray, sourceDuration: 1, timelineStart: 2.96, info: info),
        EditClip(sourceURL: white, sourceDuration: 1, timelineStart: 3.96, info: info)
    ]
    if let built = await VideoEditCompositionBuilder.build(from: seam) {
        await checkInstructionsCover(built, totalDuration: seam.duration, label: "接缝差 0.2 毫秒、跨了一格")
        let before = await averageBrightness(built, at: 2.0)
        check(before > 0.9, "接缝前是白的那段，实测 \(before)")
        let after = await averageBrightness(built, at: 3.5)
        check(abs(after - 0.5) < 0.1, "接缝后是灰的那段，实测 \(after)")
        let seamFrame = await exactBrightness(built, atTick: 1775)
        check(abs(seamFrame - 0.5) < 0.1, "接缝空出的那一格（第 1775 格）不许黑：后一段（灰）要接在前一段真正的末尾上，实测 \(seamFrame)")
    } else {
        check(false, "接缝差一格的场景合成失败")
    }

    // 真合成 ②：只有一段画面收在 2.9598，配乐收在 2.96 —— 总长那一格比最后一个画面边界晚一格。
    var tail = TimelineState()
    tail.mainClips = [first]
    tail.audioTracks = [EditLane(clips: [
        EditClip(sourceURL: music, isAudioOnly: true, sourceDuration: 2.96, timelineStart: 0, audioAssetDuration: 4)
    ])]
    checkClose(tail.duration, 2.96, 0.0001, "配乐决定总长 2.96（第 1776 格）")
    if let built = await VideoEditCompositionBuilder.build(from: tail) {
        checkEqual(built.composition.duration, CMTime(value: 1776, timescale: 600), "合成铺到配乐那一格（声音不在合成里，靠黑底撑）")
        await checkInstructionsCover(built, totalDuration: tail.duration, label: "画面比配乐早收 0.3 毫秒")
        let mid = await averageBrightness(built, at: 2.0)
        check(mid > 0.9, "画面照常，实测 \(mid)")
    } else {
        check(false, "画面比配乐早收一格的场景合成失败")
    }
}

/// 指令表首尾相接、从 0 铺到时间线总长那一格（合成本身可以短一格：接缝的零头接在前一段末尾上），
/// 且视频合成有效（无效就是预览黑屏）。
func checkInstructionsCover(_ built: VideoEditCompositionBuilder.Built, totalDuration: Double, label: String) async {
    guard let video = built.videoComposition else {
        check(false, "\(label)：有画面的时间线必须带视频合成")
        return
    }
    var cursor: CMTime = .zero
    var contiguous = true
    for instruction in video.instructions {
        if instruction.timeRange.start != cursor || instruction.timeRange.duration <= .zero { contiguous = false }
        cursor = instruction.timeRange.end
    }
    check(contiguous, "\(label)：指令表要首尾相接、每一片都有长度")
    checkEqual(cursor, CompositionTime.tick(totalDuration), "\(label)：最后一片收在时间线总长那一格上")
    check(cursor >= built.composition.duration, "\(label)：指令表不许比合成短（短了就是空出一格）")
    let valid = (try? await video.isValid(
        for: built.composition,
        timeRange: CMTimeRange(start: .zero, duration: built.composition.duration),
        validationDelegate: nil
    )) ?? false
    check(valid, "\(label)：视频合成必须有效（无效 = 预览整个黑屏）")
}
