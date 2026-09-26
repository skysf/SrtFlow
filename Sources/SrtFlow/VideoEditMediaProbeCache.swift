import AVFoundation
import Foundation

// MARK: - 素材探测（带缓存）
//
// 管什么：视频素材的探测结果（`MediaInfo`）和音频时长，按路径缓存 —— 同一个文件第二次导入、定格生成的
// 静帧视频、修图片占位块时都不再重新探。
// 不管什么：探测本身（视频走 `MediaProbe` 调 ffmpeg，音频时长直接读 `AVURLAsset`）、探到之后怎么进时间线。
// 从 VideoEditProject.swift 拆出来（那个文件在行数基线里只许降，见 docs/architecture/coding-standards.md）。

@MainActor
final class MediaProbeCache {
    private var infos: [URL: MediaInfo] = [:]
    private var audioDurations: [URL: Double] = [:]

    /// 已经探过的结果，不去探。修图片占位块时用：那时只认缓存里有的。
    func cachedInfo(for url: URL) -> MediaInfo? { infos[url] }

    func probeVideo(_ url: URL) async -> MediaInfo? {
        if let cached = infos[url] { return cached }
        let result = await MediaProbe.probe(url: url, ffmpeg: MediaToolchain.shared.runtime?.url)
        if case .success(let info) = result {
            infos[url] = info
            return info
        }
        return nil
    }

    func audioDuration(_ url: URL) async -> Double? {
        if let cached = audioDurations[url] { return cached }
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration).seconds, duration.isFinite else { return nil }
        audioDurations[url] = duration
        return duration
    }
}
