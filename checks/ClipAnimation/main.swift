import AVFoundation
import CoreGraphics
import Foundation
import SrtFlowCore

// **入场 / 出场动画：两条管线逐点对账。**
//
// 同一份时间线跑两遍 —— 一遍建 AVComposition 真取帧（预览那条），一遍调
// `VideoEditExportGraph.plan()` 真跑 ffmpeg 出成片再抽帧（导出那条）——
// 同一个时刻、同一块区域，两边的数必须对得上。
//
// 逐帧效果的成片是**预渲染**出来的（用预览同一套合成渲中间片），"按构造一致"
// 只是设计意图：中间隔着 ProRes 转码、alphamerge、overlay 一整条链，任何一环
// 错位都是「预览看着对、成片不对」。这里就是那份构造一致性的机器证明。
//
// 编译方式见 scripts/check-clip-animation.sh。长期约束见
// docs/architecture/clip-animation.md。
//
// ## 两边的量法为什么能直接比
//
// 预览读的是 AVFoundation 的全范围 RGB，成品是 yuv420p；`format=gray` 转出来
// 已经拉回全范围（纯白实测 0.98、纯黑 0.02），所以同一块区域的平均值可以直接
// 相减。容差 `pipelineTolerance` 收的就是这点系统性压缩 + 抽帧落点差半帧。

var failures = 0
var checks = 0

func check(_ condition: Bool, _ message: String, line: Int = #line) {
    checks += 1
    if !condition {
        failures += 1
        print("FAIL [line \(line)] \(message)")
    }
}

/// 两条管线之间允许的差。0.10 是实测系统性压缩（≈0.02）加上抽帧落点差半帧
/// 在缓动最陡处造成的偏移（≈0.05）之后留的余量 —— 再放宽就盖不住真分叉了。
let pipelineTolerance = 0.10

let ffmpegPath = ProcessInfo.processInfo.environment["SRTFLOW_FFMPEG"]
    ?? FileManager.default.currentDirectoryPath + "/vendor/ffmpeg"

let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("srtflow-clipanim-\(UUID().uuidString)", isDirectory: true)
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

// MARK: - 预览侧探针

/// 归一化区域（左上原点 0…1）的平均亮度。与导出侧 `exportProbe` 量的是同一块。
func previewProbe(
    _ built: VideoEditCompositionBuilder.Built, at seconds: Double, region: CGRect
) async -> Double {
    let generator = AVAssetImageGenerator(asset: built.composition)
    generator.videoComposition = built.videoComposition
    // 半帧以内：24fps 工程上探针时刻都取整帧，落点必须和导出抽的是同一帧。
    generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 60)
    generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 60)
    guard let image = try? await generator.image(
        at: CMTime(seconds: seconds, preferredTimescale: 600)
    ).image else { return -1 }

    let rect = CGRect(
        x: region.minX * Double(image.width), y: region.minY * Double(image.height),
        width: max(1, region.width * Double(image.width)),
        height: max(1, region.height * Double(image.height))
    )
    guard let cropped = image.cropping(to: rect) else { return -1 }
    var pixel = [UInt8](repeating: 0, count: 4)
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
              data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          ) else { return -1 }
    context.interpolationQuality = .medium
    context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    return (Double(pixel[0]) + Double(pixel[1]) + Double(pixel[2])) / 3 / 255
}

// MARK: - 导出侧：真跑一遍生产导出

/// 跑一遍**生产**导出，返回成品路径和真实滤镜参数。
func exportProduct(_ state: TimelineState, name: String) async -> (url: URL, args: [String])? {
    let output = root.appendingPathComponent("\(name).mp4")
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
    // `tempOutput` 就在 workspace 里，清掉 workspace 等于把成品一起删了。
    let kept = root.appendingPathComponent("product-\(name).mp4")
    try? FileManager.default.removeItem(at: kept)
    do {
        try FileManager.default.copyItem(at: plan.tempOutput, to: kept)
    } catch {
        try? FileManager.default.removeItem(at: plan.workspace)
        check(false, "\(name) 的成品搬不出来：\(error)")
        return nil
    }
    let args = plan.arguments
    try? FileManager.default.removeItem(at: plan.workspace)
    return (kept, args)
}

/// 成品某时刻、某归一化区域的平均亮度。与 `previewProbe` 量的是同一块。
func exportProbe(
    _ url: URL, at seconds: Double, region: CGRect, canvas: CGSize, name: String
) -> Double {
    let x = Int((region.minX * canvas.width).rounded())
    let y = Int((region.minY * canvas.height).rounded())
    let w = max(1, Int((region.width * canvas.width).rounded()))
    let h = max(1, Int((region.height * canvas.height).rounded()))
    let raw = root.appendingPathComponent("\(name)-\(x)x\(y)-\(seconds).gray")
    let (code, out) = run(ffmpegPath, [
        "-hide_banner", "-loglevel", "error", "-y",
        "-ss", String(seconds), "-i", url.path,
        "-frames:v", "1", "-vf", "crop=\(w):\(h):\(x):\(y),format=gray,scale=1:1",
        "-f", "rawvideo", "-pix_fmt", "gray", raw.path
    ])
    guard code == 0, let data = try? Data(contentsOf: raw), let byte = data.first else {
        check(false, "\(name) 在 \(seconds)s 取区域失败：\(out.suffix(300))")
        return -1
    }
    return Double(byte) / 255
}

