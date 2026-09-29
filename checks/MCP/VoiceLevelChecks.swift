import AVFoundation
import Foundation

// 配音的音量（AIVoiceLevel + AIAudioFileWriter.writeVoiceover）：峰值超过满幅的一句写进文件之后不许削波（2026-09-28 用户的
// en_male 旁白「One.」「Two.」「Three.」一声声爆音，docs/bugfixes/2026-09-28-kokoro-voiceover-clipping.md）；**开头炸了满幅 90 倍的
// 一下，后面说的话照样在该有的响度**（2026-09-29 第一版修法被那一下压了 37 dB，docs/bugfixes/2026-09-29-kokoro-short-pieces-explode.md）；
// 说话部分拉到同一个响度、停顿不算、静音原样、底噪不放大成噪音。写文件那一步真写一个 .m4a 再读回来量。编法见 scripts/check-mcp.sh。

func runVoiceLevelChecks() {
    levelMathChecks()
    writtenFileChecks()
}

private let rate = 24_000.0

/// 像一句话：几个「词」（180 Hz 的正弦，幅度 `level`），词之间停 0.2 秒；`burst` 不为 0 时开头先来 5 毫秒那么响的一下（像「T」「O」）。
private func line(level: Float, burst: Float = 0, pauseAfter: Double = 0) -> [Float] {
    var samples: [Float] = []
    if burst > 0 {
        samples += (0..<Int(rate * 0.005)).map { burst * Float(sin(2 * Double.pi * 300 * Double($0) / rate)) }
    }
    for _ in 0..<5 {
        samples += (0..<Int(rate * 0.25)).map { level * Float(sin(2 * Double.pi * 180 * Double($0) / rate)) }
        samples += [Float](repeating: 0, count: Int(rate * 0.2))
    }
    return samples + [Float](repeating: 0, count: Int(rate * pauseAfter))
}

private func peak(_ samples: [Float]) -> Float { samples.map { abs($0) }.max() ?? 0 }

/// 说话部分的均方根，用和 AIVoiceLevel 一样的口径（20 毫秒一格、−45 dBFS 以下不算）。
private func activeRMS(_ samples: [Float]) -> Float {
    let window = Int(rate * 0.02)
    var sum: Double = 0
    var count = 0
    var start = 0
    while start < samples.count {
        let slice = samples[start..<min(samples.count, start + window)]
        let energy = slice.reduce(0.0) { $0 + Double($1 * $1) }
        if (energy / Double(slice.count)).squareRoot() >= Double(AIVoiceLevel.activeFloor) {
            sum += energy
            count += slice.count
        }
        start += window
    }
    return count > 0 ? Float((sum / Double(count)).squareRoot()) : 0
}

private func dB(_ value: Float) -> Float { 20 * log10(value) }

/// 像 am_fenrir 那几句：说话部分本来就在 −18 dBFS 上下，开头一下冲到 1.15（峰值比说话响 19 dB）。
private let hotLine = line(level: 0.17, burst: 1.15)

/// 像 2026-09-29 那句「Two. Keep your prompts…」：开头 0.45 秒炸到满幅的 90 倍（+39 dB），后面是正常的说话。
private let blownUpLine = (0..<Int(rate * 0.45)).map { 90 * Float(sin(2 * Double.pi * 220 * Double($0) / rate)) } + line(level: 0.14)

/// 从第 `from` 秒起的说话部分有多响（dB）。
private func speechDB(_ samples: [Float], from: Double) -> Float {
    dB(activeRMS(Array(samples.dropFirst(Int(rate * from)))))
}

private func levelMathChecks() {
    let hot = AIVoiceLevel.normalized(hotLine, sampleRate: rate)
    check(abs(peak(hot) - AIVoiceLevel.peakCeiling) < 1e-4,
          "a line whose peak is over full scale is limited to exactly −1 dBFS there (got \(peak(hot)))")
    check(abs(speechDB(hot, from: 0.02) - dB(AIVoiceLevel.targetRMS)) < 1,
          "and the speech around it keeps its level (only the peak is pulled down, got \(speechDB(hot, from: 0.02)) dB)")
    let blown = AIVoiceLevel.normalized(blownUpLine, sampleRate: rate)
    check(abs(speechDB(blown, from: 0.5) - dB(AIVoiceLevel.targetRMS)) < 1,
          "a burst at 90 × full scale does not push the rest of the line down (speech at \(speechDB(blown, from: 0.5)) dB)")
    check(peak(blown) <= AIVoiceLevel.peakCeiling + 1e-5, "and the burst itself is limited to −1 dBFS (got \(peak(blown)))")
    let spiky = line(level: 0.05, burst: 0.5)
    let raised = AIVoiceLevel.normalized(spiky, sampleRate: rate)
    check(peak(raised) > peak(spiky) && peak(raised) <= AIVoiceLevel.peakCeiling + 1e-5,
          "turning a quiet line up never pushes its loudest moment over −1 dBFS (got \(peak(raised)))")
    let normal = AIVoiceLevel.normalized(line(level: 0.1), sampleRate: rate)
    check(abs(dB(activeRMS(normal)) - dB(AIVoiceLevel.targetRMS)) < 0.2, "an ordinary line is brought to −18 dBFS while speaking")
    let loud = AIVoiceLevel.normalized(line(level: 0.4), sampleRate: rate)
    let quiet = AIVoiceLevel.normalized(line(level: 0.05), sampleRate: rate)
    check(abs(dB(activeRMS(loud)) - dB(activeRMS(quiet))) < 0.1, "lines read louder or softer come out equally loud")
    let withPause = AIVoiceLevel.gain(for: line(level: 0.1, pauseAfter: 3), sampleRate: rate)
    check(abs(withPause - AIVoiceLevel.gain(for: line(level: 0.1), sampleRate: rate)) < 1e-3, "pauses do not count toward how loud a line is")
    let silence = [Float](repeating: 0, count: 4_800)
    checkEqual(AIVoiceLevel.normalized(silence, sampleRate: rate), silence, "silence stays as it is")
    checkEqual(AIVoiceLevel.normalized([], sampleRate: rate), [], "nothing stays nothing")
    checkEqual(AIVoiceLevel.gain(for: line(level: 0.012), sampleRate: rate), AIVoiceLevel.maxBoost, "a line of near-silence is boosted at most 4×")
}

/// 生产那一步：写成 .m4a 再读回来。AAC 会在峰值附近多冒一点，−1 dBFS 的上限留着这个余量
/// （2026-09-28 实测 Kokoro 八个音色的真句子，读回来的峰值和写进去的差不到 0.05 dB）。
private func writtenFileChecks() {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("srtflow-voice-level-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("hot.m4a")
    let raw = hotLine
    guard let written = try? AIAudioFileWriter.writeVoiceover(raw, sampleRate: rate, to: url) else {
        check(false, "the voiceover file could not be written")
        return
    }
    check(written == AIVoiceLevel.normalized(raw, sampleRate: rate), "what the writer returns is the leveled sound (word times are measured on it)")
    guard let file = try? AVAudioFile(forReading: url),
          let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
          (try? file.read(into: buffer)) != nil, let channel = buffer.floatChannelData?[0] else {
        check(false, "the voiceover file could not be read back")
        return
    }
    let decoded = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    check(peak(decoded) < 0.95, "the written voiceover never reaches full scale, so nothing is clipped (peak read back \(peak(decoded)))")
    check(abs(dB(activeRMS(decoded)) - dB(activeRMS(written))) < 0.5, "and it is as loud as the leveled sound")
}
