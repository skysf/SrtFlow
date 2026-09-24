import AVFoundation
import Foundation

// MARK: - 波形数据：一个素材文件读一次，存多级峰值
//
// 2026-09-23 之前每段素材按自己的范围读成**固定 240 根柱子**（8kHz 单声道），
// 放大到最大也还是那 240 根 —— 「放到最大还是不够」有一半是它造成的。
//
// 现在按**文件**读一次（原生采样率、最多两个声道），存成多级峰值（Logic 的
// overview 文件是同一个意思）：第 0 级每 64 个采样一个桶，往上每级 4 桶并 1 桶。
// 画的时候按「一个像素盖多少采样」挑最细但不比像素细的那一级，放多大都不用再读
// PCM，裁切、分割、挪位置也不用（范围只是换个下标）。
//
// 数据按**块**存（每块 16384 个桶，48kHz 下约 22 秒），块一旦写完就不再变：
// 解码途中可以把「已经写完的块」直接交给界面先画出来（长录屏从左往右长出来），
// 交出去的只是一串引用，不会整份拷贝。
//
// 合同见 docs/architecture/audio-waveform.md。

/// 多级峰值里的一块（写完即不可变）。
final class WaveformChunk: Sendable {
    /// 这一块从第几个采样帧开始（每声道计）。
    let startFrame: Int
    /// 这一块实际有多少个采样帧（最后一块通常不满）。
    let frameCount: Int
    /// `levels[k][channel]` = 第 k 级、某个声道的 (min, max) 交错数组：
    /// `[min0, max0, min1, max1, …]`，Int16 满幅 ±32767 对应 ±1.0。
    let levels: [[[Int16]]]

    init(startFrame: Int, frameCount: Int, levels: [[[Int16]]]) {
        self.startFrame = startFrame
        self.frameCount = frameCount
        self.levels = levels
    }
}

/// 一个素材文件的多级峰值快照。解码途中也可以拿来画（`isComplete == false`，
/// 只含已经写完的块）。
struct WaveformPeaks: Sendable {
    /// 第 0 级一个桶多少个采样帧。
    static let baseBucket = 64
    /// 相邻两级之间几个桶并一个。
    static let levelFactor = 4
    /// 一块多少个第 0 级的桶（必须是 levelFactor 的整数次幂，每级才除得尽）。
    static let bucketsPerChunk = 16_384
    static var framesPerChunk: Int { baseBucket * bucketsPerChunk }
    /// 块内一共几级（16384 → 4096 → … → 1）。
    static let levelCount = 8

    let sampleRate: Double
    /// 1 或 2（更多声道读的时候就混成立体声了）。
    let channelCount: Int
    var chunks: [WaveformChunk]
    var isComplete: Bool

    /// 已经写完的那部分覆盖到第几个采样帧。
    var framesAvailable: Int {
        guard let last = chunks.last else { return 0 }
        return last.startFrame + last.frameCount
    }

    var duration: Double { sampleRate > 0 ? Double(framesAvailable) / sampleRate : 0 }

    /// 某一级一个桶多少个采样帧。
    static func samplesPerBucket(level: Int) -> Int {
        var size = baseBucket
        for _ in 0..<level { size *= levelFactor }
        return size
    }

    /// 「一个像素盖 `framesPerPixel` 个采样」时该用哪一级：最粗、但一个桶
    /// 不超过一个像素的那一级（再粗就会把相邻像素的峰值糊到一起）。
    static func level(forFramesPerPixel framesPerPixel: Double) -> Int {
        var level = 0
        while level + 1 < levelCount,
              Double(samplesPerBucket(level: level + 1)) <= framesPerPixel {
            level += 1
        }
        return level
    }

