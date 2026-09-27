import CoreGraphics
import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - get_timeline 的内容：把时间线写给 AI 看
//
// 管什么：一份 TimelineState → 一段 JSON（轨道、片段、文字、滤镜、字幕概况、画面）。
// 纯值，自检够得着（scripts/check-mcp.sh）。
// 不管什么：画面尺寸从哪来（调用方传，预览合成算好的那一份）、id 怎么缩短（AIShortIDs）。
//
// 写法上省 token：默认值不写（速度 1、音量 0 dB、没静音、没隐藏都不出现），
// 时间保留三位小数，路径在打开的文件夹里就写相对路径。

enum AITimelineSummary {
    struct Context {
        var ids: AIShortIDs
        /// 「打开的文件夹」：路径按它写成相对的。
        var workspace: URL?
        var playhead: Double
        var selection: [UUID]
        var renderSize: CGSize
    }

    static func make(_ state: TimelineState, _ context: Context) -> JSONValue {
        var tracks: [JSONValue] = [lane(.main, clips: state.mainClips, hidden: state.mainHidden, state: state, context)]
        for (index, lane) in state.overlayTracks.enumerated() {
            tracks.append(self.lane(.overlay(index), clips: lane.clips, hidden: lane.isHidden, state: state, context))
        }
        for (index, lane) in state.audioTracks.enumerated() {
            tracks.append(self.lane(.audio(index), clips: lane.clips, hidden: lane.isHidden, state: state, context))
        }
        var result: [String: JSONValue] = [
            "duration": AIFormat.seconds(state.duration),
            "playhead": AIFormat.seconds(context.playhead),
            "canvas": [
                "ratio": .string(state.canvasRatio == .auto ? "auto" : state.canvasRatio.title),
                "width": .number(Double(Int(context.renderSize.width))),
                "height": .number(Double(Int(context.renderSize.height)))
            ],
            "fps": .number(Double(state.frameRate.fps)),
            "tracks": .array(tracks),
            "texts": .array(state.textOverlays.map { text($0, context) }),
            "filters": .array(state.filters.map { filter($0, context) }),
            "subtitles": subtitles(state)
        ]
        if abs(state.masterVolume - 1) > 0.0001 { result["master_volume_db"] = AITrackSettings.decibels(state.masterVolume) }
        if !context.selection.isEmpty {
            result["selected"] = .array(context.selection.map { .string(context.ids.short($0)) })
        }
        return .object(result)
    }

    private static func lane(
        _ slot: TrackSlot, clips: [EditClip], hidden: Bool, state: TimelineState, _ context: Context
    ) -> JSONValue {
        var object: [String: JSONValue] = [
            "track": .string(AITrackName.name(of: slot)),
            "kind": .string(slot.isAudio ? "audio" : "video"),
            "clips": .array(clips.enumerated().map { index, clip in
                self.clip(clip, next: slot.isMain && index + 1 < clips.count ? clips[index + 1] : nil, context)
            })
        ]
        if hidden { object["hidden"] = true }
        if abs(state.trackVolume(for: slot) - 1) > 0.0001 { object["volume_db"] = AITrackSettings.decibels(state.trackVolume(for: slot)) }
        return .object(object)
    }

