import Foundation

// MARK: - 10a. 限幅器与响度表（纯值，不跑导出）
//
// ExportPeakLimiter：没过顶的地方逐采样原样；过顶的一个采样都不超过上限；稳态的 +6 dB 正弦出来是 −1 dBFS 的干净正弦
//（不是削平的方波）；尖峰的时刻不变、前面是斜坡不是台阶、后面按释放时间慢慢回；分块喂和整段喂逐位一样、总长度不变。
// ExportLoudnessMeter：EBU Tech 3341 的口径 —— 立体声 997 Hz 正弦 −23 dBFS ≈ −23 LUFS、−20 ≈ −20；后面接一段静音结果不变（门限）；
// 只有一个声道时低 3 dB；全静音是 nil。

private let rate = 48_000

private func stereoSine(amplitude: Float, hz: Double, seconds: Double) -> [Float] {
    let frames = Int(seconds * Double(rate))
    var out = [Float](repeating: 0, count: frames * 2)
    for i in 0 ..< frames {
        let v = amplitude * Float(sin(2 * .pi * hz * Double(i) / Double(rate)))
        out[i * 2] = v
        out[i * 2 + 1] = v
    }
    return out
}

/// 整段一次喂完（或按 `chunk` 帧分块），冲干净，返回输出和限幅器（看统计）。
private func limit(_ input: [Float], chunk: Int? = nil, ceiling: Float = ExportPeakLimiter.defaultCeiling) -> ([Float], ExportPeakLimiter) {
    var limiter = ExportPeakLimiter(channels: 2, sampleRate: rate, ceiling: ceiling)
    var output: [Float] = []
    let frames = input.count / 2
    var start = 0
    while start < frames {
        let count = min(chunk ?? frames, frames - start)
        input.withUnsafeBufferPointer { whole in
            let slice = UnsafeBufferPointer(rebasing: whole[(start * 2) ..< ((start + count) * 2)])
            limiter.process(slice, frames: count, into: &output)
        }
        start += count
    }
    limiter.flush(into: &output)
    return (output, limiter)
}

private func peak(_ samples: ArraySlice<Float>) -> Float { samples.reduce(0) { max($0, abs($1)) } }
private func rms(_ samples: ArraySlice<Float>) -> Double {
    guard !samples.isEmpty else { return 0 }
    return sqrt(samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count))
}

private func loudness(_ samples: [Float]) -> Double? {
    var meter = ExportLoudnessMeter(channels: 2)
    samples.withUnsafeBufferPointer { meter.add($0, frames: samples.count / 2) }
    return meter.integratedLUFS
}

