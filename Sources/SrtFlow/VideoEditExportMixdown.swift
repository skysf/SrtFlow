import AVFoundation

// MARK: - 成片的声音：用预览那个引擎离线渲出来
//
// 2026-09-24 起，剪辑导出的声音**不再由 ffmpeg 另搭一套滤镜链**（以前是每段 atrim → atempo →
// volume / aeval → afade → adelay，主轨 concat / acrossfade，最后 amix）；2026-10-01 PR3a 起也不再读
// AVFoundation 的合成 + audioMix，而是和预览**同一个** `TimelineAudioEngine`（AudioEngineConfig 同一份配置、
// 同一段渲染代码）离线渲成一个 raw f32 文件；ffmpeg 只负责编码、和画面合在一起。
//
// 为什么：用户嫌「每个声音功能要在预览、成片各做一遍」效率低，而两份实现迟早分叉 —— 音量、
// 渐变、曲线、推子为了让 ffmpeg 模仿 AVFoundation 攒下了一整套规矩（aeval 平衡树、afade 必须
// 在 atempo 之后、增益必须在 adelay 之前……）。现在成片听到的就是预览听到的那一份。
// 方案与实测：docs/plans/2026-09-24-sound-scenes.md；长期约束：docs/architecture/export-audio-mixdown.md。
//
// 这个文件只管「读出来、过限幅器、写成文件、量电平和响度」；限幅怎么做在 ExportPeakLimiter、响度怎么量在
// ExportLoudnessMeter；滤镜图怎么接这个文件在 VideoEditExportGraph，电平怎么告诉用户在 VideoEditExporter /
// VideoEditExportSheet（面板）和 AIExportTools（AI 的结果）。

enum ExportAudioMixdown {
    /// 和以前导出链末尾的 `aresample=48000,aformat=…stereo` 同一个规格。
    static let sampleRate = 48_000
    static let channels = 2

    /// ffmpeg 读混音文件的输入参数（raw f32le，没有容器头，靠这几个参数说清楚格式）。
    static func inputArguments(_ file: URL) -> [String] {
        ["-f", "f32le", "-ar", String(sampleRate), "-ac", String(channels), "-i", file.path]
    }

    /// 混音的电平（写 f32 时量的）：限幅前的峰值、超过上限压了多久多深、写出去的峰值、整段响度。导出结果和导出面板拿它告诉用户。
    struct Levels: Equatable {
        /// 限幅前的采样峰值（线性）。
        var peak: Float
        /// 写进文件的采样峰值（线性，≤ 上限）。
        var outputPeak: Float
        /// 超过上限、被压下来的帧数（任一声道超过就算）。
        var limitedFrames: Int
        /// 压得最深的那一下压了多少 dB（0 = 从没压过）。
        var maxReductionDB: Double
        /// 整段响度（BS.1770 带门限，LUFS）；全是静音时 nil。
        var loudnessLUFS: Double?

        /// 压过这么深（dB）就建议用户把主推子降下来：轻轻碰一下上限听不出，压 3 dB 以上就是另一种声音了。
        static let attentionThresholdDB = 3.0

        var peakDBFS: Double { 20 * log10(Double(max(peak, 1e-9))) }
        var outputPeakDBFS: Double { 20 * log10(Double(max(outputPeak, 1e-9))) }
        var limitedSeconds: Double { Double(limitedFrames) / Double(ExportAudioMixdown.sampleRate) }
        var isLimited: Bool { limitedFrames > 0 }
        /// 压得超过 `attentionThresholdDB`：面板和 AI 的结果多说一句「把主推子降这么多更干净」。
        var needsAttention: Bool { maxReductionDB > Self.attentionThresholdDB }
        /// 建议主推子降多少：正好是压得最深的那一下（降了它就一帧都不用压）。
        var suggestedReductionDB: Double { maxReductionDB }
    }

    /// 写进 f32 的上限：−1 dBFS。混音本身是线性的、和可以过 0 dBFS（AVFoundation 的 float 不削），但交给 AAC 编码器的信号
    /// 过了 0 就不可预期：2026-09-30 探针实测两轨各 +6 dB 叠加，成片 RMS 比混音掉 4.5 dB、峰值却冒到 +12 dBFS，主推子降 3 dB
    /// 成片只降 2 dB（docs/bugfixes/2026-09-30-export-mix-over-0dbfs-into-aac.md）。所以写之前过 ExportPeakLimiter（前瞻 5 ms、
    /// 释放 80 ms 的真峰值限幅，不是削平），留 1 dB 给编码器的过冲；限幅前的峰值、压了多久多深记在 Levels 里报给用户。
    static let peakCeiling: Float = ExportPeakLimiter.defaultCeiling

    enum Outcome: Equatable {
        /// 写好了，正好是要的长度。
        case written(Levels)
        /// 这条时间线一个出声的段都没有：调用方给成片垫静音。
        case silent
    }

    /// 读混音失败。界面上显示的是这一句（导出面板的错误行），底层原因接在后面。
    struct ReadError: LocalizedError {
        var detail: String?
        var errorDescription: String? {
            [L10n("Could not mix the timeline’s sound for export."), detail].compactMap { $0 }.joined(separator: " ")
        }
    }

