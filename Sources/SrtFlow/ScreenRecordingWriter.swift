import AVFoundation
import CoreMedia
import Foundation
import SrtFlowCore

/// 双 writer：`.mov`（画面 + 电脑声音）与 `.m4a`（麦克风 sidecar）。
///
/// **Phase 0 实测得出的硬约束，全部在这里落实**
/// （证据见 `docs/reports/2026-08-06-native-screen-recording-implementation-report.md`）：
///
/// 1. **必须设 `movieFragmentInterval`。** 不设的话 `moov` 只在 `finishWriting`
///    时写出，崩溃/强杀/磁盘满会让**整个文件打不开**（实测 -11829），不是丢尾部
///    而是全丢。设了才有 partial 可恢复（门槛 12/13）。
/// 2. **音频绝不在 `isReadyForMoreMediaData` 为假时丢弃。** 丢了 m4a 会把空隙
///    折叠掉，产物看着起点正常、内容整体提前。改成有界 backlog；溢出才显式
///    判 partial（门槛 3）。画面掉帧可接受但要计数。
/// 3. **三路 PTS 共享 mach 时基，但 timescale 不同**（mic 48000、另两路 1e9），
///    比较/相减前必须 `CMTimeConvertScale`（门槛 2）。
/// 4. **按共享 PTS 对齐，不做任何固定偏移。** 声学测得的 69 ms 含扬声器/声程/
///    输入缓冲等环境成分，是本机观测值，不得写死（门槛 3 结论订正）。
/// 5. **共同 T0 / 共同 T1**：第一个到达采样定 T0，三路统一减 T0；收尾时两个
///    writer `endSession` 到同一个 T1（门槛 11）。
/// 6. **`idle` 帧不带 image buffer**，占比可达 45–62%，不能计作掉帧（门槛 11）。
/// 7. **画面轨必须自己盖到 T1**（`holdLastFrame`）。`endSession` 只延**容器**
///    时长；静止期一帧都不写，画面轨末端会停在最后一次画面变化。播放器把
///    最后一帧冻住，看不出问题，但进时间线后 `insertTimeRange` 只能取到画面轨
///    真实存在的那段，剩下的全是**纯黑**
///    （docs/bugfixes/2026-08-11-screen-recording-idle-tail-black.md）。
///    门槛 11 当年只验了容器时长，结论「不需要补尾帧」是错的。
@available(macOS 15.0, *)
final class ScreenRecordingWriter: @unchecked Sendable {

    struct Counters {
        var arrived: [String: Int] = [:]
        var written: [String: Int] = [:]
        var droppedBeforeT0: [String: Int] = [:]
        var videoBackpressureDrops = 0
        var audioOverflowDrops = 0
        var idleFrames = 0
        /// PTS 没有严格前进的采样（重复或倒退）。AVAssetWriter 对这类输入会直接
        /// 判 failed，丢掉整段尾巴，所以在入口就挡下来并计数（复审 P1-4）。
        var nonMonotonicDrops: [String: Int] = [:]
        /// 停止栅栏之后仍然到达的采样。正常是 0；不是 0 说明栅栏漏了。
        var afterFinishDrops = 0
        /// 音频溢出即残缺 —— 必须显式告诉用户，不能当成功。
        var isPartial: Bool { audioOverflowDrops > 0 }
    }

