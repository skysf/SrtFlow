import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - 几帧拼成一张给 AI 看
//
// 管什么：一帧或几帧 → 一张图（几帧时排成格子，每格左上角标它的时刻）→ JPEG。一次调用只回一张图：
// 几张分开的图每张都要单独算 token，拼在一起又小又能对比。
// 不管什么：帧从哪来（AIFrameComposer / AIFrameSampler）、写文字描述（AIFrameDescription）。
//
// 排法（`grid`，纯值，自检够得着）：试每一种列数，挑拼出来最接近 4:3 的那种（横的画面排得宽、竖的画面排得高，
// 看起来都差不多方）；整张的宽按 `size` 定，单帧按长边定。

enum AIContactSheet {
    enum Size: String, CaseIterable {
        case small, medium, large

        /// 单帧时长边多少像素；几帧时整张多宽。
        var singleLongSide: Int {
            switch self {
            case .small: return 512
            case .medium: return 768
            case .large: return 1280
            }
        }

        var sheetWidth: Int {
            switch self {
            case .small: return 768
            case .medium: return 1152
            case .large: return 1536
            }
        }
    }

    struct Grid: Equatable {
        var columns: Int
        var rows: Int
    }

    /// `count` 帧、每帧宽高比 `aspect`（宽 / 高）：拼出来最接近 4:3 的那种列数。
    static func grid(count: Int, aspect: Double) -> Grid {
        let n = max(1, count)
        let target = 4.0 / 3.0
        var best = Grid(columns: n, rows: 1)
        var bestScore = Double.infinity
        for columns in 1...n {
            let rows = (n + columns - 1) / columns
            // 空格子太多的排法不要（最后一行至少要有一半是满的）。
            guard columns * rows - n < max(1, (columns + 1) / 2) else { continue }
            let score = abs(log(Double(columns) * aspect / Double(rows) / target))
            if score < bestScore {
                bestScore = score
                best = Grid(columns: columns, rows: rows)
            }
        }
        return best
    }

    /// 拼成一张。每一帧配一个标签（它的时刻）。
    static func sheet(_ frames: [(label: String, image: CGImage)], size: Size) -> CGImage? {
        guard let first = frames.first?.image else { return nil }
        let aspect = Double(first.width) / Double(max(1, first.height))
        let grid = grid(count: frames.count, aspect: aspect)
        let gap = frames.count == 1 ? 0.0 : 4.0
        var tileWidth: Double
        if frames.count == 1 {
            tileWidth = aspect >= 1 ? Double(size.singleLongSide) : Double(size.singleLongSide) * aspect
        } else {
            tileWidth = (Double(size.sheetWidth) - gap * Double(grid.columns - 1)) / Double(grid.columns)
            // 竖的画面排出来可能比宽还高很多：整张的高不超过宽的 1.25 倍（再高就只是更费 token）。
            let tallest = Double(size.sheetWidth) * 1.25
            let sheetHeight = tileWidth / aspect * Double(grid.rows)
            if sheetHeight > tallest { tileWidth *= tallest / sheetHeight }
        }
        let tileHeight = tileWidth / aspect
        let width = Int((tileWidth * Double(grid.columns) + gap * Double(grid.columns - 1)).rounded())
        let height = Int((tileHeight * Double(grid.rows) + gap * Double(grid.rows - 1)).rounded())
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else { return nil }
        context.setFillColor(CGColor(gray: 0.12, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        for (index, frame) in frames.enumerated() {
            let column = index % grid.columns
            let row = index / grid.columns
            // CG 原点在左下：第 0 行画在最上面。
            let tile = CGRect(
                x: Double(column) * (tileWidth + gap),
                y: Double(height) - Double(row + 1) * tileHeight - Double(row) * gap,
                width: tileWidth, height: tileHeight
            )
            context.draw(frame.image, in: fitted(frame.image, in: tile))
            drawLabel(frame.label, at: tile, context: context)
        }
        return context.makeImage()
    }

    /// 等比缩小到长边不超过 `maxSide`（已经够小就原样返回）。
    static func scaled(_ image: CGImage, maxSide: Int) -> CGImage? {
        let longSide = max(image.width, image.height)
        guard longSide > maxSide else { return image }
        let scale = Double(maxSide) / Double(longSide)
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    static func jpeg(_ image: CGImage, quality: Double = 0.8) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// 帧的比例和格子不一样时（几个文件拼在一起）等比放进去、居中。
    private static func fitted(_ image: CGImage, in tile: CGRect) -> CGRect {
        let scale = min(tile.width / Double(image.width), tile.height / Double(image.height))
        let size = CGSize(width: Double(image.width) * scale, height: Double(image.height) * scale)
        return CGRect(x: tile.midX - size.width / 2, y: tile.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// 左上角一块半透明黑底白字。
    private static func drawLabel(_ text: String, at tile: CGRect, context: CGContext) {
        let fontSize = max(11, min(22, tile.height / 14))
        let font = CTFontCreateWithName("Helvetica Neue Bold" as CFString, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        let padding = fontSize * 0.35
        let box = CGRect(
            x: tile.minX + 4, y: tile.maxY - 4 - bounds.height - padding * 2,
            width: bounds.width + padding * 2, height: bounds.height + padding * 2
        )
        context.setFillColor(CGColor(gray: 0, alpha: 0.6))
        context.addPath(CGPath(roundedRect: box, cornerWidth: padding, cornerHeight: padding, transform: nil))
        context.fillPath()
        context.textPosition = CGPoint(x: box.minX + padding - bounds.minX, y: box.minY + padding - bounds.minY)
        CTLineDraw(line, context)
    }
}
