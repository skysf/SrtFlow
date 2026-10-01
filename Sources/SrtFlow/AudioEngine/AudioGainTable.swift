import CoreMedia
import Foundation

// MARK: - 增益表：一段声音在时间线上的音量设定（段音量 / 曲线 × 渐入渐出），以及怎么从一段剪辑铺出来
//
// 管什么：`GainTable`（按时间顺序的设定点和线性斜坡，`sampler()` 给渲染块按秒取值）和 `AudioGainRamps`
// （从 `EditClip` 的音量、渐变、音量曲线铺出一张表）。`AudioEngineConfig.make` 给每一段铺一张，引擎的渲染块
// 64 帧一块取值；check-audio-engine 的 oracle 逐采样取同一张表。
// 不管什么：轨道推子、总推子（配置里另存，渲染块乘）；渐变和转场怎么仲裁（`AudioFadeWindow`）。
//
// 2026-10-01 PR3b 从 VideoEditAudioMeter.swift（GainTable）和 VideoEditAudioMix.swift（AudioMixBuilder.addVolumeRamps /
// addCurveRamps）搬过来：那两个文件是 AVPlayer 那条声音路的，随它一起删了；表本身一行没改。

struct GainTable: Sendable {
    struct Segment: Sendable {
        var start: CMTime
        var end: CMTime
        var from: Float
        var to: Float
    }

    private(set) var segments: [Segment] = []

    /// 从 `time` 起音量是 `value`。
    mutating func set(_ value: Float, at time: CMTime) {
        segments.append(Segment(start: time, end: time, from: value, to: value))
    }

    /// 一段线性斜坡。
    mutating func ramp(from: Float, to: Float, range: CMTimeRange) {
        segments.append(Segment(start: range.start, end: range.end, from: from, to: to))
    }

    /// 某一刻的音量：斜坡里线性插值，斜坡之间保持上一个值，第一个设定之前是默认的 1.0（引擎只在段内取样，
    /// 段的第一个设定点不晚于段起点 —— check-audio-fade 第 4b 组钉着，所以那个 1.0 永远取不到）。
    /// 按秒存一份，免得音频线程里反复换算 CMTime。
    func sampler() -> Sampler {
        Sampler(points: segments.map {
            Sampler.Point(start: $0.start.seconds, end: $0.end.seconds, from: $0.from, to: $0.to)
        })
    }

    struct Sampler: Sendable {
        struct Point: Sendable {
            var start: Double
            var end: Double
            var from: Float
            var to: Float
        }
        let points: [Point]

        func gain(at time: Double) -> Float {
            guard let first = points.first, time >= first.start else { return 1 }
            var low = 0
            var high = points.count - 1
            while low < high {
                let mid = (low + high + 1) / 2
                if points[mid].start <= time { low = mid } else { high = mid - 1 }
            }
            let point = points[low]
            guard time < point.end, point.end > point.start else { return point.to }
            let fraction = Float((time - point.start) / (point.end - point.start))
            return point.from + (point.to - point.from) * fraction
        }
    }
}


