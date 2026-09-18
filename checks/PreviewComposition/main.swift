import AVFoundation
import CoreGraphics
import Foundation
import SrtFlowCore

// 自检里所有 clip 都是 speed=1；用 30fps 半帧＝迁移前写死的 1/60，行为不变。
let kfTol = KeyframeTrack.sourceTolerance(frameRate: .fps30, speed: 1)

// 预览合成（叠化 × Transform）的自检：真的建 AVComposition、真的取帧、
// 真的量像素。编译方式见 scripts/check-preview-composition.sh。
//
// 守的是 docs/architecture/preview-free-transform.md 里的合成模型合同：
// 1. 接缝两侧「盖满画布且不透明」→ 精确「垫底」路径，叠化全程**不许变暗**
//    （仅翻转也算满幅不透明 —— 误走近似路径就是白闪变暗的回归）。
// 2. 有一侧半透明 → 近似「双向淡变」路径：转场开头**不许把后段全亮泄漏**
//    （那是「垫底常亮」模型的错），中点允许记录在案的轻微下凹。
// 3. 推移族：平移斜坡，方向要跟 xfade slide 的实测语义一致（pushLeft 的
//    进场段从右边滑进来）；滑动的是**压平后的整幅**（两色探针分辨得出
//    「滑进来的是另半边」）。条件不满足（如任意角旋转）回退双向淡变。
// 4. 擦除族：出场段挂线性缩小的裁切窗口，方向同 xfade wipe 实测语义；
//    两色探针要能证明露出的是**出场段窗口外的进场段**，而不是滑动。

var failures = 0
var checks = 0

func checkEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String, line: Int = #line) {
    check(actual == expected, "\(message): got \(actual), expected \(expected)", line: line)
}

/// 浮点比较：摆放框的归一化值都要量到亚像素，别用 == 也别抄一份 abs()。
func checkClose(_ actual: Double, _ expected: Double, _ tolerance: Double,
                _ message: String, line: Int = #line) {
    check(abs(actual - expected) <= tolerance,
          "\(message)：got \(actual), expected \(expected)±\(tolerance)", line: line)
}

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
// 顶层 defer 会被结尾的 exit() 绕过（exit 不跑 defer）——
// 实测这个检查攒了 52 个 srtflow-previewcheck-* 临时目录。显式清理。

struct SolidVideoError: Error, CustomStringConvertible {
    let description: String
}

func makeSolidVideo(
    white: Double, seconds: Double, name: String, size: CGSize = CGSize(width: 64, height: 36)
) async throws -> URL {
    try await makeVideo(seconds: seconds, name: name, size: size) { _, _ in white }
}

/// 左半白右半黑的两色素材：分辨「擦除露出自己窗口外的进场段」和
/// 「推移把画面另半边滑进来」的关键探针（纯色素材下两者长得一样）。
func makeHalfToneVideo(
    seconds: Double, name: String, size: CGSize = CGSize(width: 64, height: 36)
) async throws -> URL {
    try await makeVideo(seconds: seconds, name: name, size: size) { column, width in
        column < width / 2 ? 1 : 0
    }
}

func makeVideo(
    seconds: Double, name: String, size: CGSize,
    brightness: (_ column: Int, _ width: Int) -> Double
) async throws -> URL {
    let url = root.appendingPathComponent(name)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: Int(size.width),
        AVVideoHeightKey: Int(size.height)
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height)
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
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let width = CVPixelBufferGetWidth(buffer)
        for row in 0..<CVPixelBufferGetHeight(buffer) {
            let words = (base + row * bytesPerRow).assumingMemoryBound(to: UInt32.self)
            for column in 0..<width {
                let level = UInt32(min(max(brightness(column, width), 0), 1) * 255)
                words[column] = 0xFF00_0000 | (level << 16) | (level << 8) | level
            }
        }
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

/// 归一化区域（左上原点，0…1）的平均亮度。推移/擦除的方向要分区量。
func regionBrightness(
    _ built: VideoEditCompositionBuilder.Built, at seconds: Double, region: CGRect
) async -> Double {
    let generator = AVAssetImageGenerator(asset: built.composition)
    generator.videoComposition = built.videoComposition
    generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 15)
    generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 15)
    guard let image = try? await generator.image(
        at: CMTime(seconds: seconds, preferredTimescale: 600)
    ).image else { return -1 }
    let pixelRegion = CGRect(
        x: region.minX * Double(image.width),
        y: region.minY * Double(image.height),
        width: region.width * Double(image.width),
        height: region.height * Double(image.height)
    )
    return averageRGBA(image, region: pixelRegion).red
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

