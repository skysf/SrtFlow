import Foundation
import SrtFlowCore

// MARK: - edit_subtitles：一批字幕改动（纯值）
//
// 管什么：把 AI 给的「改哪几句、加哪几句、删哪几句」读成类型、先全部验过（时间倒过来的、
// id 不是字幕的，一句都不改就报错），再用 `SubtitleTrackEditing` 那份两轨合同一次改完。
// 自检够得着（scripts/check-mcp.sh）。
// 不管什么：提交和给用户看（AISubtitleTools.edit）。

struct AISubtitleEdits {
    struct Change {
        var id: UUID
        var text: String?
        var start: Double?
        var end: Double?
    }

    struct Addition {
        var track: SubtitleTrack
        var start: Double
        var end: Double
        var text: String
    }

    var changes: [Change] = []
    var additions: [Addition] = []
    var deletions: Set<UUID> = []

    var isEmpty: Bool { changes.isEmpty && additions.isEmpty && deletions.isEmpty }

    static func parse(_ args: AIToolArguments, ids: AIShortIDs, in state: TimelineState) throws -> AISubtitleEdits {
        var edits = AISubtitleEdits()
        for (index, item) in (try args.array("changes") ?? []).enumerated() {
            let entry = AIToolArguments(item)
            let id = try ids.resolve(try entry.requiredString("id"))
            guard let cue = state.subtitleCue(id) else { throw AIToolError("changes[\(index)]: that id is not a subtitle line.") }
            let change = Change(id: id, text: try entry.string("text"), start: try entry.double("start"), end: try entry.double("end"))
            guard (change.end ?? cue.end) > (change.start ?? cue.start) else {
                throw AIToolError("changes[\(index)]: end must be after start.")
            }
            edits.changes.append(change)
        }
        for (index, item) in (try args.array("add") ?? []).enumerated() {
            let entry = AIToolArguments(item)
            let track: SubtitleTrack = try entry.choice("track", from: ["original", "translation"]) == "translation"
                ? .translation : .original
            let start = max(0, try entry.requiredDouble("start"))
            let end = try entry.requiredDouble("end")
            guard end > start else { throw AIToolError("add[\(index)]: end must be after start.") }
            edits.additions.append(Addition(track: track, start: start, end: end, text: try entry.string("text") ?? ""))
        }
        for text in try args.stringArray("delete") ?? [] {
            let id = try ids.resolve(text)
            guard state.subtitleCue(id) != nil else { throw AIToolError("delete: \(text) is not a subtitle line.") }
            edits.deletions.insert(id)
        }
        return edits
    }

    /// 一次改完，返回新加的那几句的 id。还没有字幕轨时就地建一条原文轨（同界面上的「+」）。
    func apply(to state: inout TimelineState) -> [UUID] {
        var created: [UUID] = []
        state.editSubtitleTracks(creatingOriginal: !additions.isEmpty) { original, companion in
            for change in changes {
                if let text = change.text {
                    SubtitleTrackEditing.setText(id: change.id, text: text, original: &original, companion: &companion)
                }
                if change.start != nil || change.end != nil {
                    let cue = original.cues.first { $0.id == change.id }
                        ?? companion.translation?.cues.first { $0.id == change.id }
                    guard let cue else { continue }
                    SubtitleTrackEditing.setTime(
                        id: change.id, start: max(0, change.start ?? cue.start), end: change.end ?? cue.end,
                        original: &original, companion: &companion
                    )
                }
            }
            for addition in additions {
                let cue = SubtitleCue(id: UUID(), start: addition.start, end: addition.end, text: addition.text)
                if let id = SubtitleTrackEditing.insertCue(cue, into: addition.track, original: &original, companion: &companion) {
                    created.append(id)
                }
            }
            if !deletions.isEmpty {
                SubtitleTrackEditing.removeCues(ids: deletions, original: &original, companion: &companion)
            }
        }
        return created
    }
}
