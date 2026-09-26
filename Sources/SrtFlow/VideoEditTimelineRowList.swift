import Foundation
import SrtFlowCore

// MARK: - 时间线上有哪些行、各多高
//
// 管什么：从工程排出时间线的行（标尺、滤镜层、上层视频轨、文字行、形状、主轨、字幕、音频轨）
// 以及每一行多高 —— 时间线画它、缩放找锚点、⌘V 找指针底下是哪一行，**都从这一份来**。
// 不管什么：行怎么排成 y（`VideoEditTimelineView.layouts(of:open:)` → `TimelineSeams.layout`）、
// 行里画什么（各行自己的文件）。
//
// 2026-09-26 从 `VideoEditTimelineView.rows` 挪出来：纵向缩放和粘贴都在时间线的视图树外面，
// 拿不到那个视图，又不许各自再排一份（同一条规则只有一处实现）。

@MainActor
enum TimelineRowList {

    /// 从上到下的每一行。行的上下顺序就是画面的叠放顺序（滤镜行除外，它压在最顶上）。
    static func rows(for project: VideoEditProject) -> [TimelineRowSpec] {
        let state = project.state
        var result: [TimelineRowSpec] = [TimelineRowSpec(id: "ruler", icon: "", height: 26, slot: nil, isRuler: true)]
        // 滤镜行在**最顶上**：它作用于下面全部画面，不参与「行的上下顺序就是
        // 叠放次序」那套视频轨语义，混进去只会让人以为它是一条能放素材的轨。
        // 层号大的画在上面 —— 上面的后作用（docs/architecture/filters.md）。
        for layer in (0..<state.filterLayerCount).reversed() {
            result.append(TimelineRowSpec(
                id: "filter-\(layer)", icon: "camera.filters", height: 26, slot: nil,
                filterLayer: layer
            ))
        }
        // 上层视频轨：编号大的画在上面，行也放上面 —— 行的上下顺序就是叠放顺序。
        // 图标与主轨**同一个**：它们是对等的视频轨，区别只有叠放次序（行的位置
        // 已经表达了）和颜色。用 pip 图标会把「这是个小窗」的旧心智带回来。
        for index in state.overlayTracks.indices.reversed() {
            let row = trackRowHeight(.overlay(index), in: project)
            result.append(TimelineRowSpec(
                id: "overlay-\(state.overlayTracks[index].id)",
                icon: "film",
                height: row.height,
                slot: .overlay(index),
                heightKey: row.key,
                isHidden: state.overlayTracks[index].isHidden
            ))
        }
        // 文字行在形状行**上面**：行的上下顺序就是叠放顺序（行号大的在上、画在上面），
        // 而文字压在形状之上。
        for row in (0..<state.textRowCount).reversed() {
            result.append(TimelineRowSpec(
                id: "text-\(row)", icon: "textformat", height: 26, slot: nil, textRow: row
            ))
        }
        if !state.shapes.isEmpty {
            result.append(TimelineRowSpec(id: "shapes", icon: "square.on.square.dashed", height: 26, slot: nil, isShapes: true))
        }
        let mainRow = trackRowHeight(.main, in: project)
        result.append(TimelineRowSpec(
            id: "main",
            icon: "film",
            height: mainRow.height,
            slot: .main,
            heightKey: mainRow.key,
            isHidden: state.mainHidden
        ))
        // 一个语言一条字幕轨：原文一行，有译文再来一行，各自一只眼睛、各自的句子
        // （2026-09-26 起两条轨独立；画面上怎么排见 TimelineState.subtitleScreenBlocks）。
        if state.subtitle != nil {
            result.append(TimelineRowSpec(
                id: "subtitle-original", icon: "captions.bubble", height: 22, slot: nil,
                subtitleKind: .original,
                isHidden: state.subtitleHidden
            ))
            if state.subtitleCompanion?.translation != nil {
                result.append(TimelineRowSpec(
                    id: "subtitle-translation", icon: "character.bubble", height: 22, slot: nil,
                    subtitleKind: .translation,
                    isHidden: state.translationHidden
                ))
            }
        }
        for index in state.audioTracks.indices {
            let row = trackRowHeight(.audio(index), in: project)
            result.append(TimelineRowSpec(
                id: "audio-\(state.audioTracks[index].id)",
                icon: "music.note",
                height: row.height,
                slot: .audio(index),
                heightKey: row.key,
                isHidden: state.audioTracks[index].isHidden
            ))
        }
        return result
    }

    /// 视频轨 / 音频轨这一行多高，以及它的行高存在哪个键上。
    /// **一轨一个值**：没单独调过的轨回落到纵向缩放定的统一高度，再没有才是这一类的默认高度。
    private static func trackRowHeight(
        _ slot: TrackSlot, in project: VideoEditProject
    ) -> (height: Double, key: TimelineRowHeightKey?) {
        let key = TimelineRowHeights.key(for: slot, in: project.state)
        return (project.rowHeight(for: key, kind: TrackRowKind(slot)), key)
    }
}
