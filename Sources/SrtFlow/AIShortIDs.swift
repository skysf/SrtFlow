import Foundation
import SrtFlowCore

// MARK: - 给 AI 看的短 id
//
// 管什么：时间线上每样东西（片段、文字、滤镜、形状、字幕句）的 id 在结果里写成 UUID 的前 8 位，
// 撞了就整体加长；AI 传回来时，前缀能唯一对上就认。纯值，自检够得着（scripts/check-mcp.sh）。
// 不管什么：这个 id 是哪一类东西、在哪条轨（`AIItemKind`、`AITrackName`）。
//
// 为什么要短：一个工程几十上百段，36 位的 UUID 又费 token 又容易抄错一位。

struct AIShortIDs {
    private let ids: [UUID]
    private let length: Int

    static let minimumLength = 8

    init(_ ids: [UUID]) {
        self.ids = ids
        let texts = ids.map { $0.uuidString.lowercased() }
        var length = Self.minimumLength
        // 前缀撞了就加长，直到两两不同（36 位的完整 UUID 必然不同）。
        while length < 36, Set(texts.map { $0.prefix(length) }).count < texts.count {
            length += 1
        }
        self.length = length
    }

    /// 工程里所有能被 AI 指名的东西。
    init(state: TimelineState) {
        var all = state.allClips.map(\.id)
        all += state.textOverlays.map(\.id)
        all += state.filters.map(\.id)
        all += state.shapes.map(\.id)
        all += state.subtitleCues(of: .original).map(\.id)
        all += state.subtitleCues(of: .translation).map(\.id)
        self.init(all)
    }

    func short(_ id: UUID) -> String {
        String(id.uuidString.lowercased().prefix(length))
    }

    /// 完整 UUID 直接认；否则按前缀找，必须恰好对上一个。
    func resolve(_ text: String) throws -> UUID {
        let wanted = text.trimmingCharacters(in: .whitespaces).lowercased()
        if let exact = UUID(uuidString: wanted), ids.contains(exact) { return exact }
        guard wanted.count >= 4 else { throw AIToolError("Id \"\(text)\" is too short; use the id exactly as get_timeline shows it.") }
        let matches = ids.filter { $0.uuidString.lowercased().hasPrefix(wanted) }
        switch matches.count {
        case 1: return matches[0]
        case 0: throw AIToolError("Nothing in the project has id \"\(text)\". Call get_timeline (or get_subtitles) for the current ids.")
        default: throw AIToolError("Id \"\(text)\" matches several items; use more characters.")
        }
    }
}

/// 一个 id 指的是哪一类东西。
enum AIItemKind: String {
    case clip, text, filter, shape, subtitle

    static func of(_ id: UUID, in state: TimelineState) -> AIItemKind? {
        if state.clip(with: id) != nil { return .clip }
        if state.textOverlays.contains(where: { $0.id == id }) { return .text }
        if state.filters.contains(where: { $0.id == id }) { return .filter }
        if state.shapes.contains(where: { $0.id == id }) { return .shape }
        if state.subtitleTrack(of: id) != nil { return .subtitle }
        return nil
    }
}

/// 轨道在 AI 那边的名字：V1 = 主轨，V2、V3… = 上层视频轨（编号大的画在上面），A1、A2… = 音频轨。
/// 和专业剪辑软件的叫法一样，用户和 AI 说的是同一套话。
enum AITrackName {
    static func name(of slot: TrackSlot) -> String {
        switch slot {
        case .main: return "V1"
        case .overlay(let index): return "V\(index + 2)"
        case .audio(let index): return "A\(index + 1)"
        }
    }

    /// AI 写的轨道名 → 落点。V2 指第一条上层轨；正好比现有的多一条（没有 V3 时写 V3）就是新开一条。
    static func target(_ text: String, in state: TimelineState) throws -> TrackDropTarget {
        let name = text.trimmingCharacters(in: .whitespaces).lowercased()
        switch name {
        case "new_video", "new-video": return .newOverlayTop
        case "new_audio", "new-audio": return .newAudioBottom
        case "main", "v1": return .main
        default: break
        }
        guard let letter = name.first, let number = Int(name.dropFirst()), number >= 1 else {
            throw AIToolError("Unknown track \"\(text)\". Use V1, V2… for video or A1, A2… for audio.")
        }
        if letter == "v" {
            let index = number - 2
            if state.overlayTracks.indices.contains(index) { return .overlay(index) }
            if index == state.overlayTracks.count { return .newOverlayTop }
            throw AIToolError("There is no track \(text.uppercased()); the video tracks are V1…V\(state.overlayTracks.count + 1).")
        }
        if letter == "a" {
            let index = number - 1
            if state.audioTracks.indices.contains(index) { return .audio(index) }
            if index == state.audioTracks.count { return .newAudioBottom }
            throw AIToolError("There is no track \(text.uppercased()); the audio tracks are A1…A\(max(1, state.audioTracks.count)).")
        }
        throw AIToolError("Unknown track \"\(text)\". Use V1, V2… for video or A1, A2… for audio.")
    }
}
