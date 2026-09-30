import AVFoundation
import SrtFlowCore
import Foundation

// MARK: - 10b. 过 0 dBFS 的混音：真跑导出，f32 经限幅器在 −1 dBFS 之内、峰值 / 压了多少 / 响度照实报；成片的峰值不冒出 0、响度和混音一致
//
// 2026-09-30 婚礼工程（docs/bugfixes/2026-09-30-export-mix-over-0dbfs-into-aac.md）：17 个音效叠在音乐上，混音过了 0 dBFS，
// 原样交给 AAC 编码器 —— 成片峰值 +2.15 dBFS、RMS 比混音掉几 dB、主推子降 3 dB 成片里只降 2 dB。混音本身（AVFoundation 的 float）
// 是线性的、不削；所以在写 f32 那一步限幅（先是硬削，同一天换成 ExportPeakLimiter，docs/plans/2026-09-30-export-limiter-and-easing.md）、
// 把限幅前的峰值和整段响度报出来。这里用 0.9 满幅的正弦两轨各 +6 dB（和 ≈ 3.6）真跑一遍导出；响度拿 ffmpeg 的 ebur128 当第二把尺子。

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

/// 第二把尺子：ffmpeg 的 ebur128 量 f32 混音文件的整段响度（LUFS）。
private func ffmpegIntegratedLoudness(_ f32: URL) -> Double? {
    let (_, out) = run(ffmpegPath, ["-hide_banner", "-nostats"] + ExportAudioMixdown.inputArguments(f32) + ["-af", "ebur128=framelog=quiet", "-f", "null", "-"])
    guard let line = out.split(separator: "\n").first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("I:") }) else { return nil }
    return Double(line.replacingOccurrences(of: "LUFS", with: "").replacingOccurrences(of: "I:", with: "").trimmingCharacters(in: .whitespaces))
}

/// 交错立体声在 [from, to) 秒里的均方根。
private func stereoRMS(_ samples: [Float], from: Double, to: Double) -> Double {
    let lo = Int(from * 48_000) * 2, hi = min(samples.count, Int(to * 48_000) * 2)
    guard hi > lo else { return 0 }
    return sqrt(samples[lo ..< hi].reduce(0.0) { $0 + Double($1) * Double($1) } / Double(hi - lo))
}

/// 真跑一遍导出，同时留下计划里的电平、f32 混音文件，以及 ffmpeg 量的混音响度。
private func exportKeepingMixdown(_ state: TimelineState, name: String) async
    -> (levels: ExportAudioMixdown.Levels?, raw: [Float], exported: [Float], ffmpegLoudness: Double?)? {
    let output = root.appendingPathComponent(name)
    guard let plan = try? await VideoEditExportGraph.plan(
        state: state, settings: VideoEncodeSettings(), subtitleStyle: BurnInStyle(name: "check"), subtitleFontURL: nil, output: output
    ) else { check(false, "\(name) 的 plan() 失败"); return nil }
    defer { try? FileManager.default.removeItem(at: plan.workspace) }
    let mixdown = plan.workspace.appendingPathComponent("audio-mixdown.f32")
    let raw = rawMixdown(mixdown)
    let ffmpegLoudness = ffmpegIntegratedLoudness(mixdown)
    let (code, out) = run(ffmpegPath, plan.arguments)
    guard code == 0 else { check(false, "\(name) 的 ffmpeg 执行失败：\(out.suffix(300))"); return nil }
    return (plan.audioLevels, raw, decodeStereo(plan.tempOutput), ffmpegLoudness)
}

