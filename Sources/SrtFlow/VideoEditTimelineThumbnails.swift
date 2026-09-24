import AVFoundation
import ImageIO
import SwiftUI

// MARK: - 缩略图条
//
// 从 `VideoEditTimelineView.swift` 拆出来（拆分前 2101 行，远超仓库约 800 行的
// 警戒线）。纯装饰，整条 `allowsHitTesting(false)`：`.clipped()` 只裁绘制不裁命中区
// （docs/bugfixes/2026-08-16-clipped-thumbnail-hit-area-covers-ruler.md）。
// 接线守卫 `checks/timeline-drag-wiring.sh` 按文件扫描，挪动这里的东西要同步改它。
//
// 2026-09-23 深度缩放起改成**按可见范围铺小格**（docs/architecture/audio-waveform.md）：
// 以前是整段均分成至多 24 张图，放大 40 倍之后一张图要被拉到一万多点宽、只剩中间
// 一条横缝。现在每格的宽度按行高和画面比例定，只取、只画看得见的那几格；每格取哪一帧
// 按「帧 / 2 的整数次幂秒」的网格对齐，缩放时大多数格子还是同一张图（缓存命中），
// 新图没回来之前先拿缓存里时间最近的那张顶着。

/// 视频块里的缩略图条。
struct ThumbnailStripView: View {
    let clip: EditClip
    let height: Double
    let pps: Double

    /// 缓存里新到了图就 +1，让 Canvas 重画（图本身在 `ThumbnailTileCache` 里，同步取）。
    @State private var revision = 0
    /// 图片素材：原图的小缩略图，所有格子都用它。
    @State private var still: CGImage?

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        Canvas { [revision, still] context, size in
            PerfCounters.canvas(Self.self)
            _ = revision
            ThumbnailPainter(clip: clip, pps: pps, still: still).draw(in: &context, size: size)
        }
        .frame(height: height)
        .task(id: clip.stillImageURL) {
            // 图片素材直接读原图（比开 AVAsset 快得多，静帧还在转的时候也能显示）。
            guard let url = clip.stillImageURL else { still = nil; return }
            still = await ClipThumbnailCache.shared.stillThumbnail(url: url)
        }
        .onReceive(NotificationCenter.default.publisher(for: ThumbnailTileCache.didLoad)) { note in
            guard (note.object as? URL) == clip.sourceURL.standardizedFileURL else { return }
            revision &+= 1
        }
        // 纯装饰，整条不吃事件。画在 Canvas 里本来就不会溢出命中区，但守卫与
        // 2026-08-16 那条教训一起钉着：块的点选/拖动/悬停全挂在 ClipBlockView 那一层。
        .allowsHitTesting(false)
    }
}

/// 一次绘制：算出看得见的格子，取图（没有就登记请求并拿最近的一张顶着），画。
struct ThumbnailPainter {
    let clip: EditClip
    let pps: Double
    let still: CGImage?

    /// 一格多宽：按画面比例铺满行高，太窄太宽都夹住。
    func tileWidth(height: Double) -> Double {
        let size = clip.info?.displaySize ?? CGSize(width: 16, height: 9)
        let aspect = size.height > 0 ? min(2.5, max(0.5, size.width / size.height)) : 16.0 / 9.0
        return max(24, height * aspect)
    }

    func draw(in context: inout GraphicsContext, size: CGSize) {
        guard size.width > 0, size.height > 0, pps > 0 else { return }
        let tile = tileWidth(height: size.height)
        let visible = context.clipBoundingRect
        let first = max(0, Int((visible.minX / tile).rounded(.down)))
        let last = Int((min(Double(size.width), visible.maxX) / tile).rounded(.up))
        guard last >= first else { return }

        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.25)))
        let cache = ThumbnailTileCache.shared
        // 一格在源素材里跨多少秒，按帧 / 2 的整数次幂取网格（见文件头）。
        let secondsPerTile = tile / pps * max(0.05, clip.speed)
        // 素材帧率探测不到（图片、音频、坏文件）时按 30 取网格 —— 只影响缩略图取哪一帧。
        let sourceFPS = clip.info.map(\.frameRate).flatMap { $0 > 0 ? $0 : nil } ?? 30
        let step = ThumbnailGrid.step(forSecondsPerTile: secondsPerTile, frameRate: sourceFPS)
        var wanted: [Double] = []
        for index in first...last {
            let rect = CGRect(x: Double(index) * tile, y: 0, width: tile, height: Double(size.height))
            let image: CGImage?
            if let still {
                image = still
            } else {
                let centre = clip.timelineStart + min(rect.midX, Double(size.width) - 0.5) / pps
                let source = min(max(clip.sourceTime(atTimeline: centre), clip.sourceStart),
                                 clip.sourceStart + max(0, clip.sourceDuration - 0.001))
                let time = ThumbnailGrid.snap(source, step: step)
                if let exact = cache.image(url: clip.sourceURL, time: time) {
                    image = exact
                } else {
                    wanted.append(time)
                    image = cache.nearest(url: clip.sourceURL, to: time)
                }
            }
            guard let image else { continue }
            drawFilling(image, in: rect, context: &context)
        }
        if !wanted.isEmpty {
            cache.request(url: clip.sourceURL, times: wanted, tolerance: step / 2)
        }
    }

    /// 等比铺满一格、裁掉多出来的部分（scaledToFill 的样子）。
    private func drawFilling(_ image: CGImage, in rect: CGRect, context: inout GraphicsContext) {
        let imageAspect = Double(image.width) / Double(max(1, image.height))
        let rectAspect = rect.width / max(1, rect.height)
        var target = rect
        if imageAspect > rectAspect {
            target.size.width = rect.height * imageAspect
            target.origin.x = rect.midX - target.width / 2
        } else {
            target.size.height = rect.width / imageAspect
            target.origin.y = rect.midY - target.height / 2
        }
        context.drawLayer { layer in
            layer.clip(to: Path(rect))
            layer.draw(Image(decorative: image, scale: 1), in: target)
        }
    }
}

