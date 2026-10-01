import AVFoundation
import Foundation

// 从 main.swift 搬出来（2026-09-24，那个文件过了 600 行的上限）：量包络的工具，
// 两条管线的每一组都用它们。编译方式见 scripts/check-audio-fade.sh。

// MARK: - 量包络

/// 把文件解成单声道 f32 PCM。
func decodePCM(_ url: URL) -> [Float] {
    let raw = root.appendingPathComponent("pcm-\(UUID().uuidString).raw")
    let (code, log) = run(ffmpegPath, [
        "-y", "-hide_banner", "-loglevel", "error",
        "-i", url.path, "-map", "0:a",
        "-f", "f32le", "-ac", "1", "-ar", "48000", raw.path,
    ])
    guard code == 0, let data = try? Data(contentsOf: raw) else {
        print("解码失败：\(log)")
        return []
    }
    return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
}

/// 预览侧（2026-10-01 起用户听到的那一份）：音频引擎离线渲出来的 PCM，并成单声道。并法是 (L + R) / √2 —— 和 `decodePCM`
/// 里 ffmpeg `-ac 1` 的口径一样（实测：左右相同的正弦并出来是单边的 1.414 倍；写成 (L + R) / 2 就比成片整体低 2.93 dB）。
/// 成片就是这份渲染经限幅、编码出来的，「成片 = 预览」要对着它比。
/// 2026-10-01 PR3b 之前这里还有 AVFoundation 那条读法（合成 + audioMix 经 AVAssetReaderAudioMixOutput）；那条路删了。
func enginePCM(_ state: TimelineState) -> [Float] {
    guard let engine = try? TimelineAudioEngine(config: AudioEngineConfig.make(from: state), mode: .offline) else { return [] }
    return renderMono(engine, duration: state.duration)
}

/// 快路径：按 `base` 开引擎，只换增益到 `changed`（`updateGains`：结构不变、流不重开），再离线渲 ——
/// 和「拖完滑块听到的」是同一条路；对照组是按 `changed` 重开一个引擎（`enginePCM`）。
func enginePCM(_ base: TimelineState, thenUpdateGains changed: TimelineState) -> [Float] {
    guard let engine = try? TimelineAudioEngine(config: AudioEngineConfig.make(from: base), mode: .offline) else { return [] }
    engine.updateGains(config: AudioEngineConfig.make(from: changed))
    return renderMono(engine, duration: changed.duration)
}

private func renderMono(_ engine: TimelineAudioEngine, duration: Double) -> [Float] {
    var samples: [Float] = []
    do {
        try engine.renderOffline(duration: duration) { interleaved, frames in
            samples.reserveCapacity(samples.count + frames)
            for index in 0..<frames { samples.append((interleaved[2 * index] + interleaved[2 * index + 1]) * 0.70710678) }
            return true
        }
    } catch { return [] }
    return samples
}

/// 挂着电平表渲出来的结果：单声道 PCM，加上每条表**按拍**记下的槽里的峰值（取走之前看一眼）。
struct MeteredRender {
    var samples: [Float] = []
    /// 每条表：(这一拍的起点秒, 槽里的峰值 —— 左右取大)。
    var peaks: [MeterKey: [(time: Double, peak: Float)]] = [:]

    /// `[from, to)` 秒内落下的拍里最大的峰值（没有就是 0）。
    func rawPeak(for key: MeterKey, from: Double, to: Double) -> Float {
        (peaks[key] ?? []).filter { $0.time >= from - 0.0001 && $0.time < to }.map(\.peak).max() ?? 0
    }
}

/// 挂着电平表离线渲：每拍渲完先看一眼 `keys` 每条表槽里的峰值（`slotPeak`，不清零），再照界面那条路取走
/// （`reading`，顺带算回落和红灯）。离线一拍是引擎的一个渲染块（4096 帧 ≈ 85 ms）。
func enginePCMMetered(_ state: TimelineState, keys: [MeterKey], meters: AudioMeterEngine) -> MeteredRender? {
    guard let engine = try? TimelineAudioEngine(config: AudioEngineConfig.make(from: state), mode: .offline, meters: meters)
    else { return nil }
    var result = MeteredRender()
    var position = 0
    do {
        try engine.renderOffline(duration: state.duration) { interleaved, frames in
            let time = Double(position) / 48_000
            for key in keys {
                if let peak = meters.slotPeak(for: key) {
                    result.peaks[key, default: []].append((time, max(peak.left, peak.right)))
                }
                _ = meters.reading(for: key, at: time, now: time)
            }
            result.samples.reserveCapacity(result.samples.count + frames)
            for index in 0..<frames { result.samples.append((interleaved[2 * index] + interleaved[2 * index + 1]) * 0.70710678) }
            position += frames
            return true
        }
    } catch { return nil }
    return result
}

