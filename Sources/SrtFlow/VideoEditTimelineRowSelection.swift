import Foundation
import SrtFlowCore

// MARK: - 轨道头点一下选中谁
//
// 左侧轨道头点**非眼睛**的区域 = 选中这一行的全部素材（2026-09-18 用户拍板）。
// 眼睛仍然是整轨显隐的唯一入口，两件事互不干扰：眼睛是 Button，它自己把点击
// 吃掉，落不到行上。
//
// 这个文件只有纯值：一行的身份 → 该选中哪些 ID。判据留在值这一层是为了能被
// `checks/ProjectFile` 编进去跑 —— @MainActor 的 `VideoEditProject` 自检编不动，
// 而「点空轨会不会把别的选择抹掉」「隐藏轨点得中吗」这类边界只有断言守得住。
// 把结果落进 `EditSelection` 的那一步在 `VideoEditProject+RowSelection.swift`。
//
// 长期约束见 docs/architecture/video-tracks.md。

enum TimelineRowSelection {

    /// 时间线上一行的身份。与 `VideoEditTimelineView.RowSpec` 一一对应，但
    /// **不带视图** —— 标尺那种点不出选择的行根本进不了这个枚举（映射写在
    /// `RowSpec.selectionRow`，nil 就是「这一行没有可选的东西」）。
    enum Row {
        case track(TrackSlot)
        /// 文字行的行号（`TextOverlay.row`，进模型）。
        case textRow(Int)
        case shapes
        case subtitle(SubtitleRowKind)
    }

    /// 选中项的类别。一行只产出**一类**，所以点选的互斥规则（`EditSelection`）
    /// 一条都没松：混选仍然只能从框选进来。
    enum Category {
        case clips
        case shapes
        case texts
        case subtitleCues
    }

    struct Result {
        var category: Category
        var ids: Set<UUID>
        var isEmpty: Bool { ids.isEmpty }
    }

    /// 这一行点下去该选中谁。
    ///
    /// **隐藏的行一律返回空**：隐藏 = 不可编辑（`trackRow` / `subtitleRow` 都
    /// 关了命中测试），轨道头是同一条合同的另一半。否则用户能从轨道头选中一批
    /// 在时间线上碰都碰不到的块，⌫ 一按就删掉了看不见的东西。
    static func ids(for row: Row, in state: TimelineState) -> Result {
        switch row {
        case .track(let slot):
            guard !state.isLaneHidden(slot) else { return Result(category: .clips, ids: []) }
            return Result(category: .clips, ids: Set(state[track: slot].map(\.id)))

        case .textRow(let row):
            // 和 `RowSpec` 那边读的是同一个字段（`TextOverlay.row`），点第几行选中的
            // 就是画在第几行的那些字。
            return Result(category: .texts, ids: Set(state.textOverlays(onRow: row).map(\.id)))

        case .shapes:
            return Result(category: .shapes, ids: Set(state.shapes.map(\.id)))

        case .subtitle(let kind):
            let hidden = kind == .original ? state.subtitleHidden : state.translationHidden
            guard !hidden else { return Result(category: .subtitleCues, ids: []) }
            // 译文轨是原文轨的镜像（同 ID 同时间），所以点哪一行选中的是同一批
            // cue —— 这里照样按行取各自的 cue 表，镜像关系由
            // `LinkedSubtitleEditing` 保证，不在这儿假设。
            let cues = kind == .original
                ? state.subtitle?.cues
                : state.subtitleCompanion?.translation?.cues
            return Result(category: .subtitleCues, ids: Set((cues ?? []).map(\.id)))
        }
    }

    /// ⌘/⇧ 点的加选规则：整行**已经全在选中里**就减掉，否则并进去。
    ///
    /// 和块的点选（`VideoEditProject.select(_:additive:)`）同一个心智，只是单位
    /// 从一块变成一行。逐个翻转是错的：一行里有选中的也有没选中的时，逐个翻转
    /// 会把已选的那几块**取消掉**，用户看到的是「加选反而少了几块」。
    static func applying(_ ids: Set<UUID>, to current: Set<UUID>, additive: Bool) -> Set<UUID> {
        guard additive else { return ids }
        return ids.isSubset(of: current) ? current.subtracting(ids) : current.union(ids)
    }
}
