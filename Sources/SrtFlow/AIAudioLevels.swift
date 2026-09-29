import Foundation
import SrtFlowMCPKit

// MARK: - 听：一段声音有多响、哪儿最响、哪儿没声音（纯值）
//
// 管什么：波形数据（峰值 + 均方，一个文件读一遍的那份）按约 43ms 切窗 → 电平（RMS）、峰值、静音段、一条粗的
// 响度曲线；片段在时间线上时换成时间线秒、乘上听到的增益（段音量 / 曲线、渐入渐出、轨道推子 ——
// `EditClip.heardGain`，波形条画「听到的声音」也是它）。纯值，自检够得着（scripts/check-mcp.sh）。
// 不管什么：波形怎么读（WaveformStore）、参数和权限（AIListenTool）。
//
// 口径：
// - **电平只算有声音的部分**（静音窗不进平均）：一段话里停顿多，整段平均会被拉低，AI 拿它配音乐会配得太响。
// - dB 走 `AudioGain.decibels`（电平表也是它）：−60 就是「静音或更轻」。
// - 静音 = 连续的窗都低于门限（默认 −45 dB），长度够 `minSilence`（默认 0.5 秒）才算一段。

enum AIAudioLevels {
    /// 一个窗：时间（文件秒或时间线秒）、均方、峰值（线性）。
    struct Window: Equatable {
        var start: Double
        var end: Double
        var meanSquare: Double
        var peak: Double

        var decibels: Double { AudioGain.decibels(fromLinear: meanSquare.squareRoot()) }
    }

    /// 一个窗是几个均方桶（48kHz 下两桶约 43ms）。
    static let bucketsPerWindow = 2

    /// 源时间 [from, to) 切成窗。**窗和均方桶的边对齐**：不对齐的话，跨在「响 / 静」交界上的那个桶会把响的能量
    /// 按帧数摊进隔壁的静音窗，静音段两头各缩一截。只有头尾两个窗可能不满。波形还没读到的部分不出窗。
    static func windows(_ peaks: WaveformPeaks, from: Double, to: Double) -> [Window] {
        let rate = peaks.sampleRate
        guard rate > 0, to > from else { return [] }
        let span = bucketsPerWindow * WaveformPowerBuilder.bucket
        let first = max(0, Int((from * rate).rounded(.down)))
        let last = min(Int((to * rate).rounded(.down)), peaks.framesAvailable)
        guard last > first else { return [] }
        let level = WaveformPeaks.level(forFramesPerPixel: Double(span))
        var result: [Window] = []
        var start = first
        while start < last {
            let end = min(last, (start / span + 1) * span)
            if let power = peaks.meanSquare(channel: nil, from: start, to: end),
               let range = peaks.extremes(channel: nil, from: start, to: end, level: level) {
                result.append(Window(
                    start: Double(start) / rate, end: Double(end) / rate,
                    meanSquare: power, peak: Double(max(abs(range.min), abs(range.max)))
                ))
            }
            start = end
        }
        return result
    }

    /// 片段在时间线上听到的：窗换成时间线秒，均方乘增益的平方、峰值乘增益。
    static func heard(_ windows: [Window], clip: EditClip, trackGain: Double) -> [Window] {
        windows.map { window in
            let start = clip.timelineTime(atSource: window.start)
            let end = clip.timelineTime(atSource: window.end)
            let gain = clip.heardGain(atTimeline: (start + end) / 2, trackGain: trackGain)
            return Window(start: start, end: end, meanSquare: window.meanSquare * gain * gain, peak: window.peak * gain)
        }
    }

    struct Report: Equatable {
        /// 有声音的部分的 RMS（dB）；整段都没声音是 nil。
        var levelDB: Double?
        var peakDB: Double
        var silences: [ClosedRange<Double>]
        var silentSeconds: Double
    }

