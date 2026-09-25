import AVFoundation
import CoreGraphics
import Foundation
import SrtFlowCore

// **画面文字的真实回归**：不测纯函数，测真导出的成片就是渲染器画的那张图。
//
// 这套东西的全部价值都押在一句话上：**预览和导出用同一个渲染函数**。守卫因此
// 必须直接钉这句话 —— 拿 `TextRenderer.render()` 在导出分辨率上渲一张，
// 从中挑出「一定是字」和「一定不是字」的像素坐标，再跑一遍**生产**导出，
// 到成片的同一批坐标上逐点量明暗。两边对不上，就是两条管线分叉了。
//
// 顺带把落点取整那条契约也钉住了：`TextRenderer` 把位图落点 `.rounded()` 到
// 整像素，ffmpeg 的 overlay 也按整像素贴。少了这一步，成片会比渲染图差半个
// 像素，本组的逐点断言立刻红。
//
// 探针方式沿用 check-video-fade 的教训：成品是 yuv420p **有限范围**
//（白≈235、黑≈16），整幅平均会随色彩范围漂，所以只问「这一点亮还是暗」。
// 又因为 4:2:0 会抹色度、编码会糊边，挑点时要求 **3×3 邻域同质**，
// 而不是逮着一个孤立像素就问。
//
// 动画（第二刀）再加五条，见文件后半段的第 5–9 组。
//
// 守的五条契约：
// 1. 成片里的字与 `TextRenderer` 渲出来的**逐点重合**（位置 + 形状 + 落点取整）。
// 2. 只在自己的时间区间里出现。
// 3. 压在形状之上（滤镜图次序）。
// 4. 空文字不进导出（不生成 PNG、不加 input）。
// 5. 位图是**包络**大小，不是整幅画布（逐帧导出的成本前提）。
//
// 编译方式见 scripts/check-text-render.sh。长期约束见
// docs/architecture/text-overlays.md。

let ffmpegPath = ProcessInfo.processInfo.environment["SRTFLOW_FFMPEG"]
    ?? FileManager.default.currentDirectoryPath + "/vendor/ffmpeg"

let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("srtflow-textrender-\(UUID().uuidString)", isDirectory: true)
try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

func finish(_ code: Int32) -> Never {
    try? FileManager.default.removeItem(at: root)
    exit(code)
}