/// 两段 4s，任意转场 1s（重叠 3.0–4.0），可对第一段做改动。
func seamState(
    _ url1: URL, _ url2: URL, kind: ClipTransition,
    mutateFirst: (inout EditClip) -> Void = { _ in }
) -> TimelineState {
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
    first.transitionAfter = kind
    first.transitionDuration = 1
    mutateFirst(&first)
    let second = EditClip(sourceURL: url2, sourceDuration: 4, timelineStart: 3, info: info)
    var state = TimelineState()
    state.mainClips = [first, second]
    return state
}

/// 两段 4s 纯白，叠化 1s（重叠 3.0–4.0），可对第一段做改动。
func whiteDissolveState(_ url1: URL, _ url2: URL, mutateFirst: (inout EditClip) -> Void) -> TimelineState {
    seamState(url1, url2, kind: .crossFade, mutateFirst: mutateFirst)
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

        // 3. 主轨数组乱序（磁吸关掉拖动过的时间线）：A/B 轨插入必须按时间
        //    顺序，否则 `insertTimeRange` 会把同槽已插好的段往后挤 ——
        //    回归现象是排在数组前面、时间靠后的段所在的时刻一片黑。
        do {
            let info = MediaInfo(
                duration: 4, displaySize: CGSize(width: 64, height: 36), frameRate: 10,
                videoCodec: "h264", audioCodec: nil, hasAudio: false,
                audioCanCopyToMP4: false, fileBytes: 1
            )
            var state = TimelineState()
            state.mainClips = [
                EditClip(sourceURL: white1, sourceDuration: 4, timelineStart: 8, info: info),
                EditClip(sourceURL: white2, sourceDuration: 4, timelineStart: 4, info: info),
                EditClip(sourceURL: white1, sourceDuration: 4, timelineStart: 0, info: info)
            ]
            if let built = await VideoEditCompositionBuilder.build(from: state) {
                for at in [1.0, 5.0, 10.0] {
                    let level = await averageBrightness(built, at: at)
                    check(level > 0.9, "主轨数组乱序时 \(at)s 处也必须全亮，实测 \(level)")
                }
            } else {
                check(false, "主轨乱序场景合成失败")
            }
        }

        // 4. 上层视频轨的默认布局 = **等比铺满画布、居中**，和主轨同一份账
        //    （2026-09-17 起上层轨不再是画中画）。比例对不上的素材两侧留空，
        //    留空处**不补黑** —— 露出来的是下面那一层。
        //
        //    黑色竖版素材（36×64）铺在白色主轨（画布 64×36）上：contain 之后
        //    高度顶满、宽 = 36 × (36/64) = 20.25，占画布宽 20.25/64 = 31.6%，
        //    整幅亮度 = 1 − 0.316 ≈ 0.684。这个数同时排掉两种错法：
        //      · 旧的画中画九宫格（宽 40%、停右上角、收进画布）≈ 0.73；
        //      · 两侧补黑（把主轨遮死）≈ 0.32。
        do {
            let portrait = try await makeSolidVideo(
                white: 0, seconds: 4, name: "portrait.mp4", size: CGSize(width: 36, height: 64)
            )
            let info = MediaInfo(
                duration: 4, displaySize: CGSize(width: 64, height: 36), frameRate: 10,
                videoCodec: "h264", audioCodec: nil, hasAudio: false,
                audioCanCopyToMP4: false, fileBytes: 1
            )
            var portraitInfo = info
            portraitInfo.displaySize = CGSize(width: 36, height: 64)

            // 先钉模型层的契约：默认摆放必须顶满高度、居中、宽按比例收。
            let portraitClip = EditClip(
                sourceURL: portrait, sourceDuration: 4, timelineStart: 0, info: portraitInfo
            )
            let box = portraitClip.defaultPlacement(canvas: CGSize(width: 64, height: 36))
            checkClose(box.height, 1, 0.001, "上层轨竖版素材默认要顶满画布高度")
            checkClose(box.width, 20.25 / 64, 0.001, "宽度按等比 contain 收")
            checkClose(box.centerX, 0.5, 0.001, "水平居中")
            checkClose(box.centerY, 0.5, 0.001, "垂直居中")

            var state = TimelineState()
            state.mainClips = [
                EditClip(sourceURL: white1, sourceDuration: 4, timelineStart: 0, info: info)
            ]
            state.overlayTracks = [EditLane(clips: [portraitClip])]
            if let built = await VideoEditCompositionBuilder.build(from: state) {
                let level = await averageBrightness(built, at: 2)
                check(
                    level > 0.66 && level < 0.71,
                    "上层轨竖版素材要等比铺满画布，实测亮度 \(level)（旧九宫格≈0.73、两侧补黑≈0.32）"
                )
            } else {
                check(false, "上层轨竖版素材场景合成失败")
            }
        }

        // 5. 单段画面渐变（上层轨）：渐变露出来的是**下面那一层**，不是黑场。
        //
        //    黑色满幅素材盖在白色主轨上，给它 2s 渐入：t=0 应当全白（上层
        //    完全透明，主轨透出来），t=1 是半程（≈0.5），t=3 渐变结束后全黑。
        //    如果渐变被实现成「淡向黑色」，t=0 就会是黑的 —— 这条守卫专门钉
        //    这个方向，别改成只量中点。
        do {
            let info = MediaInfo(
                duration: 4, displaySize: CGSize(width: 64, height: 36), frameRate: 10,
                videoCodec: "h264", audioCodec: nil, hasAudio: false,
                audioCanCopyToMP4: false, fileBytes: 1
            )
            let black = try await makeSolidVideo(
                white: 0, seconds: 4, name: "fadeblack.mp4", size: CGSize(width: 64, height: 36)
            )
            var top = EditClip(sourceURL: black, sourceDuration: 4, timelineStart: 0, info: info)
            top.videoFadeInDuration = 2
            var state = TimelineState()
            state.mainClips = [
                EditClip(sourceURL: white1, sourceDuration: 4, timelineStart: 0, info: info)
            ]
            state.overlayTracks = [EditLane(clips: [top])]
            if let built = await VideoEditCompositionBuilder.build(from: state) {
                let atStart = await averageBrightness(built, at: 0.05)
                let atMid = await averageBrightness(built, at: 1.0)
                let atEnd = await averageBrightness(built, at: 3.0)
                check(atStart > 0.9, "渐入起点上层全透明，应当看到主轨的白，实测 \(atStart)")
                check(atMid > 0.35 && atMid < 0.65, "渐入半程应当在两者中间，实测 \(atMid)")
                check(atEnd < 0.1, "渐变结束后上层不透明，应当全黑，实测 \(atEnd)")
            } else {
                check(false, "上层轨画面渐变场景合成失败")
            }
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
            animation.opacity.set(1, atSourceTime: 0, tolerance: kfTol)
            animation.opacity.set(0, atSourceTime: 4, tolerance: kfTol)
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
            animation.width.set(0.2, atSourceTime: 0, tolerance: kfTol)
            animation.width.set(1.0, atSourceTime: 4, tolerance: kfTol)
            animation.height.set(0.2, atSourceTime: 0, tolerance: kfTol)
            animation.height.set(1.0, atSourceTime: 4, tolerance: kfTol)
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
            animation.rotation.set(0, atSourceTime: 0, tolerance: kfTol)
            animation.rotation.set(90, atSourceTime: 4, tolerance: kfTol)
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
            animation.width.set(0.2, atSourceTime: 0, tolerance: kfTol)
            animation.width.set(1.0, atSourceTime: 4, tolerance: kfTol)
            animation.height.set(0.2, atSourceTime: 0, tolerance: kfTol)
            animation.height.set(1.0, atSourceTime: 4, tolerance: kfTol)
            clip.animation = animation
            let intermediate = try await AnimatedClipPrerenderer.renderMain(
                clip: clip, fades: clip.videoFades, renderSize: CGSize(width: 64, height: 36),
                frameRate: .fps30, into: root
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
        //    fill、matte 都烘焙了同一份不透明度（ffmpeg 那边靠 matte 把
        //    fill 除回真实色，两边不带同一份 opacity 权重就除不对，见
        //    docs/bugfixes/2026-08-05-export-prerender-review.md）。
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
            animation.centerX.set(0.5, atSourceTime: 0, tolerance: kfTol)
            animation.centerX.set(0.5, atSourceTime: 4, tolerance: kfTol)
            pip.animation = animation
            let pair = try await AnimatedClipPrerenderer.renderOverlay(
                clip: pip, fades: pip.videoFades, renderSize: CGSize(width: 64, height: 36),
                frameRate: .fps30, into: root
            )
            if let fillFrame = await frameImage(fromFile: pair.fill, at: 2),
               let matteFrame = await frameImage(fromFile: pair.matte, at: 2) {
                let w = Double(fillFrame.width)
                let h = Double(fillFrame.height)
                let centerRegion = CGRect(x: w * 0.45, y: h * 0.45, width: w * 0.1, height: h * 0.1)
                let cornerRegion = CGRect(x: 0, y: 0, width: max(2, w * 0.08), height: max(2, h * 0.08))
                let fillCenter = averageRGBA(fillFrame, region: centerRegion)
                check(
                    fillCenter.red > 0.4 && fillCenter.red < 0.6,
                    "fill 中心要跟 matte 一样烘焙 50% 不透明度（除回真实色时两边权重得对得上），实测 \(fillCenter.red)"
                )
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

        // ---- 推移 / 擦除转场 ----
        //
        // 方向语义来自 xfade 的纯色实测（2026-08-23）：pushLeft/wipeLeft 的
        // 进场段从**右**边进来（画面/擦除边向左运动），以此类推。
        do {
            let black1 = try await makeSolidVideo(white: 0, seconds: 4, name: "black1.mp4")
            let halfTone = try await makeHalfToneVideo(seconds: 4, name: "halftone.mp4")
            let leftBand = CGRect(x: 0.05, y: 0.1, width: 0.35, height: 0.8)
            let rightBand = CGRect(x: 0.6, y: 0.1, width: 0.35, height: 0.8)
            let topBand = CGRect(x: 0.1, y: 0.05, width: 0.8, height: 0.35)
            let bottomBand = CGRect(x: 0.1, y: 0.6, width: 0.8, height: 0.35)

            // P1. 左推方向：白→黑，中点左半是还没滑走的出场段（白）、
            //     右半是从右边滑进来的进场段（黑）。
            if let built = await VideoEditCompositionBuilder.build(
                from: seamState(white1, black1, kind: .pushLeft)
            ) {
                let left = await regionBrightness(built, at: 3.5, region: leftBand)
                let right = await regionBrightness(built, at: 3.5, region: rightBand)
                check(left > 0.85, "左推中点左半应是出场段（白），实测 \(left)")
                check(right < 0.15, "左推中点右半应是进场段（黑），实测 \(right)")
            } else {
                check(false, "左推场景合成失败")
            }

            // P2. 右推方向相反：中点左黑右白。
            if let built = await VideoEditCompositionBuilder.build(
                from: seamState(white1, black1, kind: .pushRight)
            ) {
                let left = await regionBrightness(built, at: 3.5, region: leftBand)
                let right = await regionBrightness(built, at: 3.5, region: rightBand)
                check(left < 0.15, "右推中点左半应是进场段（黑），实测 \(left)")
                check(right > 0.85, "右推中点右半应是出场段（白），实测 \(right)")
            } else {
                check(false, "右推场景合成失败")
            }

            // P3. 下擦除：进场段从顶上露出来 → 中点上黑下白。
            if let built = await VideoEditCompositionBuilder.build(
                from: seamState(white1, black1, kind: .wipeDown)
            ) {
                let top = await regionBrightness(built, at: 3.5, region: topBand)
                let bottom = await regionBrightness(built, at: 3.5, region: bottomBand)
                check(top < 0.15, "下擦除中点上半应是进场段（黑），实测 \(top)")
                check(bottom > 0.85, "下擦除中点下半应是出场段（白），实测 \(bottom)")
            } else {
                check(false, "下擦除场景合成失败")
            }

            // P4. 推移 vs 擦除的本质区别（两色探针，出场段左白右黑、进场段全黑）：
            //     中点画布左半边 —— 擦除显示出场段**自己的左半**（白），
            //     左推显示的是**滑过来的右半**（黑）。纯色素材下两者长得一样，
            //     这一对探针就是防「擦除写成了滑动」（或反过来）的。
            if let built = await VideoEditCompositionBuilder.build(
                from: seamState(halfTone, black1, kind: .wipeLeft)
            ) {
                let left = await regionBrightness(built, at: 3.5, region: leftBand)
                check(left > 0.85, "左擦除中点左半应是出场段原位的左半（白），实测 \(left)")
            } else {
                check(false, "左擦除两色场景合成失败")
            }
            if let built = await VideoEditCompositionBuilder.build(
                from: seamState(halfTone, black1, kind: .pushLeft)
            ) {
                let left = await regionBrightness(built, at: 3.5, region: leftBand)
                check(left < 0.15, "左推中点左半应是滑过来的出场段右半（黑），实测 \(left)")
            } else {
                check(false, "左推两色场景合成失败")
            }

            // P5. 回退：任意角旋转的出场段不满足推移的精确前提 → 双向淡变，
            //     不许出现硬切边（左右两半亮度要接近），也不许全亮。
            if let built = await VideoEditCompositionBuilder.build(
                from: seamState(white1, black1, kind: .pushLeft) { $0.rotationDegrees = 30 }
            ) {
                let left = await regionBrightness(built, at: 3.5, region: leftBand)
                let right = await regionBrightness(built, at: 3.5, region: rightBand)
                check(
                    abs(left - right) < 0.3,
                    "旋转段左推应回退成淡变（无滑动分界），实测左 \(left) 右 \(right)"
                )
                check(left < 0.8, "旋转段左推回退路径中点不该全亮，实测 \(left)")
            } else {
                check(false, "旋转段左推场景合成失败")
            }
        }

        // ---- 工程帧率：24 / 30 / 60 各自的 frameDuration 与真实出帧数 ----
        // 计划 §17.3：2 秒素材，24/30/60 分别应得 48/60/120 帧。
        // 这里走的是真实的 VideoEditCompositionBuilder（预览与预渲染共用的那条）。
        do {
            let src = try await makeSolidVideo(white: 1, seconds: 2, name: "fps-src.mp4")
            let info = MediaInfo(
                duration: 2, displaySize: CGSize(width: 320, height: 180), frameRate: 30,
                videoCodec: "h264", audioCodec: nil, hasAudio: false,
                audioCanCopyToMP4: false, fileBytes: 1
            )
            var measuredByRate: [Int: Double] = [:]
            for (rate, expected) in [(ProjectFrameRate.fps24, 48),
                                     (.fps30, 60),
                                     (.fps60, 120)] {
                var state = TimelineState()
                state.frameRate = rate
                state.mainClips = [
                    EditClip(sourceURL: src, sourceDuration: 2, timelineStart: 0, info: info)
                ]
                guard let built = try await VideoEditCompositionBuilder.build(from: state),
                      let vc = built.videoComposition else {
                    check(false, "\(rate.fps)fps 合成失败")
                    continue
                }
                // 1) frameDuration 必须等于工程帧率
                checkEqual(
                    vc.frameDuration.timescale, Int32(rate.fps),
                    "\(rate.fps)fps 的 frameDuration.timescale"
                )
                checkEqual(vc.frameDuration.value, 1, "\(rate.fps)fps 的 frameDuration.value")

                // 2) 真导出一遍再数帧。
                //
                // 注意不能用 AVAssetReaderVideoCompositionOutput 数：直通合成
                // （单段、无动画无转场）下它按**源帧**透传，frameDuration 不生效 ——
                // 实测 10fps 的 2 秒素材在 24/30/60 三档下都只出 20 帧。
                // 真实导出（预渲染走的就是这条）才会按 frameDuration 重采样。
                let outURL = root.appendingPathComponent("fps-out-\(rate.fps).mov")
                try? FileManager.default.removeItem(at: outURL)
                guard let session = AVAssetExportSession(
                    asset: built.composition, presetName: AVAssetExportPresetAppleProRes422LPCM
                ) else {
                    check(false, "\(rate.fps)fps 建不出导出会话")
                    continue
                }
                session.videoComposition = vc
                do {
                    try await session.export(to: outURL, as: .mov)
                } catch {
                    check(false, "\(rate.fps)fps 导出失败：\(error)")
                    continue
                }
                let outAsset = AVURLAsset(url: outURL)
                guard let outTrack = try await outAsset.loadTracks(withMediaType: .video).first else {
                    check(false, "\(rate.fps)fps 产物没有视频轨")
                    continue
                }
                let reader = try AVAssetReader(asset: outAsset)
                let out = AVAssetReaderTrackOutput(track: outTrack, outputSettings: nil)
                reader.add(out)
                reader.startReading()
                var frames = 0
                while out.copyNextSampleBuffer() != nil { frames += 1 }
                reader.cancelReading()
                // 断言真实契约：帧数 ÷ 实际时长 ≈ 工程帧率。
                // 不直接比「应得 N 帧」——源素材末帧时长会外延，合成比标称的
                // 2.0s 略长（实测 24fps 得 51 帧而非 48），那是素材边界不是帧率错。
                let outDur = try await outAsset.load(.duration).seconds
                let measured = Double(frames) / max(outDur, 0.001)
                measuredByRate[rate.fps] = measured
                // 容差 10%：三档实测都有 +2~3 帧的固定溢出（AVFoundation 在
                // 指令边界补帧），24fps 得 51 帧 = 25.5fps。10% 既容得下这个
                // 系统性溢出，又远小于相邻档之间 25% 的差距。
                check(
                    abs(measured - Double(rate.fps)) / Double(rate.fps) < 0.10,
                    "\(rate.fps)fps 导出的实际帧率应≈\(rate.fps)"
                        + "（实得 \(frames) 帧 / \(String(format: "%.3f", outDur))s"
                        + " = \(String(format: "%.2f", measured)) fps，理论 \(expected) 帧）"
                )
            }
            // 更强的回归信号：三档必须明显区分。若哪天帧率又被写死，
            // 三档会得到**相同**的帧数，上面的百分比断言可能还侥幸过关。
            if let f24 = measuredByRate[24], let f30 = measuredByRate[30],
               let f60 = measuredByRate[60] {
                check(f30 > f24 * 1.15, "30fps 的出帧率要明显高于 24fps（\(f30) vs \(f24)）")
                check(f60 > f30 * 1.5, "60fps 的出帧率要明显高于 30fps（\(f60) vs \(f30)）")
            } else {
                check(false, "三档帧率没有全部测到")
            }
        }

        // MARK: 预设入场 / 出场动画（2026-09-18）
        //
        // 求值器是纯函数，先把曲线本身钉死；再真建合成、真取帧，验证它确实
        // 落到了图层指令上。场景与 checks/VideoFade 里的**一一对应** ——
        // 两条管线同账是这套东西的核心合同。
        // 长期约束见 docs/architecture/clip-animation.md。
        do {
            func state(_ kind: ClipPresetKind, reveal: Double, covers: Bool) -> ClipAnimationState {
                // 2 秒窗口、段长 10：local = reveal × 2 就落在入场窗口里。
                ClipAnimator.state(
                    resolved: ResolvedClipPreset(
                        entrance: kind, exit: .none,
                        window: FadeWindow(fadeIn: 2, fadeOut: 0), intensity: 0.6
                    ),
                    local: reveal * 2, span: 10, coversCanvas: covers
                )
            }

            // 1. Fade 必须是**线性**：它就是 v10 起的画面渐变，导出侧走 ffmpeg
            //    的 `fade`（默认线性）。这里换成缓动曲线，同一个工程"只设淡入"
            //    和"淡入 + 另一侧有位移动画"就会渲出两种画面。
            for point in [0.25, 0.5, 0.75] {
                checkClose(state(.fade, reveal: point, covers: true).opacity, point, 0.0001,
                           "Fade 的不透明度必须线性（与 ffmpeg 的 fade 逐帧对齐）")
            }

            // 2. 盖满画布的段：**任何时刻缩放都不许小于 1**，否则边上会露出
            //    底下那一层（主轨是黑场）。这是产品决策第 4 条的机器守卫。
            for kind in [ClipPresetKind.rise, .pop, .zoom] {
                for step in 0...20 {
                    let value = state(kind, reveal: Double(step) / 20, covers: true)
                    check(value.scale >= 1 - 0.0001,
                          "\(kind.title) 在铺满画布的段上不许缩到 1 以下（会露黑边），实测 \(value.scale)")
                    // 位移多少，就得放大多少盖回去。
                    check(value.scale >= 1 + 2 * abs(value.offset.y) - 0.0001,
                          "\(kind.title) 的位移必须有对应的放大补偿，实测 scale \(value.scale) / offset \(value.offset.y)")
                }
            }

            // 3. 不铺满的段反过来：Pop 要从小弹出来（那才是"弹"），
            //    没有可露的边，也就不补放大。
            let popSmall = state(.pop, reveal: 0, covers: false)
            check(popSmall.scale < 0.9, "角落里的小图 Pop 要从小弹出来，实测 \(popSmall.scale)")
            let popCover = state(.pop, reveal: 0, covers: true)
            check(popCover.scale > 1.1, "铺满画布的段 Pop 反过来从大落到位，实测 \(popCover.scale)")

            // 4. 擦除是线性几何量（裁切斜坡靠它精确重建，不必逐帧加密）。
            for point in [0.25, 0.5, 0.75] {
                checkClose(state(.wipe, reveal: point, covers: true).reveal ?? -1, point, 0.0001,
                           "擦除进度必须线性")
            }
            check(!ClipPresetKind.wipe.needsDenseSampling, "擦除不需要按帧加密（线性）")
            check(ClipPresetKind.rise.needsDenseSampling, "带缓动的效果必须按帧加密")

            // 5. 真取帧：擦除半程时左半边已揭开、右半边还是垫底的黑。
            //    与 checks/VideoFade 场景 6 是同一份几何。
            let info = MediaInfo(
                duration: 4, displaySize: CGSize(width: 64, height: 36), frameRate: 10,
                videoCodec: "h264", audioCodec: nil, hasAudio: false,
                audioCanCopyToMP4: false, fileBytes: 1
            )
            var wiped = EditClip(sourceURL: white1, sourceDuration: 4, timelineStart: 0, info: info)
            wiped.presetAnimation.entrance = .wipe
            wiped.videoFadeInDuration = 2
            var wipeState = TimelineState()
            wipeState.mainClips = [wiped]
            if let built = await VideoEditCompositionBuilder.build(from: wipeState) {
                let leftBand = CGRect(x: 0, y: 0.25, width: 0.25, height: 0.5)
                let rightBand = CGRect(x: 0.75, y: 0.25, width: 0.25, height: 0.5)
                let left = await regionBrightness(built, at: 1.0, region: leftBand)
                let right = await regionBrightness(built, at: 1.0, region: rightBand)
                check(left > 0.7, "擦除半程左侧应当已揭开，实测 \(left)")
                check(right < 0.3, "擦除半程右侧应当还是黑，实测 \(right)")
                let after = await averageBrightness(built, at: 3.0)
                check(after > 0.9, "擦除结束后应当是完整画面，实测 \(after)")
            } else {
                check(false, "擦除入场场景合成失败")
            }

            // 6. 真取帧：铺满画布的段做上浮入场，**底边不许露出黑条**。
            //    量的是"底边和中心一样亮"——上浮自带淡入，两处的绝对亮度
            //    全程在变，但补偿到位的话它们永远相等。
            // 画布用 320×180 而不是 64×36：补偿撤掉后露出来的黑条只有几个像素，
            // 36 px 高的画布上量不出来 —— 守卫红不了就等于没守（AGENTS.md）。
            // 强度拉满、探针压在动画前段，同样是为了让黑条足够宽。
            let bigWhite = try await makeSolidVideo(
                white: 1, seconds: 4, name: "rise-big.mp4", size: CGSize(width: 320, height: 180)
            )
            var bigInfo = info
            bigInfo.displaySize = CGSize(width: 320, height: 180)
            var rose = EditClip(sourceURL: bigWhite, sourceDuration: 4, timelineStart: 0, info: bigInfo)
            rose.presetAnimation.entrance = .rise
            rose.presetAnimation.intensity = 1
            rose.videoFadeInDuration = 2
            var riseState = TimelineState()
            riseState.mainClips = [rose]
            if let built = await VideoEditCompositionBuilder.build(from: riseState) {
                // 入场是**从下方浮上来**，所以动画中这一段是压低的，缺口在**上边**；
                // 两条边都量，省得下次把方向改了守卫却看不见。
                let topBand = CGRect(x: 0.25, y: 0, width: 0.5, height: 0.1)
                let bottomBand = CGRect(x: 0.25, y: 0.9, width: 0.5, height: 0.1)
                let centerBand = CGRect(x: 0.25, y: 0.45, width: 0.5, height: 0.1)
                for at in [0.3, 0.5, 0.8] {
                    let center = await regionBrightness(built, at: at, region: centerBand)
                    for (band, label) in [(topBand, "上边"), (bottomBand, "下边")] {
                        let edge = await regionBrightness(built, at: at, region: band)
                        check(abs(edge - center) < 0.08,
                              "上浮入场 \(at)s：\(label)不许比中心暗（露黑边），实测 边 \(edge) / 中 \(center)")
                    }
                }
                let after = await averageBrightness(built, at: 3.0)
                check(after > 0.9, "上浮结束后应当是完整画面，实测 \(after)")
            } else {
                check(false, "上浮入场场景合成失败")
            }
        }

        // N. 单段隐藏（快捷键 V）：那一段在预览里真的没有画面
        //
        // 两级隐藏（整轨的眼睛 / 单段的 V）渲染语义是同一条：画面和声音都不进。
        // 纯值那边（checks/ProjectFile）只证明「过滤函数算得对」，这里真取帧：
        // 藏起来的那一段所在时刻必须是黑的，邻居一帧都不许受影响。
        // 合同见 docs/architecture/clip-visibility.md。
        do {
            let info = MediaInfo(
                duration: 4, displaySize: CGSize(width: 64, height: 36), frameRate: 10,
                videoCodec: "h264", audioCodec: nil, hasAudio: false,
                audioCanCopyToMP4: false, fileBytes: 1
            )
            var state = TimelineState()
            state.mainClips = [
                EditClip(sourceURL: white1, sourceDuration: 4, timelineStart: 0, info: info),
                EditClip(sourceURL: white2, sourceDuration: 4, timelineStart: 4, info: info)
            ]
            state.mainClips[1].isHidden = true
            if let built = await VideoEditCompositionBuilder.build(from: state) {
                let visible = await averageBrightness(built, at: 2.0)
                check(visible > 0.9, "没藏的那一段照常出画面，实测 \(visible)")
                let hidden = await averageBrightness(built, at: 6.0)
                check(hidden < 0.1, "藏起来的那一段所在时刻必须是黑场，实测 \(hidden)")
            } else {
                check(false, "单段隐藏场景合成失败")
            }

            // 接缝：前一段挂着叠化、后一段被藏起来 —— 这条接缝不存在，活着的
            // 那一侧**不许**淡进黑场（导出那边隐藏段早被滤掉、转场退回硬切，
            // 两边必须同解）。量的是转场本该发生的时刻。
            var seam = TimelineState()
            seam.mainClips = [
                EditClip(sourceURL: white1, sourceDuration: 4, timelineStart: 0, info: info),
                EditClip(sourceURL: white2, sourceDuration: 4, timelineStart: 3, info: info)
            ]
            seam.mainClips[0].transitionAfter = .crossFade
            seam.mainClips[0].transitionDuration = 1
            seam.mainClips[1].isHidden = true
            if let built = await VideoEditCompositionBuilder.build(from: seam) {
                let inSeam = await averageBrightness(built, at: 3.5)
                check(inSeam > 0.9,
                      "后一段被藏起来时，前一段不许在接缝里淡出（导出是硬切），实测 \(inSeam)")
            } else {
                check(false, "隐藏段接缝场景合成失败")
            }
        }

    } catch {
        check(false, "自检执行失败：\(error)")
    }
    semaphore.signal()
}
semaphore.wait()

print("\(checks) checks, \(failures) failures")
if failures == 0 { print("All checks passed") }
try? FileManager.default.removeItem(at: root)
exit(failures == 0 ? 0 : 1)