/// 第 4b 组的不变量，引擎版：每一段的增益表**第一个设定点不晚于段的起点**（引擎只在段内取样，表在第一个点之前默认 1.0
/// 的那一截永远取不到），而且起点处的增益就是「这一段该从多少起步」—— 有渐入是 0、没渐入是段的音量，不是默认的 1.0。
/// `startGain` 给了就连值一起验。
/// （AVFoundation 那条路的版本是「每条合成音轨的第一个音量设定点在时间 0」：混音器把第一个点之前的默认 1.0 平滑成一条
/// 下坡贴在渐入最前面 —— 2026-08-12 的爆音。引擎没有 de-zipper、段外不取样，这条约束就落在增益表自己身上。）
func checkPinnedFromZero(_ state: TimelineState, _ label: String, startGain: Float? = nil) {
    let config = AudioEngineConfig.make(from: state)
    check(!config.tracks.isEmpty, "\(label)：引擎的配置里该有轨")
    for track in config.tracks {
        for segment in track.segments {
            let firstPoint = segment.gain.points.first?.start ?? .infinity
            check(firstPoint <= segment.start + 0.0005,
                  "\(label)：轨 \(track.name) 段 \(segment.clipID) 的第一个增益设定点在 \(firstPoint)s，"
                  + "晚于段的起点 \(segment.start)s —— 起点到它之间会落到表的默认 1.0 上")
            if let startGain {
                let got = segment.gain.gain(at: segment.start)
                check(abs(got - startGain) < 0.001, "\(label)：轨 \(track.name) 段起点的增益该是 \(startGain)，量到 \(got)")
            }
        }
    }
}

/// 一个时间窗内的 RMS（48kHz 单声道）。
func rms(_ samples: [Float], from: Double, to: Double) -> Double {
    let rate = 48_000.0
    let start = max(0, Int(from * rate))
    let end = min(samples.count, Int(to * rate))
    guard end > start else { return 0 }
    var sum = 0.0
    for index in start..<end {
        let value = Double(samples[index])
        sum += value * value
    }
    return (sum / Double(end - start)).squareRoot()
}

/// 一个时间窗内的**峰值**。RMS 会把几毫秒的爆音摊平（100ms 窗里的 2ms 满幅
/// 只把 RMS 抬到 0.14），抓瞬态必须看峰值。
func peak(_ samples: [Float], from: Double, to: Double) -> Double {
    let rate = 48_000.0
    let start = max(0, Int(from * rate))
    let end = min(samples.count, Int(to * rate))
    guard end > start else { return 0 }
    return samples[start..<end].map { Double(abs($0)) }.max() ?? 0
}

/// 一条包络的四个采样点，全部**相对满音量**归一化 —— 这样断言不依赖编码器
/// 的绝对增益，也不依赖素材音量。
struct Envelope {
    var head: Double    // 0.00–0.10s
    var quarter: Double // 0.20–0.30s（1 秒渐入的四分之一处）
    var half: Double    // 0.45–0.55s
    var body: Double    // 2.00–2.10s（满音量参照）
    var tail: Double    // 3.90–4.00s

    init(_ samples: [Float]) {
        let full = rms(samples, from: 2.0, to: 2.1)
        body = full
        let scale = full > 0 ? full : 1
        head = rms(samples, from: 0, to: 0.1) / scale
        quarter = rms(samples, from: 0.2, to: 0.3) / scale
        half = rms(samples, from: 0.45, to: 0.55) / scale
        tail = rms(samples, from: 3.9, to: 4.0) / scale
    }

    var description: String {
        String(
            format: "head=%.3f quarter=%.3f half=%.3f tail=%.3f (满音量 RMS %.3f)",
            head, quarter, half, tail, body
        )
    }
}

/// 一条**线性**渐入 1s / 渐出 1s 的包络该长什么样。
func checkFadedEnvelope(_ envelope: Envelope, _ label: String) {
    check(envelope.body > 0.01, "\(label)：中段必须真的有声音（量到 \(envelope.description)）")
    // 0–0.1s：增益 0→0.1，RMS 比例 ≈ 0.058。
    check(envelope.head < 0.15, "\(label)：开头必须几乎无声（\(envelope.description)）")
    // 0.2–0.3s：增益 0.2→0.3，RMS 比例 ≈ 0.25。
    check(envelope.quarter > 0.12 && envelope.quarter < 0.40,
          "\(label)：渐入四分之一处应在四分之一音量附近（\(envelope.description)）")
    // 0.45–0.55s：增益 ≈ 0.5 —— 线性曲线的判据，换成等功率曲线这条会红。
    check(envelope.half > 0.38 && envelope.half < 0.62,
          "\(label)：渐入中点应是半音量（线性曲线；\(envelope.description)）")
    check(envelope.tail < 0.15, "\(label)：结尾必须几乎无声（\(envelope.description)）")
}

/// 反例对照：没设渐变的同一条时间线，开头结尾都必须是满音量。
func checkFlatEnvelope(_ envelope: Envelope, _ label: String) {
    check(envelope.body > 0.01, "\(label)：中段必须真的有声音（\(envelope.description)）")
    check(envelope.head > 0.85, "\(label)：没设渐变时开头就该是满音量（\(envelope.description)）")
    check(envelope.tail > 0.85, "\(label)：没设渐变时结尾就该是满音量（\(envelope.description)）")
}
