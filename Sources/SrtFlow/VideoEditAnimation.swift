import Foundation
import SrtFlowCore

// MARK: - 关键帧动画（Transform 面板四行：位置/缩放/旋转/不透明度）
//
// 关键帧锚在**源时间**上（和 `sourceStart` 同一把尺）：变速时动画跟着素材
// 压缩/拉伸，裁头尾时留在原来的画面上，分割后两半各自播放自己窗口里的段落，
// 接缝处数值天然连续 —— 全都不需要特判。时间线时刻 ↔ 源时刻的换算见
// `EditClip.sourceTime(atTimeline:)`。

/// 一个关键帧：源时刻 + 值 + 到下一帧那一段的曲线。
struct Keyframe: Hashable, Sendable {
    var time: Double
    var value: Double
    /// 从这一帧到**下一帧**那一段用什么曲线（最后一帧的没用）。老工程没有这个键 = linear（VideoEditKeyframeEasing.swift）。
    var easing: KeyframeEasing = .linear

    init(time: Double, value: Double, easing: KeyframeEasing = .linear) {
        self.time = time
        self.value = value
        self.easing = easing
    }
}

/// 一条属性的关键帧轨：按时间升序，两帧之间按起点那帧的曲线插值（默认线性），两端外夹紧。
struct KeyframeTrack: Hashable, Sendable {
    private(set) var keys: [Keyframe] = []

    /// 半帧以内算同一帧：反复写同一时刻是替换不是堆积。
    ///
    /// **容差要分空间**（关键，容易写错）：
    /// - 本类型的 `keys[].time` 是 **source time**（素材内时间，锚定素材本身，
    ///   变速/分割后依然正确）。source time 比 timeline time 快 `speed` 倍，
    ///   所以「timeline 上的半帧」在 source 空间里是 `半帧 × |speed|`。
    /// - 而 ‹ › 跳帧是先把 source time 映射回 timeline time 再比较的，
    ///   那一侧**只用工程半帧，不再乘 speed**（乘了就是重复折算）。
    ///
    /// 因此所有按时刻匹配的方法都要求显式传 tolerance —— 不给默认值，
    /// 逼调用方想清楚自己在哪个空间。
    ///
    /// 历史值是写死的 `1.0 / 60`，恰好等于 30 fps 的半帧；30 fps 工程行为不变。
    static func sourceTolerance(frameRate: ProjectFrameRate, speed: Double) -> Double {
        frameRate.halfFrameTolerance * max(abs(speed), 0.0001)
    }

    var isEmpty: Bool { keys.isEmpty }

    /// 插值取值（起点那帧的曲线；线性那条式子和以前逐位一致）；空轨返回 nil（用静态字段兜底）。
    func value(atSourceTime time: Double) -> Double? {
        guard let first = keys.first, let last = keys.last else { return nil }
        if time <= first.time { return first.value }
        if time >= last.time { return last.value }
        for index in 1..<keys.count where time <= keys[index].time {
            let a = keys[index - 1]
            let b = keys[index]
            let span = b.time - a.time
            guard span > 0.0001 else { return b.value }
            if a.easing == .linear {
                return a.value + (b.value - a.value) * (time - a.time) / span
            }
            return a.value + (b.value - a.value) * a.easing.apply((time - a.time) / span)
        }
        return last.value
    }

    /// 有没有哪一段不是线性（存盘要抬版本：VideoEditFormatVersion 的 v27）。
    var hasEasing: Bool { keys.contains { $0.easing != .linear } }

    /// 播到 `time` 正处在哪一段（首帧之前算第一段、末帧之后算最后一段）的起点那帧的下标；不到两帧没有段。
    func segmentIndex(atSourceTime time: Double) -> Int? {
        guard keys.count >= 2 else { return nil }
        let index = keys.lastIndex { $0.time <= time } ?? 0
        return min(index, keys.count - 2)
    }

    /// 播到 `time` 正处在的那一段的曲线；不到两帧 nil。
    func easing(atSourceTime time: Double) -> KeyframeEasing? {
        segmentIndex(atSourceTime: time).map { keys[$0].easing }
    }

