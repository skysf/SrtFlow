import CoreGraphics
import Foundation

// MARK: - 形状这一刻怎么画（预览、导出、AI 的「看」同一份）
//
// 管什么：一块形状（线条、长方形、正方形、圆、圆弧）在它自己的框里（左上原点、y 向下、框从 (0,0) 起）画成哪条路径、涂满还是描边、
// 线头圆不圆，以及入场 / 出场动画此刻把它截到哪、缩多少、露出哪一块、多透明（`ShapeAnimationState` 由 `ShapeAnimator` 求）。
// 不管什么：框在画布上哪儿（`ShapeAnnotation.frame(in:)`）、颜色怎么上（预览 `ShapePreviewDrawing`、导出 `ShapePNGRenderer` 各自上色）。
//
// 纯 CoreGraphics：预览（`Path(cgPath)`）和导出拿同一条 CGPath，所以笔顺、线头、描边收在框内几个像素这些事只在这里算一次
//（2026-10-03 起所有种类都走这里；之前线条和长方形预览、导出各画一份，导出的线两头各多出半个线宽）。
//
// 几条口径（docs/architecture/shapes.md）：
// - 描边全在框内（往里收半个线宽，同 SwiftUI 的 `strokeBorder`）；线条的可见长度就是 `width`（圆线头在长度以内）。
// - 圆弧从 12 点钟方向顺时针转过 `rotationDegrees` 开始、顺时针扫过 `arcSweep` 度。
// - 「画出来」的笔顺：线从左端（转过角度后的那一端）起；长方形从左上角顺时针；圆从 12 点钟顺时针；圆弧从它的起点。
//   实心的不截路径，顺着同一个方向露出来：长方形从左往右、圆从 12 点钟顺时针扫一圈。
// - 缩放只缩几何、不缩线宽，绕框的中心。

enum ShapeOutline {
    /// 一块形状这一刻怎么画。
    struct Drawing {
        var path: CGPath
        /// true = 涂满；false = 按线宽描边。
        var filled: Bool
        /// 描边的线头：线条、圆、圆弧是圆头；长方形、正方形是平头（转角是尖角）。
        var lineCap: CGLineCap
        /// 只露出这一块（擦除；实心的「画出来」）。nil = 不裁。
        var reveal: CGPath?
        /// 整个形状的不透明度乘数（颜色自己的透明度另算）。
        var opacity: Double
    }

    /// `size`：框的尺寸（线条：宽就是长度，高随意，线画在框的正中）。路径、露出的那一块都在框自己的坐标里。
    static func drawing(
        for shape: ShapeAnnotation, size: CGSize, strokeWidth: Double, state: ShapeAnimationState = .identity
    ) -> Drawing {
        let filled = shape.drawsFilled
        let drawn = min(max(state.drawn ?? 1, 0), 1)
        let squareCorners = shape.kind == .rectangle || shape.kind == .square
        let lineCap: CGLineCap = squareCorners ? .butt : .round
        // 还什么都没露出来：给空路径，**不许**用「裁到一块空区域」来表达 —— CoreGraphics 拿空路径 clip 等于没裁，
        // 导出会把整块画出来（预览的 mask 却是全遮住），两边对不上（2026-10-03 自检撞出来的）。
        if (state.wipe ?? 1) <= 0 || (filled && drawn <= 0) {
            return Drawing(path: CGMutablePath(), filled: filled, lineCap: lineCap, reveal: nil, opacity: state.opacity)
        }
        // 实心的「画出来」不截路径，按同一个方向露出来（下面的 reveal）。
        var path = outline(for: shape, size: size, strokeWidth: strokeWidth, drawn: filled ? 1 : drawn)
        if state.scale != 1 {
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            var transform = CGAffineTransform(translationX: center.x, y: center.y)
                .scaledBy(x: state.scale, y: state.scale)
                .translatedBy(x: -center.x, y: -center.y)
            path = path.copy(using: &transform) ?? path
        }
        var reveal: CGPath?
        if let wipe = state.wipe, wipe < 1 {
            reveal = wipeArea(for: shape, size: size, strokeWidth: strokeWidth, fraction: wipe)
        } else if filled, drawn < 1 {
            reveal = shape.kind == .circle
                ? sweepArea(size: size, fraction: drawn)
                : wipeArea(for: shape, size: size, strokeWidth: strokeWidth, fraction: drawn)
        }
        return Drawing(path: path, filled: filled, lineCap: lineCap, reveal: reveal, opacity: state.opacity)
    }

