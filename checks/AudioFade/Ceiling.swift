import AVFoundation
import SrtFlowCore
import Foundation

// MARK: - 10. 过 0 dBFS 的混音：f32 在 −1 dBFS 封顶、记峰值；成片的峰值不再冒出 0、响度和混音一致
//
// 2026-09-30 婚礼工程（docs/bugfixes/2026-09-30-export-mix-over-0dbfs-into-aac.md）：17 个音效叠在音乐上，混音过了 0 dBFS，
// 原样交给 AAC 编码器 —— 成片峰值 +2.15 dBFS、RMS 比混音掉几 dB、主推子降 3 dB 成片里只降 2 dB。混音本身（AVFoundation 的 float）
// 是线性的、不削；所以在写 f32 那一步封顶、把封顶前的峰值报出来。这里用 0.9 满幅的正弦两轨各 +6 dB（和 ≈ 3.6）真跑一遍导出。

/// 0.9 满幅的正弦（makeTone 的 sine 只有 −17.8 dBFS，叠加也过不了 0）。
private func makeLoudTone(_ name: String) -> URL {
    let url = root.appendingPathComponent(name)
    run(ffmpegPath, ["-y", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "aevalsrc=0.9*sin(2*PI*440*t):s=48000:d=4",
                     "-c:a", "aac", "-b:a", "192k", "-ac", "2", "-t", "4", url.path])
    return url
}

private func rawMixdown(_ url: URL) -> [Float] {
    guard let data = try? Data(contentsOf: url) else { return [] }
    return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
}

/// 成片解成**立体声** f32（和 f32 混音文件同一种排法）。`decodePCM` 那条路混成单声道会乘 1/√2·(L+R)，和混音文件比要差 3 dB。
private func decodeStereo(_ url: URL) -> [Float] {
    let raw = root.appendingPathComponent(url.lastPathComponent + ".stereo.f32")
    run(ffmpegPath, ["-y", "-hide_banner", "-loglevel", "error", "-i", url.path, "-vn", "-ac", "2", "-ar", "48000", "-f", "f32le", raw.path])
    return rawMixdown(raw)
}

/// 交错立体声在 [from, to) 秒里的均方根。
private func stereoRMS(_ samples: [Float], from: Double, to: Double) -> Double {
    let lo = Int(from * 48_000) * 2, hi = min(samples.count, Int(to * 48_000) * 2)
    guard hi > lo else { return 0 }
    return sqrt(samples[lo ..< hi].reduce(0.0) { $0 + Double($1) * Double($1) } / Double(hi - lo))
}

/// 真跑一遍导出，同时留下计划里的电平和 f32 混音文件。
private func exportKeepingMixdown(_ state: TimelineState, name: String) async -> (levels: ExportAudioMixdown.Levels?, raw: [Float], exported: [Float])? {
    let output = root.appendingPathComponent(name)
    guard let plan = try? await VideoEditExportGraph.plan(
        state: state, settings: VideoEncodeSettings(), subtitleStyle: BurnInStyle(name: "check"), subtitleFontURL: nil, output: output
    ) else { check(false, "\(name) 的 plan() 失败"); return nil }
    defer { try? FileManager.default.removeItem(at: plan.workspace) }
    let raw = rawMixdown(plan.workspace.appendingPathComponent("audio-mixdown.f32"))
    let (code, out) = run(ffmpegPath, plan.arguments)
    guard code == 0 else { check(false, "\(name) 的 ffmpeg 执行失败：\(out.suffix(300))"); return nil }
    return (plan.audioLevels, raw, decodeStereo(plan.tempOutput))
}

func checkMixCeiling() async {
    let tone = makeLoudTone("loud.m4a")
    func clip(_ volume: Double) -> EditClip {
        var c = EditClip(sourceURL: tone, isAudioOnly: true, sourceDuration: 4, timelineStart: 0, audioAssetDuration: 4)
        c.volume = volume
        return c
    }
    var state = TimelineState()
    state.frameRate = .fps30
    state.masterVolume = 1
    // 先量一条轨、音量 1 的峰值当尺子（素材经 AAC 一来一回、读法本身的口径都在里面），后面按线性比。
    state.audioTracks = [EditLane(clips: [clip(1)])]
    guard let one = await exportKeepingMixdown(state, name: "ceiling-one.m4a"), let single = one.levels else {
        check(false, "一条轨：导出没跑出来"); return
    }
    check(!single.isClipped && single.peakDBFS > -4 && single.peakDBFS < 0, "一条轨 0.9 满幅的正弦不削（峰值 \(single.peakDBFS) dBFS）")
    state.audioTracks = [EditLane(clips: [clip(2)]), EditLane(clips: [clip(2)])]

    guard let hot = await exportKeepingMixdown(state, name: "ceiling-hot.m4a"), let levels = hot.levels else {
        check(false, "两轨各 +6 dB：导出没跑出来"); return
    }
    let ceiling = Double(ExportAudioMixdown.peakCeiling)
    check(abs(Double(levels.peak) - Double(single.peak) * 4) < Double(single.peak) * 0.2,
          "封顶前的峰值照实记：两轨各 +6 dB 叠加 = 一条轨的 4 倍（得到 \(levels.peak)，一条轨 \(single.peak)）")
    check(levels.isClipped && levels.clippedSeconds > 1, "削了的时长照实记（得到 \(levels.clippedSeconds) s）")
    check(abs(levels.suggestedReductionDB - (levels.peakDBFS + 1)) < 1e-6, "建议主推子降的量 = 峰值到 −1 dBFS 的差")
    let rawPeak = Double(hot.raw.reduce(0) { max($0, abs($1)) })
    check(rawPeak <= ceiling + 1e-4, "f32 里没有一个采样超过 −1 dBFS（得到 \(decibels(rawPeak)) dBFS）")
    check(rawPeak >= ceiling - 0.01, "封顶不是别的：最响处正好贴着 −1 dBFS")
    let exportedPeak = Double(hot.exported.reduce(0) { max($0, abs($1)) })
    check(decibels(exportedPeak) <= 0.3, "成片解回来的峰值不冒出 0 dBFS（编码器过冲留了 1 dB；得到 \(decibels(exportedPeak)) dBFS）")
    let rawRMS = decibels(stereoRMS(hot.raw, from: 1, to: 3)), exportedRMS = decibels(stereoRMS(hot.exported, from: 1, to: 3))
    check(abs(rawRMS - exportedRMS) < 0.5, "成片的响度和混音一致（混音 \(rawRMS)、成片 \(exportedRMS) dB；封顶前差 4.5 dB）")

    // 主推子压到不削：不再削、峰值按线性算、和成片一致
    state.masterVolume = 0.2
    guard let cool = await exportKeepingMixdown(state, name: "ceiling-cool.m4a"), let cooled = cool.levels else {
        check(false, "主推子 0.2：导出没跑出来"); return
    }
    check(!cooled.isClipped, "主推子压到 0.2 之后一帧都不削（得到 \(cooled.clippedFrames) 帧）")
    check(abs(Double(cooled.peak) - Double(levels.peak) * 0.2) < 0.02, "封顶前的峰值随主推子线性（\(cooled.peak) vs \(levels.peak) × 0.2）")
    let coolRMS = decibels(stereoRMS(cool.raw, from: 1, to: 3)), coolExported = decibels(stereoRMS(cool.exported, from: 1, to: 3))
    check(abs(coolRMS - coolExported) < 0.5, "不削时成片响度也和混音一致（\(coolRMS) vs \(coolExported) dB）")
}
