import CoreGraphics
import CoreImage
import Foundation

// MARK: - 把盖一块盖到一帧上（AI 的「看」合成用）
//
// 管什么：AI 的「看」（`AIFrameComposer`）合成一帧时，把此刻的盖一块盖上去 —— 每一块裁出来、跑 `CoverFilters` 那几个 CIFilter、
// 贴回原位；框取偶数、力度按画面高换算，和导出（`VideoEditCoverExport`）同一个函数出的数。AI 盖完之后靠这一步核对盖没盖住。
// 不管什么：预览怎么盖（CoverPreviewLayer，图层）、导出（ffmpeg 滤镜）。

enum CoverCompositing {
    static func apply(_ covers: [ShapeAnnotation], to image: CGImage) -> CGImage {
        guard !covers.isEmpty else { return image }
        let size = CGSize(width: image.width, height: image.height)
        var output = CIImage(cgImage: image)
        for cover in covers {
            guard let rect = VideoEditCoverExport.pixelRect(cover, canvas: size) else { continue }
            // pixelRect 是左上原点的像素框，CoreImage 是左下原点。
            let box = CGRect(x: rect.minX, y: size.height - rect.maxY, width: rect.width, height: rect.height)
            var region = output.cropped(to: box).transformed(by: CGAffineTransform(translationX: -box.minX, y: -box.minY))
            let amount = VideoEditCoverExport.pixels(cover.coverAmount, canvas: size)
            for filter in CoverFilters.ciFilters(kind: cover.kind, amount: amount, regionHeight: rect.height) {
                filter.setValue(region, forKey: kCIInputImageKey)
                if let next = filter.outputImage { region = next }
            }
            region = region.cropped(to: CGRect(origin: .zero, size: box.size)).transformed(by: CGAffineTransform(translationX: box.minX, y: box.minY))
            output = region.composited(over: output)
        }
        return context.createCGImage(output, from: CGRect(origin: .zero, size: size), format: .RGBA8, colorSpace: image.colorSpace ?? CGColorSpaceCreateDeviceRGB()) ?? image
    }

    private static let context = CIContext()
}
