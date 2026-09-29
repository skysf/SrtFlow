import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - 工具：读时间线、放素材、切、删、转场
//
// 管什么：参数读成类型 → 在副本上用纯值规则算好（AITimelineEdits）→ 一次
// `perform` 提交（一个工具 = 一步撤销）→ 选中改到的、播放头跳过去 → 结果。
// 不管什么：规则本身（那个纯值文件）、改一段（AIClipTools）、说明文字（SrtFlowMCPKit/MCPTimelineTools.swift）。

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
        var summary = AITimelineSummary.make(state, context)
        let credits = AIAudioLibraryTools.projectCredits(state)
        if !credits.isEmpty, case .object(var object) = summary {
            object["music_credits"] = .array(credits.map { .string($0) })
            summary = .object(object)
        }
        return .ok(summary)
    }

    // MARK: add_clips

    private struct ClipRequest {
        /// 文件路径，或者音乐库里一首的 id（`library_id`，AIAudioLibraryTools）。两个只给一个。
        var url: URL?
        var libraryID: String?
        var sourceIn: Double?
        var sourceOut: Double?
        var track: String?
        var start: Double?

        var isSubtitle: Bool { url.map(MediaFileTypes.isSubtitle) ?? false }
    }

    static func addClips(_ args: AIToolArguments, _ project: VideoEditProject) async throws -> AIToolResult {
        guard let items = try args.array("clips"), !items.isEmpty else { throw AIToolError("clips is required.") }
        guard items.count <= 200 else { throw AIToolError("Add at most 200 clips per call.") }
        let requests = try items.enumerated().map { index, item -> ClipRequest in
            let entry = AIToolArguments(item)
            var request = ClipRequest(
                sourceIn: try entry.double("source_in"), sourceOut: try entry.double("source_out"),
                track: try entry.string("track"), start: try entry.double("start")
            )
            switch (try entry.string("file"), try entry.string("library_id")) {
            case (let path?, nil):
                let url = AIWorkspace.shared.resolve(path)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw AIToolError("clips[\(index)]: \(path) does not exist.")
                }
                request.url = url
            case (nil, let id?):
                request.libraryID = id
            default:
                throw AIToolError("clips[\(index)]: give either file or library_id.")
            }
            return request
        }
        if let ask = try AIWorkspace.shared.confirmReading(requests.compactMap(\.url), verb: "read", args: args, project: project) {
            return ask
        }
        // 字幕文件不占轨：挂成字幕轨（和把 .srt 拖进来同一条路，换掉原来的字幕），挂在下面放素材的那一步里。
        let subtitles = requests.compactMap { $0.isSubtitle ? $0.url : nil }
        guard subtitles.count <= 1 else { throw AIToolError("A project has one subtitle track; add one subtitle file at a time.") }
        let generation = project.documentGeneration
        var plans: [AITimelineEdits.PlannedClip] = []
        var images: [(id: UUID, url: URL)] = []
        var library: [UUID: AudioLibraryItem] = [:]
        for (index, request) in requests.enumerated() where !request.isSubtitle {
            var clip: EditClip
            var isAudio = true
            var name: String
            if let id = request.libraryID {
                let found = try await AIAudioLibraryTools.libraryClip(id: id)
                (clip, name) = (found.clip, found.item.title)
                library[clip.id] = found.item
                try trim(&clip, duration: found.item.duration, name: name, request: request, index: index)
            } else {
                guard let url = request.url, let media = await project.probeImports([url]).first else {
                    throw AIToolError("clips[\(index)]: SrtFlow cannot use \(request.url?.lastPathComponent ?? "it") as a clip.")
                }
                if media.kind == .image, !project.canConvertStills {
                    throw AIToolError("SrtFlow's video engine is still starting, so images cannot be added yet. Try again in a moment.")
                }
                (clip, isAudio, name) = (project.clip(for: media), media.kind == .audio, media.url.lastPathComponent)
                if media.kind == .image {
                    let length = request.sourceOut.map { $0 - (request.sourceIn ?? 0) } ?? VideoEditProject.importedImageDuration
                    clip.sourceDuration = min(max(length, TimelineTrim.clipMinimumDuration), StillImageClipFactory.stillDuration)
                    images.append((clip.id, media.url))
                } else {
                    try trim(&clip, duration: media.duration, name: name, request: request, index: index)
                }
            }
            guard project.isCurrentGeneration(generation) else {
                throw AIToolError("The project changed while the files were being read. Try again.")
            }
            let target = try request.track.map { try AITrackName.target($0, in: project.state) }
            try check(target, isAudio: isAudio, name: name, index: index)
            plans.append(.init(clip: clip, isAudio: isAudio, target: target, start: request.start))
        }
        let insert = try args.bool("insert") ?? false
        let linkage = project.linkageEnabled
        // 挂字幕和放素材是同一步（一次调用 = 一步撤销）。挂字幕要是落在这一步外面，App 在后台收不到事件，它按事件
        // 自动开的那一组一直关不上，之后 AI 的每一步都嵌进去，撤一步全空
        // （docs/bugfixes/2026-09-27-ai-undo-swallowed-by-subtitle-attach.md）。
        try AIUndoGrouping.step(project.effectiveUndoManager) {
            if let subtitle = subtitles.first {
                project.attachSubtitle(subtitle)
                guard project.state.subtitleURL == subtitle else {
                    throw AIToolError(project.notice ?? "SrtFlow could not read \(subtitle.lastPathComponent).")
                }
            }
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
            var entry: [String: JSONValue] = [
                "id": .string(ids.short(clip.id)),
                "track": .string(AITrackName.name(of: location.track)),
                "start": AIFormat.seconds(clip.timelineStart),
                "end": AIFormat.seconds(clip.timelineEnd)
            ]
            if let item = library[clip.id] {
                entry["library_id"] = .string(item.id)
                entry["title"] = .string(item.title)
            } else {
                entry["file"] = .string(AIWorkspace.shared.display(clip.stillImageURL ?? clip.sourceURL))
            }
            return .object(entry)
        }
        let firstStart = plans.compactMap { state.clip(with: $0.clip.id)?.timelineStart }.min()
        AIEditorPresenter.reveal(.init(clips: Set(plans.map(\.clip.id)), time: firstStart), project: project)
        var result: [String: JSONValue] = ["added": .array(added), "timeline_duration": AIFormat.seconds(state.duration)]
        if let subtitle = subtitles.first {
            result["subtitles"] = .string("\(subtitle.lastPathComponent) is now the subtitle track (\(state.subtitleCues(of: .original).count) lines).")
        }
        let credits = AIMusicCredits.lines(Array(library.values))
        if !credits.isEmpty { result["credits"] = .array(credits.map { .string($0) }) }
        // 声音比画面长（音乐库的一首不按工程裁短，方案第 23 条）：片长跟着拖长、后面是黑的，说一声（2026-09-29 验收：放上一首
        // 130 秒的曲子，片长变成 130 秒，AI 过了几步才发现）。
        let pictureEnd = state.allClips.filter { !$0.isAudioOnly }.map(\.timelineEnd).max() ?? 0
        let soundEnd = plans.filter(\.isAudio).compactMap { state.clip(with: $0.clip.id)?.timelineEnd }.max() ?? 0
        if pictureEnd > 0, soundEnd > pictureEnd + 0.5 {
            result["note"] = .string(String(
                format: "The sound runs to %.1f s, past the end of the picture at %.1f s, so the video goes on over a black screen: "
                    + "trim it with edit_clip (end) and fade it out (fade_out), unless you mean to add more picture.",
                soundEnd, pictureEnd
            ))
        }
        return .ok(.object(result), changed: true)
    }

    /// 用素材的哪一段（图片只有「放多久」，在上面单独算）。音乐库的一首按清单上的时长。
    private static func trim(_ clip: inout EditClip, duration: Double, name: String, request: ClipRequest, index: Int) throws {
        var start = request.sourceIn ?? 0
        var stop = request.sourceOut ?? duration
        if start < 0, start > -AIClipEdit.tolerance { start = 0 }
        if stop > duration, stop - duration < AIClipEdit.tolerance { stop = duration }
        guard start >= 0, stop <= duration else {
            throw AIToolError("clips[\(index)]: \(name) is \(String(format: "%.2f", duration)) s long; source_in/source_out must be inside that.")
        }
        guard stop - start >= TimelineTrim.clipMinimumDuration else {
            throw AIToolError("clips[\(index)]: source_out must be at least \(TimelineTrim.clipMinimumDuration) s after source_in.")
        }
        clip.sourceStart = start
        clip.sourceDuration = stop - start
    }

    private static func check(_ target: TrackDropTarget?, isAudio: Bool, name: String, index: Int) throws {
        guard let target else { return }
        switch (target, isAudio) {
        case (.audio, false), (.newAudioBottom, false):
            throw AIToolError("clips[\(index)]: \(name) has a picture, so it goes on a video track (V1, V2…).")
        case (.main, true), (.overlay, true), (.newOverlayTop, true):
            throw AIToolError("clips[\(index)]: \(name) is audio, so it goes on an audio track (A1, A2…).")
        default:
            return
        }
    }

    // MARK: set_track

    static func setTrack(_ args: AIToolArguments, _ project: VideoEditProject) throws -> AIToolResult {
        let name = try args.requiredString("track")
        let target = try AITrackSettings.target(name, in: project.state)
        let volumeDB = try args.double("volume_db")
        let hidden = try args.bool("hidden")
        guard volumeDB != nil || hidden != nil else { throw AIToolError("Pass volume_db and/or hidden.") }
        var next = project.state
        try AITrackSettings.apply(target, volumeDB: volumeDB, hidden: hidden, in: &next)
        // 只动推子是纯声音的改动，perform 自己会走只换混音的快路径（不重建画面）。
        project.perform { $0 = next }
        var result: [String: JSONValue] = [:]
        switch target {
        case .master:
            result["track"] = "master"
            result["volume_db"] = AITrackSettings.decibels(project.state.masterVolume)
        case .track(let slot):
            result["track"] = .string(AITrackName.name(of: slot))
            result["volume_db"] = AITrackSettings.decibels(project.state.trackVolume(for: slot))
            result["hidden"] = .bool(project.state.isLaneHidden(slot))
        }
        return .ok(.object(result), changed: true)
    }

    // MARK: set_keyframes

    static func setKeyframes(_ args: AIToolArguments, _ project: VideoEditProject) throws -> AIToolResult {
        let state = project.state
        let ids = AIShortIDs(state: state)
        let id = try ids.resolve(try args.requiredString("clip_id"))
        guard var clip = state.clip(with: id) else { throw AIToolError("\(ids.short(id)) is not a clip.") }
        let request = try AIKeyframes.parse(args)
        let canvas = VideoEditCompositionBuilder.renderSize(for: state)
        try AIKeyframes.apply(request, to: &clip, canvas: canvas, frameRate: state.frameRate)
        var next = state
        next.update(id) { $0 = clip }
        project.perform { $0 = next }
        AIEditorPresenter.reveal(.init(clips: [id], time: clip.timelineStart), project: project)
        var result: [String: JSONValue] = ["id": .string(ids.short(id))]
        result["keyframes"] = AIKeyframes.summary(clip, canvas: canvas) ?? "none"
        return .ok(.object(result), changed: true)
    }

    // MARK: duplicate_items

    static func duplicate(_ args: AIToolArguments, _ project: VideoEditProject) throws -> AIToolResult {
        let state = project.state
        let ids = AIShortIDs(state: state)
        guard let raw = try args.stringArray("ids"), !raw.isEmpty else { throw AIToolError("ids is required.") }
        let selection = try AIDuplicate.selection(try raw.map { try ids.resolve($0) }, in: state, linkage: project.linkageEnabled)
        let pointing: TrackSlot? = try args.string("track").map { name in
            switch try AITrackSettings.target(name, in: state) {
            case .track(let slot): return slot
            case .master: throw AIToolError("track must be V1, V2… or A1, A2….")
            }
        }
        var next = state
        let result = try AIDuplicate.apply(selection, to: &next, at: try args.double("start"), pointing: pointing)
        // 和 ⌘V 同一条路：一步撤销、粘完选中粘出来的、静帧没转完的照原图再转一次。
        project.perform(rebuildsPreview: !result.clips.isEmpty) { $0 = next }
        project.convertPastedStills(result.stillConversions)
        let fresh = AIShortIDs(state: project.state)
        let created = result.clips.union(result.shapes).union(result.texts).union(result.cues).union(result.filters)
        let starts = project.state.allClips.filter { result.clips.contains($0.id) }.map(\.timelineStart)
            + project.state.textOverlays.filter { result.texts.contains($0.id) }.map(\.timelineStart)
        AIEditorPresenter.reveal(.init(
            clips: result.clips, shapes: result.shapes, texts: result.texts, filters: result.filters, cues: result.cues,
            time: starts.min()
        ), project: project)
        return .ok([
            "new_ids": .array(created.map { .string(fresh.short($0)) }.sorted { ($0.stringValue ?? "") < ($1.stringValue ?? "") }),
            "timeline_duration": AIFormat.seconds(project.state.duration)
        ], changed: true)
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
}
