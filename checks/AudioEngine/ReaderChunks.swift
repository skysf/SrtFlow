import AVFoundation
import Foundation

// 读素材的连续性（2026-10-01 案例：docs/bugfixes/2026-10-01-resampler-reset-every-chunk.md）：
// 不是 48 kHz 的源（AI 视频的 32 kHz AAC、配乐 / 配音的 44.1 kHz mp3）要经 AVAudioConverter 重采样。喂样线程每次读 4096 帧、
// 位置从头算；读取器必须接着上一次的转换器状态读 —— 每块各自 reset 的话块头一个毛刺（44.1 kHz 的配乐块头 128 帧的误差只比
// 信号低 9 dB，连起来是持续的沙沙声）；转换器推式喂（一块塞完说 noDataNow）的话每次调用的最后几十帧也是错的。
// 判据：按 4096 帧连续读和按 32768 帧一口气读，**逐采样相同**；三种源各一遍（44.1k 单声道、32k 立体声、48k 立体声直读）。
func checkReaderChunks() {
    let tone32 = makeTone("stereo-32k.m4a", frequency: 700, withVideo: false, sampleRate: 32_000, channels: 2)
    let left = UnsafeMutablePointer<Float>.allocate(capacity: 32768)
    let right = UnsafeMutablePointer<Float>.allocate(capacity: 32768)
    defer {
        left.deallocate()
        right.deallocate()
    }
    func readAll(_ reader: AudioSegmentReader, chunk: Int, seconds: Double) -> [Float] {
        var out: [Float] = []
        var position = 0
        let total = Int(seconds * 48_000)
        while position < total {
            let got = reader.read(sourceSeconds: Double(position) / 48_000, frames: min(chunk, total - position), into: left, right)
            if got == 0 { break }
            out.append(contentsOf: UnsafeBufferPointer(start: left, count: got))
            position += got
        }
        return out
    }
    for (label, url, channels) in [("44.1 kHz 单声道", toneMono, 1), ("32 kHz 立体声", tone32, 2), ("48 kHz 立体声（直读）", toneC, 2)] {
        guard let chunked = AudioSegmentReader(url: url, speed: 1), let oneshot = AudioSegmentReader(url: url, speed: 1) else {
            check(false, "\(label)：读取器打不开")
            continue
        }
        check(chunked.channels == channels, "\(label)：读出 \(channels) 路")
        let a = readAll(chunked, chunk: 4096, seconds: 3), b = readAll(oneshot, chunk: 32768, seconds: 3)
        check(a.count == b.count && a.count >= 48_000 * 3 - 4096, "\(label)：两种读法帧数一样（\(a.count) vs \(b.count)）")
        var maxDiff: Float = 0
        var headError = 0.0, headFrames = 0
        for index in 0..<min(a.count, b.count) {
            let diff = abs(a[index] - b[index])
            maxDiff = max(maxDiff, diff)
            if index % 4096 < 128 {
                headError += Double(diff) * Double(diff)
                headFrames += 1
            }
        }
        let headDB = headError > 0 ? 10 * log10(headError / Double(max(1, headFrames))) : -200
        check(maxDiff < 1e-5, "\(label)：按块读和一口气读逐采样相同（最大差 \(maxDiff)）")
        check(headDB < -90, "\(label)：块头 128 帧没有毛刺（误差 \(headDB) dB）")
    }
}
