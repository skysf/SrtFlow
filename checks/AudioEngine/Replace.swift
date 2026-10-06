import Foundation
import SrtFlowCore

// 第 13 组：换配置（`TimelineAudioEngine.replace`）之后要按**新的几何**出声。
//
// 挪一段、裁头、裁尾、变速、换文件之后 clipID 和顺序都没变。2026-10-01 到 10-06 `sameStructure` 只比 id 的顺序，
// `replace` 把这些全当成「只换增益」：喂样器还按旧的 start / end / sourceStart 开流，画面（播放器的条目整个重建）挪了、
// 声音还在原地（docs/bugfixes/2026-10-06-audio-engine-replace-keeps-old-segment-positions.md）。
// 这里按 A 建引擎、`replace(B)`、离线渲到 B 的总长，必须和直接按 B 建的引擎逐窗口一样；只改音量的 B 仍是同一个结构
//（快路径不许被这次修复弄丢）。编译方式见 scripts/check-audio-engine.sh。

/// 底：A1 一段 880 Hz（toneC）占 0–2 秒；A2 一段静音的 330 Hz（toneD）把总长撑到 4 秒 —— 段挪了 / 裁了之后
/// 旧位置和新位置才都在渲染范围里（一边有声一边静音就是这组要抓的）。
func replaceBase(_ toneC: URL, _ toneD: URL) -> TimelineState {
    var filler = audioClip(toneD, start: 0, sourceStart: 0, duration: 4)
    filler.isMuted = true
    var state = baseState()
    state.audioTracks = [EditLane(clips: [audioClip(toneC, start: 0, sourceStart: 0, duration: 2)]), EditLane(clips: [filler])]
    return state
}

/// 先按 `before` 建引擎、再 `replace` 成 `after`，渲到 `after` 的总长。
func replacedPCM(before: TimelineState, after: TimelineState) -> (pcm: Stereo, underruns: Int)? {
    guard let engine = try? TimelineAudioEngine(config: AudioEngineConfig.make(from: before), mode: .offline) else { return nil }
    engine.replace(config: AudioEngineConfig.make(from: after))
    var pcm = Stereo()
    do {
        try engine.renderOffline(duration: after.duration) { interleaved, frames in
            pcm.append(interleaved: interleaved, frames: frames)
            return true
        }
    } catch {
        print("换配置之后引擎渲染失败：\(error)")
        return nil
    }
    return (pcm, engine.underrunFrames)
}

/// 一段里过零数出来的频率（Hz）。
func zeroCrossingFrequency(_ pcm: Stereo, from: Double, to: Double) -> Double {
    let samples = pcm.left[Int(from * 48_000)..<Int(to * 48_000)]
    var crossings = 0
    var previous = samples.first ?? 0
    for sample in samples.dropFirst() {
        if (sample >= 0) != (previous >= 0) { crossings += 1 }
        previous = sample
    }
    return Double(crossings) / 2 / (to - from)
}

/// 一个用例：`replace` 之后渲出来的和直接按 `after` 建的引擎逐窗口一样；两份配置的结构按预期同 / 不同
/// （不同 = 走重开流那条路，同 = 只换增益的快路径）。
@discardableResult
func compareReplaced(_ label: String, before: TimelineState, after: TimelineState, tolerance: Double = 0.15,
                     margin: Double = 0.012, expectSameStructure: Bool = false) -> Stereo? {
    let configBefore = AudioEngineConfig.make(from: before), configAfter = AudioEngineConfig.make(from: after)
    check(TimelineAudioEngine.sameStructure(configBefore, configAfter) == expectSameStructure,
          "\(label)：两份配置\(expectSameStructure ? "该是" : "不该是")同一个结构")
    guard let fresh = enginePCM(after) else {
        check(false, "\(label)：直接按新配置建的引擎渲不出来")
        return nil
    }
    guard let replaced = replacedPCM(before: before, after: after) else {
        check(false, "\(label)：换配置之后的引擎渲不出来")
        return nil
    }
    check(replaced.pcm.frames == fresh.pcm.frames, "\(label)：帧数该一样（换配置 \(replaced.pcm.frames)，直接建 \(fresh.pcm.frames)）")
    check(replaced.underruns == 0, "\(label)：换配置之后离线渲染不许欠载，欠了 \(replaced.underruns) 帧")
    check(rmsDB(fresh.pcm.left) > -50, "\(label)：直接建的引擎不该是静音（整段 RMS \(rmsDB(fresh.pcm.left)) dB）")
    let boundaries = configAfter.tracks.flatMap { $0.segments.flatMap { [$0.start, $0.end] } }
    let result = compareWindows(reference: fresh.pcm, engine: replaced.pcm, boundaries: boundaries, tolerance: tolerance, margin: margin)
    check(result.compared > 0, "\(label)：一个窗口都没比到")
    check(result.failures.isEmpty,
          "\(label)：换配置之后 \(result.failures.count) 个窗口和直接建的对不上（参照 = 直接建，引擎 = 换配置），前几个：\(result.failures.prefix(4))")
    print(String(format: "  %@：比了 %d 个窗口（跳过边界 %d），最大差 %.3f dB", label, result.compared, result.skipped, result.maxDiffDB))
    return replaced.pcm
}

/// 第 13 组本体。
func checkReplace(toneC: URL, toneD: URL) {
    let base = replaceBase(toneC, toneD)

    var moved = base
    moved.audioTracks[0].clips[0].timelineStart = 1.5
    compareReplaced("挪一段（0–2 → 1.5–3.5 秒）", before: base, after: moved)

    var headTrimmed = base
    headTrimmed.audioTracks[0].clips[0].sourceStart = 0.5
    headTrimmed.audioTracks[0].clips[0].sourceDuration = 1.5
    headTrimmed.audioTracks[0].clips[0].timelineStart = 0.5
    compareReplaced("裁头（从 0.5 秒起）", before: base, after: headTrimmed)

    var tailTrimmed = base
    tailTrimmed.audioTracks[0].clips[0].sourceDuration = 1.2
    compareReplaced("裁尾（到 1.2 秒为止）", before: base, after: tailTrimmed)

    var sped = base
    sped.audioTracks[0].clips[0].speed = 2
    // 变速走保音调的拉伸：两次渲的包络一样，但头尾要过渡几十毫秒，边界两侧各 0.1 秒不比（同第 12 组）。
    compareReplaced("变速（2 倍速，0–1 秒）", before: base, after: sped, tolerance: 0.5, margin: 0.1)

    var swapped = base
    swapped.audioTracks[0].clips[0].sourceURL = toneD
    // 两个文件一样响，RMS 比不出谁是谁：数过零。
    if let pcm = compareReplaced("换文件（880 Hz → 330 Hz）", before: base, after: swapped) {
        let hz = zeroCrossingFrequency(pcm, from: 0.2, to: 1.8)
        check(abs(hz - 330) < 20, "换文件之后该读新文件（330 Hz），量到 \(hz) Hz")
    }

    var quieter = base
    quieter.audioTracks[0].clips[0].volume = 0.5
    if let pcm = compareReplaced("只改音量（结构没变，走快路径）", before: base, after: quieter, expectSameStructure: true),
       let original = enginePCM(base) {
        let level = rmsDB(pcm.left[Int(0.2 * 48_000)..<Int(1.8 * 48_000)])
        let loud = rmsDB(original.pcm.left[Int(0.2 * 48_000)..<Int(1.8 * 48_000)])
        check(abs((loud - level) - 6.02) < 0.2, "只改音量：快路径该把声音压 6 dB（原 \(loud) dB，改后 \(level) dB）")
    }
}
