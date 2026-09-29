import Foundation
import SrtFlowCore

// MARK: - edit_clip：改一段（纯值）
//
// 管什么：挪（起点、换轨）、裁（素材里的入点 / 出点）、变速、音量、静音、隐藏、声音渐变、
// 画面怎么放进画布（裁切 + 摆放，算好的 `framing`），以及 V1 上的 ripple（这一段的尾巴动了多少，
// 后面的 V1 片段跟着动多少）。算在副本上，撞了别的段就抛 `Conflict`（调用方用短 id 说给 AI 听），
// 不改原来那份。
// 不管什么：参数怎么读、黑边和主体怎么找（AIClipTools）、裁切和摆放怎么算（AIFrameFit）、
// 放素材 / 切 / 删（AITimelineEdits）。
//
// 语义和拖把手不同，是有意的：AI 说的是**绝对值**（「入点改成 2.0 秒」），所以改入出点时
// 片段的起点不动（除非同时给了 start）；拖左把手则是连起点一起挪。两种都对，各自的用法不一样。

struct AIClipChange {
    var start: Double?
    var target: TrackDropTarget?
    var sourceIn: Double?
    var sourceOut: Double?
    var speed: Double?
    var volumeDB: Double?
    var muted: Bool?
    var hidden: Bool?
    var fadeIn: Double?
    var fadeOut: Double?
    /// 画面的裁切和摆放（AIFrameFit 算好的，两样一起换）。
    var framing: AIFrameFit.Framing?
    /// 旋转、不透明度、翻转、入场出场、音量曲线、声音场景、标记（AIClipDetails）。
    var details: AIClipDetails?
    var ripple = false
    /// 改素材窗口 / 速度时关键帧怎么办（默认留在原来的画面上，范围外的收成两头的值）。
    var keyframes: AIKeyframePolicy?
}

/// edit_clip 的 keyframes：机器不拖拽，意图用参数说（docs/architecture/keyframe-animation.md「AI 接口」）。
enum AIKeyframePolicy: String, CaseIterable {
    /// 动画留在原来的素材帧上（剪辑软件的惯例）；落到新窗口外面的帧收成两头的值，不留看不见的帧。
    case keepFrames = "keep_frames"
    /// 动画按新窗口等比重排：AI 换了素材窗口但还想要「整段慢推」时用。
    case stretch
    case clear
}

enum AIClipEdit {
    /// 撞上了同一条轨上的另一段。
    struct Conflict: Error {
        let other: EditClip
        let track: TrackSlot
    }

    /// 入点、出点超出素材一丁点（四舍五入的误差）就夹回来；超出多了才报错。
    static let tolerance = 0.05

