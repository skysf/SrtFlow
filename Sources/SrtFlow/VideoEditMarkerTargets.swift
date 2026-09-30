import Foundation

// M / 工具栏书签此刻会打在哪几个归属上。纯值：checks/ProjectFile 编进去做守卫。
// 生产入口在 VideoEditProject+Markers.swift（按钮的置灰判据和动作本身共用这一个函数）。
// 长期约束见 docs/architecture/clip-markers.md 第九节。

enum MarkerTargets {
    /// 落点规则（2026-09-30 用户拍板了标尺那一条）：
    /// 1. 标尺选中着（点过标尺、还没点别的），或者选中的是一枚标尺标记 → 只打标尺。
    /// 2. 否则选中的块里，凡是被播放头穿过的都各打一枚（多选 = 批量打；素材段 / 文字 / 形状 / 滤镜段都算）。
    /// 3. 一个都没选中（或选中的都不在播放头下）时，退回主轨播放头下那一段。
    ///
    /// 不跟随鼠标位置：鼠标不在时间线上时 M 会变成哑键，而播放头永远有确定的位置。
    /// 链接组**不**跟着一起打：标记是给人看的标注，不是剪辑结构。
    static func atPlayhead(_ time: Double, selection: EditSelection, state: TimelineState) -> [MarkerOwner] {
        if selection.rulerSelected { return [.ruler] }
        if let ref = selection.markerRef, ref.owner == .ruler { return [.ruler] }
        var owners: [MarkerOwner] = []
        owners += state.allClips.filter { selection.clipIDs.contains($0.id) && $0.contains(time: time) }.map { .clip($0.id) }
        owners += state.textOverlays.filter { selection.textIDs.contains($0.id) && $0.contains(time: time) }.map { .text($0.id) }
        owners += state.shapes.filter { selection.shapeIDs.contains($0.id) && $0.contains(time: time) }.map { .shape($0.id) }
        owners += state.filters.filter { selection.filterIDs.contains($0.id) && $0.contains(time: time) }.map { .filter($0.id) }
        if !owners.isEmpty { return owners }
        return state.mainClips.first { $0.contains(time: time) }.map { [.clip($0.id)] } ?? []
    }
}
