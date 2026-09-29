import CoreGraphics
import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - 工具：edit_clip（改一段）、freeze_frame（定格）
//
// 管什么：参数读成一份 `AIClipChange` → 需要看画面的（去黑边、对准主体）先去看 → 在副本上用纯值规则
// 算好（AIClipEdit）→ 一次 `perform` 提交 → 选中它、播放头跳过去 → 结果（含画面现在怎么放）。
// 分两步给路由：`plan` 可以 await（抽帧、识别画面），`apply` 必须同步 —— 路由把它包在
// `AIUndoGrouping.step` 里，包的那一段不许有 await（docs/architecture/ai-control-mcp.md 第四节第 1 条）。
// 不管什么：规则本身（AIClipEdit、AIFrameFit）、说明文字（SrtFlowMCPKit/MCPTimelineTools.swift）。

@MainActor
enum AIClipTools {
    /// 看完画面、算好的一次修改；`apply` 时再按最新的工程提交。
    struct Plan {
        let id: UUID
        var change: AIClipChange
        /// 算裁切和摆放时用的画布：提交前变了（用户中途换了画面比例）就不提交，免得按旧画布摆。
        let canvas: CGSize
        /// 看画面看出来的东西，原样写进结果（黑边、主体在哪）。
        var findings: [String: JSONValue] = [:]
    }

    static func plan(_ args: AIToolArguments, _ project: VideoEditProject) async throws -> Plan {
        let state = project.state
        let ids = AIShortIDs(state: state)
        let id = try ids.resolve(try args.requiredString("clip_id"))
        guard let clip = state.clip(with: id) else {
            throw AIToolError("\(ids.short(id)) is not a clip. Texts and filters are changed with set_text and set_filter.")
        }
        var change = AIClipChange()
        change.start = try args.double("start")
        change.target = try args.string("track").map { try AITrackName.target($0, in: state) }
        change.sourceIn = try args.double("source_in")
        change.sourceOut = try args.double("source_out")
        change.speed = try args.double("speed")
        change.volumeDB = try args.double("volume_db")
        change.muted = try args.bool("muted")
        change.hidden = try args.bool("hidden")
        change.fadeIn = try args.double("fade_in")
        change.fadeOut = try args.double("fade_out")
        change.ripple = try args.bool("ripple") ?? false
        change.keyframes = try args.choice("keyframes", from: MCPVocabulary.keyframePolicies).flatMap(AIKeyframePolicy.init(rawValue:))
        let canvas = VideoEditCompositionBuilder.renderSize(for: state)
        var plan = Plan(id: id, change: change, canvas: canvas)
        let details = try AIClipDetails(args)
        if details.touchesPicture || details.touchesSound || details.markers != nil { plan.change.details = details }
        let request = try AIFramingRequest(args)
        if request.touchesPicture {
            try requirePicture(clip)
            var usable: CGRect?
            if request.removeBlackBars {
                let bars = await AIPictureProbe.blackBars(of: clip)
                plan.findings["black_bars"] = AIBlackBars.json(bars)
                if let bars, !bars.isEmpty { usable = bars.active }
            }
            let crop = chosenCrop(request, usable: usable)
            var focus = request.focusPoint
            var followed: AIFrameFit.Framing?
            if request.fit == .fill, focus == nil, request.focus != .center,
               let found = await subjectFocus(
                   clip, canvas: canvas, active: AIFrameFit.region(of: crop ?? nil), textFirst: request.focus == .text,
                   follow: request.follow && request.focus != .text, frame: state.frameRate.secondsPerFrame * clip.speed
               ) {
                focus = found.point
                followed = found.followed
                plan.findings["subject"] = found.json
            }
            plan.change.framing = try followed ?? framing(request, clip: clip, canvas: canvas, crop: crop, focus: focus)
        }
        return plan
    }

