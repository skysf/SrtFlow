import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit
import SrtFlowCore

/// `SCStream` 与 delegate 的桥：把三路 sample buffer 转交给 writer。
///
/// 只做「配置 stream、起停、转发采样」，不碰工程、不做状态机（计划 §4.2）。
@available(macOS 15.0, *)
final class ScreenCaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {

    /// stream 意外停止（显示器拔出、锁屏、系统中断）。
    /// **必须走正常停止链路** —— 直接进 failed 会在清理完成前解锁工程。
    ///
    /// 回调**带上 sessionID**：上一次会话的 engine 迟到的回调不能停掉新会话
    /// （复审二 P1-7）。
    var onStreamStopped: ((UUID, Error) -> Void)?

    /// 本 engine 所属的录制会话。
    let sessionID: UUID

    /// 麦克风通道被降级掉的原因（nil = 正常）。coordinator 据此判 partial。
    private(set) var microphoneDegraded: String?

    private let writer: ScreenRecordingWriter
    private let queue = DispatchQueue(label: "com.srtflow.screenrecording.samples")

    /// `stream` 与 `stopHostTime` 会被三方并发触碰：`start()`（主线程）、
    /// `stop()`（主线程）、`didStopWithError`（SCK 自己的线程）。
    /// `@unchecked Sendable` 只是关掉编译器检查，**不消除数据竞争**
    /// （复审三 P2），所以这里用一把锁真正保护它们。
    private let stateLock = NSLock()
    private var _stream: SCStream?
    private var _stopHostTime: CMTime?

