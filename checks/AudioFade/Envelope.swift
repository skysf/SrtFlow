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

/// 预览侧：从真实合成 + audioMix 里读 PCM（单声道 f32）。
func previewPCM(_ built: VideoEditCompositionBuilder.Built) async -> [Float] {
    await previewPCM(built.composition, mix: built.audioMix)
}

func previewPCM(_ asset: AVMutableComposition, mix: AVMutableAudioMix?) async -> [Float] {
    guard let tracks = try? await asset.loadTracks(withMediaType: .audio), !tracks.isEmpty,
          let reader = try? AVAssetReader(asset: asset) else { return [] }
    let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 1,
    ])
    output.audioMix = mix
    guard reader.canAdd(output) else { return [] }
    reader.add(output)
    guard reader.startReading() else { return [] }

    var samples: [Float] = []
    while let buffer = output.copyNextSampleBuffer() {
        guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
        let length = CMBlockBufferGetDataLength(block)
        var bytes = [UInt8](repeating: 0, count: length)
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &bytes)
                == kCMBlockBufferNoErr else { continue }
        bytes.withUnsafeBytes { raw in
            samples.append(contentsOf: raw.bindMemory(to: Float.self))
        }
    }
    return samples
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