    static func apply(_ plan: Plan, _ project: VideoEditProject) throws -> AIToolResult {
        let state = project.state
        let ids = AIShortIDs(state: state)
        if plan.change.framing != nil, VideoEditCompositionBuilder.renderSize(for: state) != plan.canvas {
            throw AIToolError("The frame shape changed while SrtFlow was looking at the clip. Call edit_clip again.")
        }
        let next: TimelineState
        do {
            next = try AIClipEdit.apply(
                plan.change, to: plan.id, linkage: project.linkageEnabled,
                stillDuration: StillImageClipFactory.stillDuration, in: state
            )
        } catch let conflict as AIClipEdit.Conflict {
            let other = conflict.other
            throw AIToolError("""
                That would overlap "\(other.name)" (\(ids.short(other.id)), \(String(format: "%.2f", other.timelineStart))–\
                \(String(format: "%.2f", other.timelineEnd)) s) on \(AITrackName.name(of: conflict.track)). \
                Move or trim that clip first, choose another start or track, or use ripple on V1.
                """)
        }
        // 什么都没变（没找到黑边、给的就是现在的值）：不提交，免得撤销栈里多一步空的。
        let changed = next != state
        if changed { project.perform { $0 = next } }
        let fresh = project.state
        guard let clip = fresh.clip(with: plan.id), let location = fresh.location(of: plan.id) else {
            return .ok(["changed": .string(ids.short(plan.id))], changed: true)
        }
        AIEditorPresenter.reveal(.init(clips: [plan.id], time: clip.timelineStart), project: project)
        let context = AITimelineSummary.Context(
            ids: AIShortIDs(state: fresh), workspace: AIWorkspace.shared.current, playhead: project.clock.time,
            selection: [], renderSize: VideoEditCompositionBuilder.renderSize(for: fresh)
        )
        var summary = AITimelineSummary.clip(clip, next: nil, context, frameRate: fresh.frameRate).objectValue ?? [:]
        summary["track"] = .string(AITrackName.name(of: location.track))
        if !clip.isAudioOnly, plan.change.framing != nil {
            summary["picture"] = AITimelineSummary.picture(clip, canvas: context.renderSize, always: true)
        }
        for (key, value) in plan.findings { summary[key] = value }
        if let old = state.clip(with: plan.id),
           let note = AIKeyframes.editNote(policy: plan.change.keyframes ?? .keepFrames, old: old, new: clip, frameRate: fresh.frameRate) {
            summary["keyframes_note"] = .string(note)
        }
        if !changed { summary["unchanged"] = true }
        return .ok(.object(summary), changed: changed)
    }

    // MARK: 画面怎么放

    private static func requirePicture(_ clip: EditClip) throws {
        guard !clip.isAudioOnly else { throw AIToolError("\(clip.name) is audio; it has no picture to crop or place.") }
        guard clip.info?.displaySize != nil else {
            throw AIToolError("SrtFlow does not know the picture size of \(clip.name) yet. Try again in a moment.")
        }
    }

    /// 这次的裁切：手动裁切和去黑边二选一（AIFramingRequest 挡过），哪个给了就是哪个。
    /// 外层 nil = 两个都没给（按位置摆时沿用原来的裁切）；里层 nil = 不裁。
    private static func chosenCrop(_ request: AIFramingRequest, usable: CGRect?) -> ClipCrop?? {
        request.crop.map { AIFrameFit.crop(keeping: AIFrameFit.region(of: $0)) }
            ?? usable.map { AIFrameFit.crop(keeping: $0) }
    }

    /// 铺满时对准的主体；主体走动大、`follow` 开着就跟着走（`followed`：带位置关键帧的放法，第四块；`frame` = 一帧是几个源秒，
    /// 换镜头处两个关键帧隔这么远）。
    /// 不用裁（素材和画布同比例）就不去认；认不出来时写一句「照正中铺」、点是正中。
    private static func subjectFocus(
        _ clip: EditClip, canvas: CGSize, active: CGRect, textFirst: Bool, follow: Bool, frame: Double
    ) async -> (point: CGPoint, json: JSONValue, followed: AIFrameFit.Framing?)? {
        guard let display = clip.info?.displaySize else { return nil }
        let centre = CGPoint(x: active.midX, y: active.midY)
        let window = AIFrameFit.fillWindow(display: display, canvas: canvas, active: active, focus: centre)
        guard abs(window.width - active.width) > 0.001 || abs(window.height - active.height) > 0.001 else { return nil }
        let samples = await AIPictureProbe.subjectSamples(of: clip)
        let subject = AISubjectFocus.combine(samples.map(\.findings), window: window.size, textFirst: textFirst)
        var followed: AIFrameFit.Framing?
        if follow, !clip.isStillImage {
            let targets = AIFollowSubject.targets(samples, window: window.size)
            if AIFollowSubject.needsFollow(targets, window: window.size) {
                let cuts = await AIShotScan.cuts(of: clip)
                let path = AIFollowSubject.path(targets.points, window: window.size, active: active, cuts: cuts, frame: frame)
                followed = AIFollowSubject.framing(path, window: window.size)
            }
        }
        let json = AIPictureProbe.json(subject, window: window.size, followKeyframes: followed.map { $0.follow.count })
        return (subject?.point ?? centre, json, followed)
    }

