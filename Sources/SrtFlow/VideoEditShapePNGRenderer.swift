import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - 形状 PNG
//
// 管什么：把一个形状按输出尺寸、按这一刻的动画状态渲成整幅透明 PNG（导出叠在画面上、AI 的「看」合成时间线也用它），
// 位置和预览里画的一致。画什么（路径、线头、截到哪、露出哪一块）只问 `ShapeOutline.drawing`，这里只上色。
// 不管什么：形状的数据（VideoEditShapeModels.swift）、动画求值（`ShapeAnimator`）、预览里怎么画（`ShapePreviewDrawing`）、
// 导出里怎么切段叠上去（`ShapeOverlayExport`、`OverlayExportFile`）。
// 2026-09-28 从 VideoEditExportGraph.swift 搬出来（那个文件在行数基线里只许降），同时加了实心。

/// 把一个形状按输出尺寸渲成整幅透明 PNG，位置和预览里画的一致。
enum ShapePNGRenderer {
    static func render(_ shape: ShapeAnnotation, canvas: CGSize, state: ShapeAnimationState = .identity) -> Data? {
        guard let image = image(shape, canvas: canvas, state: state) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// 同一张图，不编成 PNG（自检拿它和预览逐像素比）。
    static func image(_ shape: ShapeAnnotation, canvas: CGSize, state: ShapeAnimationState = .identity) -> CGImage? {
        let width = Int(canvas.width)
        let height = Int(canvas.height)
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }

        // CG 的原点在左下，翻一下让坐标和预览（左上原点）一致。
        context.translateBy(x: 0, y: canvas.height)
        context.scaleBy(x: 1, y: -1)
        draw(shape, in: context, canvas: canvas, state: state)
        return context.makeImage()
    }

    /// 在左上原点的上下文里画一个形状。盖一块不画东西：它的效果是导出图里的滤镜（VideoEditCoverExport），不在这张 PNG 上。
    private static func draw(_ shape: ShapeAnnotation, in context: CGContext, canvas: CGSize, state: ShapeAnimationState) {
        guard !shape.kind.isCover else { return }
        let strokeWidth = shape.strokeWidth(in: canvas)
        let frame = shape.frame(in: canvas)
        // 线条的框高是 0：线画在框的正中，也就是 (centerX, centerY)。
        let drawing = ShapeOutline.drawing(for: shape, size: frame.size, strokeWidth: strokeWidth, state: state)
        let color = CGColor(
            srgbRed: shape.color.red,
            green: shape.color.green,
            blue: shape.color.blue,
            alpha: shape.color.opacity
        )

        context.saveGState()
        context.translateBy(x: frame.minX, y: frame.minY)
        if let reveal = drawing.reveal {
            context.addPath(reveal)
            context.clip()
        }
        context.setAlpha(drawing.opacity)
        context.addPath(drawing.path)
        if drawing.filled {
            context.setFillColor(color)
            context.fillPath()
        } else {
            context.setStrokeColor(color)
            context.setLineWidth(strokeWidth)
            context.setLineCap(drawing.lineCap)
            context.setLineJoin(.miter)
            context.strokePath()
        }
        context.restoreGState()
    }
}