    enum WriterError: Error, LocalizedError, Equatable {
        case diskFull
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .diskFull: return L10n("The disk ran out of space while recording.")
            case .failed(let message): return message
            }
        }
    }

    private let movURL: URL
    private let micURL: URL?
    private let movWriter: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let systemAudioInput: AVAssetWriterInput?
    /// 麦克风是**可选通道**：它失败时置 nil，主会话继续（复审三 P1-4）。
    private var micWriter: AVAssetWriter?
    private var micInput: AVAssetWriterInput?
    /// 麦克风通道被关掉的原因（nil = 正常）。与致命的 `failure` 分开记。
    private var microphoneFailure: String?

    /// 共同零点。第一个到达的采样定它，三路共用。
    private var t0: CMTime?
    /// 每一路**最后成功写入**的相对 PTS —— 单调性判据。
    private var lastWritten: [String: CMTime] = [:]
    /// 每一路**第一份成功写入**的采样起点。
    ///
    /// 没有它就只能验末端：开头缺十秒、后面一直正常的录制会被判成功
    /// （复审四 P1-6）。
    private var firstAppended: [String: CMTime] = [:]
    /// 每一路**最后一份成功写入**采样的**结束**时刻（PTS + duration）。
    ///
    /// 用结束而不是起点：一份采样覆盖的是一个区间，拿起点当末端会少算一帧。
    private var lastAppendedEnd: [String: CMTime] = [:]
    /// 所有采样（**含 idle 帧**）观察到的最大相对时刻。
    ///
    /// idle 帧不带像素、不写入，但它证明「录制仍在继续」。不计它的话，
    /// 「静止画面 + 关闭电脑声音」录 30 秒会得到 0 秒或只到最后一次画面变化的
    /// 文件（复审 P1-4）。
    private var observedEnd: CMTime = .zero
    /// 最后一份**写进去**的画面（以及它的格式）。收尾补尾帧要用（硬约束 7）。
    private var lastVideoImage: CVImageBuffer?
    private var lastVideoFormat: CMFormatDescription?
    /// 一帧的时长。补尾帧的 PTS 兜底和「差不到一帧就不算洞」的容差都按它算。
    private let frameDuration: CMTime
    /// 进入收尾后拒收新采样 —— 与 engine 的队列栅栏共同保证
    /// 「append 与 markAsFinished 不并发」。
    private var isFinishing = false
    private(set) var counters = Counters()
    private var backlog: [String: [CMSampleBuffer]] = [:]
    private var failure: WriterError?
    private let lock = NSLock()

    /// backlog 上限：约 12 秒的音频包。超了就是真的跟不上，显式判 partial。
    private static let maxBacklog = 600
    /// 收尾排空的总墙钟上限（两路共享）。宁可判 partial 也不能让退出看起来卡死。
    private static let drainDeadlineSeconds: TimeInterval = 3

    init(
        movURL: URL,
        micURL: URL?,
        pixelSize: CGSize,
        frameRate: ProjectFrameRate,
        capturesSystemAudio: Bool
    ) throws {
        self.movURL = movURL
        self.micURL = micURL
        let rational = frameRate.frameDurationRational
        self.frameDuration = CMTime(value: rational.value, timescale: rational.timescale)
        try? FileManager.default.removeItem(at: movURL)
        if let micURL { try? FileManager.default.removeItem(at: micURL) }

        movWriter = try AVAssetWriter(outputURL: movURL, fileType: .mov)
        // 硬约束 1 —— 数据安全的必要条件，不是优化项。
        movWriter.movieFragmentInterval = CMTime(value: 1, timescale: 1)

        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(pixelSize.width),
            AVVideoHeightKey: Int(pixelSize.height),
            AVVideoCompressionPropertiesKey: [
                // 关键帧间隔约 1 秒：兼顾文字清晰度与进编辑器后的 seek（计划 §7.1）。
                AVVideoMaxKeyFrameIntervalDurationKey: 1.0,
                AVVideoAllowFrameReorderingKey: false,
            ],
        ])
        videoInput.expectsMediaDataInRealTime = true
        movWriter.add(videoInput)

        if capturesSystemAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000,
            ])
            input.expectsMediaDataInRealTime = true
            movWriter.add(input)
            systemAudioInput = input
        } else {
            systemAudioInput = nil
        }

        // 麦克风 writer 的构造**不能用 `try`** —— 它抛错会让整个 writer 初始化
        // 失败，一个可选通道拖停主录屏（复审四 P1-2）。构造不出来就降级。
        if let micURL, let writer = try? AVAssetWriter(outputURL: micURL, fileType: .m4a) {
            writer.movieFragmentInterval = CMTime(value: 1, timescale: 1)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 128_000,
            ])
            input.expectsMediaDataInRealTime = true
            writer.add(input)
            micWriter = writer
            micInput = input
        } else {
            micWriter = nil
            micInput = nil
            if micURL != nil {
                microphoneFailure = "microphone writer could not be created"
            }
        }
    }

    /// 起两个 writer。
    ///
    /// **麦克风是可选的，它的失败不能拖停主录屏**（计划 §1：mic 权限/设备/
    /// writer 失败时画面与电脑声音照常继续）。早先 mic `startWriting()` 失败
    /// 会让整个 `start()` 抛错，主录制根本起不来（复审三 P1-4）。
    func start() throws {
        guard movWriter.startWriting() else {
            // 主 writer 失败才是致命的。
            throw WriterError.failed(movWriter.error?.localizedDescription ?? "startWriting failed")
        }
        movWriter.startSession(atSourceTime: .zero)

        guard let micWriter else { return }
        if micWriter.startWriting() {
            micWriter.startSession(atSourceTime: .zero)
        } else {
            disableMicrophone(
                reason: micWriter.error?.localizedDescription ?? "mic startWriting failed"
            )
        }
    }

    /// 关掉麦克风通道，主会话继续。
    ///
    /// 之后到达的 microphone 采样直接丢弃（不再进 backlog、不影响其他两路），
    /// 收尾时按 partial 如实告知。
    private func disableMicrophone(reason: String) {
        lock.lock()
        microphoneFailure = reason
        micWriter?.cancelWriting()
        micWriter = nil
        micInput = nil
        backlog["microphone"] = nil
        lock.unlock()
        if let micURL { try? FileManager.default.removeItem(at: micURL) }
    }

    // MARK: 收样

    /// - Parameter kind: "screen" / "audio" / "microphone"
    func append(_ sampleBuffer: CMSampleBuffer, kind: String, isIdleFrame: Bool) {
        guard CMSampleBufferIsValid(sampleBuffer) else { return }
        lock.lock()
        if isFinishing {
            counters.afterFinishDrops += 1
            lock.unlock()
            return
        }
        if failure != nil { lock.unlock(); return }
        counters.arrived[kind, default: 0] += 1
        // idle 帧没有像素，是 SCK 的省带宽机制，**不是掉帧**。
        if isIdleFrame { counters.idleFrames += 1 }
        lock.unlock()

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid else { return }
        // 三路 timescale 不同（mic 48000 / 另两路 1e9），统一到纳秒再比较。
        let ptsNanos = CMTimeConvertScale(pts, timescale: 1_000_000_000, method: .default)

        lock.lock()
        if t0 == nil { t0 = ptsNanos }
        let base = t0!
        lock.unlock()

        let relative = CMTimeSubtract(ptsNanos, base)
        guard relative >= .zero else {
            lock.lock(); counters.droppedBeforeT0[kind, default: 0] += 1; lock.unlock()
            return
        }

        // 时长上界要含 idle 帧（见 `observedEnd`）。
        lock.lock()
        if relative > observedEnd { observedEnd = relative }
        // 严格单调：重复或倒退的 PTS 会让 writer 直接 failed。
        let isMonotonic = lastWritten[kind].map { relative > $0 } ?? true
        if !isIdleFrame, !isMonotonic { counters.nonMonotonicDrops[kind, default: 0] += 1 }
        lock.unlock()

        guard !isIdleFrame, isMonotonic else { return }

        switch kind {
        case "screen":
            appendVideo(sampleBuffer, at: relative)
        case "audio":
            guard let systemAudioInput else { return }
            enqueueAudio(sampleBuffer, at: relative, kind: kind, input: systemAudioInput)
        case "microphone":
            guard let micInput else { return }
            enqueueAudio(sampleBuffer, at: relative, kind: kind, input: micInput)
        default:
            return
        }
        // **这里不记 lastWritten。** enqueue 只代表「进了排队」，不代表写成功；
        // 真正的记录点在 `noteAppended`，由 append 成功之后调用（复审四 P1-6）。
    }

    /// 一份采样**确实被 writer 接收**之后调用。
    private func noteAppended(kind: String, at time: CMTime, duration: CMTime) {
        lock.lock()
        counters.written[kind, default: 0] += 1
        lastWritten[kind] = time
        if firstAppended[kind] == nil { firstAppended[kind] = time }
        let end = duration.isValid && duration > .zero ? CMTimeAdd(time, duration) : time
        if let previous = lastAppendedEnd[kind] {
            if end > previous { lastAppendedEnd[kind] = end }
        } else {
            lastAppendedEnd[kind] = end
        }
        lock.unlock()
    }

    private func appendVideo(_ sampleBuffer: CMSampleBuffer, at time: CMTime) {
        guard let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        guard videoInput.isReadyForMoreMediaData else {
            // 画面掉帧可接受（录屏本就按需出帧），但必须计数、不假装没发生。
            lock.lock(); counters.videoBackpressureDrops += 1; lock.unlock()
            return
        }
        var format: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: nil, imageBuffer: image, formatDescriptionOut: &format
        )
        guard let format else { return }
        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sampleBuffer),
            presentationTimeStamp: time,
            decodeTimeStamp: .invalid
        )
        var retimed: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: image, formatDescription: format,
            sampleTiming: &timing, sampleBufferOut: &retimed
        )
        guard let retimed, videoInput.append(retimed) else {
            checkWriterFailure(kind: "screen")
            return
        }
        // 收尾补尾帧要拿它再写一份（硬约束 7）。留的是 image buffer 本身，
        // 一份的开销就是一块 IOSurface。
        lock.lock()
        lastVideoImage = image
        lastVideoFormat = format
        lock.unlock()
        noteAppended(kind: "screen", at: time, duration: CMSampleBufferGetDuration(sampleBuffer))
    }

    /// 音频入队再排空 —— **绝不直接丢**（硬约束 2）。
    private func enqueueAudio(
        _ sampleBuffer: CMSampleBuffer, at time: CMTime, kind: String, input: AVAssetWriterInput
    ) {
        guard let retimed = Self.retimed(sampleBuffer, to: time) else { return }
        lock.lock()
        backlog[kind, default: []].append(retimed)
        if backlog[kind]!.count > Self.maxBacklog {
            backlog[kind]!.removeFirst()
            counters.audioOverflowDrops += 1   // 显式记录 → 结果判 partial
        }
        lock.unlock()
        drain(kind: kind, input: input)
    }

    private func drain(kind: String, input: AVAssetWriterInput) {
        while true {
            lock.lock()
            guard input.isReadyForMoreMediaData, let next = backlog[kind]?.first else {
                lock.unlock(); return
            }
            backlog[kind]!.removeFirst()
            lock.unlock()
            if input.append(next) {
                noteAppended(
                    kind: kind,
                    at: CMSampleBufferGetPresentationTimeStamp(next),
                    duration: CMSampleBufferGetDuration(next)
                )
            } else {
                checkWriterFailure(kind: kind)
                return
            }
        }
    }

    private static func retimed(_ sampleBuffer: CMSampleBuffer, to pts: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sampleBuffer),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var out: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: nil, sampleBuffer: sampleBuffer, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleBufferOut: &out
        )
        return status == noErr ? out : nil
    }

    /// ENOSPC 的识别特征（Phase 0 门槛 12 实测）：`AVFoundationErrorDomain -11807`
    /// "Disk Full"，底层 `NSPOSIXErrorDomain 28`。**两条检测路径都要查** ——
    /// 设了 fragment 时 `append` 先返回 false，没设时 `status` 先变 failed。
    /// - Parameter kind: 哪一路的 append 失败了。
    ///   **麦克风的失败绝不能写进共用的 `failure`** —— 那会让后续所有画面和
    ///   系统声音也被 `append` 入口拒收，一个可选通道拖停整段录制（复审三 P1-4）。
    private func checkWriterFailure(kind: String) {
        if kind == "microphone" {
            lock.lock()
            let alreadyDown = micWriter == nil
            let status = micWriter?.status
            let message = micWriter?.error?.localizedDescription
            lock.unlock()
            guard !alreadyDown, status == .failed else { return }
            disableMicrophone(reason: message ?? "microphone writer failed")
            return
        }

        lock.lock(); defer { lock.unlock() }
        guard failure == nil, movWriter.status == .failed else { return }
        let error = movWriter.error as NSError?
        let underlying = error?.userInfo[NSUnderlyingErrorKey] as? NSError
        if error?.code == -11807 || underlying?.code == 28 {
            failure = .diskFull
        } else {
            failure = .failed(error?.localizedDescription ?? "writer failed")
        }
    }

    var currentFailure: WriterError? {
        lock.lock(); defer { lock.unlock() }
        return failure
    }

    /// 音频 backlog 已经溢出过。计划要求这时**立刻停止**而不是继续录一段
    /// 注定残缺的内容 —— 早先只累计计数，录制会一路跑到用户手动 Stop
    /// （复审二 P1-8）。
    var hasAudioOverflow: Bool {
        lock.lock(); defer { lock.unlock() }
        return counters.audioOverflowDrops > 0
    }

    var elapsed: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return max(0, CMTimeGetSeconds(observedEnd))
    }

    // MARK: 收尾

    struct FinishResult {
        var duration: Double
        var counters: Counters
        var isPartial: Bool
        var partialReason: String?
        /// 每一路**第一份成功写入**采样的起点（秒）。
        var firstAppendedSeconds: [String: Double] = [:]
        /// 每一路**最后一份成功写入**采样的**结束**时刻（秒）。
        ///
        /// 验收音频是否覆盖整段录制要用这一对区间端点 —— 只看「容器里有没有
        /// 音轨/时长是否大于零」，一个包就断线也能通过（复审三 P1-5）；
        /// 只看末端，则开头缺一截也能通过（复审四 P1-6）。
        var lastAppendedEndSeconds: [String: Double] = [:]
        /// 麦克风通道中途被关掉的原因（nil = 正常）。
        var microphoneFailure: String?
        /// **产物里画面轨真实的末端**（秒），读的是写完的文件，不是内部账。
        ///
        /// 验收画面覆盖只能以它为准：内部账记的是「我以为写进去了多少」，
        /// 而这一条是「文件里到底有多少」（外部真值，见录屏地基复审）。
        /// 读不出来时为 nil。
        var videoTrackEndSeconds: Double?
        /// 补尾帧没成功的原因（nil = 没失败或压根不需要补）。诊断用；
        /// 判 partial 以 `videoTrackEndSeconds` 为准，不拿它当判据 ——
        /// 补帧失败但 writer 自己把时长兜住了的情况不该误报。
        var tailFrameFailure: String?
    }

    /// 冲干净 backlog → 共同 T1 → finalize。
    ///
    /// **必须先冲 backlog**：排队里的音频还没写，直接 markAsFinished 会丢尾部。
    ///
    /// - Parameter stopHostTime: engine 在 `stopCapture` 那一刻读到的 host clock。
    ///   三路 PTS 与 host clock 共享 mach 时基（Phase 0 门槛 2 实测：同步时钟读数
    ///   与 host clock 完全一致），所以它可以直接换算成相对时刻，作为时长下界。
    ///   **不能只用最后一个采样当 T1**：静止画面下最后一个带像素的帧可能停在
    ///   很早的时刻（复审 P1-4）。传 `nil` 时退化为「观察到的最大时刻」。
    func finish(stopHostTime: CMTime?) async -> FinishResult {
        // 先立栅栏：之后到达的采样一律拒收并计数。
        lock.lock(); isFinishing = true; lock.unlock()

        // 排空用**共享的墙钟 deadline**，不是每路各自计次。
        // 每路 20000 次 × 2ms 最坏是 40 秒，两路就是 80 秒 —— 磁盘满或 writer
        // 已 failed 时，用户看到的就是「退出卡死」（复审三 P2）。
        let deadline = Date().addingTimeInterval(Self.drainDeadlineSeconds)
        var unflushed = 0
        for (kind, input) in [("audio", systemAudioInput), ("microphone", micInput)] {
            guard let input else { continue }
            while true {
                lock.lock()
                let remaining = backlog[kind]?.count ?? 0
                let dead = failure != nil
                lock.unlock()
                // 已经失败就别再等了：后面的 append 只会继续失败。
                if remaining == 0 || dead || Date() >= deadline { break }
                drain(kind: kind, input: input)
                lock.lock(); let after = backlog[kind]?.count ?? 0; lock.unlock()
                if after == remaining { try? await Task.sleep(nanoseconds: 2_000_000) }
            }
            // 退出时 backlog 里还剩东西 = 尾部音频没写进去。
            // **必须计入 partial**，不能当成功收尾（复审二 P1-8）。
            lock.lock(); unflushed += backlog[kind]?.count ?? 0; lock.unlock()
        }

        lock.lock()
        var t1 = observedEnd
        if let stopHostTime, let base = t0, stopHostTime.isValid {
            let stopNanos = CMTimeConvertScale(
                stopHostTime, timescale: 1_000_000_000, method: .default
            )
            let stopRelative = CMTimeSubtract(stopNanos, base)
            // 取上界：stop 时刻应当晚于任何采样；异常时不让它把时长缩短。
            if stopRelative > t1 { t1 = stopRelative }
        }
        lock.unlock()

        // 画面轨要自己盖到 T1（硬约束 7）—— 必须在 markAsFinished 之前。
        let tailFrameFailure = await holdLastFrame(untilT1: t1)

        lock.lock()
        let counters = self.counters
        let failure = self.failure
        let microphoneFailure = self.microphoneFailure
        let firstAppendedSeconds = firstAppended.mapValues { CMTimeGetSeconds($0) }
        let lastAppendedEndSeconds = lastAppendedEnd.mapValues { CMTimeGetSeconds($0) }
        lock.unlock()

        videoInput.markAsFinished()
        systemAudioInput?.markAsFinished()
        micInput?.markAsFinished()
        // 共同 T1：两个 writer 收到同一时刻，尾部长度才一致。
        movWriter.endSession(atSourceTime: t1)
        micWriter?.endSession(atSourceTime: t1)
        await movWriter.finishWriting()
        if let micWriter { await micWriter.finishWriting() }

        // **以产物为准**验一遍画面覆盖：内部账只能说明「我以为写进去了多少」。
        // 补尾帧失败（编码器不收、造不出采样）之后 writer 照样可能是 .completed，
        // 光看容器时长和音频覆盖，短画面轨会被当成功提交、黑尾再来一次。
        let videoTrackEnd = await Self.videoTrackEndSeconds(of: movURL)
        let expected = CMTimeGetSeconds(t1)
        let halfFrame = CMTimeGetSeconds(frameDuration) / 2
        let videoCoversRecording = videoTrackEnd.map { $0 >= expected - halfFrame } ?? false

        var partialReason: String?
        if failure == .diskFull {
            partialReason = L10n("The disk ran out of space, so the recording is incomplete.")
        } else if unflushed > 0 {
            partialReason = L10n("The end of the audio couldn’t be written in time, so the recording is incomplete.")
        } else if counters.audioOverflowDrops > 0 {
            partialReason = L10n("Some audio could not be written in time, so the recording is incomplete.")
        } else if movWriter.status != .completed {
            partialReason = movWriter.error?.localizedDescription
                ?? L10n("The recording could not be finished.")
        } else if !videoCoversRecording {
            // 画面轨没盖满 = 尾部在编辑器里是黑的。必须说，不能静默提交。
            partialReason = L10n("The end of the recording has no picture, so the recording is incomplete.")
        } else if let micWriter, micWriter.status != .completed {
            // 麦克风 writer 失败以前会被当成功 —— 用户以为录到了旁白（复审 P1-4）。
            partialReason = L10n("The microphone track could not be finished, so only the screen was recorded.")
        } else if microphoneFailure != nil {
            // 麦克风通道中途被关掉：主录制是完好的，但要如实说少了旁白。
            partialReason = L10n("The microphone stopped working, so only the screen and computer audio were recorded.")
        }

        return FinishResult(
            duration: CMTimeGetSeconds(t1),
            counters: counters,
            isPartial: partialReason != nil,
            partialReason: partialReason,
            firstAppendedSeconds: firstAppendedSeconds,
            lastAppendedEndSeconds: lastAppendedEndSeconds,
            microphoneFailure: microphoneFailure,
            videoTrackEndSeconds: videoTrackEnd,
            tailFrameFailure: tailFrameFailure
        )
    }

    /// 写完的文件里画面轨真实的末端（秒）。读不出来返回 nil。
    private static func videoTrackEndSeconds(of url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let range = try? await track.load(.timeRange) else { return nil }
        let end = CMTimeGetSeconds(range.end)
        return end.isFinite ? end : nil
    }

    /// 把最后一帧再写一份，让**画面轨自己**覆盖到 T1（硬约束 7）。
    ///
    /// `endSession(atSourceTime:)` 只延容器时长，画面轨的末端仍停在最后一次
    /// 画面变化 —— 静止期 SCK 只发不带像素的 idle 帧，一帧都不会写。
    /// 播放器会把最后一帧冻在屏幕上，所以单看文件察觉不到；但
    /// `AVMutableCompositionTrack.insertTimeRange` 只能取到画面轨真实存在的那段，
    /// 超出的部分在预览/导出里就是**纯黑**
    ///（docs/bugfixes/2026-08-11-screen-recording-idle-tail-black.md）。
    /// - Returns: 补尾帧失败的原因；不需要补或补成功了返回 nil。
    ///   **每一条提前退出都要带原因**：静默 return 会让短画面轨照常提交，
    ///   黑尾原样再来一次（复审 P1）。
    private func holdLastFrame(untilT1 t1: CMTime) async -> String? {
        lock.lock()
        let end = lastAppendedEnd["screen"]
        let lastPTS = lastWritten["screen"]
        let image = lastVideoImage
        let format = lastVideoFormat
        let alreadyFailed = failure != nil
        lock.unlock()

        if alreadyFailed { return "writer already failed" }
        // 一帧都没写过就没得补：画面轨本来就是空的，这本身就是要如实报的状态。
        guard let image, let format, let end, let lastPTS else {
            return "no video frame was ever written"
        }
        // 差不到半帧就不是洞，别为了凑整多写一帧。
        let half = CMTimeMultiplyByFloat64(frameDuration, multiplier: 0.5)
        guard CMTimeCompare(CMTimeAdd(end, half), t1) < 0 else { return nil }

        // PTS 必须**严格**大于上一份，否则 writer 直接判 failed（同 append 入口）。
        var pts = end
        if CMTimeCompare(pts, lastPTS) <= 0 { pts = CMTimeAdd(lastPTS, frameDuration) }
        guard CMTimeCompare(pts, t1) < 0 else { return "no room before T1" }
        let duration = CMTimeSubtract(t1, pts)

        var timing = CMSampleTimingInfo(
            duration: duration, presentationTimeStamp: pts, decodeTimeStamp: .invalid
        )
        var tail: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: image, formatDescription: format,
            sampleTiming: &timing, sampleBufferOut: &tail
        )
        guard let tail else { return "could not build the tail sample" }

        // 实时编码器可能一时不收；有界等待，宁可少一帧也不能让退出卡住
        //（同 BlackBaseVideoFactory 的教训：isReadyForMoreMediaData 可能永不恢复）。
        var waited: UInt64 = 0
        while !videoInput.isReadyForMoreMediaData {
            guard movWriter.status == .writing, waited < 1_000_000_000 else {
                return "the encoder never became ready for the tail frame"
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
            waited += 5_000_000
        }
        guard videoInput.append(tail) else {
            checkWriterFailure(kind: "screen")
            return movWriter.error?.localizedDescription ?? "the tail frame was rejected"
        }
        noteAppended(kind: "screen", at: pts, duration: duration)
        return nil
    }

    /// 倒计时期间取消：作废两个 writer，删掉空临时文件。
    func cancel() {
        movWriter.cancelWriting()
        micWriter?.cancelWriting()
        try? FileManager.default.removeItem(at: movURL)
        if let micURL { try? FileManager.default.removeItem(at: micURL) }
    }
}