    /// `[from, to)` 这段采样帧里某个声道的最小 / 最大值（−1…1）。
    /// `channel == nil` = 所有声道合在一起（单条波形用）。没数据的地方返回 nil。
    func extremes(channel: Int?, from: Int, to: Int, level: Int) -> (min: Float, max: Float)? {
        guard to > from, !chunks.isEmpty else { return nil }
        let bucketSize = Self.samplesPerBucket(level: level)
        let channels = channel.map { [$0] } ?? Array(0..<channelCount)
        var low: Int16 = .max
        var high: Int16 = .min
        var found = false
        // 块是按 startFrame 升序排的，长度固定（除了最后一块）：直接算下标。
        let firstChunk = max(0, from / Self.framesPerChunk)
        let lastChunk = min(chunks.count - 1, (to - 1) / Self.framesPerChunk)
        guard firstChunk <= lastChunk else { return nil }
        for chunkIndex in firstChunk...lastChunk {
            let chunk = chunks[chunkIndex]
            let localFrom = max(0, from - chunk.startFrame)
            let localTo = min(chunk.frameCount, to - chunk.startFrame)
            guard localTo > localFrom, chunk.levels.indices.contains(level) else { continue }
            let firstBucket = localFrom / bucketSize
            let lastBucket = (localTo - 1) / bucketSize
            for ch in channels where chunk.levels[level].indices.contains(ch) {
                let pairs = chunk.levels[level][ch]
                let upper = min(lastBucket, pairs.count / 2 - 1)
                guard firstBucket <= upper else { continue }
                pairs.withUnsafeBufferPointer { buffer in
                    for bucket in firstBucket...upper {
                        low = min(low, buffer[bucket * 2])
                        high = max(high, buffer[bucket * 2 + 1])
                    }
                }
                found = true
            }
        }
        guard found else { return nil }
        return (Float(low) / Float(Int16.max), Float(high) / Float(Int16.max))
    }
}

// MARK: - 读取

/// 波形数据的全局仓库：同一个文件只解一次，多段素材 / 多次重画共用。
///
/// 解码途中通过 `AsyncStream` 陆续交出快照（每写完一块、或每隔一小会儿交一次），
/// 界面先画出已经有的部分。
actor WaveformStore {
    static let shared = WaveformStore()

    private struct Entry {
        var latest: WaveformPeaks?
        var continuations: [UUID: AsyncStream<WaveformPeaks>.Continuation] = [:]
        var failed = false
        /// 最近一次被要的时间（LRU 淘汰用）。
        var lastUsed = Date()
    }

    private var entries: [URL: Entry] = [:]
    /// 缓存上限（字节，估算）。长录屏一小时约 30MB，这个量够十来个。
    private let byteBudget = 400 * 1024 * 1024

    /// 某个文件的波形：先交出已有的快照（有的话），之后每有新块再交一次，
    /// 读完（或失败）即结束。
    func peaks(for url: URL) -> AsyncStream<WaveformPeaks> {
        let key = url.standardizedFileURL
        let token = UUID()
        let (stream, continuation) = AsyncStream<WaveformPeaks>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        var entry = entries[key] ?? Entry()
        entry.lastUsed = Date()
        if let latest = entry.latest { continuation.yield(latest) }
        if entry.failed || entry.latest?.isComplete == true {
            continuation.finish()
            entries[key] = entry
            return stream
        }
        let isNew = entries[key] == nil
        entry.continuations[token] = continuation
        entries[key] = entry
        continuation.onTermination = { [weak self] _ in
            Task { await self?.dropContinuation(token, for: key) }
        }
        if isNew {
            // 性能测试等后台读完再量（PerfCounters.backgroundReadBegan）。
            PerfCounters.backgroundReadBegan()
            Task.detached(priority: .utility) {
                await WaveformDecoder.decode(url: key) { snapshot in
                    await self.publish(snapshot, for: key)
                }
                await self.finish(key)
                PerfCounters.backgroundReadEnded()
            }
        }
        return stream
    }

    private func dropContinuation(_ token: UUID, for key: URL) {
        entries[key]?.continuations[token] = nil
    }

    private func publish(_ snapshot: WaveformPeaks, for key: URL) {
        guard var entry = entries[key] else { return }
        entry.latest = snapshot
        for continuation in entry.continuations.values { continuation.yield(snapshot) }
        entries[key] = entry
    }

    private func finish(_ key: URL) {
        guard var entry = entries[key] else { return }
        if entry.latest == nil { entry.failed = true }
        for continuation in entry.continuations.values { continuation.finish() }
        entry.continuations = [:]
        entries[key] = entry
        evictIfNeeded()
    }

    /// 超预算时按最久没用的先扔（正在读的不扔）。
    private func evictIfNeeded() {
        func bytes(_ entry: Entry) -> Int {
            guard let peaks = entry.latest else { return 0 }
            // 第 0 级 ≈ 帧数 / 64 × 2（min+max）× 2 字节 × 声道，其余各级再加三分之一。
            return peaks.framesAvailable / WaveformPeaks.baseBucket * 4 * peaks.channelCount * 4 / 3
        }
        var total = entries.values.reduce(0) { $0 + bytes($1) }
        guard total > byteBudget else { return }
        let victims = entries
            .filter { $0.value.continuations.isEmpty && $0.value.latest?.isComplete == true }
            .sorted { $0.value.lastUsed < $1.value.lastUsed }
        for (key, entry) in victims where total > byteBudget {
            total -= bytes(entry)
            entries[key] = nil
        }
    }
}

