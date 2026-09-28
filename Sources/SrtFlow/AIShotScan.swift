import AVFoundation
import CoreVideo
import Foundation

// MARK: - 找一个视频文件的镜头：从头解到尾、缓存、慢的交给任务
//
// 管什么：一个视频文件整个扫一遍（每帧让解码器直接缩到长边 48 像素，逐帧算和上一帧差多少、有多亮），交给
// `AIShotDetector` 找切点，结果按「路径 + 大小 + 修改时间」记在内存里（再问秒回；文件换了、改了就重扫）。
// 同一个文件同时只扫一次（第二个来问的接着等那一次）。解码是这件事的全部成本：M1 上 1440p 约 17 倍速，
// 分段并行也不更快（2026-09-28 实测，硬件解码器只有一个），14 分钟的课要 50 秒 —— 所以调用方最多等一会儿，
// 没扫完就把它变成 AI 的任务（`job(for:)`，get_job 看进度、cancel_job 能停），扫完的结果照样进缓存。
// 读采样的循环是单独的同步函数，在 `MediaReadQueue.shots` 上跑（docs/architecture/blocking-media-reads.md）。
// 不管什么：怎么判断切点（AIShotDetector，纯值）、写给 AI（AILookShots）。

@MainActor
enum AIShotScan {
    struct Result: Sendable {
        var shots: [AIShotDetector.Shot]
        var duration: Double
    }

    /// 解码器直接缩到这么大（长边像素）：够分辨换没换镜头，一帧几 KB。
    static let signatureLongSide = 48

    private struct Key: Hashable {
        var path: String
        var size: Int64
        var modified: TimeInterval
    }

    private final class Scan {
        let control = AIShotScanControl()
        var job: AIJobs.Job?
    }

    private static var finished: [Key: Result] = [:]
    private static var failures: [Key: String] = [:]
    private static var scans: [Key: Scan] = [:]

    /// 扫完的结果；没扫过、文件换了是 nil。
    static func cached(_ url: URL) -> Result? {
        finished[key(for: url)]
    }

    /// 开始扫（已经在扫就接着等那一次），最多等 `seconds` 秒：扫完了回结果；没扫完回 nil，接着在后台扫。
    /// 读不了（没有画面、文件坏了）抛错。
    static func result(for url: URL, waiting seconds: Double) async throws -> Result? {
        let key = key(for: url)
        if let hit = finished[key] { return hit }
        failures[key] = nil
        if scans[key] == nil { start(url, key: key) }
        let deadline = Date().addingTimeInterval(max(0, seconds))
        while scans[key] != nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        if let hit = finished[key] { return hit }
        if let failure = failures[key] { throw AIToolError(failure) }
        return nil
    }

    /// 还在扫的那个文件给 AI 的任务（同一次扫描只有一个任务）。扫完 / 没在扫回 nil。
    static func job(for url: URL) -> AIJobs.Job? {
        guard let scan = scans[key(for: url)] else { return nil }
        if let job = scan.job, job.status == .running { return job }
        let control = scan.control
        let job = AIJobs.shared.start(.shots, progress: { control.progress }, cancel: { control.cancel() })
        scan.job = job
        return job
    }

