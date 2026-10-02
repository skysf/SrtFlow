import Foundation
import SrtFlowMCPKit

// MARK: - 一次 upscale 从原片到落盘的流水线（不碰界面、不碰账本、不碰钥匙串）
//
// 管什么：裁出那一段（或整个 mp4 直接用）→ 上传 → 提交、等、取结果 → 下载 → 把原片那一段声音封回去 → 探测 → 起名落盘，
// 每一步报阶段（`FalJobPhase`，上传 / 下载带字节比例），Task 被取消时每一步都停得下来（在飞的 fal 请求替 fal 也取消，中间文件不留）。
// 结果是一个 `UpscaleOutcome`：文件、探测信息、来源记录（换源时拼成 `ClipSourceSwap.Replacement`）。
// 自检用假 URLSession 走整条线（checks/Upscale）。
// 不管什么：花钱的把关和记账、Key（UpscaleJob）；换源（VideoEditClipUpscale.swift）；界面（第四刀）。

struct UpscaleRequest: Sendable {
    var originalURL: URL
    var originalInfo: MediaInfo
    var range: UpscaleRange
    var tier: FalUpscaleTier
    var target: FalUpscaleTarget
    /// 原片的文件夹写不进去时退到哪（工程的家、下载）。
    var fallbackFolders: [URL]

    var plan: FalUpscalePlan { tier.plan(source: originalInfo.displaySize, target: target) }
    var estimate: Double { tier.estimate(seconds: range.duration, plan: plan) }
}

struct UpscaleOutcome: Sendable {
    var file: URL
    var info: MediaInfo
    var record: ClipUpscaleRecord
    var requestID: String
    /// 原片的声音封回去了（原片没声音时也算 true：没什么可封的）；ffmpeg 不在时是 false，文件带的是 fal 给的声音（或没有）。
    var audioRestored: Bool
    var elapsed: Double
}

enum UpscalePipelineError: Error, Equatable {
    case trim(String)
    case probe(String)
    case save(String)
    var message: String {
        switch self {
        case .trim(let detail): return "Could not cut the clip for upscaling: \(detail)"
        case .probe(let detail): return "Could not read the upscaled file: \(detail)"
        case .save(let detail): return "Could not save the upscaled file: \(detail)"
        }
    }
}

/// 取消的标志：阻塞的裁切跑在 OperationQueue 的线程上，那里看不见 Task 的取消，用这个盒子传。
final class UpscaleCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

enum UpscalePipeline {
    /// 整个文件直接上传的条件：范围就是整个文件、是 mp4、不超过模型的时长 / 大小上限。否则裁一份。
    static func uploadsWholeFile(_ request: UpscaleRequest) -> Bool {
        let range = request.range, info = request.originalInfo
        guard range.start <= ClipUpscaleRecord.frameSlack, range.end >= info.duration - ClipUpscaleRecord.frameSlack else { return false }
        guard request.originalURL.pathExtension.lowercased() == "mp4" else { return false }
        if let maxSeconds = request.tier.maxInputSeconds, info.duration > maxSeconds { return false }
        if let maxBytes = request.tier.maxInputBytes, info.fileBytes > maxBytes { return false }
        return true
    }

