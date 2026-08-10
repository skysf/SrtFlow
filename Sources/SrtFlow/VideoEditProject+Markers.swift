import Foundation
import SrtFlowCore

// 标记的生产入口：加 / 删 / 改色 / 改文字。
//
// 全部走 `perform(rebuildsPreview: false)` —— 每一步都可撤销、都会打脏标记，
// 但**一律不重建预览**：标记不进合成也不进导出，重建一次预览是几百毫秒的
// AVComposition 重搭，换来画面一帧不变。这跟形状标注是同一类改动。
//
// 长期约束见 docs/architecture/clip-markers.md。
@MainActor
extension VideoEditProject {
    /// 打标记的容差 / 判据都按工程帧率和本段速度算，跟关键帧同一把尺子。
    private func markerTolerance(for clip: EditClip) -> Double {
        KeyframeTrack.sourceTolerance(frameRate: state.frameRate, speed: clip.speed)
    }

    /// M / 工具栏书签按钮此刻会打在哪几段上。
    ///
    /// 落点规则：
    /// 1. 选中的段里，凡是被播放头穿过的都各打一枚（多选就是批量打）。
    /// 2. 一个都没选中（或选中的段都不在播放头下）时，退回主轨播放头下那一段。
    ///
    /// 不跟随鼠标位置：鼠标不在时间线上时 M 会变成哑键，而播放头永远有确定的
    /// 位置。
    ///
    /// 链接组**不**跟着一起打：标记是给人看的标注，不是剪辑结构。分离出来的
    /// 音频段自动多一枚标记只会让人莫名其妙。
    ///
    /// 按钮的置灰判据和动作本身共用这一个函数 —— 分成两份写，迟早会出现
    /// 「按钮亮着但按下去什么都没发生」。
    func markerTargetsAtPlayhead() -> [UUID] {
        let time = clock.time
        let selected = state.allClips
            .filter { selectedClipIDs.contains($0.id) && $0.contains(time: time) }
            .map(\.id)
        if !selected.isEmpty { return selected }
        return mainClipAtPlayhead().map { [$0.id] } ?? []
    }

    /// 工具栏书签按钮亮不亮。
    var canAddMarker: Bool { !markerTargetsAtPlayhead().isEmpty }

    /// 快捷键 M / 工具栏书签：给落点上的每一段在播放头处打一枚标记。
    ///
    /// 同一帧上已有标记时 `addMarker` 自己会挡掉，连按 M 不会叠点。
    func addMarkerAtPlayhead() {
        let time = clock.time
        let targets = markerTargetsAtPlayhead()
        guard !targets.isEmpty else { return }

        // 打完把最后一枚选上：紧接着按 ⌫ 撤掉、或者直接点开写字，都不用再瞄准。
        var created: ClipMarkerRef?
        perform(rebuildsPreview: false) { state in
            for id in targets {
                guard let clip = state.clip(with: id) else { continue }
                let tolerance = KeyframeTrack.sourceTolerance(frameRate: state.frameRate, speed: clip.speed)
                if let ref = state.addMarker(
                    toClip: id, atTimeline: time, color: .red, tolerance: tolerance
                ) {
                    created = ref
                }
            }
        }
        if let created { selectedMarkerRef = created }
    }

    /// 在某段的指定时刻打一枚标记（右键菜单 / 未来的其它入口）。
    func addMarker(toClip id: UUID, atTimeline time: Double) {
        guard let clip = state.clip(with: id) else { return }
        let tolerance = markerTolerance(for: clip)
        var created: ClipMarkerRef?
        perform(rebuildsPreview: false) { state in
            created = state.addMarker(toClip: id, atTimeline: time, color: .red, tolerance: tolerance)
        }
        if let created { selectedMarkerRef = created }
    }

    func deleteMarker(_ ref: ClipMarkerRef) {
        // 先摘选择再改 state：`state.didSet` 里的 prune 也能兜住，但那是兜底，
        // 不是让调用点省事的理由。
        if selectedMarkerRef == ref { selectedMarkerRef = nil }
        perform(rebuildsPreview: false) { $0.removeMarker(ref) }
    }

    func setMarkerColor(_ ref: ClipMarkerRef, _ color: MarkerColor) {
        perform(rebuildsPreview: false) { state in
            state.updateMarker(ref) { $0.color = color }
        }
    }

    /// 改备注文字。
    ///
    /// 一次提交一步撤销（不是每敲一个字一步）：调用点在编辑框**收工时**才调
    /// 这里，编辑过程中的中间值不进 state。`perform` 自己会挡下「值没变」的
    /// 调用，所以点开又原样关掉不会白占一格撤销栈。
    func setMarkerText(_ ref: ClipMarkerRef, _ text: String) {
        perform(rebuildsPreview: false) { state in
            state.updateMarker(ref) { $0.text = text }
        }
    }
}
