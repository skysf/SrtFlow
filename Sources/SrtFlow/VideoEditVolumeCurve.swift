import CoreGraphics
import Foundation

// MARK: - 音量曲线（画在段上的音量自动化）
//
// 2026-09-23 起：音频块（以及视频块底部的波形带）上画一条音量线，靠近线拖、
// ⌥ 点线加点、拖点改时间和值 —— 对齐 Final Cut / Logic 的手感。
//
// 这个文件是**纯值**（不 import SwiftUI / AVFoundation），自检编得动它：
//
// - 取值：`EditClip.clipGain(atTimeline:)` —— 「这一刻这段自己的增益」，界面、
//   波形、电平表都从这儿读。
// - 编辑：加点 / 删点 / 挪点 / 拖一段线 / 整条平移，全部是「从手势起手那一刻的
//   段出发，算出松手后的段」—— 拖动中不写 `TimelineState`（时间线拖动 §0）。
// - 两条管线：`VolumeCurveSampling.breakpoints(for:)` 把曲线展开成一张**线性幅度
//   的折线表**，预览（`setVolumeRamp`）和导出（ffmpeg `aeval`）吃的是同一张表。
//
// 合同见 docs/architecture/audio-volume-curve.md。

/// 音量曲线的读盘入口（命名空间）。
///
/// 故意是一个**类型**而不是 `KeyframeTrack` 的扩展：`VideoEditModels.swift` 解码时
/// 要调它，而自检脚本源文件清单的守卫只认得「引用了别的文件里的顶层类型」——
/// 只走扩展的话，漏编这个文件它看不出来（checks/check-script-source-lists.sh 的盲区）。
enum VolumeCurve {
    /// 读盘后的音量曲线：丢掉非有限的点，dB 夹进合法区间。
    ///
    /// 工程文件是可以被外部改的 JSON，NaN 一旦进了折线表，`setVolumeRamp` 与
    /// `aeval` 各坏各的（前者静默忽略，后者整条声音变 nan）—— 在读侧一次收口。
    static func sanitized(_ track: KeyframeTrack) -> KeyframeTrack {
        KeyframeTrack(keys: track.keys.compactMap { key in
            guard key.time.isFinite, key.value.isFinite else { return nil }
            return Keyframe(time: key.time, value: AudioGain.clampedDecibels(key.value))
        })
    }
}

extension FadeWindow {
    /// 渐入渐出在段内某一刻的**线性**包络（0…1）。`elapsed` 是离段起点的时间线秒。
    ///
    /// 与两条管线同一种曲线（`setVolumeRamp` / `afade=tri` 都是线性），波形和
    /// 电平表画「听到的声音」时用它，别再各写一份 min(…)。
    func linearEnvelope(atElapsed elapsed: Double, span: Double) -> Double {
        var envelope = 1.0
        if fadeIn > 0, elapsed < fadeIn {
            envelope = min(envelope, max(0, elapsed) / fadeIn)
        }
        if fadeOut > 0, elapsed > span - fadeOut {
            envelope = min(envelope, max(0, span - elapsed) / fadeOut)
        }
        return envelope
    }
}

// MARK: - 取值

extension EditClip {
    /// 画过音量曲线吗（至少一个点）。
    var hasVolumeCurve: Bool { !volumeCurve.isEmpty }

    /// 曲线在某个时间线时刻的值（dB）。没有曲线返回 nil。
    func curveDecibels(atTimeline time: Double) -> Double? {
        volumeCurve.value(atSourceTime: sourceTime(atTimeline: time))
    }

    /// 「那条线」此刻在哪（dB）：有曲线读曲线，没曲线就是 `volume`。
    /// 不含静音 —— 静音时线照样画在原处，只是整段灰掉。
    func volumeLineDecibels(atTimeline time: Double) -> Double {
        curveDecibels(atTimeline: time) ?? AudioGain.decibels(fromLinear: volume)
    }

    /// 这一刻**这段自己**的增益（线性幅度）：曲线或 `volume`，静音为 0。
    /// 不含渐入渐出、轨道推子和总推子（那三样由调用方各自乘）。
    func clipGain(atTimeline time: Double) -> Double {
        guard !isMuted else { return 0 }
        guard let decibels = curveDecibels(atTimeline: time) else { return volume }
        return AudioGain.linear(fromDecibels: decibels)
    }

    /// 时间线上真正听到的增益：段增益 × 用户设的渐入渐出 × `trackGain`。
    /// 波形条和静态爆音标记用它（主轨接缝上的转场仲裁不在这里，那是管线的事）。
    func heardGain(atTimeline time: Double, trackGain: Double) -> Double {
        let elapsed = time - timelineStart
        let envelope = audioFades.linearEnvelope(atElapsed: elapsed, span: timelineDuration)
        return clipGain(atTimeline: time) * envelope * trackGain
    }
}