    private static func key(for url: URL) -> Key {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return Key(
            path: url.standardizedFileURL.path,
            size: (attributes?[.size] as? NSNumber)?.int64Value ?? -1,
            modified: (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        )
    }

    private static func start(_ url: URL, key: Key) {
        let scan = Scan()
        scans[key] = scan
        Task { @MainActor in
            let outcome = await read(url, control: scan.control)
            scans[key] = nil
            switch outcome {
            case .success(let result):
                finished[key] = result
                if let job = scan.job {
                    AIJobs.shared.finish(job, .done, detail: ["shots": .number(Double(result.shots.count))])
                }
            case .failure(let failure):
                failures[key] = failure.message
                if let job = scan.job {
                    AIJobs.shared.finish(job, scan.control.isCancelled ? .cancelled : .failed, message: failure.message)
                }
            }
        }
    }

    private static func read(_ url: URL, control: AIShotScanControl) async -> Swift.Result<Result, AIToolError> {
        let asset = AVURLAsset(url: url)
        guard let found = try? await asset.loadTracks(withMediaType: .video).first else {
            return .failure(AIToolError("\(url.lastPathComponent) has no picture to find shots in."))
        }
        let natural = (try? await found.load(.naturalSize)) ?? CGSize(width: 16, height: 9)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let longSide = Double(signatureLongSide)
        let scale = longSide / max(1, max(natural.width, natural.height))
        let width = max(4, Int((natural.width * scale).rounded()))
        let height = max(4, Int((natural.height * scale).rounded()))
        // AVAssetTrack 没标 Sendable；它是只读的，交给读取线程之后这边不再碰（同 AIBeats）。
        nonisolated(unsafe) let track = found
        let signals = await MediaReadQueue.run(on: MediaReadQueue.shots) {
            readSignals(asset: asset, track: track, width: width, height: height, duration: duration, control: control)
        }
        if control.isCancelled { return .failure(AIToolError("Finding the shots in \(url.lastPathComponent) was cancelled.")) }
        guard let signals, !signals.times.isEmpty else {
            return .failure(AIToolError("SrtFlow could not read the pictures of \(url.lastPathComponent)."))
        }
        let cuts = AIShotDetector.cutIndices(changes: signals.changes, brightness: signals.brightness, times: signals.times)
        let end = max(duration, signals.times.last ?? 0)
        return .success(Result(shots: AIShotDetector.shots(cutTimes: cuts.map { signals.times[$0] }, from: 0, to: end), duration: end))
    }

    private struct Signals: Sendable {
        var times: [Double] = []
        var changes: [Double] = []
        var brightness: [Double] = []
    }

    /// 阻塞地把整个文件解一遍：每帧的时间、和上一帧差多少、多亮。**只在 `MediaReadQueue` 上调。**
    nonisolated private static func readSignals(
        asset: AVURLAsset, track: AVAssetTrack, width: Int, height: Int, duration: Double, control: AIShotScanControl
    ) -> Signals? {
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        var signals = Signals()
        var previous: [UInt8]?
        while let sample = output.copyNextSampleBuffer() {
            if control.isCancelled {
                reader.cancelReading()
                return nil
            }
            guard let buffer = CMSampleBufferGetImageBuffer(sample), let rgb = rgbBytes(of: buffer) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            signals.times.append(time)
            signals.changes.append(previous.map { AIShotDetector.change($0, rgb) } ?? 0)
            signals.brightness.append(AIShotDetector.brightness(rgb))
            previous = rgb
            if signals.times.count % 30 == 0, duration > 0 { control.setProgress(min(1, time / duration)) }
        }
        return reader.status == .completed ? signals : nil
    }

    /// BGRA 的像素缓冲 → 紧挨着的 RGB 字节（去掉每行末尾的填充）。
    nonisolated private static func rgbBytes(of buffer: CVPixelBuffer) -> [UInt8]? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var rgb = [UInt8]()
        rgb.reserveCapacity(width * height * 3)
        for y in 0..<height {
            let row = bytes + y * rowBytes
            for x in 0..<width {
                let pixel = row + x * 4
                rgb.append(pixel[2])
                rgb.append(pixel[1])
                rgb.append(pixel[0])
            }
        }
        return rgb
    }
}

/// 读取线程和主线程之间传进度、传「取消」的小盒子。
final class AIShotScanControl: @unchecked Sendable {
    private let lock = NSLock()
    private var progressValue = 0.0
    private var cancelledValue = false

    var progress: Double { lock.withLock { progressValue } }
    var isCancelled: Bool { lock.withLock { cancelledValue } }

    func setProgress(_ value: Double) {
        lock.withLock { progressValue = value }
    }

    func cancel() {
        lock.withLock { cancelledValue = true }
    }
}
