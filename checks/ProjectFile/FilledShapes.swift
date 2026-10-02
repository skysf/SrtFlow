import Foundation
import SrtFlowCore

// 第 36 组：实心的长方形 / 正方形（2026-09-28，MCP 第 5 块补的零件：电影遮幅、色块底）。
// `ShapeAnnotation.isFilled` 是 v24 数据：按需写键（描边的不落键）、缺键读作描边、判据和写键同源；
// 线条永远画成线（`drawsFilled` 为假）。编法见 scripts/check-project-file.sh。

func checkFilledShapes(root: URL) throws {
    let outline = ShapeAnnotation(kind: .rectangle, timelineStart: 0)
    var bar = ShapeAnnotation(kind: .rectangle, timelineStart: 0, color: .black, centerY: 0.064, width: 1, height: 0.128)
    bar.isFilled = true
    var line = ShapeAnnotation(kind: .line, timelineStart: 0)
    line.isFilled = true
    check(bar.drawsFilled, "实心的长方形画成实心")
    check(!outline.drawsFilled, "描边的长方形画描边")
    check(!line.drawsFilled, "线条就算标了实心也画成线")

    var state = TimelineState()
    state.shapes = [outline]
    check(!state.requiresFormatVersion24, "只有描边的形状：不是 v24 数据（按需）")
    let path = root.appendingPathComponent("filled-shapes.srtflowproj")
    try VideoEditProjectIO.save(state, to: path)
    let cleanRaw = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any]
    let cleanShapes = ((cleanRaw?["timeline"] as? [String: Any])?["shapes"] as? [[String: Any]]) ?? []
    check(!cleanShapes.isEmpty && cleanShapes.allSatisfy { $0["isFilled"] == nil }, "描边的形状不写 isFilled 键（与判据同源）")
    checkEqual(try VideoEditProjectIO.load(from: path).timeline.shapes.first?.isFilled, false, "缺键读作描边（v23 及更早只有描边）")

    state.shapes = [outline, bar]
    check(state.requiresFormatVersion24, "有实心的形状 → v24 判据为真")
    try VideoEditProjectIO.save(state, to: path)
    let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any]
    checkEqual(raw?["formatVersion"] as? Int, 29, "带实心形状的工程写 latest（v29）")
    let back = try VideoEditProjectIO.load(from: path).timeline
    checkEqual(back.shapes.map(\.isFilled), [false, true], "往返不丢实心")
    checkEqual(back.shapes.last?.color, .black, "往返不丢颜色")
}
