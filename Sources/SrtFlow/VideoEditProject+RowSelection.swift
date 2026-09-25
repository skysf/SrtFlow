import Foundation

// MARK: - 轨道头点一下 = 选中这一行的素材
//
// 选谁由纯值 `TimelineRowSelection` 算（自检编得动它），这里只负责把结果落进
// `EditSelection` —— 别在视图里直接写 `selectedClipIDs = …`，那样「点哪一行
// 选什么」就会散成两份判据。接线守卫在 checks/timeline-drag-wiring.sh 第 13 节。

extension VideoEditProject {

    /// 轨道头点一下：选中这一行的全部素材。⌘/⇧ 点是加选 / 取消，和块的点选一致。
    ///
    /// 空行和隐藏行**什么都不做** —— 注意这不是「选中 0 个」：后者会把用户手上
    /// 已有的选择抹掉，而他只是点空了一下轨道头。
    func selectRow(_ row: TimelineRowSelection.Row, additive: Bool) {
        let result = TimelineRowSelection.ids(for: row, in: state)
        guard !result.isEmpty else { return }
        switch result.category {
        case .clips:
            selectedClipIDs = TimelineRowSelection.applying(
                result.ids, to: selectedClipIDs, additive: additive)
        case .shapes:
            selectedShapeIDs = TimelineRowSelection.applying(
                result.ids, to: selectedShapeIDs, additive: additive)
        case .texts:
            selectedTextIDs = TimelineRowSelection.applying(
                result.ids, to: selectedTextIDs, additive: additive)
        case .subtitleCues:
            selectedSubtitleCueIDs = TimelineRowSelection.applying(
                result.ids, to: selectedSubtitleCueIDs, additive: additive)
        case .filters:
            selectedFilterIDs = TimelineRowSelection.applying(
                result.ids, to: selectedFilterIDs, additive: additive)
        }
    }
}