    static func apply(
        _ change: AIClipChange, to id: UUID, linkage: Bool, stillDuration: Double, in original: TimelineState
    ) throws -> TimelineState {
        guard let clip = original.clip(with: id), let location = original.location(of: id) else {
            throw AIToolError("There is no clip with that id. Call get_timeline for current ids.")
        }
        var updated = clip
        try applySourceWindow(change, to: &updated, stillDuration: stillDuration)
        if let speed = change.speed { updated.speed = min(max(speed, 0.1), 8) }
        applyKeyframePolicy(change.keyframes ?? .keepFrames, from: clip, to: &updated, frameRate: original.frameRate)
        if let start = change.start { updated.timelineStart = max(0, start) }
        if let db = change.volumeDB {
            let target = AudioGain.clampedDecibels(db)
            if updated.hasVolumeCurve {
                // 曲线盖着 `volume`：整条曲线平移到「段开头那一点 = 给的 dB」（同检查器的滑杆）。
                updated.shiftWholeVolume(byDecibels: target - updated.volumeLineDecibels(atTimeline: updated.timelineStart))
            } else {
                updated.volume = AudioGain.linear(fromDecibels: target)
            }
        }
        if let muted = change.muted { updated.isMuted = muted }
        if let hidden = change.hidden { updated.isHidden = hidden }
        if let fadeIn = change.fadeIn { updated.fadeInDuration = max(0, fadeIn) }
        if let fadeOut = change.fadeOut { updated.fadeOutDuration = max(0, fadeOut) }
        if let framing = change.framing { try applyFraming(framing, to: &updated, frameRate: original.frameRate) }

        let destination = try destinationSlot(change.target, from: location.track, clip: clip)
        var state = original
        // 先拿掉、放进目标轨、最后再清空轨：顺序反过来的话，拿掉最后一段就把轨删了，
        // 后面几条上层轨的编号跟着错一位，「放进 V3」就放进了别的轨。
        var lane = state[track: location.track]
        lane.remove(at: location.clipIndex)
        state[track: location.track] = lane
        insert(updated, into: destination, state: &state)

        if linkage, let group = clip.linkGroup {
            for partner in original.allClips where partner.linkGroup == group && partner.id != id {
                state.update(partner.id) { follow(&$0, from: clip, to: updated) }
            }
        }
        if change.ripple, location.track.isMain, change.target == nil || change.target == .main {
            let delta = updated.timelineEnd - clip.timelineEnd
            let partners = linkage ? original.linkedClipIDs(of: id) : [id]
            AITimelineEdits.shiftMain(
                from: clip.timelineEnd, by: delta, excluding: partners.union([id]), linkage: linkage, in: &state
            )
        }
        if let details = change.details { try details.apply(to: id, in: &state, frameRate: original.frameRate) }
        state.pruneEmptyTracks()
        AITimelineEdits.sortLanes(&state)
        if let other = AITimelineEdits.conflict(for: id, in: state), let slot = state.location(of: id)?.track {
            throw Conflict(other: other, track: slot)
        }
        return state
    }

    /// 关键帧跟着素材窗口怎么走。速度变了范围不变，三种都是原样。
    private static func applyKeyframePolicy(
        _ policy: AIKeyframePolicy, from old: EditClip, to updated: inout EditClip, frameRate: ProjectFrameRate
    ) {
        guard let animation = updated.animation, !animation.isEmpty else { return }
        switch policy {
        case .clear:
            updated.animation = nil
        case .stretch:
            updated.animation = animation.stretched(from: old.sourceRange, to: updated.sourceRange)
        case .keepFrames:
            updated.animation = updated.clippingAnimation(frameRate: frameRate)
        }
    }

    /// 入点 / 出点。图片只看长度（素材是一段循环的静帧，最长 `stillDuration`）。
    private static func applySourceWindow(_ change: AIClipChange, to clip: inout EditClip, stillDuration: Double) throws {
        guard change.sourceIn != nil || change.sourceOut != nil else { return }
        let oldIn = clip.sourceStart
        let oldOut = clip.sourceStart + clip.sourceDuration
        if clip.isStillImage {
            let length = (change.sourceOut ?? oldOut) - (change.sourceIn ?? oldIn)
            guard length >= TimelineTrim.clipMinimumDuration else {
                throw AIToolError("An image must show for at least \(TimelineTrim.clipMinimumDuration) s.")
            }
            clip.sourceStart = 0
            clip.sourceDuration = min(length, stillDuration)
            return
        }
        var newIn = change.sourceIn ?? oldIn
        var newOut = change.sourceOut ?? oldOut
        let end = clip.assetDuration
        if newIn < 0 { guard newIn > -tolerance else { throw AIToolError("source_in cannot be negative.") }; newIn = 0 }
        if newOut > end {
            guard newOut - end < tolerance else {
                throw AIToolError("source_out \(newOut) s is past the end of the file (\(String(format: "%.2f", end)) s).")
            }
            newOut = end
        }
        guard newOut - newIn >= TimelineTrim.clipMinimumDuration else {
            throw AIToolError("source_out must be at least \(TimelineTrim.clipMinimumDuration) s after source_in.")
        }
        clip.sourceStart = newIn
        clip.sourceDuration = newOut - newIn
    }

