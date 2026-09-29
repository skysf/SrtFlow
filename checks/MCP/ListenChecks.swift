import Foundation
import SrtFlowMCPKit

// listen（「听」）的纯值部分（AIAudioLevels）：用生产的 ChunkBuilder 攒一份波形（0.5 的正弦 1 秒 → 静音 1 秒 →
// 0.1 的正弦 1 秒），量电平（只算有声音的部分）、峰值、静音段（窗和均方桶对齐，交界不漏能量）、响度曲线、
// 片段在时间线上听到的（变速换时间、段音量乘进去）。读真文件的那一半在 scripts/check-waveform.sh。
// 编法见 scripts/check-mcp.sh。

func runListenChecks() {
    guard let peaks = syntheticPeaks() else {
        check(false, "could not build the synthetic waveform")
        return
    }
    checkLevelsAndSilences(peaks)
    checkCurve(peaks)
    checkHeardOnTimeline(peaks)
    checkListenJSON(peaks)
}

private let rate = 48_000.0

/// 走生产的 ChunkBuilder：48kHz 单声道，0.5 正弦 1 秒、静音 1 秒、0.1 正弦 1 秒。
private func syntheticPeaks() -> WaveformPeaks? {
    var builder = ChunkBuilder(channels: 1, startFrame: 0)
    var chunks: [WaveformChunk] = []
    let samples: [Float] = (0..<Int(3 * rate)).map { index in
        let time = Double(index) / rate
        let tone = sin(2 * Double.pi * 440 * time)
        if time < 1 { return Float(0.5 * tone) }
        if time < 2 { return 0 }
        return Float(0.1 * tone)
    }
    samples.withUnsafeBufferPointer { builder.append(interleaved: $0) { chunks.append($0) } }
    if let tail = builder.finishChunk() { chunks.append(tail) }
    guard !chunks.isEmpty else { return nil }
    return WaveformPeaks(sampleRate: rate, channelCount: 1, chunks: chunks, isComplete: true)
}

private func checkLevelsAndSilences(_ peaks: WaveformPeaks) {
    let windows = AIAudioLevels.windows(peaks, from: 0, to: 3)
    check(windows.count > 60, "3 seconds are cut into ~43 ms windows (got \(windows.count))")
    check(abs((windows.first?.meanSquare ?? 0) - 0.125) < 0.002, "a 0.5 sine window has mean square 0.125")
    let report = AIAudioLevels.report(windows, silenceDB: -45, minSilence: 0.5)
    checkEqual(report.silences.count, 1, "one silence in the middle")
    if let silence = report.silences.first {
        // 窗和桶对齐：静音段两头最多各缩一个窗（约 43ms），不会被隔壁的响声拖得更短。
        check(silence.lowerBound >= 1.0 && silence.lowerBound <= 1.05, "the silence starts at 1 s (got \(silence.lowerBound))")
        check(silence.upperBound >= 1.95 && silence.upperBound <= 2.0, "the silence ends at 2 s (got \(silence.upperBound))")
    }
    // 电平只算有声音的部分：(0.125 + 0.005) / 2 的均方 ≈ −11.9 dB（整段平均的话会被静音拉到 −13.7）。
    check(abs((report.levelDB ?? 0) - (-11.9)) < 0.4, "level is the RMS of the parts that are not silent (got \(String(describing: report.levelDB)))")
    check(abs(report.peakDB - (-6.02)) < 0.05, "peak of a 0.5 sine is −6.02 dB (got \(report.peakDB))")
    checkEqual(AIAudioLevels.report(windows, silenceDB: -45, minSilence: 1.5).silences.count, 0,
               "a silence shorter than min_silence is not reported")
    let quiet = AIAudioLevels.report(AIAudioLevels.windows(peaks, from: 1.1, to: 1.9), silenceDB: -45, minSilence: 0.5)
    check(quiet.levelDB == nil, "all silent: no level")
}

private func checkCurve(_ peaks: WaveformPeaks) {
    let windows = AIAudioLevels.windows(peaks, from: 0, to: 3)
    guard let curve = AIAudioLevels.curve(windows) else {
        check(false, "no curve")
        return
    }
    checkEqual(curve.step, 0.5, "3 seconds: half-second steps")
    checkEqual(curve.decibels.count, 6, "six points")
    checkEqual(curve.decibels.first, -9, "the loud part is −9 dB")
    checkEqual(curve.decibels[2], -60, "the silent part is −60 dB (silent or quieter)")
    checkEqual(curve.decibels.last, -23, "the quiet tone is −23 dB")
    checkEqual(AIAudioLevels.loudest(curve), 0.25, "the loudest step's middle")
    let long = AIAudioLevels.Curve(from: 0, step: AIAudioLevels.curveSteps.first { 3600 / $0 <= 40 } ?? 0, decibels: [])
    checkEqual(long.step, 120, "an hour: two-minute steps (at most 40 points)")
}

private func checkHeardOnTimeline(_ peaks: WaveformPeaks) {
    // 时间线 10 秒处、两倍速、音量 0.5（−6 dB）：时间减半、电平低 6 dB。
    var clip = EditClip(
        sourceURL: music, isAudioOnly: true, sourceDuration: 3, speed: 2, timelineStart: 10, volume: 0.5,
        audioAssetDuration: 3
    )
    clip.fadeInDuration = 0
    let heard = AIAudioLevels.heard(AIAudioLevels.windows(peaks, from: 0, to: 3), clip: clip, trackGain: 1)
    check(abs((heard.first?.start ?? 0) - 10) < 1e-9, "windows move to timeline seconds")
    check(abs((heard.last?.end ?? 0) - 11.5) < 1e-3, "twice the speed: three source seconds are 1.5 timeline seconds")
    let report = AIAudioLevels.report(heard, silenceDB: -45, minSilence: 0.25)
    check(abs(report.peakDB - (-12.04)) < 0.05, "the clip's volume is in the peak (got \(report.peakDB))")
    check(abs((report.silences.first?.lowerBound ?? 0) - 10.5) < 0.03, "the silence is at 10.5 s on the timeline")
    let quieter = AIAudioLevels.heard(AIAudioLevels.windows(peaks, from: 0, to: 1), clip: clip, trackGain: 0.5)
    check(abs(AIAudioLevels.report(quieter, silenceDB: -45, minSilence: 0.5).peakDB - (-18.06)) < 0.05,
          "the track fader is in it too")
}

private func checkListenJSON(_ peaks: WaveformPeaks) {
    let windows = AIAudioLevels.windows(peaks, from: 0, to: 3)
    let report = AIAudioLevels.report(windows, silenceDB: -45, minSilence: 0.5)
    let detailed = AIAudioLevels.json(report, curve: AIAudioLevels.curve(windows), detailed: true)
    checkEqual(detailed["silences"]?.arrayValue?.count, 1, "one clip: the silences are listed")
    checkEqual(detailed["curve"]?["step"]?.doubleValue, 0.5, "one clip: the curve is there")
    checkEqual(detailed["peak_db"]?.doubleValue, -6, "peak rounded to a tenth of a dB")
    let brief = AIAudioLevels.json(report, curve: AIAudioLevels.curve(windows), detailed: false)
    checkEqual(brief["silences"]?.intValue, 1, "whole timeline: only how many silences")
    check(brief["curve"] == nil, "whole timeline: no curve")
    let silent = AIAudioLevels.Report(levelDB: nil, peakDB: -60, silences: [], silentSeconds: 0)
    checkEqual(AIAudioLevels.json(silent, curve: nil, detailed: false)["level_db"]?.stringValue, "silent", "all silent says so")
}