// MARK: - 对账

/// 一个探针：时刻 + 区域 + 这一处该亮还是该暗（nil = 只对账、不判绝对值）。
struct Probe {
    var seconds: Double
    var region: CGRect
    var expect: String?
    var label: String
}

let full = CGRect(x: 0, y: 0, width: 1, height: 1)
func band(x: Double, width: Double = 0.12) -> CGRect {
    CGRect(x: x, y: 0.35, width: width, height: 0.3)
}
func row(y: Double, height: Double = 0.1) -> CGRect {
    CGRect(x: 0.3, y: y, width: 0.4, height: height)
}

func reconcile(
    _ state: TimelineState, name: String, canvas: CGSize, probes: [Probe]
) async -> [String] {
    var graphArgs: [String] = []
    guard let built = await VideoEditCompositionBuilder.build(from: state) else {
        check(false, "\(name)：预览合成建不起来")
        return graphArgs
    }
    guard let product = await exportProduct(state, name: name) else { return graphArgs }
    graphArgs = product.args
    for probe in probes {
        let preview = await previewProbe(built, at: probe.seconds, region: probe.region)
        let export = exportProbe(
            product.url, at: probe.seconds, region: probe.region, canvas: canvas, name: name
        )
        guard preview >= 0, export >= 0 else {
            check(false, "\(name) \(probe.label)：探针取不到值（预览 \(preview) / 成片 \(export)）")
            continue
        }
        check(
            abs(preview - export) < pipelineTolerance,
            "\(name) \(probe.label)：两条管线必须同账，预览 \(preview) / 成片 \(export)"
        )
        switch probe.expect {
        case "bright":
            check(preview > 0.7 && export > 0.7,
                  "\(name) \(probe.label)：两边都该是亮的，预览 \(preview) / 成片 \(export)")
        case "dark":
            check(preview < 0.3 && export < 0.3,
                  "\(name) \(probe.label)：两边都该是暗的，预览 \(preview) / 成片 \(export)")
        default:
            break
        }
    }
    return graphArgs
}

