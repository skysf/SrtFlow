import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - 工具：读时间线、放素材、改片段、切、删、转场
//
// 管什么：参数读成类型 → 在副本上用纯值规则算好（AITimelineEdits / AIClipEdit）→ 一次
// `perform` 提交（一个工具 = 一步撤销）→ 选中改到的、播放头跳过去 → 结果。
// 不管什么：规则本身（那两个纯值文件）、说明文字（SrtFlowMCPKit/MCPTimelineTools.swift）。

@MainActor
enum AITimelineTools {
    static func timeline(_ project: VideoEditProject) -> AIToolResult {
        let state = project.state
        let selection = Array(project.selectedClipIDs) + Array(project.selectedTextIDs) + Array(project.selectedFilterIDs)
        let context = AITimelineSummary.Context(
            ids: AIShortIDs(state: state),
            workspace: AIWorkspace.shared.current,
            playhead: project.clock.time,
            selection: selection,
            renderSize: VideoEditCompositionBuilder.renderSize(for: state)
        )
        return .ok(AITimelineSummary.make(state, context))
    }

    // MARK: add_clips

    private struct ClipRequest {
        var url: URL
        var sourceIn: Double?
        var sourceOut: Double?
        var track: String?
        var start: Double?
    }

    static func addClips(_ args: AIToolArguments, _ project: VideoEditProject) async throws -> AIToolResult {
        guard let items = try args.array("clips"), !items.isEmpty else { throw AIToolError("clips is required.") }
        guard items.count <= 200 else { throw AIToolError("Add at most 200 clips per call.") }
        let requests = try items.enumerated().map { index, item -> ClipRequest in
            let entry = AIToolArguments(item)
            let path = try entry.requiredString("file")
            let url = AIWorkspace.shared.resolve(path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw AIToolError("clips[\(index)]: \(path) does not exist.")
            }
            return ClipRequest(
                url: url, sourceIn: try entry.double("source_in"), sourceOut: try entry.double("source_out"),
                track: try entry.string("track"), start: try entry.double("start")
            )
        }
        let outside = requests.map(\.url).filter { !AIWorkspace.shared.allowsReading($0, project: project) }
        let action = "read:" + Set(outside.map(\.path)).sorted().joined(separator: "|")
        if !outside.isEmpty, !AIConfirmations.shared.consume(try args.string("confirm_token"), action: action) {
            let names = Set(outside.map(\.path)).sorted().prefix(5).joined(separator: ", ")
            return AIConfirmations.shared.ask(
                "SrtFlow needs to read files outside the folder you opened (\(names)). Allow it?", action: action
            )
        }
        // 字幕文件不占轨：挂成字幕轨（和把 .srt 拖进来同一条路，换掉原来的字幕，一步撤销）。
        let subtitles = requests.filter { MediaFileTypes.isSubtitle($0.url) }
        guard subtitles.count <= 1 else { throw AIToolError("A project has one subtitle track; add one subtitle file at a time.") }
        if let subtitle = subtitles.first {
            project.attachSubtitle(subtitle.url)
            guard project.state.subtitleURL == subtitle.url else {
                throw AIToolError(project.notice ?? "SrtFlow could not read \(subtitle.url.lastPathComponent).")
            }
        }
        let generation = project.documentGeneration
        var plans: [AITimelineEdits.PlannedClip] = []
        var images: [(id: UUID, url: URL)] = []
        for (index, request) in requests.enumerated() where !MediaFileTypes.isSubtitle(request.url) {
            guard let media = await project.probeImports([request.url]).first else {
                throw AIToolError("clips[\(index)]: SrtFlow cannot use \(request.url.lastPathComponent) as a clip.")
            }
            guard project.isCurrentGeneration(generation) else {
                throw AIToolError("The project changed while the files were being read. Try again.")
            }
            if media.kind == .image, !project.canConvertStills {
                throw AIToolError("SrtFlow's video engine is still starting, so images cannot be added yet. Try again in a moment.")
            }
            var clip = project.clip(for: media)
            try trim(&clip, media: media, request: request, index: index)
            let target = try request.track.map { try AITrackName.target($0, in: project.state) }
            try check(target, fits: media, index: index)
            plans.append(.init(clip: clip, isAudio: media.kind == .audio, target: target, start: request.start))
            if media.kind == .image { images.append((clip.id, media.url)) }
        }
        let insert = try args.bool("insert") ?? false
        let linkage = project.linkageEnabled
        AIUndoGrouping.step(project.effectiveUndoManager) {
            project.perform { AITimelineEdits.place(plans, insert: insert, linkage: linkage, in: &$0) }
        }
        // 图片和拖进来一样：先上轨，静帧视频在后台转，转完无感替换。
        for image in images {
            project.trackImportTask(Task { await project.convertStillClip(image.id, from: image.url, generation: generation) })
        }
        let state = project.state
        let ids = AIShortIDs(state: state)
        let added: [JSONValue] = plans.compactMap { plan in
            guard let clip = state.clip(with: plan.clip.id), let location = state.location(of: clip.id) else { return nil }
            return [
                "id": .string(ids.short(clip.id)),
                "file": .string(AIWorkspace.shared.display(clip.stillImageURL ?? clip.sourceURL)),
                "track": .string(AITrackName.name(of: location.track)),
                "start": AIFormat.seconds(clip.timelineStart),
                "end": AIFormat.seconds(clip.timelineEnd)
            ]
        }
        let firstStart = plans.compactMap { state.clip(with: $0.clip.id)?.timelineStart }.min()
        AIEditorPresenter.reveal(.init(clips: Set(plans.map(\.clip.id)), time: firstStart), project: project)
        var result: [String: JSONValue] = ["added": .array(added), "timeline_duration": AIFormat.seconds(state.duration)]
        if let subtitle = subtitles.first {
            result["subtitles"] = .string("\(subtitle.url.lastPathComponent) is now the subtitle track (\(state.subtitleCues(of: .original).count) lines).")
        }
        return .ok(.object(result), changed: true)
    }

