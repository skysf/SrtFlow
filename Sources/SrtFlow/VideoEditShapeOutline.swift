import CoreGraphics
import Foundation

// MARK: - 圆和圆弧的轮廓（预览、导出、AI 的「看」同一份）
//
// 管什么：圆、圆弧在它自己的外接框里（左上原点、y 向下、框从 (0,0) 起）的那条路径。描边全在框内（往里收半个线宽，同长方形的
// `strokeBorder`）；圆弧从 12 点钟方向顺时针转过 `rotationDegrees` 开始、顺时针扫过 `arcSweep` 度。
// 不管什么：框在画布上哪儿（`ShapeAnnotation.frame(in:)`）、颜色线宽怎么上（预览 SwiftUI、导出 CG 各自上色）。
// 纯 CoreGraphics：预览（`Path(cgPath)`）和导出（`ShapePNGRenderer`）拿同一条 CGPath —— 圆弧从哪儿起、往哪边扫只在这里算一次。

enum ShapeOutline {
    /// 这一块的轮廓（只有圆、圆弧有；别的种类是空路径，它们各自画矩形 / 线）。`size` 是外接框的像素尺寸。
    static func path(for shape: ShapeAnnotation, size: CGSize, strokeWidth: Double) -> CGPath {
        let path = CGMutablePath()
        switch shape.kind {
        case .circle:
            let inset = shape.drawsFilled ? 0 : strokeWidth / 2
            path.addEllipse(in: CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset))
        case .arc:
            let radius = max(0, min(size.width, size.height) / 2 - strokeWidth / 2)
            // y 向下的坐标里角度变大 = 画面上顺时针；12 点钟方向是 -90°。CGPath 的 clockwise: false 就是角度变大的那个方向。
            let start = (shape.rotationDegrees - 90) * .pi / 180
            let sweep = min(max(shape.arcSweep, ShapeAnnotation.arcSweepRange.lowerBound), ShapeAnnotation.arcSweepRange.upperBound)
            path.addArc(
                center: CGPoint(x: size.width / 2, y: size.height / 2), radius: radius,
                startAngle: start, endAngle: start + sweep * .pi / 180, clockwise: false
            )
        case .line, .rectangle, .square, .blur, .mosaic:
            break
        }
        return path
    }
}
