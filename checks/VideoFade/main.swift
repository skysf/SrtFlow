import AVFoundation
import Foundation
import SrtFlowCore

// **上层视频轨 + 画面渐变的真实回归**：不测纯函数，测真导出的成片就是那样。
//
// 调真实的 `VideoEditExportGraph.plan()` 拿生产 ffmpeg 参数，真跑一遍，
// 再把成品抽帧量像素。场景与 `scripts/check-preview-composition.sh` 里的
// **逐一对应** —— 两条管线同账是这套东西的核心合同，分叉了就是
// 「预览看着对、成片不对」。
//
// 两边的探针方式故意不同：预览那边读 AVFoundation 的全范围 RGB，量整幅平均
// 亮度；这边的成品是 yuv420p **有限范围**（白≈235、黑≈16），整幅平均会随色彩
// 范围漂，所以改量逐个像素的明暗。同一份几何，两种量法都得成立。
//
// 守的三条契约（改 VideoEditExportGraph 的上层轨滤镜段之前必读）：
// 1. 上层视频轨的默认摆放 = 等比铺满画布居中（不是画中画的角落小框），
//    比例对不上的两侧**留空露出下层**，不补黑。
// 2. 画面渐变在 alpha 上做：渐变露出来的是下面那一层。上层轨底下是主轨画面，
//    主轨底下是画布黑底 —— 同一条斜坡、两种观感。
// 3. 主轨接缝上有转场时，那一边的画面渐变让位给 xfade（不叠加）。
//
// 编译方式见 scripts/check-video-fade.sh。长期约束见
// docs/architecture/video-fades.md 与 docs/architecture/preview-free-transform.md。

var failures = 0
var checks = 0

func check(_ condition: Bool, _ message: String, line: Int = #line) {
    checks += 1
    if !condition {
        failures += 1
        print("FAIL [line \(line)] \(message)")
    }
}

let ffmpegPath = ProcessInfo.processInfo.environment["SRTFLOW_FFMPEG"]
    ?? FileManager.default.currentDirectoryPath + "/vendor/ffmpeg"

let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("srtflow-videofade-\(UUID().uuidString)", isDirectory: true)
try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

/// 所有出口都是 exit()，而 exit() 不跑 defer —— 统一走 finish() 清临时目录。
func finish(_ code: Int32) -> Never {
    try? FileManager.default.removeItem(at: root)
    exit(code)
}

