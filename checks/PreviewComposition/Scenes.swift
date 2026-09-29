import AVFoundation
import CoreGraphics
import Foundation

// 预览合成自检的场景搭建：两段 4 秒的素材接一条缝。从 main.swift 拆出来（那个文件超过 600 行、只许降）。

// MARK: - 场景搭建

/// 两段 4s，任意转场 1s（重叠 3.0–4.0），可对第一段做改动。
func seamState(
    _ url1: URL, _ url2: URL, kind: ClipTransition,
    mutateFirst: (inout EditClip) -> Void = { _ in }
) -> TimelineState {
    let info = MediaInfo(
        duration: 4,
        displaySize: CGSize(width: 64, height: 36),
        frameRate: 10,
        videoCodec: "h264",
        audioCodec: nil,
        hasAudio: false,
        audioCanCopyToMP4: false,
        fileBytes: 1
    )
    var first = EditClip(sourceURL: url1, sourceDuration: 4, timelineStart: 0, info: info)
    first.transitionAfter = kind
    first.transitionDuration = 1
    mutateFirst(&first)
    let second = EditClip(sourceURL: url2, sourceDuration: 4, timelineStart: 3, info: info)
    var state = TimelineState()
    state.mainClips = [first, second]
    return state
}

/// 两段 4s 纯白，叠化 1s（重叠 3.0–4.0），可对第一段做改动。
func whiteDissolveState(_ url1: URL, _ url2: URL, mutateFirst: (inout EditClip) -> Void) -> TimelineState {
    seamState(url1, url2, kind: .crossFade, mutateFirst: mutateFirst)
}
