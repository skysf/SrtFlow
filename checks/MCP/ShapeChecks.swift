import CoreGraphics
import Foundation
import ImageIO
import SrtFlowMCPKit

// set_shape（AIShapeChange）：新加要给种类、各种的默认大小（同检查器「加形状」）、夹紧（线宽 1…24、尺寸 0.02…1、线的角度 ±90°、
// 至少 0.2 秒）、正方形的高永远等于宽、只有线能转、颜色不许是 none、实心只给长方形 / 正方形、入场 / 出场动画；写回给 AI 的样子。
// 编法见 scripts/check-mcp.sh。

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
    // 实心（2026-09-28）：长方形 / 正方形涂满、线条永远是线；回给 AI 的是 filled 而不是线宽。
    let bar = try? AIShapeChange(args(["kind": "rectangle", "filled": true, "color": "#000000", "width": 1, "height": 0.128]))
        .makeShape(at: 0)
    check(bar?.drawsFilled == true, "filled=true makes a solid rectangle")
    let filledLine = try? AIShapeChange(args(["kind": "line", "filled": true])).makeShape(at: 0)
    check(filledLine?.isFilled == false, "a line is never filled")
    if let bar {
        var state = TimelineState()
        state.shapes = [bar]
        let summary = AIShapeChange.summary(bar, ids: AIShortIDs(state: state))
        check(summary["filled"]?.boolValue == true && summary["line_width"] == nil, "a filled shape is reported as filled, without a line width")
    }
    if let square {
        var state = TimelineState()
        state.shapes = [square]
        let summary = AIShapeChange.summary(square, ids: AIShortIDs(state: state))
        check(summary["height"] == nil && summary["kind"]?.stringValue == "square", "a square is reported without a separate height")
    }
    runCircleArcChecks()
    runShapeAnimationChecks()
}

/// 入场 / 出场动画（2026-10-03）：参数名同 set_text（animation_in / animation_out / 时长）、时长夹在 0.1…5 秒、
/// 不认识的效果名报错、盖一块不收动画、只给一侧时另一侧不动；写回给 AI 的样子。
private func runShapeAnimationChecks() {
    let ring = try? AIShapeChange(args([
        "kind": "circle", "animation_in": "draw", "animation_out": "fade",
        "animation_in_duration": 9, "animation_out_duration": 0.01
    ])).makeShape(at: 0)
    checkEqual(ring?.animation.entrance, .draw, "animation_in=draw")
    checkEqual(ring?.animation.exit, .fade, "animation_out=fade")
    checkEqual(ring?.animation.entranceDuration, 5, "entrance seconds stop at 5")
    checkEqual(ring?.animation.exitDuration, 0.1, "exit seconds start at 0.1")
    checkThrows("an unknown shape animation is refused") { _ = try AIShapeChange(args(["kind": "line", "animation_in": "spin"])) }
    let blur = try? AIShapeChange(args(["kind": "blur", "animation_in": "fade"])).makeShape(at: 0)
    check(blur?.animation.isEmpty == true, "blur / mosaic take no animation")
    if var ring {
        (try? AIShapeChange(args(["animation_in": "none"])))?.apply(to: &ring)
        checkEqual(ring.animation.entrance, ShapeAnimationKind.none, "animation_in=none removes the entrance")
        checkEqual(ring.animation.exit, .fade, "the exit is kept when only the entrance changes")
        var state = TimelineState()
        state.shapes = [ring]
        let summary = AIShapeChange.summary(ring, ids: AIShortIDs(state: state))
        check(summary["animation_in"] == nil && summary["animation_out"]?.stringValue == "fade",
              "the summary reports only the animations that are set")
    }
}

