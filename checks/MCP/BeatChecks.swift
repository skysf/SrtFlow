import Foundation

// 鼓点（AudioBeatTracker）：合成一段已知速度的鼓点声（衰减的噪声脉冲，每四拍一个重拍，底下垫一个不变的长音和一点底噪），
// 速度差不过 1 BPM、每一拍离真的拍点不过 35 毫秒、小节头落在重拍上；换一个速度照样。再合成一段像样的鼓组（底鼓 1、3，
// 军鼓 2、4，八分踩镲，低音、铺底和弦）：拍子要跟在正拍上 —— 起音不分频带时，宽频的踩镲压过底鼓，128 BPM 每一拍都
// 差了半拍、带摇摆的 92 BPM 跟到了后半拍的踩镲上。只有长音没有鼓点时要说「不清楚」。
// 编法见 scripts/check-mcp.sh。

func runBeatChecks() {
    checkAnalysisWindow()
    checkClickTrack(bpm: 120, first: 0.3)
    checkClickTrack(bpm: 90, first: 0.55)
    checkGroove(bpm: 128, swing: 0)
    checkGroove(bpm: 92, swing: 0.12)
    checkNoRhythm()
}

private let rate = 11_025.0

/// listen 和 cut_to_beat 要看同一份分析：请求落在文件开头 15 分钟里就分析整段（2026-09-29 婚礼工程 BUG-07：0–90 秒和
/// 0–32 秒各分析各的，同一首歌一边 63.5 BPM 一边 95.3）。
private func checkAnalysisWindow() {
    let listen = BeatAnalysisWindow.resolve(from: 0, to: 90, fileDuration: 263.4)
    let cut = BeatAnalysisWindow.resolve(from: 0, to: 32.21, fileDuration: 263.4)
    check(listen == cut && listen == (0, 263.4), "listen (0–90 s) and cut_to_beat (0–32 s) analyse the whole song: \(listen) vs \(cut)")
    check(BeatAnalysisWindow.resolve(from: 120, to: 150, fileDuration: 263.4) == (0, 263.4), "a clip from the middle of the song still uses the whole-song analysis")
    check(BeatAnalysisWindow.resolve(from: 0, to: 32, fileDuration: 1200) == (0, 900), "a long file is analysed up to the 15-minute cap")
    check(BeatAnalysisWindow.resolve(from: 950, to: 1000, fileDuration: 1200) == (950, 1000), "a request past the cap keeps its own window")
    check(BeatAnalysisWindow.resolve(from: 1000, to: 3000, fileDuration: 3000) == (1000, 1900), "and is itself capped at 15 minutes")
}

/// 20 秒：从 `first` 起每拍一个脉冲，第 0、4、8… 拍是重拍。
private func clicks(bpm: Double, first: Double, seconds: Double = 20) -> (samples: [Float], beats: [Double]) {
    var generator = SystemRandomNumberGenerator()
    var samples = (0..<Int(seconds * rate)).map { index -> Float in
        let t = Double(index) / rate
        return Float(0.1 * sin(2 * .pi * 220 * t)) + Float.random(in: -0.01...0.01, using: &generator)
    }
    let interval = 60 / bpm
    var beats: [Double] = []
    var time = first
    var count = 0
    while time < seconds - 0.1 {
        beats.append(time)
        let amplitude: Float = count % 4 == 0 ? 1 : 0.45
        let start = Int(time * rate)
        for offset in 0..<Int(0.03 * rate) where start + offset < samples.count {
            let decay = Float(exp(-Double(offset) / (0.006 * rate)))
            samples[start + offset] += amplitude * decay * Float.random(in: -1...1, using: &generator)
        }
        time += interval
        count += 1
    }
    return (samples, beats)
}

private func checkClickTrack(bpm: Double, first: Double) {
    let track = clicks(bpm: bpm, first: first)
    guard let analysis = AudioBeatTracker.analyze(track.samples, sampleRate: rate) else {
        check(false, "\(Int(bpm)) BPM: no analysis at all")
        return
    }
    check(abs(analysis.bpm - bpm) < 1, "\(Int(bpm)) BPM detected (got \(analysis.bpm))")
    // 头一秒里的拍子动态规划还在摸索，从第 1 秒以后比。
    let settled = analysis.beats.filter { $0 > 1 }
    let worst = settled.map { beat in track.beats.map { abs($0 - beat) }.min() ?? .infinity }.max() ?? .infinity
    check(worst < 0.035, "\(Int(bpm)) BPM: every beat within 35 ms of a click (worst \(worst))")
    check(settled.count >= track.beats.filter { $0 > 1 }.count - 1, "\(Int(bpm)) BPM: no beat is missed")
    let accents = Set(stride(from: 0, to: track.beats.count, by: 4).map { track.beats[$0] })
    let onAccent = analysis.downbeats.filter { downbeat in accents.contains { abs($0 - downbeat) < 0.035 } }
    check(onAccent.count >= analysis.downbeats.count - 1, "\(Int(bpm)) BPM: downbeats land on the accents")
    check(analysis.confidence > 0.2, "\(Int(bpm)) BPM: a clear beat has a clear confidence (\(analysis.confidence))")
}