    /// 按 AI 说的算出裁切和摆放。`crop` 见 `chosenCrop`；`focus` 是铺满时窗对准的点（nil = 可用区域的正中）。
    private static func framing(
        _ request: AIFramingRequest, clip: EditClip, canvas: CGSize, crop: ClipCrop??, focus: CGPoint?
    ) throws -> AIFrameFit.Framing {
        switch request.fit {
        case .fit?:
            return AIFrameFit.fit(active: AIFrameFit.region(of: crop ?? nil))
        case .fill?:
            let active = AIFrameFit.region(of: crop ?? nil)
            let aim = focus ?? CGPoint(x: active.midX, y: active.midY)
            guard let filled = AIFrameFit.fill(clip, canvas: canvas, active: active, focus: aim) else {
                throw AIToolError("SrtFlow cannot fill the frame with \(clip.name).")
            }
            return filled
        case nil:
            return AIFrameFit.place(
                clip, canvas: canvas, crop: crop ?? clip.crop, x: request.x, y: request.y, scale: request.scale
            )
        }
    }

    // MARK: freeze_frame

    /// 定格：和手动定格同一条路（`VideoEditProject.freezeFrame` → `runFreeze`），提交那一下包进一步撤销。
    static func freeze(_ args: AIToolArguments, _ project: VideoEditProject) async throws -> AIToolResult {
        let state = project.state
        let ids = AIShortIDs(state: state)
        let time = try args.requiredDouble("time")
        let duration = min(max(try args.double("duration") ?? FreezeFrame.defaultDuration, 0.2), StillImageClipFactory.stillDuration)
        let clipID: UUID
        if let text = try args.string("clip_id") {
            clipID = try ids.resolve(text)
        } else {
            guard let clip = state.mainClips.first(where: { $0.contains(time: time) }) else {
                throw AIToolError("There is no V1 clip at \(time) s. Pass clip_id for a clip on another track.")
            }
            clipID = clip.id
        }
        let undo = project.effectiveUndoManager
        let outcome = await project.freezeFrame(clipID: clipID, at: time, duration: duration) { body in
            AIUndoGrouping.step(undo, body)
        }
        switch outcome {
        case .failed(let message):
            throw AIToolError(message)
        case .frozen(let id, let usedNearestFrame):
            let fresh = AIShortIDs(state: project.state)
            guard let clip = project.state.clip(with: id) else {
                return .ok(["freeze_id": .string(fresh.short(id))], changed: true)
            }
            AIEditorPresenter.reveal(.init(clips: [id], time: clip.timelineStart), project: project)
            var result: [String: JSONValue] = [
                "freeze_id": .string(fresh.short(id)),
                "start": AIFormat.seconds(clip.timelineStart),
                "end": AIFormat.seconds(clip.timelineEnd),
                "timeline_duration": AIFormat.seconds(project.state.duration),
                "note": "The clip was cut at that time and the still inserted; later clips on the same track moved right by its length."
            ]
            if usedNearestFrame { result["warning"] = "The clip has no frame exactly at that time; the nearest one was used." }
            // 静帧后面还剩一截短的原片（不到一帧的已经拿掉了，FreezeSliver）：多半是想收在这一帧上、定格早了几帧（2026-09-29 验收）。
            if let original = state.clip(with: clipID), let tail = project.state.allClips.first(where: {
                $0.id != id && $0.sourceURL == original.sourceURL && abs($0.timelineStart - clip.timelineEnd) < 0.001
            }), tail.timelineDuration < 1 {
                result["tail_id"] = .string(fresh.short(tail.id))
                result["tail_note"] = .string(String(
                    format: "%.2f s of the clip (with its sound) still plays after the still. To end on the still, delete tail_id with delete_items.",
                    tail.timelineDuration
                ))
            }
            return .ok(.object(result), changed: true)
        }
    }
}