/// 圆和圆弧（2026-10-03，南极工程的 HUD 圆环）：set_shape 怎么读、夹紧，画出来的真像素（导出 / AI 的「看」用的 ShapePNGRenderer，
/// 预览拿同一条 ShapeOutline 路径）—— 圆弧从 12 点钟方向顺时针转过 rotation 开始、顺时针扫过 sweep。
private func runCircleArcChecks() {
    let circle = try? AIShapeChange(args(["kind": "circle", "width": 0.5, "height": 0.1, "filled": true])).makeShape(at: 0)
    checkEqual(circle.map { [$0.width, $0.height] }, [0.5, 0.5], "a circle's height is its width")
    check(circle?.drawsFilled == true, "a circle can be filled")
    let fresh = try? AIShapeChange(args(["kind": "arc"])).makeShape(at: 0)
    checkEqual(fresh.map { [$0.width, $0.height] }, [0.2, 0.2], "a new arc has the inspector's default size")
    checkEqual(fresh?.arcSweep, 270, "a new arc sweeps 270°")
    let arc = try? AIShapeChange(args(["kind": "arc", "rotation": 270, "sweep": 400, "filled": true])).makeShape(at: 0)
    checkEqual(arc?.rotationDegrees, -90, "an arc's start is normalised like the inspector's (270 → -90)")
    checkEqual(arc?.arcSweep, ShapeAnnotation.arcSweepRange.upperBound, "sweep is clamped to 359")
    check(arc?.drawsFilled == false, "an arc is always a stroke")
    let line = try? AIShapeChange(args(["kind": "line", "rotation": 270])).makeShape(at: 0)
    checkEqual(line?.rotationDegrees, 90, "a line's angle is still clamped to ±90")
    if let arc {
        var state = TimelineState()
        state.shapes = [arc]
        let summary = AIShapeChange.summary(arc, ids: AIShortIDs(state: state))
        check(summary["sweep"]?.doubleValue == 359 && summary["rotation"]?.doubleValue == -90, "an arc is reported with its sweep and start")
    }

    // ---- 真像素：200×200 的画布，直径 100、线宽 24（1080 高时）≈ 4.4 px，圆心 (100, 100)、描边中线半径 ≈ 47.8 ----
    let canvas = CGSize(width: 200, height: 200)
    func shape(_ kind: ShapeKind, rotation: Double = 0, sweep: Double = 270) -> ShapeAnnotation {
        var shape = ShapeAnnotation(kind: kind, timelineStart: 0, color: .white, lineWidth: 24, width: 0.5)
        shape.rotationDegrees = rotation
        shape.arcSweep = sweep
        return shape
    }
    /// 角度从 12 点钟方向顺时针量。
    func alpha(_ shape: ShapeAnnotation, clockFrom12 degrees: Double, radius: Double = 47.8) -> UInt8? {
        let theta = (degrees - 90) * .pi / 180
        return renderedAlpha(shape, canvas: canvas, x: 100 + radius * cos(theta), y: 100 + radius * sin(theta))
    }
    let ring = shape(.circle)
    check((alpha(ring, clockFrom12: 0) ?? 0) > 200 && (alpha(ring, clockFrom12: 200) ?? 0) > 200, "a circle outline is drawn all round")
    check((renderedAlpha(ring, canvas: canvas, x: 100, y: 100) ?? 255) < 20, "a circle outline is empty inside")
    check((renderedAlpha(ring, canvas: canvas, x: 53, y: 53) ?? 255) < 20, "the corner of a circle's box is empty (it is round, not square)")
    let quarter = shape(.arc, rotation: 0, sweep: 90)
    check((alpha(quarter, clockFrom12: 45) ?? 0) > 200, "an arc from 12 sweeping 90° covers 1:30")
    check((alpha(quarter, clockFrom12: 180) ?? 255) < 20 && (alpha(quarter, clockFrom12: 270) ?? 255) < 20,
          "and not 6 or 9 o'clock (it goes clockwise, not counter-clockwise)")
    let turned = shape(.arc, rotation: 180, sweep: 90)
    check((alpha(turned, clockFrom12: 225) ?? 0) > 200 && (alpha(turned, clockFrom12: 45) ?? 255) < 20,
          "rotation 180 starts the arc at 6 o'clock")
}

/// ShapePNGRenderer 渲出来那张图在 (x, y)（左上原点）的 alpha。
private func renderedAlpha(_ shape: ShapeAnnotation, canvas: CGSize, x: Double, y: Double) -> UInt8? {
    guard let data = ShapePNGRenderer.render(shape, canvas: canvas),
          let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
        guard let context = CGContext(
            data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    let column = Int(x.rounded()), row = Int(y.rounded())
    guard drawn, (0..<width).contains(column), (0..<height).contains(row) else { return nil }
    return pixels[(row * width + column) * 4 + 3]
}