    static func clip(_ clip: EditClip, next: EditClip?, _ context: Context) -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(context.ids.short(clip.id)),
            "name": .string(clip.name),
            "file": .string(AIFormat.path(clip.stillImageURL ?? clip.sourceURL, relativeTo: context.workspace)),
            "kind": .string(clip.isStillImage ? "image" : (clip.isAudioOnly ? "audio" : "video")),
            "start": AIFormat.seconds(clip.timelineStart),
            "end": AIFormat.seconds(clip.timelineEnd),
            "source_in": AIFormat.seconds(clip.sourceStart),
            "source_out": AIFormat.seconds(clip.sourceStart + clip.sourceDuration)
        ]
        if abs(clip.speed - 1) > 0.0001 { object["speed"] = .number(clip.speed) }
        if abs(clip.volume - 1) > 0.0001 {
            object["volume_db"] = .number((AudioGain.decibels(fromLinear: clip.volume) * 10).rounded() / 10)
        }
        if clip.isMuted { object["muted"] = true }
        if clip.isHidden { object["hidden"] = true }
        if !clip.hasAudio, !clip.isStillImage { object["has_audio"] = false }
        if clip.fadeInDuration > 0 { object["fade_in"] = AIFormat.seconds(clip.fadeInDuration) }
        if clip.fadeOutDuration > 0 { object["fade_out"] = AIFormat.seconds(clip.fadeOutDuration) }
        if let group = clip.linkGroup { object["link_group"] = .string(String(group.uuidString.lowercased().prefix(6))) }
        if next != nil, clip.transitionAfter != .none {
            object["transition_after"] = [
                "type": .string(clip.transitionAfter.rawValue),
                "duration": AIFormat.seconds(clip.transitionDuration)
            ]
        }
        if !clip.isAudioOnly, let picture = picture(clip, canvas: context.renderSize, always: false) {
            object["picture"] = picture
        }
        for (key, value) in AIClipDetails.summary(clip) { object[key] = value }
        if let keyframes = AIKeyframes.summary(clip, canvas: context.renderSize) { object["keyframes"] = keyframes }
        return .object(object)
    }

    /// 画面怎么放在画布上（AIFrameFit 的读法）。默认布局、又正好盖满画面的段不写（省 token）；
    /// `always` 时照写（edit_clip 刚改过画面，AI 要看到结果）。
    static func picture(_ clip: EditClip, canvas: CGSize, always: Bool) -> JSONValue? {
        guard clip.info?.displaySize != nil, canvas.width > 0, canvas.height > 0 else { return nil }
        let summary = AIFrameFit.describe(clip, canvas: canvas)
        guard always || !summary.isDefault || !summary.fillsFrame else { return nil }
        var object: [String: JSONValue] = ["fills_frame": .bool(summary.fillsFrame)]
        if !summary.isDefault || always {
            object["x"] = AIFormat.seconds(summary.x)
            object["y"] = AIFormat.seconds(summary.y)
            object["scale"] = AIFormat.seconds(summary.scale)
        }
        if summary.stretched { object["stretched"] = true }
        if let crop = summary.crop {
            object["crop"] = [
                "left": AIFormat.seconds(crop.leading), "right": AIFormat.seconds(crop.trailing),
                "top": AIFormat.seconds(crop.top), "bottom": AIFormat.seconds(crop.bottom)
            ]
        }
        return .object(object)
    }

    private static func text(_ overlay: TextOverlay, _ context: Context) -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(context.ids.short(overlay.id)),
            "text": .string(overlay.number != nil ? overlay.settledText : overlay.text),
            "start": AIFormat.seconds(overlay.timelineStart),
            "end": AIFormat.seconds(overlay.timelineEnd),
            "x": AIFormat.seconds(overlay.centerX),
            "y": AIFormat.seconds(overlay.centerY),
            "font": .string(overlay.style.fontName),
            "font_size": .number(overlay.style.fontSize.rounded()),
            "color": .string(AIColor.hex(overlay.style.fill.primaryColor))
        ]
        if overlay.number != nil { object["kind"] = "number" }
        if overlay.animation.entrance != .none { object["animation_in"] = .string(overlay.animation.entrance.rawValue) }
        if overlay.animation.exit != .none { object["animation_out"] = .string(overlay.animation.exit.rawValue) }
        if overlay.isHidden { object["hidden"] = true }
        return .object(object)
    }

    private static func filter(_ filter: FilterClip, _ context: Context) -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(context.ids.short(filter.id)),
            "preset": .string(filter.preset.rawValue),
            "start": AIFormat.seconds(filter.timelineStart),
            "end": AIFormat.seconds(filter.timelineEnd),
            "strength": AIFormat.seconds(filter.strength)
        ]
        if filter.layer > 0 { object["layer"] = .number(Double(filter.layer)) }
        if filter.isHidden { object["hidden"] = true }
        return .object(object)
    }

    private static func subtitles(_ state: TimelineState) -> JSONValue {
        let companion = state.subtitleCompanion
        var object: [String: JSONValue] = [:]
        let original = state.subtitleCues(of: .original)
        if state.subtitle != nil {
            var track: [String: JSONValue] = ["lines": .number(Double(original.count))]
            if let language = companion?.sourceLanguage { track["language"] = .string(language) }
            if state.subtitleHidden { track["hidden"] = true }
            object["original"] = .object(track)
        }
        let translated = state.subtitleCues(of: .translation)
        if !translated.isEmpty {
            var track: [String: JSONValue] = ["lines": .number(Double(translated.count))]
            if let language = companion?.targetLanguage { track["language"] = .string(language) }
            if state.translationHidden { track["hidden"] = true }
            object["translation"] = .object(track)
        }
        return .object(object)
    }
}