/// 真正干活的那一段：AVAssetReader 把整条音轨解成 Float32，边读边分桶。
enum WaveformDecoder {
    /// 解完一块就交一次，最后一次 `isComplete == true`。读不了（没有音轨、
    /// 格式不认）时一次都不交。
    ///
    /// 这里只做异步的那部分（找音轨、看声道数）。**读 PCM 的循环是阻塞的，在
    /// `MediaReadQueue.overview` 上跑，不许挪回这个 async 函数里**：打开工程时几十个
    /// 文件一起读，会把 Swift 并发的线程池堵到死锁（2026-09-23 事故，见 `MediaReadQueue`）。
    /// 读的途中攒出的快照经一条 AsyncStream 送回来，按先后交出去。
    static func decode(url: URL, publish: (WaveformPeaks) async -> Void) async {
        let asset = AVURLAsset(url: url)
        guard let found = try? await asset.loadTracks(withMediaType: .audio).first else { return }
        let sourceChannels = await sourceChannelCount(found)
        // AVAssetTrack 没标 Sendable；它是只读的，交给读取线程之后这边不再碰。
        nonisolated(unsafe) let track = found
        let (snapshots, feed) = AsyncStream<WaveformPeaks>.makeStream()
        MediaReadQueue.overview.addOperation {
            read(asset: asset, track: track, sourceChannels: sourceChannels) { feed.yield($0) }
            feed.finish()
        }
        for await snapshot in snapshots { await publish(snapshot) }
    }

    /// 把整条音轨阻塞地读完：读的途中隔一会儿 `emit` 一份已写完的块，读完再 `emit`
    /// 完整的那份。**只在 `MediaReadQueue` 上调。**
    private static func read(
        asset: AVURLAsset,
        track: AVAssetTrack,
        sourceChannels: Int,
        emit: (WaveformPeaks) -> Void
    ) {
        guard let reader = try? AVAssetReader(asset: asset) else { return }
        let channels = min(2, max(1, sourceChannels))
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
            AVNumberOfChannelsKey: channels,
        ]
        // 超过两个声道（5.1 之类）让读取器混成立体声：要给它一个声道布局。
        if sourceChannels > 2 {
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
            settings[AVChannelLayoutKey] = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return }
        reader.add(output)
        guard reader.startReading() else { return }

        var builder: ChunkBuilder?
        var sampleRate = 0.0
        var chunks: [WaveformChunk] = []
        var lastPublish = Date.distantPast

        while let buffer = output.copyNextSampleBuffer() {
            if builder == nil {
                guard let format = CMSampleBufferGetFormatDescription(buffer),
                      let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
                else { continue }
                sampleRate = asbd.mSampleRate
                builder = ChunkBuilder(channels: Int(asbd.mChannelsPerFrame), startFrame: 0)
            }
            guard var current = builder else { continue }
            var blockBuffer: CMBlockBuffer?
            var list = AudioBufferList()
            let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                buffer,
                bufferListSizeNeededOut: nil,
                bufferListOut: &list,
                bufferListSize: MemoryLayout<AudioBufferList>.size,
                blockBufferAllocator: nil,
                blockBufferMemoryAllocator: nil,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
            guard status == noErr, let data = list.mBuffers.mData else { continue }
            let floats = Int(list.mBuffers.mDataByteSize) / MemoryLayout<Float>.size
            let samples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: floats)
            current.append(interleaved: samples) { finished in chunks.append(finished) }
            builder = current
            if Date().timeIntervalSince(lastPublish) > 0.25, !chunks.isEmpty {
                lastPublish = Date()
                emit(WaveformPeaks(
                    sampleRate: sampleRate, channelCount: current.channels,
                    chunks: chunks, isComplete: false
                ))
            }
        }
        guard reader.status == .completed, var current = builder else { return }
        if let tail = current.finishChunk() { chunks.append(tail) }
        emit(WaveformPeaks(
            sampleRate: sampleRate, channelCount: current.channels, chunks: chunks, isComplete: true
        ))
    }

    private static func sourceChannelCount(_ track: AVAssetTrack) async -> Int {
        guard let formats = try? await track.load(.formatDescriptions),
              let first = formats.first,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(first)?.pointee
        else { return 2 }
        return Int(asbd.mChannelsPerFrame)
    }
}