// MARK: - 编辑（纯值：给起手时的段，算松手后的段）

/// 音量点在源时间上的「同一个点」容差。
///
/// **不用关键帧的半帧容差**：放大到一帧 200pt 之后，半帧就是 100pt —— 两个点
/// 在屏幕上隔着一大段也会被当成同一个。声音要的是亚帧精度，这里只合并
/// 真正重合的点（半毫秒，按变速折到源时间）。
enum VolumeCurveEditing {
    static let timelineTolerance = 0.0005

    static func sourceTolerance(speed: Double) -> Double {
        timelineTolerance * max(abs(speed), 0.0001)
    }
}

extension EditClip {
    /// 段在源时间上的可见窗口（点只许加在 / 挪进这个范围）。
    var sourceWindow: ClosedRange<Double> {
        sourceStart...(sourceStart + max(0, sourceDuration))
    }

    /// 在时间线时刻 `time` 加一个点，值取**此刻线上的值** —— 加点这个动作本身
    /// 不改变任何声音，改声音的只有随后的拖动。第一个点也一样：一个点的曲线是
    /// 一条水平线（两端外夹紧），正好等于原来的 `volume`。
    mutating func addVolumePoint(atTimeline time: Double) {
        let source = min(max(sourceTime(atTimeline: time), sourceWindow.lowerBound), sourceWindow.upperBound)
        let decibels = AudioGain.clampedDecibels(volumeLineDecibels(atTimeline: timelineTime(atSource: source)))
        volumeCurve.set(decibels, atSourceTime: source,
                        tolerance: VolumeCurveEditing.sourceTolerance(speed: speed))
    }

    /// 删掉第 `index` 个点。删的是**最后一个**时把它的值固化进 `volume`：
    /// 线原地不动（同关键帧「删掉最后一帧不跳」那条）。
    mutating func removeVolumePoint(at index: Int) {
        let keys = volumeCurve.keys
        guard keys.indices.contains(index) else { return }
        if keys.count == 1 {
            volume = AudioGain.linear(fromDecibels: keys[0].value)
        }
        var remaining = keys
        remaining.remove(at: index)
        volumeCurve = KeyframeTrack(keys: remaining)
    }

    /// 把第 `index` 个点挪到（时间线时刻 `time`, `decibels`）。
    ///
    /// 时间夹在左右邻点之间（不许越过邻点 —— 越过就等于悄悄改了点的顺序）、
    /// 也夹在段的可见窗口里；dB 夹进 [−60, +6.02]。
    mutating func moveVolumePoint(at index: Int, toTimeline time: Double, decibels: Double) {
        var keys = volumeCurve.keys
        guard keys.indices.contains(index) else { return }
        let gap = VolumeCurveEditing.sourceTolerance(speed: speed) * 2
        var low = sourceWindow.lowerBound
        var high = sourceWindow.upperBound
        if index > 0 { low = max(low, keys[index - 1].time + gap) }
        if index + 1 < keys.count { high = min(high, keys[index + 1].time - gap) }
        let source = sourceTime(atTimeline: time)
        keys[index].time = high >= low ? min(max(source, low), high) : keys[index].time
        keys[index].value = AudioGain.clampedDecibels(decibels)
        volumeCurve = KeyframeTrack(keys: keys)
    }

    /// 「这一刻底下是哪一段线」：返回要跟着一起上下平移的点的下标。
    ///
    /// - 两点之间 → 两端那两个点（拖一段线 = 这段整体上下，Logic 的手感）；
    /// - 第一个点之前 / 最后一个点之后 → 那一段是水平延长线，只动端点那一个；
    /// - 没有点 → 空数组，调用方改 `volume`（整条水平线）。
    func volumeSegmentIndices(atTimeline time: Double) -> [Int] {
        let keys = volumeCurve.keys
        guard !keys.isEmpty else { return [] }
        let source = sourceTime(atTimeline: time)
        guard let right = keys.firstIndex(where: { $0.time > source }) else { return [keys.count - 1] }
        return right == 0 ? [0] : [right - 1, right]
    }

    /// 把 `indices` 这几个点（空 = 整段的 `volume`）一起平移 `delta` dB。
    /// 每个点各自夹进合法区间 —— 顶到头的点停住，其余照走（反向拖回来能复原，
    /// 因为手势永远从起手那一份算，不在上一拍的结果上叠加）。
    mutating func shiftVolume(indices: [Int], byDecibels delta: Double) {
        guard delta.isFinite else { return }
        if indices.isEmpty {
            let decibels = AudioGain.decibels(fromLinear: volume)
            volume = AudioGain.linear(fromDecibels: AudioGain.clampedDecibels(decibels + delta))
            return
        }
        var keys = volumeCurve.keys
        for index in indices where keys.indices.contains(index) {
            keys[index].value = AudioGain.clampedDecibels(keys[index].value + delta)
        }
        volumeCurve = KeyframeTrack(keys: keys)
    }

