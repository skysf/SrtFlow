import AVFoundation
import CoreGraphics
import Foundation

// 往合成轨上接素材：只从真正的末尾接、合成完每条轨裁到时间线总长
// （Sources/SrtFlow/CompositionTime.swift，docs/bugfixes/2026-09-27-preview-black-after-audio-tick-pushed-past-end.md）。
//
// 复现用户南极工程里的那条音效轨：一段从 5.3 秒起、长 1.4 秒（5.3 + 1.4 在浮点里是 6.699999999999999），
// 空一截，最后一段正好收在画面结尾。修之前：空白从第 4019 格插进去，切下前一段的最后一格、挤到全片最后，
// 合成比画面长 1/600 秒，视频合成的指令铺不满 → 判无效 → 预览整个黑屏。

func checkAppendOnly(root: URL) async throws {
    // 换算四舍五入到格子：CMTime(seconds:preferredTimescale:) 向零截断，6.699999999999999 会落在 4019。
    checkEqual(CompositionTime.ticks(5.3 + 1.4).value, 4020, "5.3 + 1.4（6.699999999999999）落在第 4020 格")
    checkEqual(CompositionTime.ticks(5.3).value, 3180, "5.3 落在第 3180 格")

    let picture = try await makeSolidVideo(white: 1, seconds: 7, name: "append-picture.mp4")
    let whoosh = try makeToneWAV(seconds: 1.4, name: "append-whoosh.wav")
    let hit = try makeToneWAV(seconds: 1, name: "append-hit.wav")
    let info = MediaInfo(
        duration: 7, displaySize: CGSize(width: 64, height: 36), frameRate: 10,
        videoCodec: "h264", audioCodec: nil, hasAudio: false, audioCanCopyToMP4: false, fileBytes: 1
    )
    var state = TimelineState()
    state.mainClips = [EditClip(sourceURL: picture, sourceDuration: 7, timelineStart: 0, info: info)]
    state.audioTracks = [EditLane(clips: [
        EditClip(sourceURL: whoosh, isAudioOnly: true, sourceDuration: 1.4, timelineStart: 5.3, audioAssetDuration: 1.4),
        EditClip(sourceURL: hit, isAudioOnly: true, sourceDuration: 0.2, timelineStart: 6.8, audioAssetDuration: 1),
    ])]

    guard let built = await VideoEditCompositionBuilder.build(from: state) else {
        check(false, "音效轨场景合成失败")
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
    // 1.4 秒那段音效必须是一整段、在 5.3–6.7 秒，没被后面的空白切开、挤到别处。
    let whooshSegments = composition.tracks(withMediaType: .audio).flatMap(\.segments).filter {
        !$0.isEmpty && $0.sourceURL == whoosh
    }
    checkEqual(whooshSegments.count, 1, "1.4 秒的音效没被切成几截")
    if let segment = whooshSegments.first {
        checkEqual(segment.timeMapping.target, CMTimeRange(start: CMTime(value: 3180, timescale: 600),
                                                           duration: CMTime(value: 840, timescale: 600)),
                   "1.4 秒的音效整段落在 5.3–6.7 秒")
    }
}
