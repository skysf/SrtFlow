import Foundation
import SrtFlowCore

// MARK: - AI 改时间线的规则（纯值）
//
// 管什么：放素材、改一段（挪 / 裁 / 变速 / 音量…）、切、删、推 V1、设转场 —— 全部是
// `TimelineState` 上的纯函数，出错就抛，不改原来那份。调用方（AITimelineTools）在副本上算好，
// 再用 `project.perform { $0 = next }` 一次提交：一个工具 = 一步撤销，磁吸照常收尾。
// 自检够得着（scripts/check-mcp.sh）。
// 不管什么：参数怎么读、结果怎么写、预览跳到哪。
//
// 能复用的全复用手动操作那一份：落点走 `mediaImportLandings` + `insertImported`（撞上就往上抬一轨），
// 切走 `split(clipID:at:)`，转场能不能放问 `transitionCapacity`。AI 这边多出来的只有两条：
// 「给定绝对的起点 / 入出点」和「V1 往后推（insert / ripple）」—— 界面上是拖出来的，AI 要直接说。

enum AITimelineEdits {
    static let epsilon = 0.001

    // MARK: 放素材

    struct PlannedClip {
        var clip: EditClip
        var isAudio: Bool
        /// nil = 按类型默认：画面落 V1，声音落第一条放得下的音频轨。
        var target: TrackDropTarget?
        var start: Double?
    }

    /// 按顺序放一批素材。同一批里两段都要「新开一条轨」时，第二段放进第一段开的那条。只有**自己要了新开**的那一段
    /// 开出来的轨才记下 —— 前面一段只是因为还没有音频轨才开了 A1，后面点名 new_audio 的照样另开一条
    /// （docs/bugfixes/2026-09-28-new-audio-lands-on-a1.md）。
    static func place(_ plans: [PlannedClip], insert: Bool, linkage: Bool, in state: inout TimelineState) {
        var openedVideo: Int?
        var openedAudio: Int?
        for plan in plans {
            var target = plan.target ?? (plan.isAudio ? nil : .main)
            if target == .newOverlayTop, let index = openedVideo { target = .overlay(index) }
            if target == .newAudioBottom, let index = openedAudio { target = .audio(index) }
            let start = plan.start ?? defaultStart(for: target, in: state)
            if insert, plan.start != nil, target == .main {
                shiftMain(from: start, by: plan.clip.timelineDuration, excluding: [], linkage: linkage, in: &state)
            }
            let item = MediaImportItem(duration: plan.clip.timelineDuration, isAudio: plan.isAudio)
            let landings = state.mediaImportLandings([item], firstStart: start, preferring: target)
            state.insertImported([plan.clip], at: landings)
            if plan.target == .newOverlayTop, landings.first?.target == .newOverlayTop { openedVideo = state.overlayTracks.count - 1 }
            if plan.target == .newAudioBottom, landings.first?.target == .newAudioBottom { openedAudio = state.audioTracks.count - 1 }
        }
    }

    /// 没给起点时放在哪：接在那条轨最后一段后面；新开的轨和默认的声音从 0 开始。
    static func defaultStart(for target: TrackDropTarget?, in state: TimelineState) -> Double {
        switch target {
        case .main:
            return state.mainClips.map(\.timelineEnd).max() ?? 0
        case .overlay(let index) where state.overlayTracks.indices.contains(index):
            return state.overlayTracks[index].clips.map(\.timelineEnd).max() ?? 0
        case .audio(let index) where state.audioTracks.indices.contains(index):
            return state.audioTracks[index].clips.map(\.timelineEnd).max() ?? 0
        default:
            return 0
        }
    }

    // MARK: V1 往后推 / 往前拉

    /// V1 上从 `time` 起（含）的片段整体挪 `delta` 秒；链接开着时链接伙伴跟着挪。
    static func shiftMain(
        from time: Double, by delta: Double, excluding: Set<UUID>, linkage: Bool, in state: inout TimelineState
    ) {
        guard abs(delta) > epsilon else { return }
        let movers = state.mainClips
            .filter { $0.timelineStart >= time - epsilon && !excluding.contains($0.id) }
            .map(\.id)
        var ids = Set(movers)
        if linkage { for id in movers { ids.formUnion(state.linkedClipIDs(of: id)) } }
        ids.subtract(excluding)
        for id in ids { state.update(id) { $0.timelineStart = max(0, $0.timelineStart + delta) } }
        sortLanes(&state)
    }

