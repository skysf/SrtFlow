import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import SrtFlowCore

// 录屏 writer 的自检：真的喂采样、真的落文件、真的建预览合成、真的量像素。
// 编译方式见 scripts/check-screen-recording-writer.sh。
//
// 守的是「画面轨必须自己盖到 T1」这条硬约束
// （docs/bugfixes/2026-08-11-screen-recording-idle-tail-black.md）：
// SCK 在静止期只发不带像素的 idle 帧，一帧都不写。`endSession` 只延容器时长，
// 画面轨末端会停在最后一次画面变化 —— 这一段在预览里是纯黑。

var failures = 0
var checks = 0

func check(_ condition: Bool, _ message: String, line: Int = #line) {
    checks += 1
    if !condition {
        failures += 1
        print("FAIL [line \(line)] \(message)")
    }
}

let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("srtflow-writercheck-\(UUID().uuidString)", isDirectory: true)
try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
// 顶层 defer 会被结尾的 exit() 绕过（exit 不跑 defer）—— 显式清理。
func cleanUp() { try? FileManager.default.removeItem(at: root) }

let size = CGSize(width: 320, height: 180)
let frameRate = ProjectFrameRate.fps24

/// 造一份纯白画面的采样，PTS 就是**此刻**的 mach 时间。
///
/// 必须按真实时间喂：`movieFragmentInterval` 每秒把已写的采样冲进一个 fragment，
/// 冲出去的采样时长就定死了，`endSession` 再也改不动它 —— 这正是尾帧空洞
/// 出现的条件。几毫秒内喂完 6 秒的假 PTS 会让所有采样落在同一个 fragment 里，
/// 收尾时最后一帧还能被延长，守卫就永远红不了（本次反向验证的教训）。
func makeSample() -> CMSampleBuffer {
    var pixelBuffer: CVPixelBuffer?
    CVPixelBufferCreate(
        nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA,
        [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary,
        &pixelBuffer
    )
    let buffer = pixelBuffer!
    CVPixelBufferLockBaseAddress(buffer, [])
    if let base = CVPixelBufferGetBaseAddress(buffer) {
        let bytes = CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer)
        let words = base.assumingMemoryBound(to: UInt32.self)
        for index in 0..<(bytes / 4) { words[index] = 0xFFFF_FFFF }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])

    var format: CMFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format
    )
    // PTS 用 mach 时基：writer 会减去自己记的 T0（和 SCK 的采样同一个时钟）。
    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: 24),
        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
        decodeTimeStamp: .invalid
    )
    var sample: CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(
        allocator: nil, imageBuffer: buffer, formatDescription: format!,
        sampleTiming: &timing, sampleBufferOut: &sample
    )
    return sample!
}

/// 一包静音（48kHz 立体声 16 位 PCM），PTS 同样取此刻。
///
/// **电脑声音这一路是必需的**：静止期只有它还在写，`movieFragmentInterval`
/// 才会把画面轨那份最后的采样冲进 fragment 定死时长。没有它，收尾时
/// `endSession` 还能把最后一帧延长到 T1，空洞根本不出现（反向验证的教训）。
func makeAudioSample(frames: Int) -> CMSampleBuffer? {
    var asbd = AudioStreamBasicDescription(
        mSampleRate: 48000,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
        mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0
    )
    var format: CMAudioFormatDescription?
    guard CMAudioFormatDescriptionCreate(
        allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
        magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format
    ) == noErr, let format else { return nil }

    let byteCount = frames * 4
    var block: CMBlockBuffer?
    guard CMBlockBufferCreateWithMemoryBlock(
        allocator: nil, memoryBlock: nil, blockLength: byteCount, blockAllocator: nil,
        customBlockSource: nil, offsetToData: 0, dataLength: byteCount,
        flags: 0, blockBufferOut: &block
    ) == noErr, let block else { return nil }
    CMBlockBufferFillDataBytes(
        with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount
    )

    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: 48000),
        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
        decodeTimeStamp: .invalid
    )
    var sampleSize = 4
    var sample: CMSampleBuffer?
    guard CMSampleBufferCreateReady(
        allocator: nil, dataBuffer: block, formatDescription: format,
        sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
        sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sample
    ) == noErr else { return nil }
    return sample
}

/// 平均亮度（0…1）。全黑判据。
func luma(_ image: CGImage) -> Double {
    let width = 32, height = 18
    var buffer = [UInt8](repeating: 0, count: width * height * 4)
    let context = CGContext(
        data: &buffer, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
    )!
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    var sum = 0.0
    for index in stride(from: 0, to: buffer.count, by: 4) {
        sum += (Double(buffer[index + 1]) + Double(buffer[index + 2]) + Double(buffer[index + 3])) / 3
    }
    return sum / Double(width * height) / 255
}

// MARK: - 画面在前 1 秒变化，之后静止 4 秒（idle 期一帧都不写）

let movURL = root.appendingPathComponent("recording.mov")
let writer = try ScreenRecordingWriter(
    movURL: movURL, micURL: nil, pixelSize: size,
    frameRate: frameRate, capturesSystemAudio: true
)
try writer.start()