    /// 换播到 `time` 正处在的那一段的曲线（检查器的曲线菜单）；不到两帧不动。
    mutating func setEasing(_ easing: KeyframeEasing, forSegmentAtSourceTime time: Double) {
        guard let index = segmentIndex(atSourceTime: time) else { return }
        keys[index].easing = easing
    }

    func key(atSourceTime time: Double, tolerance: Double) -> Keyframe? {
        keys.first { abs($0.time - time) < tolerance }
    }

    /// 写一帧：半帧内已有的只改值（曲线留着，给了 `easing` 才换）；没有的新加（曲线 = `easing`，默认线性）。
    mutating func set(_ value: Double, atSourceTime time: Double, tolerance: Double, easing: KeyframeEasing? = nil) {
        if let index = keys.firstIndex(where: { abs($0.time - time) < tolerance }) {
            keys[index].value = value
            if let easing { keys[index].easing = easing }
        } else {
            keys.append(Keyframe(time: time, value: value, easing: easing ?? .linear))
            keys.sort { $0.time < $1.time }
        }
    }

    /// 只换某一帧到下一帧那段的曲线（检查器的曲线菜单）；半帧内没有帧就不动。
    mutating func setEasing(_ easing: KeyframeEasing, atSourceTime time: Double, tolerance: Double) {
        guard let index = keys.firstIndex(where: { abs($0.time - time) < tolerance }) else { return }
        keys[index].easing = easing
    }

    mutating func remove(atSourceTime time: Double, tolerance: Double) {
        keys.removeAll { abs($0.time - time) < tolerance }
    }

    init(keys: [Keyframe] = []) {
        self.keys = keys.sorted { $0.time < $1.time }
    }

    /// 只留 [from, to] 里的帧，范围外的帧收成两头插值出来的帧：动画在这段里播出来一样，但没有落在范围外的帧
    /// （给 AI 的接口：报出来的、存下来的都不出段外，见 docs/architecture/keyframe-animation.md「AI 接口」）。
    func clipped(from: Double, to: Double, tolerance: Double) -> KeyframeTrack {
        guard let first = keys.first, let last = keys.last, from <= to else { return self }
        var inside = keys.filter { $0.time >= from - tolerance && $0.time <= to + tolerance }
        if first.time < from - tolerance, inside.first.map({ abs($0.time - from) >= tolerance }) ?? true,
           let value = value(atSourceTime: from) {
            // 切在一段中间：补出来的那帧接着用这一段的曲线（形状尽量保住）。
            let easing = keys.last { $0.time < from }?.easing ?? .linear
            inside.insert(Keyframe(time: from, value: value, easing: easing), at: 0)
        }
        if last.time > to + tolerance, inside.last.map({ abs($0.time - to) >= tolerance }) ?? true,
           let value = value(atSourceTime: to) {
            inside.append(Keyframe(time: to, value: value))
        }
        return KeyframeTrack(keys: inside)
    }

    /// 时刻从 `old` 等比挪到 `new`（换素材窗口时保住动画的形状：edit_clip 的 keyframes=stretch）。
    func stretched(from old: ClosedRange<Double>, to new: ClosedRange<Double>) -> KeyframeTrack {
        let oldSpan = old.upperBound - old.lowerBound
        let newSpan = new.upperBound - new.lowerBound
        guard oldSpan > 0.0001 else {
            return KeyframeTrack(keys: keys.map { Keyframe(time: new.lowerBound, value: $0.value, easing: $0.easing) })
        }
        return KeyframeTrack(keys: keys.map { key in
            Keyframe(time: new.lowerBound + (key.time - old.lowerBound) / oldSpan * newSpan, value: key.value, easing: key.easing)
        })
    }
}

/// 一段剪辑的全部动画轨。Position 行写 centerX+centerY，Scale 行写
/// width+height（都是 `ClipPlacement` 的归一化量），另加旋转和不透明度。
struct ClipAnimation: Hashable, Sendable {
    var centerX = KeyframeTrack()
    var centerY = KeyframeTrack()
    var width = KeyframeTrack()
    var height = KeyframeTrack()
    var rotation = KeyframeTrack()
    var opacity = KeyframeTrack()

