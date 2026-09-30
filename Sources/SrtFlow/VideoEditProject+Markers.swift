import Foundation
import SrtFlowCore

// 标记的生产入口：加 / 删 / 改色 / 改文字、M 打在哪、标尺的选中。
//
// 全部走 `perform(rebuildsPreview: false)` —— 每一步都可撤销、都会打脏标记，
// 但**一律不重建预览**：标记不进合成也不进导出，重建一次预览是几百毫秒的
// AVComposition 重搭，换来画面一帧不变。这跟形状标注是同一类改动。
//
// 落点的规则是纯值（VideoEditMarkerTargets.swift）；长期约束见 docs/architecture/clip-markers.md。
@MainActor
extension VideoEditProject {
    // 选中的标记（`selectedMarkerRef`）、失效清理（`pruneMarkerSelection`）和「点标尺 = 选中标尺」
    //（`selectRuler`）都在 VideoEditProject.swift 里：`selection` 是 `private(set)`，改它的门面只能写在那儿。

    // MARK: - M 打在哪

    /// M / 工具栏书签按钮此刻会打在哪几个归属上（规则见 `MarkerTargets`）。
    ///
    /// 按钮的置灰判据和动作本身共用这一个函数 —— 分成两份写，迟早会出现
    /// 「按钮亮着但按下去什么都没发生」。
    func markerTargetsAtPlayhead() -> [MarkerOwner] {
        MarkerTargets.atPlayhead(clock.time, selection: selection, state: state)
    }

    /// 工具栏书签按钮亮不亮。
    var canAddMarker: Bool { !markerTargetsAtPlayhead().isEmpty }

    /// 快捷键 M / 工具栏书签：给落点上的每一个归属在播放头处打一枚标记。
    ///
    /// 同一帧上已有标记时 `addMarker` 自己会挡掉，连按 M 不会叠点。
    func addMarkerAtPlayhead() {
        let time = clock.time
        let targets = markerTargetsAtPlayhead()
        guard !targets.isEmpty else { return }

        // 打完把最后一枚选上：紧接着按 ⌫ 撤掉、或者直接点开写字，都不用再瞄准。
        var created: MarkerRef?
        perform(rebuildsPreview: false) { state in
            for owner in targets {
                if let ref = state.addMarker(
                    to: owner, atTimeline: time, color: .red, tolerance: state.markerTolerance(for: owner)
                ) {
                    created = ref
                }
            }
        }
        if let created { selectedMarkerRef = created }
    }

    /// 在某个归属的指定时刻打一枚标记（块的右键菜单、标尺的右键菜单）。
    func addMarker(to owner: MarkerOwner, atTimeline time: Double) {
        var created: MarkerRef?
        perform(rebuildsPreview: false) { state in
            created = state.addMarker(
                to: owner, atTimeline: time, color: .red, tolerance: state.markerTolerance(for: owner)
            )
        }
        if let created { selectedMarkerRef = created }
    }

    /// 标尺右键「Add Marker Here」：落在右键按下的那一处（读不到就退回播放头）。
    func addRulerMarkerAtContextClick() {
        addMarker(to: .ruler, atTimeline: TimelinePointer.contextClickTime(project: self) ?? clock.time)
    }

    // MARK: - 删 / 改

    func deleteMarker(_ ref: MarkerRef) {
        // 先摘选择再改 state：`state.didSet` 里的 prune 也能兜住，但那是兜底，
        // 不是让调用点省事的理由。
        if selectedMarkerRef == ref { selectedMarkerRef = nil }
        perform(rebuildsPreview: false) { $0.removeMarker(ref) }
    }

    func setMarkerColor(_ ref: MarkerRef, _ color: MarkerColor) {
        perform(rebuildsPreview: false) { state in
            state.updateMarker(ref) { $0.color = color }
        }
    }

    /// 改备注文字。
    ///
    /// 一次提交一步撤销（不是每敲一个字一步）：调用点在编辑框**收工时**才调
    /// 这里，编辑过程中的中间值不进 state。`perform` 自己会挡下「值没变」的
    /// 调用，所以点开又原样关掉不会白占一格撤销栈。
    func setMarkerText(_ ref: MarkerRef, _ text: String) {
        perform(rebuildsPreview: false) { state in
            state.updateMarker(ref) { $0.text = text }
        }
    }
}