let frameNanos: UInt64 = 1_000_000_000 / 24
/// 每喂一帧画面就配一包声音 —— 真实录制里电脑声音是一直在的。
///
/// 声音这一路**造不出来就必须让整个检查失败**：它是本场景的必要条件，
/// 静默跳过会退化成「没有第二条轨」那种不出问题的情形，守卫从此永远绿。
func tick(idleFrame: Bool) async throws {
    writer.append(makeSample(), kind: "screen", isIdleFrame: idleFrame)
    guard let audio = makeAudioSample(frames: 2000) else {
        print("FAIL 造不出静音采样 —— 这条守卫必须有电脑声音那一路才成立")
        cleanUp()
        exit(1)
    }
    writer.append(audio, kind: "audio", isIdleFrame: false)
    try await Task.sleep(nanoseconds: frameNanos)
}
// 头 1 秒：24 帧真画面。
for _ in 0..<24 { try await tick(idleFrame: false) }
// 之后 4 秒：画面只剩 idle 帧（SCK 的省带宽机制，不带像素、不写入，
// 但证明还在录），声音照旧。
for _ in 0..<96 { try await tick(idleFrame: true) }
let stopHostTime = CMClockGetTime(CMClockGetHostTimeClock())
let result = await writer.finish(stopHostTime: stopHostTime)

check(result.duration > 4.5, "录制时长应当到 5 秒上下：\(result.duration)")
// 场景前提：静止期真的一帧都没写（否则这条守卫测的根本不是这个 bug）。
check(result.counters.idleFrames > 90, "静止期应当全是 idle 帧：\(result.counters.idleFrames)")
check(
    (result.counters.written["screen"] ?? 0) <= 26,
    "画面只该写头 1 秒那 24 帧（外加最多一帧补的尾帧）：\(result.counters.written["screen"] ?? 0)"
)
// 场景前提：声音全程在写 —— fragment 靠它才会被冲出去。
check(
    (result.counters.written["audio"] ?? 0) >= 100,
    "电脑声音必须全程写入：\(result.counters.written["audio"] ?? 0)"
)
// 收尾没有静默失败（补尾帧失败会被记下来，不再是静默 return）。
check(result.tailFrameFailure == nil, "补尾帧不该失败：\(result.tailFrameFailure ?? "")")
check(!result.isPartial, "这段录制不该被判 partial：\(result.partialReason ?? "")")

let asset = AVURLAsset(url: movURL)
let videoTrack = try await asset.loadTracks(withMediaType: .video).first
check(videoTrack != nil, "产物里应当有画面轨")
let audioTracks = try await asset.loadTracks(withMediaType: .audio)
check(!audioTracks.isEmpty, "产物里必须有音轨 —— 没有它这条守卫红不了")
if let audioTrack = audioTracks.first {
    let audioRange = try await audioTrack.load(.timeRange)
    check(audioRange.duration.seconds > 3, "音轨要覆盖大半段录制：\(audioRange.duration.seconds)")
}
// writer 自己以产物为准报的末端，必须和这里读到的一致。
check(
    result.videoTrackEndSeconds != nil,
    "FinishResult 应当带上产物里画面轨的末端"
)

if let videoTrack {
    let range = try await videoTrack.load(.timeRange)
    let assetDuration = try await asset.load(.duration).seconds
    // 回归守卫①：录制自称 5 秒，画面轨就必须有 5 秒。
    // 修复前实测：画面轨停在 1.48 秒，录制却是 7.47 秒。
    check(
        range.end.seconds >= result.duration - 0.05,
        "画面轨必须盖到录制末端：轨 \(range.end.seconds) vs 录制 \(result.duration)"
    )
    check(
        assetDuration >= result.duration - 0.05,
        "容器时长必须盖到录制末端：容器 \(assetDuration) vs 录制 \(result.duration)"
    )

    // 回归守卫②：再走一遍真实预览路径。时间线拿到的这段有多长，
    // 画面就得有多长 —— 静止期取帧必须还是白的，不能是黑的。
    let clipDuration = max(assetDuration, result.duration)
    var state = TimelineState()
    state.frameRate = frameRate
    state.canvasRatio = .wide16x9
    state.mainClips = [
        EditClip(
            sourceURL: movURL,
            sourceDuration: clipDuration,
            timelineStart: 0,
            info: MediaInfo(
                duration: clipDuration, displaySize: size, frameRate: 24,
                videoCodec: "avc1", audioCodec: "aac", hasAudio: true,
                audioCanCopyToMP4: true, fileBytes: 0
            )
        )
    ]
    if let built = await VideoEditCompositionBuilder.build(from: state) {
        let generator = AVAssetImageGenerator(asset: built.composition)
        generator.videoComposition = built.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        for probe in [0.5, 2.5, 4.5] {
            let time = CMTime(seconds: probe, preferredTimescale: 600)
            if let (image, _) = try? await generator.image(at: time) {
                let value = luma(image)
                check(value > 0.5, "静止期 \(probe)s 预览不该是黑的：亮度 \(value)")
            } else {
                check(false, "\(probe)s 取帧失败")
            }
        }
    } else {
        check(false, "预览合成建不出来")
    }
}

cleanUp()
print("ScreenRecordingWriter checks: \(checks - failures)/\(checks) passed")
exit(failures == 0 ? 0 : 1)