// MARK: - 缓存

/// 时间线缩略图的格子缓存。**同步可读**（Canvas 的绘制闭包里要用），缺的图登记请求、
/// 后台去取，取到一批在主线程发 `didLoad`。
final class ThumbnailTileCache: @unchecked Sendable {
    static let shared = ThumbnailTileCache()
    static let didLoad = Notification.Name("ThumbnailTileCache.didLoad")

    private struct Key: Hashable {
        let url: URL
        let millis: Int
    }

    private let lock = NSLock()
    private var images: [Key: CGImage] = [:]
    /// 每个素材已有哪些时刻（毫秒，升序）—— 取「最近的一张」用。
    private var times: [URL: [Int]] = [:]
    private var recency: [Key] = []
    private var queue: [(key: Key, tolerance: Double)] = []
    private var queued: Set<Key> = []
    private var draining = false
    private var generators: [URL: AVAssetImageGenerator] = [:]
    /// 最多留几张（160×90 的小图，几十 MB 以内）。
    private let limit = 600
    /// 排队的上限：滚得快的时候，老的请求早就滚出视野了，扔掉比排着强。
    private let queueLimit = 96

    private static func millis(_ time: Double) -> Int { Int((time * 1000).rounded()) }

    func image(url: URL, time: Double) -> CGImage? {
        let key = Key(url: url.standardizedFileURL, millis: Self.millis(time))
        lock.lock(); defer { lock.unlock() }
        return images[key]
    }

    /// 同一个素材里时间最近的一张（新图回来之前先顶着，别让格子闪成黑的）。
    func nearest(url: URL, to time: Double) -> CGImage? {
        let base = url.standardizedFileURL
        let target = Self.millis(time)
        lock.lock(); defer { lock.unlock() }
        guard let list = times[base], !list.isEmpty else { return nil }
        var low = 0
        var high = list.count - 1
        while low < high {
            let mid = (low + high) / 2
            if list[mid] < target { low = mid + 1 } else { high = mid }
        }
        var best = list[low]
        if low > 0, abs(list[low - 1] - target) < abs(best - target) { best = list[low - 1] }
        return images[Key(url: base, millis: best)]
    }

    /// 登记要取的图。**后到的先取**（最新的请求就是此刻看得见的那几格）。
    func request(url: URL, times wanted: [Double], tolerance: Double) {
        let base = url.standardizedFileURL
        lock.lock()
        for time in wanted {
            let key = Key(url: base, millis: Self.millis(time))
            guard images[key] == nil, !queued.contains(key) else { continue }
            queued.insert(key)
            queue.append((key, tolerance))
        }
        while queue.count > queueLimit {
            queued.remove(queue.removeFirst().key)
        }
        let shouldStart = !draining && !queue.isEmpty
        if shouldStart { draining = true }
        lock.unlock()
        if shouldStart {
            // 性能测试等后台读完再量（PerfCounters.backgroundReadBegan）；结束记在 drain 最后。
            PerfCounters.backgroundReadBegan()
            Task.detached(priority: .utility) { [self] in await drain() }
        }
    }

    private func next() -> (key: Key, tolerance: Double, generator: AVAssetImageGenerator)? {
        lock.lock(); defer { lock.unlock() }
        guard let job = queue.popLast() else {
            draining = false
            return nil
        }
        queued.remove(job.key)
        let generator: AVAssetImageGenerator
        if let existing = generators[job.key.url] {
            generator = existing
        } else {
            let made = AVAssetImageGenerator(asset: AVURLAsset(url: job.key.url))
            made.appliesPreferredTrackTransform = true
            made.maximumSize = CGSize(width: 320, height: 180)
            generators[job.key.url] = made
            generator = made
        }
        return (job.key, job.tolerance, generator)
    }

    private func drain() async {
        var delivered = Set<URL>()
        var sinceNotice = 0
        while let job = next() {
            let tolerance = CMTime(seconds: max(0.001, job.tolerance), preferredTimescale: 600)
            job.generator.requestedTimeToleranceBefore = tolerance
            job.generator.requestedTimeToleranceAfter = tolerance
            let time = CMTime(seconds: Double(job.key.millis) / 1000, preferredTimescale: 600)
            if let image = try? await job.generator.image(at: time).image {
                store(image, for: job.key)
                delivered.insert(job.key.url)
                sinceNotice += 1
            }
            // 攒几张发一次通知：一格一重画太碎，全攒完再画又太慢。
            if sinceNotice >= 4 {
                await announce(delivered)
                delivered.removeAll()
                sinceNotice = 0
            }
        }
        await announce(delivered)
        PerfCounters.backgroundReadEnded()
    }

    private func store(_ image: CGImage, for key: Key) {
        lock.lock(); defer { lock.unlock() }
        if images[key] == nil {
            var list = times[key.url] ?? []
            let position = list.firstIndex { $0 > key.millis } ?? list.count
            list.insert(key.millis, at: position)
            times[key.url] = list
        }
        images[key] = image
        recency.removeAll { $0 == key }
        recency.append(key)
        while recency.count > limit {
            let evicted = recency.removeFirst()
            images[evicted] = nil
            times[evicted.url]?.removeAll { $0 == evicted.millis }
        }
    }

    @MainActor
    private func announce(_ urls: Set<URL>) {
        for url in urls {
            NotificationCenter.default.post(name: Self.didLoad, object: url)
        }
    }
}

/// 缩略图的全局缓存（非时间线的地方用：滤镜库、转场选择器的预览图）。
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
