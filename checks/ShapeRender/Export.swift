import AVFoundation
import CoreGraphics
import Foundation
import SrtFlowCore

// 二、真导出：黑底上一个白色圆环（描边），0.5 秒起、2 秒长，入场「画出来」0.8 秒、出场「淡出」0.6 秒，30fps。
// 抽帧量四个钟点上的亮度：入场画到一半时只有右半圈、中间一整圈、出场淡到一半时只剩约一成亮、段外全黑。
// 抽的帧离边界都隔着好几帧，差一帧也不会让结论翻转 —— 这里守的是「动画真的进了成片、落在对的那一截」，
// 逐像素长什么样是 Parity.swift 的事（导出的每一帧就是 ShapePNGRenderer 那张图）。

private let exportCanvas = CGSize(width: 640, height: 360)
private let fps = 30.0

@discardableResult
private func run(_ launchPath: String, _ args: [String], workingDirectory: URL? = nil) -> (Int32, String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = args
    // 形状的 PNG 在滤镜图里是相对文件名，生产侧靠 FFmpegProcess 把工作目录设成 workspace，这里照做。
    if let workingDirectory { process.currentDirectoryURL = workingDirectory }
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do { try process.run() } catch { return (-1, "启动失败：\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// 纯黑素材，AVAssetWriter 直接写（造素材和被测对象不共用 ffmpeg）。
private func makeBlackVideo(seconds: Double) async throws -> URL {
    let url = root.appendingPathComponent("black.mp4")
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: Int(exportCanvas.width),
        AVVideoHeightKey: Int(exportCanvas.height)
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: Int(exportCanvas.width),
        kCVPixelBufferHeightKey as String: Int(exportCanvas.height)
    ])
    input.expectsMediaDataInRealTime = false
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    let rate = 10
    for frame in 0..<Int(seconds * Double(rate)) {
        while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
        guard let pixels = buffer else { continue }
        CVPixelBufferLockBaseAddress(pixels, [])
        if let base = CVPixelBufferGetBaseAddress(pixels) {
            memset(base, 0, CVPixelBufferGetBytesPerRow(pixels) * Int(exportCanvas.height))  // H.264 不看 alpha，全 0 就是黑
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(rate)))
    }
    input.markAsFinished()
    await writer.finishWriting()
    return url
}

private func plan(_ state: TimelineState, name: String) async -> VideoEditExportGraph.Plan? {
    do {
        return try await VideoEditExportGraph.plan(
            state: state, settings: VideoEncodeSettings(), subtitleStyle: BurnInStyle(name: "check"),
            subtitleFontURL: nil, output: root.appendingPathComponent("\(name).mp4")
        )
    } catch {
        check(false, "\(name) 的 plan() 失败：\(error)")
        return nil
    }
}

private func pngNames(in workspace: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: workspace.path)) ?? []).filter { $0.hasSuffix(".png") }
}

/// 第 `frame` 帧上 (x, y) 的亮度 0…1。`-ss` 落在这一帧之前四分之一帧：ffmpeg 丢掉时间戳早于它的帧，第一张就是这一帧。
private func luma(_ video: URL, x: Int, y: Int, frame: Int) -> Double? {
    let raw = root.appendingPathComponent("probe-\(frame)-\(x)x\(y).gray")
    let (code, out) = run(ffmpegPath, [
        "-hide_banner", "-loglevel", "error", "-y",
        "-ss", String(format: "%.4f", (Double(frame) - 0.25) / fps), "-i", video.path,
        "-frames:v", "1", "-vf", "crop=1:1:\(x):\(y),format=gray", "-f", "rawvideo", "-pix_fmt", "gray", raw.path
    ])
    guard code == 0, let byte = (try? Data(contentsOf: raw))?.first else {
        check(false, "第 \(frame) 帧取 (\(x),\(y)) 失败：\(out.suffix(300))")
        return nil
    }
    return Double(byte) / 255
}

