import Foundation

// MARK: - 时间线上的一行
//
// 管什么：一行是什么（标尺 / 滤镜层 / 视频轨 / 文字行 / 形状 / 字幕轨 / 音轨）、多高、
// 行高存在哪、点轨道头选中谁、纯值排布时算不算「在轨道上面」。
// 不管什么：这些行怎么排（`VideoEditTimelineView.rows`）、画成什么样（各行自己的文件）。
//
// 从 VideoEditTimelineView.swift 拆出来（那个文件超过 600 行、只许降）。那边留了
// `typealias RowSpec = TimelineRowSpec`，别的文件照旧按 `VideoEditTimelineView.RowSpec` 叫它。

/// 一行画出来之后在滚动内容里的位置（`VideoEditTimelineView.rowLayouts`）。
struct TimelineRowLayout {
    var spec: TimelineRowSpec
    var minY: Double
    var midY: Double
    var maxY: Double
}

/// 行的描述，轨道头列和滚动区共用，保证两边行高对得上。
///
/// `Equatable` 不是摆设：轨道头列拿的是一整份行数组，比不出「没变」的话，拖动每动一下
/// 时间线一重算，整列轨道头（推子、电平表、行高把手）都跟着重算（2026-09-24 实测）。
struct TimelineRowSpec: Identifiable, Equatable {
    var id: String
    var icon: String
    var height: Double
    var slot: TrackSlot?
    /// 这一行的行高存在哪（nil = 这一行的高度不可调）。键是轨道身份不是
    /// 行号，见 `TimelineRowHeights`。
    var heightKey: TimelineRowHeightKey?
    var isRuler = false
    var isShapes = false
    /// 文字行的行号（nil = 不是文字行）。**进模型**（`TextOverlay.row`，0 = 最下面
    /// 那条文字行），行序就是画面上的叠放序（VideoEditTextRows.swift）。
    var textRow: Int?
    /// 字幕行属于哪条字幕轨（nil = 不是字幕行）。一个语言一条轨。
    var subtitleKind: SubtitleRowKind?
    /// 滤镜行的层号（nil = 不是滤镜行）。**和文字行不同，层号进模型**
    ///（`FilterClip.layer`）—— LUT 不可交换，现算的层号会在拖动别的段时
    /// 重排，画面跟着变。
    var filterLayer: Int?
    /// 整轨隐藏中（灰显，不可编辑）。
    var isHidden = false

    /// 轨道头点一下要选中谁；nil = 这一行没有可选的东西（标尺）。
    /// 判据本体在 `TimelineRowSelection` —— 这里只做「行 → 身份」的翻译，
    /// 一条规则都不许在这儿写（空轨、隐藏轨那些边界都归它判）。
    var selectionRow: TimelineRowSelection.Row? {
        if isRuler { return nil }
        // 滤镜行的轨道头点不出选择：滤镜是单选的（`EditSelection.filterID`），
        // 「整行一起选」没地方放。点行头什么都不做，好过选中一批 ⌫ 删不掉的东西。
        if filterLayer != nil { return nil }
        if let slot { return .track(slot) }
        if let subtitleKind { return .subtitle(subtitleKind) }
        if let textRow { return .textRow(textRow) }
        if isShapes { return .shapes }
        return nil
    }

    /// 纯值排布用的这一行（`TimelineSeams`）。
    var seamRow: TimelineSeams.Row {
        TimelineSeams.Row(slot: slot, height: height, sitsAboveTracks: isRuler || filterLayer != nil)
    }
}
