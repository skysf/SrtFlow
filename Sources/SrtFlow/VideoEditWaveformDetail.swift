import AVFoundation
import Foundation

// MARK: - 深度放大时的原始采样（按需读、按块缓存）
//
// 多级峰值最细的一级是 64 个采样一个桶。放到一个像素还盖不满一个桶的时候
// （48kHz、Retina 下约 375pt/秒以上），再用桶画出来就是一段一段的锯齿 ——
// 2026-09-23 离屏渲染实测：4800pt/秒下 220Hz 的正弦画成了乱跳的折线。Logic 在
// 这个深度画的是真实的采样。
//
// 所以放到那么大时，**只把看得见的那一两秒**原样读出来（1 秒一块），每个像素取
// 真实采样的 min/max：正弦就是一条正弦。块没读到之前先拿 64 采样的桶顶着，读到了
// 发一条通知，波形视图重画一次。
//
// 合同见 docs/architecture/audio-waveform.md。

/// 一块原始采样（交错存放，声道数与多级峰值那份相同）。
struct WaveformDetailTile: Sendable {
    /// 这一块第一个采样是素材里的第几帧（按读出来的时间戳算，不是按请求算：
    /// 压缩音频的读取会从包边界起，可能比请求早一点）。
    let startFrame: Int
    let channels: Int
    let samples: [Float]

    var frameCount: Int { samples.count / max(1, channels) }

    /// `[from, to)` 里某个声道（nil = 全部声道）的最小 / 最大值；不在这块里返回 nil。
    func extremes(channel: Int?, from: Int, to: Int) -> (min: Float, max: Float)? {
        let low = max(from, startFrame) - startFrame
        let high = min(to, startFrame + frameCount) - startFrame
        guard high > low else { return nil }
        var lo = Float.greatestFiniteMagnitude
        var hi = -Float.greatestFiniteMagnitude
        samples.withUnsafeBufferPointer { buffer in
            for frame in low..<high {
                let base = frame * channels
                if let channel {
                    let value = buffer[base + min(channel, channels - 1)]
                    lo = min(lo, value); hi = max(hi, value)
                } else {
                    for ch in 0..<channels {
                        let value = buffer[base + ch]
                        lo = min(lo, value); hi = max(hi, value)
                    }
                }
            }
        }
        return (lo, hi)
    }
}

/// 原始采样块的缓存。**同步可读**（Canvas 的绘制闭包里要用），读不到就登记一个请求、
/// 后台去读，读完在主线程发 `didLoad`。
final class WaveformDetailCache: @unchecked Sendable {
    static let shared = WaveformDetailCache()
    /// 一块多长（秒）。最深的放大下一屏约 0.3 秒，刚放进细节区（约 375pt/秒）时
    /// 一屏约 3.5 秒 —— 1 秒一块，两头都只读几块。
    static let tileSeconds = 1.0
    /// 读完一块时发的通知，`object` 是素材的 URL（标准化过的）。
    static let didLoad = Notification.Name("WaveformDetailCache.didLoad")

    private struct Key: Hashable {
        let url: URL
        let index: Int
    }

    private let lock = NSLock()
    private var tiles: [Key: WaveformDetailTile] = [:]
    private var recency: [Key] = []
    private var pending: Set<Key> = []
    /// 最多留几块（立体声 48kHz 一块约 384KB）。
    private let limit = 48

    /// 第 `index` 块（没读到返回 nil）。
    func tile(url: URL, index: Int) -> WaveformDetailTile? {
        let key = Key(url: url.standardizedFileURL, index: index)
        lock.lock(); defer { lock.unlock() }
        guard let tile = tiles[key] else { return nil }
        if let position = recency.firstIndex(of: key) {
            recency.remove(at: position)
            recency.append(key)
        }
        return tile
    }

