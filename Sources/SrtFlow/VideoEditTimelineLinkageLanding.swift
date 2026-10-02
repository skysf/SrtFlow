import Foundation
import SrtFlowCore

// MARK: - 联动挪过的东西撞上了往哪让
//
// 管什么：联动（`TimelineLinkage.follow`）把段 / 文字 / 滤镜挪到新位置之后，和同一条轨 / 同一行 / 同一层上没动的东西
// 撞上了怎么办 —— 上层轨的段往上抬一轨、音频轨的段另找一条放得下的，都放不下新开一条（同拖文件进轨道 / 粘贴的梯子）；
// 文字往上找空行、滤镜往上找空层（同拖文字换行 / 拖滤镜卡片落层）；最后收拢空行 / 空层、每条轨按时间排好。
// 让路的永远是**这次挪过的**那个，没动的留在原地。字幕句和形状允许重叠，不归这里管。
// 不管什么：谁该挪、挪多少（`TimelineLinkage`）、一步撤销（调用方一次 perform）。
//
// 为什么非让不可：同一条轨上两段重叠，预览合成往轨上插的时候会把已有内容挤走（AVFoundation 的 insert 不报错），
// 一格之差整个合成就无效、预览黑屏（docs/architecture/preview-free-transform.md「一份时间账」）。
// 纯值、不 import AppKit：scripts/check-timeline-snap.sh 直接编。

enum TimelineLinkageLanding {

    /// `lanes` / `texts` / `filters`：这次挪过的段 / 文字 / 滤镜的 id。撞上了的让开，没撞上的一个不碰。
    static func settle(lanes: Set<UUID>, texts: Set<UUID>, filters: Set<UUID>, in state: inout TimelineState) {
        if !lanes.isEmpty {
            settleLanes(movers: lanes, audio: false, in: &state)
            settleLanes(movers: lanes, audio: true, in: &state)
            state.pruneEmptyTracks()
        }
        if !texts.isEmpty { settleTextRows(movers: texts, in: &state) }
        if !filters.isEmpty { settleFilterLayers(movers: filters, in: &state) }
        sortLanes(&state)
    }

    // MARK: 段：换一条轨

    /// 画面从自己那条轨往上试（叠放顺序只会往上，同拖文件「撞上往上抬」）；声音从自己那条起、再试别的（没有叠放语义）；
    /// 隐藏的轨不上梯子（同 `mediaImportLandings`），自己那条除外。都放不下就新开一条（画面在最上、声音在最下）。
    private static func settleLanes(movers: Set<UUID>, audio: Bool, in state: inout TimelineState) {
        var lanes = audio ? state.audioTracks : state.overlayTracks
        var homeless: [(clip: EditClip, from: Int)] = []
        for index in lanes.indices {
            let clips = lanes[index].clips
            for clip in clips where movers.contains(clip.id) && clips.contains(where: { $0.id != clip.id && overlaps($0, clip) }) {
                lanes[index].clips.removeAll { $0.id == clip.id }
                homeless.append((clip, index))
            }
        }
        guard !homeless.isEmpty else { return }
        for (clip, from) in homeless.sorted(by: { $0.clip.timelineStart < $1.clip.timelineStart }) {
            let order = audio ? Array(lanes.indices) : lanes.indices.filter { $0 >= from }
            if let target = order.first(where: { ($0 == from || !lanes[$0].isHidden) && fits(clip, in: lanes[$0].clips) }) {
                lanes[target].clips.append(clip)
            } else {
                lanes.append(EditLane(clips: [clip]))
            }
        }
        if audio { state.audioTracks = lanes } else { state.overlayTracks = lanes }
    }

    private static func overlaps(_ a: EditClip, _ b: EditClip) -> Bool {
        a.timelineStart < b.timelineEnd - 0.001 && b.timelineStart < a.timelineEnd - 0.001
    }

    private static func fits(_ clip: EditClip, in track: [EditClip]) -> Bool {
        !track.contains { overlaps($0, clip) }
    }

    // MARK: 文字：往上找空行；滤镜：往上找空层

    private static func settleTextRows(movers: Set<UUID>, in state: inout TimelineState) {
        var changed = false
        for text in state.textOverlays where movers.contains(text.id) {
            let taken = state.textOverlays.contains {
                $0.id != text.id && $0.row == text.row && $0.timelineStart < text.timelineEnd - 0.001 && text.timelineStart < $0.timelineEnd - 0.001
            }
            guard taken else { continue }
            let row = state.freeTextRow(from: text.row, start: text.timelineStart, end: text.timelineEnd, ignoring: text.id)
            state.updateTextOverlay(text.id) { $0.row = row }
            changed = true
        }
        if changed { state.compactTextRows() }
    }

    private static func settleFilterLayers(movers: Set<UUID>, in state: inout TimelineState) {
        var changed = false
        for filter in state.filters where movers.contains(filter.id) {
            guard occupied(filter.layer, by: filter, in: state) else { continue }
            var layer = filter.layer + 1
            while occupied(layer, by: filter, in: state) { layer += 1 }
            state.updateFilter(filter.id) { $0.layer = layer }
            changed = true
        }
        if changed { state.compactFilterLayers() }
    }

    private static func occupied(_ layer: Int, by filter: FilterClip, in state: TimelineState) -> Bool {
        state.filters.contains { $0.id != filter.id && $0.layer == layer && $0.overlaps(start: filter.timelineStart, end: filter.timelineEnd) }
    }

    // MARK: 每条轨按时间排

    private static func sortLanes(_ state: inout TimelineState) {
        for index in state.overlayTracks.indices {
            state.overlayTracks[index].clips.sort { $0.timelineStart < $1.timelineStart }
        }
        for index in state.audioTracks.indices {
            state.audioTracks[index].clips.sort { $0.timelineStart < $1.timelineStart }
        }
    }
}
