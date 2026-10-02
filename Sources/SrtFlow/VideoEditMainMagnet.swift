import Foundation

// MARK: - 主轨磁吸：这次改动之后要不要把 V1 排紧
//
// 管什么：磁吸（`TimelineState.mainMagnet`，跟着工程走、存进工程文件）开着时，哪些改动之后要排紧 V1：只有改到了 V1 的排布
//（段的先后、起点、时长、转场），或者磁吸是这次才打开的。改字幕、音量、别的轨永远不动 V1。排完报一句挪了几段（给 AI 的结果）。
// 不管什么：怎么排（`TimelineState.packMain` / `packedStarts`）、开关本身（工具栏、`VideoEditProject.setMagnet`）。
//
// 为什么（docs/bugfixes/2026-10-02-magnet-closes-v1-gaps-on-any-edit.md）：以前磁吸是全 App 一份、每次 perform 收尾都排一遍。
// 磁吸被记住为开、又打开一个 V1 有缝的工程（缝是磁吸关着时留的），改一条音量曲线就把整条 V1 合拢，联动把压在上面的 97 样东西
// 跟着挪。纯值、不 import AppKit：scripts/check-timeline-snap.sh 直接编。

enum MainMagnet {
    /// 起点挪了多少以下不算挪（同联动的口径）。
    static let epsilon = 0.000_5

    /// V1 一段的排布：`packMain` 排出来的位置只取决于这几样。
    struct Slot: Equatable {
        var id: UUID
        var start: Double
        var duration: Double
        var transition: ClipTransition
        var transitionDuration: Double

        init(_ clip: EditClip) {
            id = clip.id
            start = clip.timelineStart
            duration = clip.timelineDuration
            transition = clip.transitionAfter
            transitionDuration = clip.transitionDuration
        }
    }

    static func layout(of state: TimelineState) -> [Slot] { state.mainClips.map(Slot.init) }

    /// 新建工程（启动时那个空工程、⌘N、AI 的 new_project）的时间线：空的，磁吸用 `remembered`
    ///（上次拨的值，`EditorToggles.magnet` —— 2026-10-02 起它只当新建工程的默认）。
    static func newTimeline(remembered: Bool) -> TimelineState {
        var timeline = TimelineState()
        timeline.mainMagnet = remembered
        return timeline
    }

    /// 从 `previous` 改成 `next` 之后要不要排紧 V1：磁吸开着，并且是这次才打开的、或者这次改到了 V1 的排布。
    static func needsPacking(_ next: TimelineState, after previous: TimelineState) -> Bool {
        guard next.mainMagnet else { return false }
        return !previous.mainMagnet || layout(of: next) != layout(of: previous)
    }

    /// 要排就排，回排的时候挪了几段（没挪、不用排都是 0）。`perform` / `liveApply` 收尾只走这一个。
    @discardableResult
    static func settle(_ next: inout TimelineState, after previous: TimelineState) -> Int {
        guard needsPacking(next, after: previous) else { return 0 }
        let starts = next.mainClips.map(\.timelineStart)
        next.packMain()
        return zip(starts, next.mainClips).filter { abs($0 - $1.timelineStart) > epsilon }.count
    }
}
