import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - set_shape：画面上的线、长方形、正方形、圆、圆弧，和盖一块（模糊 / 马赛克）（纯值）
//
// 管什么：AI 给的参数读成类型，加一个新形状或改一个已有的（只改给了的字段），夹紧照检查器 / 预览里拖的那一套：
// 线宽 1…24（1080 高画面上的像素）、宽高 0.02…1（画面的比例）、线的角度 ±90°、至少 0.2 秒；中心 0…1。
// 圆弧（2026-10-03）：`rotation` 是从 12 点钟方向顺时针转过多少开始（收进 (-180, 180]）、`sweep` 扫过多少度（1…359）。
// 盖一块（blur / mosaic，2026-09-29）不画东西，颜色 / 线宽 / 实心 / 旋转都没有意义；`strength` 是模糊的半径 / 马赛克每格的边长（2…80）。
// 正方形的高永远等于宽（`TimelineState.updateShape` 那条规矩）；实心只对长方形 / 正方形（线条永远是线）。以及写回给 AI 看。
// 不管什么：提交和撤销（AIOverlayTools / 路由）、删除（delete_items 本来就认形状）。
// 模型见 VideoEditShapeModels.swift：形状按数组顺序画（后加的在上面），文字压在形状之上。

struct AIShapeChange {
    var kind: ShapeKind?
    var start: Double?
    var duration: Double?
    var x: Double?
    var y: Double?
    var width: Double?
    var height: Double?
    var rotation: Double?
    var color: SubtitleColor?
    var lineWidth: Double?
    var strength: Double?
    var sweep: Double?
    var filled: Bool?
    var hidden: Bool?

    static let kindNames = ShapeKind.allCases.map(\.rawValue)

    init(_ args: AIToolArguments) throws {
        kind = try args.choice("kind", from: Self.kindNames).flatMap(ShapeKind.init(rawValue:))
        start = try args.double("start").map { max(0, $0) }
        duration = try args.double("duration").map { max(0.2, $0) }
        x = try args.double("x").map { min(max($0, 0), 1) }
        y = try args.double("y").map { min(max($0, 0), 1) }
        width = try (args.double("width") ?? args.double("length")).map { min(max($0, 0.02), 1) }
        height = try args.double("height").map { min(max($0, 0.02), 1) }
        // 线条夹在 ±90°、圆弧收进 (-180, 180]：按种类在 apply 里收（这时还不知道改的是哪一种）。
        rotation = try args.double("rotation")
        sweep = try args.double("sweep").map { min(max($0, ShapeAnnotation.arcSweepRange.lowerBound), ShapeAnnotation.arcSweepRange.upperBound) }
        if let text = try args.string("color") {
            guard let parsed = try AIColor.parse(text) else { throw AIToolError("A shape needs a colour; \"none\" is not allowed.") }
            color = parsed
        }
        lineWidth = try args.double("line_width").map { min(max($0, 1), 24) }
        strength = try args.double("strength").map { min(max($0, ShapeKind.coverAmountRange.lowerBound), ShapeKind.coverAmountRange.upperBound) }
        filled = try args.bool("filled")
        hidden = try args.bool("hidden")
    }

    /// 新形状：没给的用检查器「加形状」的默认大小（`ShapeKind.defaultSize`，同一份）。
    func makeShape(at playhead: Double) throws -> ShapeAnnotation {
        guard let kind else {
            throw AIToolError("kind is required when adding a shape: line, rectangle, square, circle, arc, blur or mosaic.")
        }
        let size = kind.defaultSize
        var shape = ShapeAnnotation(kind: kind, timelineStart: start ?? playhead, width: size.width, height: size.height)
        apply(to: &shape)
        return shape
    }

    func apply(to shape: inout ShapeAnnotation) {
        if let kind { shape.kind = kind }
        if let start { shape.timelineStart = start }
        if let duration { shape.duration = duration }
        if let x { shape.centerX = x }
        if let y { shape.centerY = y }
        if let width { shape.width = width }
        if let height { shape.height = height }
        if let rotation { shape.rotationDegrees = rotation }
        if let color { shape.color = color }
        if let lineWidth { shape.lineWidth = lineWidth }
        if let strength { shape.coverAmount = strength }
        if let sweep { shape.arcSweep = sweep }
        if let filled { shape.isFilled = filled }
        if let hidden { shape.isHidden = hidden }
        if shape.kind.keepsSquare { shape.height = shape.width }
        switch shape.kind {
        case .line: shape.rotationDegrees = min(max(shape.rotationDegrees, -90), 90)
        case .arc: shape.rotationDegrees = Self.normalized(shape.rotationDegrees)
        default: shape.rotationDegrees = 0
        }
        if shape.kind == .line || shape.kind == .arc || shape.kind.isCover { shape.isFilled = false }
    }

    /// 收进 (-180, 180]（同文字的旋转、检查器的「起始角」）。
    private static func normalized(_ degrees: Double) -> Double {
        var angle = degrees.truncatingRemainder(dividingBy: 360)
        if angle > 180 { angle -= 360 }
        if angle <= -180 { angle += 360 }
        return angle.isFinite ? angle : 0
    }

    static func summary(_ shape: ShapeAnnotation, ids: AIShortIDs) -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(ids.short(shape.id)),
            "kind": .string(shape.kind.rawValue),
            "start": AIFormat.seconds(shape.timelineStart),
            "end": AIFormat.seconds(shape.timelineEnd),
            "x": AIFormat.seconds(shape.centerX),
            "y": AIFormat.seconds(shape.centerY),
            "width": AIFormat.seconds(shape.width)
        ]
        if shape.kind.isCover {
            // 盖一块不画东西：没有颜色 / 线宽，只有力度和高。
            object["strength"] = AIFormat.seconds(shape.coverAmount)
            object["height"] = AIFormat.seconds(shape.height)
        } else {
            object["color"] = .string(AIColor.hex(shape.color))
            if shape.drawsFilled { object["filled"] = true } else { object["line_width"] = AIFormat.seconds(shape.lineWidth) }
        }
        if shape.kind == .rectangle { object["height"] = AIFormat.seconds(shape.height) }
        if shape.kind == .line, abs(shape.rotationDegrees) > 0.01 { object["rotation"] = AIFormat.seconds(shape.rotationDegrees) }
        if shape.kind == .arc {
            object["sweep"] = AIFormat.seconds(shape.arcSweep)
            object["rotation"] = AIFormat.seconds(shape.rotationDegrees)
        }
        if shape.isHidden { object["hidden"] = true }
        return .object(object)
    }
}