    /// 整条线一起平移（检查器的音量滑杆、⌥ 拖整段）：有曲线平移所有点，
    /// 没曲线改 `volume`。
    mutating func shiftWholeVolume(byDecibels delta: Double) {
        shiftVolume(indices: Array(volumeCurve.keys.indices), byDecibels: delta)
    }

    /// 去掉整条曲线，回到画曲线之前的那条水平线（`volume` 在有曲线期间不动，
    /// 所以它就是加第一个点之前的值）。
    mutating func removeVolumeCurve() {
        volumeCurve = KeyframeTrack()
    }
}

// MARK: - 画在块上的那条线：纵轴与命中（纯值，视图和自检共用）

/// 块上那条音量线的几何：纵轴是 **dB 线性**的 [−60, +6.02]（与检查器滑杆、推子同一个
/// 刻度 —— 曲线本身按 dB 线性插值，所以屏幕上的直线就是听到的那条线）。
enum VolumeCurveLayout {
    /// 上下各留几点：线顶到 +6 dB / 沉到 −∞ 时还看得见、够得着。
    static let inset = 3.0
    /// 波形区矮于这个值就不画线（矮到拖不准）。
    static let minimumHeight = 10.0
    /// 离线多近算「点在线上」、离点多近算「点在点上」（pt）。
    static let lineHitRadius = 5.0
    static let pointHitRadius = 7.0

    static func y(forDecibels decibels: Double, height: Double) -> Double {
        inset + (1 - AudioGain.scaleFraction(forDecibels: decibels)) * max(0, height - 2 * inset)
    }

    static func decibels(forY y: Double, height: Double) -> Double {
        AudioGain.decibels(forScaleFraction: 1 - (y - inset) / max(1, height - 2 * inset))
    }

    /// 线在块里的折点（块内 x，y）：段的两端 + 落在段内的每个点。没有点就是一条水平线。
    static func vertices(for clip: EditClip, pps: Double, height: Double) -> [CGPoint] {
        let span = clip.timelineDuration
        guard span > 0, pps > 0 else { return [] }
        var xs: [Double] = [0, span * pps]
        for key in clip.volumeCurve.keys {
            let x = (clip.timelineTime(atSource: key.time) - clip.timelineStart) * pps
            if x > 0, x < span * pps { xs.append(x) }
        }
        return xs.sorted().map { x in
            CGPoint(x: x, y: y(forDecibels: clip.volumeLineDecibels(atTimeline: clip.timelineStart + x / pps),
                               height: height))
        }
    }

    /// 段内能看见、能抓的点：(在 `volumeCurve.keys` 里的下标, 块内位置)。
    static func handles(for clip: EditClip, pps: Double, height: Double) -> [(index: Int, point: CGPoint)] {
        let span = clip.timelineDuration
        return clip.volumeCurve.keys.enumerated().compactMap { index, key in
            let x = (clip.timelineTime(atSource: key.time) - clip.timelineStart) * pps
            guard x >= -0.5, x <= span * pps + 0.5 else { return nil }
            return (index, CGPoint(x: x, y: y(forDecibels: key.value, height: height)))
        }
    }

    /// 按在哪个点上（没有返回 nil）。离得最近的那个。
    static func handle(at location: CGPoint, clip: EditClip, pps: Double, height: Double) -> Int? {
        handles(for: clip, pps: pps, height: height)
            .map { ($0.index, hypot($0.point.x - location.x, $0.point.y - location.y)) }
            .filter { $0.1 <= pointHitRadius }
            .min { $0.1 < $1.1 }?.0
    }
}

// MARK: - 两条管线共用的折线表

/// 曲线 → 线性幅度的折线（片内线性）。
///
/// 曲线本身按 **dB 线性**插值（屏幕上画的直线 = 听到的那条线）；两条管线都只会
/// 画「幅度线性」的斜坡（`setVolumeRamp`、`aeval` 里的一次式），所以每段 dB
/// 直线要切成若干根弦。弦的最大误差 ≈ (0.1151·Δ)²/8（Δ = 一根弦跨的 dB 数），
/// 1.5 dB 一根时 ≈ 0.03 dB，耳朵听不出来。
///
/// **预览和导出吃同一张表**，所以它们之间没有这 0.03 dB —— 两边是同一条折线。
enum VolumeCurveSampling {
    static let maxDecibelStep = 1.5

