import AVFoundation
import ImageIO
import SwiftUI

// MARK: - 缩略图条
//
// 从 `VideoEditTimelineView.swift` 拆出来（拆分前 2101 行，远超仓库约 800 行的
// 警戒线）。纯装饰，整条 `allowsHitTesting(false)`：`.clipped()` 只裁绘制不裁命中区
// （docs/bugfixes/2026-08-16-clipped-thumbnail-hit-area-covers-ruler.md）。
// 接线守卫 `checks/timeline-drag-wiring.sh` 按文件扫描，挪动这里的东西要同步改它。

// MARK: - 缩略图条

/// 视频块里的缩略图条：按可见宽度取若干帧铺满。取帧是异步的，先给底色。
struct ThumbnailStripView: View {
    let clip: EditClip
    let height: Double

    @State private var images: [CGImage] = []

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                if images.isEmpty {
                    Color.black.opacity(0.25)
                } else {
                    ForEach(Array(images.enumerated()), id: \.offset) { _, image in
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .scaledToFill()
                            .frame(
                                width: proxy.size.width / Double(images.count),
                                height: height
                            )
                            .clipped()
                    }
                }
            }
            .task(id: taskKey(width: proxy.size.width)) {
                await loadThumbnails(width: proxy.size.width)
            }
        }
        .frame(height: height)
        // 纯装饰，整条不吃事件。缩略图 `.scaledToFill().clipped()` 只裁**画面**
        // 不裁**命中区**：竖版图按 tile 宽 fill 后纵向溢出 (tile宽×高宽比−条高)/2，
        // tile 宽又随缩放涨（块宽/24）——放大后这片隐形命中区能高出块几百 pt，
        // 把上面的标尺整段盖死（点标尺 = 选中图片，就是 2026-08-16 那个 bug）。
        // 块的点选/拖动/悬停全挂在 ClipBlockView 那一层，底色矩形提供命中面，
        // 这里让路零损失。案例见
        // docs/bugfixes/2026-08-16-clipped-thumbnail-hit-area-covers-ruler.md。
        .allowsHitTesting(false)
    }

    private func taskKey(width: Double) -> String {
        "\(clip.sourceURL.path)|\(Int(clip.sourceStart * 10))|\(Int(clip.sourceDuration * 10))|\(Int(width / 56))"
    }

    private func loadThumbnails(width: Double) async {
        guard width > 4 else { return }
        // 裁切/缩放拖动中 key 每个 tick 都在变：已有图先撑着，等手停稳 200ms 再取，
        // 否则每一拍都解码一串帧、旧任务的结果还会乱序落地把新图盖掉——就是闪烁。
        // 首次加载（还没图）不等，尽快替掉底色。
        if !images.isEmpty {
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
        }
        let count = max(1, min(24, Int(width / 56)))
        // 图片素材：直接读原图铺满（比开 AVAsset 快得多，占位期也能显示）。
        if let stillURL = clip.stillImageURL {
            if let image = await ClipThumbnailCache.shared.stillThumbnail(url: stillURL) {
                images = Array(repeating: image, count: count)
            }
            return
        }
        let loaded = await ClipThumbnailCache.shared.thumbnails(
            url: clip.sourceURL,
            start: clip.sourceStart,
            duration: clip.sourceDuration,
            count: count
        )
        guard !Task.isCancelled, !loaded.isEmpty else { return }
        images = loaded
    }
}

/// 取帧走全局缓存：同一段素材反复布局时别重复解码。
actor ClipThumbnailCache {
    static let shared = ClipThumbnailCache()

    private var cache: [String: [CGImage]] = [:]
    private var generators: [URL: AVAssetImageGenerator] = [:]
    private var stills: [URL: CGImage] = [:]

    /// 静态图片的小缩略图（CGImageSource 直读，快）。
    func stillThumbnail(url: URL) -> CGImage? {
        if let cached = stills[url] { return cached }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 160,
            kCGImageSourceCreateThumbnailWithTransform: true
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        stills[url] = image
        return image
    }

    func thumbnails(url: URL, start: Double, duration: Double, count: Int) async -> [CGImage] {
        let key = "\(url.path)|\(Int(start * 10))|\(Int(duration * 10))|\(count)"
        if let cached = cache[key] { return cached }

        let generator: AVAssetImageGenerator
        if let existing = generators[url] {
            generator = existing
        } else {
            let asset = AVURLAsset(url: url)
            generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 160, height: 90)
            // 缩略图不用帧准，给宽容差能快一个数量级。
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
            generators[url] = generator
        }

        var result: [CGImage] = []
        for index in 0..<count {
            // 调用方（.task）已经换 key 取消了就别接着磨：actor 是串行的，
            // 磨完一整串废帧会把新请求堵在门外。
            if Task.isCancelled { return [] }
            let fraction = (Double(index) + 0.5) / Double(count)
            let seconds = start + duration * fraction
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            if let image = try? await generator.image(at: time).image {
                result.append(image)
            }
        }
        if !result.isEmpty { cache[key] = result }
        return result
    }
}
