import AVFoundation
import Foundation
import SrtFlowMCPKit

// MARK: - 鼓点：读采样、缓存、写给 AI 看
//
// 管什么：一个文件某一段的鼓点（速度、每一拍、小节头）—— 读成 11025 Hz 的单声道（读的循环是单独的同步函数，
// 在 `MediaReadQueue.analysis` 上跑，docs/architecture/blocking-media-reads.md），交给 `AudioBeatTracker` 算，
// 按「路径 + 大小 + 修改时间 + 区间」记在内存里（同一首再问是秒回；文件换了、改了就重算）。
// listen 的 beats 和 cut_to_beat 都从这里拿。
// 不管什么：怎么算（AudioBeatTracker，纯计算）、换到时间线（调用方给换算）。

@MainActor
enum AIBeats {
    static let sampleRate = 11_025.0
    /// 一次最多分析多长（秒），见 BeatAnalysisWindow。
    static let maxSeconds = BeatAnalysisWindow.maxSeconds

    private struct Key: Hashable {
        var path: String
        var size: Int64
        var modified: TimeInterval
        var from: Double
        var to: Double
    }

    /// nil 的值 = 分析过、听不出清楚的节拍。
    private static var cache: [Key: AudioBeatTracker.Analysis?] = [:]

    /// 源 [from, to) 秒的鼓点，时间是源秒。听不出清楚的节拍是 nil；文件读不了抛错。
    /// 真正分析的是整首歌（`BeatAnalysisWindow`），listen 和 cut_to_beat 看同一份；调用方再按自己的区间挑拍。
    static func analysis(of url: URL, from: Double, to: Double) async throws -> AudioBeatTracker.Analysis? {
        let asset = AVURLAsset(url: url)
        let fileDuration = (try? await asset.load(.duration))?.seconds ?? to
        let window = BeatAnalysisWindow.resolve(from: from, to: to, fileDuration: fileDuration)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let key = Key(
            path: url.standardizedFileURL.path,
            size: (attributes?[.size] as? NSNumber)?.int64Value ?? -1,
            modified: (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
            from: window.from, to: window.to
        )
        if let hit = cache[key] { return hit }
        guard let found = try? await asset.loadTracks(withMediaType: .audio).first else {
            throw AIToolError("\(url.lastPathComponent) has no sound to find beats in.")
        }
        // AVAssetTrack 没标 Sendable；它是只读的，交给读取线程之后这边不再碰（同 WaveformDetail）。
        nonisolated(unsafe) let track = found
        let rate = sampleRate
        let read = await MediaReadQueue.run(on: MediaReadQueue.analysis) { () -> Reading? in
            guard let pcm = readMono(asset: asset, track: track, from: window.from, to: window.to, sampleRate: rate) else { return nil }
            return Reading(analysis: AudioBeatTracker.analyze(pcm.samples, sampleRate: rate).map { shifted($0, by: pcm.start) })
        }
        guard let read else { throw AIToolError("SrtFlow could not read the sound of \(url.lastPathComponent).") }
        cache[key] = .some(read.analysis)
        return read.analysis
    }

    private struct Reading: Sendable {
        var analysis: AudioBeatTracker.Analysis?
    }

    /// 分析出来的时间是从这段采样的第一帧算的；加上第一帧在文件里的时间。
    nonisolated private static func shifted(_ analysis: AudioBeatTracker.Analysis, by start: Double) -> AudioBeatTracker.Analysis {
        var moved = analysis
        moved.beats = analysis.beats.map { $0 + start }
        moved.downbeats = analysis.downbeats.map { $0 + start }
        return moved
    }

    /// 阻塞地读出 [from, to) 的单声道浮点采样和第一帧的时间。**只在 `MediaReadQueue` 上调。**
    nonisolated private static func readMono(
        asset: AVURLAsset, track: AVAssetTrack, from: Double, to: Double, sampleRate: Double
    ) -> (samples: [Float], start: Double)? {
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Mono
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: sampleRate,
            AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: from, preferredTimescale: 48_000), end: CMTime(seconds: to, preferredTimescale: 48_000)
        )
        guard reader.startReading() else { return nil }
        var samples: [Float] = []
        samples.reserveCapacity(Int((to - from) * sampleRate) + 4096)
        var start: Double?
        while let buffer = output.copyNextSampleBuffer() {
            if start == nil {
                let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
                start = pts.isValid ? pts.seconds : from
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
        guard reader.status == .completed, !samples.isEmpty else { return nil }
        return (samples, start ?? from)
    }

    // MARK: 写给 AI 看

    /// 源时间的鼓点 → 给 AI 的那几项：只列 [sourceFrom, sourceTo) 里的拍，时间用 `timeline` 换算（片段是时间线秒，
    /// 文件原样），速度乘上播放速度。
    nonisolated static func json(
        _ analysis: AudioBeatTracker.Analysis?, sourceFrom: Double, sourceTo: Double, speed: Double,
        timeline: (Double) -> Double
    ) -> [String: JSONValue] {
        guard let analysis else { return ["beats": "none: no clear beat in this sound"] }
        let inside = { (time: Double) in time >= sourceFrom - 0.001 && time < sourceTo }
        let round = { (time: Double) -> JSONValue in .number((timeline(time) * 100).rounded() / 100) }
        var object: [String: JSONValue] = [
            "tempo_bpm": .number((analysis.bpm * speed * 10).rounded() / 10),
            "beats": .array(analysis.beats.filter(inside).map(round)),
            "downbeats": .array(analysis.downbeats.filter(inside).map(round))
        ]
        if analysis.confidence < AudioBeatTracker.clearConfidence {
            object["beat_note"] = "The beat is weak or uneven here; cuts on these beats may not feel on time."
        }
        return object
    }
}