/// 从一段剪辑铺增益表。
enum AudioGainRamps {
    /// 剪辑范围内的恒定音量；两端按 `fades` 做线性斜坡。
    ///
    /// `fades` 里已经把「用户设的渐入渐出」和「转场重叠区的交叉淡变」仲裁完了
    /// （`AudioFadeWindow.previewMainTrack`），这里只管照着铺斜坡 —— 别在这个
    /// 函数里再判断转场，两处判断迟早会分叉。
    ///
    /// `previousEnd`：钉点的落点。AVFoundation 那条路（2026-10-01 PR3b 之前）钉在同一条合成轨上上一段的结束处，
    /// 躲混音器的 de-zipper；引擎只在段内取样，段外没有声音，传段自己的起点即可（`AudioEngineConfig`）。
    static func addVolumeRamps(
        table: inout GainTable,
        clip: EditClip,
        fades: AudioFadeWindow,
        previousEnd: Double,
        gainScale: Double
    ) {
        // 画了音量曲线的段走折线表（与导出同一张），没画的段一行不变地走老路。
        if clip.hasVolumeCurve {
            addCurveRamps(
                table: &table, clip: clip, fades: fades, previousEnd: previousEnd, gainScale: gainScale
            )
            return
        }
        let volume = Float((clip.isMuted ? 0 : clip.volume) * gainScale)
        let fadeIn: Double? = fades.fadeIn > 0 ? fades.fadeIn : nil
        let fadeOut: Double? = fades.fadeOut > 0 ? fades.fadeOut : nil

        // 段起点（或更早）先把音量钉到「这一段该从多少起步」：有渐入钉 0，没渐入钉 body 音量本身 —— 表在
        // 第一个设定点之前默认 1.0，钉点保证段内从第一个采样起就是用户定的值（check-audio-fade 第 4b 组）。
        // 这条规矩来自 AVFoundation 那条路的 de-zipper 爆音（docs/bugfixes/2026-08-12-audio-fade-in-pop.md）；
        // 引擎没有 de-zipper，但「起点处就是该起步的音量」照样是合同。
        let pin = min(previousEnd, clip.timelineStart)
        table.set(fadeIn == nil ? volume : 0, at: time(pin))

        var bodyStart = clip.timelineStart
        var bodyEnd = clip.timelineEnd
        if let fadeIn, fadeIn > 0 {
            table.ramp(
                from: 0, to: volume,
                range: CMTimeRange(start: time(clip.timelineStart), end: time(clip.timelineStart + fadeIn))
            )
            bodyStart += fadeIn
        }
        if let fadeOut, fadeOut > 0 { bodyEnd -= fadeOut }
        if bodyEnd > bodyStart {
            table.ramp(
                from: volume, to: volume,
                range: CMTimeRange(start: time(bodyStart), end: time(bodyEnd))
            )
        }
        if let fadeOut, fadeOut > 0 {
            table.ramp(
                from: volume, to: 0,
                range: CMTimeRange(start: time(clip.timelineEnd - fadeOut), end: time(clip.timelineEnd))
            )
        }
    }

    /// 画了音量曲线的段：按 `VolumeCurveSampling.breakpoints` 那张折线表铺一串线性斜坡，再乘上渐入渐出和推子。
    /// 唯一要额外细分的是渐变窗口：线性渐变 × 线性折线是二次曲线，窗口里按 `fadeSubdivisions` 等分取点
    /// （误差远小于 0.1 dB）。钉点同 `addVolumeRamps`：钉的值是这一段起点真正的增益。
    private static func addCurveRamps(
        table: inout GainTable,
        clip: EditClip,
        fades: AudioFadeWindow,
        previousEnd: Double,
        gainScale: Double
    ) {
        let span = clip.timelineDuration
        let curve = VolumeCurveSampling.breakpoints(for: clip)
        guard span > 0, !curve.isEmpty else { return }

        var times = curve.map(\.time)
        for (start, length) in [(0.0, fades.fadeIn), (span - fades.fadeOut, fades.fadeOut)] where length > 0 {
            for step in 0...fadeSubdivisions {
                times.append(start + length * Double(step) / Double(fadeSubdivisions))
            }
        }
        times = times.map { min(max($0, 0), span) }.sorted()

        func gain(_ offset: Double) -> Float {
            let envelope = fades.linearEnvelope(atElapsed: offset, span: span)
            return Float(VolumeCurveSampling.gain(at: offset, in: curve) * envelope * gainScale)
        }

        let pin = min(previousEnd, clip.timelineStart)
        table.set(gain(0), at: time(pin))
        // 相邻两点落在同一个 1/600 秒格子里就并掉（零长斜坡没有意义）。
        var last: (time: CMTime, gain: Float) = (time(clip.timelineStart), gain(0))
        for offset in times {
            let at = time(clip.timelineStart + offset)
            let value = gain(offset)
            guard CMTimeCompare(at, last.time) > 0 else {
                last.gain = value
                continue
            }
            table.ramp(from: last.gain, to: value, range: CMTimeRange(start: last.time, end: at))
            last = (at, value)
        }
    }

    /// 渐变窗口里细分多少份（见 `addCurveRamps`）。
    static let fadeSubdivisions = 16

    private static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: max(0, seconds), preferredTimescale: 600)
    }
}