func runExportChecks() async {
    guard let black = try? await makeBlackVideo(seconds: 3) else {
        check(false, "黑底素材造不出来")
        return
    }
    var state = TimelineState()
    state.frameRate = .fps30
    state.mainClips = [EditClip(sourceURL: black, sourceDuration: 3, info: MediaInfo(
        duration: 3, displaySize: exportCanvas, frameRate: 10, videoCodec: "h264", audioCodec: nil, hasAudio: false,
        audioCanCopyToMP4: false, fileBytes: 1
    ))]
    // 直径 0.4 × 640 = 256 像素，线宽 30（1080 高）= 10 像素：描边的中线落在半径 123 上。
    var ring = ShapeAnnotation(kind: .circle, timelineStart: 0.5, duration: 2, color: .white, lineWidth: 30, width: 0.4)
    ring.animation = ShapeAnimation(entrance: .draw, exit: .fade, entranceDuration: 0.8, exitDuration: 0.6)

    // 没有动画的形状照旧整段一张图；有动画的只逐帧渲入场和出场那两截。
    var still = state
    still.shapes = [ShapeAnnotation(kind: .circle, timelineStart: 0.5, duration: 2, color: .white, lineWidth: 30, width: 0.4)]
    if let stillPlan = await plan(still, name: "still") {
        check(pngNames(in: stillPlan.workspace) == ["shape0.png"], "没有动画：只渲一张 shape0.png（实际 \(pngNames(in: stillPlan.workspace))）")
        try? FileManager.default.removeItem(at: stillPlan.workspace)
    }
    state.shapes = [ring]
    guard let animated = await plan(state, name: "animated") else { return }
    let names = pngNames(in: animated.workspace)
    let entrance = names.filter { $0.hasPrefix("shape0-in_") }.count
    let exit = names.filter { $0.hasPrefix("shape0-out_") }.count
    check((24...26).contains(entrance), "入场 0.8 秒逐帧渲 24 帧左右（加末尾多一帧），实际 \(entrance)")
    check((18...20).contains(exit), "出场 0.6 秒逐帧渲 18 帧左右（加末尾多一帧），实际 \(exit)")
    check(names.contains("shape0-mid.png") && names.count == entrance + exit + 1, "中间那截一张图，别的不渲（实际 \(names.count) 张）")

    let (code, out) = run(ffmpegPath, animated.arguments, workingDirectory: animated.workspace)
    guard code == 0 else {
        check(false, "导出失败：\(out.suffix(800))")
        try? FileManager.default.removeItem(at: animated.workspace)
        return
    }
    let video = root.appendingPathComponent("animated-product.mp4")
    try? FileManager.default.copyItem(at: animated.tempOutput, to: video)
    try? FileManager.default.removeItem(at: animated.workspace)

    // 四个钟点：12 点、3 点、6 点、9 点（中心 (320, 180)，描边中线半径 123）。
    let twelve = (320, 57), three = (443, 180), nine = (197, 180), six = (320, 303)
    func at(_ point: (Int, Int), _ frame: Int) -> Double { luma(video, x: point.0, y: point.1, frame: frame) ?? -1 }

    check(at(three, 9) < 0.15, "段开头之前（0.3 秒）没有圆环")
    // 入场画到一半（0.9 秒，第 27 帧）：从 12 点顺时针到 6 点，3 点亮、9 点还黑。
    check(at(three, 27) > 0.7, "入场画到一半：3 点已经画上了（\(at(three, 27))）")
    check(at(nine, 27) < 0.15, "入场画到一半：9 点还没画到（\(at(nine, 27))）")
    // 中间（1.6 秒，第 48 帧）：一整圈。
    let whole = [twelve, three, six, nine].map { at($0, 48) }
    check(whole.allSatisfy { $0 > 0.7 }, "中间一整圈都亮（\(whole)）")
    // 出场淡到一半（2.2 秒，第 66 帧）：不透明度 easeIn(0.5) = 0.125，量相对亮度（不管色彩范围怎么换算）。
    let dark = at(nine, 9), bright = at(twelve, 48), fading = at(twelve, 66)
    let relative = (fading - dark) / max(0.01, bright - dark)
    check(relative > 0.05 && relative < 0.25, "出场淡到一半只剩一成左右的亮（相对亮度 \(relative)）")
    check(at(twelve, 81) < 0.15, "段结束之后（2.7 秒）没有圆环")
}