    static func report(_ windows: [Window], silenceDB: Double, minSilence: Double) -> Report {
        var loudPower = 0.0
        var loudSeconds = 0.0
        var peak = 0.0
        var silences: [ClosedRange<Double>] = []
        var quietStart: Double?
        var quietEnd = 0.0
        func closeQuiet() {
            if let begin = quietStart, quietEnd - begin >= minSilence - 1e-9 { silences.append(begin...quietEnd) }
            quietStart = nil
        }
        for window in windows {
            peak = max(peak, window.peak)
            if window.decibels < silenceDB {
                if quietStart == nil || abs(window.start - quietEnd) > 1e-6 {
                    closeQuiet()
                    quietStart = window.start
                }
                quietEnd = window.end
            } else {
                closeQuiet()
                let seconds = window.end - window.start
                loudPower += window.meanSquare * seconds
                loudSeconds += seconds
            }
        }
        closeQuiet()
        return Report(
            levelDB: loudSeconds > 0 ? AudioGain.decibels(fromLinear: (loudPower / loudSeconds).squareRoot()) : nil,
            peakDB: AudioGain.decibels(fromLinear: peak),
            silences: silences,
            silentSeconds: silences.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
        )
    }

    /// 一条粗的响度曲线：最多 `maxPoints` 个点，每点是那一格的 RMS（整数 dB），格宽取好读的整数秒。
    struct Curve: Equatable {
        var from: Double
        var step: Double
        var decibels: [Int]
    }

    static let curveSteps: [Double] = [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600]

    static func curve(_ windows: [Window], maxPoints: Int = 40) -> Curve? {
        guard let first = windows.first, let last = windows.last else { return nil }
        let span = last.end - first.start
        let step = curveSteps.first { span / $0 <= Double(maxPoints) } ?? curveSteps[curveSteps.count - 1]
        var sums: [Double] = []
        var weights: [Double] = []
        for window in windows {
            let index = Int(((window.start - first.start) / step).rounded(.down) + 1e-9)
            while sums.count <= index {
                sums.append(0)
                weights.append(0)
            }
            let seconds = window.end - window.start
            sums[index] += window.meanSquare * seconds
            weights[index] += seconds
        }
        let values = zip(sums, weights).map { sum, weight in
            Int(AudioGain.decibels(fromLinear: weight > 0 ? (sum / weight).squareRoot() : 0).rounded())
        }
        return Curve(from: first.start, step: step, decibels: values)
    }

    /// 最响的那一格的中点（曲线的格子，不是某一个 50ms 的尖）。
    static func loudest(_ curve: Curve) -> Double? {
        guard let index = curve.decibels.indices.max(by: { curve.decibels[$0] < curve.decibels[$1] }) else { return nil }
        return curve.from + (Double(index) + 0.5) * curve.step
    }

    // MARK: 写给 AI 看

    static let maxSilences = 50

    static func json(_ report: Report, curve: Curve?, detailed: Bool) -> [String: JSONValue] {
        var object: [String: JSONValue] = ["peak_db": decibels(report.peakDB)]
        object["level_db"] = report.levelDB.map(decibels) ?? "silent"
        if detailed {
            object["silences"] = .array(report.silences.prefix(maxSilences).map {
                .array([AIFormat.seconds($0.lowerBound), AIFormat.seconds($0.upperBound)])
            })
            if report.silences.count > maxSilences { object["more_silences"] = .number(Double(report.silences.count - maxSilences)) }
        } else {
            object["silences"] = .number(Double(report.silences.count))
        }
        if report.silentSeconds > 0 { object["silent_seconds"] = AIFormat.seconds(report.silentSeconds) }
        if let curve {
            if let loudest = loudest(curve) { object["loudest_at"] = AIFormat.seconds(loudest) }
            if detailed {
                object["curve"] = [
                    "from": AIFormat.seconds(curve.from), "step": AIFormat.seconds(curve.step),
                    "db": .array(curve.decibels.map { .number(Double($0)) })
                ]
            }
        }
        return object
    }

    private static func decibels(_ value: Double) -> JSONValue {
        .number((value * 10).rounded() / 10)
    }
}
