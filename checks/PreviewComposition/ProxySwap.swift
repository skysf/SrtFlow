import AVFoundation
import Foundation
import SrtFlowCore

// 优化媒体（V2）：builder 按段换源。段跨两块 → 合成里插两段块文件、总长和插原片一样、几个时刻的画面和原片一样；
// 块没齐 → 插原片；「原片」（什么都不传）→ 插原片；变速、上层轨、4K 减半的代理（尺寸按代理自己的算）都一样；
// 块文件被清了 → 退回原片、不黑。另外钉住 OptimizedMediaPlan 的纯值（先转播放头附近的、缺探的源、要转的源）。
// 长期约束 docs/architecture/optimized-media.md；素材用 checks/OptimizedMedia/RampVideo.swift 的渐变灰视频（亮度 = 时间 ÷ 总长）。

// 不标 @MainActor：main.swift 的主线程卡在信号量上等结果，主 actor 上的函数永远轮不到（第一版就这么卡死了 20 分钟）。
func checkProxySwap(root: URL) async throws {
    OptimizedMediaStore.rootOverride = root.appendingPathComponent("proxy-cache", isDirectory: true)
    defer { OptimizedMediaStore.rootOverride = nil }

    func info(duration: Double, size: CGSize, keyframeInterval: Double? = 10) -> MediaInfo {
        MediaInfo(duration: duration, displaySize: size, frameRate: 30, videoCodec: "h264", audioCodec: nil, hasAudio: false,
                  audioCanCopyToMP4: false, fileBytes: 1, keyframeInterval: keyframeInterval)
    }
    func chunks(of url: URL, _ indexes: ClosedRange<Int>) async -> [Int: URL]? {
        guard case .success(let source) = await OptimizedMediaTranscoder.load(url) else { return nil }
        var result: [Int: URL] = [:]
        for chunk in indexes {
            let outcome = await MediaReadQueue.run(on: MediaReadQueue.proxy) { OptimizedMediaTranscoder.transcode(source, chunk: chunk) }
            guard case .success(let file) = outcome else { return nil }
            result[chunk] = file
        }
        return result
    }
    func segmentFiles(_ built: VideoEditCompositionBuilder.Built, track: Int = 0) -> [String] {
        let tracks = built.composition.tracks(withMediaType: .video)
        guard track < tracks.count else { return [] }
        return tracks[track].segments.filter { !$0.isEmpty }.compactMap { $0.sourceURL?.lastPathComponent }
    }
    /// 上层轨那条合成轨的段：主轨 B 空着时会被摘掉，上层轨不一定是第 2 条，按「第 0 条之后第一条有内容的」找。
    func overlaySegmentFiles(_ built: VideoEditCompositionBuilder.Built) -> [String] {
        let tracks = built.composition.tracks(withMediaType: .video).dropFirst()
        guard let overlay = tracks.first(where: { $0.segments.contains { !$0.isEmpty } }) else { return [] }
        return overlay.segments.filter { !$0.isEmpty }.compactMap { $0.sourceURL?.lastPathComponent }
    }
    func sameBrightness(_ a: VideoEditCompositionBuilder.Built, _ b: VideoEditCompositionBuilder.Built, at times: [Double], _ label: String) async {
        for t in times {
            let left = await averageBrightness(a, at: t), right = await averageBrightness(b, at: t)
            check(abs(left - right) < 0.04, "\(label)：\(t)s 处换源 \(left) vs 原片 \(right)")
        }
    }

    let size = CGSize(width: 64, height: 36)
    let source = try await makeRampVideo(seconds: 12, fps: 30, size: size, keyframeEvery: 300, name: "proxy-src.mp4")
    guard let ready = await chunks(of: source, 0...1) else {
        check(false, "两块代理转不出来")
        return
    }
    let lookup = OptimizedMediaLookup(chunks: [source: ready])
    let sourceInfo = info(duration: 12, size: size)

    // 1. 一段跨两块（源 3–12 秒放在时间线 0）：两段块文件首尾相接、总长一样、画面一样。
    var state = TimelineState()
    var clip = EditClip(sourceURL: source, sourceDuration: 9, timelineStart: 0, info: sourceInfo)
    clip.sourceStart = 3
    state.mainClips = [clip]
    guard let proxied = await VideoEditCompositionBuilder.build(from: state, proxies: lookup),
          let plain = await VideoEditCompositionBuilder.build(from: state) else {
        check(false, "跨两块的合成失败")
        return
    }
    checkEqual(segmentFiles(proxied), ["chunk-0.mov", "chunk-1.mov"], "段跨两块 → 合成里按块插两段")
    checkEqual(segmentFiles(plain), ["proxy-src.mp4"], "不传 proxies → 插原片")
    check(proxied.composition.duration == plain.composition.duration,
          "换源不动时间账：总长 \(proxied.composition.duration.seconds) vs \(plain.composition.duration.seconds)")
    check(proxied.composition.tracks(withMediaType: .video).count == plain.composition.tracks(withMediaType: .video).count, "换源的合成和原片同样的层数")
    await sameBrightness(proxied, plain, at: [0.5, 6.95, 7.05, 8.9], "跨两块")

    // 1b. 零头的段（源 3.0007 起、8.9986 长：边界不在格子上）：换源的轨和原片的轨盖住同一段 —— 各片各自截断会少一格、
    //     接缝上露一帧黑（CompositionClipInsert.append 把格子算在边界上，加起来正好）。
    var ragged = TimelineState()
    var raggedClip = EditClip(sourceURL: source, sourceDuration: 8.9986, timelineStart: 0, info: sourceInfo)
    raggedClip.sourceStart = 3.0007
    ragged.mainClips = [raggedClip]
    if let built = await VideoEditCompositionBuilder.build(from: ragged, proxies: lookup), let reference = await VideoEditCompositionBuilder.build(from: ragged) {
        checkEqual(segmentFiles(built), ["chunk-0.mov", "chunk-1.mov"], "零头的段也按块插两段")
        let covered = built.composition.tracks(withMediaType: .video)[0].segments.filter { !$0.isEmpty }.map(\.timeMapping.target)
        let referenceCovered = reference.composition.tracks(withMediaType: .video)[0].segments.filter { !$0.isEmpty }.map(\.timeMapping.target)
        check(covered.first?.start == referenceCovered.first?.start && covered.last?.end == referenceCovered.last?.end,
              "零头的段：换源的轨和原片的轨盖住同一段（\(covered.first?.start.value ?? -1)…\(covered.last?.end.value ?? -1) vs \(referenceCovered.first?.start.value ?? -1)…\(referenceCovered.last?.end.value ?? -1)）")
        check(zip(covered.dropFirst(), covered).allSatisfy { $0.start == $1.end }, "零头的段：两片首尾相接、中间不空一格")
        await sameBrightness(built, reference, at: [0.5, 6.95, 7.05, 8.9], "零头的段")
    } else {
        check(false, "零头的段的合成失败")
    }

    // 2. 块没齐（只有第 0 块、段要 0 和 1）→ 插原片。
    let partial = OptimizedMediaLookup(chunks: [source: [0: ready[0]!]])
    if let built = await VideoEditCompositionBuilder.build(from: state, proxies: partial) {
        checkEqual(segmentFiles(built), ["proxy-src.mp4"], "块没齐 → 插原片")
    } else {
        check(false, "块没齐的合成失败")
    }
    check(lookup.readyChunks(for: clip)?.keys.sorted() == [0, 1] && partial.readyChunks(for: clip) == nil, "readyChunks：齐了给块号、差一块 nil")

    // 3. 只用一块的段（源 10–12）：一段、来自第 1 块。
    var tail = TimelineState()
    var tailClip = EditClip(sourceURL: source, sourceDuration: 2, timelineStart: 0, info: sourceInfo)
    tailClip.sourceStart = 10
    tail.mainClips = [tailClip]
    if let built = await VideoEditCompositionBuilder.build(from: tail, proxies: lookup), let reference = await VideoEditCompositionBuilder.build(from: tail) {
        checkEqual(segmentFiles(built), ["chunk-1.mov"], "只用最后一块的段 → 一段、第 1 块")
        await sameBrightness(built, reference, at: [0.3, 1.7], "最后一块")
    } else {
        check(false, "最后一块的合成失败")
    }

    // 4. 变速 2×（源 3–12 放在 0 → 4.5 秒）。
    var fast = state
    fast.mainClips[0].speed = 2
    if let built = await VideoEditCompositionBuilder.build(from: fast, proxies: lookup), let reference = await VideoEditCompositionBuilder.build(from: fast) {
        check(built.composition.duration == reference.composition.duration, "变速：总长一样 \(built.composition.duration.seconds)")
        await sameBrightness(built, reference, at: [0.5, 3.4, 3.6, 4.3], "变速 2×")
    } else {
        check(false, "变速的合成失败")
    }

    // 5. 上层轨的段（跨两块、摆小了放角上）：画面一样。
    var layered = TimelineState()
    layered.mainClips = [EditClip(sourceURL: source, sourceDuration: 2, timelineStart: 0, info: sourceInfo)]
    var upper = EditClip(sourceURL: source, sourceDuration: 9, timelineStart: 0, info: sourceInfo)
    upper.sourceStart = 3
    upper.placement = ClipPlacement(centerX: 0.25, centerY: 0.25, width: 0.5, height: 0.5)
    layered.overlayTracks = [EditLane(clips: [upper])]
    if let built = await VideoEditCompositionBuilder.build(from: layered, proxies: lookup), let reference = await VideoEditCompositionBuilder.build(from: layered) {
        checkEqual(overlaySegmentFiles(built), ["chunk-0.mov", "chunk-1.mov"], "上层轨的段也按块插")
        await sameBrightness(built, reference, at: [0.5, 6.95, 7.05], "上层轨")
    } else {
        check(false, "上层轨的合成失败")
    }

    // 6. 4K 减半的代理（长边 2600 > 2560 → 1300×100）：尺寸按代理自己的算，画面和原片一样（摆错了会多出黑边、亮度掉下去）。
    let wideSize = CGSize(width: 2600, height: 200)
    let wide = try await makeRampVideo(seconds: 11, fps: 30, size: wideSize, keyframeEvery: 300, name: "proxy-wide.mp4")
    if let wideChunks = await chunks(of: wide, 0...0) {
        let wideLookup = OptimizedMediaLookup(chunks: [wide: wideChunks])
        var wideState = TimelineState()
        var wideClip = EditClip(sourceURL: wide, sourceDuration: 5, timelineStart: 0, info: info(duration: 11, size: wideSize))
        wideClip.sourceStart = 1
        wideState.mainClips = [wideClip]
        if let built = await VideoEditCompositionBuilder.build(from: wideState, proxies: wideLookup),
           let reference = await VideoEditCompositionBuilder.build(from: wideState) {
            checkEqual(segmentFiles(built), ["chunk-0.mov"], "4K 减半的代理插进去了")
            let proxyTrack = try? await AVURLAsset(url: wideChunks[0]!).loadTracks(withMediaType: .video).first
            let natural = (try? await proxyTrack?.load(.naturalSize)) ?? .zero
            check(natural == CGSize(width: 1300, height: 100), "代理减了半：\(natural)")
            check(built.renderSize == reference.renderSize, "画布尺寸照旧按素材信息算：\(built.renderSize)")
            await sameBrightness(built, reference, at: [1.0, 4.0], "4K 减半")
        } else {
            check(false, "4K 减半的合成失败")
        }
    } else {
        check(false, "4K 减半的代理转不出来")
    }

    // 7. 块文件被清了（缓存目录没了）→ 退回原片、画面不黑。
    try? FileManager.default.removeItem(at: ready[1]!)
    if let built = await VideoEditCompositionBuilder.build(from: state, proxies: lookup) {
        checkEqual(segmentFiles(built), ["proxy-src.mp4"], "块文件没了 → 退回原片")
        await sameBrightness(built, plain, at: [0.5, 8.9], "块文件没了")
    } else {
        check(false, "块文件没了的合成失败")
    }

    // 8. OptimizedMediaPlan（纯值）：先转播放头附近的段用到的块、缺探的源、要转的源。
    let long = info(duration: 35, size: size)
    var planState = TimelineState()
    var a = EditClip(sourceURL: source, sourceDuration: 9, timelineStart: 0, info: long)
    a.sourceStart = 3   // 第 0–1 块，余量 → 0–2
    var b = EditClip(sourceURL: source, sourceDuration: 5, timelineStart: 20, info: long)
    b.sourceStart = 25  // 第 2 块，余量 → 1–3
    planState.mainClips = [a, b]
    let jobs = OptimizedMediaPlan.jobs(in: planState, playhead: 22, decodeFPS: 500, ready: [:], excluded: [])
    checkEqual(jobs.map(\.chunk), [1, 2, 3, 0], "播放头在 B 上：先 B 的 1–3 块，再 A 还差的第 0 块")
    let later = OptimizedMediaPlan.jobs(in: planState, playhead: 2, decodeFPS: 500, ready: [source: [0]], excluded: [])
    checkEqual(later.map(\.chunk), [1, 2, 3], "播放头在 A 上、第 0 块转好了：A 的 1、2，再 B 的 3")
    check(OptimizedMediaPlan.jobs(in: planState, playhead: 0, decodeFPS: 500, ready: [:], excluded: [source]).isEmpty, "转不了的源不排")
    check(OptimizedMediaPlan.jobs(in: planState, playhead: 0, decodeFPS: 100_000, ready: [:], excluded: []).isEmpty, "快机器上判不转就不排")
    var legacy = planState
    legacy.mainClips[0].info?.keyframeInterval = nil
    checkEqual(OptimizedMediaPlan.unknownKeyframeIntervals(in: legacy), [source], "缺关键帧间隔的源要补探")
    check(OptimizedMediaPlan.unknownKeyframeIntervals(in: planState).isEmpty, "探过的不再探")
    var mixed = planState
    var audio = EditClip(sourceURL: source, sourceDuration: 3, timelineStart: 0, info: long)
    audio.isAudioOnly = true
    mixed.audioTracks = [EditLane(clips: [audio])]
    check(OptimizedMediaPlan.pictureClips(in: mixed).count == 2, "纯音频的段不算画面")
    check(OptimizedMediaPlan.proxySources(in: planState, decodeFPS: 500) == [source], "要转的源")
}
