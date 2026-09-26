import Foundation
import SrtFlowCore

// MARK: - 剪贴板里的一批时间线内容（纯值）
//
// 管什么：⌘C / ⌘X 从时间线上拿走什么、以什么样子放进剪贴板 —— 每一样都是**完整的一份**（和存盘同一套
// 编码），外加粘贴时要用的「它原来在哪」：剪辑在哪条轨、字幕句在哪条轨、藏没藏。
// 不管什么：粘到哪（`TimelinePaste`）、系统剪贴板的读写（`TimelineClipboard`，App 那一层）。
//
// 2026-09-26 用户拍板（docs/plans/2026-09-26-timeline-clipboard-and-zoom.md）；长期约束见
// docs/architecture/timeline-clipboard.md。纯值、不 import AppKit，自检编得动（scripts/check-timeline-clipboard.sh）。

struct TimelineClipboardPayload: Codable, Equatable {
    /// 一段剪辑原来在哪条轨上。上层轨和音频轨记轨道身份（同一个工程里粘回那条轨）和当时是第几条
    /// （几组一起粘时保住上下关系；跨工程时身份对不上，只剩它）。
    enum Lane: Codable, Hashable {
        case main
        case overlay(id: UUID, index: Int)
        case audio(id: UUID, index: Int)

        var isAudio: Bool {
            if case .audio = self { return true }
            return false
        }

        /// 同一类里的上下次序：画面从主轨往上数，声音从第一条往下数。
        var order: Int {
            switch self {
            case .main: return 0
            case .overlay(_, let index): return index + 1
            case .audio(_, let index): return index
            }
        }
    }

    struct Clip: Codable, Equatable {
        var clip: EditClip
        var lane: Lane
        /// 图片刚拖进来、静帧视频还在后台转（不存盘的临时状态，编码里没有，单独带着）。
        var needsStillConversion: Bool

        /// 把这个标记从剪辑里摘出来单独带着：它不进存盘的编码，留在剪辑里的话载荷往返就不是原样。
        init(_ clip: EditClip, lane: Lane) {
            var stored = clip
            stored.needsStillConversion = false
            self.clip = stored
            self.lane = lane
            self.needsStillConversion = clip.needsStillConversion
        }
    }

    struct Cue: Codable, Equatable {
        var cue: SubtitleCue
        var isTranslation: Bool
        /// 藏没藏记在字幕的旁表里（`hiddenCueIDs`），句子本身不带，单独带着。
        var isHidden: Bool
    }

    /// 载荷的版本：以后换了结构，老版本认不出就当剪贴板里没东西，不硬解出半截。
    var version = TimelineClipboardPayload.currentVersion
    var clips: [Clip] = []
    var shapes: [ShapeAnnotation] = []
    var texts: [TextOverlay] = []
    var filters: [FilterClip] = []
    var cues: [Cue] = []

    static let currentVersion = 1

    var isEmpty: Bool {
        clips.isEmpty && shapes.isEmpty && texts.isEmpty && filters.isEmpty && cues.isEmpty
    }

    /// 这一批里最早的开头：粘贴时整批按它对齐落点（左边缘对齐，同拖文件）。
    var start: Double? {
        (clips.map(\.clip.timelineStart) + shapes.map(\.timelineStart) + texts.map(\.timelineStart)
            + filters.map(\.timelineStart) + cues.map(\.cue.start)).min()
    }

    /// 这一批里最晚的结尾（落点吸附按整批的两条边去够）。
    var end: Double? {
        (clips.map(\.clip.timelineEnd) + shapes.map(\.timelineEnd) + texts.map(\.timelineEnd)
            + filters.map(\.timelineEnd) + cues.map(\.cue.end)).max()
    }

    func encoded() -> Data? { try? JSONEncoder().encode(self) }

    /// 读剪贴板里的字节。解不开、版本比自己新、里面什么都没有 —— 都当剪贴板里没东西。
    static func decoded(from data: Data) -> TimelineClipboardPayload? {
        guard let payload = try? JSONDecoder().decode(Self.self, from: data),
              payload.version <= currentVersion, !payload.isEmpty else { return nil }
        return payload
    }
}

extension TimelineClipboardPayload {
    /// 从时间线上拿这些东西（链接伙伴由调用方按链接开关展开，同 ⌫）。一样都拿不到是 nil。
    ///
    /// - 剪辑按时间线上的顺序：主轨 → 上层轨 → 音频轨。
    /// - **转场写在出场段身上**：主轨上一段的下一段没被一起拿走，这一段就不带转场（另一半不在，转场不成立）。
    /// - 字幕句记下在哪条轨、藏没藏。
    init?(
        copying state: TimelineState,
        clips clipIDs: Set<UUID>, shapes shapeIDs: Set<UUID>, texts textIDs: Set<UUID>,
        cues cueIDs: Set<UUID>, filters filterIDs: Set<UUID>
    ) {
        var payload = TimelineClipboardPayload()
        for (index, clip) in state.mainClips.enumerated() where clipIDs.contains(clip.id) {
            var copy = clip
            let next = state.mainClips.indices.contains(index + 1) ? state.mainClips[index + 1].id : nil
            if !(next.map(clipIDs.contains) ?? false) { copy.transitionAfter = .none }
            payload.clips.append(Clip(copy, lane: .main))
        }
        for (index, lane) in state.overlayTracks.enumerated() {
            for clip in lane.clips where clipIDs.contains(clip.id) {
                payload.clips.append(Clip(clip, lane: .overlay(id: lane.id, index: index)))
            }
        }
        for (index, lane) in state.audioTracks.enumerated() {
            for clip in lane.clips where clipIDs.contains(clip.id) {
                payload.clips.append(Clip(clip, lane: .audio(id: lane.id, index: index)))
            }
        }
        payload.shapes = state.shapes.filter { shapeIDs.contains($0.id) }
        payload.texts = state.textOverlays.filter { textIDs.contains($0.id) }
        payload.filters = state.filters.filter { filterIDs.contains($0.id) }
        for cue in state.subtitle?.cues ?? [] where cueIDs.contains(cue.id) {
            payload.cues.append(Cue(cue: cue, isTranslation: false, isHidden: state.isSubtitleCueHidden(cue.id)))
        }
        for cue in state.subtitleCompanion?.translation?.cues ?? [] where cueIDs.contains(cue.id) {
            payload.cues.append(Cue(cue: cue, isTranslation: true, isHidden: state.isSubtitleCueHidden(cue.id)))
        }
        guard !payload.isEmpty else { return nil }
        self = payload
    }
}

/// 同一样东西换一个身份：编码成 JSON、换掉顶层的 `id`、再解回来。
///
/// 剪辑、文字、形状、滤镜段的 `id` 都是 `let`，手写「除了 id 以外的每个字段都照抄」迟早漏字段（分割那条路
/// 就漏过 `remoteKey` 和 `isHidden`，2026-09-26 才补上）；存盘的编码本来就是「这一样的全部」，走它就不会漏。
/// 编码里没有 `id` 这个键（有人改了编码的键名）就是 nil —— 宁可粘不出来，也不许粘出两个同身份的东西。
enum ClipboardIdentity {
    static func renewed<Value: Codable>(_ value: Value, id: UUID = UUID()) -> Value? {
        guard let data = try? JSONEncoder().encode(value),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["id"] != nil else { return nil }
        object["id"] = id.uuidString
        guard let edited = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: edited)
    }
}
