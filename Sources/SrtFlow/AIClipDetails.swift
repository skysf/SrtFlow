import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - edit_clip 的其余设置：旋转、不透明度、翻转、入场出场、音量曲线、声音场景、标记（纯值）
//
// 管什么：这几样参数读成类型、互相冲突的挡掉，改一段时换上去（`apply`），以及写回给 AI 看（`summary`）。
// 能调现成规则的都调：声音场景走 `TimelineState.setSoundSceneKind / setSoundSceneValue`（检查器同一份），
// 标记走 `EditClip.addMarker`（半帧容差，和按 M 同一把尺子），曲线按音量线的容差去重、dB 走 `AudioGain` 夹紧。
// 不管什么：挪、裁、变速这些（AIClipEdit）、画面放法（AIFrameFit / AIFramingRequest）、关键帧（后面的工具）。
//
// 口径（和检查器一致的地方照抄，AI 多出来的写明）：
// - 旋转夹在 ±360°、不到 0.01° 算 0；不透明度 0…1。**这一行做了关键帧的段不改**（静态值会被关键帧盖掉），报错。
// - 入场 / 出场：种类和时长是一对（`kind == .none` ⟺ 时长 0，ClipPresetAnimation 的不变量）。只给时长、种类是 none
//   时当作「渐显 / 渐隐」；只给种类、原来时长是 0 时给默认 0.6 秒（同检查器选上效果时）。
// - 音量曲线：给的时间是时间线秒，存成源时间（跟着段走）；空列表 = 去掉曲线（`volume` 不动）。
// - 段上有曲线时 volume_db 整条曲线平移到「段开头那一点 = 给的 dB」（同检查器：播放头不在段里时以段开头为准）；
//   以前直接写 `volume`，被曲线盖着、听不出变化。

struct AIClipDetails {
    enum Scene: Equatable {
        case remove
        case set(SoundSceneKind, values: [WritableKeyPath<SoundScene, Double>: Double])
    }

    struct Marker: Equatable {
        var time: Double
        var note: String
        var color: MarkerColor
    }

    var rotation: Double?
    var opacity: Double?
    var flipHorizontal: Bool?
    var flipVertical: Bool?
    var entrance: ClipPresetKind?
    var entranceDuration: Double?
    var exit: ClipPresetKind?
    var exitDuration: Double?
    var intensity: Double?
    /// 时间线秒 → dB。空 = 去掉曲线。
    var volumeCurve: [(time: Double, decibels: Double)]?
    var scene: Scene?
    var markers: [Marker]?

    var touchesPicture: Bool {
        rotation != nil || opacity != nil || flipHorizontal != nil || flipVertical != nil || entrance != nil
            || entranceDuration != nil || exit != nil || exitDuration != nil || intensity != nil
    }

    var touchesSound: Bool { volumeCurve != nil || scene != nil }

    static let presetNames = ClipPresetKind.allCases.map(\.rawValue)
    static let sceneNames = ["none"] + SoundSceneKind.allCases.map(\.rawValue)

    init(_ args: AIToolArguments) throws {
        rotation = try args.double("rotation")
        opacity = try args.double("opacity").map { min(max($0, 0), 1) }
        flipHorizontal = try args.bool("flip_horizontal")
        flipVertical = try args.bool("flip_vertical")
        entrance = try args.choice("entrance", from: Self.presetNames).flatMap(ClipPresetKind.init(rawValue:))
        exit = try args.choice("exit", from: Self.presetNames).flatMap(ClipPresetKind.init(rawValue:))
        entranceDuration = try args.double("entrance_duration").map { max(0, $0) }
        exitDuration = try args.double("exit_duration").map { max(0, $0) }
        intensity = try args.double("animation_intensity")
        volumeCurve = try Self.curve(args)
        scene = try Self.scene(args)
        markers = try Self.markers(args)
        if volumeCurve?.isEmpty == false, args.has("volume_db") {
            throw AIToolError("Pass volume_curve or volume_db, not both (volume_db moves an existing curve up or down).")
        }
    }

    // MARK: 读参数

    private static func curve(_ args: AIToolArguments) throws -> [(time: Double, decibels: Double)]? {
        guard let items = try args.array("volume_curve") else { return nil }
        return try items.enumerated().map { index, item in
            let point = AIToolArguments(item)
            guard case .object = item else { throw AIToolError("volume_curve[\(index)] must be {\"time\": seconds, \"db\": dB}.") }
            return (try point.requiredDouble("time"), try point.requiredDouble("db"))
        }
    }