func checkMixCeiling() async {
    group("10b. 过 0 dBFS 的混音真跑导出：限幅、报峰值和响度")
    let tone = makeLoudTone("loud.m4a")
    func clip(_ volume: Double) -> EditClip {
        var c = EditClip(sourceURL: tone, isAudioOnly: true, sourceDuration: 4, timelineStart: 0, audioAssetDuration: 4)
        c.volume = volume
        return c
    }
    func loudnessAgrees(_ levels: ExportAudioMixdown.Levels, _ reference: Double?, _ label: String) {
        guard let got = levels.loudnessLUFS, let reference else {
            check(false, "\(label)：响度没量出来（我们 \(String(describing: levels.loudnessLUFS))、ffmpeg \(String(describing: reference))）"); return
        }
        check(abs(got - reference) < 0.5, "\(label)：整段响度和 ffmpeg 的 ebur128 一致（我们 \(got)、ffmpeg \(reference) LUFS）")
    }
    var state = TimelineState()
    state.frameRate = .fps30
    state.masterVolume = 1
    // 先量一条轨、音量 1 的峰值当尺子（素材经 AAC 一来一回、读法本身的口径都在里面），后面按线性比。
    state.audioTracks = [EditLane(clips: [clip(1)])]
    guard let one = await exportKeepingMixdown(state, name: "ceiling-one.m4a"), let single = one.levels else {
        check(false, "一条轨：导出没跑出来"); return
    }
    check(!single.isLimited && single.peakDBFS > -4 && single.peakDBFS < 0, "一条轨 0.9 满幅的正弦不压（峰值 \(single.peakDBFS) dBFS）")
    check(single.maxReductionDB == 0 && !single.needsAttention, "没压过：压得最深是 0、不用提醒")
    check(abs(Double(single.outputPeak) - Double(single.peak)) < 1e-6, "没压过：写出去的峰值 = 限幅前的峰值")
    loudnessAgrees(single, one.ffmpegLoudness, "一条轨")
    state.audioTracks = [EditLane(clips: [clip(2)]), EditLane(clips: [clip(2)])]

    guard let hot = await exportKeepingMixdown(state, name: "ceiling-hot.m4a"), let levels = hot.levels else {
        check(false, "两轨各 +6 dB：导出没跑出来"); return
    }
    let ceiling = Double(ExportAudioMixdown.peakCeiling)
    check(abs(Double(levels.peak) - Double(single.peak) * 4) < Double(single.peak) * 0.2,
          "限幅前的峰值照实记：两轨各 +6 dB 叠加 = 一条轨的 4 倍（得到 \(levels.peak)，一条轨 \(single.peak)）")
    check(levels.isLimited && levels.limitedSeconds > 1, "压了的时长照实记（得到 \(levels.limitedSeconds) s）")
    check(abs(levels.maxReductionDB - (levels.peakDBFS + 1)) < 0.1, "压得最深 = 峰值到 −1 dBFS 的差（\(levels.maxReductionDB) vs \(levels.peakDBFS + 1)）")
    check(levels.needsAttention && levels.suggestedReductionDB == levels.maxReductionDB, "压了 3 dB 以上要提醒，建议降的量就是压得最深的那一下")
    let rawPeak = Double(hot.raw.reduce(0) { max($0, abs($1)) })
    check(rawPeak <= ceiling + 1e-4, "f32 里没有一个采样超过 −1 dBFS（得到 \(decibels(rawPeak)) dBFS）")
    check(rawPeak >= ceiling - 0.01, "限幅不是别的：最响处正好贴着 −1 dBFS")
    check(abs(Double(levels.outputPeak) - rawPeak) < 1e-6, "报出来的输出峰值就是文件里的（\(levels.outputPeak) vs \(rawPeak)）")
    // 限幅不是削平：稳态那一段还是正弦（峰值 / 均方根 = √2；削平的方波接近 1）
    let rawRMS = stereoRMS(hot.raw, from: 1, to: 3)
    let crest = rawPeak / rawRMS
    check(abs(crest - 2.0.squareRoot()) < 0.05, "限幅之后仍是干净的正弦：峰值 / 均方根 = √2（得到 \(crest)；削平的会接近 1）")
    loudnessAgrees(levels, hot.ffmpegLoudness, "两轨各 +6 dB")
    let exportedPeak = Double(hot.exported.reduce(0) { max($0, abs($1)) })
    check(decibels(exportedPeak) <= 0.3, "成片解回来的峰值不冒出 0 dBFS（编码器过冲留了 1 dB；得到 \(decibels(exportedPeak)) dBFS）")
    let exportedRMS = decibels(stereoRMS(hot.exported, from: 1, to: 3))
    check(abs(decibels(rawRMS) - exportedRMS) < 0.5, "成片的响度和混音一致（混音 \(decibels(rawRMS))、成片 \(exportedRMS) dB；限幅前差 4.5 dB）")

    // 主推子压到不压：不再压、峰值按线性算、响度按线性算、和成片一致
    state.masterVolume = 0.2
    guard let cool = await exportKeepingMixdown(state, name: "ceiling-cool.m4a"), let cooled = cool.levels else {
        check(false, "主推子 0.2：导出没跑出来"); return
    }
    check(!cooled.isLimited, "主推子压到 0.2 之后一帧都不压（得到 \(cooled.limitedFrames) 帧）")
    check(abs(Double(cooled.peak) - Double(levels.peak) * 0.2) < 0.02, "限幅前的峰值随主推子线性（\(cooled.peak) vs \(levels.peak) × 0.2）")
    if let a = cooled.loudnessLUFS, let b = single.loudnessLUFS {
        // 两轨各 ×2 再 ×0.2 = 一条轨的 0.8 倍 = −1.94 dB
        check(abs((a - b) - 20 * log10(0.8)) < 0.3, "响度随增益线性：两轨 +6 dB × 主推子 0.2 比一条轨低 1.94 LU（得到 \(a - b)）")
    } else { check(false, "主推子 0.2 / 一条轨：响度没量出来") }
    let coolRMS = decibels(stereoRMS(cool.raw, from: 1, to: 3)), coolExported = decibels(stereoRMS(cool.exported, from: 1, to: 3))
    check(abs(coolRMS - coolExported) < 0.5, "不压时成片响度也和混音一致（\(coolRMS) vs \(coolExported) dB）")
}
