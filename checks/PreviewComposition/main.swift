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

struct SolidVideoError: Error, CustomStringConvertible {
    let description: String
}

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
    guard writer.startWriting() else {
        throw SolidVideoError(description: "writer 起不来：\(writer.error?.localizedDescription ?? "?")")
    }
    writer.startSession(atSourceTime: .zero)
    guard let pool = adaptor.pixelBufferPool else {
        writer.cancelWriting()
        throw SolidVideoError(description: "拿不到 pixel buffer pool")
    }
    var buffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
    guard let buffer else {
        writer.cancelWriting()
        throw SolidVideoError(description: "拿不到 pixel buffer")
    }
    CVPixelBufferLockBaseAddress(buffer, [])
    if let base = CVPixelBufferGetBaseAddress(buffer) {
        let level = UInt32(min(max(white, 0), 1) * 255)
        let bgra: UInt32 = 0xFF00_0000 | (level << 16) | (level << 8) | level
        let words = base.assumingMemoryBound(to: UInt32.self)
        let count = CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer) / 4
        for index in 0..<count { words[index] = bgra }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    // 和产线 BlackBaseVideoFactory 同一课：isReadyForMoreMediaData 在 writer
    // 异步失败后可能永远为 false，等待必须有状态检查和截止时间，
    // 不然整个自检脚本挂死，连最后的 semaphore.signal() 都到不了。
    let fps = 10.0
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    for frame in 0..<Int(seconds * fps) {
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing, ContinuousClock.now < deadline else {
                writer.cancelWriting()
                throw SolidVideoError(
                    description: "写测试视频卡住或失败：status=\(writer.status.rawValue) "
                        + (writer.error?.localizedDescription ?? "")
                )
            }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        guard adaptor.append(
            buffer,
            withPresentationTime: CMTime(seconds: Double(frame) / fps, preferredTimescale: 600)
        ) else {
            writer.cancelWriting()
            throw SolidVideoError(
                description: "append 失败：\(writer.error?.localizedDescription ?? "?")"
            )
        }
    }
    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else {
        throw SolidVideoError(description: "写测试视频收尾失败：\(writer.error?.localizedDescription ?? "?")")
    }
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

/// 从文件抽帧（预渲染中间片的验收用）。
func frameImage(fromFile url: URL, at seconds: Double) async -> CGImage? {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 15)
    generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 15)
    return try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
}