    /// 整条（或画到 `drawn` 那么多的）轮廓。`drawn` ≤ 0 时是空路径 —— 圆线头的零长线段会画出一个点。
    private static func outline(for shape: ShapeAnnotation, size: CGSize, strokeWidth: Double, drawn: Double) -> CGPath {
        let path = CGMutablePath()
        guard drawn > 0 else { return path }
        let box = CGRect(origin: .zero, size: size)
        let inset = shape.drawsFilled ? 0 : strokeWidth / 2
        switch shape.kind {
        case .line:
            // 圆线头在长度以内：线段两端各往里收半个线宽，可见长度正好是 width（线比线宽还短时缩成一个点）。
            let half = max(0, size.width / 2 - strokeWidth / 2)
            let angle = shape.rotationDegrees * .pi / 180
            let center = CGPoint(x: box.midX, y: box.midY)
            let start = CGPoint(x: center.x - half * cos(angle), y: center.y - half * sin(angle))
            let end = CGPoint(x: center.x + half * cos(angle), y: center.y + half * sin(angle))
            path.move(to: start)
            path.addLine(to: CGPoint(x: start.x + (end.x - start.x) * drawn, y: start.y + (end.y - start.y) * drawn))
        case .rectangle, .square:
            let rect = insetBox(box, by: inset)
            if drawn >= 1 {
                path.addRect(rect)
            } else {
                addPerimeter(of: rect, fraction: drawn, to: path)
            }
        case .circle:
            let rect = insetBox(box, by: inset)
            if drawn >= 1 {
                path.addEllipse(in: rect)
            } else {
                // y 向下的坐标里角度变大 = 画面上顺时针；12 点钟方向是 -90°。CGPath 的 clockwise: false 就是角度变大的那个方向。
                let start = -Double.pi / 2
                path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: rect.width / 2,
                            startAngle: start, endAngle: start + 2 * .pi * drawn, clockwise: false)
            }
        case .arc:
            let radius = max(0, min(size.width, size.height) / 2 - strokeWidth / 2)
            let start = (shape.rotationDegrees - 90) * .pi / 180
            let sweep = min(max(shape.arcSweep, ShapeAnnotation.arcSweepRange.lowerBound), ShapeAnnotation.arcSweepRange.upperBound)
            path.addArc(
                center: CGPoint(x: box.midX, y: box.midY), radius: radius,
                startAngle: start, endAngle: start + sweep * .pi / 180 * drawn, clockwise: false
            )
        case .blur, .mosaic:
            break   // 盖一块不画东西
        }
        return path
    }

    /// 框往里收（收过头时缩成中心的一个点，不让 `insetBy` 吐出 null 框）。
    private static func insetBox(_ box: CGRect, by inset: Double) -> CGRect {
        let rect = box.insetBy(dx: min(inset, box.width / 2), dy: min(inset, box.height / 2))
        return rect.isNull ? CGRect(x: box.midX, y: box.midY, width: 0, height: 0) : rect
    }

    /// 长方形的边从左上角顺时针走 `fraction` 那么长。
    private static func addPerimeter(of rect: CGRect, fraction: Double, to path: CGMutablePath) {
        let corners = [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.minY)
        ]
        var remaining = 2 * (rect.width + rect.height) * fraction
        path.move(to: corners[0])
        for index in 1..<corners.count {
            let from = corners[index - 1]
            let to = corners[index]
            let length = hypot(to.x - from.x, to.y - from.y)
            if remaining >= length {
                path.addLine(to: to)
                remaining -= length
            } else {
                let t = length > 0 ? remaining / length : 0
                path.addLine(to: CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
                return
            }
        }
    }

    /// 这块形状看得见的那个框（线条：转过角度之后连线头的外接框；别的：框本身，描边在框内）。擦除在它上面从左往右走。
    static func visibleBox(for shape: ShapeAnnotation, size: CGSize, strokeWidth: Double) -> CGRect {
        let box = CGRect(origin: .zero, size: size)
        guard shape.kind == .line else { return box }
        let angle = shape.rotationDegrees * .pi / 180
        let half = size.width / 2
        let halfWidth = abs(half * cos(angle)) + abs(strokeWidth / 2 * sin(angle))
        let halfHeight = abs(half * sin(angle)) + abs(strokeWidth / 2 * cos(angle))
        return CGRect(x: box.midX - halfWidth, y: box.midY - halfHeight, width: 2 * halfWidth, height: 2 * halfHeight)
    }

    /// 擦除露出来的那一块：可见框左起 `fraction` 那么宽（左、上、下多给一两个像素，免得切掉边上的抗锯齿）。
    /// `fraction` > 0（什么都不露的情况在 `drawing` 里先挡掉了）。
    private static func wipeArea(for shape: ShapeAnnotation, size: CGSize, strokeWidth: Double, fraction: Double) -> CGPath {
        let visible = visibleBox(for: shape, size: size, strokeWidth: strokeWidth)
        let width = visible.width * min(max(fraction, 0), 1)
        return CGPath(rect: CGRect(x: visible.minX - 1, y: visible.minY - 2, width: width + 1, height: visible.height + 4), transform: nil)
    }

    /// 实心圆「画出来」露出来的那一块：从 12 点钟方向顺时针扫过 `fraction` 圈的扇形（半径给到框的对角线，盖得住整个圆）。
    /// `fraction` > 0（同上）。
    private static func sweepArea(size: CGSize, fraction: Double) -> CGPath {
        let path = CGMutablePath()
        let turn = min(max(fraction, 0), 1)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let start = -Double.pi / 2
        path.move(to: center)
        path.addArc(center: center, radius: hypot(size.width, size.height),
                    startAngle: start, endAngle: start + 2 * .pi * turn, clockwise: false)
        path.closeSubpath()
        return path
    }
}