func checkLimiterAndLoudness() {
    group("10a. 限幅器与响度表（纯值）")
    let ceiling = ExportPeakLimiter.defaultCeiling
    let lookahead = ExportPeakLimiter(channels: 2, sampleRate: rate).lookahead
    checkEqual(lookahead, 240, "前瞻 5 ms = 240 帧")

    // ---- 没过顶：逐采样原样 ----
    var quiet = stereoSine(amplitude: 0.5, hz: 440, seconds: 1)
    var seed: UInt32 = 7
    for i in quiet.indices { // 掺点确定性的杂音，别只测正弦
        seed = seed &* 1_664_525 &+ 1_013_904_223
        quiet[i] += Float(seed >> 8) / Float(1 << 24) * 0.3 - 0.15
    }
    let (quietOut, quietLimiter) = limit(quiet, chunk: 1_000)
    check(quietOut == quiet, "没过顶的信号逐采样原样（含分块喂）")
    check(quietLimiter.overFrames == 0 && quietLimiter.minimumGain == 1, "没过顶：一帧都没压、最深增益是 1")
    checkEqual(quietLimiter.emitted, quietLimiter.received, "没过顶：写出去的帧数 = 收进来的")

    // ---- 稳态 +6 dB 正弦：干净的 −1 dBFS 正弦 ----
    let hot = stereoSine(amplitude: 2.0, hz: 440, seconds: 2)
    let (hotOut, hotLimiter) = limit(hot)
    checkEqual(hotOut.count, hot.count, "总长度不变")
    let hotPeak = peak(hotOut[...])
    check(hotPeak <= ceiling + 1e-5, "一个采样都不超过上限（得到 \(hotPeak)）")
    let steady = hotOut[(rate * 2) ..< (rate * 2 * 2)] // 0.5 s 之后
    let steadyRMS = rms(steady), steadyPeak = Double(peak(steady))
    check(abs(steadyPeak - Double(ceiling)) < 0.005, "稳态峰值正好贴着上限（得到 \(steadyPeak)）")
    check(abs(steadyRMS - Double(ceiling) / 2.0.squareRoot()) < 0.01,
          "稳态是干净的正弦：均方根 = 上限 / √2（得到 \(steadyRMS)，正弦该是 \(Double(ceiling) / 2.0.squareRoot())，削平的方波会到 \(ceiling)）")
    // 和等幅的理想正弦逐采样比（限幅器延迟了 lookahead 帧，理想正弦也照样延迟）
    let ideal = stereoSine(amplitude: ceiling, hz: 440, seconds: 2)
    var worst: Float = 0
    for i in (rate * 2) ..< (rate * 2 * 2) { worst = max(worst, abs(hotOut[i] - ideal[i])) }
    check(worst < ceiling * 0.02, "和等幅正弦逐采样差 < 2%（最大差 \(worst)）")
    check(abs(Double(hotLimiter.inputPeak) - 2) < 1e-6 && hotLimiter.overFrames > rate * 2 / 2,
          "统计：限幅前峰值 2.0、过顶的帧数过半（得到 \(hotLimiter.inputPeak)、\(hotLimiter.overFrames)）")
    let expectedReduction = -20 * log10(Double(ceiling) / 2)
    let gotReduction = -20 * log10(Double(hotLimiter.minimumGain))
    check(abs(gotReduction - expectedReduction) < 0.05, "压得最深 = 峰值到上限的差（\(gotReduction) vs \(expectedReduction) dB）")

    // ---- 低频过顶：50 Hz +6 dB 也不许超过上限、也不许抽成锯齿 ----
    let low = stereoSine(amplitude: 2.0, hz: 50, seconds: 2)
    let (lowOut, _) = limit(low)
    check(peak(lowOut[...]) <= ceiling + 1e-5, "50 Hz 过顶也一个采样都不超过上限")
    let lowSteady = rms(lowOut[(rate * 2) ..< (rate * 2 * 2)])
    check(lowSteady > Double(ceiling) / 2.0.squareRoot() * 0.9, "50 Hz 没被抽扁：均方根还在正弦的九成以上（得到 \(lowSteady)）")

    // ---- 尖峰：时刻不变、前面是斜坡、后面慢慢回 ----
    let frames = rate * 3
    var spike = [Float](repeating: 0.2, count: frames * 2)
    let at = rate / 2 // 0.5 s 处一个 2.0 的尖峰
    spike[at * 2] = 2.0
    spike[at * 2 + 1] = -2.0
    let (spikeOut, spikeLimiter) = limit(spike, chunk: 333)
    var spikeIndex = 0
    var spikeMax: Float = 0
    for i in 0 ..< frames where abs(spikeOut[i * 2]) > spikeMax { spikeMax = abs(spikeOut[i * 2]); spikeIndex = i }
    checkEqual(spikeIndex, at, "尖峰的时刻不变")
    check(abs(spikeMax - ceiling) < 1e-3, "尖峰压到正好上限（得到 \(spikeMax)）")
    check(abs(spikeOut[at * 2 + 1] + ceiling) < 1e-3, "两个声道同一个增益（右声道 \(spikeOut[at * 2 + 1])）")
    checkEqual(spikeLimiter.overFrames, 1, "只有那一帧过顶")
    // 前面 lookahead 帧：单调往下、每一步不超过一小格（台阶会一步跳 0.2 × (1 − 0.4455) ≈ 0.11）
    var monotone = true, biggestStep: Float = 0
    for i in (at - lookahead) ..< at {
        let step = spikeOut[(i - 1) * 2] - spikeOut[i * 2]
        if step < -1e-6 { monotone = false }
        biggestStep = max(biggestStep, abs(step))
    }
    check(monotone && biggestStep < 0.002, "尖峰前 5 ms 是斜坡：单调下降、最大一步 \(biggestStep)")
    check(abs(spikeOut[(at - lookahead - 1) * 2] - 0.2) < 1e-6, "斜坡之前一个采样都没动")
    let required = ceiling / 2
    let after10ms = spikeOut[(at + rate / 100) * 2], after1s = spikeOut[(at + rate) * 2], after2s = spikeOut[(at + rate * 2) * 2]
    check(after10ms < 0.2 * (required + 0.15), "尖峰过后 10 ms 还压着（得到 \(after10ms)，压满是 \(0.2 * required)）")
    check(after1s > 0.2 * 0.9999, "尖峰过后 1 s（12 个释放时间）差不到万分之一（得到 \(after1s)）")
    check(after2s == 0.2, "尖峰过后 2 s 逐位回到原样（得到 \(after2s)）")

    // ---- 分块喂 = 整段喂；各种长度总长不变 ----
    for length in [0, 1, lookahead - 1, lookahead, lookahead + 1, 1_000, 10_007] {
        let signal = Array(hot.prefix(length * 2))
        let (whole, _) = limit(signal)
        let (chunked, chunkedLimiter) = limit(signal, chunk: 7)
        checkEqual(whole.count, length * 2, "长度 \(length) 帧：输出总长不变")
        check(whole == chunked, "长度 \(length) 帧：按 7 帧分块喂和整段喂逐位一样")
        checkEqual(chunkedLimiter.emitted, length, "长度 \(length) 帧：emitted")
    }

    // ---- 响度表 ----
    func near(_ got: Double?, _ want: Double, _ label: String) {
        check(got.map { abs($0 - want) < 0.3 } ?? false, "\(label)：\(got.map { String(format: "%.2f", $0) } ?? "nil") LUFS，该是 \(want)（±0.3）")
    }
    let minus23 = stereoSine(amplitude: Float(pow(10.0, -23.0 / 20)), hz: 997, seconds: 10)
    near(loudness(minus23), -23, "EBU 3341 第 1 条：997 Hz −23 dBFS 立体声")
    let minus20 = stereoSine(amplitude: Float(pow(10.0, -20.0 / 20)), hz: 997, seconds: 10)
    near(loudness(minus20), -20, "997 Hz −20 dBFS 立体声")
    near(loudness(minus20 + [Float](repeating: 0, count: rate * 2 * 20)), -20, "后面接 20 秒静音，门限挡住（结果不变）")
    var leftOnly = minus20
    for i in stride(from: 1, to: leftOnly.count, by: 2) { leftOnly[i] = 0 }
    near(loudness(leftOnly), -23.01, "只有左声道：低 3.01 dB")
    check(loudness([Float](repeating: 0, count: rate * 2 * 3)) == nil, "全静音：nil")
    check(loudness(Array(minus20.prefix(rate * 2 / 4))) != nil, "不到 400 ms 也给个数（按已有的算）")
    // 分块喂和整段喂一样
    var chunkedMeter = ExportLoudnessMeter(channels: 2)
    var start = 0
    while start < minus23.count / 2 {
        let count = min(1_234, minus23.count / 2 - start)
        minus23.withUnsafeBufferPointer { whole in
            chunkedMeter.add(UnsafeBufferPointer(rebasing: whole[(start * 2) ..< ((start + count) * 2)]), frames: count)
        }
        start += count
    }
    check(chunkedMeter.integratedLUFS == loudness(minus23), "响度表：分块喂和整段喂一样")
    // 限幅之后量：+6 dB 正弦压到上限之后的响度 = 上限那么响的正弦
    near(loudness(hotOut), loudness(ideal) ?? 0, "限幅后的响度 = 等幅正弦的响度")
}
