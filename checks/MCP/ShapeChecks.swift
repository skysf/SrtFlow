import Foundation
import SrtFlowMCPKit

// set_shape（AIShapeChange）：新加要给种类、各种的默认大小（同检查器「加形状」）、夹紧（线宽 1…24、尺寸 0.02…1、线的角度 ±90°、
// 至少 0.2 秒）、正方形的高永远等于宽、只有线能转、颜色不许是 none；写回给 AI 的样子。编法见 scripts/check-mcp.sh。

func runShapeChecks() {
    checkThrows("adding needs a kind") { _ = try AIShapeChange(args(["x": 0.5])).makeShape(at: 0) }
    checkThrows("a shape needs a colour") { _ = try AIShapeChange(args(["kind": "line", "color": "none"])) }
    let line = try? AIShapeChange(args(["kind": "line", "rotation": 120, "line_width": 50])).makeShape(at: 4)
    checkEqual(line?.width, 0.3, "a new line is 0.3 of the frame long")
    checkEqual(line?.rotationDegrees, 90, "line angle is clamped to 90")
    checkEqual(line?.lineWidth, 24, "line width is clamped to 24")
    checkEqual(line?.timelineStart, 4, "a new shape starts at the playhead")
    let rectangle = try? AIShapeChange(args(["kind": "rectangle", "rotation": 30, "duration": 0.05])).makeShape(at: 0)
    checkEqual(rectangle.map { [$0.width, $0.height] }, [0.3, 0.22], "a new rectangle is 0.3 × 0.22")
    checkEqual(rectangle?.rotationDegrees, 0, "only lines turn")
    checkEqual(rectangle?.duration, 0.2, "at least 0.2 s on screen")
    let square = try? AIShapeChange(args(["kind": "square", "width": 2, "height": 0.1])).makeShape(at: 0)
    checkEqual(square.map { [$0.width, $0.height] }, [1, 1], "a square's height is its width, and sizes stop at 1")
    if var existing = rectangle {
        (try? AIShapeChange(args(["color": "#FF000080", "x": -1])))?.apply(to: &existing)
        checkEqual(existing.color.opacity, 128.0 / 255, "#RRGGBBAA sets the opacity")
        checkEqual(existing.centerX, 0, "the centre stays on the frame")
        checkEqual(existing.width, 0.3, "fields not passed are kept")
    }
    if let square {
        var state = TimelineState()
        state.shapes = [square]
        let summary = AIShapeChange.summary(square, ids: AIShortIDs(state: state))
        check(summary["height"] == nil && summary["kind"]?.stringValue == "square", "a square is reported without a separate height")
    }
}
