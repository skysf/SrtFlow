import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - set_shape：画面上的线、长方形、正方形，和盖一块（模糊 / 马赛克）（纯值）
//
// 管什么：AI 给的参数读成类型，加一个新形状或改一个已有的（只改给了的字段），夹紧照检查器 / 预览里拖的那一套：
// 线宽 1…24（1080 高画面上的像素）、宽高 0.02…1（画面的比例）、线的角度 ±90°、至少 0.2 秒；中心 0…1。
// 盖一块（blur / mosaic，2026-09-30）不画东西，颜色 / 线宽 / 实心 / 旋转都没有意义；`strength` 是模糊的半径 / 马赛克每格的边长（2…80）。
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
        rotation = try args.double("rotation").map { min(max($0, -90), 90) }
        if let text = try args.string("color") {
            guard let parsed = try AIColor.parse(text) else { throw AIToolError("A shape needs a colour; \"none\" is not allowed.") }
            color = parsed
        }
        lineWidth = try args.double("line_width").map { min(max($0, 1), 24) }
        strength = try args.double("strength").map { min(max($0, ShapeKind.coverAmountRange.lowerBound), ShapeKind.coverAmountRange.upperBound) }
        filled = try args.bool("filled")
        hidden = try args.bool("hidden")
    }

    /// 新形状：没给的用检查器「加形状」的默认大小（线 0.3 长、长方形 0.3 × 0.22、正方形 0.2）。
    func makeShape(at playhead: Double) throws -> ShapeAnnotation {
        guard let kind else { throw AIToolError("kind is required when adding a shape: line, rectangle, square, blur or mosaic.") }
        let size: (Double, Double) = switch kind {
        case .line: (0.3, 0)
        case .rectangle, .blur, .mosaic: (0.3, 0.22)
        case .square: (0.2, 0.2)
        }
        var shape = ShapeAnnotation(kind: kind, timelineStart: start ?? playhead, width: size.0, height: size.1)
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
        if let filled { shape.isFilled = filled }
        if let hidden { shape.isHidden = hidden }
        if shape.kind == .square { shape.height = shape.width }
        if shape.kind != .line { shape.rotationDegrees = 0 }
        if shape.kind == .line || shape.kind.isCover { shape.isFilled = false }
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
        if shape.isHidden { object["hidden"] = true }
        return .object(object)
    }
}
