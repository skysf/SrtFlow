import CoreGraphics
import SrtFlowCore
import SwiftUI

// 一、预览 = 导出：同一块形状、同一个动画状态，预览那个画法离屏渲一张，和导出那张逐像素比。
// 白色的形状画在不透明的黑底上，量亮度（= 不透明度）。比三样：最亮的那一点（透明度两边乘得一样）、墨迹的外框（线头、截到哪、
// 缩放的中心）、墨迹重合度和平均差（裁剪、笔顺）。
// 黑底不是装饰：`ImageRenderer` 渲透明底时，内容什么都没画就把上一张图原样还回来（2026-10-03 实测，「画了 0」那几条撞出来的）。

private let parityCanvas = CGSize(width: 960, height: 540)

/// 铺在黑底上取红色通道（白色的形状：亮度就是不透明度）。重新画一遍到自己的缓冲里，不猜 CGImage 内部的排布。
func inkPlane(_ image: CGImage, size: CGSize) -> [UInt8]? {
    let width = Int(size.width), height = Int(size.height)
    guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let ok = bytes.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(
            data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    return ok ? stride(from: 0, to: bytes.count, by: 4).map { bytes[$0] } : nil
}

/// 预览那条路：`ShapeOverlayCanvas` 里同样的摆法（左上对齐的整块画布、按中心 `.position`）。
@MainActor
private func previewImage(_ shape: ShapeAnnotation, state: ShapeAnimationState) -> CGImage? {
    let frame = shape.frame(in: parityCanvas)
    let strokeWidth = shape.strokeWidth(in: parityCanvas)
    let renderer = ImageRenderer(content: ZStack(alignment: .topLeading) {
        Color.black
        ShapePreviewDrawing.view(
            shape, size: ShapePreviewDrawing.size(of: shape, frame: frame, strokeWidth: strokeWidth),
            strokeWidth: strokeWidth, state: state
        )
        .position(x: shape.centerX * parityCanvas.width, y: shape.centerY * parityCanvas.height)
    }.frame(width: parityCanvas.width, height: parityCanvas.height))
    renderer.scale = 1
    renderer.isOpaque = true
    return renderer.cgImage
}

private func makeShape(
    _ kind: ShapeKind, width: Double, height: Double = 0.3, rotation: Double = 0, filled: Bool = false, sweep: Double = 270
) -> ShapeAnnotation {
    var shape = ShapeAnnotation(kind: kind, timelineStart: 0, color: .white, lineWidth: 18, width: width, height: height,
                                rotationDegrees: rotation)
    shape.isFilled = filled
    shape.arcSweep = sweep
    return shape
}

/// 墨迹（alpha 过了一半）的外框，像素。
private func inkBox(_ alpha: [UInt8], threshold: UInt8) -> CGRect? {
    let width = Int(parityCanvas.width)
    var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
    for (index, value) in alpha.enumerated() where value > threshold {
        let x = index % width, y = index / width
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
    }
    return maxX < 0 ? nil : CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
}

private func format(_ value: Double) -> String { String(format: "%.3f", value) }

@MainActor
func runParityChecks() async {
    let line = makeShape(.line, width: 0.5, rotation: 30)
    let rectangle = makeShape(.rectangle, width: 0.4)
    let block = makeShape(.square, width: 0.25, filled: true)
    let circle = makeShape(.circle, width: 0.3)
    let disc = makeShape(.circle, width: 0.3, filled: true)
    let arc = makeShape(.arc, width: 0.35, rotation: 30, sweep: 240)
    let cases: [(name: String, shape: ShapeAnnotation, state: ShapeAnimationState)] = [
        ("线（转 30°）", line, .identity),
        ("线画到四成", line, ShapeAnimationState(drawn: 0.4)),
        ("线擦除到六成", line, ShapeAnimationState(wipe: 0.6)),
        ("线弹性缩放起手（缩到 0.79、淡到两成）", line, ShapeAnimationState(opacity: 0.2, scale: ShapeAnimator.popStartScale)),
        ("长方形描边", rectangle, .identity),
        ("长方形描边画到六成", rectangle, ShapeAnimationState(drawn: 0.6)),
        ("长方形描边擦除到三成", rectangle, ShapeAnimationState(wipe: 0.3)),
        ("实心正方形", block, .identity),
        ("实心正方形画到一半（从左往右露）", block, ShapeAnimationState(drawn: 0.5)),
        ("圆描边画到七成", circle, ShapeAnimationState(drawn: 0.7)),
        ("圆描边弹出冲过头（1.08）", circle, ShapeAnimationState(opacity: 0.9, scale: 1.08)),
        ("实心圆画到三成（从 12 点扫出来）", disc, ShapeAnimationState(drawn: 0.3)),
        ("圆弧（起点 30°、扫 240°）画到一半", arc, ShapeAnimationState(drawn: 0.5)),
        ("圆弧淡到一半", arc, ShapeAnimationState(opacity: 0.5))
    ]
    for item in cases {
        guard let exported = ShapePNGRenderer.image(item.shape, canvas: parityCanvas, state: item.state),
              let previewed = previewImage(item.shape, state: item.state),
              let e = inkPlane(exported, size: parityCanvas), let p = inkPlane(previewed, size: parityCanvas) else {
            check(false, "\(item.name)：渲不出来")
            continue
        }
        let maxE = e.max() ?? 0, maxP = p.max() ?? 0
        check(maxE > 0, "\(item.name)：导出那张画出了东西")
        check(abs(Int(maxE) - Int(maxP)) <= 3, "\(item.name)：最不透明的一点两边一样（导出 \(maxE)、预览 \(maxP)）")
        let threshold = UInt8(max(1, Int(maxE) / 2))
        var union = 0, inter = 0, diff = 0.0, touched = 0
        for index in e.indices {
            let a = e[index] > threshold, b = p[index] > threshold
            if a || b { union += 1 }
            if a && b { inter += 1 }
            if e[index] > 0 || p[index] > 0 {
                diff += abs(Double(e[index]) - Double(p[index]))
                touched += 1
            }
        }
        let overlap = union == 0 ? 0 : Double(inter) / Double(union)
        let meanDiff = touched == 0 ? 0 : diff / Double(touched) / Double(max(1, maxE))
        check(overlap >= 0.97, "\(item.name)：两边的墨迹重合（\(format(overlap))，应 ≥ 0.97）")
        check(meanDiff <= 0.08, "\(item.name)：逐像素平均差（\(format(meanDiff))，应 ≤ 0.08）")
        if let boxE = inkBox(e, threshold: threshold), let boxP = inkBox(p, threshold: threshold) {
            let off = max(abs(boxE.minX - boxP.minX), abs(boxE.maxX - boxP.maxX), abs(boxE.minY - boxP.minY), abs(boxE.maxY - boxP.maxY))
            check(off <= 1.5, "\(item.name)：墨迹的外框差 \(off) 像素（导出 \(boxE)、预览 \(boxP)），应 ≤ 1.5")
        } else {
            check(false, "\(item.name)：量不出墨迹的外框")
        }
    }

    // 画了 0 / 擦了 0：两边都什么都没有（圆线头的零长线段会画出一个点，擦除露出一条抗锯齿的边 —— 都不许）。
    for (name, shape, state) in [("线画了 0", line, ShapeAnimationState(drawn: 0)),
                                 ("长方形擦了 0", rectangle, ShapeAnimationState(wipe: 0)),
                                 ("实心圆画了 0", disc, ShapeAnimationState(drawn: 0))] {
        let e = ShapePNGRenderer.image(shape, canvas: parityCanvas, state: state).flatMap { inkPlane($0, size: parityCanvas) }
        let p = previewImage(shape, state: state).flatMap { inkPlane($0, size: parityCanvas) }
        check(e?.max() == 0 && p?.max() == 0, "\(name)：两边都是空的（导出最大 \(e?.max() ?? 255)、预览最大 \(p?.max() ?? 255)）")
    }
}
