import AVFoundation
import CoreGraphics
import Foundation
import ImageIO

// MARK: - 从素材里抽帧，给 AI 的「眼睛」用
//
// 管什么：按源时间抽几帧（按显示方向摆正、按 `maxSide` 限大小），图片素材直接读原图。去黑边、找主体、
// 「看」一个文件都从这里拿帧。
// 不管什么：帧怎么分析（AIBlackBars / AISubjectFocus / AIFrameDescription）、时间线上合成好的画面
// （AIFrameComposer）。
//
// 用 `AVAssetImageGenerator` 的 async 接口：它不卡线程，可以在 async 函数里 await（会卡线程的读取另有
// 规矩，见 docs/architecture/blocking-media-reads.md）。素材从 `MediaAssetCache` 拿，和预览同一份、不另开。

enum AIFrameSampler {
    struct Frame: Sendable {
        /// 源时间（秒）；图片是 0。
        var time: Double
        var image: CGImage
    }

    /// 在源时间 [from, to] 里均匀取 `count` 个时刻：每一格的中点（避开首尾的黑场、淡入淡出）。
    static func times(from: Double, to: Double, count: Int) -> [Double] {
        let span = max(0, to - from)
        let n = max(1, count)
        return (0..<n).map { from + span * (Double($0) + 0.5) / Double(n) }
    }

    /// 一段素材用到的那一截里均匀取 `count` 帧（图片素材就是原图那一张）。
    static func frames(of clip: EditClip, count: Int, maxSide: Int) async -> [Frame] {
        if let still = clip.stillImageURL {
            return image(at: still, maxSide: maxSide).map { [Frame(time: 0, image: $0)] } ?? []
        }
        let at = times(from: clip.sourceStart, to: clip.sourceStart + clip.sourceDuration, count: count)
        return await frames(ofVideo: clip.sourceURL, at: at, maxSide: maxSide, tolerance: 0.25)
    }

    /// 视频在这几个源时刻的画面；取不到的跳过。`tolerance`（秒）越宽越快（可以就近取关键帧）。
    static func frames(ofVideo url: URL, at times: [Double], maxSide: Int, tolerance: Double) async -> [Frame] {
        let generator = AVAssetImageGenerator(asset: MediaAssetCache.asset(for: url).asset)
        generator.appliesPreferredTrackTransform = true
        generator.dynamicRangePolicy = .forceSDR
        generator.maximumSize = CGSize(width: maxSide, height: maxSide)
        let window = CMTime(seconds: max(0.001, tolerance), preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = window
        generator.requestedTimeToleranceAfter = window
        var frames: [Frame] = []
        for time in times {
            let requested = CMTime(seconds: max(0, time), preferredTimescale: 600)
            if let image = try? await generator.image(at: requested).image {
                frames.append(Frame(time: time, image: image))
            }
        }
        return frames
    }

    /// 读一张图片（按 EXIF 方向摆正），长边不超过 `maxSide`。
    static func image(at url: URL, maxSide: Int) -> CGImage? {
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
            kCGImageSourceCreateThumbnailWithTransform: true
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }
}