    /// 读出 `state` 整条时间线的混音写到 `file`：**正好 `duration` 秒**（读短了补静音、长了截掉），
    /// 和画面一样长 —— 以前的滤镜链靠 `anullsrc` 补齐，这条账不能丢。
    static func render(
        state: TimelineState,
        duration: Double,
        to file: URL,
        cancellation: ExportCancellationToken? = nil
    ) async throws -> Outcome {
        if cancellation?.isCancelled == true { throw CancellationError() }
        // 和预览同一份配置（段落、增益、场景、变速都在里面；`make` 自己排序、展开转场）。
        let config = AudioEngineConfig.make(from: state)
        guard !config.tracks.isEmpty else { return .silent }
        let frames = max(0, Int((duration * Double(sampleRate)).rounded()))
        let result = await MediaReadQueue.run(on: MediaReadQueue.export) {
            renderWithEngine(config, frames: frames, to: file, cancellation: cancellation)
        }
        switch result {
        case .success(let levels): return .written(levels)
        case .failure(let error): throw error
        }
    }

    /// 阻塞地渲完整条混音、边渲边写盘。**只在 `MediaReadQueue` 上调**（引擎的喂样在这条线程上同步读文件，阻塞读取
    /// 不许进 Swift 并发的线程池，见 docs/architecture/blocking-media-reads.md）。
    private static func renderWithEngine(
        _ config: AudioEngineConfig,
        frames: Int,
        to file: URL,
        cancellation: ExportCancellationToken?
    ) -> Result<Levels, Error> {
        guard let engine = try? TimelineAudioEngine(config: config, mode: .offline) else {
            return .failure(ReadError(detail: nil))
        }
        guard FileManager.default.createFile(atPath: file.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: file) else {
            return .failure(ReadError(detail: file.lastPathComponent))
        }
        defer { try? handle.close() }
        var sink = FrameSink(handle: handle, limit: frames, channels: channels, sampleRate: sampleRate)
        var cancelled = false
        do {
            try engine.renderOffline(duration: Double(frames) / Double(sampleRate)) { interleaved, got in
                if cancellation?.isCancelled == true {
                    cancelled = true
                    return false
                }
                sink.append(interleaved, frames: got)
                return true
            }
        } catch {
            return .failure(ReadError(detail: "\(error)"))
        }
        if cancelled { return .failure(CancellationError()) }
        // 引擎正好渲到 `frames`；万一短了补静音补到正好；再把限幅器延迟线里的最后 5 ms 冲出来。
        sink.padSilence(upTo: frames)
        let levels = sink.finish()
        return sink.failure.map { .failure($0) } ?? .success(levels)
    }
}

/// 往 raw 文件里按帧写（引擎渲出来的交错 f32）：记着收了几帧，超过上限的截掉；每一帧先过限幅器（ExportPeakLimiter，延迟 5 ms）再写盘，
/// 写出去的采样同时喂响度表（ExportLoudnessMeter）。`finish()` 把延迟线冲干净，写出去的总帧数 = 收进来的。
private struct FrameSink {
    let handle: FileHandle
    let limit: Int
    let channels: Int
    /// 收进来的帧数（含补的静音）。
    private(set) var received = 0
    private(set) var failure: Error?
    private var limiter: ExportPeakLimiter
    private var meter: ExportLoudnessMeter
    private var pending: [Float] = []

    init(handle: FileHandle, limit: Int, channels: Int, sampleRate: Int) {
        self.handle = handle
        self.limit = limit
        self.channels = channels
        limiter = ExportPeakLimiter(channels: channels, sampleRate: sampleRate)
        meter = ExportLoudnessMeter(channels: channels)
    }

    mutating func padSilence(upTo frame: Int) {
        var missing = min(frame, limit) - received
        let chunk = 48_000
        while missing > 0, failure == nil {
            let count = min(missing, chunk)
            let silence = [Float](repeating: 0, count: count * channels)
            silence.withUnsafeBufferPointer { feed($0, frames: count) }
            missing -= count
        }
    }

    /// 引擎渲出来的一拍（交错的立体声 f32）。
    mutating func append(_ interleaved: UnsafeBufferPointer<Float>, frames: Int) {
        let count = min(frames, limit - received)
        guard count > 0 else { return }
        feed(UnsafeBufferPointer(rebasing: interleaved[0..<(count * channels)]), frames: count)
    }

    /// 冲掉限幅器的延迟，写完最后几帧；给出电平。
    mutating func finish() -> ExportAudioMixdown.Levels {
        pending.removeAll(keepingCapacity: true)
        limiter.flush(into: &pending)
        write(pending)
        return .init(
            peak: limiter.inputPeak, outputPeak: limiter.outputPeak, limitedFrames: limiter.overFrames,
            maxReductionDB: -20 * log10(Double(max(limiter.minimumGain, 1e-9))), loudnessLUFS: meter.integratedLUFS
        )
    }

    private mutating func feed(_ samples: UnsafeBufferPointer<Float>, frames: Int) {
        pending.removeAll(keepingCapacity: true)
        limiter.process(samples, frames: frames, into: &pending)
        received += frames
        write(pending)
    }

    private mutating func write(_ samples: [Float]) {
        guard !samples.isEmpty, failure == nil else { return }
        samples.withUnsafeBufferPointer { meter.add($0, frames: samples.count / channels) }
        do {
            try samples.withUnsafeBytes { try handle.write(contentsOf: Data($0)) }
        } catch {
            failure = error
        }
    }
}
