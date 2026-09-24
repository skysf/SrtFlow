import Foundation

// MARK: - 文字行
//
// 管什么：`TextOverlay.row` 的规矩 —— 有几行、每行有谁、画面上谁压谁、新文字开在哪一行、
// 拖到别的行落在哪、空行怎么收、老工程怎么补行号，以及上下拖时指针落在哪一行的判定。
// 不管什么：行怎么画（VideoEditTimelineTextRow.swift）、拖动会话（VideoEditTimelineDragWiring.swift）。
//
// 2026-09-24 用户拍板：
// 1. 行号进模型、存盘（v21），不再按时间重叠现算 —— 现算的行号会在拖别的段时重排，
//    而**行序就是画面上的叠放序**，重排等于换画面。
// 2. 新加的文字 / 数字永远在最上面**新开一行**。
// 3. 行可以上下拖：目标行在那段时间被占了，就往上找第一条空行；最上面那行之上 = 新开一行。
// 4. 空行收掉（收拢只改编号，不改谁上谁下）。
// 5. 形状不动（还是一行，允许重叠）。
//
// 同一行里不许重叠是**落点**的规矩（拖动落地、加新文字），不是硬约束：裁切把两段拉到
// 相交时照样各画各的。

enum TextRows {
    /// 老工程（没有 `row` 键）按当年的自动排布定行：当年时间线把贪心层 0 画在**最下面**
    /// 那条文字行（`rows` 里按层号倒序往下排），和行号的方向一样，照抄即可 —— 迁移之后
    /// 屏幕上一行都不挪。
    static func migratedRows(for overlays: [TextOverlay]) -> [Int] {
        TextOverlayStacking.levels(for: overlays)
    }

    /// 上下拖时指针落在哪一行。`rows` 是画出来的文字行（行号、内容 y 的上下沿，任意顺序）。
    ///
    /// - 落在某一行里且不是自己那一行 → 那一行；
    /// - 比最上面那一行还高（标尺、滤镜、上层轨都算）→ `rowCount`，即「顶上新开一行」；
    /// - 文字行以下、或自己那一行 → nil（留在原行）。
    static func dropTarget(
        y: Double, rows: [(row: Int, minY: Double, maxY: Double)], rowCount: Int, current: Int
    ) -> Int? {
        guard let top = rows.min(by: { $0.minY < $1.minY }) else { return nil }
        if y < top.minY { return rowCount }
        guard let hit = rows.first(where: { y >= $0.minY && y < $0.maxY }) else { return nil }
        return hit.row == current ? nil : hit.row
    }
}

extension TimelineState {
    /// 时间线上要给文字留几行。没有文字时是 0（那些行整个不出现）。
    var textRowCount: Int {
        (textOverlays.map(\.row).max().map { $0 + 1 }) ?? 0
    }

    func textOverlays(onRow row: Int) -> [TextOverlay] {
        textOverlays.filter { $0.row == row }
    }

    /// 画面上的叠放序：行号小的先画（在下面），同一行按数组顺序。预览叠层和导出都按它。
    var textOverlaysInStackingOrder: [TextOverlay] {
        textOverlays.enumerated()
            .sorted { ($0.element.row, $0.offset) < ($1.element.row, $1.offset) }
            .map(\.element)
    }

    /// 从 `row` 往上找第一条在 `[start, end)` 上空着的行；都满了就是新的一行（`textRowCount`）。
    /// 容差 1ms：紧挨着的两段（前一段结束 = 后一段开始）不算占着。
    func freeTextRow(from row: Int, start: Double, end: Double, ignoring ignored: UUID? = nil) -> Int {
        var candidate = max(0, row)
        let ceiling = textRowCount
        while candidate < ceiling {
            let occupied = textOverlays.contains {
                $0.row == candidate && $0.id != ignored
                    && $0.timelineStart + 0.001 < end && start + 0.001 < $0.timelineEnd
            }
            if !occupied { return candidate }
            candidate += 1
        }
        return ceiling
    }

    /// 把一段文字放到 `row`（被占就往上找，最上面之上新开一行），然后收掉空行。
    mutating func moveTextOverlay(_ id: UUID, toRow row: Int) {
        guard let index = textOverlays.firstIndex(where: { $0.id == id }) else { return }
        let overlay = textOverlays[index]
        textOverlays[index].row = freeTextRow(
            from: row, start: overlay.timelineStart, end: overlay.timelineEnd, ignoring: id
        )
        compactTextRows()
    }

    /// 拖动落地：被拖的文字先按目标行（没有就是自己那一行）落，落点被占就往上找。
    /// 和横向位移在同一次 `perform` 里，所以是一步撤销。
    mutating func settleTextRow(_ plan: ClipDragPlan, preferring row: Int?) {
        guard plan.members.contains(where: { $0.id == plan.draggedID && $0.kind == .text }),
              let overlay = textOverlays.first(where: { $0.id == plan.draggedID }) else { return }
        moveTextOverlay(plan.draggedID, toRow: row ?? overlay.row)
    }

    /// 删段 / 换行之后把空出来的行号收拢。**相对顺序不变，所以画面不跳**。
    mutating func compactTextRows() {
        let used = Set(textOverlays.map(\.row)).sorted()
        guard used.last.map({ $0 + 1 }) != used.count else { return }
        var remap: [Int: Int] = [:]
        for (newRow, old) in used.enumerated() { remap[old] = newRow }
        for index in textOverlays.indices {
            textOverlays[index].row = remap[textOverlays[index].row] ?? 0
        }
    }

    /// 读盘后的规范化：全部没有行号（老工程）就按当年的自动排布补；个别没有的当 0；
    /// 最后收拢一遍，坏数据（负数、跳号）也一并收口。
    mutating func normalizeTextRows() {
        guard !textOverlays.isEmpty else { return }
        if textOverlays.allSatisfy({ $0.row == TextOverlay.unassignedRow }) {
            let rows = TextRows.migratedRows(for: textOverlays)
            for index in textOverlays.indices { textOverlays[index].row = rows[index] }
        }
        for index in textOverlays.indices where textOverlays[index].row < 0 {
            textOverlays[index].row = 0
        }
        compactTextRows()
    }
}