    private static func scene(_ args: AIToolArguments) throws -> Scene? {
        guard let raw = args.raw["sound_scene"], !raw.isNull else { return nil }
        if let name = raw.stringValue, name.lowercased() == "none" { return .remove }
        guard case .object = raw else {
            throw AIToolError("sound_scene must be {\"kind\": \"hall\", \"intensity\": 0.8, …} or \"none\".")
        }
        let fields = AIToolArguments(raw)
        guard let name = try fields.choice("kind", from: sceneNames) else { throw AIToolError("sound_scene.kind is required.") }
        guard let kind = SoundSceneKind(rawValue: name) else { return .remove }
        var values: [WritableKeyPath<SoundScene, Double>: Double] = [:]
        if let amount = try fields.double("intensity") { values[\.amount] = amount }
        let knobs: [(name: String, path: WritableKeyPath<SoundScene, Double>)] = kind.group == .speaker
            ? [("distortion", \.first), ("tone", \.second)]
            : [("room_size", \.first), ("distance", \.second)]
        let other = kind.group == .speaker ? ["room_size", "distance"] : ["distortion", "tone"]
        if let wrong = other.first(where: { fields.has($0) }) {
            throw AIToolError("\(wrong) does not apply to \(kind.rawValue); its knobs are \(knobs.map(\.name).joined(separator: " and ")).")
        }
        for knob in knobs {
            if let value = try fields.double(knob.name) { values[knob.path] = value }
        }
        return .set(kind, values: values)
    }

    private static func markers(_ args: AIToolArguments) throws -> [Marker]? {
        guard let items = try args.array("markers") else { return nil }
        let colors = MarkerColor.allCases.map(\.rawValue)
        return try items.enumerated().map { index, item in
            guard case .object = item else { throw AIToolError("markers[\(index)] must be {\"time\": seconds, \"note\": text}.") }
            let fields = AIToolArguments(item)
            let color = try fields.choice("color", from: colors).flatMap(MarkerColor.init(rawValue:)) ?? .red
            return Marker(time: try fields.requiredDouble("time"), note: try fields.string("note") ?? "", color: color)
        }
    }

    // MARK: 改一段

    /// 画面和声音两样先在段上改，声音场景在整份状态上改（调检查器那两个函数）。
    func apply(to id: UUID, in state: inout TimelineState, frameRate: ProjectFrameRate) throws {
        guard var clip = state.clip(with: id) else { throw AIToolError("There is no clip with that id.") }
        if touchesPicture, clip.isAudioOnly { throw AIToolError("\(clip.name) is audio; it has no picture to turn, fade or animate.") }
        if touchesSound, !clip.hasAudio { throw AIToolError("\(clip.name) has no sound.") }
        try applyPicture(to: &clip)
        try applyCurve(to: &clip)
        try applyMarkers(to: &clip, frameRate: frameRate)
        state.update(id) { $0 = clip }
        switch scene {
        case .remove?:
            state.setSoundSceneKind(nil, for: [id])
        case .set(let kind, let values)?:
            state.setSoundSceneKind(kind, for: [id])
            for (path, value) in values { state.setSoundSceneValue(path, to: value, for: [id]) }
        case nil:
            break
        }
    }

    private func applyPicture(to clip: inout EditClip) throws {
        let animation = clip.animation ?? ClipAnimation()
        if let rotation {
            guard animation.rotation.isEmpty else {
                throw AIToolError("This clip's rotation is animated with keyframes; change those instead (or remove them in the inspector).")
            }
            let clamped = min(max(rotation.isFinite ? rotation : 0, -360), 360)
            clip.rotationDegrees = abs(clamped) < 0.01 ? 0 : clamped
        }
        if let opacity {
            guard animation.opacity.isEmpty else {
                throw AIToolError("This clip's opacity is animated with keyframes; change those instead (or remove them in the inspector).")
            }
            clip.opacity = opacity
        }
        if let flipHorizontal { clip.flippedHorizontally = flipHorizontal }
        if let flipVertical { clip.flippedVertically = flipVertical }
        Self.setEdge(kind: entrance, duration: entranceDuration, preset: &clip.presetAnimation.entrance,
                     seconds: &clip.videoFadeInDuration)
        Self.setEdge(kind: exit, duration: exitDuration, preset: &clip.presetAnimation.exit,
                     seconds: &clip.videoFadeOutDuration)
        if let intensity {
            clip.presetAnimation.intensity = intensity
            clip.presetAnimation.clampToValidRange()
        }
    }

