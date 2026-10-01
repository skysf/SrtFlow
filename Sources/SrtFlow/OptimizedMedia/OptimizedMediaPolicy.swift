import CoreGraphics
import CoreMedia
import Foundation

// MARK: - 优化媒体的判据和参数：纯值
//
// 管什么：哪些源要转（长 GOP 的、解一个 GOP 超过两帧时间的）、转成多大（原分辨率，长边超过 4K 的一半）、码率、
// 关键帧间隔、按源时间分块、一段用到哪几块。全是纯函数，自检直接算。
// 不管什么：探（MediaKeyframeProbe / DecodeSpeedProbe）、转（OptimizedMediaTranscoder）、存（OptimizedMediaStore）。
// 方案：docs/plans/2026-10-01-video-optimized-media.md；长期约束：docs/architecture/optimized-media.md。

enum OptimizedMediaPolicy {
    /// 代理的关键帧间隔（秒）：探针实测 0.5 秒一个关键帧的 H.264 seek 27–36 ms，全帧内只再快十几毫秒、体积翻倍。
    static let keyframeInterval = 0.5
    /// 按源时间分块，一块多长（秒）。
    static let chunkSeconds = 10.0
    /// 一段用到的块两边各多留几块：裁切把手拖一拖不用马上转新块。
    static let chunkMargin = 1
    /// 长边超过这么多像素（4K）就减半。
    static let maxLongEdge = 2560
    /// 「一个 GOP 要解超过这么多帧的时间」才值得转（验收是点一下到画面 ≤ 2 帧）。
    static let worthwhileFrames = 2.0
    /// 全帧内 / 图片序列类编码：本来就没有 GOP，不转。
    static let intraCodecs: Set<String> = ["prores", "apch", "apcn", "apcs", "apco", "ap4h", "ap4x", "mjpeg", "mjpg", "jpeg", "png", "dnxhd", "dnxhr", "avdn"]

    /// 要不要给这个源转代理。`keyframeInterval` 不知道（老工程没探过）→ 不转；静帧、全帧内 → 不转；
    /// 一个 GOP 按这台机器的解码速度要解超过两帧的时间才转。
    static func needsProxy(info: MediaInfo, isStillImage: Bool, decodeFPS: Double) -> Bool {
        guard !isStillImage, decodeFPS > 0, info.frameRate > 0 else { return false }
        guard let interval = info.keyframeInterval, interval > 0 else { return false }
        if intraCodecs.contains(info.videoCodec.lowercased()) { return false }
        let gopFrames = interval * info.frameRate
        let decodeSeconds = gopFrames / decodeFPS
        return decodeSeconds > worthwhileFrames / info.frameRate
    }

    /// 代理的像素尺寸：原分辨率；长边超过 `maxLongEdge` 减半；宽高都取偶数（yuv420 的世界）。
    static func targetSize(forNatural natural: CGSize) -> CGSize {
        var width = natural.width, height = natural.height
        if max(width, height) > CGFloat(maxLongEdge) {
            width /= 2
            height /= 2
        }
        return CGSize(width: max(2, (width / 2).rounded() * 2), height: max(2, (height / 2).rounded() * 2))
    }

    /// 码率（bit/s）：1080p 给 12 Mbps，按像素数等比，封在 2–40 Mbps。
    static func bitRate(for size: CGSize) -> Int {
        let pixels = Double(size.width * size.height)
        let scaled = 12_000_000 * pixels / (1920 * 1080)
        return Int(min(40_000_000, max(2_000_000, scaled)))
    }

    /// 源时间 `seconds` 落在第几块。
    static func chunkIndex(forSourceSeconds seconds: Double) -> Int {
        max(0, Int((seconds / chunkSeconds).rounded(.down)))
    }

    /// 第 `index` 块覆盖的源时间。
    static func chunkRange(_ index: Int) -> ClosedRange<Double> {
        let start = Double(index) * chunkSeconds
        return start...(start + chunkSeconds)
    }

    /// 一段（源时间 `sourceStart` 起、`sourceDuration` 长）要用到的块，两边各留 `chunkMargin` 块，不超过源的总长。
    static func chunks(sourceStart: Double, sourceDuration: Double, sourceLength: Double) -> ClosedRange<Int> {
        let covering = coveringChunks(sourceStart: sourceStart, sourceDuration: sourceDuration, sourceLength: sourceLength)
        let last = max(0, chunkIndex(forSourceSeconds: max(0, sourceLength - 0.001)))
        return max(0, covering.lowerBound - chunkMargin)...min(last, covering.upperBound + chunkMargin)
    }

    /// 正好盖住这一截的块（不留余量）：builder 插画面时要的就是这几块，不超过源的最后一块。
    static func coveringChunks(sourceStart: Double, sourceDuration: Double, sourceLength: Double) -> ClosedRange<Int> {
        let first = chunkIndex(forSourceSeconds: max(0, sourceStart))
        let end = max(first, chunkIndex(forSourceSeconds: max(0, sourceStart + sourceDuration - 0.001)))
        guard sourceLength.isFinite else { return first...end }
        let last = max(0, chunkIndex(forSourceSeconds: max(0, sourceLength - 0.001)))
        return min(first, last)...min(end, last)
    }

    /// 代理按恒定帧率写（源是变帧率的录屏时静止期没有帧，块头块尾都要有画面才插得进合成）：帧率照源的标称值，
    /// 常见的几档按精确的分数（29.97 = 30000/1001）；对不上任何一档（变帧率的录屏报的是平均值）按 30。
    static func proxyFrameDuration(sourceFPS fps: Double) -> CMTime {
        let standard: [(rate: Double, duration: CMTime)] = [
            (23.976, CMTime(value: 1001, timescale: 24000)), (24, CMTime(value: 1, timescale: 24)),
            (25, CMTime(value: 1, timescale: 25)), (29.97, CMTime(value: 1001, timescale: 30000)),
            (30, CMTime(value: 1, timescale: 30)), (48, CMTime(value: 1, timescale: 48)),
            (50, CMTime(value: 1, timescale: 50)), (59.94, CMTime(value: 1001, timescale: 60000)),
            (60, CMTime(value: 1, timescale: 60)),
        ]
        guard fps.isFinite, fps > 0 else { return CMTime(value: 1, timescale: 30) }
        // 容差 0.05%：29.97 和 30 只差 0.1%，松一点就混在一起（第一版 0.4% 把 30 认成了 29.97）。
        for entry in standard where abs(fps - entry.rate) < entry.rate * 0.0005 { return entry.duration }
        return CMTime(value: 1, timescale: 30)
    }
}
