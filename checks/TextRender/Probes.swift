import CoreGraphics
import Foundation

// 渲染图的探针：alpha 蒙版、挑「一定是字」和「一定不是字」的点、位图最外圈是不是透明。
// 从 main.swift 拆出来（那个文件超过 600 行、只许降）；用例在 main.swift 和 FontFallback.swift 里。

func alphaMask(_ image: CGImage) -> (width: Int, height: Int, alpha: [UInt8])? {
    let width = image.width
    let height = image.height
    guard width > 0, height > 0,
          let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let ok: Bool = bytes.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(
            data: buffer.baseAddress, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    guard ok else { return nil }
    // premultipliedLast：每 4 个字节的最后一个是 alpha。
    return (width, height, stride(from: 3, to: bytes.count, by: 4).map { bytes[$0] })
}

/// 在渲染图里找「3×3 邻域全是字」和「3×3 邻域全是空」的点，换算成画布坐标。
///
/// 要求邻域同质，是因为成品是 4:2:0 + 有损编码：孤立的一个像素会被邻居糊掉，
/// 拿它当探针等于在测编码器的心情。
func probePoints(
    _ rendered: RenderedText, canvas: CGSize, wanted: Int
) -> (ink: [(Int, Int)], empty: [(Int, Int)]) {
    guard let mask = alphaMask(rendered.image), mask.width > 2, mask.height > 2 else { return ([], []) }
    var ink: [(Int, Int)] = []
    var empty: [(Int, Int)] = []

    func solid(_ x: Int, _ y: Int, _ test: (UInt8) -> Bool) -> Bool {
        for dy in -1...1 {
            for dx in -1...1 where !test(mask.alpha[(y + dy) * mask.width + (x + dx)]) {
                return false
            }
        }
        return true
    }

    // `CGContext.draw` 把 CGImage 的第 0 行画在**顶部**，所以这里的 y 和画布的
    // 左上原点同向，直接加 origin 就是画布坐标。
    for y in 1..<(mask.height - 1) {
        for x in 1..<(mask.width - 1) {
            let cx = Int(rendered.origin.x) + x
            let cy = Int(rendered.origin.y) + y
            guard cx > 0, cy > 0, cx < Int(canvas.width) - 1, cy < Int(canvas.height) - 1 else { continue }
            if ink.count < wanted, solid(x, y, { $0 > 250 }) {
                ink.append((cx, cy))
            } else if empty.count < wanted, solid(x, y, { $0 == 0 }) {
                empty.append((cx, cy))
            }
            if ink.count >= wanted, empty.count >= wanted { return (ink, empty) }
        }
    }
    return (ink, empty)
}

/// 位图最外圈那一圈像素全是透明吗。
///
/// 包络留小了的判据就是它：内容被位图边缘切掉时，边上一定有不透明的像素。
/// 只看尺寸是不是恒定抓不到这个 —— 包络算小了的话尺寸照样恒定，只是内容被裁。
func borderIsClear(_ image: CGImage) -> Bool {
    guard let mask = alphaMask(image), mask.width > 2, mask.height > 2 else { return false }
    for x in 0..<mask.width {
        if mask.alpha[x] != 0 { return false }
        if mask.alpha[(mask.height - 1) * mask.width + x] != 0 { return false }
    }
    for y in 0..<mask.height {
        if mask.alpha[y * mask.width] != 0 { return false }
        if mask.alpha[y * mask.width + mask.width - 1] != 0 { return false }
    }
    return true
}
