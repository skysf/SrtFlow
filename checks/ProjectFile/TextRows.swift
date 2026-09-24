import Foundation

// 第 32 组：文字行进模型（`TextOverlay.row`，2026-09-24 用户拍板）。合同见
// docs/architecture/text-overlays.md「时间线上的行」。
//
// 1. 行号存盘、往返不变；有文字就是 v21 数据；没有文字不是。
// 2. 叠放序 = 行号小的先画，同一行按数组顺序。
// 3. 换行：目标行在那段时间被占就往上找第一条空行，最上面之上新开一行；
//    紧挨着（前一段结束 = 后一段开始）不算占着。
// 4. 空行收拢，只改编号不改上下。
// 5. 老工程没有 `row` 键：按当年的自动排布补（贪心层 0 当年画在最下面那条文字行 =
//    行号 0，屏幕上一行不挪）；个别缺的当 0；负数收口。
// 6. 上下拖时指针落在哪一行（纯值）。

func checkTextRows(root: URL) throws {
    let dir = root.appendingPathComponent("textrows")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    var a = TextOverlay(text: "A", timelineStart: 0, duration: 3, row: 0)
    var b = TextOverlay(text: "B", timelineStart: 1, duration: 3, row: 1)
    let c = TextOverlay(text: "C", timelineStart: 10, duration: 2, row: 0)
    var state = TimelineState()
    check(!state.requiresFormatVersion21, "没有文字的工程不是 v21 数据")
    state.textOverlays = [b, a, c]
    check(state.requiresFormatVersion21, "有文字就是 v21 数据（行号无条件落盘）")
    checkEqual(state.textRowCount, 2, "两行")
    checkEqual(state.textOverlays(onRow: 0).map(\.text), ["A", "C"], "第 0 行是 A、C")
    checkEqual(state.textOverlaysInStackingOrder.map(\.text), ["A", "C", "B"],
               "叠放序：行号小的先画，同一行按数组顺序")

    // ---- 换行 ----
    checkEqual(state.freeTextRow(from: 0, start: 0.5, end: 2), 2, "0、1 行都被占 → 新开第 2 行")
    checkEqual(state.freeTextRow(from: 0, start: 3, end: 5), 0, "紧挨着 A 的结尾不算占着")
    checkEqual(state.freeTextRow(from: 1, start: 5, end: 6), 1, "从第 1 行起找，空着就落在第 1 行")
    state.moveTextOverlay(b.id, toRow: 0)
    checkEqual(state.textOverlays.first { $0.id == b.id }?.row, 1, "B 想去第 0 行但被 A 占着 → 留在第 1 行")
    state.moveTextOverlay(c.id, toRow: 5)
    checkEqual(state.textOverlays.first { $0.id == c.id }?.row, 2, "C 要去很高的行 → 落在新开的一行，编号紧接着")
    state.moveTextOverlay(c.id, toRow: 0)
    checkEqual(state.textOverlays.first { $0.id == c.id }?.row, 0, "C 回第 0 行（10s 处空着）")
    checkEqual(state.textRowCount, 2, "空出来的第 2 行收掉了")

    // ---- 收拢：只改编号不改上下 ----
    state.textOverlays[0].row = 7   // B
    state.textOverlays[1].row = 3   // A
    state.textOverlays[2].row = 3   // C
    state.compactTextRows()
    checkEqual(state.textOverlays.map(\.row), [1, 0, 0], "7/3/3 收成 1/0/0，谁上谁下不变")

    // ---- 存盘往返 ----
    let file = dir.appendingPathComponent("rows.srtflowproj")
    try VideoEditProjectIO.save(state, to: file)
    let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
    checkEqual(raw?["formatVersion"] as? Int, 21, "带文字的工程写 v21")
    let overlays = (raw?["timeline"] as? [String: Any])?["textOverlays"] as? [[String: Any]]
    check(overlays?.allSatisfy { $0["row"] != nil } == true, "每段文字都写 row 键（包括第 0 行）")
    let back = try VideoEditProjectIO.load(from: file).timeline
    checkEqual(back.textOverlays.map(\.row), [1, 0, 0], "行号往返不变")

    // ---- 老工程：没有 row 键，按当年的自动排布补 ----
    // 当年的排布：按开始时间贪心，第一条放得下的层；层 0 画在最下面那条文字行。
    // A(0–3) 层 0、B(1–4) 层 1、C(10–12) 层 0 → 行号照抄：A 0、B 1、C 0。
    let legacyText = try String(contentsOf: file, encoding: .utf8)
        .replacingOccurrences(of: #""row" : \d+,?"#, with: "", options: .regularExpression)
    check(!legacyText.contains("\"row\""), "造老工程：把 row 键全拿掉")
    let legacy = dir.appendingPathComponent("legacy.srtflowproj")
    try Data(legacyText.utf8).write(to: legacy)
    let migrated = try VideoEditProjectIO.load(from: legacy).timeline
    let rowByText = Dictionary(uniqueKeysWithValues: migrated.textOverlays.map { ($0.text, $0.row) })
    checkEqual(rowByText["A"], 0, "老工程：A 当年在最下面那一行 → 行号 0")
    checkEqual(rowByText["B"], 1, "老工程：B 当年在它上面那一行 → 行号 1")
    checkEqual(rowByText["C"], 0, "老工程：C 和 A 共用最下面那一行")
    checkEqual(TextRows.migratedRows(for: [a, b, c]), [0, 1, 0], "迁移函数本身：层号照抄成行号")

    // ---- 个别缺行号 / 坏行号 ----
    a.row = TextOverlay.unassignedRow
    b.row = 2
    var partial = TimelineState()
    partial.textOverlays = [a, b]
    partial.normalizeTextRows()
    checkEqual(partial.textOverlays.map(\.row), [0, 1], "只有个别没行号：当 0，再收拢")
    var negative = TimelineState()
    negative.textOverlays = [TextOverlay(text: "N", timelineStart: 0, row: -4)]
    negative.normalizeTextRows()
    checkEqual(negative.textOverlays[0].row, 0, "负数行号收口成 0")

    // ---- 上下拖的落点（纯值）：行画出来的位置 —— 第 1 行在上（y 30–56），第 0 行在下（y 56–82） ----
    let rows: [(row: Int, minY: Double, maxY: Double)] = [(1, 30, 56), (0, 56, 82)]
    checkEqual(TextRows.dropTarget(y: 40, rows: rows, rowCount: 2, current: 0), 1, "落在第 1 行里")
    checkEqual(TextRows.dropTarget(y: 60, rows: rows, rowCount: 2, current: 0), nil, "落在自己那一行 = 不换")
    checkEqual(TextRows.dropTarget(y: 10, rows: rows, rowCount: 2, current: 0), 2, "比最上面那一行还高 = 顶上新开一行")
    checkEqual(TextRows.dropTarget(y: 100, rows: rows, rowCount: 2, current: 1), nil, "文字行以下 = 不换")
    checkEqual(TextRows.dropTarget(y: 40, rows: [], rowCount: 0, current: 0), nil, "没有文字行时什么都不判")
}