    struct Breakpoint: Equatable, Sendable {
        /// 离段起点的**时间线**秒（变速之后）。
        var time: Double
        /// 线性幅度（静音段为 0）。
        var gain: Double
    }

    /// 覆盖整段 [0, timelineDuration] 的折线，首尾各一个点，中间按曲线的点和弦
    /// 细分。没有曲线时是 `volume` 的两点水平线（调用方一般走不到这里）。
    static func breakpoints(for clip: EditClip) -> [Breakpoint] {
        let span = clip.timelineDuration
        guard span > 0 else { return [] }
        let mute = clip.isMuted ? 0.0 : 1.0
        guard clip.hasVolumeCurve else {
            return [Breakpoint(time: 0, gain: clip.volume * mute),
                    Breakpoint(time: span, gain: clip.volume * mute)]
        }
        // 结点：段的两端 + 落在段内的每个点（换到时间线偏移）。
        var knots: [Double] = [0, span]
        for key in clip.volumeCurve.keys {
            let offset = clip.timelineTime(atSource: key.time) - clip.timelineStart
            if offset > 0, offset < span { knots.append(offset) }
        }
        knots.sort()
        var unique: [Double] = []
        for knot in knots where unique.last.map({ knot - $0 > 1e-9 }) ?? true {
            unique.append(knot)
        }

        func decibels(_ offset: Double) -> Double {
            AudioGain.clampedDecibels(
                clip.curveDecibels(atTimeline: clip.timelineStart + offset) ?? 0
            )
        }

        var result: [Breakpoint] = []
        for index in 0..<(unique.count - 1) {
            let a = unique[index]
            let b = unique[index + 1]
            let dbA = decibels(a)
            let dbB = decibels(b)
            let pieces = max(1, Int((abs(dbB - dbA) / maxDecibelStep).rounded(.up)))
            for step in 0..<pieces {
                let fraction = Double(step) / Double(pieces)
                result.append(Breakpoint(
                    time: a + (b - a) * fraction,
                    gain: AudioGain.linear(fromDecibels: dbA + (dbB - dbA) * fraction) * mute
                ))
            }
        }
        result.append(Breakpoint(time: span, gain: AudioGain.linear(fromDecibels: decibels(span)) * mute))
        return result
    }

    /// 折线在某个偏移处的值（片内线性，两端外夹紧）。自检和电平表用。
    static func gain(at offset: Double, in points: [Breakpoint]) -> Double {
        guard let first = points.first, let last = points.last else { return 1 }
        if offset <= first.time { return first.gain }
        if offset >= last.time { return last.gain }
        var low = 0
        var high = points.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if points[mid].time <= offset { low = mid } else { high = mid }
        }
        let a = points[low]
        let b = points[high]
        let span = b.time - a.time
        guard span > 1e-12 else { return b.gain }
        return a.gain + (b.gain - a.gain) * (offset - a.time) / span
    }
}

// MARK: - 轨道推子与总推子（取值口）

extension TimelineState {
    /// 某条轨的推子（线性）。越界的行回 1。
    func trackVolume(for slot: TrackSlot) -> Double {
        switch slot {
        case .main:
            return mainVolume
        case .overlay(let index):
            return overlayTracks.indices.contains(index) ? overlayTracks[index].volume : 1
        case .audio(let index):
            return audioTracks.indices.contains(index) ? audioTracks[index].volume : 1
        }
    }

    /// 写某条轨的推子。夹紧只在这一处（`AudioGain.clampedLinear`）。
    mutating func setTrackVolume(_ linear: Double, for slot: TrackSlot) {
        let value = AudioGain.clampedLinear(linear)
        switch slot {
        case .main:
            mainVolume = value
        case .overlay(let index):
            guard overlayTracks.indices.contains(index) else { return }
            overlayTracks[index].volume = value
        case .audio(let index):
            guard audioTracks.indices.contains(index) else { return }
            audioTracks[index].volume = value
        }
    }

    /// 某一段所在那条轨的推子（找不到这段 = 1）。
    func trackVolume(containingClip id: UUID) -> Double {
        guard let location = location(of: id) else { return 1 }
        return trackVolume(for: location.track)
    }

    /// 任何一段画了音量曲线（v19 判据之一，看存下来的数据）。
    var hasVolumeCurves: Bool {
        allClips.contains { $0.hasVolumeCurve }
    }

    /// 任何一个推子离开了 0 dB（v19 判据之二）。
    var hasMixerSettings: Bool {
        mainVolume != 1 || masterVolume != 1
            || overlayTracks.contains { $0.volume != 1 }
            || audioTracks.contains { $0.volume != 1 }
    }
}