    /// 裁切 + 摆放。铺满（`replacesMotion`）换掉原有的位置 / 大小关键帧、跟拍的写上新的；别的放法遇到位置 / 大小
    /// 做了关键帧动画的段不改：静态摆放会被关键帧盖掉，AI 以为改了其实没变。
    private static func applyFraming(_ framing: AIFrameFit.Framing, to clip: inout EditClip, frameRate: ProjectFrameRate) throws {
        guard !clip.isAudioOnly else { throw AIToolError("An audio clip has no picture to crop or place.") }
        if framing.replacesMotion {
            if var animation = clip.animation {
                animation.centerX = KeyframeTrack()
                animation.centerY = KeyframeTrack()
                animation.width = KeyframeTrack()
                animation.height = KeyframeTrack()
                clip.animation = animation.isEmpty ? nil : animation
            }
        } else if let animation = clip.animation,
                  !(animation.centerX.isEmpty && animation.centerY.isEmpty && animation.width.isEmpty && animation.height.isEmpty) {
            throw AIToolError(
                "This clip's position or size is animated with keyframes, so SrtFlow cannot place it from here. "
                + "Ask the user to remove the Position and Scale keyframes in the inspector first."
            )
        }
        clip.crop = framing.crop
        clip.placement = framing.placement
        guard !framing.follow.isEmpty else { return }
        var animation = clip.animation ?? ClipAnimation()
        let tolerance = KeyframeTrack.sourceTolerance(frameRate: frameRate, speed: clip.speed)
        for point in framing.follow {
            animation.centerX.set(Double(point.center.x), atSourceTime: point.time, tolerance: tolerance)
            animation.centerY.set(Double(point.center.y), atSourceTime: point.time, tolerance: tolerance)
        }
        clip.animation = animation
    }

    private static func destinationSlot(_ target: TrackDropTarget?, from current: TrackSlot, clip: EditClip) throws -> TrackSlot? {
        guard let target else { return current }
        switch target {
        case .main, .overlay, .newOverlayTop:
            guard !clip.isAudioOnly else { throw AIToolError("An audio clip can only go on an audio track (A1, A2…).") }
        case .audio, .newAudioBottom:
            guard clip.isAudioOnly else { throw AIToolError("A video or image clip can only go on a video track (V1, V2…).") }
        case .insertOverlay, .insertAudio:
            throw AIToolError("Use V1, V2… or A1, A2… as the track.")
        }
        switch target {
        case .main: return .main
        case .overlay(let index): return .overlay(index)
        case .audio(let index): return .audio(index)
        default: return nil   // 新开一条
        }
    }

    /// 放进目标轨；`slot` 为 nil = 新开一条（画面在最上面、声音在最下面）。
    private static func insert(_ clip: EditClip, into slot: TrackSlot?, state: inout TimelineState) {
        switch slot {
        case .main:
            state.mainClips.append(clip)
        case .overlay(let index) where state.overlayTracks.indices.contains(index):
            state.overlayTracks[index].clips.append(clip)
        case .audio(let index) where state.audioTracks.indices.contains(index):
            state.audioTracks[index].clips.append(clip)
        default:
            _ = state.insertLane(
                audio: clip.isAudioOnly,
                at: clip.isAudioOnly ? state.audioTracks.count : state.overlayTracks.count,
                clips: [clip]
            )
        }
    }

    /// 链接伙伴（分离出来的声音）跟着同样地挪、同样地裁、同样地变速。
    private static func follow(_ partner: inout EditClip, from old: EditClip, to new: EditClip) {
        partner.timelineStart = max(0, partner.timelineStart + (new.timelineStart - old.timelineStart))
        let headDelta = new.sourceStart - old.sourceStart
        let lengthDelta = new.sourceDuration - old.sourceDuration
        partner.sourceStart = min(max(0, partner.sourceStart + headDelta), partner.assetDuration)
        partner.sourceDuration = min(
            max(TimelineTrim.clipMinimumDuration, partner.sourceDuration + lengthDelta),
            max(TimelineTrim.clipMinimumDuration, partner.assetDuration - partner.sourceStart)
        )
        if new.speed != old.speed { partner.speed = new.speed }
    }
}
