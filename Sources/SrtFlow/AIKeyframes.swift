import CoreGraphics
import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - set_keyframes：给一段画面做关键帧动画（纯值）
//
// 管什么：AI 给位置 / 大小 / 旋转 / 不透明度各一串（时间线秒, 值），整行换掉；空列表去掉那一行；以及写回给 AI 看。
// 模型见 docs/architecture/keyframe-animation.md：关键帧锚在**源时间**上（段挪了、变速了跟着走），两帧之间直线插值，
// 同一帧的容差是半帧（`KeyframeTrack.sourceTolerance`，和检查器打关键帧同一把尺）。
// 不管什么：检查器那套「在播放头处打一帧」（VideoEditProject+Keyframes），提交和撤销（AITimelineTools / 路由）。
//
// 口径：
// - 位置 = 画面中心在画面上的位置（0…1，和 edit_clip 的 x / y 一样）；大小 = 相对默认布局（1 = 裁剩的画面完整放进画布，
//   和 edit_clip 的 scale 一样），存成宽、高两行。
// - 去掉一行只去掉关键帧，静态的位置 / 旋转 / 不透明度原样留着（检查器「清除」会连静态值一起复位，AI 这边不替它复位）。
// - 一行都不剩时 `animation` 回到 nil（没有动画的段走轻量路径）。

enum AIKeyframes {
    enum Property: String, CaseIterable {
        case position, scale, rotation, opacity
    }

    /// 每一行要换成的点（时间线秒 + 值；位置有两个值）。nil = 这一行不动；空 = 去掉这一行。
    struct Request {
        var position: [(time: Double, x: Double, y: Double)]?
        var scale: [(time: Double, value: Double)]?
        var rotation: [(time: Double, value: Double)]?
        var opacity: [(time: Double, value: Double)]?
        /// 时间是这一段的比例（0 = 第一帧、1 = 最后一帧），不是时间线秒：AI 不用自己拿四舍五入的秒去算段尾。
        var relative = false

        var isEmpty: Bool { position == nil && scale == nil && rotation == nil && opacity == nil }
    }

    static func parse(_ args: AIToolArguments) throws -> Request {
        var request = Request()
        request.relative = try args.bool("relative") ?? false
        request.position = try points("position", args).map { list in
            try list.enumerated().map { index, point in
                (try point.requiredDouble("time"), try required(point, "x", "position[\(index)]"), try required(point, "y", "position[\(index)]"))
            }
        }
        request.scale = try values("scale", "value", args)
        request.rotation = try values("rotation", "degrees", args)
        request.opacity = try values("opacity", "value", args)
        guard !request.isEmpty else { throw AIToolError("Pass at least one of position, scale, rotation, opacity.") }
        return request
    }

    private static func points(_ key: String, _ args: AIToolArguments) throws -> [AIToolArguments]? {
        try args.array(key).map { items in
            try items.enumerated().map { index, item in
                guard case .object = item else { throw AIToolError("\(key)[\(index)] must be an object with time and a value.") }
                return AIToolArguments(item)
            }
        }
    }

    private static func values(_ key: String, _ field: String, _ args: AIToolArguments) throws -> [(time: Double, value: Double)]? {
        try points(key, args).map { list in
            try list.enumerated().map { index, point in
                (try point.requiredDouble("time"), try required(point, field, "\(key)[\(index)]"))
            }
        }
    }

    private static func required(_ point: AIToolArguments, _ field: String, _ label: String) throws -> Double {
        guard let value = try point.double(field) else { throw AIToolError("\(label).\(field) is required.") }
        return value
    }