    /// 一侧的种类和时长一起改，守住「none ⟺ 0 秒」。
    static func setEdge(kind: ClipPresetKind?, duration: Double?, preset: inout ClipPresetKind, seconds: inout Double) {
        guard kind != nil || duration != nil else { return }
        var newKind = kind ?? preset
        var newSeconds = duration ?? seconds
        if kind == ClipPresetKind.none || duration == 0 {
            newKind = .none
            newSeconds = 0
        } else if newKind == .none {
            newKind = .fade
        }
        if newKind != .none, newSeconds <= 0 { newSeconds = ClipPresetAnimation.defaultDuration }
        preset = newKind
        seconds = newSeconds
    }

    private func applyCurve(to clip: inout EditClip) throws {
        guard let volumeCurve else { return }
        guard !volumeCurve.isEmpty else {
            clip.removeVolumeCurve()
            return
        }
        var track = KeyframeTrack()
        let tolerance = VolumeCurveEditing.sourceTolerance(speed: clip.speed)
        for point in volumeCurve {
            guard point.time >= clip.timelineStart - 0.001, point.time <= clip.timelineEnd + 0.001 else {
                throw AIToolError("volume_curve time \(point.time) s is outside the clip (\(String(format: "%.2f", clip.timelineStart))–\(String(format: "%.2f", clip.timelineEnd)) s).")
            }
            let source = min(max(clip.sourceTime(atTimeline: point.time), clip.sourceWindow.lowerBound), clip.sourceWindow.upperBound)
            track.set(AudioGain.clampedDecibels(point.decibels), atSourceTime: source, tolerance: tolerance)
        }
        clip.volumeCurve = track
    }

    private func applyMarkers(to clip: inout EditClip, frameRate: ProjectFrameRate) throws {
        guard let markers else { return }
        clip.markers = []
        let tolerance = KeyframeTrack.sourceTolerance(frameRate: frameRate, speed: clip.speed)
        for marker in markers {
            guard let id = clip.addMarker(atTimeline: marker.time, color: marker.color, tolerance: tolerance) else {
                throw AIToolError("A marker at \(marker.time) s is outside the clip or on top of another marker.")
            }
            if let index = clip.markers.firstIndex(where: { $0.id == id }) { clip.markers[index].text = marker.note }
        }
    }

    // MARK: 写给 AI 看

    /// 这一段的这些设置（默认的不写）。
    static func summary(_ clip: EditClip) -> [String: JSONValue] {
        var object: [String: JSONValue] = [:]
        if abs(clip.rotationDegrees) > 0.01 { object["rotation"] = AIFormat.seconds(clip.rotationDegrees) }
        if clip.opacity < 0.999 { object["opacity"] = AIFormat.seconds(clip.opacity) }
        if clip.flippedHorizontally { object["flip_horizontal"] = true }
        if clip.flippedVertically { object["flip_vertical"] = true }
        if clip.presetAnimation.entrance != .none {
            object["entrance"] = ["kind": .string(clip.presetAnimation.entrance.rawValue), "duration": AIFormat.seconds(clip.videoFadeInDuration)]
        }
        if clip.presetAnimation.exit != .none {
            object["exit"] = ["kind": .string(clip.presetAnimation.exit.rawValue), "duration": AIFormat.seconds(clip.videoFadeOutDuration)]
        }
        if clip.presetAnimation.usesIntensity { object["animation_intensity"] = AIFormat.seconds(clip.presetAnimation.intensity) }
        if clip.hasVolumeCurve {
            object["volume_curve"] = .array(clip.volumeCurve.keys.map {
                ["time": AIFormat.seconds(clip.timelineTime(atSource: $0.time)), "db": .number(($0.value * 10).rounded() / 10)]
            })
        }
        if let scene = clip.soundScene {
            let names = scene.kind.group == .speaker ? ("distortion", "tone") : ("room_size", "distance")
            object["sound_scene"] = [
                "kind": .string(scene.kind.rawValue), "intensity": AIFormat.seconds(scene.amount),
                names.0: AIFormat.seconds(scene.first), names.1: AIFormat.seconds(scene.second)
            ]
        }
        let visible = clip.visibleMarkers
        if !visible.isEmpty {
            object["markers"] = .array(visible.map { marker in
                var entry: [String: JSONValue] = ["time": AIFormat.seconds(clip.timelineTime(atSource: marker.sourceTime))]
                if !marker.text.isEmpty { entry["note"] = .string(marker.text) }
                if marker.color != .red { entry["color"] = .string(marker.color.rawValue) }
                return .object(entry)
            })
        }
        return object
    }
}
