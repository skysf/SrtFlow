import AVFoundation
import CoreGraphics
import Foundation

// 预览合成（叠化 × Transform）的自检：真的建 AVComposition、真的取帧、
// 真的量像素。编译方式见 scripts/check-preview-composition.sh。
//
// 守的是 docs/architecture/preview-free-transform.md 里的合成模型合同：
// 1. 接缝两侧「盖满画布且不透明」→ 精确「垫底」路径，叠化全程**不许变暗**
//    （仅翻转也算满幅不透明 —— 误走近似路径就是白闪变暗的回归）。
// 2. 有一侧半透明 → 近似「双向淡变」路径：转场开头**不许把后段全亮泄漏**
//    （那是「垫底常亮」模型的错），中点允许记录在案的轻微下凹。

var failures = 0
var checks = 0

func check(_ condition: Bool, _ message: String, line: Int = #line) {
    checks += 1
    if !condition {
        failures += 1
        print("FAIL [line \(line)] \(message)")
    }
}

// MARK: - 纯色测试视频（AVAssetWriter 直接写，不依赖 ffmpeg）

let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("srtflow-previewcheck-\(UUID().uuidString)", isDirectory: true)
try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }

func makeSolidVideo(white: Double, seconds: Double, name: String) async throws -> URL {
    let url = root.appendingPathComponent(name)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: 64,
        AVVideoHeightKey: 36
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64,
            kCVPixelBufferHeightKey as String: 36
        ]
    )
    writer.add(input)
    precondition(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    guard let pool = adaptor.pixelBufferPool else { fatalError("no pixel buffer pool") }
    var buffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
    guard let buffer else { fatalError("no pixel buffer") }
    CVPixelBufferLockBaseAddress(buffer, [])
    if let base = CVPixelBufferGetBaseAddress(buffer) {
        let level = UInt32(min(max(white, 0), 1) * 255)
        let bgra: UInt32 = 0xFF00_0000 | (level << 16) | (level << 8) | level
        let words = base.assumingMemoryBound(to: UInt32.self)
        let count = CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer) / 4
        for index in 0..<count { words[index] = bgra }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    let fps = 10.0
    for frame in 0..<Int(seconds * fps) {
        while !input.isReadyForMoreMediaData { try? await Task.sleep(nanoseconds: 2_000_000) }
        precondition(adaptor.append(
            buffer,
            withPresentationTime: CMTime(seconds: Double(frame) / fps, preferredTimescale: 600)
        ))
    }
    input.markAsFinished()
    await writer.finishWriting()
    precondition(writer.status == .completed, "写测试视频失败")
    return url
}

// MARK: - 取帧量亮度

/// 整幅平均亮度（0…1）。测试画面都是均匀纯色，平均就够了。
func averageBrightness(_ built: VideoEditCompositionBuilder.Built, at seconds: Double) async -> Double {
    let generator = AVAssetImageGenerator(asset: built.composition)
    generator.videoComposition = built.videoComposition
    generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 15)
    generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 15)
    guard let image = try? await generator.image(
        at: CMTime(seconds: seconds, preferredTimescale: 600)
    ).image else { return -1 }

    var pixel = [UInt8](repeating: 0, count: 4)
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
              data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          ) else { return -1 }
    context.interpolationQuality = .medium
    context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    return (Double(pixel[0]) + Double(pixel[1]) + Double(pixel[2])) / 3 / 255
}

// MARK: - 场景搭建

/// 两段 4s 纯白，叠化 1s（重叠 3.0–4.0），可对第一段做改动。
func whiteDissolveState(_ url1: URL, _ url2: URL, mutateFirst: (inout EditClip) -> Void) -> TimelineState {
    let info = MediaInfo(
        duration: 4,
        displaySize: CGSize(width: 64, height: 36),
        frameRate: 10,
        videoCodec: "h264",
        audioCodec: nil,
        hasAudio: false,
        audioCanCopyToMP4: false,
        fileBytes: 1
    )
    var first = EditClip(sourceURL: url1, sourceDuration: 4, timelineStart: 0, info: info)
    first.transitionAfter = .crossFade
    first.transitionDuration = 1
    mutateFirst(&first)
    let second = EditClip(sourceURL: url2, sourceDuration: 4, timelineStart: 3, info: info)
    var state = TimelineState()
    state.mainClips = [first, second]
    return state
}

// MARK: - 用例

let semaphore = DispatchSemaphore(value: 0)
Task {
    do {
        let white1 = try await makeSolidVideo(white: 1, seconds: 4, name: "w1.mp4")
        let white2 = try await makeSolidVideo(white: 1, seconds: 4, name: "w2.mp4")

        // 1. 无任何变换：精确「垫底」路径，中点必须还是全亮（dissolve 不变暗）。
        if let built = await VideoEditCompositionBuilder.build(
            from: whiteDissolveState(white1, white2) { _ in }
        ) {
            let mid = await averageBrightness(built, at: 3.5)
            check(mid > 0.9, "白→白叠化中点不许变暗（精确路径），实测 \(mid)")
        } else {
            check(false, "无变换场景合成失败")
        }

        // 2. 仅水平翻转：仍满幅不透明，必须走精确路径 —— 这是「误用
        //    hasVisualTransform 判定」的直接回归（当时中点会掉到 ~0.75）。
        if let built = await VideoEditCompositionBuilder.build(
            from: whiteDissolveState(white1, white2) { $0.flippedHorizontally = true }
        ) {
            let mid = await averageBrightness(built, at: 3.5)
            check(mid > 0.9, "仅翻转的白→白叠化中点不许变暗，实测 \(mid)")
        } else {
            check(false, "仅翻转场景合成失败")
        }

        // 3. 前段 50% 透明：近似「双向淡变」路径。
        //    转场开头后段必须还黑着（泄漏的话亮度会冲到 ~1.0）；
        //    中点是记录在案的近似（理论 0.625），给宽松区间。
        if let built = await VideoEditCompositionBuilder.build(
            from: whiteDissolveState(white1, white2) { $0.opacity = 0.5 }
        ) {
            let start = await averageBrightness(built, at: 3.05)
            check(
                start > 0.3 && start < 0.75,
                "半透明段叠化开头应≈前段自身亮度（无后段泄漏），实测 \(start)"
            )
            let mid = await averageBrightness(built, at: 3.5)
            check(
                mid > 0.45 && mid < 0.8,
                "半透明段叠化中点应在近似模型区间内，实测 \(mid)"
            )
        } else {
            check(false, "半透明场景合成失败")
        }
    } catch {
        check(false, "自检执行失败：\(error)")
    }
    semaphore.signal()
}
semaphore.wait()

print("\(checks) checks, \(failures) failures")
if failures == 0 { print("All checks passed") }
exit(failures == 0 ? 0 : 1)