    static func run(
        _ request: UpscaleRequest, client: FalClient, ffmpeg: URL?, workFolder: URL,
        phase report: @escaping @Sendable (FalJobPhase) -> Void
    ) async throws -> UpscaleOutcome {
        let started = Date()
        // 同一个阶段同一个比例只报一次（轮询每 1–4 秒回一次 IN_PROGRESS，界面不用每次都醒）。
        let last = FalPhaseBox()
        let phase: @Sendable (FalJobPhase) -> Void = { next in
            guard last.swap(next) else { return }
            report(next)
        }
        try FileManager.default.createDirectory(at: workFolder, withIntermediateDirectories: true)
        let stamp = UUID().uuidString
        let temporaries = [workFolder.appendingPathComponent("\(stamp)-in.mp4"), workFolder.appendingPathComponent("\(stamp)-out.mp4"),
                           workFolder.appendingPathComponent("\(stamp)-muxed.mp4")]
        defer { for url in temporaries { try? FileManager.default.removeItem(at: url) } }

        // 1. 输入：整个 mp4 直接用，否则裁出那一段（只有画面）。
        phase(.preparing)
        let offset: Double
        let input: URL
        if uploadsWholeFile(request) {
            input = request.originalURL
            offset = 0
        } else {
            input = temporaries[0]
            offset = request.range.start
            try await trim(request, to: input)
        }
        try Task.checkCancellation()

        // 2. 上传、提交、等、取结果、下载。
        phase(.uploading(fraction: nil))
        let link = try await client.upload(fileURL: input, contentType: "video/mp4", fileName: "upscale-input.mp4") { fraction in
            phase(.uploading(fraction: FalJobPhase.quantized(fraction)))
        }
        let body = request.tier.body(videoURL: link.absoluteString, plan: request.plan, sourceFrameRate: request.originalInfo.frameRate)
        let outcome = try await client.run(endpoint: request.tier.endpoint, body: body, maxSeconds: request.tier.maxSeconds) { status in
            switch status {
            case .queued(let position): phase(.queued(position: position))
            case .running: phase(.processing)
            case .completed: break   // 下一步就是下载
            }
        }
        let media = try FalOutputs.media(from: outcome.result, kind: .textToVideo)
        phase(.downloading(fraction: nil))
        try await client.download(media.url, to: temporaries[1]) { fraction in
            phase(.downloading(fraction: FalJobPhase.quantized(fraction)))
        }
        try Task.checkCancellation()

        // 3. 探测；原片有声音就把那一段封回去（fal 给的声音不可信）；再探一遍。
        phase(.finishing)
        var file = temporaries[1]
        var info = try await probe(file, ffmpeg: ffmpeg)
        var audioRestored = !request.originalInfo.hasAudio
        if request.originalInfo.hasAudio, let ffmpeg {
            try await UpscaleAudioMux.mux(
                ffmpeg: ffmpeg, upscaled: file, original: request.originalURL, start: offset, duration: info.duration,
                videoCodec: info.videoCodec, output: temporaries[2]
            )
            file = temporaries[2]
            info = try await probe(file, ffmpeg: ffmpeg)
            audioRestored = true
        }
        try Task.checkCancellation()

        // 4. 起名落盘（原片旁边；撞名加编号）。
        let destination = UpscaleOutputName.destination(
            original: request.originalURL, outputSize: info.displaySize, tier: request.tier.id, fallbacks: request.fallbackFolders
        )
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: file, to: destination)
        } catch {
            throw UpscalePipelineError.save(error.localizedDescription)
        }
        let record = ClipUpscaleRecord(
            originalURL: request.originalURL, sourceOffset: offset, tier: request.tier.id, originalInfo: request.originalInfo, madeAt: Date()
        )
        return UpscaleOutcome(
            file: destination, info: info, record: record, requestID: outcome.submission.requestID, audioRestored: audioRestored,
            elapsed: Date().timeIntervalSince(started)
        )
    }

    /// 裁出 `[start, end)`（阻塞的读和编跑在 MediaReadQueue.export 上；Task 取消时那边也停）。
    private static func trim(_ request: UpscaleRequest, to output: URL) async throws {
        let source: UpscaleSourceTrimmer.Source
        switch await UpscaleSourceTrimmer.load(request.originalURL) {
        case .success(let loaded): source = loaded
        case .failure(let failure): throw UpscalePipelineError.trim("\(failure)")
        }
        let flag = UpscaleCancelFlag()
        let start = request.range.start, end = request.range.end
        let result = await withTaskCancellationHandler {
            await MediaReadQueue.run(on: MediaReadQueue.export) {
                UpscaleSourceTrimmer.trim(source, start: start, end: end, to: output, isCancelled: { flag.isCancelled })
            }
        } onCancel: {
            flag.cancel()
        }
        switch result {
        case .success: return
        case .failure(.cancelled): throw CancellationError()
        case .failure(let failure): throw UpscalePipelineError.trim("\(failure)")
        }
    }

    private static func probe(_ url: URL, ffmpeg: URL?) async throws -> MediaInfo {
        switch await MediaProbe.probe(url: url, ffmpeg: ffmpeg) {
        case .success(let info): return info
        case .failure(let error): throw UpscalePipelineError.probe(error.localizedDescription)
        }
    }
}