/// 区域平均 RGBA（0…1，premultiplied）。画中画中间片要验 alpha 通道。
func averageRGBA(_ image: CGImage, region: CGRect) -> (red: Double, alpha: Double) {
    guard let cropped = image.cropping(to: region) else { return (-1, -1) }
    var pixel = [UInt8](repeating: 0, count: 4)
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
              data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          ) else { return (-1, -1) }
    context.interpolationQuality = .medium
    context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    return (Double(pixel[0]) / 255, Double(pixel[3]) / 255)
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

        // A. 不透明度关键帧：1→0 匀减，中点该是半亮（验证斜坡 × 黑底轨）。
        do {
            var state = TimelineState()
            let info = MediaInfo(
                duration: 4, displaySize: CGSize(width: 64, height: 36), frameRate: 10,
                videoCodec: "h264", audioCodec: nil, hasAudio: false,
                audioCanCopyToMP4: false, fileBytes: 1
            )
            var clip = EditClip(sourceURL: white1, sourceDuration: 4, timelineStart: 0, info: info)
            var animation = ClipAnimation()
            animation.opacity.set(1, atSourceTime: 0)
            animation.opacity.set(0, atSourceTime: 4)
            clip.animation = animation
            state.mainClips = [clip]
            if let built = await VideoEditCompositionBuilder.build(from: state) {
                let mid = await averageBrightness(built, at: 2)
                check(mid > 0.35 && mid < 0.65, "不透明度 1→0 动画中点应≈半亮，实测 \(mid)")
                let head = await averageBrightness(built, at: 0.15)
                check(head > 0.85, "不透明度动画开头应接近全亮，实测 \(head)")
            } else {
                check(false, "不透明度动画场景合成失败")
            }
        }

        // B. 缩放关键帧：白块从 0.2 长到满幅，画面平均亮度就是面积占比曲线
        //    （验证 setTransformRamp 的端点取值和切片）。
        do {
            var state = TimelineState()
            let info = MediaInfo(
                duration: 4, displaySize: CGSize(width: 64, height: 36), frameRate: 10,
                videoCodec: "h264", audioCodec: nil, hasAudio: false,
                audioCanCopyToMP4: false, fileBytes: 1
            )
            var clip = EditClip(sourceURL: white1, sourceDuration: 4, timelineStart: 0, info: info)
            var animation = ClipAnimation()
            animation.width.set(0.2, atSourceTime: 0)
            animation.width.set(1.0, atSourceTime: 4)
            animation.height.set(0.2, atSourceTime: 0)
            animation.height.set(1.0, atSourceTime: 4)
            clip.animation = animation
            state.mainClips = [clip]
            if let built = await VideoEditCompositionBuilder.build(from: state) {
                let mid = await averageBrightness(built, at: 2)
                check(mid > 0.26 && mid < 0.46, "缩放动画中点面积占比应≈0.36，实测 \(mid)")
                let tail = await averageBrightness(built, at: 3.9)
                check(tail > 0.85, "缩放动画结尾应近满幅，实测 \(tail)")
            } else {
                check(false, "缩放动画场景合成失败")
            }
        }

        // C. 旋转关键帧要按 ≤6°/片加密（矩阵插值走弦，不加密就是缩水变形）。
        do {
            var state = TimelineState()
            let info = MediaInfo(
                duration: 4, displaySize: CGSize(width: 64, height: 36), frameRate: 10,
                videoCodec: "h264", audioCodec: nil, hasAudio: false,
                audioCanCopyToMP4: false, fileBytes: 1
            )
            var clip = EditClip(sourceURL: white1, sourceDuration: 4, timelineStart: 0, info: info)
            var animation = ClipAnimation()
            animation.rotation.set(0, atSourceTime: 0)
            animation.rotation.set(90, atSourceTime: 4)
            clip.animation = animation
            state.mainClips = [clip]
            if let built = await VideoEditCompositionBuilder.build(from: state) {
                let count = built.videoComposition?.instructions.count ?? 0
                check(count >= 15, "旋转 90° 动画至少切成 15 片（≤6°/片），实测 \(count)")
            } else {
                check(false, "旋转动画场景合成失败")
            }
        }

        // D. 主轨预渲染：动画段渲成黑底 ProRes 422 中间片，抽帧亮度要跟
        //    合成里的面积曲线一致（导出=预览按构造一致的直接验收）。
        do {
            let info = MediaInfo(
                duration: 4, displaySize: CGSize(width: 64, height: 36), frameRate: 10,
                videoCodec: "h264", audioCodec: nil, hasAudio: false,
                audioCanCopyToMP4: false, fileBytes: 1
            )
            var clip = EditClip(sourceURL: white1, sourceDuration: 4, timelineStart: 0, info: info)
            var animation = ClipAnimation()
            animation.width.set(0.2, atSourceTime: 0)
            animation.width.set(1.0, atSourceTime: 4)
            animation.height.set(0.2, atSourceTime: 0)
            animation.height.set(1.0, atSourceTime: 4)
            clip.animation = animation
            let intermediate = try await AnimatedClipPrerenderer.renderMain(
                clip: clip, renderSize: CGSize(width: 64, height: 36), into: root
            )
            if let frame = await frameImage(fromFile: intermediate, at: 2) {
                let probe = averageRGBA(frame, region: CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
                check(probe.red > 0.26 && probe.red < 0.46, "主轨预渲染中点面积占比应≈0.36，实测 \(probe.red)")
            } else {
                check(false, "主轨预渲染中间片抽不出帧")
            }
        }

        // E. 画中画预渲染（fill + matte）：默认合成器出不了透明背景
        //    （backgroundColor 只支持不透明色），所以蒙版单独渲 —— 验证
        //    fill 中心有内容、matte 的白块盖在正确位置（含不透明度烘焙）。
        do {
            let info = MediaInfo(
                duration: 4, displaySize: CGSize(width: 64, height: 36), frameRate: 10,
                videoCodec: "h264", audioCodec: nil, hasAudio: false,
                audioCanCopyToMP4: false, fileBytes: 1
            )
            var pip = EditClip(sourceURL: white1, sourceDuration: 4, timelineStart: 0, info: info)
            pip.placement = ClipPlacement(centerX: 0.5, centerY: 0.5, width: 0.5, height: 0.5)
            pip.opacity = 0.5
            var animation = ClipAnimation()
            animation.centerX.set(0.5, atSourceTime: 0)
            animation.centerX.set(0.5, atSourceTime: 4)
            pip.animation = animation
            let pair = try await AnimatedClipPrerenderer.renderOverlay(
                clip: pip, renderSize: CGSize(width: 64, height: 36), into: root
            )
            if let fillFrame = await frameImage(fromFile: pair.fill, at: 2),
               let matteFrame = await frameImage(fromFile: pair.matte, at: 2) {
                let w = Double(fillFrame.width)
                let h = Double(fillFrame.height)
                let centerRegion = CGRect(x: w * 0.45, y: h * 0.45, width: w * 0.1, height: h * 0.1)
                let cornerRegion = CGRect(x: 0, y: 0, width: max(2, w * 0.08), height: max(2, h * 0.08))
                let fillCenter = averageRGBA(fillFrame, region: centerRegion)
                check(fillCenter.red > 0.85, "fill 中心应全亮（不透明度不许压在 fill 上），实测 \(fillCenter.red)")
                let matteCenter = averageRGBA(matteFrame, region: centerRegion)
                let matteCorner = averageRGBA(matteFrame, region: cornerRegion)
                check(
                    matteCenter.red > 0.4 && matteCenter.red < 0.6,
                    "matte 中心应≈0.5（50% 不透明度烘焙进蒙版），实测 \(matteCenter.red)"
                )
                check(matteCorner.red < 0.08, "matte 角落应是黑（透明区），实测 \(matteCorner.red)")
            } else {
                check(false, "画中画预渲染中间片抽不出帧")
            }
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