    private var stream: SCStream? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _stream }
        set { stateLock.lock(); _stream = newValue; stateLock.unlock() }
    }

    /// `stopCapture` 那一刻的 host clock，交给 writer 当时长上界。
    var stopHostTime: CMTime? {
        stateLock.lock(); defer { stateLock.unlock() }; return _stopHostTime
    }

    init(writer: ScreenRecordingWriter, sessionID: UUID) {
        self.writer = writer
        self.sessionID = sessionID
    }

    /// 按 request 配置并启动 capture。
    ///
    /// - Parameter filter: 已经处理好控制窗排除的最终 filter
    ///   （整屏/区域来源由 coordinator 重建；单窗口用 picker 原 filter）。
    func start(request: ScreenRecordingRequest, filter: SCContentFilter) async throws {
        let configuration = SCStreamConfiguration()
        // 尺寸是**开录前冻结**的真实像素（已过硬件编码单边 ≤4096 与偶数处理）。
        configuration.width = Int(request.capturePixelSize.width)
        configuration.height = Int(request.capturePixelSize.height)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        // 注意：这是**上限**不是固定帧率 —— idle 帧不出图，产物是变帧率的。
        let duration = request.frameRate.frameDurationRational
        configuration.minimumFrameInterval = CMTime(
            value: duration.value, timescale: duration.timescale
        )
        configuration.showsCursor = request.cursor.showsCursor
        configuration.showMouseClicks = request.cursor.showsClicks
        configuration.queueDepth = 8

        if case .region(_, let rect) = request.source {
            // `sourceRect` 是**相对所在显示器左上角**的点坐标，不是全局 CG 坐标。
            // 区域面板已经用 `ScreenRecordingCoordinateMapper.displayLocalRect`
            // 换算过；早先直接塞全局坐标，主屏碰巧原点为零看不出来，副屏就会
            // 录错区域甚至越界（复审 P1-6）。
            configuration.sourceRect = rect
        }

        configuration.capturesAudio = request.capturesSystemAudio
        // 要录到 SrtFlow 自己播放的声音（Phase 0 门槛 8 实测：false 时峰值 0.088、
        // true 时峰值 0.000，二值化很干净）。
        configuration.excludesCurrentProcessAudio = false

        if let deviceID = request.microphone.deviceID {
            configuration.captureMicrophone = true
            // 必须传**已解析**的 uniqueID（门槛 2）。
            configuration.microphoneCaptureDeviceID = deviceID
        }

        // 先按完整配置试一次；麦克风相关的失败**降级重来，不拖停主录屏**
        // （计划 §1；复审四 P1-2）。失效的设备 ID 会让 `startCapture()` 直接抛错，
        // `addStreamOutput(.microphone)` 同理 —— 两者都不能让整段录制起不来。
        do {
            self.stream = try await makeStream(
                request: request, filter: filter, configuration: configuration
            )
            return
        } catch {
            guard request.microphone.isEnabled else { throw error }
            microphoneDegraded = error.localizedDescription
        }

        configuration.captureMicrophone = false
        configuration.microphoneCaptureDeviceID = nil
        self.stream = try await makeStream(
            request: request, filter: filter, configuration: configuration,
            includeMicrophone: false
        )
    }

    private func makeStream(
        request: ScreenRecordingRequest,
        filter: SCContentFilter,
        configuration: SCStreamConfiguration,
        includeMicrophone: Bool = true
    ) async throws -> SCStream {
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if request.capturesSystemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        }
        if includeMicrophone, request.microphone.isEnabled {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        }
        try await stream.startCapture()
        return stream
    }

    /// 幂等停止。重复调用安全 —— Stop 按钮、Quit、stream error 可能同时触发。
    ///
    /// 返回前会在采样队列上立一道**栅栏**：`stopCapture` 返回不代表回调都跑完了，
    /// 少了这一步，writer 可能一边 `append`、主线程一边 `markAsFinished` /
    /// `finishWriting`（复审 P1-4）。队列是串行的，所以排在最后的一个空块跑完
    /// 就意味着此前所有 sample handler 都已结束。
    /// - Important: 栅栏是**无条件**的。`stream` 已经是 nil 时提前 return 会漏掉
    ///   它 —— 而 `didStopWithError` 正是先把 `stream` 置 nil 再回调的，于是
    ///   显示器拔出/锁屏这类异常停止路径根本不会立栅栏，append 与
    ///   `markAsFinished` 仍可能并发（复审二 P1-7）。
    func stop() async {
        // 取出并置空要在同一次持锁里完成，否则两条停止路径可能都拿到同一个
        // stream 并各自 stopCapture 一次。
        stateLock.lock()
        if _stopHostTime == nil { _stopHostTime = CMClockGetTime(CMClockGetHostTimeClock()) }
        let stream = _stream
        _stream = nil
        stateLock.unlock()

        if let stream {
            try? await stream.stopCapture()
        }
        // 串行队列上排一个空块：它跑完就意味着此前所有 sample handler 都结束了。
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }

    // MARK: SCStreamOutput

    func stream(
        _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        let kind: String
        var isIdle = false
        switch type {
        case .screen:
            kind = "screen"
            // 判据取「状态说 idle」**或**「确实没有像素」——状态读不出来时
            // 不能把一个带像素的真帧当 idle 丢掉。
            isIdle = Self.frameStatus(sampleBuffer) == "idle"
                || CMSampleBufferGetImageBuffer(sampleBuffer) == nil
        case .audio:
            kind = "audio"
        case .microphone:
            kind = "microphone"
        @unknown default:
            return
        }
        writer.append(sampleBuffer, kind: kind, isIdleFrame: isIdle)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // 注意：这里置 nil 之后，coordinator 侧的 `stop()` 仍必须立采样队列栅栏。
        // `stop()` 已改成无条件立栅栏，别再往回改成 `guard let stream else { return }`。
        self.stream = nil
        onStreamStopped?(sessionID, error)
    }

    /// `SCFrameStatus`：`.complete` 与 `.started` 带 image buffer；
    /// `.idle` / `.blank` / `.suspended` / `.stopped` 一律没有像素。
    ///
    /// **`.started` 必须算真帧。** 它是系统定义的「第一帧」，早先与 idle 一起
    /// 丢掉，等于把开头那一帧扔了（复审 P1-4）。
    static func frameStatus(_ sampleBuffer: CMSampleBuffer) -> String {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
            let raw = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: raw) else { return "unknown" }
        return (status == .complete || status == .started) ? "complete" : "idle"
    }
}