    // MARK: 删

    struct Deletion {
        var clips: Set<UUID> = []
        var texts: Set<UUID> = []
        var filters: Set<UUID> = []
        var shapes: Set<UUID> = []
        var cues: Set<UUID> = []
    }

    /// 一批 id 认成要删的几类。**整批一起认**：有一个认不出就把认不出的都列出来、并说明一个都没删 ——
    /// 一个工具 = 一步撤销，删一半不删一半没法当一步退；只报第一个错的话 AI 以为前面的删掉了
    /// （2026-09-29 婚礼工程 ISSUE-21）。
    static func deletion(of raw: [String], in state: TimelineState) throws -> Deletion {
        let ids = AIShortIDs(state: state)
        var deletion = Deletion()
        var problems: [String] = []
        for text in raw {
            do {
                let id = try ids.resolve(text)
                switch AIItemKind.of(id, in: state) {
                case .clip: deletion.clips.insert(id)
                case .text: deletion.texts.insert(id)
                case .filter: deletion.filters.insert(id)
                case .shape: deletion.shapes.insert(id)
                case .subtitle: deletion.cues.insert(id)
                case nil: problems.append("Nothing in the project has id \"\(text)\".")
                }
            } catch let error as AIToolError {
                problems.append(error.message)
            }
        }
        guard problems.isEmpty else {
            throw AIToolError(
                problems.joined(separator: " ") + " Nothing was deleted (the batch is all-or-nothing): "
                    + "call get_timeline (or get_subtitles) for the current ids and call delete_items again."
            )
        }
        return deletion
    }

    /// 一次删完（和 ⌫ 同一口径：链接开着时带上链接伙伴）。`ripple`：删掉的 V1 片段留下的空，
    /// 由后面的 V1 片段往前补上 —— 只补被删那一段的长度，原来就有的空隙照样留着。
    static func delete(_ deletion: Deletion, ripple: Bool, linkage: Bool, in state: inout TimelineState) {
        var clipIDs = deletion.clips
        if linkage { for id in deletion.clips { clipIDs.formUnion(state.linkedClipIDs(of: id)) } }
        if ripple {
            // 从最晚的一段往前处理：后面先挪好，前面那一段再挪时会把它们一起带着走。
            let removed = state.mainClips.filter { clipIDs.contains($0.id) }
                .sorted { $0.timelineStart > $1.timelineStart }
            for clip in removed {
                let rest = state.mainClips.filter { !clipIDs.contains($0.id) && $0.timelineStart > clip.timelineStart + epsilon }
                guard let next = rest.min(by: { $0.timelineStart < $1.timelineStart }) else { continue }
                let delta = clip.timelineStart - min(next.timelineStart, clip.timelineEnd)
                shiftMain(from: next.timelineStart, by: delta, excluding: clipIDs, linkage: linkage, in: &state)
            }
        }
        for id in clipIDs { state.remove(id) }
        if !deletion.texts.isEmpty {
            state.textOverlays.removeAll { deletion.texts.contains($0.id) }
            state.compactTextRows()
        }
        if !deletion.filters.isEmpty {
            state.filters.removeAll { deletion.filters.contains($0.id) }
            state.compactFilterLayers()
        }
        if !deletion.shapes.isEmpty { state.shapes.removeAll { deletion.shapes.contains($0.id) } }
        if !deletion.cues.isEmpty {
            state.editSubtitleTracks { SubtitleTrackEditing.removeCues(ids: deletion.cues, original: &$0, companion: &$1) }
        }
    }

    // MARK: 切