private func checkNoRhythm() {
    let tone = (0..<Int(20 * rate)).map { Float(0.3 * sin(2 * .pi * 330 * Double($0) / rate)) }
    let analysis = AudioBeatTracker.analyze(tone, sampleRate: rate)
    check(analysis == nil || analysis!.confidence < 0.2, "a steady tone has no clear beat (\(analysis?.confidence ?? 0))")
}

/// 30 秒的鼓组：底鼓 1、3，军鼓 2、4，八分踩镲（后半拍可以晚一点，摇摆），低音每拍换一个音、有时后半拍多一个，
/// 铺底和弦两小节一换、慢起。
private func groove(bpm: Double, swing: Double, seconds: Double = 30) -> (samples: [Float], beats: [Double]) {
    var generator = SystemRandomNumberGenerator()
    var samples = [Float](repeating: 0, count: Int(seconds * rate))
    let beat = 60 / bpm
    func hit(_ time: Double, _ duration: Double, _ amplitude: Float, _ wave: (Double) -> Float) {
        let start = Int(time * rate)
        for offset in 0..<Int(duration * rate) where start + offset < samples.count {
            samples[start + offset] += amplitude * wave(Double(offset) / rate)
        }
    }
    var beats: [Double] = []
    var time = 0.4
    var count = 0
    while time < seconds - 0.5 {
        beats.append(time)
        if count % 2 == 0 {
            hit(time, 0.25, 0.9) { x in Float(sin(2 * .pi * (60 + 80 * exp(-x * 30)) * x) * exp(-x * 12)) }
        } else {
            hit(time, 0.18, 0.6) { x in Float.random(in: -1...1, using: &generator) * Float(exp(-x * 25)) }
        }
        hit(time, 0.05, 0.25) { x in Float.random(in: -1...1, using: &generator) * Float(exp(-x * 80)) }
        hit(time + beat * (0.5 + swing), 0.05, 0.18) { x in Float.random(in: -1...1, using: &generator) * Float(exp(-x * 80)) }
        let note = [55.0, 55, 73.4, 65.4][count % 4]
        hit(time, beat * 0.9, 0.3) { x in Float(sin(2 * .pi * note * x)) * Float(min(1, x * 50)) }
        if count % 3 == 2 { hit(time + beat * 0.75, beat * 0.2, 0.2) { x in Float(sin(2 * .pi * 82.4 * x)) } }
        time += beat
        count += 1
    }
    var chordTime = 0.4
    var chord = 0
    while chordTime < seconds {
        let notes = [[220.0, 277.2, 329.6], [196.0, 246.9, 293.7]][chord % 2]
        hit(chordTime, beat * 8, 0.08) { x in Float(notes.reduce(0) { $0 + sin(2 * .pi * $1 * x) }) * Float(min(1, x * 2)) }
        chordTime += beat * 8
        chord += 1
    }
    return (samples, beats)
}

private func checkGroove(bpm: Double, swing: Double) {
    let track = groove(bpm: bpm, swing: swing)
    guard let analysis = AudioBeatTracker.analyze(track.samples, sampleRate: rate) else {
        check(false, "groove \(Int(bpm)): no analysis at all")
        return
    }
    check(abs(analysis.bpm - bpm) < 1, "groove \(Int(bpm)) BPM detected (got \(analysis.bpm))")
    let errors = analysis.beats.filter { $0 > 2 && $0 < 29 }.map { beat in track.beats.map { abs($0 - beat) }.min() ?? .infinity }
    let median = errors.sorted()[errors.count / 2]
    check(median < 0.025, "groove \(Int(bpm)) BPM (swing \(swing)): beats on the beat, not the off-beat hats (median \(median))")
    check(analysis.confidence > 0.4, "groove \(Int(bpm)) BPM: clear confidence (\(analysis.confidence))")
}