func main() async {
    guard FileManager.default.isExecutableFile(atPath: ffmpegPath) else {
        print("找不到 ffmpeg：\(ffmpegPath)（跑 scripts/vendor-ffmpeg.sh，或设 SRTFLOW_FFMPEG）")
        finish(1)
    }

    // 画布给到 256×144：几何探针要量得出边界，64×36 上一个像素就是 1.5%。
    let canvas = CGSize(width: 256, height: 144)
    let meta = info(canvas, seconds: 4)
    let white: URL
    let black: URL
    do {
        white = try await makeSolidVideo(white: 1, seconds: 4, name: "white.mp4", size: canvas)
        black = try await makeSolidVideo(white: 0, seconds: 4, name: "black.mp4", size: canvas)
    } catch {
        check(false, "造素材失败：\(error)")
        finish(1)
    }

    func mainClip(_ mutate: (inout EditClip) -> Void) -> TimelineState {
        var clip = EditClip(sourceURL: white, sourceDuration: 4, timelineStart: 0, info: meta)
        mutate(&clip)
        var state = TimelineState()
        state.mainClips = [clip]
        return state
    }

    // MARK: 1. Fade：走 ffmpeg 快路径，**不预渲染**
    //
    // 这一条同时守两件事：曲线在两条管线里同账（线性斜坡），以及"纯淡变不该
    // 因为这套动画变慢" —— 图里必须还是 `fade=…:alpha=1`，不许出现中间片。
    do {
        let state = mainClip {
            $0.presetAnimation.entrance = .fade
            $0.videoFadeInDuration = 2
        }
        let args = await reconcile(state, name: "fade", canvas: canvas, probes: [
            Probe(seconds: 0.5, region: full, expect: nil, label: "淡入 1/4"),
            Probe(seconds: 1.0, region: full, expect: nil, label: "淡入半程"),
            Probe(seconds: 1.5, region: full, expect: nil, label: "淡入 3/4"),
            Probe(seconds: 3.0, region: full, expect: "bright", label: "结束后")
        ])
        let graph = args.firstIndex(of: "-filter_complex").map { args[$0 + 1] } ?? ""
        check(graph.contains("fade=t=in:st=0:d=2:alpha=1"),
              "纯淡变必须还走 ffmpeg 的 fade 快路径")
        check(!args.contains { $0.contains("prerender-") },
              "纯淡变不许走预渲染（整段重渲一遍，白白变慢）")
    }

    // MARK: 2. Wipe：几何量，左右两边一量就知道对不对
    do {
        let state = mainClip {
            $0.presetAnimation.entrance = .wipe
            $0.videoFadeInDuration = 2
        }
        let args = await reconcile(state, name: "wipe", canvas: canvas, probes: [
            Probe(seconds: 1.0, region: band(x: 0.1), expect: "bright", label: "半程左侧"),
            Probe(seconds: 1.0, region: band(x: 0.78), expect: "dark", label: "半程右侧"),
            Probe(seconds: 0.5, region: band(x: 0.1), expect: "bright", label: "1/4 处左侧"),
            Probe(seconds: 0.5, region: band(x: 0.4), expect: "dark", label: "1/4 处中间偏右"),
            Probe(seconds: 3.0, region: full, expect: "bright", label: "结束后")
        ])
        check(args.contains { $0.contains("prerender-") },
              "擦除必须走预渲染（ffmpeg 没有干净的逐帧裁切斜坡）")
    }

    // MARK: 3. Rise：铺满画布的段，两条管线都不许露出黑边
    //
    // 上浮是"从下面浮上来"，动画中这一段是压低的，缺口在**上边**。补偿到位的话
    // 上边和中心全程一样亮 —— 而它们的绝对值一直在变（自带淡入），所以这条
    // 断言同时也在对账那条曲线。
    do {
        let state = mainClip {
            $0.presetAnimation.entrance = .rise
            $0.presetAnimation.intensity = 1
            $0.videoFadeInDuration = 2
        }
        await reconcile(state, name: "rise", canvas: canvas, probes: [
            Probe(seconds: 0.5, region: row(y: 0.0), expect: nil, label: "半途上边"),
            Probe(seconds: 0.5, region: row(y: 0.45), expect: nil, label: "半途中心"),
            Probe(seconds: 0.5, region: row(y: 0.9), expect: nil, label: "半途下边"),
            Probe(seconds: 3.0, region: full, expect: "bright", label: "结束后")
        ])
        // 同一条时间线里，上/下边和中心必须一样亮（露边的话上边会暗一截）。
        if let built = await VideoEditCompositionBuilder.build(from: state) {
            for at in [0.3, 0.5, 0.8] {
                let center = await previewProbe(built, at: at, region: row(y: 0.45))
                for (region, label) in [(row(y: 0.0), "上边"), (row(y: 0.9), "下边")] {
                    let edge = await previewProbe(built, at: at, region: region)
                    check(abs(edge - center) < 0.08,
                          "上浮 \(at)s：\(label)不许比中心暗（露黑边），实测 \(edge) vs \(center)")
                }
            }
        }
    }

    // MARK: 4. Zoom：缓推，曲线在两条管线里同账
    do {
        let state = mainClip {
            $0.presetAnimation.entrance = .zoom
            $0.presetAnimation.intensity = 1
            $0.videoFadeInDuration = 2
        }
        await reconcile(state, name: "zoom", canvas: canvas, probes: [
            Probe(seconds: 0.5, region: full, expect: nil, label: "缓推 1/4"),
            Probe(seconds: 1.0, region: full, expect: nil, label: "缓推半程"),
            Probe(seconds: 3.0, region: full, expect: "bright", label: "结束后")
        ])
    }

    // MARK: 5. Pop 在上层轨：fill + matte 那条路也得同账
    //
    // 上层轨的动画段在导出侧要走 fill + matte 双预渲染再 alphamerge 合回来 ——
    // 权重对不齐就是这里露馅（画中画边缘发灰、整体偏亮或偏暗）。
    // 角落里的小图不铺满画布，所以 Pop 走的是"从小弹出来"那一支。
    do {
        var top = EditClip(sourceURL: white, sourceDuration: 4, timelineStart: 0, info: meta)
        top.placement = ClipPlacement(centerX: 0.5, centerY: 0.5, width: 0.5, height: 0.5)
        top.presetAnimation.entrance = .pop
        top.presetAnimation.intensity = 1
        top.videoFadeInDuration = 2
        var state = TimelineState()
        state.mainClips = [
            EditClip(sourceURL: black, sourceDuration: 4, timelineStart: 0, info: meta)
        ]
        state.overlayTracks = [EditLane(clips: [top])]
        let args = await reconcile(state, name: "pop-overlay", canvas: canvas, probes: [
            Probe(seconds: 0.5, region: band(x: 0.44, width: 0.12), expect: nil, label: "弹入中心"),
            Probe(seconds: 1.0, region: band(x: 0.44, width: 0.12), expect: nil, label: "落位中心"),
            Probe(seconds: 3.0, region: band(x: 0.44, width: 0.12), expect: "bright", label: "结束后中心"),
            Probe(seconds: 3.0, region: band(x: 0.05, width: 0.1), expect: "dark", label: "结束后画布边缘（露出主轨的黑）")
        ])
        check(args.contains { $0.contains("-fill.mov") } && args.contains { $0.contains("-matte.mov") },
              "上层轨的动画段必须走 fill + matte 双预渲染")
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
