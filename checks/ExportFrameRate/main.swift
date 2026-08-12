import AVFoundation
import Foundation
import SrtFlowCore

// **真实生产导出滤镜的帧率回归**（计划 §17.3）。
//
// 与 `scripts/check-export-alpha-compositing.sh` 的区别，务必分清：
// - 那个是**手工复制的独立 alpha fixture**，守 alpha 合成数学，
//   **不调用生产代码**，而且只取第一帧 —— 帧率写错它也发现不了。
// - 本检查调用**真实的 `VideoEditExportGraph.plan()`** 拿到生产 ffmpeg 参数，
//   真跑一遍 ffmpeg，再数输出帧。这才是「导出真的按工程帧率出片」的回归。
//
// 第二组用例守**主轨拼接链**（硬切 concat 与转场 xfade 混排的两种顺序），
// 见文件后半段和 docs/architecture/project-frame-rate.md 的约束 6。
//
// 编译方式见 scripts/check-export-frame-rate.sh。

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
    .appendingPathComponent("srtflow-exportfps-\(UUID().uuidString)", isDirectory: true)
try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
// 注意**不能**用顶层 defer 清理：本文件所有出口都是 exit()，而 exit() 不跑
// defer（实测 previewcheck 因此攒了 52 个临时目录、本检查攒了 8 个）。
// 统一走 finish()。
func finish(_ code: Int32) -> Never {
    try? FileManager.default.removeItem(at: root)
    exit(code)
}

/// 跑一条命令，返回 (退出码, 合并输出)。
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
    return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

/// 造一段 2 秒素材（10 fps，故意与所有工程帧率都不同 ——
/// 这样输出帧数只可能来自滤镜里的 fps，不可能是源帧透传）。
func makeSource() -> URL {
    let url = root.appendingPathComponent("src.mp4")
    let (code, out) = run(ffmpegPath, [
        "-y", "-hide_banner", "-loglevel", "error",
        "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=10:duration=2",
        "-c:v", "libx264", "-pix_fmt", "yuv420p", url.path,
    ])
    if code != 0 { print("造素材失败：\(out)") }
    return url
}

/// 同上，但带一条真音轨 —— 转场那组用例要连 `acrossfade` 一起走真实拼接链。
func makeSourceWithAudio() -> URL {
    let url = root.appendingPathComponent("src-audio.mp4")
    let (code, out) = run(ffmpegPath, [
        "-y", "-hide_banner", "-loglevel", "error",
        "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=10:duration=2",
        "-f", "lavfi", "-i", "sine=frequency=440:duration=2",
        "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", url.path,
    ])
    if code != 0 { print("造带声素材失败：\(out)") }
    return url
}

/// 数一个文件的视频帧数。
func frameCount(_ url: URL) -> Int {
    let (_, out) = run(ffmpegPath, [
        "-hide_banner", "-loglevel", "error",
        "-i", url.path, "-map", "0:v", "-f", "null", "-",
        "-progress", "pipe:1",
    ])
    // -progress 的输出里 frame=N 会多次出现，取最后一个
    let frames = out.split(separator: "\n")
        .compactMap { line -> Int? in
            guard line.hasPrefix("frame=") else { return nil }
            return Int(line.dropFirst("frame=".count).trimmingCharacters(in: .whitespaces))
        }
    return frames.last ?? -1
}

