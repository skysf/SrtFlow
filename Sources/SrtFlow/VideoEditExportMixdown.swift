import AVFoundation

// MARK: - 成片的声音：离线读出预览那份混音
//
// 2026-09-24 起，剪辑导出的声音**不再由 ffmpeg 另搭一套滤镜链**（以前是每段 atrim → atempo →
// volume / aeval → afade → adelay，主轨 concat / acrossfade，最后 amix）。现在用和预览**同一个**
// `VideoEditCompositionBuilder.build` + `makeAudioMix` 建出合成，`AVAssetReaderAudioMixOutput`
// 把整条混音原样读成一个 raw f32 文件；ffmpeg 只负责编码、和画面合在一起。
//
// 为什么：用户嫌「每个声音功能要在预览、成片各做一遍」效率低，而两份实现迟早分叉 —— 音量、
// 渐变、曲线、推子为了让 ffmpeg 模仿 AVFoundation 攒下了一整套规矩（aeval 平衡树、afade 必须
// 在 atempo 之后、增益必须在 adelay 之前……）。现在成片听到的就是预览听到的那一份。
// 方案与实测：docs/plans/2026-09-24-sound-scenes.md；长期约束：docs/architecture/export-audio-mixdown.md。
//
// 这个文件只管「读出来、写成文件」；滤镜图怎么接这个文件在 VideoEditExportGraph。

enum ExportAudioMixdown {
    /// 和以前导出链末尾的 `aresample=48000,aformat=…stereo` 同一个规格。
    static let sampleRate = 48_000
    static let channels = 2

    /// ffmpeg 读混音文件的输入参数（raw f32le，没有容器头，靠这几个参数说清楚格式）。
    static func inputArguments(_ file: URL) -> [String] {
        ["-f", "f32le", "-ar", String(sampleRate), "-ac", String(channels), "-i", file.path]
    }

    enum Outcome: Equatable {
        /// 写好了，正好是要的长度。
        case written
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
        guard let built = await VideoEditCompositionBuilder.build(from: state),
              let tracks = try? await built.composition.loadTracks(withMediaType: .audio),
              !tracks.isEmpty else { return .silent }
        let frames = max(0, Int((duration * Double(sampleRate)).rounded()))
        // 这几样 AVFoundation 对象都没标 Sendable；交给读取线程之后这边不再碰。
        nonisolated(unsafe) let composition = built.composition
        nonisolated(unsafe) let audioTracks = tracks
        nonisolated(unsafe) let mix = built.audioMix
        let result = await MediaReadQueue.run(on: MediaReadQueue.export) {
            read(composition, tracks: audioTracks, mix: mix, frames: frames, to: file, cancellation: cancellation)
        }
        switch result {
        case .success: return .written
        case .failure(let error): throw error
        }
    }

    /// 阻塞地读完整条混音、边读边写盘。**只在 `MediaReadQueue` 上调**（阻塞读取不许进 Swift
    /// 并发的线程池，见 docs/architecture/blocking-media-reads.md）。
    private static func read(
        _ composition: AVComposition,
        tracks: [AVAssetTrack],
        mix: AVAudioMix?,
        frames: Int,
        to file: URL,
        cancellation: ExportCancellationToken?
    ) -> Result<Void, Error> {
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: composition) } catch { return .failure(error) }
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: outputSettings)
        output.audioMix = mix
        // 变速段的保音调算法和预览的播放条目是同一个（VideoEditCompositionBuilder.timePitchAlgorithm）。
        output.audioTimePitchAlgorithm = VideoEditCompositionBuilder.timePitchAlgorithm
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            return .failure(ReadError(detail: nil))
        }
        reader.add(output)
        reader.timeRange = CMTimeRange(
            start: .zero, duration: CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(sampleRate))
        )
        guard reader.startReading() else {
            return .failure(ReadError(detail: reader.error?.localizedDescription))
        }

        guard FileManager.default.createFile(atPath: file.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: file) else {
            reader.cancelReading()
            return .failure(ReadError(detail: file.lastPathComponent))
        }
        defer { try? handle.close() }
        var sink = FrameSink(handle: handle, limit: frames, channels: channels)

        while sink.written < frames, let buffer = output.copyNextSampleBuffer() {
            if cancellation?.isCancelled == true {
                reader.cancelReading()
                return .failure(CancellationError())
            }
            // 按时间戳落位：中间要是缺了一截（不该有，但不能赌），缺的补静音，不许把后面的声音
            // 往前挪 —— 挪了就是声画不同步。
            let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
            if pts.isValid {
                sink.padSilence(upTo: Int((pts.seconds * Double(sampleRate)).rounded()))
            }
            sink.append(buffer)
        }
        if reader.status == .failed {
            return .failure(ReadError(detail: reader.error?.localizedDescription))
        }
        // 读得比画面短（最后一截没有声音）：补静音补到正好 `frames`。
        sink.padSilence(upTo: frames)
        return sink.failure.map { .failure($0) } ?? .success(())
    }

    /// interleaved f32 立体声 48kHz。
    private static var outputSettings: [String: Any] {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        return [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
            AVNumberOfChannelsKey: channels,
            AVSampleRateKey: sampleRate,
            AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
        ]
    }
}

/// 往 raw 文件里按帧写：记着写到第几帧，超过上限的截掉。
private struct FrameSink {
    let handle: FileHandle
    let limit: Int
    let channels: Int
    private(set) var written = 0
    private(set) var failure: Error?

    init(handle: FileHandle, limit: Int, channels: Int) {
        self.handle = handle
        self.limit = limit
        self.channels = channels
    }

    private var bytesPerFrame: Int { channels * MemoryLayout<Float>.size }

    mutating func padSilence(upTo frame: Int) {
        var missing = min(frame, limit) - written
        let chunk = 48_000
        while missing > 0, failure == nil {
            let count = min(missing, chunk)
            write(Data(count: count * bytesPerFrame), frames: count)
            missing -= count
        }
    }

    mutating func append(_ buffer: CMSampleBuffer) {
        guard let block = CMSampleBufferGetDataBuffer(buffer) else { return }
        let length = CMBlockBufferGetDataLength(block)
        let frames = min(length / bytesPerFrame, limit - written)
        guard frames > 0 else { return }
        var data = Data(count: frames * bytesPerFrame)
        let status = data.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(
                block, atOffset: 0, dataLength: frames * bytesPerFrame, destination: raw.baseAddress!
            )
        }
        guard status == kCMBlockBufferNoErr else { return }
        write(data, frames: frames)
    }

    private mutating func write(_ data: Data, frames: Int) {
        do {
            try handle.write(contentsOf: data)
            written += frames
        } catch {
            failure = error
        }
    }
}
