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

/// 容量是不是「能放、最长约 `expected` 秒」。容量是乘出来的（长度 × 0.4），
/// 1.5 × 0.4 在 Double 里是 0.6000000000000001 —— 枚举的 `==` 是精确比较，
/// 拿它断言浮点结果会假红。
func capacity(_ value: TransitionCapacity, isAbout expected: Double) -> Bool {
    if case .available(let maxDuration) = value { return abs(maxDuration - expected) < 1e-9 }
    return false
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

    // MARK: 4b. 磁吸**关着**（两段首尾相接、并不相叠）时的转场
    //
    // 回归守卫，事故是 2026-09-20 查出来的：这条缝上两条管线以前不同解 ——
    // 导出要求两段**真的相叠**才发 xfade（上面 4. 那种几何是磁吸 packMain 排
    // 出来的），预览侧没有这个判据、照挂淡变。于是磁吸关着（**默认配置**）
    // 设转场：预览看得见效果，成片是硬切。
    //
    // 现在两条管线在入口共用 `expandingTransitionHandles()`：向两边借裁掉的
    // 素材，展开后两段真相叠，而片段位置和总时长都不动。
    do {
        // 两段各留 0.25s 余料：素材 2s，只取中间 1.5s。
        func trimmed(_ url: URL, at start: Double) -> EditClip {
            var clip = EditClip(
                sourceURL: url, sourceDuration: 1.5, timelineStart: start, info: info(canvas, seconds: 2)
            )
            clip.sourceStart = 0.25
            return clip
        }
        var first = trimmed(white, at: 0)
        first.transitionAfter = .crossFade
        first.transitionDuration = 0.4
        let second = trimmed(black, at: 1.5)   // 首尾相接，gap = 0
        var state = TimelineState()
        state.mainClips = [first, second]

        // 容量只看长度（1.5s × 0.4 = 0.6）：余料不够的部分现在由定格补足，余料只决定
        // 借多少真素材。这里 0.4s 的转场两边余料加起来 0.5s 够用 —— 一帧都不定格。
        check(
            capacity(state.transitionCapacity(afterMainIndex: 0), isAbout: 0.6),
            "两边各 0.25s 余料 → 容量按长度 = 1.5s × 0.4"
        )
        let borrowed = state.expandingTransitionHandles()
        check(borrowed.mainClips.allSatisfy { $0.renderHoldHead == 0 && $0.renderHoldTail == 0 },
              "余料够用时一帧都不定格")
        // 「不挪用户在轨道上的片段」是拍过板的口径：展开只改素材取值范围。
        check(
            abs(state.expandingTransitionHandles().duration - state.duration) < 0.001,
            "借余料不许改变时间线总长"
        )
        if let graph = await filterGraph(state, name: "handles-graph") {
            check(graph.contains("xfade=transition=fade"), "首尾相接 + 有余料 → 导出必须真的发 xfade")
        }
    }

    // 4b-2. 余料**只在一边**：窗口整个落在接缝的一侧，照样是完整的交叉淡变。
    //
    // 进场段在那段时间本来就在播它自己的开头，出场段拿尾料叠上去淡出 —— 两边
    // 的可见内容一帧都没少。按 2×min(尾料, 头料) 算容量会把这种缝白白判死，
    // 那是 2026-09-20 第一版的毛病。
    do {
        var first = EditClip(
            sourceURL: white, sourceDuration: 1.5, timelineStart: 0, info: info(canvas, seconds: 2)
        )
        first.transitionAfter = .crossFade
        first.transitionDuration = 0.4
        // 进场段从素材第 0 帧开始 —— **没有头料**，全部得从出场段的尾巴借。
        let second = EditClip(
            sourceURL: black, sourceDuration: 2, timelineStart: 1.5, info: info(canvas, seconds: 2)
        )
        var state = TimelineState()
        state.mainClips = [first, second]

        check(second.leadingHandle == 0, "这一版里进场段确实没有头料")
        check(
            capacity(state.transitionCapacity(afterMainIndex: 0), isAbout: 0.6),
            "只有出场段有尾料 → 容量按长度 = 1.5s × 0.4"
        )
        // 0.4s 全从出场段 0.5s 的尾料里借：窗口整个落在接缝之后，一帧都不定格。
        let oneSided = state.expandingTransitionHandles()
        check(oneSided.mainClips.allSatisfy { $0.renderHoldHead == 0 && $0.renderHoldTail == 0 },
              "单边余料够用时同样一帧都不定格")
        check(
            abs(state.expandingTransitionHandles().duration - state.duration) < 0.001,
            "单边借料同样不许改变时间线总长"
        )
        if let graph = await filterGraph(state, name: "one-sided-graph") {
            check(graph.contains("xfade=transition=fade"), "单边有余料 → 导出必须真的发 xfade")
        }
    }

    // 4b-3. 零余料 + 压黑：走原地斜坡，一点料都不借、也不定格
    //
    // 压黑就是「A 灭到黑、B 从黑亮起」，两段各做一道 alpha 斜坡就够了 —— 主轨
    // 片段底下垫的正是黑底。所以它在**完全没有余料**的缝上优先走这条路。叠化、
    // 推移、擦除要两段同时在画面上，走的是「借料 + 定格补足」（见 4b-5）。
    do {
        var first = EditClip(sourceURL: white, sourceDuration: 2, timelineStart: 0, info: info(canvas, seconds: 2))
        first.transitionAfter = .blackFade
        first.transitionDuration = 0.5
        let second = EditClip(sourceURL: black, sourceDuration: 2, timelineStart: 2, info: info(canvas, seconds: 2))
        var state = TimelineState()
        state.mainClips = [first, second]

        check(first.trailingHandle == 0 && second.leadingHandle == 0, "这一版里两边确实都没有余料")
        check(capacity(state.transitionCapacity(afterMainIndex: 0, kind: .blackFade), isAbout: 0.8),
              "零余料的缝上压黑必须可用")
        check(capacity(state.transitionCapacity(afterMainIndex: 0, kind: .crossFade), isAbout: 0.8),
              "同一条缝上叠化也可用（2026-09-23 起余料不够用首尾帧定格补足），容量按长度 = 2s × 0.4")

        let expanded = state.expandingTransitionHandles()
        check(expanded.mainClips[0].transitionAfter == .none, "压黑从渲染副本里摘掉，接缝上不发 xfade")
        check(abs(expanded.mainClips[0].videoFadeOutDuration - 0.25) < 0.001, "出场段灭掉后半程")
        check(abs(expanded.mainClips[1].videoFadeInDuration - 0.25) < 0.001, "进场段亮起前半程")
        check(abs(expanded.duration - state.duration) < 0.001, "原地斜坡同样不许改变总时长")

        // 遮罩的**画法**：宽度有下限，位置必须按窗口中心补偿。
        //
        // 回归守卫，用户 2026-09-20 报的：「调时长的时候遮罩移动了」。当时左边界
        // 钉在 window.start、宽度另外夹下限，下限多出来的宽度全长在右边 —— 转场
        // 越短偏得越厉害，看起来就是遮罩整个往右挪。
        do {
            let window = (start: 1.75, duration: 0.5)
            // 时间线放得够大：宽度不碰下限，左边界就该正好是 window.start。
            let wide = TimelineState.transitionMaskRect(window: window, pps: 200, minWidth: 18)
            check(abs(wide.width - 100) < 0.001, "不碰下限时宽度 = d × pps")
            check(abs(wide.x - 350) < 0.001, "不碰下限时左边界 = window.start × pps")
            // 缩得很小：宽度贴下限，但**中心仍然压在缝上**。
            let narrow = TimelineState.transitionMaskRect(window: window, pps: 6, minWidth: 18)
            check(abs(narrow.width - 18) < 0.001, "很窄时宽度取下限")
            let seam = (window.start + window.duration / 2) * 6
            check(abs((narrow.x + narrow.width / 2) - seam) < 0.001, "贴下限时中心仍然对准缝，不许整块右移")
        }

        // 时间线遮罩画在哪：跨在缝上、两边各一半（压黑那条路也是 d/2 + d/2）。
        if let window = state.transitionWindow(afterMainIndex: 0) {
            check(abs(window.start - (2.0 - 0.25)) < 0.001, "遮罩左边界 = 缝 - d/2")
            check(abs(window.duration - 0.5) < 0.001, "遮罩宽度 = d")
        } else {
            check(false, "压黑的缝上应该有遮罩窗口")
        }

        if let graph = await filterGraph(state, name: "dip-graph") {
            check(!graph.contains("xfade="), "压黑走原地斜坡 → 不该发 xfade")
            check(graph.contains("fade=t=out"), "出场段要有渐出")
            check(graph.contains("fade=t=in"), "进场段要有渐入")
        }
    }

    // 4b-4. 已相叠（磁吸排的）几何：遮罩窗口就是重叠区本身，不是「缝 ± d/2」
    do {
        var first = EditClip(sourceURL: white, sourceDuration: 2, timelineStart: 0, info: info(canvas, seconds: 2))
        first.transitionAfter = .crossFade
        first.transitionDuration = 0.5
        let second = EditClip(sourceURL: black, sourceDuration: 2, timelineStart: 1.5, info: info(canvas, seconds: 2))
        var state = TimelineState()
        state.mainClips = [first, second]
        if let window = state.transitionWindow(afterMainIndex: 0) {
            check(abs(window.start - 1.5) < 0.001, "相叠时遮罩从进场段的起点开始")
            check(abs(window.duration - 0.5) < 0.001, "相叠时遮罩宽度 = 实际重叠量")
        } else {
            check(false, "相叠的缝上应该有遮罩窗口")
        }
    }

    // 4b-5. 零余料 + 叠化：**首尾帧定格补足**（2026-09-23 用户拍板）
    //
    // 两段都用满了素材，一点余料都没有。以前这条缝上只有压黑能用；现在照
    // Premiere / 达芬奇的做法，差的那截用首尾帧定格补：接缝前半程 A 照常播、
    // B 的**首帧**定住淡入，后半程 B 照常播、A 的**尾帧**定住淡出。片段位置、
    // 总时长都不动。纯白 / 纯黑素材分辨不出「在播」还是「定住」，但分辨得出
    // 「定格那一截有没有画面」：没做出定格，那一截就是黑的。
    do {
        func seam(_ a: URL, _ b: URL) -> TimelineState {
            var first = EditClip(sourceURL: a, sourceDuration: 4, timelineStart: 0, info: info(canvas, seconds: 4))
            first.transitionAfter = .crossFade
            first.transitionDuration = 1
            let second = EditClip(sourceURL: b, sourceDuration: 4, timelineStart: 4, info: info(canvas, seconds: 4))
            var state = TimelineState()
            state.mainClips = [first, second]
            return state
        }
        let whiteToBlack = seam(white, black)
        check(whiteToBlack.mainClips[0].trailingHandle == 0 && whiteToBlack.mainClips[1].leadingHandle == 0,
              "这一版里两边确实都没有余料")
        check(capacity(whiteToBlack.transitionCapacity(afterMainIndex: 0), isAbout: 1.6),
              "零余料的缝上叠化可用，容量按长度 = 4s × 0.4")

        // 渲染副本：两边各定格 d/2，窗口跨在缝上（和时间线遮罩「缝 ± d/2」一致）。
        let expanded = whiteToBlack.expandingTransitionHandles()
        check(abs(expanded.mainClips[0].renderHoldTail - 0.5) < 0.001, "出场段尾帧定格 d/2")
        check(abs(expanded.mainClips[1].renderHoldHead - 0.5) < 0.001, "进场段首帧定格 d/2")
        check(expanded.mainClips[0].renderHoldHead == 0 && expanded.mainClips[1].renderHoldTail == 0,
              "另外两头没有定格")
        check(abs(expanded.mainClips[1].timelineStart - 3.5) < 0.001, "进场段在渲染副本里提前 d/2 进场")
        check(abs(expanded.mainClips[0].timelineEnd - 4.5) < 0.001, "出场段在渲染副本里延后 d/2 退场")
        check(abs(expanded.transitionOverlap(afterMainIndex: 0) - 1) < 0.001, "展开后两段正好相叠 d")
        check(abs(expanded.duration - whiteToBlack.duration) < 0.001, "定格补足不许改变时间线总长")
        check(abs(expanded.mainClips[0].renderSourceDuration - 4) < 0.001
              && abs(expanded.mainClips[1].renderSourceStart) < 0.001,
              "真正从素材里取的仍然是原来那 4s，定格那截不去素材里要")
        // 用户的工程不许带着定格字段：它只在渲染副本里存在。
        check(whiteToBlack.mainClips.allSatisfy { $0.renderHoldHead == 0 && $0.renderHoldTail == 0 },
              "原件的定格字段恒为 0")

        if let graph = await filterGraph(whiteToBlack, name: "hold-graph") {
            check(graph.contains("xfade=transition=fade"), "零余料 + 叠化 → 导出发 xfade")
            check(graph.contains("tpad=stop_mode=clone:stop_duration=0.5"), "出场段用 tpad 复制尾帧 0.5s")
            check(graph.contains("tpad=start_mode=clone:start_duration=0.5"), "进场段用 tpad 复制首帧 0.5s")
        }

        // 真跑导出：白→黑，4.25s 处是 A 的**尾帧定格**以 25% 叠在 B 上。
        if let product = await export(whiteToBlack, name: "hold-white-black.mp4"),
           let whiteLevel = brightness(product, at: 1, name: "hold-wb"),
           let blackLevel = brightness(product, at: 7, name: "hold-wb"),
           let late = brightness(product, at: 4.25, name: "hold-wb"),
           let early = brightness(product, at: 3.75, name: "hold-wb") {
            let span = whiteLevel - blackLevel
            check(span > 0.5, "白段和黑段要分得开，实测白 \(whiteLevel)、黑 \(blackLevel)")
            let lateMix = (late - blackLevel) / span
            let earlyMix = (early - blackLevel) / span
            check(abs(lateMix - 0.25) < 0.1,
                  "接缝后 0.25s：A 的尾帧定格还剩 25% —— 没做出定格这里是全黑，实测 \(lateMix)")
            check(abs(earlyMix - 0.75) < 0.1, "接缝前 0.25s：A 还有 75%，实测 \(earlyMix)")
            if let length = mediaDuration(product) {
                check(abs(length - 8) < 0.15, "成片总长不变（8s），实测 \(length)")
            } else {
                check(false, "读不出成片时长")
            }
        }

        // 黑→白：3.75s 处是 B 的**首帧定格**透出 25%。
        if let product = await export(seam(black, white), name: "hold-black-white.mp4"),
           let blackLevel = brightness(product, at: 1, name: "hold-bw"),
           let whiteLevel = brightness(product, at: 7, name: "hold-bw"),
           let early = brightness(product, at: 3.75, name: "hold-bw") {
            let span = whiteLevel - blackLevel
            let earlyMix = (early - blackLevel) / span
            check(abs(earlyMix - 0.25) < 0.1,
                  "接缝前 0.25s：B 的首帧定格已经透出 25% —— 没做出定格这里是全黑，实测 \(earlyMix)")
        }
    }

    // 4c. 缝不成立的两种情形：两条管线必须**都**当它没有转场
    do {
        // 出场段只有 0.1s：做不出像样的叠化（2026-09-23 之前这里测的是「零余料」，
        // 余料不够现在改成定格补足了，唯一还放不下的就是太短的段）。
        var first = EditClip(sourceURL: white, sourceDuration: 0.1, timelineStart: 0, info: info(canvas, seconds: 2))
        first.transitionAfter = .crossFade
        first.transitionDuration = 0.4
        let touching = EditClip(sourceURL: black, sourceDuration: 2, timelineStart: 0.1, info: info(canvas, seconds: 2))
        var state = TimelineState()
        state.mainClips = [first, touching]

        check(state.transitionCapacity(afterMainIndex: 0) == .tooShort, "出场段只有 0.1s → 放不下")
        check(
            state.expandingTransitionHandles().transitionOverlap(afterMainIndex: 0) == 0,
            "放不下时，预览侧也不许挂淡变（以前就是这里和导出分了叉）"
        )
        if let graph = await filterGraph(state, name: "too-short-graph") {
            check(!graph.contains("xfade="), "放不下 → 导出不许发 xfade")
        }

        var gapped = state
        gapped.mainClips[0].sourceDuration = 2
        gapped.mainClips[1].timelineStart = 2.5
        check(gapped.transitionCapacity(afterMainIndex: 0) == .notAdjacent, "中间有空隙的不算一条缝")
        check(
            gapped.expandingTransitionHandles().transitionOverlap(afterMainIndex: 0) == 0,
            "有空隙时预览侧也不许挂淡变"
        )
        if let graph = await filterGraph(gapped, name: "gap-graph") {
            check(!graph.contains("xfade="), "有空隙 → 导出不许发 xfade")
        }
    }

    // MARK: 5. 预渲染的中间片**不许**把该让位的渐变烤进画面
    //
    // 回归守卫，事故见 docs/bugfixes/2026-09-18-prerender-fade-ignores-transition.md：
    // 带逐帧动画的段走 AnimatedClipPrerenderer 渲中间片，而那条临时时间线里
    // 只有它自己、没有邻居 —— 仲裁不在外面做完就传进去的话，`VideoFade.effective`
    // 会以为「两边都没转场」，把本该归 xfade 的渐变烤进画面。预览侧是正确让位的，
    // 于是表现为「预览让位、成片还在淡黑」。
    //
    // 这一条只能量像素：中间片是当普通素材进图的，滤镜图上看不出区别。
    do {
        let tol = KeyframeTrack.sourceTolerance(frameRate: .fps24, speed: 1)
        var animation = ClipAnimation()
        // 恒等动画：值全程是 1，画面不变，但足够让这一段走预渲染那条路。
        animation.opacity.set(1, atSourceTime: 0, tolerance: tol)
        animation.opacity.set(1, atSourceTime: 2, tolerance: tol)

        var first = EditClip(sourceURL: white, sourceDuration: 2, timelineStart: 0, info: info(canvas, seconds: 2))
        first.animation = animation
        first.transitionAfter = .crossFade
        first.transitionDuration = 0.5
        // 结尾这条边归转场管 —— 设了也不该生效（修复前会被烤进中间片）。
        first.videoFadeOutDuration = 1
        let second = EditClip(
            sourceURL: black, sourceDuration: 2, timelineStart: 1.5, info: info(canvas, seconds: 2)
        )
        var state = TimelineState()
        state.mainClips = [first, second]
        if let product = await export(state, name: "prerender-seam.mp4") {
            // t=1.4：在「被烤进去的渐出」窗口里（1.0→2.0）、但还没进转场窗口
            // （1.5→2.0）。让位了就是满白；没让位的话此刻只剩 60% 亮度。
            if let level = brightness(product, at: 1.4, name: "prerender-seam") {
                check(level > 0.9, "接缝那一边的渐变必须让位给转场，不许烤进中间片，实测 \(level)")
            }
        }
    }

    // MARK: 6. 预设入场动画：逐帧效果真的进了成片
    //
    // 擦除是几何量，成片上一量就知道对不对：2s 的窗口走到半程时，
    // 左半边该是这一段的画面、右半边还是垫在下面的黑底。
    do {
        var clip = EditClip(sourceURL: white, sourceDuration: 4, timelineStart: 0, info: landscape)
        clip.presetAnimation.entrance = .wipe
        clip.videoFadeInDuration = 2
        var state = TimelineState()
        state.mainClips = [clip]
        check(clip.needsPerFrameRender, "擦除入场必须走逐帧路径（否则 ffmpeg 的 fade 顶不了这活）")
        if let product = await export(state, name: "preset-wipe.mp4") {
            if let level = pixel(product, x: 8, y: 18, at: 1.0, name: "preset-wipe-left") {
                check(level > 0.7, "擦除半程时左侧应当已经揭开（白），实测 \(level)")
            }
            if let level = pixel(product, x: 56, y: 18, at: 1.0, name: "preset-wipe-right") {
                check(level < 0.3, "擦除半程时右侧还没揭开，应当是垫底的黑，实测 \(level)")
            }
            if let level = brightness(product, at: 3.0, name: "preset-wipe-end") {
                check(level > 0.9, "动画结束后应当是完整画面（白），实测 \(level)")
            }
        }
    }

    // MARK: 藏起来的上层段不进成片（2026-09-26，用例在 HiddenClips.swift）
    await checkHiddenUpperClips(white: white, black: black, info: landscape)

    if failures == 0 {
        print("\(checks) checks, 0 failures")
        print("All checks passed")
        finish(0)
    }
    print("\(checks) checks, \(failures) failures")
    finish(1)
}

await main()
