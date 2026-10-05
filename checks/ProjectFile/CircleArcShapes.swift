import Foundation
import SrtFlowCore

// 第 43 组：圆和圆弧（2026-10-03，南极工程的 HUD 圆环）。`circle` / `arc` 两个种类和圆弧的 `arcSweep` 是 v30 数据：
// 只认 v29 的旧版读到不认识的种类按宽容解码退成长方形，存回去圆就成了方框 —— 所以要抬版本。`arcSweep` 按需写键（只有圆弧写），
// 缺键读作 270°；圆、圆弧的高永远等于宽。编法见 scripts/check-project-file.sh。

func checkCircleArcShapes(root: URL) throws {
    var state = TimelineState()
    let rectangle = ShapeAnnotation(kind: .rectangle, timelineStart: 0)
    state.shapes = [rectangle]
    check(!state.requiresFormatVersion30, "只有长方形：不是 v30 数据")

    var circle = ShapeAnnotation(kind: .circle, timelineStart: 0, width: 0.4, height: 0.1)
    circle.isFilled = true
    var arc = ShapeAnnotation(kind: .arc, timelineStart: 1, width: 0.3)
    arc.rotationDegrees = 45
    arc.arcSweep = 120
    checkEqual(circle.height, 0.4, "新建的圆：高等于宽")
    state.shapes = [rectangle, circle, arc]
    check(state.requiresFormatVersion30, "有圆 / 圆弧 → v30 判据为真")
    state.updateShape(circle.id) { $0.width = 0.6; $0.height = 0.2 }
    checkEqual(state.shapes[1].height, 0.6, "改圆的大小：高跟着宽（同正方形）")

    let path = root.appendingPathComponent("circle-arc.srtflowproj")
    try VideoEditProjectIO.save(state, to: path)
    let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any]
    checkEqual(raw?["formatVersion"] as? Int, 32, "带圆 / 圆弧的工程写 latest（v32）")
    let rawShapes = ((raw?["timeline"] as? [String: Any])?["shapes"] as? [[String: Any]]) ?? []
    check(rawShapes.count == 3 && rawShapes[0]["arcSweep"] == nil && rawShapes[1]["arcSweep"] == nil, "只有圆弧写 arcSweep（按需）")
    checkEqual(rawShapes.count == 3 ? rawShapes[2]["arcSweep"] as? Double : nil, 120, "圆弧写了扫过的度数")
    let back = try VideoEditProjectIO.load(from: path).timeline
    checkEqual(back.shapes.map(\.kind), [.rectangle, .circle, .arc], "往返不丢种类")
    checkEqual(back.shapes[2].arcSweep, 120, "往返不丢扫过的度数")
    checkEqual(back.shapes[2].rotationDegrees, 45, "往返不丢圆弧的起点")
    check(back.shapes[1].drawsFilled, "往返不丢圆的实心")

    // 缺 arcSweep 的圆弧（手改过的文件）：读作 270°。
    var legacy = raw ?? [:]
    var timeline = legacy["timeline"] as? [String: Any] ?? [:]
    var shapes = timeline["shapes"] as? [[String: Any]] ?? []
    if shapes.count == 3 { shapes[2].removeValue(forKey: "arcSweep") }
    timeline["shapes"] = shapes
    legacy["timeline"] = timeline
    let legacyPath = root.appendingPathComponent("circle-arc-legacy.srtflowproj")
    try JSONSerialization.data(withJSONObject: legacy).write(to: legacyPath)
    checkEqual(try VideoEditProjectIO.load(from: legacyPath).timeline.shapes.last?.arcSweep, ShapeAnnotation.defaultArcSweep,
               "缺 arcSweep 的圆弧读作 270°")
}