    /// 用素材的哪一段。图片只有「放多久」（静帧最长 `StillImageClipFactory.stillDuration`）。
    private static func trim(_ clip: inout EditClip, media: MediaFileImport, request: ClipRequest, index: Int) throws {
        if media.kind == .image {
            let length = request.sourceOut.map { $0 - (request.sourceIn ?? 0) } ?? VideoEditProject.importedImageDuration
            clip.sourceDuration = min(max(length, TimelineTrim.clipMinimumDuration), StillImageClipFactory.stillDuration)
            return
        }
        var start = request.sourceIn ?? 0
        var stop = request.sourceOut ?? media.duration
        if start < 0, start > -AIClipEdit.tolerance { start = 0 }
        if stop > media.duration, stop - media.duration < AIClipEdit.tolerance { stop = media.duration }
        guard start >= 0, stop <= media.duration else {
            throw AIToolError("clips[\(index)]: \(media.url.lastPathComponent) is \(String(format: "%.2f", media.duration)) s long; source_in/source_out must be inside that.")
        }
        guard stop - start >= TimelineTrim.clipMinimumDuration else {
            throw AIToolError("clips[\(index)]: source_out must be at least \(TimelineTrim.clipMinimumDuration) s after source_in.")
        }
        clip.sourceStart = start
        clip.sourceDuration = stop - start
    }

    private static func check(_ target: TrackDropTarget?, fits media: MediaFileImport, index: Int) throws {
        guard let target else { return }
        switch (target, media.kind == .audio) {
        case (.audio, false), (.newAudioBottom, false):
            throw AIToolError("clips[\(index)]: \(media.url.lastPathComponent) has a picture, so it goes on a video track (V1, V2…).")
        case (.main, true), (.overlay, true), (.newOverlayTop, true):
            throw AIToolError("clips[\(index)]: \(media.url.lastPathComponent) is audio, so it goes on an audio track (A1, A2…).")
        default:
            return
        }
    }

    // MARK: edit_clip

