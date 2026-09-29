import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - 形状 PNG
//
// 管什么：把一个形状按输出尺寸渲成整幅透明 PNG（导出叠在画面上、AI 的「看」合成时间线也用它），位置和预览里画的一致。
// 不管什么：形状的数据（VideoEditShapeModels.swift）、预览里怎么画（ShapeOverlayCanvas）、导出图里怎么叠（VideoEditExportGraph）。
// 2026-09-28 从 VideoEditExportGraph.swift 搬出来（那个文件在行数基线里只许降），同时加了实心。

/// 把一个形状按输出尺寸渲成整幅透明 PNG，位置和预览里画的一致。
enum ShapePNGRenderer {
    static func render(_ shape: ShapeAnnotation, canvas: CGSize) -> Data? {
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
        draw(shape, in: context, canvas: canvas)

        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// 在左上原点的上下文里画一个形状。
    private static func draw(_ shape: ShapeAnnotation, in context: CGContext, canvas: CGSize) {
        let color = CGColor(
            srgbRed: shape.color.red,
            green: shape.color.green,
            blue: shape.color.blue,
            alpha: shape.color.opacity
        )
        let strokeWidth = max(0.5, shape.lineWidth * canvas.height / 1080)
        let frame = shape.frame(in: canvas)

        switch shape.kind {
        case .line:
            context.saveGState()
            context.translateBy(x: frame.midX, y: frame.midY)
            context.rotate(by: shape.rotationDegrees * .pi / 180)
            context.setStrokeColor(color)
            context.setLineWidth(strokeWidth)
            context.setLineCap(.round)
            context.move(to: CGPoint(x: -frame.width / 2, y: 0))
            context.addLine(to: CGPoint(x: frame.width / 2, y: 0))
            context.strokePath()
            context.restoreGState()
        case .blur, .mosaic:
            break   // 盖一块不画东西：它的效果是导出图里的滤镜（VideoEditCoverExport），不在这张 PNG 上
        case .rectangle, .square:
            if shape.drawsFilled {
                // 实心：整块涂满、不画描边（预览是同一个框的 fill）。
                context.setFillColor(color)
                context.fill(frame)
            } else {
                context.setStrokeColor(color)
                context.setLineWidth(strokeWidth)
                // 预览用的是 strokeBorder（描边全在框内），这里也往里收半个线宽。
                context.stroke(frame.insetBy(dx: strokeWidth / 2, dy: strokeWidth / 2))
            }
        }
    }
}
