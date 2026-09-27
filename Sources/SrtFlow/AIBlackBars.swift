import CoreGraphics
import Foundation

// MARK: - 找黑边（纯值）
//
// 管什么：一帧画面四边的黑边有多宽（上下的遮幅、左右的柱边），几帧合起来算一份，给 edit_clip 的
// `remove_black_bars` 裁掉、给「看」写进描述。只看像素，纯值，自检够得着（scripts/check-mcp.sh）。
// 不管什么：帧从哪来（AIFrameSampler）、裁切怎么算（AIFrameFit）。
//
// 口径（宁可少裁，别把画面裁掉）：
// - 一行（一列）算黑：最亮的点不超过 `blackMax`、平均不超过 `blackMean`（压缩噪点会让纯黑边有几个
//   二三十的像素，暗场的天空一般过不了「最亮的点」这一条）。从边上往里数连续的黑行。
// - 整帧都黑（淡入淡出、黑场）的帧不算数。
// - 几帧合起来**每边取最小的**：只要有一帧那儿不黑，那儿就不是黑边（夜景里的一片暗天不会被当成遮幅）。
// - 黑边里压着字（字幕烧在遮幅里）的话，扫到字就停：字那几行留着。

enum AIBlackBars {
    /// 一帧的亮度（0…255），行优先、第一行是画面最上面一行。
    struct Luma: Equatable {
        let width: Int
        let height: Int
        let pixels: [UInt8]
    }

    /// 四边各有多宽的黑边（占整幅的比例）。
    struct Insets: Equatable {
        var top: Double
        var bottom: Double
        var left: Double
        var right: Double

        static let none = Insets(top: 0, bottom: 0, left: 0, right: 0)

        /// 太窄的（不到半个百分点：编码器在边上留的一两个像素）不算。
        var isEmpty: Bool { max(top, bottom, left, right) < minimumBar }

        /// 去掉黑边剩下的那块（归一化，左上原点）。
        var active: CGRect {
            CGRect(x: left, y: top, width: max(0.01, 1 - left - right), height: max(0.01, 1 - top - bottom))
        }
    }

    static let blackMax: UInt8 = 40
    static let blackMean = 20.0
    static let minimumBar = 0.005

    /// 画成灰度（长边 `maxSide`）。
    static func luma(of image: CGImage, maxSide: Int = 256) -> Luma? {
        let scale = min(1, Double(maxSide) / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn: Bool = pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? Luma(width: width, height: height, pixels: pixels) : nil
    }

    /// 一帧的黑边。整帧（几乎）都黑时返回 nil：这一帧不算数。
    static func bars(in luma: Luma) -> Insets? {
        let rows = (0..<luma.height).map { isBlack(row: $0, luma) }
        let columns = (0..<luma.width).map { isBlack(column: $0, luma) }
        let top = rows.prefix { $0 }.count
        let bottom = rows.reversed().prefix { $0 }.count
        let left = columns.prefix { $0 }.count
        let right = columns.reversed().prefix { $0 }.count
        guard top + bottom < luma.height * 9 / 10, left + right < luma.width * 9 / 10 else { return nil }
        func share(_ count: Int, of total: Int) -> Double {
            let value = Double(count) / Double(total)
            return value < minimumBar ? 0 : value
        }
        return Insets(
            top: share(top, of: luma.height), bottom: share(bottom, of: luma.height),
            left: share(left, of: luma.width), right: share(right, of: luma.width)
        )
    }

    /// 几帧合起来：每边取所有算数的帧里最小的。一帧都不算数 → nil。
    static func combine(_ frames: [Insets?]) -> Insets? {
        let valid = frames.compactMap { $0 }
        guard let first = valid.first else { return nil }
        return valid.dropFirst().reduce(first) { result, next in
            Insets(
                top: min(result.top, next.top), bottom: min(result.bottom, next.bottom),
                left: min(result.left, next.left), right: min(result.right, next.right)
            )
        }
    }

    private static func isBlack(row: Int, _ luma: Luma) -> Bool {
        var peak: UInt8 = 0
        var sum = 0
        let start = row * luma.width
        for index in start..<(start + luma.width) {
            let value = luma.pixels[index]
            peak = max(peak, value)
            sum += Int(value)
        }
        return peak <= blackMax && Double(sum) / Double(luma.width) <= blackMean
    }

    private static func isBlack(column: Int, _ luma: Luma) -> Bool {
        var peak: UInt8 = 0
        var sum = 0
        for row in 0..<luma.height {
            let value = luma.pixels[row * luma.width + column]
            peak = max(peak, value)
            sum += Int(value)
        }
        return peak <= blackMax && Double(sum) / Double(luma.height) <= blackMean
    }
}
