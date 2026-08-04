import Foundation

// MARK: - 关键帧动画（Transform 面板四行：位置/缩放/旋转/不透明度）
//
// 关键帧锚在**源时间**上（和 `sourceStart` 同一把尺）：变速时动画跟着素材
// 压缩/拉伸，裁头尾时留在原来的画面上，分割后两半各自播放自己窗口里的段落，
// 接缝处数值天然连续 —— 全都不需要特判。时间线时刻 ↔ 源时刻的换算见
// `EditClip.sourceTime(atTimeline:)`。

/// 一个关键帧：源时刻 + 值。
struct Keyframe: Hashable, Sendable {
    var time: Double
    var value: Double
}

/// 一条属性的关键帧轨：按时间升序，两帧之间线性插值，两端外夹紧。
struct KeyframeTrack: Hashable, Sendable {
    private(set) var keys: [Keyframe] = []

    /// 半帧（30fps 的一半）以内算同一帧：反复写同一时刻是替换不是堆积。
    static let timeTolerance = 1.0 / 60

    var isEmpty: Bool { keys.isEmpty }

    /// 线性插值取值；空轨返回 nil（用静态字段兜底）。
    func value(atSourceTime time: Double) -> Double? {
        guard let first = keys.first, let last = keys.last else { return nil }
        if time <= first.time { return first.value }
        if time >= last.time { return last.value }
        for index in 1..<keys.count where time <= keys[index].time {
            let a = keys[index - 1]
            let b = keys[index]
            let span = b.time - a.time
            guard span > 0.0001 else { return b.value }
            return a.value + (b.value - a.value) * (time - a.time) / span
        }
        return last.value
    }

    func key(atSourceTime time: Double) -> Keyframe? {
        keys.first { abs($0.time - time) < Self.timeTolerance }
    }

    mutating func set(_ value: Double, atSourceTime time: Double) {
        if let index = keys.firstIndex(where: { abs($0.time - time) < Self.timeTolerance }) {
            keys[index].value = value
        } else {
            keys.append(Keyframe(time: time, value: value))
            keys.sort { $0.time < $1.time }
        }
    }

    mutating func remove(atSourceTime time: Double) {
        keys.removeAll { abs($0.time - time) < Self.timeTolerance }
    }

    init(keys: [Keyframe] = []) {
        self.keys = keys.sorted { $0.time < $1.time }
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

    /// 所有轨的关键帧时刻去重升序（时间线块上画菱形、‹ › 跳帧用）。
    var allKeyTimes: [Double] {
        var times: [Double] = []
        for track in [centerX, centerY, width, height, rotation, opacity] {
            for key in track.keys
            where !times.contains(where: { abs($0 - key.time) < KeyframeTrack.timeTolerance }) {
                times.append(key.time)
            }
        }
        return times.sorted()
    }
}

// MARK: - EditClip 的动画取值

extension EditClip {
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
    func animatedPlacement(atTimeline time: Double, canvas: CGSize, isOverlay: Bool) -> ClipPlacement {
        var base = resolvedPlacement(canvas: canvas, isOverlay: isOverlay)
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
        case time, value
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            time: try c.decodeIfPresent(Double.self, forKey: .time) ?? 0,
            value: try c.decodeIfPresent(Double.self, forKey: .value) ?? 0
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(time, forKey: .time)
        try c.encode(value, forKey: .value)
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