    var isEmpty: Bool {
        centerX.isEmpty && centerY.isEmpty && width.isEmpty
            && height.isEmpty && rotation.isEmpty && opacity.isEmpty
    }

    /// 六条轨里有没有哪一段不是线性（存盘要抬版本：VideoEditFormatVersion 的 v27）。
    var hasEasing: Bool { tracks.contains(where: \.hasEasing) }

    /// 六条轨（按检查器的顺序）。
    var tracks: [KeyframeTrack] { [centerX, centerY, width, height, rotation, opacity] }

    /// 六条轨一起裁到 [from, to] 里（`KeyframeTrack.clipped`）。
    func clipped(from: Double, to: Double, tolerance: Double) -> ClipAnimation {
        var copy = self
        copy.centerX = centerX.clipped(from: from, to: to, tolerance: tolerance)
        copy.centerY = centerY.clipped(from: from, to: to, tolerance: tolerance)
        copy.width = width.clipped(from: from, to: to, tolerance: tolerance)
        copy.height = height.clipped(from: from, to: to, tolerance: tolerance)
        copy.rotation = rotation.clipped(from: from, to: to, tolerance: tolerance)
        copy.opacity = opacity.clipped(from: from, to: to, tolerance: tolerance)
        return copy
    }

    /// 六条轨一起从 `old` 等比挪到 `new`（`KeyframeTrack.stretched`）。
    func stretched(from old: ClosedRange<Double>, to new: ClosedRange<Double>) -> ClipAnimation {
        var copy = self
        copy.centerX = centerX.stretched(from: old, to: new)
        copy.centerY = centerY.stretched(from: old, to: new)
        copy.width = width.stretched(from: old, to: new)
        copy.height = height.stretched(from: old, to: new)
        copy.rotation = rotation.stretched(from: old, to: new)
        copy.opacity = opacity.stretched(from: old, to: new)
        return copy
    }

    /// 每个关键帧的时刻经 `map` 换到另一条源时间轴上，值和**曲线**原样带着（预渲染的 matte 用的是另一份素材的源轴）。
    /// `map` 是线性的（时间线时刻进出两条源轴），一段两头之间的比例不变，带着曲线过去动起来一模一样；
    /// 漏了曲线，matte 按直线走、画面按曲线走，成片里动画中途边缘错开（docs/bugfixes/2026-10-05-overlay-matte-drops-keyframe-easing.md）。
    func remapped(_ map: (Double) -> Double) -> ClipAnimation {
        func convert(_ track: KeyframeTrack) -> KeyframeTrack {
            KeyframeTrack(keys: track.keys.map { Keyframe(time: map($0.time), value: $0.value) })  // 反向验证：故意撤掉曲线
        }
        return ClipAnimation(
            centerX: convert(centerX), centerY: convert(centerY), width: convert(width), height: convert(height),
            rotation: convert(rotation), opacity: convert(opacity)
        )
    }

    /// 所有轨的关键帧时刻去重升序（时间线块上画菱形、‹ › 跳帧用）。
    /// 这里比较的是 source time，去重容差要用 source 空间的（含 speed）。
    func allKeyTimes(tolerance: Double) -> [Double] {
        var times: [Double] = []
        for track in tracks {
            for key in track.keys
            where !times.contains(where: { abs($0 - key.time) < tolerance }) {
                times.append(key.time)
            }
        }
        return times.sorted()
    }
}

// MARK: - EditClip 的动画取值

extension EditClip {
    /// 这段用到的素材范围（源秒），关键帧的时间轴。
    var sourceRange: ClosedRange<Double> { sourceStart...max(sourceStart, sourceStart + sourceDuration) }

    /// 关键帧收进这段用到的范围里（AI 的接口：报出来的、存下来的都不出段外）。空了就是没动画。
    func clippingAnimation(frameRate: ProjectFrameRate) -> ClipAnimation? {
        guard let animation, !animation.isEmpty else { return nil }
        let clipped = animation.clipped(
            from: sourceRange.lowerBound, to: sourceRange.upperBound,
            tolerance: KeyframeTrack.sourceTolerance(frameRate: frameRate, speed: speed)
        )
        return clipped.isEmpty ? nil : clipped
    }

