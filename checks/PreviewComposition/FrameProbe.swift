import AVFoundation
import CoreGraphics
import Foundation
import SrtFlowCore

// 取帧量亮度：从合成 / 文件里抽一帧，量整幅或某个区域的平均亮度 / RGBA。
// 从 main.swift 拆出来（那个文件超过 600 行、只许降）；用例在 main.swift 里。

// MARK: - 取帧量亮度

/// 整幅平均亮度（0…1）。测试画面都是均匀纯色，平均就够了。
func averageBrightness(_ built: VideoEditCompositionBuilder.Built, at seconds: Double) async -> Double {
    let generator = AVAssetImageGenerator(asset: built.composition)
    generator.videoComposition = built.videoComposition
    generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 15)
    generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 15)
    guard let image = try? await generator.image(
        at: CMTime(seconds: seconds, preferredTimescale: 600)
    ).image else { return -1 }

    var pixel = [UInt8](repeating: 0, count: 4)
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
              data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          ) else { return -1 }
    context.interpolationQuality = .medium
    context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    return (Double(pixel[0]) + Double(pixel[1]) + Double(pixel[2])) / 3 / 255
}

/// 归一化区域（左上原点，0…1）的平均亮度。推移/擦除的方向要分区量。
func regionBrightness(
    _ built: VideoEditCompositionBuilder.Built, at seconds: Double, region: CGRect
) async -> Double {
    let generator = AVAssetImageGenerator(asset: built.composition)
    generator.videoComposition = built.videoComposition
    generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 15)
    generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 15)
    guard let image = try? await generator.image(
        at: CMTime(seconds: seconds, preferredTimescale: 600)
    ).image else { return -1 }
    let pixelRegion = CGRect(
        x: region.minX * Double(image.width),
        y: region.minY * Double(image.height),
        width: region.width * Double(image.width),
        height: region.height * Double(image.height)
    )
    return averageRGBA(image, region: pixelRegion).red
}

/// 从文件抽帧（预渲染中间片的验收用）。
func frameImage(fromFile url: URL, at seconds: Double) async -> CGImage? {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 15)
    generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 15)
    return try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
}

/// 区域平均 RGBA（0…1，premultiplied）。画中画中间片要验 alpha 通道。
func averageRGBA(_ image: CGImage, region: CGRect) -> (red: Double, alpha: Double) {
    guard let cropped = image.cropping(to: region) else { return (-1, -1) }
    var pixel = [UInt8](repeating: 0, count: 4)
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
              data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          ) else { return (-1, -1) }
    context.interpolationQuality = .medium
    context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    return (Double(pixel[0]) / 255, Double(pixel[3]) / 255)
}

