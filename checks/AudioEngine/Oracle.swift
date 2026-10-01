import AVFoundation
import Foundation

// MARK: - 参照：纯 Swift 的 oracle 混音器
//
// 2026-10-01 PR3b 起引擎是唯一的声音实现，没有「另一条管线」可比了：参照改成这里这个**只有几十行、
// 一眼看得完**的 oracle —— 源文件让 ffmpeg 解成 48 kHz f32（和引擎用的 AVAudioFile / AVAudioConverter
// 不是一套代码），每个采样 = Σ 段的源采样（按源位置线性插值）× 段增益（`GainTable.Sampler` 按**采样**取，
// 引擎按 64 帧一块插值）× 轨道推子，最后乘总推子。变速只按线性插值重采样（音高会变，但量的是包络；
// 音高另有过零数的断言）。声音场景（混响、滤波）oracle 不做：那几组只比「强度 0 = 原声」，场景本身
// 验结构（和原声不同、余音越过段尾、慢慢散）。
//
// 它验的是引擎的「水管」：喂样线程、环、锚点、渲染块的取样与增益插值、重采样、变速、推子、总推子。
// 「哪些段出声、增益表长什么样」在 `AudioEngineConfig.make` 里，两边共用，这里验不了，由
// check-audio-fade 的绝对期望（渐变形状、曲线探针、接缝电平）兜着。

/// 解码缓存：每个 URL 用 ffmpeg 解一次（按源自己的声道数解，单声道自己铺到两边 —— ffmpeg 的 `-ac 2` 会把
/// 单声道升成立体声时各乘 0.707，和引擎「原样铺到两边」差 3 dB）。
final class OracleSources {
    private var cache: [URL: Stereo] = [:]

    func stereo(_ url: URL) -> Stereo? {
        if let hit = cache[url] { return hit }
        // 只问声道数，采样不从 AVAudioFile 来。
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let channels = max(1, Int(file.processingFormat.channelCount))
        let raw = root.appendingPathComponent("oracle-\(UUID().uuidString).raw")
        let (code, out) = run(ffmpegPath, [
            "-y", "-hide_banner", "-loglevel", "error", "-i", url.path, "-map", "0:a:0",
            "-f", "f32le", "-ar", "48000", "-ac", "\(channels)", raw.path,
        ])
        guard code == 0, let data = try? Data(contentsOf: raw) else {
            print("oracle 解码失败：\(out)")
            return nil
        }
        var pcm = Stereo()
        data.withUnsafeBytes { bytes in
            let floats = bytes.bindMemory(to: Float.self)
            let frames = floats.count / channels
            pcm.left.reserveCapacity(frames)
            pcm.right.reserveCapacity(frames)
            for index in 0..<frames {
                let left = floats[index * channels]
                pcm.left.append(left)
                pcm.right.append(channels >= 2 ? floats[index * channels + 1] : left)
            }
        }
        cache[url] = pcm
        return pcm
    }
}

let oracleSources = OracleSources()

/// 按配置渲出整条时间线（48 kHz 立体声，正好 `config.duration`）。
func oraclePCM(_ config: AudioEngineConfig) -> Stereo? {
    let rate = 48_000.0
    let frames = Int((config.duration * rate).rounded())
    var left = [Float](repeating: 0, count: frames)
    var right = [Float](repeating: 0, count: frames)
    for track in config.tracks {
        for segment in track.segments {
            guard let source = oracleSources.stereo(segment.url) else { return nil }
            let first = max(0, Int((segment.start * rate).rounded()))
            let last = min(frames, Int((segment.end * rate).rounded()))
            guard last > first else { continue }
            for index in first..<last {
                let time = Double(index) / rate
                let position = (segment.sourceStart + (time - segment.start) * segment.speed) * rate
                let base = Int(position.rounded(.down))
                guard base >= 0, base + 1 < source.frames else { continue }
                let fraction = Float(position - Double(base))
                let gain = segment.gain.gain(at: time) * track.fader
                left[index] += (source.left[base] + (source.left[base + 1] - source.left[base]) * fraction) * gain
                right[index] += (source.right[base] + (source.right[base + 1] - source.right[base]) * fraction) * gain
            }
        }
    }
    for index in 0..<frames {
        left[index] *= config.master
        right[index] *= config.master
    }
    return Stereo(left: left, right: right)
}