    /// 在 `time` 切开这几段（链接开着时连伙伴一起切），返回新切出来的右半段。
    /// 没指定哪几段时切 V1 上压着这一刻的那段。
    static func split(at time: Double, ids: [UUID], linkage: Bool, in state: inout TimelineState) throws -> [UUID] {
        var seed = ids
        if seed.isEmpty {
            guard let main = state.mainClips.first(where: { $0.contains(time: time) }) else {
                throw AIToolError("No V1 clip is under \(time) s. Pass clip_ids, or pick a time inside a clip.")
            }
            seed = [main.id]
        }
        for id in seed where state.clip(with: id)?.contains(time: time) != true {
            throw AIToolError("Clip \(id.uuidString.prefix(8).lowercased()) does not cover \(time) s, so it cannot be cut there.")
        }
        var targets = Set(seed)
        if linkage { for id in seed { targets.formUnion(state.linkedClipIDs(of: id)) } }
        return LinkRegrouping.split(targets, at: time, in: &state)
    }

    // MARK: 转场

    /// 设 V1 上一条缝（或每一条相接的缝）的转场。返回设上了的出场段。
    static func setTransition(
        _ kind: ClipTransition, duration: Double?, after id: UUID?, all: Bool, in state: inout TimelineState
    ) throws -> [UUID] {
        let main = state.mainClips
        var indices: [Int] = []
        if all {
            indices = main.indices.dropLast().filter { index in
                TimelineState.transitionCapacity(outgoing: main[index], incoming: main[index + 1], kind: kind) != .notAdjacent
            }
            guard !indices.isEmpty else { throw AIToolError("No two V1 clips touch, so there is no cut to put a transition on.") }
        } else {
            guard let id, let index = main.firstIndex(where: { $0.id == id }) else {
                throw AIToolError("after_clip_id must be a clip on V1 (transitions only exist between V1 clips).")
            }
            guard index + 1 < main.count else { throw AIToolError("That is the last clip on V1; there is no clip after it.") }
            switch TimelineState.transitionCapacity(outgoing: main[index], incoming: main[index + 1], kind: kind) {
            case .notAdjacent:
                let gap = main[index + 1].timelineStart - main[index].timelineEnd
                throw AIToolError("The two clips do not touch (there is a \(String(format: "%.2f", gap)) s gap). Close the gap first.")
            case .tooShort:
                throw AIToolError("One of the two clips is too short for a transition.")
            case .available:
                indices = [index]
            }
        }
        for index in indices {
            let clip = state.mainClips[index]
            var seconds = duration ?? TimelineState.transitionDropDuration(existing: clip) ?? clip.transitionDuration
            if case .available(let maxDuration) = TimelineState.transitionCapacity(
                outgoing: clip, incoming: state.mainClips[index + 1], kind: kind
            ) {
                seconds = min(seconds, maxDuration)
            }
            state.mainClips[index].transitionAfter = kind
            state.mainClips[index].transitionDuration = min(max(seconds, 0.1), 3)
        }
        return indices.map { state.mainClips[$0].id }
    }

    // MARK: 共用

    /// 每条轨按时间排好（主轨「数组顺序 = 时间顺序」是硬不变量，别的轨也按它显示）。
    static func sortLanes(_ state: inout TimelineState) {
        state.sortMainClipsByStart()
        for index in state.overlayTracks.indices {
            state.overlayTracks[index].clips.sort { $0.timelineStart < $1.timelineStart }
        }
        for index in state.audioTracks.indices {
            state.audioTracks[index].clips.sort { $0.timelineStart < $1.timelineStart }
        }
    }

    /// 这一段和同一条轨上别的段撞了吗；V1 上转场本来就叠着的那一截不算撞。
    static func conflict(for id: UUID, in state: TimelineState) -> EditClip? {
        guard let location = state.location(of: id), let clip = state.clip(with: id) else { return nil }
        let lane = state[track: location.track].sorted { $0.timelineStart < $1.timelineStart }
        guard let index = lane.firstIndex(where: { $0.id == id }) else { return nil }
        for (otherIndex, other) in lane.enumerated() where other.id != id {
            let overlap = min(clip.timelineEnd, other.timelineEnd) - max(clip.timelineStart, other.timelineStart)
            guard overlap > epsilon else { continue }
            if location.track.isMain, abs(otherIndex - index) == 1 {
                let allowed = TimelineState.transitionOverlap(in: lane, afterIndex: min(index, otherIndex))
                if overlap <= allowed + epsilon { continue }
            }
            return other
        }
        return nil
    }
}