/// `workingDirectory` 必须能传：形状和文字的 PNG、字幕的 ASS 在滤镜图里都是
/// **相对文件名**，生产侧靠 `FFmpegProcess` 把进程的工作目录设成 workspace
/// 才找得到（`process.currentDirectoryURL = workingDirectory`）。自检不设的话，
/// 跑起来是「Error opening input file text0.png」—— 而那不是产品的问题。
@discardableResult
func run(_ launchPath: String, _ args: [String], workingDirectory: URL? = nil) -> (Int32, String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = args
    if let workingDirectory { process.currentDirectoryURL = workingDirectory }
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do { try process.run() } catch { return (-1, "启动失败：\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

// MARK: - 素材

/// 纯色素材。用 AVAssetWriter 直接写，不依赖 ffmpeg 造素材
///（造素材和被测对象共用一个工具，工具出错会两边一起错，看不出来）。
func makeSolidVideo(white: Double, seconds: Double, name: String, size: CGSize) async throws -> URL {
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
    input.expectsMediaDataInRealTime = false
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)

    let fps = 10
    let total = Int(seconds * Double(fps))
    let value = UInt8(max(0, min(255, white * 255)))
    for frame in 0..<total {
        while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
        guard let pixels = buffer else { continue }
        CVPixelBufferLockBaseAddress(pixels, [])
        if let base = CVPixelBufferGetBaseAddress(pixels) {
            memset(base, Int32(value), CVPixelBufferGetBytesPerRow(pixels) * Int(size.height))
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
    }
    input.markAsFinished()
    await writer.finishWriting()
    return url
}

func info(_ size: CGSize, seconds: Double) -> MediaInfo {
    MediaInfo(
        duration: seconds, displaySize: size, frameRate: 10,
        videoCodec: "h264", audioCodec: nil, hasAudio: false,
        audioCanCopyToMP4: false, fileBytes: 1
    )
}

// MARK: - 真导出 + 抽帧

func export(_ state: TimelineState, name: String) async -> URL? {
    let output = root.appendingPathComponent(name)
    let plan: VideoEditExportGraph.Plan
    do {
        plan = try await VideoEditExportGraph.plan(
            state: state,
            settings: VideoEncodeSettings(),
            subtitleStyle: BurnInStyle(name: "check"),
            subtitleFontURL: nil,
            output: output
        )
    } catch {
        check(false, "\(name) 的 plan() 失败：\(error)")
        return nil
    }
    let (code, out) = run(ffmpegPath, plan.arguments, workingDirectory: plan.workspace)
    guard code == 0 else {
        try? FileManager.default.removeItem(at: plan.workspace)
        check(false, "\(name) 的 ffmpeg 执行失败：\(out.suffix(800))")
        return nil
    }
    // `tempOutput` 在 workspace 里，清掉 workspace 等于把成品一起删了。
    let kept = root.appendingPathComponent("product-\(name)")
    try? FileManager.default.removeItem(at: kept)
    do {
        try FileManager.default.copyItem(at: plan.tempOutput, to: kept)
    } catch {
        try? FileManager.default.removeItem(at: plan.workspace)
        check(false, "\(name) 的成品搬不出来：\(error)")
        return nil
    }
    try? FileManager.default.removeItem(at: plan.workspace)
    return kept
}

func pixel(_ url: URL, x: Int, y: Int, at seconds: Double, name: String) -> Double? {
    let raw = root.appendingPathComponent("\(name)-\(x)x\(y)-\(seconds).gray")
    let (code, out) = run(ffmpegPath, [
        "-hide_banner", "-loglevel", "error", "-y",
        "-ss", String(seconds), "-i", url.path,
        "-frames:v", "1", "-vf", "crop=1:1:\(x):\(y),format=gray",
        "-f", "rawvideo", "-pix_fmt", "gray", raw.path
    ])
    guard code == 0, let data = try? Data(contentsOf: raw), let byte = data.first else {
        check(false, "\(name) 在 \(seconds)s 取 (\(x),\(y)) 失败：\(out.suffix(300))")
        return nil
    }
    return Double(byte) / 255
}

func filterGraph(_ state: TimelineState, name: String) async -> String? {
    let output = root.appendingPathComponent("\(name).mp4")
    do {
        let plan = try await VideoEditExportGraph.plan(
            state: state,
            settings: VideoEncodeSettings(),
            subtitleStyle: BurnInStyle(name: "check"),
            subtitleFontURL: nil,
            output: output
        )
        defer { try? FileManager.default.removeItem(at: plan.workspace) }
        guard let index = plan.arguments.firstIndex(of: "-filter_complex"),
              index + 1 < plan.arguments.count else {
            check(false, "\(name) 的参数里没有 -filter_complex")
            return nil
        }
        return plan.arguments[index + 1]
    } catch {
        check(false, "\(name) 的 plan() 失败：\(error)")
        return nil
    }
}

/// 跑一次 `plan()` 但**留下 workspace**：要数里面渲了多少张 PNG
///（"只逐帧渲动画进行中的那段"这条契约只能靠数文件来守）。
func planKeepingWorkspace(_ state: TimelineState, name: String) async -> VideoEditExportGraph.Plan? {
    do {
        return try await VideoEditExportGraph.plan(
            state: state,
            settings: VideoEncodeSettings(),
            subtitleStyle: BurnInStyle(name: "check"),
            subtitleFontURL: nil,
            output: root.appendingPathComponent("\(name).mp4")
        )
    } catch {
        check(false, "\(name) 的 plan() 失败：\(error)")
        return nil
    }
}

func pngCount(in workspace: URL, prefix: String) -> Int {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: workspace.path)) ?? []
    return names.filter { $0.hasPrefix(prefix) && $0.hasSuffix(".png") }.count
}

// MARK: - 从渲染图里挑探针点

/// 位图的 alpha 通道。重新画一遍到自己的缓冲里，不去猜 `CGImage` 内部的排布。
func alphaMask(_ image: CGImage) -> (width: Int, height: Int, alpha: [UInt8])? {
    let width = image.width
    let height = image.height
    guard width > 0, height > 0,
          let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let ok: Bool = bytes.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(
            data: buffer.baseAddress, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    guard ok else { return nil }
    // premultipliedLast：每 4 个字节的最后一个是 alpha。
    return (width, height, stride(from: 3, to: bytes.count, by: 4).map { bytes[$0] })
}

/// 在渲染图里找「3×3 邻域全是字」和「3×3 邻域全是空」的点，换算成画布坐标。
///
/// 要求邻域同质，是因为成品是 4:2:0 + 有损编码：孤立的一个像素会被邻居糊掉，
/// 拿它当探针等于在测编码器的心情。
func probePoints(
    _ rendered: RenderedText, canvas: CGSize, wanted: Int
) -> (ink: [(Int, Int)], empty: [(Int, Int)]) {
    guard let mask = alphaMask(rendered.image), mask.width > 2, mask.height > 2 else { return ([], []) }
    var ink: [(Int, Int)] = []
    var empty: [(Int, Int)] = []

    func solid(_ x: Int, _ y: Int, _ test: (UInt8) -> Bool) -> Bool {
        for dy in -1...1 {
            for dx in -1...1 where !test(mask.alpha[(y + dy) * mask.width + (x + dx)]) {
                return false
            }
        }
        return true
    }

    // `CGContext.draw` 把 CGImage 的第 0 行画在**顶部**，所以这里的 y 和画布的
    // 左上原点同向，直接加 origin 就是画布坐标。
    for y in 1..<(mask.height - 1) {
        for x in 1..<(mask.width - 1) {
            let cx = Int(rendered.origin.x) + x
            let cy = Int(rendered.origin.y) + y
            guard cx > 0, cy > 0, cx < Int(canvas.width) - 1, cy < Int(canvas.height) - 1 else { continue }
            if ink.count < wanted, solid(x, y, { $0 > 250 }) {
                ink.append((cx, cy))
            } else if empty.count < wanted, solid(x, y, { $0 == 0 }) {
                empty.append((cx, cy))
            }
            if ink.count >= wanted, empty.count >= wanted { return (ink, empty) }
        }
    }
    return (ink, empty)
}

/// 位图最外圈那一圈像素全是透明吗。
///
/// 包络留小了的判据就是它：内容被位图边缘切掉时，边上一定有不透明的像素。
/// 只看尺寸是不是恒定抓不到这个 —— 包络算小了的话尺寸照样恒定，只是内容被裁。
func borderIsClear(_ image: CGImage) -> Bool {
    guard let mask = alphaMask(image), mask.width > 2, mask.height > 2 else { return false }
    for x in 0..<mask.width {
        if mask.alpha[x] != 0 { return false }
        if mask.alpha[(mask.height - 1) * mask.width + x] != 0 { return false }
    }
    for y in 0..<mask.height {
        if mask.alpha[y * mask.width] != 0 { return false }
        if mask.alpha[y * mask.width + mask.width - 1] != 0 { return false }
    }
    return true
}

// MARK: - 场景

let canvas = CGSize(width: 640, height: 360)

func baseState(_ source: URL, seconds: Double) -> TimelineState {
    var state = TimelineState()
    state.mainClips = [EditClip(
        sourceURL: source,
        sourceDuration: seconds,
        info: info(canvas, seconds: seconds)
    )]
    return state
}

/// 白字、粗体，不带描边/投影/底板 —— 只留「字本身」，探针才问得干净。
func whiteTitle(start: Double, duration: Double, text: String = "HIHI") -> TextOverlay {
    var style = TextStyle.default
    // 1080p 基准，画布高 360 → 实际 ≈ 100px，笔画够粗，扛得住 4:2:0。
    style.fontSize = 300
    style.shadow = nil
    style.fill = .solid(.white)
    return TextOverlay(
        text: text,
        timelineStart: start,
        duration: duration,
        centerX: 0.5,
        centerY: 0.5,
        boxWidth: 0.9,
        style: style
    )
}

func main() async {
    let dark: URL
    do {
        dark = try await makeSolidVideo(white: 0.08, seconds: 6, name: "dark.mp4", size: canvas)
    } catch {
        print("FAIL 造素材失败：\(error)")
        finish(1)
    }

    // MARK: 1 —— 成片里的字与渲染图逐点重合

    var state = baseState(dark, seconds: 6)
    state.textOverlays = [whiteTitle(start: 1, duration: 3)]
    let overlay = state.textOverlays[0]

    guard let rendered = TextRenderer.render(overlay, canvas: canvas) else {
        check(false, "TextRenderer 渲不出这段文字")
        finish(1)
    }

    // 契约 5：位图是包络，不是整幅画布。
    check(
        rendered.size.width < canvas.width && rendered.size.height < canvas.height,
        "位图应当只有包络那么大，实际 \(rendered.size) vs 画布 \(canvas)"
    )
    // 落点必须是整数（ffmpeg 的 overlay 按整像素贴）。
    check(
        rendered.origin.x == rendered.origin.x.rounded()
            && rendered.origin.y == rendered.origin.y.rounded(),
        "位图落点必须取整，实际 \(rendered.origin)"
    )

    let probes = probePoints(rendered, canvas: canvas, wanted: 6)
    check(probes.ink.count >= 3, "渲染图里没找到足够的「一定是字」探针点（\(probes.ink.count)）")
    check(probes.empty.count >= 3, "渲染图里没找到足够的「一定不是字」探针点（\(probes.empty.count)）")

    if let product = await export(state, name: "title.mp4") {
        for point in probes.ink.prefix(3) {
            if let value = pixel(product, x: point.0, y: point.1, at: 2, name: "ink") {
                check(value > 0.6, "成片 (\(point.0),\(point.1)) 应当是字（亮），实际 \(value)")
            }
        }
        for point in probes.empty.prefix(3) {
            if let value = pixel(product, x: point.0, y: point.1, at: 2, name: "empty") {
                check(value < 0.3, "成片 (\(point.0),\(point.1)) 应当没有字（暗），实际 \(value)")
            }
        }

        // MARK: 2 —— 只在自己的时间区间里出现
        if let point = probes.ink.first {
            if let before = pixel(product, x: point.0, y: point.1, at: 0.4, name: "before") {
                check(before < 0.3, "文字起点之前不该有字，实际 \(before)")
            }
            if let after = pixel(product, x: point.0, y: point.1, at: 5, name: "after") {
                check(after < 0.3, "文字终点之后不该有字，实际 \(after)")
            }
        }
    }

    // MARK: 3 —— 层序：形状先贴，文字后贴（文字压在形状之上）

    var layered = baseState(dark, seconds: 6)
    layered.shapes = [ShapeAnnotation(kind: .rectangle, timelineStart: 0, duration: 6)]
    layered.textOverlays = [whiteTitle(start: 0, duration: 6)]
    if let graph = await filterGraph(layered, name: "layered") {
        // 形状贴在 x=0:y=0（整幅 PNG），文字贴在渲染器算出来的落点上。
        let shapeOverlay = graph.range(of: "overlay=x=0:y=0")
        let textOverlay = graph.range(of: "overlay=x=\(Int(rendered.origin.x)):")
        check(shapeOverlay != nil, "滤镜图里没有形状的 overlay")
        check(textOverlay != nil, "滤镜图里没有文字的 overlay（落点该是渲染器算的那个）")
        if let shapeOverlay, let textOverlay {
            check(
                shapeOverlay.lowerBound < textOverlay.lowerBound,
                "文字必须贴在形状之后（压在形状之上）"
            )
        }
        // 这份时间线没有字幕，确认没混进 subtitles 滤镜（字幕永远在最后烧）。
        check(!graph.contains("subtitles="), "这份时间线没有字幕，不该出现 subtitles 滤镜")
    }

    // MARK: 4 —— 渲不出画面的文字：不登记 input，导出照常跑完
    //
    // 这一组守的不是"空文字看不见"（那有好几道闸门各自兜着，拆掉任何一道都
    // 还是看不见），而是 `TextOverlayExport.renderFiles` 的**登记与落盘必须
    // 同生共死**：一旦它给某段文字加了 `-i text0.png` 却没写出那个文件，
    // ffmpeg 会当场 "Error opening input file text0.png"，**整个导出失败** ——
    // 用户丢的不是一段文字，是整次渲染。所以断言要跑真导出、要求它成功。
    var blank = baseState(dark, seconds: 6)
    blank.textOverlays = [TextOverlay(text: "   \n  ", timelineStart: 0, duration: 3)]
    if let graph = await filterGraph(blank, name: "blank") {
        check(!graph.contains("text0.png"), "渲不出画面的文字不该进滤镜图")
    }
    check(
        await export(blank, name: "blank.mp4") != nil,
        "带一段渲不出画面的文字时，导出必须照常跑完"
    )

    // MARK: 5 —— 动画：模型说多少，成片就是多少
    //
    // **这一组是第二刀的核心。**淡入的每一刻，`TextAnimator` 给出一个
    // 不透明度 o；成片在同一刻的那个像素应当正好是 `o × 字 + (1-o) × 底`。
    // 对不上就是两条管线分叉了 —— 而最容易分叉的恰恰是缓动曲线：
    // 线性和 easeOutCubic 在中点差 0.375，远超这里的容差。

    var fading = baseState(dark, seconds: 6)
    fading.frameRate = .fps30
    var fadeText = whiteTitle(start: 1, duration: 4)
    fadeText.animation = TextAnimation(
        entrance: .fade, exit: .none,
        entranceDuration: 1.5, exitDuration: 0.6,
        emphasis: .none, intensity: 0.6
    )
    fading.textOverlays = [fadeText]

    if let product = await export(fading, name: "fade.mp4"),
       let point = probes.ink.first {
        // 先量两个端点：完全显示时多亮、完全没有时多亮。
        // 不假设"白=1、黑=0" —— 成品是有限范围 yuv，端点要实测。
        let full = pixel(product, x: point.0, y: point.1, at: 3.5, name: "fade-full")
        let empty = pixel(product, x: point.0, y: point.1, at: 0.5, name: "fade-empty")
        if let full, let empty {
            check(full - empty > 0.4, "淡入结束后该明显比没有字时亮（\(empty) → \(full)）")
            for offset in [0.25, 0.5, 0.75] {
                let time = 1 + 1.5 * offset
                let state = TextAnimator.state(
                    for: fadeText, at: time, canvas: canvas, frameRate: .fps30
                )
                guard let measured = pixel(
                    product, x: point.0, y: point.1, at: time, name: "fade-\(offset)"
                ) else { continue }
                let expected = state.opacity * full + (1 - state.opacity) * empty
                // 容差 0.10：h264 量化 + 抽帧可能差一帧（1.5 秒的淡入里
                // 一帧只有 ~3% 的变化），但缓动写错是 37% 的差别。
                checkClose(measured, expected, 0.10,
                           "淡入 \(Int(offset * 100))% 处，成片应当等于模型给的不透明度")
            }
        }
    }

    // MARK: 6 —— 只逐帧渲动画进行中的那段
    //
    // 一段 4 秒的文字、入场 0.5s + 出场 0.5s，中间 3 秒画面一帧都没变 ——
    // 那 3 秒必须是**一张图 + 一个时间区间**。整段逐帧渲的话，30fps 下是
    // 120 帧而不是 32 帧，逐帧导出的成本前提就塌了。

    var segmented = baseState(dark, seconds: 6)
    segmented.frameRate = .fps30
    var segText = whiteTitle(start: 1, duration: 4)
    segText.animation = TextAnimation(
        entrance: .rise, exit: .fade,
        entranceDuration: 0.5, exitDuration: 0.5,
        emphasis: .none, intensity: 0.6
    )
    segmented.textOverlays = [segText]

    if let plan = await planKeepingWorkspace(segmented, name: "segmented") {
        defer { try? FileManager.default.removeItem(at: plan.workspace) }
        let graph = plan.arguments.firstIndex(of: "-filter_complex")
            .map { plan.arguments[$0 + 1] } ?? ""
        check(plan.arguments.contains("text0-in_%05d.png"), "入场要有逐帧序列")
        check(plan.arguments.contains("text0-mid.png"), "中间要是一张静止图")
        check(plan.arguments.contains("text0-out_%05d.png"), "出场要有逐帧序列")
        check(graph.contains("loop=loop=-1") == false, "没有强调动画时不该出现循环段")

        checkEqual(pngCount(in: plan.workspace, prefix: "text0-mid"), 1,
                   "中间那段只该渲一张图")
        // 0.5 秒 @30fps = 15 帧，加一帧堵 EOF 的缝 = 16。
        checkEqual(pngCount(in: plan.workspace, prefix: "text0-in_"), 16,
                   "入场逐帧的张数 = 时长 × 帧率 + 1")
    }

    // MARK: 7 —— 循环动画只渲一个周期
    //
    // 呼吸是周期性的。整段逐帧渲会随文字时长线性膨胀 —— 10 分钟的呼吸文字
    // 能写出几个 GB。所以中间那段只渲一个周期，交给 ffmpeg 的 `loop` 铺满。

    var breathing = baseState(dark, seconds: 6)
    breathing.frameRate = .fps30
    var breatheText = whiteTitle(start: 0, duration: 6)
    breatheText.animation = TextAnimation(
        entrance: .none, exit: .none,
        entranceDuration: 0.6, exitDuration: 0.6,
        emphasis: .breathe, intensity: 0.5
    )
    breathing.textOverlays = [breatheText]

    if let plan = await planKeepingWorkspace(breathing, name: "breathing") {
        defer { try? FileManager.default.removeItem(at: plan.workspace) }
        let graph = plan.arguments.firstIndex(of: "-filter_complex")
            .map { plan.arguments[$0 + 1] } ?? ""
        let periodFrames = Int((TextAnimation.breathePeriod(frameRate: .fps30) * 30).rounded())
        check(graph.contains("loop=loop=-1:size=\(periodFrames)"),
              "循环段要用 loop 滤镜铺满，且只有一个周期那么多帧")
        checkEqual(pngCount(in: plan.workspace, prefix: "text0-mid_"), periodFrames,
                   "循环段只该渲一个周期的帧（不是整段 6 秒 × 30fps）")
        // 周期必须是整数帧，否则循环接缝处相位会跳。
        checkClose(TextAnimation.breathePeriod(frameRate: .fps30) * 30,
                   Double(periodFrames), 0.0001, "呼吸周期必须落在整数帧上")
    }

    // MARK: 8 —— 位图尺寸和落点全程固定
    //
    // 逐帧导出时每一帧都按**整段动画的包络**渲，overlay 的 x/y 才能是常数。
    // 按当帧算的话尺寸每帧都变，贴图位置得跟着改，动画会抖。

    var popping = whiteTitle(start: 0, duration: 3)
    popping.animation = TextAnimation(
        entrance: .pop, exit: .rise,
        entranceDuration: 0.8, exitDuration: 0.8,
        emphasis: .breathe, intensity: 1
    )
    var sizes: Set<String> = []
    var origins: Set<String> = []
    for step in 0...12 {
        let time = Double(step) * 0.25
        let state = TextAnimator.state(for: popping, at: time, canvas: canvas, frameRate: .fps30)
        guard let frame = TextRenderer.render(popping, canvas: canvas, state: state) else { continue }
        sizes.insert("\(frame.size)")
        origins.insert("\(frame.origin)")
    }
    checkEqual(sizes.count, 1, "整段动画里位图尺寸必须只有一种")
    checkEqual(origins.count, 1, "整段动画里贴图落点必须只有一个")

    // 尺寸恒定还不够：包络**算小了**的话尺寸照样恒定，只是内容被位图边缘
    // 切掉。所以逐帧确认最外圈始终全透明 —— 真正会顶到边的不是缩放的峰值
    // （那点余量版面框里本来就有），而是 `rise` 在低不透明度时那个大位移：
    // 淡到两成的时候文字已经偏出去大半个字高了。
    var clippedAt: [String] = []
    for step in 0...24 {
        let time = Double(step) * 0.125
        let state = TextAnimator.state(for: popping, at: time, canvas: canvas, frameRate: .fps30)
        guard state.opacity > 0.02,
              let frame = TextRenderer.render(popping, canvas: canvas, state: state) else { continue }
        if !borderIsClear(frame.image) {
            clippedAt.append(String(format: "%.2fs", time))
        }
    }
    check(clippedAt.isEmpty, "动画期间位图最外圈必须始终全透明，被裁的时刻：\(clippedAt)")

    // MARK: 9 —— 时长夹紧与声音 / 画面渐变共用同一份
    //
    // 「入场 2s + 出场 2s 撞上只有 1s 的文字」和「音频渐变超过段长」是同一个
    // 问题。共用 `FadeWindow.clamped`，所以这里的期望值可以直接拿它算。

    let greedy = TextAnimation(
        entrance: .fade, exit: .fade,
        entranceDuration: 2, exitDuration: 2,
        emphasis: .none, intensity: 0.6
    )
    let clamped = greedy.window(span: 1)
    checkClose(clamped.fadeIn + clamped.fadeOut, 1, 0.0001, "夹紧后两段之和不超过时长")
    checkClose(clamped.fadeIn, clamped.fadeOut, 0.0001, "等长的两段要按比例同时收")
    checkEqual(
        clamped, FadeWindow.clamped(fadeIn: 2, fadeOut: 2, span: 1),
        "文字动画的夹紧必须与声音/画面渐变逐字相同"
    )

    // MARK: 10 —— 打字机：字是一个一个出来的
    //
    // 不去猜每个字落在哪个像素，只问一件**一定成立**的事：可见墨迹的面积
    // 随进度单调不减。写反了顺序、错峰算错、或者把硬切写成淡变，都会破坏它。

    var typed = whiteTitle(start: 0, duration: 3, text: "ABCDEFGH")
    typed.animation = TextAnimation(
        entrance: .typewriter, exit: .none,
        entranceDuration: 1, exitDuration: 0.6,
        emphasis: .none, intensity: 0.6
    )
    var inkCounts: [Int] = []
    for step in 0...8 {
        let time = Double(step) / 8
        let state = TextAnimator.state(for: typed, at: time, canvas: canvas, frameRate: .fps30)
        guard let frame = TextRenderer.render(typed, canvas: canvas, state: state),
              let mask = alphaMask(frame.image) else { continue }
        inkCounts.append(mask.alpha.filter { $0 > 128 }.count)
    }
    check(inkCounts.count == 9, "打字机的每一步都该渲得出来")
    check(zip(inkCounts, inkCounts.dropFirst()).allSatisfy { $0 <= $1 },
          "打字机的可见墨迹必须单调不减，实际 \(inkCounts)")
    check((inkCounts.last ?? 0) > (inkCounts.first ?? 0) * 2,
          "打字机结束时的墨迹要明显多于开头，实际 \(inkCounts)")

    // MARK: 11 —— 数字格式化（checks/TextRender/NumberDelay.swift）
    checkNumberFormatting()

    // MARK: 12–15 —— 数字：插值终点、老虎机、等宽、位图尺寸落点（checks/TextRender/NumberDelay.swift）
    checkNumberRolling()

    // MARK: 16 —— 导出切段要把滚动窗口算进去
    //
    // 数字滚完之前画面每一帧都在变，哪怕入场动画早就结束了。只按入场时长
    // 切段的话，滚动的后半截会被冻成一张静止图 —— 数字会数到一半卡住。

    var exported = baseState(dark, seconds: 8)
    exported.frameRate = .fps30
    var exportNumber = whiteTitle(start: 1, duration: 5)
    exportNumber.number = NumberRoll(
        from: 0, to: 500, fractionDigits: 0, groupsThousands: false,
        prefix: "", suffix: "", style: .count, duration: 2, delay: 0.5
    )
    exportNumber.animation = TextAnimation(
        entrance: .fade, exit: .none,
        entranceDuration: 0.5, exitDuration: 0.6,
        emphasis: .none, intensity: 0.6
    )
    exported.textOverlays = [exportNumber]

    if let plan = await planKeepingWorkspace(exported, name: "number") {
        defer { try? FileManager.default.removeItem(at: plan.workspace) }
        // 入场 0.5s、等待 0.5s + 滚动 2s → 头部逐帧要按 2.5s 算：2.5 × 30 + 1 = 76 帧。
        checkEqual(pngCount(in: plan.workspace, prefix: "text0-in_"), 76,
                   "头部逐帧的长度要取「入场」和「等待 + 滚动」里更长的那个")
        checkEqual(pngCount(in: plan.workspace, prefix: "text0-mid"), 1,
                   "滚完之后画面不再变，中间仍是一张静止图")
    }

    // MARK: 16b —— 数字的等待（checks/TextRender/NumberDelay.swift）
    checkNumberDelay()

    // MARK: 16c —— 文字行：叠放序 = 行号（checks/TextRender/TextRows.swift）
    await checkTextRowsStacking(dark: dark)

    // MARK: 17 —— 对焦：边缓缓放大、边从模糊收清
    //
    // 三条契约，每一条都对应一个当时拍板的决定：
    //   · 终点**精确**收口（缩放到 1、模糊到 0、不透明度到 1）——
    //     差一点点就是"停在略糊略小的位置"，标题上极显眼；
    //   · 曲线**接近匀速**，不是别的入场用的 easeOutCubic ——
    //     后者把动作压在前三分之一，观感是"弹进来"，正好不是"缓慢"；
    //   · 起手不透明度**可调**，两头分别是"相机对焦"和"纯淡入"。

    var focusing = whiteTitle(start: 0, duration: 4)
    focusing.animation = TextAnimation(
        entrance: .focus, exit: .focus,
        entranceDuration: 1, exitDuration: 1,
        emphasis: .none, intensity: 0.8, focusStartOpacity: 0.35
    )

    func focusState(_ overlay: TextOverlay, at time: Double) -> TextAnimationState {
        TextAnimator.state(for: overlay, at: time, canvas: canvas, frameRate: .fps30)
    }

    let inStart = focusState(focusing, at: 0)
    let inMid = focusState(focusing, at: 0.5)
    // **量入场窗口里的最后一帧，不是窗口边界**：`t == 入场时长` 那一刻已经
    // 出了窗口，拿到的是静止态，断言就成了空的（第一版就是这么写的，
    // 把"缩放停在 0.98"的破坏改动放了过去）。
    let inLast = focusState(focusing, at: 1 - 1.0 / 30)
    let afterIn = focusState(focusing, at: 1)

    check(inStart.scale < 0.95, "入场起手要明显缩小，实际 \(inStart.scale)")
    check(inStart.blur > 1, "入场起手要明显模糊，实际 \(inStart.blur)")
    checkClose(inStart.opacity, 0.35, 0.001, "入场起手的不透明度等于设定的起手值")
    checkClose(inLast.scale, 1, 0.005, "入场最后一帧缩放已经收到 1")
    checkClose(inLast.blur, 0, 0.15, "入场最后一帧模糊已经收到 0")
    checkClose(inLast.opacity, 1, 0.01, "入场最后一帧完全不透明")
    check(afterIn.isIdentity, "入场窗口之外必须是静止态（中间那段才能当一张图导出）")

    // 曲线接近匀速的判据：中点正好落在两端的**中间**。
    // 不写死幅度常量 —— 那样改幅度就得改断言，而这里要守的是曲线形状。
    // easeOutCubic 的中点是 0.875，这两条会当场红。
    checkClose(inMid.scale, (inStart.scale + 1) / 2, 0.01,
               "缩放的中点要落在两端正中（曲线接近匀速，不是先快后慢）")
    checkClose(inMid.blur, inStart.blur / 2, 0.02 * max(1, inStart.blur),
               "模糊的中点要落在两端正中")

    // 出场**继续放大**（镜头一直往前推，最后失焦），不是缩回去。
    let outMid = focusState(focusing, at: 3.5)
    let outEnd = focusState(focusing, at: 3.999)
    check(outEnd.scale > 1.05, "出场要继续放大（不是缩回去），实际 \(outEnd.scale)")
    check(outEnd.blur > 1, "出场要糊掉，实际 \(outEnd.blur)")
    checkClose(outMid.scale, (1 + outEnd.scale) / 2, 0.02,
               "出场的缩放中点同样落在两端正中")

    // 速度可调：状态只由**相对进度**决定，不由绝对时间决定。
    // 写错成"按绝对秒数算"的话，改时长动画就会被截断或播不完。
    var slower = focusing
    slower.animation.entranceDuration = 3
    let slowMid = focusState(slower, at: 1.5)
    checkClose(slowMid.scale, inMid.scale, 0.001, "时长变了，同一相对进度处的缩放不变")
    checkClose(slowMid.blur, inMid.blur, 0.001, "时长变了，同一相对进度处的模糊不变")
    checkClose(slowMid.opacity, inMid.opacity, 0.001, "时长变了，同一相对进度处的不透明度不变")

    // 起手不透明度的两头。
    var opaqueStart = focusing
    opaqueStart.animation.focusStartOpacity = 1
    checkClose(focusState(opaqueStart, at: 0).opacity, 1, 0.001,
               "调到 100% 就是纯相机对焦：起手完全不透明，只有模糊在收")
    check(focusState(opaqueStart, at: 0).blur > 1, "调到 100% 时模糊照旧")
    var fadeStart = focusing
    fadeStart.animation.focusStartOpacity = 0
    checkClose(focusState(fadeStart, at: 0).opacity, 0, 0.001,
               "调到 0 就是从全透明淡进来")

    // 包络要同时留下模糊和出场放大的余量，否则被位图边缘切掉一条直边。
    var focusClipped: [String] = []
    for step in 0...32 {
        let time = Double(step) * 0.125
        let state = focusState(focusing, at: time)
        guard state.opacity > 0.02,
              let frame = TextRenderer.render(focusing, canvas: canvas, state: state) else { continue }
        if !borderIsClear(frame.image) { focusClipped.append(String(format: "%.2fs", time)) }
    }
    check(focusClipped.isEmpty, "对焦期间位图最外圈必须始终全透明，被裁的时刻：\(focusClipped)")

    // 只做入场对焦时，包络**不该**按出场放大留余量 —— 那会白白多出一圈空位图。
    var entranceOnly = focusing
    entranceOnly.animation.exit = .none
    let bothSizes = TextRenderer.render(focusing, canvas: canvas, state: afterIn)?.size
    let entranceSizes = TextRenderer.render(entranceOnly, canvas: canvas, state: afterIn)?.size
    if let bothSizes, let entranceSizes {
        check(entranceSizes.width < bothSizes.width,
              "只做入场对焦时位图该更小（\(entranceSizes) vs \(bothSizes)）")
    } else {
        check(false, "对焦的位图渲不出来")
    }

    // MARK: 18 —— 预览上的可点范围（HitGeometry.swift）
    checkHitGeometry()

    print("\(checks - failures)/\(checks) 通过")
    finish(failures == 0 ? 0 : 1)
}

await main()