@discardableResult
func run(_ launchPath: String, _ args: [String]) -> (Int32, String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = args
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
/// （造素材和被测对象共用一个工具，工具出错会两边一起错，看不出来）。
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

/// 跑一遍**生产**导出，返回成品路径。
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
    let (code, out) = run(ffmpegPath, plan.arguments)
    guard code == 0 else {
        try? FileManager.default.removeItem(at: plan.workspace)
        check(false, "\(name) 的 ffmpeg 执行失败：\(out.suffix(800))")
        return nil
    }
    // `tempOutput` 就在 workspace 里，清掉 workspace 等于把成品一起删了 ——
    // 先搬出来再清（第一版直接 return 它，抽帧全在报「文件不存在」）。
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

/// 成品在某一时刻那一帧的整幅平均亮度（0…1）。
func brightness(_ url: URL, at seconds: Double, name: String) -> Double? {
    let raw = root.appendingPathComponent("\(name)-\(seconds).gray")
    let (code, out) = run(ffmpegPath, [
        "-hide_banner", "-loglevel", "error", "-y",
        "-ss", String(seconds), "-i", url.path,
        "-frames:v", "1", "-vf", "format=gray,scale=1:1",
        "-f", "rawvideo", "-pix_fmt", "gray", raw.path
    ])
    guard code == 0, let data = try? Data(contentsOf: raw), let byte = data.first else {
        check(false, "\(name) 在 \(seconds)s 抽帧失败：\(out.suffix(300))")
        return nil
    }
    return Double(byte) / 255
}

/// 成品在某一时刻、某个像素的亮度（0…1）。
///
/// 量几何用它、不用整幅平均：成品是 yuv420p 有限范围（白≈235、黑≈16），
/// 整幅平均值会随色彩范围漂，算出来的「黑块占比」对不上。逐像素只问
/// 「这里亮还是暗」，范围怎么变都成立。
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

/// 这份时间线的生产滤镜图（字符串断言用）。
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

func main() async {
    guard FileManager.default.isExecutableFile(atPath: ffmpegPath) else {
        print("找不到 ffmpeg：\(ffmpegPath)（跑 scripts/vendor-ffmpeg.sh，或设 SRTFLOW_FFMPEG）")
        finish(1)
    }

    let canvas = CGSize(width: 64, height: 36)
    let landscape = info(canvas, seconds: 4)
    var portraitInfo = landscape
    portraitInfo.displaySize = CGSize(width: 36, height: 64)

    let white: URL
    let black: URL
    let portraitBlack: URL
    do {
        white = try await makeSolidVideo(white: 1, seconds: 4, name: "white.mp4", size: canvas)
        black = try await makeSolidVideo(white: 0, seconds: 4, name: "black.mp4", size: canvas)
        portraitBlack = try await makeSolidVideo(
            white: 0, seconds: 4, name: "portrait.mp4", size: CGSize(width: 36, height: 64)
        )
    } catch {
        check(false, "造素材失败：\(error)")
        finish(1)
    }

    // MARK: 1. 上层轨铺满画布，两侧留空露出主轨
    //
    // 黑色竖版（36×64）铺在白色主轨（画布 64×36）上：contain 之后高度顶满、
    // 宽 = 36 × (36/64) = 20.25，占画布宽 31.6%，整幅亮度 ≈ 0.684。
    // 这个数和 check-preview-composition.sh 里同一场景的断言**是同一个**。
    do {
        var state = TimelineState()
        state.mainClips = [
            EditClip(sourceURL: white, sourceDuration: 4, timelineStart: 0, info: landscape)
        ]
        state.overlayTracks = [EditLane(clips: [
            EditClip(sourceURL: portraitBlack, sourceDuration: 4, timelineStart: 0, info: portraitInfo)
        ])]
        if let product = await export(state, name: "upper-fill.mp4") {
            // 20 宽居中在 64 宽画布上 → 黑块占 x ∈ [22, 42)。四个探针把
            // 「居中 + 铺满高度 + 两侧露出主轨」三件事一次钉死：
            //   · 顶行和底行的中心必须是黑 → 高度真顶满了（画中画只占 40% 高）；
            //   · 最左最右必须是白 → 两侧留空且**没补黑**（补了主轨就没了）；
            //   · 画中画时代黑块停在右上角，右侧探针会是黑 —— 直接排掉。
            for (x, y, label) in [(32, 1, "顶行中心"), (32, 34, "底行中心"), (23, 18, "黑块左缘内")] {
                if let level = pixel(product, x: x, y: y, at: 2, name: "upper-fill") {
                    check(level < 0.3, "\(label)应当是上层轨的黑，实测 \(level)")
                }
            }
            for (x, y, label) in [(1, 18, "最左"), (62, 18, "最右"), (18, 18, "黑块左缘外")] {
                if let level = pixel(product, x: x, y: y, at: 2, name: "upper-fill") {
                    check(level > 0.7, "\(label)应当露出主轨的白，实测 \(level)")
                }
            }
        }
        // 九宫格的痕迹必须一点不剩：停靠表达式和 decrease 缩放都不该再出现。
        if let graph = await filterGraph(state, name: "upper-fill-graph") {
            check(
                !graph.contains("W-w-") && !graph.contains("H-h-"),
                "上层轨滤镜里不该再有九宫格停靠表达式"
            )
            // 上层轨缩到 contain 之后的**精确像素**：36×64 收进 64×36 是
            // 20.25×36，过 evenPixel 取偶得 20×36。画中画时代这里是
            // 「画布宽 40%」= 25 宽。别改成查 decrease —— 主轨自己的轻量
            // 路径也用那个参数，查它会永远绿。
            check(
                graph.contains("scale=20:36"),
                "上层轨要缩到等比 contain 的精确尺寸 20x36（画中画时代是 25 宽）"
            )
        }
    }

    // MARK: 2. 上层轨的画面渐变露出**下面那一层**，不是黑场
    //
    // 黑色满幅盖在白色主轨上，2s 渐入：起点应当是主轨的白，半程居中，
    // 结束后全黑。渐变若被实现成「淡向黑色」，起点就会是黑的。
    do {
        var top = EditClip(sourceURL: black, sourceDuration: 4, timelineStart: 0, info: landscape)
        top.videoFadeInDuration = 2
        var state = TimelineState()
        state.mainClips = [
            EditClip(sourceURL: white, sourceDuration: 4, timelineStart: 0, info: landscape)
        ]
        state.overlayTracks = [EditLane(clips: [top])]
        if let product = await export(state, name: "upper-fade.mp4") {
            if let level = brightness(product, at: 0.05, name: "upper-fade-start") {
                check(level > 0.9, "渐入起点上层全透明，应当看到主轨的白，实测 \(level)")
            }
            if let level = brightness(product, at: 1.0, name: "upper-fade-mid") {
                check(level > 0.35 && level < 0.65, "渐入半程应当在两者中间，实测 \(level)")
            }
            if let level = brightness(product, at: 3.0, name: "upper-fade-end") {
                check(level < 0.1, "渐变结束后上层不透明，应当全黑，实测 \(level)")
            }
        }
    }

    // MARK: 3. 主轨的画面渐变淡向黑（底下垫的是画布黑底）
    //
    // 同一条 alpha 斜坡、同一个滤镜，只是底下垫的东西不同 —— 这一组和上一组
    // 合起来才说明「渐变露出的是下层」这个模型是对的。
    do {
        var clip = EditClip(sourceURL: white, sourceDuration: 4, timelineStart: 0, info: landscape)
        clip.videoFadeInDuration = 2
        var state = TimelineState()
        state.mainClips = [clip]
        if let product = await export(state, name: "main-fade.mp4") {
            if let level = brightness(product, at: 0.05, name: "main-fade-start") {
                check(level < 0.15, "主轨渐入起点应当是黑场，实测 \(level)")
            }
            if let level = brightness(product, at: 3.0, name: "main-fade-end") {
                check(level > 0.9, "主轨渐变结束后应当是原画面（白），实测 \(level)")
            }
        }
    }

    // MARK: 4. 转场仲裁：接缝那一边的画面渐变让位给 xfade
    //
    // 叠加会在接缝处把画面压暗一块。判据与声音同源，这里钉的是滤镜图：
    // 有转场的那条边不该再出现段内的 fade。
    do {
        var first = EditClip(sourceURL: white, sourceDuration: 2, timelineStart: 0, info: info(canvas, seconds: 2))
        first.transitionAfter = .crossFade
        first.transitionDuration = 0.5
        // 结尾这条边归转场管 —— 设了也不该生效。
        first.videoFadeOutDuration = 1
        // 开头没有转场 —— 必须生效。
        first.videoFadeInDuration = 1
        let second = EditClip(
            sourceURL: black, sourceDuration: 2, timelineStart: 1.5, info: info(canvas, seconds: 2)
        )
        var state = TimelineState()
        state.mainClips = [first, second]
        if let graph = await filterGraph(state, name: "seam-graph") {
            check(graph.contains("fade=t=in:st=0:d=1:alpha=1"), "没有转场的那一边，渐入必须照常出现")
            check(!graph.contains("fade=t=out"), "接缝那一边的渐出必须让位给转场，不许叠加")
            check(graph.contains("xfade=transition=fade"), "接缝上的转场本身要还在")
        }
    }

    if failures == 0 {
        print("\(checks) checks, 0 failures")
        print("All checks passed")
        finish(0)
    }
    print("\(checks) checks, \(failures) failures")
    finish(1)
}

await main()
