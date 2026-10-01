import Foundation

// 比两份立体声 PCM（48 kHz）：按 10 ms 的窗口量 RMS（dB），段的边界附近的窗口不算（合成按 1/600 秒的格子截断、
// 重采样器起步，边界上差一两毫秒是换算的零头，不是混音算错）。编译方式见 scripts/check-audio-engine.sh。

struct Stereo {
    var left: [Float] = []
    var right: [Float] = []
    var frames: Int { min(left.count, right.count) }

    mutating func append(interleaved: UnsafeBufferPointer<Float>, frames: Int) {
        left.reserveCapacity(left.count + frames)
        right.reserveCapacity(right.count + frames)
        for index in 0..<frames {
            left.append(interleaved[2 * index])
            right.append(interleaved[2 * index + 1])
        }
    }
}

/// 一段采样的 RMS（dBFS）；全静音给 −120。
func rmsDB(_ samples: ArraySlice<Float>) -> Double {
    guard !samples.isEmpty else { return -120 }
    var sum = 0.0
    for sample in samples { sum += Double(sample) * Double(sample) }
    let rms = (sum / Double(samples.count)).squareRoot()
    return rms > 1e-6 ? 20 * log10(rms) : -120
}

func rmsDB(_ samples: [Float]) -> Double { rmsDB(samples[...]) }

struct WindowComparison {
    var windows = 0
    var compared = 0
    var skipped = 0
    var failures: [String] = []
    var maxDiffDB = 0.0
}

/// 逐窗口比。`boundaries` 是要跳过的时刻（秒）：段的起止。`tolerance` 是两边都有声音时允许的差（dB）。
func compareWindows(
    reference: Stereo, engine: Stereo, boundaries: [Double], tolerance: Double, rate: Double = 48_000
) -> WindowComparison {
    let window = Int(rate * 0.010)
    let frames = min(reference.frames, engine.frames)
    var result = WindowComparison()
    var start = 0
    while start + window <= frames {
        let end = start + window
        result.windows += 1
        let from = Double(start) / rate, to = Double(end) / rate
        if boundaries.contains(where: { $0 > from - 0.012 && $0 < to + 0.012 }) {
            result.skipped += 1
            start = end
            continue
        }
        result.compared += 1
        for (name, a, b) in [("L", reference.left, engine.left), ("R", reference.right, engine.right)] {
            let refDB = rmsDB(a[start..<end]), engDB = rmsDB(b[start..<end])
            let silentRef = refDB < -60, silentEng = engDB < -60
            if silentRef && silentEng { continue }
            if silentRef != silentEng {
                result.failures.append(String(format: "%.3fs %@: 一边有声一边静音（参照 %.1f dB，引擎 %.1f dB）", from, name, refDB, engDB))
                continue
            }
            let diff = abs(refDB - engDB)
            result.maxDiffDB = max(result.maxDiffDB, diff)
            if diff > tolerance {
                result.failures.append(String(format: "%.3fs %@: 差 %.2f dB（参照 %.2f，引擎 %.2f）", from, name, diff, refDB, engDB))
            }
        }
        start = end
    }
    return result
}