    /// 换上关键帧。`canvas` 算默认布局（大小的 1 倍）要用。
    static func apply(_ request: Request, to clip: inout EditClip, canvas: CGSize, frameRate: ProjectFrameRate) throws {
        guard !clip.isAudioOnly else { throw AIToolError("\(clip.name) is audio; it has no picture to animate.") }
        let tolerance = KeyframeTrack.sourceTolerance(frameRate: frameRate, speed: clip.speed)
        var animation = clip.animation ?? ClipAnimation()
        let current = clip
        func source(_ given: Double) throws -> Double {
            var time = given
            if request.relative {
                guard (-0.001...1.001).contains(given) else { throw AIToolError("With relative=true, keyframe times are fractions of the clip from 0 to 1; got \(given).") }
                time = current.timelineStart + min(max(given, 0), 1) * current.timelineDuration
            }
            guard time >= current.timelineStart - 0.001, time <= current.timelineEnd + 0.001 else {
                throw AIToolError("Keyframe time \(time) s is outside the clip (\(String(format: "%.2f", current.timelineStart))–\(String(format: "%.2f", current.timelineEnd)) s).")
            }
            // 段尾的四舍五入零头夹回段内：存下来的帧永远在这段用到的范围里。
            return min(max(current.sourceTime(atTimeline: time), current.sourceRange.lowerBound), current.sourceRange.upperBound)
        }
        if let position = request.position {
            animation.centerX = KeyframeTrack()
            animation.centerY = KeyframeTrack()
            for point in position {
                let at = try source(point.time)
                let range = AIFrameFit.centerRange   // 放大的画面中心可以出到 0–1 外边
                animation.centerX.set(min(max(point.x, range.lowerBound), range.upperBound), atSourceTime: at, tolerance: tolerance)
                animation.centerY.set(min(max(point.y, range.lowerBound), range.upperBound), atSourceTime: at, tolerance: tolerance)
            }
        }
        if let scale = request.scale {
            let base = clip.defaultPlacement(canvas: canvas)
            animation.width = KeyframeTrack()
            animation.height = KeyframeTrack()
            for point in scale {
                let at = try source(point.time)
                let factor = min(max(point.value, 0.02), 8)
                animation.width.set(base.width * factor, atSourceTime: at, tolerance: tolerance)
                animation.height.set(base.height * factor, atSourceTime: at, tolerance: tolerance)
            }
        }
        if let rotation = request.rotation {
            animation.rotation = KeyframeTrack()
            for point in rotation {
                animation.rotation.set(min(max(point.value, -360), 360), atSourceTime: try source(point.time), tolerance: tolerance)
            }
        }
        if let opacity = request.opacity {
            animation.opacity = KeyframeTrack()
            for point in opacity {
                animation.opacity.set(min(max(point.value, 0), 1), atSourceTime: try source(point.time), tolerance: tolerance)
            }
        }
        clip.animation = animation.isEmpty ? nil : animation
    }

    /// edit_clip 改了素材窗口 / 速度之后，关键帧怎么了（写进结果，AI 看不见时间线只能靠这一句）。
    static func editNote(policy: AIKeyframePolicy, old: EditClip, new: EditClip, frameRate: ProjectFrameRate) -> String? {
        guard let animation = old.animation, !animation.isEmpty else { return nil }
        let windowChanged = abs(old.sourceStart - new.sourceStart) > 0.0005 || abs(old.sourceDuration - new.sourceDuration) > 0.0005
        switch policy {
        case .clear:
            return "Keyframes removed (keyframes=clear)."
        case .stretch:
            return windowChanged ? "Keyframes re-timed to fill the new source window (keyframes=stretch)." : nil
        case .keepFrames:
            let tolerance = KeyframeTrack.sourceTolerance(frameRate: frameRate, speed: old.speed)
            let range = (new.sourceRange.lowerBound - tolerance)...(new.sourceRange.upperBound + tolerance)
            let outside = animation.allKeyTimes(tolerance: tolerance).filter { !range.contains($0) }.count
            guard outside > 0 else { return nil }
            return "\(outside) keyframe(s) sat outside the new source window (keyframes stay on their source frames) and now only "
                + "hold their edge values; keyframes=stretch keeps the motion, or call set_keyframes again."
        }
    }

    /// 写给 AI 看：每一行的点（时间线秒）。报的是**这段范围里实际播的**：范围外的帧收成两头的值（人手裁过的段
    /// 可能还留着范围外的帧，AI 不该看见负数的时刻）。没有关键帧是 nil。
    static func summary(_ clip: EditClip, canvas: CGSize, frameRate: ProjectFrameRate) -> JSONValue? {
        guard let animation = clip.clippingAnimation(frameRate: frameRate), !animation.isEmpty else { return nil }
        func time(_ source: Double) -> JSONValue { AIFormat.seconds(clip.timelineTime(atSource: source)) }
        func round(_ value: Double) -> JSONValue { .number((value * 1000).rounded() / 1000) }
        var object: [String: JSONValue] = [:]
        if !animation.centerX.isEmpty {
            object["position"] = .array(animation.centerX.keys.map { key in
                .array([time(key.time), round(key.value), round(animation.centerY.value(atSourceTime: key.time) ?? 0.5)])
            })
        }
        if !animation.width.isEmpty {
            let base = clip.defaultPlacement(canvas: canvas).width
            object["scale"] = .array(animation.width.keys.map { .array([time($0.time), round(base > 0 ? $0.value / base : 1)]) })
        }
        if !animation.rotation.isEmpty {
            object["rotation"] = .array(animation.rotation.keys.map { .array([time($0.time), round($0.value)]) })
        }
        if !animation.opacity.isEmpty {
            object["opacity"] = .array(animation.opacity.keys.map { .array([time($0.time), round($0.value)]) })
        }
        return .object(object)
    }
}