    /// 登记要读的块：已有的、正在读的都跳过，其余后台去读。
    func request(url: URL, indices: ClosedRange<Int>, sampleRate: Double, channels: Int) {
        let base = url.standardizedFileURL
        var toLoad: [Int] = []
        lock.lock()
        for index in indices where index >= 0 {
            let key = Key(url: base, index: index)
            if tiles[key] == nil, !pending.contains(key) {
                pending.insert(key)
                toLoad.append(index)
            }
        }
        lock.unlock()
        guard !toLoad.isEmpty else { return }
        Task.detached(priority: .userInitiated) { [self] in
            for index in toLoad {
                let tile = await Self.read(url: base, index: index, sampleRate: sampleRate, channels: channels)
                store(tile, for: Key(url: base, index: index))
            }
            await MainActor.run {
                NotificationCenter.default.post(name: Self.didLoad, object: base)
            }
        }
    }

    private func store(_ tile: WaveformDetailTile?, for key: Key) {
        lock.lock(); defer { lock.unlock() }
        pending.remove(key)
        // 读失败也要从 pending 里拿掉，不然这一块永远不会再试。
        guard let tile else { return }
        tiles[key] = tile
        recency.removeAll { $0 == key }
        recency.append(key)
        while recency.count > limit {
            tiles[recency.removeFirst()] = nil
        }
    }

    /// 读一块：AVAssetReader 只读这一秒（压缩音频会从包边界起，所以时间戳按读出来的算）。
    ///
    /// 找音轨是异步的，在这儿做；**读采样的循环是阻塞的，交给 `MediaReadQueue.detail`**。
    /// 放大时每个看得见的块都来要，十来个请求挤在协作线程池里，会把 userInitiated 这一整档
    /// 堵到死锁（与总览解码同一个事故，见 `MediaReadQueue`）。
    private static func read(url: URL, index: Int, sampleRate: Double, channels: Int) async -> WaveformDetailTile? {
        guard sampleRate > 0 else { return nil }
        let asset = AVURLAsset(url: url)
        guard let found = try? await asset.loadTracks(withMediaType: .audio).first else { return nil }
        // AVAssetTrack 没标 Sendable；它是只读的，交给读取线程之后这边不再碰。
        nonisolated(unsafe) let track = found
        return await MediaReadQueue.run(on: MediaReadQueue.detail) {
            readTile(asset: asset, track: track, index: index, sampleRate: sampleRate, channels: channels)
        }
    }

    /// 阻塞地读出第 `index` 块。**只在 `MediaReadQueue` 上调。**
    private static func readTile(
        asset: AVURLAsset,
        track: AVAssetTrack,
        index: Int,
        sampleRate: Double,
        channels: Int
    ) -> WaveformDetailTile? {
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
            AVNumberOfChannelsKey: channels,
            AVSampleRateKey: sampleRate,
        ]
        if channels == 2 {
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
            settings[AVChannelLayoutKey] = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: Double(index) * tileSeconds, preferredTimescale: 48_000),
            duration: CMTime(seconds: tileSeconds, preferredTimescale: 48_000)
        )
        guard reader.startReading() else { return nil }

        var samples: [Float] = []
        samples.reserveCapacity(Int(sampleRate * tileSeconds) * channels + 4096)
        var firstFrame: Int?
        while let buffer = output.copyNextSampleBuffer() {
            if firstFrame == nil {
                let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
                firstFrame = pts.isValid ? Int((pts.seconds * sampleRate).rounded()) : Int(Double(index) * tileSeconds * sampleRate)
            }
            var blockBuffer: CMBlockBuffer?
            var list = AudioBufferList()
            let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                buffer, bufferListSizeNeededOut: nil, bufferListOut: &list,
                bufferListSize: MemoryLayout<AudioBufferList>.size,
                blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
                flags: 0, blockBufferOut: &blockBuffer
            )
            guard status == noErr, let data = list.mBuffers.mData else { continue }
            let count = Int(list.mBuffers.mDataByteSize) / MemoryLayout<Float>.size
            samples.append(contentsOf: UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count))
        }
        guard reader.status == .completed, let start = firstFrame, !samples.isEmpty else { return nil }
        return WaveformDetailTile(startFrame: start, channels: channels, samples: samples)
    }
}
