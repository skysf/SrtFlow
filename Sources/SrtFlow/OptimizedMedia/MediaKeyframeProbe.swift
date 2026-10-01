import AVFoundation
import Foundation

// MARK: - 一个视频源的关键帧间隔：扫采样表，不解码
//
// 管什么：一个文件的画面轨里关键帧隔多远（秒，取窗口里相邻两个关键帧的最大距离；全帧内 = 0）。
// 不管什么：要不要给它转优化媒体（OptimizedMediaPolicy）、转成什么（OptimizedMediaTranscoder）。
//
// 怎么量：`AVAssetReaderTrackOutput(outputSettings: nil)` 是直通，拿到的是压缩的采样、不解码；每个采样的附件里
// `kCMSampleAttachmentKey_NotSync` 说它不是关键帧（没有附件数组 = 关键帧，CoreMedia 的约定）。只扫前 `maxSeconds`
// 秒：长 GOP 的源几秒就看出来了，不用读整个文件。读采样是阻塞的，跑在 MediaReadQueue 上
//（docs/architecture/blocking-media-reads.md）。
//
// 窗口里只有一个关键帧（第一帧）时报窗口的长度：真实间隔只会更长，判「长 GOP」够用。

enum MediaKeyframeProbe {
    /// 关键帧间隔（秒）。读不出画面轨 / 一个采样都没有 → nil。
    static func interval(of url: URL, maxSeconds: Double = 60) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return nil }
        nonisolated(unsafe) let videoTrack = track
        nonisolated(unsafe) let readerAsset = asset
        return await MediaReadQueue.run(on: MediaReadQueue.detail) {
            scan(asset: readerAsset, track: videoTrack, maxSeconds: maxSeconds)
        }
    }

    /// 阻塞地扫一遍采样表。**只在 MediaReadQueue 上调。**
    static func scan(asset: AVAsset, track: AVAssetTrack, maxSeconds: Double) -> Double? {
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: maxSeconds, preferredTimescale: 600))
        guard reader.startReading() else { return nil }
        defer { reader.cancelReading() }

        var samples = 0
        var syncTimes: [Double] = []
        var lastTime = 0.0
        while let buffer = output.copyNextSampleBuffer() {
            // 直通读取会夹几个零采样的标记缓冲（文件头尾、编辑列表），不是帧。
            guard CMSampleBufferGetNumSamples(buffer) > 0 else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
            guard pts.isValid else { continue }
            samples += 1
            lastTime = max(lastTime, pts.seconds)
            if isSync(buffer) { syncTimes.append(pts.seconds) }
        }
        guard samples > 0 else { return nil }
        // 全帧内：每个采样都是关键帧。
        if syncTimes.count == samples { return 0 }
        let sorted = syncTimes.sorted()
        guard sorted.count >= 2 else { return max(lastTime - (sorted.first ?? 0), 0) }
        var longest = 0.0
        for index in 1..<sorted.count { longest = max(longest, sorted[index] - sorted[index - 1]) }
        return longest
    }

    /// 关键帧 = 不带「不是 sync」也不带「只是部分 sync」的采样。
    static func isSync(_ buffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else { return true }
        let notSync = (first[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false
        let partial = (first[kCMSampleAttachmentKey_PartialSync] as? Bool) ?? false
        return !notSync && !partial
    }
}