    static func editClip(_ args: AIToolArguments, _ project: VideoEditProject) throws -> AIToolResult {
        let state = project.state
        let ids = AIShortIDs(state: state)
        let id = try ids.resolve(try args.requiredString("clip_id"))
        guard state.clip(with: id) != nil else {
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
        let next: TimelineState
        do {
            next = try AIClipEdit.apply(
                change, to: id, linkage: project.linkageEnabled,
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
        project.perform { $0 = next }
        guard let clip = project.state.clip(with: id), let location = project.state.location(of: id) else {
            return .ok(["changed": .string(ids.short(id))], changed: true)
        }
        AIEditorPresenter.reveal(.init(clips: [id], time: clip.timelineStart), project: project)
        var summary = AITimelineSummary.clip(clip, next: nil, summaryContext(project)).objectValue ?? [:]
        summary["track"] = .string(AITrackName.name(of: location.track))
        return .ok(.object(summary), changed: true)
    }

    // MARK: split / delete / transition

    static func split(_ args: AIToolArguments, _ project: VideoEditProject) throws -> AIToolResult {
        let time = try args.requiredDouble("time")
        let ids = AIShortIDs(state: project.state)
        let targets = try (args.stringArray("clip_ids") ?? []).map { try ids.resolve($0) }
        var next = project.state
        let created = try AITimelineEdits.split(at: time, ids: targets, linkage: project.linkageEnabled, in: &next)
        guard !created.isEmpty else { throw AIToolError("Nothing was cut at \(time) s.") }
        project.perform { $0 = next }
        let fresh = AIShortIDs(state: project.state)
        AIEditorPresenter.reveal(.init(clips: Set(created), time: time), project: project)
        return .ok(["new_clips": .array(created.map { .string(fresh.short($0)) }), "time": AIFormat.seconds(time)], changed: true)
    }

    static func delete(_ args: AIToolArguments, _ project: VideoEditProject) throws -> AIToolResult {
        let state = project.state
        let ids = AIShortIDs(state: state)
        guard let raw = try args.stringArray("ids"), !raw.isEmpty else { throw AIToolError("ids is required.") }
        var deletion = AITimelineEdits.Deletion()
        for text in raw {
            let id = try ids.resolve(text)
            switch AIItemKind.of(id, in: state) {
            case .clip: deletion.clips.insert(id)
            case .text: deletion.texts.insert(id)
            case .filter: deletion.filters.insert(id)
            case .shape: deletion.shapes.insert(id)
            case .subtitle: deletion.cues.insert(id)
            case nil: throw AIToolError("Nothing in the project has id \(text).")
            }
        }
        var next = state
        AITimelineEdits.delete(deletion, ripple: try args.bool("ripple") ?? false, linkage: project.linkageEnabled, in: &next)
        project.perform(rebuildsPreview: !deletion.clips.isEmpty) { $0 = next }
        project.clearSelection()
        return .ok(["deleted": .number(Double(raw.count)), "timeline_duration": AIFormat.seconds(project.state.duration)], changed: true)
    }

    static func transition(_ args: AIToolArguments, _ project: VideoEditProject) throws -> AIToolResult {
        guard let raw = try args.choice("type", from: MCPVocabulary.transitions), let kind = ClipTransition(rawValue: raw) else {
            throw AIToolError("type is required.")
        }
        let all = try args.bool("all") ?? false
        let ids = AIShortIDs(state: project.state)
        let after = try args.string("after_clip_id").map { try ids.resolve($0) }
        guard all || after != nil else { throw AIToolError("Pass after_clip_id, or all=true.") }
        var next = project.state
        let changed = try AITimelineEdits.setTransition(kind, duration: try args.double("duration"), after: after, all: all, in: &next)
        project.perform { $0 = next }
        let seam = changed.first.flatMap { project.state.clip(with: $0)?.timelineEnd }
        AIEditorPresenter.reveal(.init(clips: Set(changed), time: seam.map { max(0, $0 - 1) }), project: project)
        return .ok(["cuts": .number(Double(changed.count)), "type": .string(kind.rawValue)], changed: true)
    }

    static func summaryContext(_ project: VideoEditProject) -> AITimelineSummary.Context {
        AITimelineSummary.Context(
            ids: AIShortIDs(state: project.state), workspace: AIWorkspace.shared.current,
            playhead: project.clock.time, selection: [], renderSize: project.renderSize
        )
    }
}
