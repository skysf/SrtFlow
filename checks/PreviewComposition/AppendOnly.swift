import AVFoundation
import CoreGraphics
import Foundation

// 往合成轨上接素材：只从真正的末尾接、合成完每条轨裁到时间线总长
// （Sources/SrtFlow/CompositionTime.swift，docs/bugfixes/2026-09-27-preview-black-after-audio-tick-pushed-past-end.md）。
//
// 2026-09-27 的现场是一条音效轨：一段从 5.3 秒起、长 1.4 秒（5.3 + 1.4 在浮点里是 6.699999999999999，截断落在
// 第 4019 格），空一截，最后一段正好收在画面结尾。修之前：空白从 4019 插进去，切下前一段的最后一格、挤到全片最后，
// 合成比画面长 1/600 秒，视频合成的指令铺不满 → 判无效 → 预览整个黑屏。
// 2026-10-01 PR3b 起合成里没有音轨了（声音在音频引擎里），同一条规矩照样管着画面轨：这里用上层视频轨上同样的
// 两段复现（`insert` 对画面和当年对声音是同一个函数）。
//
// 另一件事（同一个 PR3b）：配乐比画面长时合成里没有音轨撑长度，builder 要在画面结尾到总长之间垫黑底 —— 不然播放器的
// 条目比时间线短，播到画面结尾停在最后一帧上，引擎的播放头还在走、时钟每拍都去对表。

func checkAppendOnly(root: URL) async throws {
    let picture = try await makeSolidVideo(white: 1, seconds: 7, name: "append-picture.mp4")
    let whoosh = try await makeSolidVideo(white: 0.5, seconds: 2, name: "append-whoosh.mp4")
    let hit = try await makeSolidVideo(white: 0.5, seconds: 1, name: "append-hit.mp4")
    let info = MediaInfo(
        duration: 7, displaySize: CGSize(width: 64, height: 36), frameRate: 10,
        videoCodec: "h264", audioCodec: nil, hasAudio: false, audioCanCopyToMP4: false, fileBytes: 1
    )
    var state = TimelineState()
    state.mainClips = [EditClip(sourceURL: picture, sourceDuration: 7, timelineStart: 0, info: info)]
    state.overlayTracks = [EditLane(clips: [
        EditClip(sourceURL: whoosh, sourceDuration: 1.4, timelineStart: 5.3, info: info),
        EditClip(sourceURL: hit, sourceDuration: 0.2, timelineStart: 6.8, info: info),
    ])]

    guard let built = await VideoEditCompositionBuilder.build(from: state) else {
        check(false, "上层轨场景合成失败")
        return
    }
    let composition = built.composition
    checkEqual(composition.duration, CMTime(value: 4200, timescale: 600),
               "合成正好和画面一样长（修之前多出一格：4201/600）")
    if let video = built.videoComposition {
        let valid = try await video.isValid(
            for: composition, timeRange: CMTimeRange(start: .zero, duration: composition.duration), validationDelegate: nil
        )
        check(valid, "视频合成的指令铺满整个合成（无效就是预览黑屏）")
    } else {
        check(false, "有画面的时间线必须带视频合成")
    }
    // 1.4 秒那段必须是一整段、在 5.3–6.7 秒，没被后面的空白切开、挤到别处。
    let whooshSegments = composition.tracks(withMediaType: .video).flatMap(\.segments).filter {
        !$0.isEmpty && $0.sourceURL == whoosh
    }
    checkEqual(whooshSegments.count, 1, "1.4 秒的那段没被切成几截")
    if let segment = whooshSegments.first {
        checkEqual(segment.timeMapping.target, CMTimeRange(start: CMTime(value: 3180, timescale: 600),
                                                           duration: CMTime(value: 840, timescale: 600)),
                   "1.4 秒的那段整段落在 5.3–6.7 秒")
    }
    check(composition.tracks(withMediaType: .audio).isEmpty, "合成里不该有音轨（声音在音频引擎里）")

    // ---- 配乐比画面长：画面结尾到总长垫黑底，合成和时间线一样长，尾巴是黑的 ----
    let music = try makeToneWAV(seconds: 4, name: "append-music.wav")
    var longer = TimelineState()
    longer.mainClips = [EditClip(sourceURL: picture, sourceDuration: 2, timelineStart: 0, info: info)]
    longer.audioTracks = [EditLane(clips: [
        EditClip(sourceURL: music, isAudioOnly: true, sourceDuration: 3.5, timelineStart: 0, audioAssetDuration: 4)
    ])]
    checkClose(longer.duration, 3.5, 0.0001, "配乐决定总长 3.5 秒")
    if let built = await VideoEditCompositionBuilder.build(from: longer) {
        checkEqual(built.composition.duration, CMTime(value: 2100, timescale: 600), "合成铺到时间线总长（画面只到 2 秒）")
        check(built.composition.tracks(withMediaType: .audio).isEmpty, "撑长度的不是音轨")
        await checkInstructionsCover(built, totalDuration: longer.duration, label: "配乐比画面长")
        let inside = await averageBrightness(built, at: 1.0)
        check(inside > 0.9, "画面段里照常是白的，实测 \(inside)")
        let tail = await averageBrightness(built, at: 3.0)
        check(tail < 0.05, "画面结尾之后到总长是黑的（垫的黑底），实测 \(tail)")
        // 画面铺满总长的工程一层都不多：上面那条 7 秒的时间线只有主轨 A（B 空着被清掉）+ 上层轨，没有黑底。
        checkEqual(composition.tracks(withMediaType: .video).count, 2, "画面铺满时不垫黑底（主轨 A + 上层轨 = 2 条）")
    } else {
        check(false, "配乐比画面长的场景合成失败")
    }

    // 纯音频时间线：没有画面也要有一条铺到总长的（黑）画面轨，播放器的条目才和时间线一样长。
    var audioOnly = TimelineState()
    audioOnly.audioTracks = [EditLane(clips: [
        EditClip(sourceURL: music, isAudioOnly: true, sourceDuration: 3, timelineStart: 0.5, audioAssetDuration: 4)
    ])]
    if let built = await VideoEditCompositionBuilder.build(from: audioOnly) {
        checkEqual(built.composition.duration, CMTime(value: 2100, timescale: 600), "纯音频时间线的合成也铺到总长 3.5 秒")
        check(built.videoComposition != nil, "纯音频时间线带着（黑底的）视频合成")
    } else {
        check(false, "纯音频时间线合成失败")
    }
}