    /// 时间线时刻 → 源时刻（关键帧的时间轴）。
    func sourceTime(atTimeline time: Double) -> Double {
        sourceStart + (time - timelineStart) * speed
    }

    /// 源时刻 → 时间线时刻。
    func timelineTime(atSource source: Double) -> Double {
        timelineStart + (source - sourceStart) / speed
    }

    var isAnimated: Bool { !(animation?.isEmpty ?? true) }

    /// 此刻实际生效的摆放：动画轨逐分量覆盖在静态摆放（或默认布局）上。
    func animatedPlacement(atTimeline time: Double, canvas: CGSize) -> ClipPlacement {
        var base = resolvedPlacement(canvas: canvas)
        guard let animation else { return base }
        let source = sourceTime(atTimeline: time)
        if let value = animation.centerX.value(atSourceTime: source) { base.centerX = value }
        if let value = animation.centerY.value(atSourceTime: source) { base.centerY = value }
        if let value = animation.width.value(atSourceTime: source) { base.width = value }
        if let value = animation.height.value(atSourceTime: source) { base.height = value }
        return base
    }

    func animatedRotation(atTimeline time: Double) -> Double {
        guard let animation,
              let value = animation.rotation.value(atSourceTime: sourceTime(atTimeline: time)) else {
            return rotationDegrees
        }
        return value
    }

    func animatedOpacity(atTimeline time: Double) -> Double {
        guard let animation,
              let value = animation.opacity.value(atSourceTime: sourceTime(atTimeline: time)) else {
            return opacity
        }
        return min(max(value, 0), 1)
    }

    /// 全程最低不透明度（预览黑底轨的判定要看动画里的最小值，不是静态值）。
    var minimumOpacity: Double {
        if let track = animation?.opacity, !track.isEmpty {
            return track.keys.map(\.value).min() ?? opacity
        }
        return opacity
    }
}

// MARK: - 存盘（宽容解码，规则同工程文件其他部分）

extension Keyframe: Codable {
    private enum CodingKeys: String, CodingKey {
        case time, value, easing
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            time: try c.decodeIfPresent(Double.self, forKey: .time) ?? 0,
            value: try c.decodeIfPresent(Double.self, forKey: .value) ?? 0,
            easing: try c.decodeIfPresent(KeyframeEasing.self, forKey: .easing) ?? .linear
        )
    }

    /// `easing` 按需写：线性不落键（老工程存一轮 diff 是空的；v27 只在真有曲线时才抬）。
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(time, forKey: .time)
        try c.encode(value, forKey: .value)
        if easing != .linear { try c.encode(easing, forKey: .easing) }
    }
}

extension KeyframeTrack: Codable {
    private enum CodingKeys: String, CodingKey {
        case keys
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(keys: try c.decodeIfPresent([Keyframe].self, forKey: .keys) ?? [])
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(keys, forKey: .keys)
    }
}

extension ClipAnimation: Codable {
    private enum CodingKeys: String, CodingKey {
        case centerX, centerY, width, height, rotation, opacity
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            centerX: try c.decodeIfPresent(KeyframeTrack.self, forKey: .centerX) ?? KeyframeTrack(),
            centerY: try c.decodeIfPresent(KeyframeTrack.self, forKey: .centerY) ?? KeyframeTrack(),
            width: try c.decodeIfPresent(KeyframeTrack.self, forKey: .width) ?? KeyframeTrack(),
            height: try c.decodeIfPresent(KeyframeTrack.self, forKey: .height) ?? KeyframeTrack(),
            rotation: try c.decodeIfPresent(KeyframeTrack.self, forKey: .rotation) ?? KeyframeTrack(),
            opacity: try c.decodeIfPresent(KeyframeTrack.self, forKey: .opacity) ?? KeyframeTrack()
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(centerX, forKey: .centerX)
        try c.encode(centerY, forKey: .centerY)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
        try c.encode(rotation, forKey: .rotation)
        try c.encode(opacity, forKey: .opacity)
    }
}