/// 边读边分桶：攒满一块就封口交出去。
struct ChunkBuilder {
    let channels: Int
    private(set) var startFrame: Int
    /// 当前块第 0 级已经写了几个桶。
    private var bucketCount = 0
    /// 当前桶里已经累计了几个采样帧。
    private var framesInBucket = 0
    private var framesInChunk = 0
    private var currentMin: [Float]
    private var currentMax: [Float]
    /// 当前块的第 0 级：每声道一条 (min, max) 交错数组。
    private var base: [[Int16]]

    init(channels: Int, startFrame: Int) {
        self.channels = max(1, channels)
        self.startFrame = startFrame
        currentMin = Array(repeating: .greatestFiniteMagnitude, count: max(1, channels))
        currentMax = Array(repeating: -.greatestFiniteMagnitude, count: max(1, channels))
        base = Array(repeating: [], count: max(1, channels))
        for index in base.indices { base[index].reserveCapacity(WaveformPeaks.bucketsPerChunk * 2) }
    }

    /// 喂一串交错的采样；每封一块回调一次。
    mutating func append(interleaved samples: UnsafeBufferPointer<Float>, onChunk: (WaveformChunk) -> Void) {
        let frames = samples.count / channels
        for frame in 0..<frames {
            let offset = frame * channels
            for ch in 0..<channels {
                let value = samples[offset + ch]
                if value < currentMin[ch] { currentMin[ch] = value }
                if value > currentMax[ch] { currentMax[ch] = value }
            }
            framesInBucket += 1
            framesInChunk += 1
            if framesInBucket == WaveformPeaks.baseBucket {
                closeBucket()
                if bucketCount == WaveformPeaks.bucketsPerChunk, let chunk = finishChunk() {
                    onChunk(chunk)
                }
            }
        }
    }

    private mutating func closeBucket() {
        for ch in 0..<channels {
            base[ch].append(Self.quantize(currentMin[ch]))
            base[ch].append(Self.quantize(currentMax[ch]))
            currentMin[ch] = .greatestFiniteMagnitude
            currentMax[ch] = -.greatestFiniteMagnitude
        }
        bucketCount += 1
        framesInBucket = 0
    }

    /// 把当前块封口（含没攒满的最后一个桶），算出上面各级，交出去。
    mutating func finishChunk() -> WaveformChunk? {
        if framesInBucket > 0 { closeBucket() }
        guard bucketCount > 0 else { return nil }
        var levels: [[[Int16]]] = [base]
        var previous = base
        for _ in 1..<WaveformPeaks.levelCount {
            var next: [[Int16]] = Array(repeating: [], count: channels)
            for ch in 0..<channels {
                let pairs = previous[ch]
                let buckets = pairs.count / 2
                var merged: [Int16] = []
                merged.reserveCapacity((buckets + 3) / 4 * 2)
                var index = 0
                while index < buckets {
                    let end = min(buckets, index + WaveformPeaks.levelFactor)
                    var low = Int16.max
                    var high = Int16.min
                    for bucket in index..<end {
                        low = min(low, pairs[bucket * 2])
                        high = max(high, pairs[bucket * 2 + 1])
                    }
                    merged.append(low)
                    merged.append(high)
                    index = end
                }
                next[ch] = merged
            }
            levels.append(next)
            previous = next
        }
        let chunk = WaveformChunk(startFrame: startFrame, frameCount: framesInChunk, levels: levels)
        startFrame += framesInChunk
        framesInChunk = 0
        bucketCount = 0
        base = Array(repeating: [], count: channels)
        for index in base.indices { base[index].reserveCapacity(WaveformPeaks.bucketsPerChunk * 2) }
        return chunk
    }

    /// −1…1 → Int16。超过满幅的采样（浮点素材可能有）夹在 ±32767：
    /// 它照样画到顶，爆音标记看的是乘上增益之后的值，不靠这里。
    static func quantize(_ value: Float) -> Int16 {
        guard value.isFinite else { return 0 }
        return Int16((min(max(value, -1), 1) * Float(Int16.max)).rounded())
    }
}