func main() async {
    guard FileManager.default.isExecutableFile(atPath: ffmpegPath) else {
        print("找不到 ffmpeg：\(ffmpegPath)（跑 scripts/vendor-ffmpeg.sh，或设 SRTFLOW_FFMPEG）")
        finish(1)
    }
    let src = makeSource()
    guard FileManager.default.fileExists(atPath: src.path) else {
        print("测试素材没造出来"); finish(1)
    }
    let sourceFrames = frameCount(src)
    check(sourceFrames == 20, "素材应当是 10fps × 2s = 20 帧（实得 \(sourceFrames)）")

    let info = MediaInfo(
        duration: 2, displaySize: CGSize(width: 320, height: 180), frameRate: 10,
        videoCodec: "h264", audioCodec: nil, hasAudio: false,
        audioCanCopyToMP4: false, fileBytes: 1
    )

    var measured: [Int: Int] = [:]
    for rate in ProjectFrameRate.allCases {
        var state = TimelineState()
        state.frameRate = rate
        state.canvasRatio = .wide16x9
        state.mainClips = [
            EditClip(sourceURL: src, sourceDuration: 2, timelineStart: 0, info: info)
        ]

        let output = root.appendingPathComponent("out-\(rate.fps).mp4")
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
            check(false, "\(rate.fps)fps 的 plan() 失败：\(error)")
            continue
        }
        // plan() 把 workspace（ASS/字体/形状 PNG + tempOutput）的所有权交给
        // 调用方 —— 正常导出里由 VideoEditExporter 用完删除。检查不删的话
        // 每跑一次泄漏一个 SrtFlow-Edit-* 目录（复审实测攒了 15 个约 5 MB）。
        defer { try? FileManager.default.removeItem(at: plan.workspace) }

        // 生产参数里必须出现本工程帧率，且**不得**出现别的帧率
        let joined = plan.arguments.joined(separator: " ")
        check(joined.contains("fps=\(rate.fps)"),
              "\(rate.fps)fps 的生产参数里应当有 fps=\(rate.fps)")
        for other in ProjectFrameRate.allCases where other != rate {
            check(!joined.contains("fps=\(other.fps)"),
                  "\(rate.fps)fps 的参数里不该混入 fps=\(other.fps)")
        }

        // 真跑一遍生产参数
        let (code, out) = run(ffmpegPath, plan.arguments)
        guard code == 0 else {
            check(false, "\(rate.fps)fps 的 ffmpeg 执行失败：\(out.suffix(400))")
            continue
        }
        let produced = frameCount(plan.tempOutput)
        measured[rate.fps] = produced

        // 2 秒 × N fps，允许 ±2 帧的容器边界
        let expected = rate.fps * 2
        check(abs(produced - expected) <= 2,
              "\(rate.fps)fps 的 2 秒素材应出约 \(expected) 帧（实得 \(produced)）")
        // 关键：输出帧数**不能**等于源帧数，否则说明 fps 滤镜没生效（源是 10fps/20 帧）
        check(produced != sourceFrames,
              "\(rate.fps)fps 的输出帧数不该等于源帧数 \(sourceFrames)（那说明 fps 滤镜没生效）")
    }

    // 三档必须明显区分 —— 帧率若被写死，三档会得到相同帧数
    if let f24 = measured[24], let f30 = measured[30], let f60 = measured[60] {
        check(f30 > f24, "30fps 的帧数要多于 24fps（\(f30) vs \(f24)）")
        check(f60 > f30, "60fps 的帧数要多于 30fps（\(f60) vs \(f30)）")
        check(f60 >= f24 * 2 - 4, "60fps 的帧数应接近 24fps 的 2.5 倍量级")
    } else {
        check(false, "三档没有全部测到：\(measured)")
    }

    // MARK: 拼接链：硬切和转场混排
    //
    // xfade 在 config_output 里硬性要求两条输入的 timebase 逐字段相等。段自己
    // 走 fps=<帧率> 出来是 1/fps，concat 的输出却固定是 AVTB(1/1000000)：修复前
    // 只要转场**前面**出现过一次硬切（或补黑场的缝），整个导出就报
    // “First input link main timebase (1/1000000) do not match … xfade timebase (1/24)”
    // 直接失败。见 docs/bugfixes/2026-08-12-xfade-timebase-mismatch.md。
    //
    // 两种顺序都跑：硬切在前（就是那个 bug）和转场在前（修复前本来就好使的
    // 那条，用来证明「两侧都压 AVTB」没把它弄坏）。素材带真音轨，
    // acrossfade 接在 concat 后面这一路也一并走到。
    let audioSrc = makeSourceWithAudio()
    let audioInfo = MediaInfo(
        duration: 2, displaySize: CGSize(width: 320, height: 180), frameRate: 10,
        videoCodec: "h264", audioCodec: "aac", hasAudio: true,
        audioCanCopyToMP4: true, fileBytes: 1
    )
    /// 三段各 2 秒，一处硬切一处转场（叠 0.5 秒）→ 时间线总长 5.5 秒。
    func mixedTimeline(transitionFirst: Bool) -> TimelineState {
        var state = TimelineState()
        state.frameRate = .fps24
        state.canvasRatio = .wide16x9
        func clip(at start: Double, transition: ClipTransition) -> EditClip {
            EditClip(
                sourceURL: audioSrc, sourceDuration: 2, timelineStart: start,
                transitionAfter: transition, transitionDuration: 0.5, info: audioInfo
            )
        }
        state.mainClips = transitionFirst
            ? [clip(at: 0, transition: .crossFade), clip(at: 1.5, transition: .none), clip(at: 3.5, transition: .none)]
            : [clip(at: 0, transition: .none), clip(at: 2, transition: .crossFade), clip(at: 3.5, transition: .none)]
        return state
    }

    for transitionFirst in [false, true] {
        let name = transitionFirst ? "转场在前、硬切在后" : "硬切在前、转场在后"
        let output = root.appendingPathComponent("mixed-\(transitionFirst).mp4")
        let plan: VideoEditExportGraph.Plan
        do {
            plan = try await VideoEditExportGraph.plan(
                state: mixedTimeline(transitionFirst: transitionFirst),
                settings: VideoEncodeSettings(),
                subtitleStyle: BurnInStyle(name: "check"),
                subtitleFontURL: nil,
                output: output
            )
        } catch {
            check(false, "\(name) 的 plan() 失败：\(error)")
            continue
        }
        defer { try? FileManager.default.removeItem(at: plan.workspace) }

        check(plan.arguments.joined(separator: " ").contains("xfade"),
              "\(name)：这条用例本来就该走到 xfade，滤镜图里却没有它")
        let (code, out) = run(ffmpegPath, plan.arguments)
        // 修复前这里是非零退出 + timebase 不匹配 —— 守卫的核心就是这一条。
        check(code == 0, "\(name) 的 ffmpeg 执行失败：\(out.suffix(400))")
        guard code == 0 else { continue }
        // 2+2+2 秒叠掉 0.5 秒 = 5.5 秒 × 24fps = 132 帧
        let produced = frameCount(plan.tempOutput)
        check(abs(produced - 132) <= 2, "\(name) 应出约 132 帧（实得 \(produced)）")
    }

    print("\(checks) checks, \(failures) failures")
    print("实测帧数：\(measured.sorted { $0.key < $1.key }.map { "\($0.key)fps→\($0.value)帧" }.joined(separator: "  "))")
    if failures == 0 { print("All checks passed") }
    finish(failures == 0 ? 0 : 1)
}

let semaphore = DispatchSemaphore(value: 0)
Task { await main(); semaphore.signal() }
semaphore.wait()
